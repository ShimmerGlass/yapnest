import Foundation
@preconcurrency import Martin

/// Push notifications (XEP-0357) through Yapnest's relay: the relay hands out
/// a node for this device's APNs token, and our server publishes to it when a
/// message arrives while the app is away.
extension XMPPSession {
    /// The relay the App Store builds use.
    public static let defaultPushRelay = JID("push.yapnest.fr")!

    /// The relay's ad-hoc command that turns a device token into a node.
    static let registerPushCommand = "register-push-apns"

    /// Remembers this device's APNs token and enables push with it, now if
    /// we're connected or else after the next catch-up.
    public func setPushToken(_ token: Data, sandbox: Bool) {
        let hex = token.hex
        let environment = sandbox ? "sandbox" : "production"
        let changed = (try? database.setting(.pushToken)) != hex || (try? database.setting(.pushEnvironment)) != environment
        try? database.setSetting(.pushToken, hex)
        try? database.setSetting(.pushEnvironment, environment)
        if changed, state.value == .connected(isSyncing: false) { enablePush() }
    }

    /// Asks the relay for a node and our server to publish to it. Servers tie
    /// it to the session, so every new session enables it again.
    func enablePush() {
        guard policy.registersPush, isConnected,
              let token = try? database.setting(.pushToken),
              let environment = try? database.setting(.pushEnvironment) else { return }
        guard client.module(.disco).accountDiscoResult.features.contains(NS.push) else {
            logger.info("Server has no push notifications")
            return
        }
        disableStalePushNodes()
        requestPushEnable(token: token, environment: environment, done: pushEnableFinished)
    }

    /// One try at enabling push: the relay's node, then our server's enable.
    private func requestPushEnable(token: String, environment: String, done: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let relay = pushRelay
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(relay.martin)
        let command = Element(name: "command", xmlns: NS.commands)
        command.setAttribute("node", value: Self.registerPushCommand)
        command.setAttribute("action", value: "execute")
        let form = Element(name: "x", xmlns: NS.dataForms)
        form.setAttribute("type", value: "submit")
        for (name, value) in [("token", token), ("environment", environment)] {
            let field = Element(name: "field", attributes: ["var": name])
            field.addChild(Element(name: "value", cdata: value))
            form.addChild(field)
        }
        command.addChild(form)
        iq.addChild(command)
        client.context.writer.write(iq) { [weak self] result in
            guard let self else { return }
            let node = (try? result.get())?.firstChild(name: "command", xmlns: NS.commands)?.firstChild(name: "x", xmlns: NS.dataForms)?
                .filterChildren(name: "field", xmlns: nil).first { $0.getAttribute("var") == "node" }?.firstChild(name: "value")?.value
            guard let node, !node.isEmpty else {
                self.logger.error("The push relay \(relay, privacy: .private) didn't register us: \(String(describing: result), privacy: .private)")
                // An error is the relay's own to give; an answer without a node is final.
                if case .failure(let error) = result { done(.failure(error)) } else { done(.failure(ServerError(condition: "undefined-condition", type: .cancel))) }
                return
            }
            self.enablePush(relay: relay, node: node, done: done)
        }
    }

    /// An enable that failed may pass: it is tried again a few times, and
    /// again when a resumed stream returns (`resumeWork`), as one stream can
    /// last days. What stays failing is shown, whatever its type, unless the
    /// connection went away meanwhile: the next session enables it again.
    private func pushEnableFinished(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            lock.withLock { $0.pushEnableFailed = false }
            warnings.clear("push")
        case .failure(let error):
            lock.withLock { $0.pushEnableFailed = true }
            guard ServerError.classify(error).isPassing else { return postPushWarning(error) }
            Task { [weak self] in
                guard let self else { return }
                let (backoff, started) = lock.withLock { ($0.retryBackoff, $0.attempt) }
                if backoff > 0 { try? await Task.sleep(for: .seconds(backoff)) }
                guard isConnected else { return }
                do {
                    try await retryingPassingErrors { try await attemptPushEnable() }
                    pushEnableFinished(.success(()))
                } catch {
                    guard isConnected, lock.withLock({ $0.attempt }) == started else { return }
                    postPushWarning(error)
                }
            }
        }
    }

    private func postPushWarning(_ error: Error) {
        warnings.post("push", title: String(localized: "Notifications are off"), friendly: String(localized: "The server couldn't turn on notifications"), error: error) { [weak self] in
            try await self?.attemptPushEnable()
        }
    }

    /// Why an attempt to enable push couldn't be made at all.
    enum PushEnableError: Error, LocalizedError {
        /// iOS hasn't given this device a token, so there is nothing to register.
        case noToken

        var errorDescription: String? {
            String(localized: "This device hasn't been given a notification token yet.")
        }
    }

    /// For the retries and the warning's Retry: a try that throws what failed.
    /// Returning means push is enabled: being offline, or having no token,
    /// throws, so a Retry doesn't clear the warning for what it didn't fix.
    private func attemptPushEnable() async throws {
        // A dropped connection, which passes: the next session enables it again.
        guard isConnected else { throw URLError(.networkConnectionLost) }
        guard let token = try? database.setting(.pushToken), let environment = try? database.setting(.pushEnvironment) else {
            throw PushEnableError.noToken
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            requestPushEnable(token: token, environment: environment) { continuation.resume(with: $0) }
        }
        lock.withLock { $0.pushEnableFailed = false }
    }

    private func enablePush(relay: JID, node: String, done: @escaping @Sendable (Result<Void, Error>) -> Void) {
        // Spelled out: a bare trailing closure picks the overload that reports
        // only that the stanza was written, and not the server's answer.
        client.context.writer.write(Self.pushIq("enable", relay: relay, node: node), completionHandler: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Only now: disabling the old node first would leave the
                // stored one dead if this enable failed. A node for an older
                // token, or another relay, would keep notifying.
                var staleNow: StalePushNode?
                if let oldRelay = (try? self.database.setting(.pushRelay)).flatMap(JID.init(_:)), let oldNode = try? self.database.setting(.pushNode),
                   oldRelay != relay || oldNode != node {
                    let stale = StalePushNode(relay: oldRelay.description, node: oldNode)
                    self.addStalePushNode(stale)
                    staleNow = stale
                }
                try? self.database.setSetting(.pushRelay, relay.description)
                try? self.database.setSetting(.pushNode, node)
                // The older ones were asked for when this enable began.
                if let staleNow { self.disableStalePushNodes([staleNow]) }
                self.logger.info("Push enabled through \(relay, privacy: .private)")
                done(.success(()))
            case .failure(let error):
                // An enable nobody answered may still have gone through, so
                // the node is kept to be disabled later (never the one in use).
                if case .remote_server_timeout = error {
                    self.addStalePushNode(StalePushNode(relay: relay.description, node: node))
                }
                self.logger.error("Our server didn't enable push: \(error)")
                done(.failure(error))
            }
        })
    }

    /// A node that must be disabled, kept until the server says it's gone:
    /// a lost request would otherwise leave it notifying this device.
    struct StalePushNode: Codable, Equatable {
        var relay: String
        var node: String
    }

    private func stalePushNodes() -> [StalePushNode] {
        Self.decodeStale(try? database.setting(.pushStaleNodes))
    }

    private static func decodeStale(_ json: String?) -> [StalePushNode] {
        json.flatMap { try? JSONDecoder().decode([StalePushNode].self, from: Data($0.utf8)) } ?? []
    }

    /// Changes the list in one transaction, as answers to several disables
    /// can arrive together.
    private func updateStalePushNodes(_ change: @escaping @Sendable (inout [StalePushNode]) -> Void) {
        try? database.writer.write { db in
            var nodes = Self.decodeStale(try AppDatabase.setting(db, .pushStaleNodes))
            change(&nodes)
            if nodes.isEmpty {
                try AppDatabase.setSetting(db, .pushStaleNodes, nil)
            } else if let json = try? JSONEncoder().encode(nodes) {
                try AppDatabase.setSetting(db, .pushStaleNodes, String(decoding: json, as: UTF8.self))
            }
        }
    }

    private func addStalePushNode(_ stale: StalePushNode) {
        updateStalePushNodes { if !$0.contains(stale) { $0.append(stale) } }
    }

    /// Asks the server to disable each replaced node, and forgets it once the
    /// server answers that it did or that the node is already gone. Runs on
    /// every connect until then.
    private func disableStalePushNodes(_ nodes: [StalePushNode]? = nil) {
        let current = StalePushNode(relay: (try? database.setting(.pushRelay)) ?? "", node: (try? database.setting(.pushNode)) ?? "")
        for stale in nodes ?? stalePushNodes() {
            // The node in use is never disabled, whatever the list says.
            guard stale != current, let relay = JID(stale.relay) else {
                updateStalePushNodes { $0.removeAll { $0 == stale } }
                continue
            }
            // Spelled out, as in `enablePush`: only this overload reports the answer.
            client.context.writer.write(Self.pushIq("disable", relay: relay, node: stale.node), completionHandler: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success, .failure(.item_not_found):
                    self.updateStalePushNodes { $0.removeAll { $0 == stale } }
                case .failure(let error):
                    self.logger.error("Couldn't disable the old push node, will retry: \(error)")
                }
            })
        }
    }

    /// Stops notifications to this device, before signing out: the current
    /// node and every older one still waiting to be disabled. Not a disable
    /// without a node, which would stop the account's other devices at the
    /// same relay too. Best effort, and short: the sign-out waits for it, and
    /// an unanswered request would otherwise hold it up for Martin's 30
    /// seconds. A node is forgotten only once the server has answered; the
    /// relay drops the token itself once pushes to it start failing.
    public func disablePush() async {
        guard isConnected else { return }
        let current = (try? database.setting(.pushRelay)).flatMap { relay in
            (try? database.setting(.pushNode)).map { StalePushNode(relay: relay, node: $0) }
        }
        var nodes = stalePushNodes()
        if let current, !nodes.contains(current) { nodes.append(current) }
        let answered = await withTaskGroup(of: StalePushNode?.self) { group in
            for stale in nodes {
                guard let relay = JID(stale.relay) else {
                    group.addTask { stale }
                    continue
                }
                group.addTask { [client] in
                    await withCheckedContinuation { (done: CheckedContinuation<StalePushNode?, Never>) in
                        client.context.writer.write(Self.pushIq("disable", relay: relay, node: stale.node), timeout: 5, completionHandler: { result in
                            switch result {
                            case .success, .failure(.item_not_found): done.resume(returning: stale)
                            case .failure: done.resume(returning: nil)
                            }
                        })
                    }
                }
            }
            var answered: [StalePushNode] = []
            for await stale in group { if let stale { answered.append(stale) } }
            return answered
        }
        updateStalePushNodes { $0.removeAll { answered.contains($0) } }
        if let current, answered.contains(current) {
            try? database.setSetting(.pushRelay, nil)
            try? database.setSetting(.pushNode, nil)
        }
    }

    static func pushIq(_ action: String, relay: JID, node: String) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.addChild(Element(name: action, attributes: ["xmlns": NS.push, "jid": relay.description, "node": node]))
        return iq
    }
}
