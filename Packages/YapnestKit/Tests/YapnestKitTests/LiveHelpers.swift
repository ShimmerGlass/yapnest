import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Skips the test unless the account's server advertises one of `features`
    /// (service discovery on the account, where Prosody lists the archive and
    /// stanza-id, for one). A server that lacks what a test is about can't
    /// pass it; one that has it still has to.
    static func require(_ features: String..., of session: XMPPSession, _ reason: String) async throws {
        if try await session.advertises(features) { return }
        try Test.cancel("\(target.name) doesn't advertise \(features.joined(separator: " or ")): \(reason)")
    }
}

extension LiveServer {
    /// Skips the test unless the server has an HTTP File Upload service (XEP-0363).
    static func requireUpload(of session: XMPPSession) async throws {
        if try await session.advertisesUpload() { return }
        try Test.cancel("\(target.name) has no HTTP File Upload service (urn:xmpp:http:upload:0)")
    }
}

extension XMPPSession {
    /// Whether one of the server's services offers HTTP File Upload.
    func advertisesUpload() async throws -> Bool {
        let disco = client.module(.disco)
        for item in try await disco.items(for: Martin.JID(account.domain)).items {
            if let info = try? await disco.info(for: item.jid, node: nil), info.features.contains("urn:xmpp:http:upload:0") { return true }
        }
        return false
    }

    /// Whether the account's server lists any of `features` for the account.
    func advertises(_ features: [String]) async throws -> Bool {
        let info = try await client.module(.disco).info(for: Martin.JID(account.martin), node: nil)
        return features.contains(where: info.features.contains)
    }

    /// Whether the server answers a disco query for `jid`, which for a room
    /// means it exists: asking about one that doesn't gets item-not-found.
    func existsOnServer(_ jid: YapnestKit.JID) async -> Bool {
        (try? await client.module(.disco).info(for: Martin.JID(jid.martin), node: nil)) != nil
    }
}

extension XMPPSession {
    /// Turns off the room's archive, as a room that keeps none is. The
    /// session must own the room. Returns whether it had to turn off the
    /// room's logging, which is all Openfire has for an archive.
    @discardableResult
    func disableArchive(of room: YapnestKit.JID) async throws -> Bool {
        // Prosody, ejabberd and Openfire name the option differently; the form says which exists.
        let get = Iq()
        get.type = .get
        get.to = Martin.JID(room.martin)
        get.addChild(Element(name: "query", xmlns: NS.mucOwner))
        let response = try await client.context.writer.write(iq: get)
        let form = response.firstChild(name: "query", xmlns: NS.mucOwner)?.firstChild(name: "x", xmlns: "jabber:x:data")
        let offered = Set(form?.filterChildren(name: "field", xmlns: nil).compactMap { $0.getAttribute("var") } ?? [])
        var fields = ["muc#roomconfig_enablearchiving": ["0"], "mam": ["0"]].filter { offered.contains($0.key) }
        // Openfire's archive is its room logging; elsewhere that is a log file.
        let usedLogging = fields.isEmpty && offered.contains("muc#roomconfig_enablelogging")
        if usedLogging { fields = ["muc#roomconfig_enablelogging": ["0"]] }
        try #require(!fields.isEmpty, "the server offers no archive option")
        let set = Iq()
        set.type = .set
        set.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucOwner)
        query.addChild(Self.dataForm(type: "submit", formType: "http://jabber.org/protocol/muc#roomconfig", fields: fields))
        set.addChild(query)
        _ = try await client.context.writer.write(iq: set)
        return usedLogging
    }

    /// Whether the room's disco info offers an archive.
    func roomOffersArchive(_ room: YapnestKit.JID) async throws -> Bool {
        let info = try await client.module(.disco).info(for: Martin.JID(room.martin), node: nil)
        return info.features.contains("urn:xmpp:mam:2")
    }
}
