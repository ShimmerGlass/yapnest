import CryptoKit
import Foundation
@preconcurrency import Martin
import os

private let transferLogger = Logger(subsystem: "Yapnest", category: "FileTransfer")

/// Files between two clients over Jingle (XEP-0234) and in-band bytestreams
/// (XEP-0261, XEP-0047), for when the server's upload can't take a file.
/// Offers only: the sender decides to send, and a receiver takes or declines.
/// 1:1 chats, unencrypted, and only in the app's own session: the extensions
/// don't register any of this.
///
/// `FileTransferSession` is the state of each; this is what answers stanzas
/// and does the writes, always outside its lock. Nothing survives a restart.
extension XMPPSession {
    /// Blocks sent without waiting for an acknowledgement.
    static let fileTransferWindow = 8

    // MARK: Modules

    func registerFileTransfer(on jingle: CallJingleModule) {
        jingle.fileTransfer = { [weak self] iq, element in
            try self?.fileTransferIq(iq, element) ?? false
        }
        let ibb = IBBModule()
        ibb.handler = { [weak self] from, event in
            guard let self else { throw XMPPError.item_not_found }
            return try self.ibbEvent(event, from: from)
        }
        client.modulesManager.register(ibb)
    }

    // MARK: Jingle stanzas

    private func write(_ iq: Iq, completion: ((Result<Iq, XMPPError>) -> Void)? = nil) {
        client.context.writer.write(iq, completionHandler: completion)
    }

    private func reply(to iq: Iq) {
        client.context.writer.write(iq.makeResult(type: .result))
    }

    private func terminate(_ ft: FileTransferSession, _ reason: JingleSessionTerminateReason) {
        write(JingleFileOffer.sessionTerminate(to: ft.peer, sid: ft.sid, reason: reason))
    }

    /// Takes the iq if it is a file transfer's; false if it is not. See
    /// `CallJingleModule.fileTransfer`.
    func fileTransferIq(_ iq: Iq, _ jingle: Element) throws -> Bool {
        guard let from = iq.from, let sid = jingle.getAttribute("sid") else { return false }
        let action = jingle.getAttribute("action")
        if action == "session-initiate", JingleFileOffer.isFileOffer(jingle) {
            try fileOfferReceived(iq, jingle, from: from, sid: sid)
            return true
        }
        guard let ft = fileTransfers.session(sid: sid) else { return false }
        // Only the peer we are in a session with can say anything about it.
        guard from == ft.peer else { throw XMPPError.item_not_found }
        switch action {
        case "session-accept":
            try fileOfferAccepted(ft, jingle)
            reply(to: iq)
        case "session-info":
            // A hash can follow the offer, and a `received` needs nothing.
            if ft.role == .receiver, let hash = JingleFileOffer.checksum(in: jingle) { ft.setExpectedHash(hash) }
            reply(to: iq)
        case "session-terminate":
            reply(to: iq)
            fileTransferTerminated(ft, reason: JingleFileOffer.reason(in: jingle))
        case "transport-info":
            // In-band bytestreams have nothing to add after the offer.
            reply(to: iq)
        case "session-initiate":
            throw XMPPError.unexpected_request("Known session")
        default:
            throw XMPPError.feature_not_implemented
        }
        return true
    }

    /// Offers can't outlive the session that took them, so those left from
    /// an earlier launch ended with it, and so did the files they were writing.
    /// Run when the session starts connecting, before any offer can arrive.
    func expireFileOffers() {
        fileTransfers.queue.async { [database, attachments] in
            try? database.expireFileOffers()
            attachments.removePartialFiles()
        }
    }

    // MARK: Receiving an offer

    private func fileOfferReceived(_ iq: Iq, _ jingle: Element, from: Martin.JID, sid: String) throws {
        guard fileTransfers.session(sid: sid) == nil else { throw XMPPError.unexpected_request("Known session") }
        /// Answers the iq, then ends the session we won't have.
        func turnDown(_ reason: JingleSessionTerminateReason) {
            reply(to: iq)
            write(JingleFileOffer.sessionTerminate(to: from, sid: sid, reason: reason))
        }
        // Files come from the people we know, from a device (a session has
        // to be answered somewhere), and not from our own account's other
        // devices or a room's occupants.
        guard from.resource != nil, let peer = JID(from.bareJid.stringValue), peer != account, !isGroup(peer),
              (try? database.contact(peer))?.isInRoster == true else {
            turnDown(.decline)
            return
        }
        let offer: JingleFileOffer
        switch JingleFileOffer.parse(jingle) {
        case .failure(let rejection):
            turnDown(rejection.reason)
            return
        case .success(let parsed):
            offer = parsed
        }
        let stored: Message?
        do {
            stored = try database.insertFileOffer(from: peer, sid: sid, offer: offer)
        } catch {
            transferLogger.error("Couldn't store file offer \(sid, privacy: .public): \(error, privacy: .public)")
            turnDown(.failedApplication)
            return
        }
        // Stored before for this sender: a repeat.
        guard let message = stored, let messageId = message.id else { throw XMPPError.unexpected_request("Known session") }
        let ft = FileTransferSession(sid: sid, messageId: messageId, role: .receiver, peer: from, offer: offer)
        guard fileTransfers.add(ft) else { throw XMPPError.unexpected_request("Known session") }
        reply(to: iq)
        events.send(.newMessage(message))
        if offer.size <= autoAcceptedOfferSize { accept(ft) }
    }

    /// Accepts the offer of `attachment`, a row waiting for that. If the
    /// session is gone, the offer is over.
    func acceptFileOffer(_ attachment: Attachment) {
        guard let ft = fileTransfers.session(messageId: attachment.messageId), ft.role == .receiver else {
            try? database.setOfferUnavailable(messageId: attachment.messageId)
            return
        }
        accept(ft)
    }

    /// Turns down the offer of `attachment`, or cancels it if it is coming in.
    public func declineOffer(_ attachment: Attachment) {
        guard attachment.state == .offered, attachment.url == nil else { return }
        guard let ft = fileTransfers.session(messageId: attachment.messageId), ft.role == .receiver else {
            try? database.setOfferUnavailable(messageId: attachment.messageId)
            return
        }
        let phase = ft.currentPhase
        failTransfer(ft, .declined, tell: phase == .offered ? .decline : .cancel)
    }

    private func accept(_ ft: FileTransferSession) {
        guard ft.move(from: [.offered], to: .accepted) else { return }
        do {
            try ft.startReceiving(into: try attachments.temporaryFile(), blockSize: ft.offer.blockSize)
        } catch {
            transferLogger.error("Couldn't start receiving \(ft.sid, privacy: .public): \(error, privacy: .public)")
            failTransfer(ft, .failed, tell: .failedApplication)
            return
        }
        _ = beginTransfer(ft.messageId)
        fileTransfers.routeIBB(to: ft)
        let responder = client.context.boundJid ?? Martin.JID(account.description)
        write(ft.offer.sessionAccept(to: ft.peer, sid: ft.sid, responder: responder)) { [weak self] result in
            guard let self, case .failure = result else { return }
            self.failTransfer(ft, .failed, tell: .failedTransport)
        }
        watch(ft, fileTransfers.timeouts.idle, .failed, tell: .timeout)
    }

    /// Ends the transfer if nothing happens for `limit`.
    private func watch(_ ft: FileTransferSession, _ limit: TimeInterval, _ failure: FileTransferFailure, tell reason: JingleSessionTerminateReason) {
        ft.watch(limit, on: fileTransfers.queue) { [weak self] in
            self?.failTransfer(ft, failure, tell: reason)
        }
    }

    // MARK: In-band bytestream

    func ibbEvent(_ event: IBBEvent, from: Martin.JID) throws -> (() -> Void)? {
        guard let ft = fileTransfers.session(ibb: event.sid), ft.role == .receiver, ft.peer == from else {
            throw XMPPError.item_not_found
        }
        switch event {
        case .open(_, let blockSize):
            guard ft.opened(blockSize: blockSize) else { throw XMPPError.not_acceptable("Unexpected or larger block size") }
            watch(ft, fileTransfers.timeouts.idle, .failed, tell: .timeout)
            return nil
        case .data(_, let seq, let bytes):
            switch ft.append(seq: seq, bytes) {
            case .accepted(let progress, let isComplete):
                if let progress { setProgress(progress, for: ft.messageId) }
                return isComplete ? { [weak self] in self?.finishReceiving(ft) } : nil
            case .broken:
                failTransfer(ft, .failed, tell: .failedTransport)
                throw XMPPError.unexpected_request("Block out of order or too large")
            case .unexpected:
                throw XMPPError.item_not_found
            }
        case .close:
            switch ft.currentPhase {
            case .receiving: return { [weak self] in self?.finishReceiving(ft) }
            // The last block already completed it.
            case .completed: return nil
            default: throw XMPPError.item_not_found
            }
        }
    }

    /// The stream ended: the file is whole and right, or the session fails.
    private func finishReceiving(_ ft: FileTransferSession) {
        guard ft.currentPhase == .receiving else { return }
        guard case .file(let partial, let size) = ft.finishReceiving() else {
            failTransfer(ft, .failed, tell: .mediaError)
            return
        }
        let localFile: String
        do {
            localFile = try attachments.adopt(partial, name: ft.offer.name)
        } catch {
            transferLogger.error("Couldn't keep received file \(ft.sid, privacy: .public): \(error, privacy: .public)")
            failTransfer(ft, .failed, tell: .failedApplication)
            return
        }
        guard ft.move(from: [.receiving], to: .completed) else {
            try? FileManager.default.removeItem(at: attachments.directory.appending(path: localFile))
            return
        }
        ft.disarm()
        terminate(ft, .success)
        endTransfer(ft.messageId)
        scheduleRemoval(ft)
        let messageId = ft.messageId, name = ft.offer.name, mimeType = ft.offer.mediaType
        Task.detached { [self] in
            let dimensions = await AttachmentStore.displaySize(ofFileAt: attachments.directory.appending(path: localFile), name: name)
            do {
                try database.setDownloaded(
                    messageId: messageId, localFile: localFile, size: size, mimeType: mimeType,
                    width: dimensions?.width, height: dimensions?.height,
                )
            } catch {
                transferLogger.error("Couldn't record received file for message \(messageId): \(error, privacy: .public)")
                try? database.setAttachmentState(.unavailable, messageId: messageId)
            }
        }
    }

    // MARK: Ending

    /// Ends a session that didn't succeed. `reason` is what the peer is told;
    /// nil if it ended the session itself, or the connection is gone.
    func failTransfer(_ ft: FileTransferSession, _ failure: FileTransferFailure, tell reason: JingleSessionTerminateReason?) {
        guard let previous = ft.fail() else { return }
        ft.disarm()
        if let reason, isConnected {
            // A stream we were receiving is the sender's to stop.
            if previous == .receiving { write(IBBModule.close(to: ft.peer, sid: ft.ibbSid)) }
            terminate(ft, reason)
        }
        switch ft.role {
        case .receiver:
            ft.discardReceived()
            try? database.setOfferUnavailable(messageId: ft.messageId)
            endTransfer(ft.messageId)
        case .sender:
            // The upload that is waiting for it ends its transfer.
            ft.complete(.failure(failure))
        }
        scheduleRemoval(ft)
    }

    /// A disconnect ends every session: stanzas of this stream won't be answered.
    func failFileTransfers() {
        for ft in fileTransfers.all { failTransfer(ft, .interrupted, tell: nil) }
    }

    private func scheduleRemoval(_ ft: FileTransferSession) {
        fileTransfers.queue.asyncAfter(deadline: .now() + fileTransfers.timeouts.linger) { [fileTransfers] in
            fileTransfers.remove(ft)
        }
    }

    private func fileTransferTerminated(_ ft: FileTransferSession, reason: JingleSessionTerminateReason?) {
        switch ft.role {
        case .receiver:
            failTransfer(ft, .from(reason), tell: nil)
        case .sender:
            let done = reason == .success
                && (ft.move(from: [.awaitingConfirmation], to: .completed) || (ft.hasSentEverything && ft.move(from: [.sending], to: .completed)))
            guard done else {
                failTransfer(ft, .from(reason), tell: nil)
                return
            }
            ft.disarm()
            ft.release()
            ft.complete(.success(()))
            scheduleRemoval(ft)
        }
    }

    // MARK: Sending

    /// A device of `peer` that can take a file this way: one that advertises
    /// every feature, preferring the most available.
    func fileTransferDevice(of peer: JID) -> Martin.JID? {
        guard let caps = client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER) else { return nil }
        var devices: Set<Martin.JID>?
        for feature in JingleFile.requiredFeatures {
            switch caps.isFeatureSupported(feature, by: peer.martin) {
            case .none: return nil
            case .all: continue
            case .some(let jids): devices = devices.map { $0.intersection(jids) } ?? Set(jids)
            }
        }
        let resources = lock.withLock { $0.resources[peer] } ?? [:]
        let candidates = devices ?? Set(resources.keys.map { Martin.JID(peer.martin, resource: $0) })
        return candidates.max { lhs, rhs in
            let a = lhs.resource.flatMap { resources[$0] }, b = rhs.resource.flatMap { resources[$0] }
            return (a?.availability ?? .offline, a?.order ?? -1) < (b?.availability ?? .offline, b?.order ?? -1)
        }
    }

    /// Offers the file of `attachment` to `device` and sends it when it accepts.
    /// Returns once the receiver has confirmed it has the file, and records
    /// that; throws a `FileTransferFailure` otherwise. The caller holds the
    /// message's transfer (`beginTransfer`).
    func sendOverJingle(_ message: Message, _ attachment: Attachment, to device: Martin.JID) async throws {
        guard let messageId = message.id, let file = attachments.url(for: attachment) else { throw AttachmentError.unreadable }
        let (size, hash) = try Self.sizeAndHash(of: file)
        let offer = JingleFileOffer(
            name: attachment.name, mediaType: attachment.mimeType, size: size, date: nil, sha256: hash,
            ibbSid: UUID().uuidString.lowercased(), blockSize: JingleFile.blockSize,
        )
        let sid = UUID().uuidString.lowercased()
        let ft = FileTransferSession(sid: sid, messageId: messageId, role: .sender, peer: device, offer: offer)
        do {
            try ft.startSending(from: file)
        } catch {
            throw AttachmentError.unreadable
        }
        guard fileTransfers.add(ft) else { throw FileTransferFailure.failed }
        let initiator = client.context.boundJid ?? Martin.JID(account.description)
        write(offer.sessionInitiate(to: device, sid: sid, initiator: initiator)) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            // A device that went away, or one that doesn't answer.
            let failure: FileTransferFailure = error == .remote_server_timeout || error == .recipient_unavailable(nil) ? .noAnswer : .failed
            self.failTransfer(ft, failure, tell: nil)
        }
        watch(ft, fileTransfers.timeouts.accept, .noAnswer, tell: .timeout)
        try await ft.finished()
        try database.setFileSentOverJingle(messageId: messageId)
    }

    /// Whether the file goes to the contact over Jingle after the server's
    /// upload failed with `error`, and does it if so: it fails the message
    /// itself with the reason. False if the upload's own failure stands.
    func sendOverJingleInstead(after error: Error, _ message: Message, _ attachment: Attachment, to peer: JID) async -> Bool {
        guard mode == .app, message.encryption == .none, isConnected, !isGroup(peer), let id = message.remoteId, let file = attachments.url(for: attachment), file.fileSize <= JingleFile.maxSize,
              let uploadError = error as? AttachmentError else { return false }
        switch uploadError {
        case .noUploadService, .tooLarge: break
        default: return false
        }
        guard let device = fileTransferDevice(of: peer) else { return false }
        do {
            try await sendOverJingle(message, attachment, to: device)
        } catch {
            transferLogger.error("Jingle transfer of \(id, privacy: .public) failed: \(error, privacy: .public)")
            let reason = (error as? LocalizedError)?.errorDescription ?? FileTransferFailure.failed.message
            try? database.markFailed(conversationId: message.conversationId, remoteId: id, error: reason)
        }
        return true
    }

    private func fileOfferAccepted(_ ft: FileTransferSession, _ jingle: Element) throws {
        guard ft.role == .sender, ft.move(from: [.offering], to: .sending) else { throw XMPPError.unexpected_request("Not waiting for an accept") }
        // The receiver may only lower the block size.
        let transport = jingle.firstChild(name: "content")?.firstChild(name: "transport", xmlns: JingleFile.transport)
        if let size = transport?.getAttribute("block-size").flatMap(Int.init), size > 0 { ft.negotiate(blockSize: size) }
        watch(ft, fileTransfers.timeouts.idle, .failed, tell: .timeout)
        // After the result for the accept has been written.
        fileTransfers.queue.async { [self] in
            write(IBBModule.open(to: ft.peer, sid: ft.ibbSid, blockSize: ft.negotiatedBlockSize)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.fileTransfers.queue.async { self.pump(ft) }
                case .failure: self.failTransfer(ft, .failed, tell: .failedTransport)
                }
            }
        }
    }

    /// Sends blocks while the window has room, and closes the stream after the
    /// last is acknowledged. Runs on the transfers' queue; each acknowledgement
    /// runs it again.
    private func pump(_ ft: FileTransferSession) {
        while true {
            switch ft.nextBlock(window: Self.fileTransferWindow) {
            case .block(let seq, let bytes):
                write(IBBModule.data(to: ft.peer, sid: ft.ibbSid, seq: seq, bytes: bytes)) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        if let progress = ft.acknowledge(bytes.count) { self.setProgress(progress, for: ft.messageId) }
                        self.fileTransfers.queue.async { self.pump(ft) }
                    case .failure:
                        self.failTransfer(ft, .failed, tell: .failedTransport)
                    }
                }
            case .close:
                write(IBBModule.close(to: ft.peer, sid: ft.ibbSid)) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        // The receiver may have said it has everything by now.
                        if ft.move(from: [.sending], to: .awaitingConfirmation) {
                            self.watch(ft, self.fileTransfers.timeouts.confirmation, .unconfirmed, tell: .timeout)
                        }
                    case .failure:
                        self.failTransfer(ft, .failed, tell: .failedTransport)
                    }
                }
                return
            case .nothing:
                return
            case .failed:
                failTransfer(ft, .failed, tell: .failedApplication)
                return
            }
        }
    }

    /// The size and SHA-256 of a file, read in pieces so a large one isn't loaded.
    static func sizeAndHash(of file: URL) throws -> (size: Int64, sha256: Data) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, Data(hasher.finalize()))
    }
}
