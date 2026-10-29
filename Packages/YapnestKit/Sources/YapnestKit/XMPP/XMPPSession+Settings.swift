import Combine
import Foundation
import GRDB
@preconcurrency import Martin

/// How a settings sync ended, for whoever owes it again.
enum SettingsSyncOutcome: Sendable {
    /// The whole node was read and applied.
    case done
    /// It was cut short, or the server couldn't say for now: to be done again.
    case owed
    /// Not to be done this session, as the node can't be made private.
    case refused

    var isOwed: Bool { self == .owed }
}

/// What our other devices did to the settings node (see `SettingsItem`).
enum SettingsChange {
    case published(id: String, payload: Element?)
    case retracted(String)
}

/// Notifies us when another of our devices changes Yapnest's settings in our
/// PEP.
final class SettingsSyncModule: AbstractPEPModule, XmppModule, @unchecked Sendable {
    static let ID = NS.settings
    static let IDENTIFIER = XmppModuleIdentifier<SettingsSyncModule>()

    let criteria = Criteria.empty()
    let features = [NS.settings + "+notify"]
    let changes = PassthroughSubject<SettingsChange, Never>()

    func process(stanza: Stanza) throws {
        throw XMPPError.feature_not_implemented
    }

    override func onItemNotification(notification: PubSubModule.ItemNotification) {
        // Only our own account may change our settings.
        guard notification.node == NS.settings, let context,
              notification.message.from == nil || notification.message.from?.bareJid == context.userBareJid else { return }
        switch notification.action {
        case .published(let item): changes.send(.published(id: item.id, payload: item.payload))
        case .retracted(let id): changes.send(.retracted(id))
        }
    }
}

/// Where syncing the settings stands on this connection.
struct SettingsSyncState: @unchecked Sendable {
    enum Node {
        /// Not looked at yet, so nothing is published.
        case unchecked
        /// Confirmed to be readable by nobody else.
        case verified
        /// Not private and not made so: nothing is published this session.
        case refused
    }

    var node = Node.unchecked
    /// Counts sessions, so work from an earlier one stops when it notices.
    var epoch = 0
    /// Set once the server didn't answer `max_items=max`: the node then has
    /// an explicit limit, and publishes don't ask for it again.
    var explicitMaxItems = false
    /// Items the server refused for good, by what they held when it did: not
    /// published again this session unless they change or the user retries.
    var refusedItems: [String: String] = [:]
    var syncing = false
    var syncStarted = false
    /// Whether this session's sync ran to its end. One cut off by the stream
    /// dropping is run again when the stream resumes.
    var syncCompleted = false
    /// Items that arrived live while a sync was reading the node, which its
    /// pages may predate: not to be taken as gone from the server.
    var liveItems = Set<String>()
    var publishing = false
    var publishAgain = false
    var scheduled: (work: DispatchWorkItem, at: Date)?
    var observer: Task<Void, Never>?
    /// Callers of `runSettingsSync` that found one running, to tell how it ended.
    var waiters: [@Sendable (SettingsSyncOutcome) -> Void] = []

    /// The id this device's entries carry, where not the install's.
    var deviceId: String?
    var publishTimeout = XMPPSession.bookmarkTimeout
    var settingsDelay: TimeInterval = 1
    /// Longer for our own usage, which changes in bursts of picks.
    var usageDelay: TimeInterval = 30

    mutating func startSession() {
        epoch += 1
        node = .unchecked
        explicitMaxItems = false
        refusedItems = [:]
        syncing = false
        syncStarted = false
        syncCompleted = false
        liveItems = []
        publishing = false
        publishAgain = false
        scheduled?.work.cancel()
        scheduled = nil
        observer?.cancel()
        observer = nil
    }
}

extension XMPPSession {
    /// How many items to ask for at a time.
    static let settingsPageSize = 100
    /// A node with more pages than this is taken as not fully read.
    static let settingsMaxPages = 100
    /// The limit given to a node whose server doesn't take `max_items=max`.
    static let settingsExplicitMaxItems = "1000"

    // MARK: Remote changes

    func settingsChanged(_ change: SettingsChange) {
        guard policy.syncsAccountState else { return }
        do {
            switch change {
            case .published(let id, let payload):
                lock.withLock { if $0.settingsSync.syncing { $0.settingsSync.liveItems.insert(id) } }
                applySettingsResult(try database.applyRemoteItem(id: id, payload: payload))
            case .retracted(let id):
                switch SettingsItemID(id) {
                case .usage(let device): try database.removeRemoteUsage(deviceId: device)
                case .gif: try database.forgetSyncedItem(id)
                case .global, .chat, .unknown: break
                }
            }
        } catch {
            logger.error("Failed to apply a synced setting: \(error)")
        }
    }

    /// Does what the values that just changed under us ask for. They were
    /// written without being recorded as local changes, so nothing is sent
    /// back by this.
    func applySettingsResult(_ result: AppDatabase.SyncedApplyResult) {
        if result.markedDirty {
            let delay = lock.withLock { $0.settingsSync.settingsDelay }
            scheduleSettingsPublish(after: delay)
        }
        if result.changedGlobalKeys.contains(.sharesLastSeen) {
            do {
                try sharingLastSeenChanged()
            } catch {
                logger.error("Failed to apply sharing last seen: \(error)")
            }
        } else if !result.changedGlobalKeys.isDisjoint(with: [.availability, .statusMessage]) {
            sendPresence()
        }
        if result.changedGlobalKeys.contains(.sharesProfilePublicly) {
            Task.detached(priority: .utility) { [weak self] in await self?.reconcileProfileAccess() }
        }
    }

    // MARK: Sync

    /// Brings the settings in line with the server's, once per session, after
    /// the catch-up so `archivedAt` is judged against the messages we have.
    func syncSettings(then done: @escaping @Sendable (SettingsSyncOutcome) -> Void = { _ in }) {
        guard policy.syncsAccountState else { return }
        Task.detached(priority: .utility) { [weak self] in
            done(await self?.runSettingsSync() ?? .done)
        }
    }

    /// How a settings sync ended. Called while one is running, it waits for
    /// that one's outcome.
    @discardableResult
    func runSettingsSync() async -> SettingsSyncOutcome {
        guard policy.syncsAccountState else { return .refused }
        guard isConnected else { return .owed }
        let epoch = lock.withLock { state -> Int? in
            guard !state.settingsSync.syncing else { return nil }
            state.settingsSync.syncing = true
            state.settingsSync.syncStarted = true
            return state.settingsSync.epoch
        }
        guard let epoch else {
            return await withCheckedContinuation { continuation in
                let queued = lock.withLock { state -> Bool in
                    guard state.settingsSync.syncing else { return false }
                    state.settingsSync.waiters.append { continuation.resume(returning: $0) }
                    return true
                }
                if !queued { continuation.resume(returning: .owed) }
            }
        }
        var outcome = SettingsSyncOutcome.owed
        defer {
            let waiters = lock.withLock { state -> [@Sendable (SettingsSyncOutcome) -> Void] in
                if state.settingsSync.epoch == epoch { state.settingsSync.syncing = false }
                defer { state.settingsSync.waiters = [] }
                return state.settingsSync.waiters
            }
            for waiter in waiters { waiter(outcome) }
        }
        let isCurrent = { [self] in isConnected && lock.withLock { $0.settingsSync.epoch == epoch } }

        do {
            let deviceId = lock.withLock { $0.settingsSync.deviceId } ?? SharedContainer.deviceId
            try database.seedSyncedSettingsIfNeeded(deviceId: deviceId)
        } catch {
            logger.error("Failed to prepare settings sync: \(error)")
            return .owed
        }
        let check = await confirmSettingsNodeIsPrivate(epoch: epoch)
        guard isCurrent() else { return .owed }
        switch check {
        case .isPrivate: break
        case .refused:
            outcome = .refused
            return outcome
        case .failed: return .owed
        }

        lock.withLock { $0.settingsSync.liveItems = [] }
        let fetched = await fetchSettingsItems()
        guard isCurrent() else { return .owed }
        var isWhole = false
        do {
            switch fetched {
            case .complete(let items):
                isWhole = true
                let live = lock.withLock { $0.settingsSync.liveItems }
                applySettingsResult(try database.reconcileFetched(items, keeping: live))
            case .incomplete(let items):
                // Leaving out what the server didn't send would delete it here.
                applySettingsResult(try database.applyFetched(items))
            }
        } catch {
            logger.error("Failed to apply the synced settings: \(error)")
            return .owed
        }
        await retractExpiredSettingsItems()
        startSettingsObservation(epoch: epoch)
        lock.withLock { if $0.settingsSync.epoch == epoch { $0.settingsSync.syncCompleted = true } }
        // Even after a partial fetch: an item published over newer entries
        // is put right by the device holding them, which publishes it again.
        requestSettingsPublish()
        outcome = isWhole ? .done : .owed
        return outcome
    }

    // MARK: Fetching

    enum SettingsFetch {
        case complete([(id: String, payload: Element?)])
        /// Some of the node, or none: not to decide anything is gone from it.
        case incomplete([(id: String, payload: Element?)])
    }

    /// Reads every item, a page at a time. A node that isn't there is an
    /// empty one.
    func fetchSettingsItems() async -> SettingsFetch {
        var items: [(id: String, payload: Element?)] = []
        var seen = Set<String>()
        var query = RSM.Query(max: Self.settingsPageSize)
        var cursor: String?
        for _ in 0..<Self.settingsMaxPages {
            let page: PubSubModule.RetrievedItems
            switch await readNode(NS.settings, as: "Settings", limit: .rsm(query)) {
            case .items(let read): page = read
            case .noNode: return .complete(items)
            // Nothing is decided gone from what wasn't read; the sync is owed again.
            case .unsupported, .failed: return .incomplete(items)
            }
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            items += fresh.map { ($0.id, $0.payload) }
            if page.items.isEmpty { return .complete(items) }
            guard let rsm = page.rsm, let last = rsm.last else {
                // A page with no paging data is the whole node only if it
                // isn't full: a server that ignores the limit would send
                // more than was asked, and one that cut it short a full page.
                if page.items.count < Self.settingsPageSize { return .complete(items) }
                logger.info("The settings node gave a full page without saying where it ends")
                return .incomplete(items)
            }
            if let count = rsm.count, seen.count >= count { return .complete(items) }
            // A server that gives the same page again would never end.
            if fresh.isEmpty || last == cursor {
                logger.info("The settings node did not page as asked")
                return .incomplete(items)
            }
            cursor = last
            query = RSM.Query(after: last, max: Self.settingsPageSize)
        }
        logger.info("The settings node has more pages than are read")
        return .incomplete(items)
    }

    // MARK: Privacy

    /// The node names our contacts and so must be readable by nobody else. A
    /// server may keep another access model than the one asked for, so it is
    /// read back, once per session, before anything is published. A node that
    /// is open is set right once; if it stays so, nothing is synced. It is
    /// never deleted, as that would destroy every other device's settings.
    func confirmSettingsNodeIsPrivate(epoch: Int) async -> NodeCheck {
        switch lock.withLock({ $0.settingsSync.node }) {
        case .verified: return .isPrivate
        case .refused: return .refused
        case .unchecked: break
        }
        let check = await checkSettingsNode()
        lock.withLock { state in
            guard state.settingsSync.epoch == epoch else { return }
            switch check {
            case .isPrivate: state.settingsSync.node = .verified
            case .refused: state.settingsSync.node = .refused
            // Not known either way, so the node stays unchecked and the next
            // sync looks again.
            case .failed: break
            }
        }
        return check
    }

    enum NodeCheck: Equatable {
        case isPrivate
        /// It isn't private and can't be made so, or couldn't be looked at
        /// for a reason that won't pass.
        case refused
        /// The server couldn't say for now: a timeout, a dropped connection,
        /// an error of type `wait`. This is retried at the next sync, which
        /// the app owes again at its next return (see `finishCatchUpAsApp`).
        case failed

        init(failing error: Error) {
            self = ServerError.classify(error).isPassing ? .failed : .refused
        }
    }

    func checkSettingsNode() async -> NodeCheck {
        // The configuration says whether the node can be read at all, so only
        // a node that isn't there is dealt with before it.
        if case .noNode = await readNode(NS.settings, as: "Settings", limit: .lastItems(1)) {
            do {
                try await createSettingsNode()
            } catch {
                logger.error("Couldn't create the settings node, so settings aren't synced: \(error.localizedDescription, privacy: .private)")
                return NodeCheck(failing: error)
            }
        }
        do {
            if try await pepNodeAccessModel(NS.settings) == "whitelist" { return .isPrivate }
            logger.warning("The settings node isn't private; setting it to be")
            try await configurePEPNode(NS.settings, fields: ["pubsub#access_model": ["whitelist"]])
            if try await pepNodeAccessModel(NS.settings) == "whitelist" { return .isPrivate }
            logger.error("The server keeps the settings node readable by others, so settings aren't synced")
        } catch {
            // Syncing stays off for the session when the node couldn't be
            // looked at for good, as it would be published to without knowing
            // who can read it. A failure that can pass is looked at again.
            logger.error("Couldn't check the settings node: \(error.localizedDescription, privacy: .private)")
            return NodeCheck(failing: error)
        }
        return .refused
    }

    /// The access model of one of our PEP nodes; nil when it has none.
    func pepNodeAccessModel(_ node: String) async throws -> String? {
        try await pepNodeConfig(node) { $0.accessModel?.rawValue }
    }

    /// What `read` makes of one of our PEP nodes' configuration, which isn't
    /// itself fit to leave the callback.
    func pepNodeConfig<T: Sendable>(_ node: String, read: @escaping @Sendable (PubSubNodeConfig) -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            client.module(.pubsub).retrieveNodeConfiguration(from: nil, node: node) { (result: Result<PubSubNodeConfig, PubSubError>) in
                continuation.resume(with: result.map(read))
            }
        }
    }

    /// With the node's limit, which the server would otherwise choose: some
    /// keep one item. Openfire never answers a create asking for `max`, so
    /// then the node is created with an explicit limit.
    private func createSettingsNode() async throws {
        let timeout = lock.withLock { $0.settingsSync.publishTimeout }
        do {
            try await createSettingsNode(maxItems: "max", timeout: timeout)
        } catch let error as PubSubError where error.error == .remote_server_timeout {
            logger.info("No answer to creating the settings node with max_items=max; giving it a limit")
            lock.withLock { $0.settingsSync.explicitMaxItems = true }
            try await createSettingsNode(maxItems: Self.settingsExplicitMaxItems, timeout: timeout)
        }
    }

    private func createSettingsNode(maxItems: String, timeout: TimeInterval) async throws {
        let create = OutboundStanza.createNode(NS.settings, fields: Self.settingsNodeFields(maxItems: maxItems))
        do {
            _ = try await client.context.writer.write(iq: create, timeout: timeout, errorDecoder: PubSubError.from(stanza:))
        } catch let error as PubSubError where error.error.errorCondition == .conflict {
            // Created meanwhile, by another of our devices.
        }
    }

    static func settingsNodeFields(maxItems: String) -> [String: [String]] {
        [
            "pubsub#persist_items": ["true"],
            "pubsub#max_items": [maxItems],
            "pubsub#send_last_published_item": ["never"],
            "pubsub#access_model": ["whitelist"],
        ]
    }

    // MARK: Retracting

    /// Takes off the server what every device has had time to learn of: GIF
    /// removals and chats reset to their defaults, older than a month, and devices whose picks have faded out.
    private func retractExpiredSettingsItems() async {
        do {
            for item in try database.expiredTombstones() where await retractSettingsItem(item) {
                try database.forgetSyncedItem(item)
            }
            for device in try database.forgottenUsageDevices() where await retractSettingsItem(AppDatabase.usageItem(device)) {
                try database.removeRemoteUsage(deviceId: device)
            }
        } catch {
            logger.error("Failed to clean up synced settings: \(error)")
        }
    }

    private func retractSettingsItem(_ id: String) async -> Bool {
        do {
            try await retractPEPItem(node: NS.settings, itemId: id)
            return true
        } catch {
            logger.info("Couldn't retract \(id, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    // MARK: Publishing

    /// Publishes what changed here, shortly after it does.
    private func startSettingsObservation(epoch: Int) {
        lock.withLock { state in
            guard state.settingsSync.epoch == epoch, state.settingsSync.observer == nil else { return }
            state.settingsSync.observer = Task.detached(priority: .utility) { [weak self, database] in
                // With the newest version of each, so that an item changed again while
                // it is still marked (one the server refused) is published again.
                let observation = ValueObservation.tracking { db in
                    try Row.fetchAll(db, sql: """
                        SELECT d.item AS item, COALESCE((SELECT MAX(e.version) FROM syncedEntry e WHERE e.item = d.item), '') AS version
                        FROM syncedItemDirty d
                        """).map { $0["item"] as String }
                }
                do {
                    for try await dirty in observation.values(in: database.reader, bufferingPolicy: .bufferingNewest(1)) {
                        guard let self else { return }
                        self.settingsItemsChanged(dirty)
                    }
                } catch {
                    self?.logger.error("Settings observation failed: \(error)")
                }
            }
        }
    }

    func settingsItemsChanged(_ dirty: [String]) {
        guard !dirty.isEmpty else { return }
        let delay = lock.withLock { state in
            dirty.contains { if case .usage = SettingsItemID($0) { false } else { true } } ? state.settingsSync.settingsDelay : state.settingsSync.usageDelay
        }
        scheduleSettingsPublish(after: delay)
    }

    /// Runs one publish after `delay`, unless one is due sooner already.
    func scheduleSettingsPublish(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        lock.withLock { state in
            if let scheduled = state.settingsSync.scheduled, scheduled.at <= deadline { return }
            state.settingsSync.scheduled?.work.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.lock.withLock { $0.settingsSync.scheduled = nil }
                self?.requestSettingsPublish()
            }
            state.settingsSync.scheduled = (work, deadline)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Starts a background run that publishes what is dirty, or has the one
    /// under way go round again. Does nothing until the node is known to be
    /// private: the marks wait.
    func requestSettingsPublish() {
        guard policy.syncsAccountState else { return }
        let epoch = lock.withLock { state -> Int? in
            guard state.settingsSync.node == .verified else { return nil }
            if state.settingsSync.publishing {
                state.settingsSync.publishAgain = true
                return nil
            }
            state.settingsSync.publishing = true
            return state.settingsSync.epoch
        }
        guard let epoch else { return }
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                await self.publishDirtySettings(epoch: epoch)
                let again = self.lock.withLock { state -> Bool in
                    guard state.settingsSync.epoch == epoch else { return false }
                    defer { state.settingsSync.publishAgain = false }
                    if !state.settingsSync.publishAgain { state.settingsSync.publishing = false }
                    return state.settingsSync.publishAgain
                }
                if !again { return }
            }
        }
    }

    private func publishDirtySettings(epoch: Int) async {
        let items: [AppDatabase.PendingSyncItem]
        do {
            items = try database.pendingSyncItems()
        } catch {
            logger.info("Couldn't read the settings to publish: \(error.localizedDescription, privacy: .private)")
            return
        }
        for item in items {
            guard isConnected, lock.withLock({ $0.settingsSync.epoch == epoch && $0.settingsSync.node == .verified }) else { return }
            guard lock.withLock({ $0.settingsSync.refusedItems[item.id] != item.content }) else { continue }
            do {
                try await publishSettingsItem(item.id, item.element)
                try database.markPublished(item)
            } catch {
                // Still dirty, so the next change or connection tries again;
                // one item the server refuses mustn't hold back the rest.
                logger.info("Couldn't publish \(item.id, privacy: .private): \(error.localizedDescription, privacy: .private)")
                // One that is refused for good would otherwise be tried at every
                // connect and never shown. It waits until it changes.
                if ServerError.isFromServer(error), ServerError.classify(error).isFinal {
                    lock.withLock { $0.settingsSync.refusedItems[item.id] = item.content }
                    warnSettingsRefused(error)
                }
            }
        }
    }

    private func warnSettingsRefused(_ error: Error) {
        warnings.post("settings", title: String(localized: "Settings not synced"), friendly: String(localized: "The server wouldn't take a setting"), error: error) { [weak self] in
            try await self?.retryRefusedSettings()
        }
    }

    /// For the warning's Retry: publishes the items the server refused, once more.
    private func retryRefusedSettings() async throws {
        guard isConnected else { throw ServerError.timedOut }
        let refused = lock.withLock { Set($0.settingsSync.refusedItems.keys) }
        for item in try database.pendingSyncItems() where refused.contains(item.id) {
            try await publishSettingsItem(item.id, item.element)
            try database.markPublished(item)
            lock.withLock { _ = $0.settingsSync.refusedItems.removeValue(forKey: item.id) }
        }
    }

    private func publishSettingsItem(_ id: String, _ payload: Element) async throws {
        let (explicit, timeout) = lock.withLock { ($0.settingsSync.explicitMaxItems, $0.settingsSync.publishTimeout) }
        if explicit {
            try await publishPEPKeepingErrors(
                node: NS.settings, itemId: id, payload: payload, accessModel: "whitelist",
                config: Self.settingsNodeFields(maxItems: Self.settingsExplicitMaxItems),
            )
            return
        }
        do {
            try await publishPEPKeepingErrors(
                node: NS.settings, itemId: id, payload: payload, accessModel: "whitelist",
                config: Self.settingsNodeFields(maxItems: "max"), timeout: timeout,
            )
        } catch where isConnected && Self.refusesMaxItems(error) {
            // Openfire never answers a publish asking for `max`, or fails it
            // when the node has a limit of its own. Any other failure leaves
            // the item for a later try, as capping the node of a server that
            // takes `max` would cost it its history for good. A slow answer
            // is that of a server that takes it too, so the node's own
            // configuration says whether it holds a limit.
            if error is TimeoutError, !(await settingsNodeHasLimit()) { throw error }
            logger.info("Publishing settings with max_items=max failed; giving the node a limit")
            let fields = Self.settingsNodeFields(maxItems: Self.settingsExplicitMaxItems)
            try await configurePEPNode(NS.settings, fields: fields)
            lock.withLock { $0.settingsSync.explicitMaxItems = true }
            try await publishPEPKeepingErrors(node: NS.settings, itemId: id, payload: payload, accessModel: "whitelist", config: fields)
        }
    }

    /// Whether the node is set to keep a number of items rather than `max`.
    /// False when the configuration can't be read: nothing says it is capped.
    private func settingsNodeHasLimit() async -> Bool {
        let hasLimit = try? await pepNodeConfig(NS.settings) { config in
            if case .value? = config.maxItems { true } else { false }
        }
        return hasLimit ?? false
    }

    /// Whether a publish asking for `max_items=max` failed the way a server
    /// that doesn't take it does: no answer in time, or the errors Openfire gives.
    static func refusesMaxItems(_ error: Error) -> Bool {
        if error is TimeoutError { return true }
        guard let error = error as? PubSubError else { return false }
        return error.error.errorCondition == .internal_server_error || error.error.errorCondition == .not_acceptable
    }
}
