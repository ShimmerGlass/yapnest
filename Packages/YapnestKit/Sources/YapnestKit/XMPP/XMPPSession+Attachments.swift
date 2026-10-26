import Foundation
import os
@preconcurrency import Martin

/// The server's XEP-0363 upload service.
struct UploadService: Sendable {
    var jid: Martin.JID
    var maxSize: Int?
}

extension XMPPSession {
    /// For every upload and download: no cookies and no cache, so a file host
    /// can't tie one fetch to the next, and no plaintext file is kept by the
    /// system. Redirects are still checked by `DownloadPolicy`.
    static let transferSession = URLSession.privateEphemeral()

    /// Files larger than this are never downloaded.
    static let maxDownloadSize: Int64 = 200 * 1024 * 1024
    /// Images from contacts download on their own up to this size.
    static let autoDownloadSize: Int64 = 15 * 1024 * 1024

    /// A sweep for missed images looks back this far (7 days)...
    static let sweepAge: TimeInterval = 7 * 24 * 60 * 60
    /// ...and starts at most this many downloads.
    static let sweepLimit = 50

    public enum AttachmentError: Error, LocalizedError {
        case unreadable
        case noUploadService
        /// `max` is what the server said it takes, if it did.
        case tooLarge(max: Int?)
        case uploadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The file couldn't be read.")
            case .noUploadService: String(localized: "Your server doesn't support sending files.")
            case .tooLarge(let max?):
                String(localized: "The file is too large. Your server accepts up to \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file)).")
            case .tooLarge(nil): String(localized: "The file is too large for your server.")
            case .uploadFailed(let reason): String(localized: "Upload failed: \(reason)")
            }
        }
    }

    /// Stores a file and sends it once uploaded. Photos are scaled down and
    /// stripped of metadata, unless animated; other files go as they are.
    @discardableResult
    public func sendFile(at fileURL: URL, name: String? = nil, asPhoto: Bool = false, to peer: JID) async throws -> Message {
        let outgoing = outgoingMessages
        let file = try await outgoing.prepareFile(at: fileURL, name: name, asPhoto: asPhoto)
        let stored: Message
        do {
            stored = try outgoing.stage([.file(file)], to: peer)[0]
        } catch {
            outgoing.discard([file])
            throw error
        }
        donateSuggestion(for: peer)
        transmit(stored, to: peer)
        return stored
    }

    /// Uploads the file, then sends the message with its URL.
    func upload(_ message: Message, _ attachment: Attachment, to peer: JID) {
        guard let messageId = message.id, let id = message.remoteId, beginTransfer(messageId) else { return }
        let transferId = Redacted.id(id)
        Task.detached { [self] in
            defer { endTransfer(messageId) }
            var phase = UploadPhase.prepare
            var started = Date()
            do {
                guard let file = attachments.url(for: attachment), (try? file.checkResourceIsReachable()) == true else {
                    throw AttachmentError.unreadable
                }
                phase = .service
                let service = try await retryingPassingErrors { try await uploadService() }
                // Refused before it is read: a file the server can't take
                // may be too big to hold in memory.
                if let max = service.maxSize, file.fileSize > Int64(max) { throw AttachmentError.tooLarge(max: max) }
                // Plain files go up from where they are stored. Encrypted ones
                // are sealed into a file of ours, which is uploaded from disk;
                // sealing itself holds the file and its ciphertext in memory
                // at once. It's in the system's temporary folder, not the
                // attachments', whose partial files a reconnect sweeps.
                var source = file
                var fragment: String?
                var temporary: URL?
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                if message.encryption == .omemo {
                    let sealed = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                    temporary = sealed
                    fragment = try FileCrypto.encrypt(fileAt: file, to: sealed)
                    source = sealed
                }
                let size = Int(source.fileSize)
                // Encryption adds to the size.
                if let max = service.maxSize, size > max { throw AttachmentError.tooLarge(max: max) }
                // An encrypted file is opaque bytes under a random name, so the
                // upload server, which sees the slot request and often puts the
                // name in the URL, learns no more than its extension.
                let contentType = fragment == nil ? attachment.mimeType ?? "application/octet-stream" : "application/octet-stream"
                let slotName = fragment == nil ? attachment.name : AttachmentStore.freshName(keeping: attachment.name)
                // A slot and the PUT go again together while what failed may pass:
                // a slot is only good for the file it was asked for, once.
                let slot = try await retryingPassingErrors {
                    phase = .slot
                    started = Date()
                    let slot = try await requestUploadSlot(from: service, filename: slotName, size: size, contentType: contentType)
                    DiagLog.info(.upload, "Upload slot granted", .id("msg", transferId), .size("bytes", size), .duration("took", since: started))
                    phase = .put
                    started = Date()

                    var request = URLRequest(url: slot.putURL)
                    request.httpMethod = "PUT"
                    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                    for (header, value) in slot.putHeaders { request.setValue(value, forHTTPHeaderField: header) }
                    let delegate = ProgressDelegate(policy: DownloadPolicy(allowsInsecure: allowsInsecureTransfers)) { [weak self] progress in self?.setProgress(progress, for: messageId) }
                    let (_, response) = try await Self.transferSession.upload(for: request, fromFile: source, delegate: delegate)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    DiagLog.info(.upload, "Upload finished", .id("msg", transferId), .int("status", status), .size("bytes", size), .duration("took", since: started))
                    guard (200..<300).contains(status) else {
                        // A host that won't take this file at all may be told so by 413.
                        if status == 413 { throw AttachmentError.tooLarge(max: service.maxSize) }
                        let failure = ServerError.http(status: status)
                        throw failure.isPassing ? failure : AttachmentError.uploadFailed(HTTPURLResponse.localizedString(forStatusCode: status))
                    }
                    return slot
                }

                let url = fragment.flatMap { FileCrypto.aesgcmURL(for: slot.getURL, fragment: $0) } ?? slot.getURL
                phase = .store
                guard let uploaded = try database.setUploaded(messageId: messageId, url: url.absoluteString) else { return }
                transmit(uploaded, to: peer)
            } catch {
                // A server that can't take the file may not be the only way to get it there.
                if await sendOverJingleInstead(after: error, message, attachment, to: peer) {
                    DiagLog.notice(.upload, "Upload handed to Jingle", .id("msg", transferId), .value("phase", phase), .error(error), .duration("took", since: started))
                    return
                }
                // Offline: the upload is retried when the connection is back, by the resend after a resume or a catch-up.
                guard isConnected else {
                    DiagLog.notice(.upload, "Upload deferred, offline", .id("msg", transferId), .value("phase", phase), .error(error), .duration("took", since: started))
                    return
                }
                DiagLog.error(.upload, "Upload failed", .id("msg", transferId), .value("phase", phase), .error(error), .duration("took", since: started), .bool("connected", true))
                // The server's reason, whether it was the slot's or the file host's.
                let reason = ServerError(error).map { $0.describe(String(localized: "Upload failed")) }
                    ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? database.markFailed(conversationId: message.conversationId, remoteId: id, error: reason)
            }
        }
    }

    /// Asks the upload service for a slot (XEP-0363). A file-too-large answer
    /// becomes `tooLarge`, which hands the file to Jingle where that works. A
    /// `retry` stamp is waited for once, up to a minute; without one, or
    /// after, the error is the server's, for the caller to retry if it passes.
    private func requestUploadSlot(from service: UploadService, filename: String, size: Int, contentType: String) async throws -> UploadSlot {
        var waited = false
        while true {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    client.module(.httpFileUpload).requestUploadSlot(
                        componentJid: service.jid, filename: filename, size: size, contentType: contentType,
                        errorDecoder: UploadSlotParser.error(from:),
                        completionHandler: { (result: Result<Iq, Error>) in
                            continuation.resume(with: result.flatMap { iq in
                                UploadSlotParser.slot(from: iq).map { .success($0) } ?? .failure(ServerError(condition: "undefined-condition"))
                            })
                        },
                    )
                }
            } catch let refusal as UploadSlotError {
                if refusal.isFileTooLarge { throw AttachmentError.tooLarge(max: refusal.maxFileSize ?? service.maxSize) }
                if let retryAt = refusal.retryAt, !waited {
                    waited = true
                    let delay = min(max(retryAt.timeIntervalSinceNow, 0), 60)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    continue
                }
                throw refusal.error
            }
        }
    }

    private func uploadService() async throws -> UploadService {
        if let service = lock.withLock({ $0.uploadService }) { return service }
        let components = try await client.module(.httpFileUpload).findHttpUploadComponents()
        guard let component = components.first else { throw AttachmentError.noUploadService }
        let service = UploadService(jid: component.jid, maxSize: component.maxSize > 0 ? component.maxSize : nil)
        lock.withLock { $0.uploadService = service }
        return service
    }

    /// Downloads (and decrypts) a received file, or accepts a contact's offer
    /// of one that has not been taken yet.
    public func download(_ attachment: Attachment) {
        // A contact's Jingle offer has no link to fetch: this takes it.
        if attachment.state == .offered, attachment.url == nil {
            acceptFileOffer(attachment)
            return
        }
        download(attachment, limit: Self.maxDownloadSize)
    }

    /// Whether a picture from someone in a private group we haven't added
    /// downloads by itself. Off, only the group's members in the roster do;
    /// the rest show tap-to-download.
    public var downloadsFromGroupMembers: Bool { database.flag(.downloadsFromGroupMembers, default: true) }

    /// Whether we fetch a received image without being asked, which reveals
    /// our IP address to the sender's upload server: ours, in a private group
    /// (or a private message from a room), or from someone in the roster.
    /// `isOutgoing` is `Message.isTrustedOutgoing`, which in a group doesn't
    /// take a room's word that a message is ours. `isInRoster` is for the 1:1
    /// peer, or for the real address of a group message's sender.
    static func trustsForAutoDownload(isOutgoing: Bool, isPrivateGroup: Bool = false, isInRoster: @autoclosure () -> Bool) -> Bool {
        isOutgoing || isPrivateGroup || isInRoster()
    }

    /// Downloads the recent images that should have come on their own but
    /// didn't: the notification extension stored them first, a download
    /// failed, or we were offline. At most `Self.sweepLimit` per sweep, from
    /// the last `Self.sweepAge`. `peer` limits it to one conversation.
    public func downloadMissedImages(in peer: JID? = nil) {
        guard policy.fetchesImages else { return }
        Task.detached(priority: .utility) { [self] in
            let found = try? database.missedImages(
                since: Date().addingTimeInterval(-Self.sweepAge), limit: Self.sweepLimit, maxSize: Self.autoDownloadSize, peer: peer,
            )
            for attachment in found ?? [] { autoDownload(attachment) }
        }
    }

    /// Fetches a received image (what's shown inline) right away. Callers
    /// decide whose: fetching reveals our IP address to the sender's server.
    func autoDownload(_ attachment: Attachment) {
        // The notification extension has neither the time nor the memory.
        guard attachment.isImage, policy.fetchesImages else { return }
        download(attachment, limit: Self.autoDownloadSize)
    }

    private func download(_ attachment: Attachment, limit: Int64) {
        let messageId = attachment.messageId
        guard let string = attachment.url, let url = URL(string: string), beginTransfer(messageId) else { return }
        let transferId = Redacted.id(string)
        Task.detached { [self] in
            defer { endTransfer(messageId) }
            let started = Date()
            var delegate: ProgressDelegate?
            do {
                var source = url
                var fragment: String?
                if let (https, key) = FileCrypto.split(url, insecure: allowsInsecureTransfers) {
                    source = https
                    fragment = key
                }
                guard ["https", "http"].contains(source.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
                let policy = DownloadPolicy(allowsInsecure: allowsInsecureTransfers)
                try await policy.check(source)

                let progress = ProgressDelegate(limit: limit, policy: policy) { [weak self] progress in self?.setProgress(progress, for: messageId) }
                delegate = progress
                let (file, response) = try await Self.transferSession.download(from: source, delegate: progress)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                var data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count <= limit else { throw TooLarge(size: Int64(data.count)) }
                if let fragment { data = try FileCrypto.decrypt(data, fragment: fragment) }

                let localFile = try attachments.save(data, name: attachment.name)
                let mimeType = fragment == nil ? http.mimeType : nil
                let stored = attachments.directory.appending(path: localFile)
                let size = await AttachmentStore.displaySize(of: data, savedAs: stored, name: attachment.name)
                let duration = attachment.isAudio ? AudioWaveform.duration(of: stored) : nil
                try database.setDownloaded(
                    messageId: messageId, localFile: localFile, size: Int64(data.count),
                    mimeType: mimeType, width: size?.width, height: size?.height, duration: duration,
                )
                DiagLog.info(.receive, "Download finished", .id("file", transferId), .int("status", http.statusCode), .size("bytes", data.count), .duration("took", since: started))
            } catch {
                // Over the limit isn't a failure; a tap can still fetch it.
                if let size = (error as? TooLarge)?.size ?? delegate?.exceededSize {
                    try? database.setTooLarge(messageId: messageId, size: size > 0 ? size : nil)
                    return
                }
                DiagLog.error(.receive, "Download failed", .id("file", transferId), .error(error), .duration("took", since: started))
                try? database.setAttachmentState(.downloadFailed, messageId: messageId)
            }
        }
    }

    // MARK: Progress

    func beginTransfer(_ messageId: Int64) -> Bool {
        publish(transfers, under: transfersPublishLock) { state in
            guard state.transferProgress[messageId] == nil else { return (false, nil) }
            state.transferProgress[messageId] = 0
            return (true, state.transferProgress)
        }
    }

    func endTransfer(_ messageId: Int64) {
        publish(transfers, under: transfersPublishLock) { state in
            state.transferProgress[messageId] = nil
            return ((), state.transferProgress)
        }
    }

    func setProgress(_ progress: Double, for messageId: Int64) {
        publish(transfers, under: transfersPublishLock) { state in
            guard state.transferProgress[messageId] != nil else { return ((), nil) }
            state.transferProgress[messageId] = progress
            return ((), state.transferProgress)
        }
    }
}

private struct TooLarge: Error {
    var size: Int64
}

/// Reports a transfer's progress, and cancels downloads that turn out too big.
final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, Sendable {
    private let limit: Int64?
    private let policy: DownloadPolicy
    private let report: @Sendable (Double) -> Void
    private let exceeded = OSAllocatedUnfairLock<Int64?>(initialState: nil)

    /// Set once a download was cancelled for being over the limit: its size
    /// if the server said, else 0.
    var exceededSize: Int64? { exceeded.withLock { $0 } }

    init(limit: Int64? = nil, policy: DownloadPolicy, report: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.policy = policy
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let limit, totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            exceeded.withLock { $0 = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0 }
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// A redirect is a new request to wherever the server says, so it gets the
    /// same checks as the first.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, (try? await policy.check(url)) != nil else { return nil }
        return request
    }

    // The async download API hands over the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
