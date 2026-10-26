import Foundation
import GRDB
import Network
@preconcurrency import Martin
@testable import Martin
@testable import YapnestKit

/// Stands in for the connection under a session: keeps every stanza the
/// session writes, and answers its requests from `respond`, so sending,
/// archive queries and room lookups can be driven without a server.
final class FakeWire: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var stanzas: [Stanza] = []
    private var failing = false
    private var responder: (@Sendable (Iq) -> Iq?)?
    private var holding = false
    private var held: [() -> Void] = []
    private var counting: StreamManagementModule?

    /// Everything written so far, requests included.
    var written: [Stanza] { lock.withLock { stanzas } }

    /// The messages written, with the id and body of each.
    var messages: [Martin.Message] { written.compactMap { $0 as? Martin.Message } }

    /// Makes every write that isn't a request fail, as Martin's does when the
    /// stream went away after the write was accepted.
    var failsWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    /// Has `module` count and queue what is written, as Martin's session does for a stream with
    /// stream management, so what the server left unacknowledged can be read back.
    func countsWith(_ module: StreamManagementModule) {
        lock.withLock { counting = module }
    }

    /// Answers a request with a result or error stanza; nil leaves it unanswered.
    func answer(_ responder: @escaping @Sendable (Iq) -> Iq?) {
        lock.withLock { self.responder = responder }
    }

    /// Keeps the replies to pings until `releasePings()`, or forever if the
    /// connection is to die first. A ping is otherwise answered at once, as
    /// the ones a session sends to have the server confirm a stanza.
    var holdsPings: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }

    /// How many pings wait for their reply.
    var heldPings: Int { lock.withLock { held.count } }

    /// Delivers the replies held back.
    func releasePings() {
        let replies = lock.withLock {
            defer { held = [] }
            return held
        }
        for reply in replies { reply() }
    }

    /// Pings written so far.
    var pings: [Iq] {
        written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "ping", xmlns: "urn:xmpp:ping") != nil }
    }

    func write<Failure: Error>(
        _ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?,
    ) {
        let (responder, holds) = lock.withLock {
            stanzas.append(iq)
            return (self.responder, holding)
        }
        let isPing = iq.firstChild(name: "ping", xmlns: "urn:xmpp:ping") != nil
        guard let response = responder?(iq) ?? (isPing ? FakeWire.result(to: iq) : nil), let completionHandler else { return }
        let reply: () -> Void = {
            if response.type == .error, let failure = errorDecoder(response) as? Failure {
                completionHandler(.failure(failure))
            } else {
                completionHandler(.success(response))
            }
        }
        if isPing && holds {
            lock.withLock { held.append(reply) }
        } else {
            reply()
        }
    }

    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {
        let (fails, module) = lock.withLock {
            stanzas.append(stanza)
            return (failing, counting)
        }
        if !fails { module?.processOutgoing(stanza: stanza) }
        writeCompleted?(fails ? .failure(.undefined_condition) : .success(()))
    }

    /// A result for `request`, carrying `children`.
    static func result(to request: Iq, _ children: Element...) -> Iq {
        let iq = Iq()
        iq.type = .result
        iq.id = request.id
        iq.from = request.to
        for child in children { iq.addChild(child) }
        return iq
    }

    /// An error for `request`.
    static func error(to request: Iq, condition: String = "item-not-found", type: String = "cancel") -> Iq {
        let iq = Iq()
        iq.type = .error
        iq.id = request.id
        iq.from = request.to
        let error = Element(name: "error", attributes: ["type": type])
        error.addChild(Element(name: condition, xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        iq.addChild(error)
        return iq
    }

    /// A disco#info result naming one identity.
    static func discoInfo(to request: Iq, category: String, type: String, features: [String] = []) -> Iq {
        let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        query.addChild(Element(name: "identity", attributes: ["category": category, "type": type, "name": "x"]))
        for feature in features { query.addChild(Element(name: "feature", attributes: ["var": feature])) }
        return result(to: request, query)
    }
}

extension XMPPSession {
    /// Makes the session think it is connected and done catching up, writing
    /// to `wire`. Nothing real is involved: there is no socket.
    func connectForTesting(_ wire: FakeWire, syncing: Bool = false) {
        client.writer = wire
        client.update(state: .connected())
        lock.withLock { $0.isSyncing = syncing }
        state.send(.connected(isSyncing: syncing))
    }

    /// Waits for what `peer`'s send queue has taken up so far to be written.
    func drainSendQueue(_ peer: YapnestKit.JID) {
        sendQueue(for: peer).sync {}
    }

    /// Makes the stream acknowledge what it writes, so a written message stays
    /// pending until the server's acknowledgement, as on a real stream.
    func enableAcknowledgementsForTesting() {
        client.module(.streamManagement).processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
    }
}

func parseStanza<T: Stanza>(_ xml: String) -> T {
    Stanza.from(element: Element.from(string: xml)!) as! T
}

/// The fields of a data form, by name.
func formFields(of form: Element?) -> [String: [String]] {
    let fields = form.flatMap(XDataForm.init)?.fields ?? []
    return Dictionary(fields.compactMap { field in field.name.map { ($0, field.values) } }, uniquingKeysWith: { _, last in last })
}

/// A synced setting from another device, newer than anything the tests hold.
func settingsEntry(_ key: String, _ value: String?, by: String = "other") -> SettingsEntry {
    let ms = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    return SettingsEntry(key: key, value: value, version: SettingsVersion(ms: ms, counter: 0), by: by)
}

func settingsItem(_ entries: SettingsEntry...) -> Element { SettingsItem(entries: entries).element }

/// The notification that a settings item was published.
func settingsEvent(from sender: String?, id: String = "global", _ payload: Element) -> Martin.Message {
    let message = Martin.Message()
    message.type = .headline
    if let sender { message.from = Martin.JID(sender) }
    let item = Element(name: "item", attributes: ["id": id])
    item.addChild(payload)
    let items = Element(name: "items", attributes: ["node": NS.settings])
    items.addChild(item)
    message.addChild(Element(name: "event", xmlns: "http://jabber.org/protocol/pubsub#event", children: [items]))
    return message
}

/// Starts the listener and answers with the port it got.
func startListening(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
    final class Once: @unchecked Sendable {
        let lock = NSLock()
        var done = false
    }
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { [listener] state in
            let result: Result<UInt16, Error>
            switch state {
            case .ready: result = .success(listener.port?.rawValue ?? 0)
            case .failed(let error): result = .failure(error)
            default: return
            }
            once.lock.lock(); defer { once.lock.unlock() }
            guard !once.done else { return }
            once.done = true
            continuation.resume(with: result)
        }
        listener.start(queue: queue)
    }
}

/// Makes storing any message fail, as a full disk would.
func failStoringMessages(_ database: AppDatabase) throws {
    try database.writer.write {
        try $0.execute(sql: "CREATE TRIGGER failInsert BEFORE INSERT ON message BEGIN SELECT RAISE(ABORT, 'disk full'); END")
    }
}

func allowStoringMessages(_ database: AppDatabase) throws {
    try database.writer.write { try $0.execute(sql: "DROP TRIGGER failInsert") }
}

final class OSAllocatedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// The number of calls before this one.
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}
