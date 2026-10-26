import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

struct AttachmentTests {
    @Test func transfersKeepNoCookiesAndNoCache() {
        let configuration = XMPPSession.transferSession.configuration
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil || configuration.httpCookieAcceptPolicy == .never)
    }

    @Test func fileCryptoEncryptsAFileAsCiphertextThenTag() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = Data((0..<70_000).map { UInt8($0 % 241) })
        let source = folder.appending(path: "plain.bin")
        let sealed = folder.appending(path: "sealed.bin")
        try plain.write(to: source)

        let fragment = try FileCrypto.encrypt(fileAt: source, to: sealed)
        let output = try Data(contentsOf: sealed)
        #expect(output.count == plain.count + 16)
        #expect(fragment.count == 88)
        #expect(try FileCrypto.decrypt(output, fragment: fragment) == plain)
        #expect(output.prefix(plain.count) != plain)

        var tampered = output
        tampered[0] ^= 1
        #expect(throws: FileCrypto.Failure.self) { try FileCrypto.decrypt(tampered, fragment: fragment) }
    }

    @Test func fileCryptoLeavesNothingWhenTheSourceIsMissing() {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sealed = folder.appending(path: "sealed.bin")
        #expect(throws: (any Error).self) { try FileCrypto.encrypt(fileAt: folder.appending(path: "nope"), to: sealed) }
        #expect(!FileManager.default.fileExists(atPath: sealed.path))
    }

    @Test func aesgcmURLs() throws {
        let url = try #require(FileCrypto.aesgcmURL(for: URL(string: "https://up.example/abc/photo.jpg")!, fragment: "00ff"))
        #expect(url.absoluteString == "aesgcm://up.example/abc/photo.jpg#00ff")
        let split = try #require(FileCrypto.split(url))
        #expect(split.download.absoluteString == "https://up.example/abc/photo.jpg")
        #expect(split.fragment == "00ff")
    }

    @Test func recognizesFileMessages() {
        #expect(AttachmentLink.parse(body: "aesgcm://up.example/a/My%20Photo.jpg#abcd", oob: nil)?.name == "My Photo.jpg")
        #expect(AttachmentLink.parse(body: "https://up.example/a/doc.pdf", oob: "https://up.example/a/doc.pdf")?.name == "doc.pdf")
        // A link someone typed is just a link.
        #expect(AttachmentLink.parse(body: "https://up.example/a/doc.pdf", oob: nil) == nil)
        // Plain http only for development servers, which send no certificate.
        let plain = "http://up.example/a/doc.pdf"
        #expect(AttachmentLink.parse(body: plain, oob: plain) == nil)
        #expect(AttachmentLink.parse(body: plain, oob: plain, allowsInsecure: true)?.name == "doc.pdf")
        #expect(AttachmentLink.parse(body: plain, oob: nil, allowsInsecure: true) == nil)
        #expect(AttachmentLink.parse(body: "look aesgcm://up.example/a#ab", oob: nil) == nil)
    }

    @Test func ingestStoresAttachment() throws {
        let db = try AppDatabase.inMemory()
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!
        let url = "https://up.example/x/cat.png"
        let inbound = InboundMessage(
            peer: alice, isOutgoing: false, sender: alice, type: "chat", timestamp: Date(), id: "f1",
            body: url, encryption: .none, oobURL: url,
            requestsReceipt: false, isMarkable: false, isError: false,
        )
        let result = try db.ingest(inbound)
        #expect(result.newAttachment?.name == "cat.png")
        #expect(result.newAttachment?.mimeType == "image/png")
        #expect(result.newMessage?.link == nil)
        let item = try db.reader.read { db in try AppDatabase.conversationItems(db, peer: alice, me: me) }.first
        #expect(item?.attachment?.state == .remote)
        #expect(try db.chatList().first?.lastAttachment?.summary == "📷 Photo")
    }

    @Test func plainHttpUploadsAreFilesOnlyOnDevelopmentServers() throws {
        let alice = JID("alice@example.org")!
        let url = "http://localhost:5280/upload/cat.png"
        func inbound(_ id: String) -> InboundMessage {
            InboundMessage(
                peer: alice, isOutgoing: false, sender: alice, type: "chat", timestamp: Date(), id: id,
                body: url, encryption: .none, oobURL: url,
                requestsReceipt: false, isMarkable: false, isError: false,
            )
        }
        let strict = try AppDatabase.inMemory()
        #expect(try strict.ingest(inbound("h1")).newAttachment == nil)

        let development = try AppDatabase.inMemory()
        development.allowsInsecureLinks = true
        #expect(try development.ingest(inbound("h1")).newAttachment?.name == "cat.png")
        #expect(try development.ingest([inbound("h2")]).first?.newAttachment?.name == "cat.png")
    }

    @Test func roomNicksAreCleanedWhenStored() throws {
        let db = try AppDatabase.inMemory()
        let room = JID("room@conference.example.org")!
        _ = try db.writer.write { db in try AppDatabase.conversation(db, with: room) }
        let inbound = InboundMessage(
            peer: room, isOutgoing: false, sender: JID("room@conference.example.org")!, nick: "\u{202E}Mom\u{200B}", type: "groupchat", timestamp: Date(), id: "g1",
            body: "send me the code", encryption: .none,
            requestsReceipt: false, isMarkable: false, isError: false,
        )
        let result = try db.ingest(inbound)
        #expect(result.newMessage?.nick == "Mom")
    }

    @Test func quotesDescribeFilesNotTheirLinks() throws {
        let key = "aesgcm://up.example/x/cat.png#0123456789abcdef"
        #expect(Attachment.quoteSummary(text: key, attachment: nil) == "📷 Photo")
        #expect(Attachment.quoteSummary(text: "https://up.example/x/clip.mp4", attachment: nil) == "🎬 Video")
        #expect(Attachment.quoteSummary(text: "https://up.example/x/notes.pdf", attachment: nil) == "📎 notes.pdf")
        #expect(Attachment.quoteSummary(text: "https://example.org/about", attachment: nil) == nil)
        #expect(Attachment.quoteSummary(text: "see aesgcm://x/y.png#k", attachment: nil) == nil)
        let stored = Attachment(messageId: 1, url: nil, name: "a.pdf", state: .pendingUpload)
        #expect(Attachment.quoteSummary(text: "", attachment: stored) == "📎 a.pdf")
    }

    @Test func recognizesContacts() {
        func card(mime: String?, name: String = "Jane Appleseed.vcf") -> YapnestKit.Attachment {
            Attachment(messageId: 1, url: nil, name: name, mimeType: mime, state: .ready)
        }
        #expect(card(mime: "text/vcard").isContact)
        #expect(card(mime: "text/x-vcard").isContact)
        #expect(card(mime: nil).isContact)
        #expect(!Attachment(messageId: 1, url: nil, name: "a.pdf", state: .ready).isContact)
        #expect(card(mime: "text/vcard").summary == "👤 Jane Appleseed")
        #expect(card(mime: nil, name: "Dr. Who.vcf").summary == "👤 Dr. Who")
        #expect(Attachment.quoteSummary(text: "https://up.example/x/Jane%20Appleseed.vcf", attachment: nil) == "👤 Jane Appleseed")
    }

    @Test func replyToAFileQuotesItsSummary() throws {
        let db = try AppDatabase.inMemory()
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!
        let id = try db.conversation(with: alice).id!
        let t0 = Date(timeIntervalSince1970: 1_000)
        let url = "aesgcm://up.example/x/cat.png#0123456789abcdef"
        let file = try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: url, timestamp: t0, remoteId: "f1"))
        try db.writer.write { try Attachment(messageId: file.id!, url: url, name: "cat.png", state: .remote).insert($0) }
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "cute", timestamp: t0 + 1, remoteId: "r1", replyToId: "f1", replyToSender: alice))
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "and", timestamp: t0 + 2, remoteId: "r2", replyToId: "gone", replyToSender: alice, replyFallback: url))
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items[1].quote?.text == "📷 Photo")
        #expect(items[2].quote?.text == "📷 Photo")
    }

    @Test func photosLoseMetadataAndShrink() async throws {
        let original = cameraImageData(.jpeg, withLocation: true, width: 4000, height: 3000)
        #expect(cameraDetails(CGImageSourceCreateWithData(original as CFData, nil)!) == [Self.allCameraDetails + ["gps"]])
        let photo = try await withImportedFile(original, name: "IMG_1.heic", asPhoto: true) { stored in
            #expect(cameraDetails(inImageAt: stored) == [[]])
        }
        // Turned a quarter, so it is measured as it is shown.
        #expect((photo.width, photo.height) == (1536, 2048))
        #expect(photo.name == "IMG_1.jpg")
    }

    @Test func importedPortraitVideoIsMeasuredAfterItsRotation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "clip.mov")
        // Recorded 64x32 and turned a quarter, which is how phones store portrait.
        try await writeVideo(to: source, width: 64, height: 32, transform: CGAffineTransform(rotationAngle: .pi / 2))

        let size = try #require(await AttachmentStore.videoSize(of: source))
        #expect((size.width, size.height) == (32, 64))

        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let video = try await store.importFile(at: source, name: "clip.mov", asPhoto: false)
        #expect((video.width, video.height) == (32, 64))
    }

    private func hasLocation(_ url: URL) async throws -> Bool {
        let items = try await AVURLAsset(url: url).load(.metadata)
        return items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 }
    }

    @Test func importedVideoLosesItsLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "clip.mov")
        try await writeVideo(to: source, width: 64, height: 32, transform: .identity, location: "+48.8584+002.2945/")
        #expect(try await hasLocation(source))

        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let video = try await store.importFile(at: source, name: "clip.mov", asPhoto: false)
        let stored = store.directory.appending(path: video.file)
        #expect(try !(await hasLocation(stored)))
        #expect((video.width, video.height) == (64, 32))
        // The user's own file is left as it was.
        #expect(try await hasLocation(source))
    }

    @Test func aPhotoSentAsAFileLosesItsCameraDetailsButKeepsItsOrientation() async throws {
        let data = cameraImageData(.jpeg, withLocation: true)
        let imported = try await withImportedFile(data, name: "IMG_3.jpg") { stored in
            #expect(cameraDetails(inImageAt: stored) == [[]])
            #expect(orientations(inImageAt: stored) == [6])
        }
        #expect(imported.name == "IMG_3.jpg")
        #expect((imported.width, imported.height) == (30, 40))
    }

    @Test func aPhotoWithoutALocationStillLosesItsCameraDetails() async throws {
        let data = cameraImageData(.jpeg, withLocation: false)
        #expect(cameraDetails(CGImageSourceCreateWithData(data as CFData, nil)!) == [Self.allCameraDetails])
        try await withImportedFile(data, name: "IMG_4.jpg") { stored in
            #expect(cameraDetails(inImageAt: stored) == [[]])
            #expect(orientations(inImageAt: stored) == [6])
        }
    }

    @Test func imageSequenceLosesItsCameraDetailsButKeepsItsFrames() async throws {
        let data = cameraImageData(.tiff, frames: 2, withLocation: true)
        let imported = try await withImportedFile(data, name: "scan.tiff", asPhoto: true) { stored in
            #expect(cameraDetails(inImageAt: stored) == [[], []])
            #expect(orientations(inImageAt: stored) == [6, 6])
        }
        #expect((imported.width, imported.height) == (30, 40))
    }

    @Test func anImageWithNothingToRemoveIsLeftAsItIs() async throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, makeImage(width: 40, height: 30), nil)
        #expect(CGImageDestinationFinalize(destination))
        try await withImportedFile(data as Data, name: "plain.png") { stored in
            let kept = try Data(contentsOf: stored)
            #expect(kept == data as Data)
        }
    }

    /// Imports `data` and hands the stored copy to `inspect`.
    @discardableResult
    private func withImportedFile(_ data: Data, name: String, asPhoto: Bool = false, inspect: (URL) throws -> Void) async throws -> AttachmentStore.Imported {
        let directory = FileManager.default.temporaryDirectory.appending(path: "meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: name)
        try data.write(to: source)
        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let imported = try await store.importFile(at: source, name: name, asPhoto: asPhoto)
        try inspect(store.directory.appending(path: imported.file))
        return imported
    }

    @Test func setDownloadedKeepsTheKnownSizeWhenNothingWasMeasured() throws {
        let db = try AppDatabase.inMemory()
        let peer = JID("alice@example.org")!
        let message = try db.writer.write { db in
            let conversation = try AppDatabase.conversation(db, with: peer)
            let (stored, _) = try AppDatabase.insert(db, Message(
                conversationId: conversation.id!, direction: .incoming, sender: peer, body: "x", timestamp: Date(),
            ))
            try Attachment(messageId: stored.id!, url: "https://up.example/a.mov", name: "a.mov", width: 32, height: 64, state: .remote).insert(db)
            return stored
        }
        try db.setDownloaded(messageId: message.id!, localFile: "f.mov", size: 10, mimeType: nil, width: nil, height: nil)
        let kept = try #require(try db.attachment(messageId: message.id!))
        #expect((kept.width, kept.height) == (32, 64))
        try db.setDownloaded(messageId: message.id!, localFile: "f.mov", size: 10, mimeType: nil, width: 100, height: 50)
        let replaced = try #require(try db.attachment(messageId: message.id!))
        #expect((replaced.width, replaced.height) == (100, 50))
    }

    private func writeVideo(to url: URL, width: Int, height: Int, transform: CGAffineTransform, location: String? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = location as NSString
            writer.metadata = [item]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Frames tagged with what a camera writes, and optionally a location,
    /// turned a quarter turn.
    private func cameraImageData(_ type: UTType, frames: Int = 1, withLocation: Bool, width: Int = 40, height: Int = 30) -> Data {
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5", kCGImagePropertyTIFFDateTime: "2020:01:01 10:00:00",
                kCGImagePropertyTIFFSoftware: "Camera Firmware 1.2", kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFOrientation: 6,
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "0123456789", kCGImagePropertyExifDateTimeOriginal: "2020:01:01 10:00:00"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Jane Doe"]],
        ]
        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 2.29, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        for _ in 0..<frames { CGImageDestinationAddImage(destination, makeImage(width: width, height: height), properties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// What `cameraImageData` writes, besides a location.
    private static let allCameraDetails = ["make", "model", "date", "software", "artist", "serial", "captured", "iptc"]

    /// For each frame, the identifying entries it still carries.
    private func cameraDetails(_ source: CGImageSource) -> [[String]] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            var found: [String] = []
            for (key, value) in [("make", tiff[kCGImagePropertyTIFFMake]), ("model", tiff[kCGImagePropertyTIFFModel]),
                                 ("date", tiff[kCGImagePropertyTIFFDateTime]), ("software", tiff[kCGImagePropertyTIFFSoftware]),
                                 ("artist", tiff[kCGImagePropertyTIFFArtist]), ("serial", exif[kCGImagePropertyExifBodySerialNumber]),
                                 ("captured", exif[kCGImagePropertyExifDateTimeOriginal]),
                                 ("iptc", properties[kCGImagePropertyIPTCDictionary]), ("gps", properties[kCGImagePropertyGPSDictionary])]
                where value != nil { found.append(key) }
            return found
        }
    }

    private func cameraDetails(inImageAt url: URL) -> [[String]] {
        cameraDetails(CGImageSourceCreateWithURL(url as CFURL, nil)!)
    }

    private func orientations(inImageAt url: URL) -> [Int] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return (0..<CGImageSourceGetCount(source)).map {
            (CGImageSourceCopyPropertiesAtIndex(source, $0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        }
    }

    @Test func animatedGifSentAsPhotoStaysAnimated() async throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)!
        for _ in 0..<2 { CGImageDestinationAddImage(destination, makeImage(width: 40, height: 30), nil) }
        #expect(CGImageDestinationFinalize(destination))

        let directory = FileManager.default.temporaryDirectory.appending(path: "gif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "funny.gif")
        try (data as Data).write(to: source)
        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let gif = try await store.importFile(at: source, name: "funny.gif", asPhoto: true)
        #expect(gif.name == "funny.gif")
        #expect(gif.file.hasSuffix(".gif"))
        #expect((gif.width, gif.height) == (40, 30))
        let stored = try #require(CGImageSourceCreateWithURL(store.directory.appending(path: gif.file) as CFURL, nil))
        #expect(CGImageSourceGetCount(stored) == 2)
    }

    @Test func stillPNGSentAsPhotoBecomesJPEG() async throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, makeImage(width: 40, height: 30), nil)
        #expect(CGImageDestinationFinalize(destination))

        let directory = FileManager.default.temporaryDirectory.appending(path: "png-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "shot.png")
        try (data as Data).write(to: source)
        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let photo = try await store.importFile(at: source, name: "shot.png", asPhoto: true)
        #expect(photo.name == "shot.jpg")
        #expect(photo.file.hasSuffix(".jpg"))
    }

    @Test func typeComesFromTheExtensionAndRepeatsAgree() {
        let byExtension = Attachment(messageId: 2, url: nil, name: "clip.mp4", state: .ready)
        #expect(byExtension.type == byExtension.type)
        #expect(byExtension.isVideo)

        let unknown = Attachment(messageId: 3, url: nil, name: "file", state: .ready)
        #expect(unknown.type == nil)
        #expect(unknown.type == nil)
    }

    @Test func mediaTypeIsOnlyUsedWhenTheNameHasNoExtension() {
        #expect(Attachment(messageId: 1, url: nil, name: "pic", mimeType: "image/png", state: .ready).isImage)
        #expect(!Attachment(messageId: 1, url: nil, name: "x.bin", mimeType: "image/png", state: .ready).isImage)
    }

    @Test func aSenderClaimOfAnImageDoesNotMakeAScriptOne() {
        for name in ["photo.terminal", "photo.command", "photo.fileloc", "photo.pkg", "photo.shortcut", "photo.sh"] {
            let offered = Attachment(messageId: 1, url: nil, name: name, mimeType: "image/png", state: .offered)
            #expect(!offered.isImage, "\(name)")
            #expect(!offered.isVideo, "\(name)")
        }
    }

    @Test func aRealPictureWithoutAMediaTypeStaysAnImage() {
        #expect(Attachment(messageId: 1, url: nil, name: "holiday.jpg", state: .remote).isImage)
    }

    @Test func downloadedHTTPAttachmentWithAnImageTypeButACommandNameIsNotAnImage() throws {
        let link = try #require(AttachmentLink.parse(body: "https://example.org/up/photo.command", oob: "https://example.org/up/photo.command"))
        let attachment = Attachment(messageId: 1, url: link.url.absoluteString, name: link.name, mimeType: "image/jpeg", state: .remote)
        #expect(!attachment.isImage)
    }

    @Test func linkNamesLoseBidiControls() throws {
        let body = "https://example.org/up/photo%E2%80%AEgnp.exe"
        let link = try #require(AttachmentLink.parse(body: body, oob: body))
        #expect(link.name == "photognp.exe")
    }
}

struct MacOpenPolicyTests {
    @Test func opensMediaAndPDF() {
        for name in ["a.png", "a.JPG", "a.mov", "a.mp3", "a.pdf"] {
            #expect(MacOpenPolicy.opensInDefaultApp(name: name), "\(name)")
        }
    }

    @Test func refusesWhatLaunchesSomethingElse() {
        for name in ["a.terminal", "a.command", "a.tool", "a.sh", "a.fileloc", "a.webloc", "a.inetloc", "a.scpt", "a.pkg", "a.shortcut", "a.app", "a.html", "a.svg", "a.txt", "a", "a.unknownext"] {
            #expect(!MacOpenPolicy.opensInDefaultApp(name: name), "\(name)")
        }
    }
}
