import AVFoundation
import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func parse(_ xml: String) throws -> InboundMessage {
    try #require(InboundMessage(parseStanza(xml) as Martin.Message, account: me, source: .live))
}

/// A mono sound of `seconds`, loud for the first half and silent after, in a
/// folder of its own. CAF takes PCM as it is, so no encoder is involved.
private func makeSound(seconds: Double = 1, named name: String = "clip.caf") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    let rate = 8000.0
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<Int(frames) {
        samples[index] = index < Int(frames) / 2 ? Float(sin(Double(index) * 0.3)) * 0.8 : 0
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}

struct AudioDetectionTests {
    @Test func audioIsRecognizedByMediaType() {
        #expect(Attachment(messageId: 1, url: nil, name: "x", mimeType: "audio/mp4", state: .remote).isAudio)
        #expect(Attachment(messageId: 1, url: nil, name: "x", mimeType: "audio/mpeg", state: .remote).isAudio)
        #expect(Attachment(messageId: 1, url: nil, name: "x", mimeType: "AUDIO/OGG", state: .remote).isAudio)
        #expect(!Attachment(messageId: 1, url: nil, name: "x.m4a", mimeType: "application/pdf", state: .remote).isAudio)
        #expect(!Attachment(messageId: 1, url: nil, name: "x.png", mimeType: "image/png", state: .remote).isAudio)
    }

    @Test func audioIsRecognizedByExtensionWhenTheTypeIsMissingOrGeneric() {
        for ext in ["m4a", "aac", "mp3", "ogg", "opus", "oga", "wav", "caf", "M4A"] {
            #expect(Attachment(messageId: 1, url: nil, name: "voice.\(ext)", state: .remote).isAudio, "\(ext)")
            #expect(Attachment(messageId: 1, url: nil, name: "voice.\(ext)", mimeType: "application/octet-stream", state: .remote).isAudio, "\(ext)")
        }
        #expect(!Attachment(messageId: 1, url: nil, name: "notes.pdf", state: .remote).isAudio)
        #expect(!Attachment(messageId: 1, url: nil, name: "voice", state: .remote).isAudio)
    }

    @Test func oggAndOpusAreNotPlayedInline() {
        func plays(_ name: String, _ type: String? = nil) -> Bool {
            Attachment(messageId: 1, url: nil, name: name, mimeType: type, state: .ready).playsInline
        }
        #expect(plays("a.m4a", "audio/mp4"))
        #expect(plays("a.mp3"))
        #expect(plays("a.wav"))
        #expect(plays("a.caf"))
        #expect(!plays("a.ogg"))
        #expect(!plays("a.opus", "audio/ogg"))
        #expect(!plays("a.oga"))
        #expect(!plays("noextension", "audio/ogg"))
        // Still audio, so it is summarised as sound, though the player can't play it.
        let opus = Attachment(messageId: 1, url: nil, name: "a.opus", state: .ready)
        #expect(opus.isAudio)
        #expect(opus.summary == "🎵 a.opus")
    }

    @Test func aVoiceMessageIsSummarised() {
        #expect(Attachment(messageId: 1, url: nil, name: "Voice message.m4a", mimeType: "audio/mp4", state: .ready).summary == "🎤 Voice message")
        #expect(Attachment.quoteSummary(text: "https://up.example/x/Voice%20message.m4a", attachment: nil) == "🎤 Voice message")
        // The key in an encrypted link is never shown.
        #expect(Attachment.quoteSummary(text: "aesgcm://up.example/x/RECORDING_20260101_101010123.m4a#0123", attachment: nil) == "🎤 Voice message")
    }

    @Test func otherSoundIsSummarisedByName() {
        #expect(Attachment(messageId: 1, url: nil, name: "Song.mp3", mimeType: "audio/mpeg", state: .ready).summary == "🎵 Song.mp3")
        #expect(Attachment(messageId: 1, url: nil, name: "interview.opus", state: .ready).summary == "🎵 interview.opus")
        #expect(Attachment.quoteSummary(text: "https://up.example/x/song.m4a", attachment: nil) == "🎵 song.m4a")
    }

    @Test(arguments: [
        "Voice message.m4a", "voice message 2.m4a", "voice-message-20260101-101010.ogg", "voice_message.opus",
        "RECORDING_20260101_101010123.m4a", "RECORDING_20260101_101010123.oga",
        "recording_20260101_101010123.M4A", "3F2504E0-4F89-41D3-9A0C-0305E82C3301.m4a", "3f2504e0-4f89-41d3-9a0c-0305e82c3301.m4a",
    ])
    func voiceClipsOfEachClientAreRecognised(name: String) {
        #expect(AudioFormat.isVoiceClip(mimeType: nil, name: name), "\(name)")
        #expect(AudioFormat.isVoiceClip(mimeType: "audio/mp4", name: name), "\(name)")
    }

    @Test(arguments: [
        "Song.mp3", "voice.m4a", "meeting recording.m4a", "RECORDING.m4a", "RECORDING_2026_1.m4a", "my voice message.m4a",
        "3F2504E0-4F89-41D3-9A0C-0305E82C3301.mp3", "3F2504E0-4F89-41D3-9A0C-0305E82C3301.m4a.pdf", "Voice message.pdf",
    ])
    func otherFilesAreNotVoiceClips(name: String) {
        #expect(!AudioFormat.isVoiceClip(mimeType: nil, name: name), "\(name)")
    }

    @Test func conversationsMP4RecordingNeedsASoundMediaType() {
        #expect(AudioFormat.isVoiceClip(mimeType: "audio/mp4", name: "RECORDING_20260101_101010123.mp4"))
        #expect(!AudioFormat.isVoiceClip(mimeType: "video/mp4", name: "RECORDING_20260101_101010123.mp4"))
        #expect(!AudioFormat.isVoiceClip(mimeType: nil, name: "RECORDING_20260101_101010123.mp4"))
    }

    @Test func aVoiceNameOnSomethingThatIsNotSoundIsNotAVoiceClip() {
        #expect(!AudioFormat.isVoiceClip(mimeType: "application/pdf", name: "Voice message.m4a"))
        #expect(!AudioFormat.isVoiceClip(mimeType: "image/png", name: "RECORDING_20260101_101010123.m4a"))
    }

    @Test func chatListAndNotificationsSayVoiceMessage() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.conversation(with: alice).id!
        let url = "https://up.example/x/Voice%20message.m4a"
        let message = try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: url, remoteId: "v1"))
        try db.writer.write { try Attachment(messageId: message.id!, url: url, name: "Voice message.m4a", mimeType: "audio/mp4", state: .remote).insert($0) }
        #expect(try db.chatList().first?.lastAttachment?.summary == "🎤 Voice message")
    }

    @Test func ourRecordingsAreUploadedAsMPEG4Audio() {
        #expect(AttachmentStore.mimeType(for: "Voice message.m4a") == "audio/mp4")
    }

    @Test func clockShowsMinutesAndSeconds() {
        #expect(AudioFormat.clock(0) == "0:00")
        #expect(AudioFormat.clock(7.9) == "0:07")
        #expect(AudioFormat.clock(754) == "12:34")
        #expect(AudioFormat.clock(3723) == "1:02:03")
        #expect(AudioFormat.clock(-5) == "0:00")
        #expect(AudioFormat.clock(.nan) == "0:00")
    }
}

struct VoiceMetadataTests {
    private func announced(length: String, type: String = "audio/mp4", name: String = "voice.m4a") -> String {
        """
        <message from='alice@example.org/r' type='chat' id='v1'>
          <body>https://up.example/x/\(name)</body>
          <x xmlns='jabber:x:oob'><url>https://up.example/x/\(name)</url></x>
          <file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>
            <media-type>\(type)</media-type><size>5000</size><length>\(length)</length></file></file-sharing>
        </message>
        """
    }

    @Test func lengthIsReadInMilliseconds() throws {
        let metadata = try #require(try parse(announced(length: "12500")).fileMetadata)
        #expect(metadata.length == 12.5)
        #expect(metadata.size == 5000)
    }

    @Test func implausibleLengthsAreIgnored() throws {
        for length in ["0", "-3", "abc", "", "999999999999", "1.5"] {
            let metadata = try #require(try parse(announced(length: length)).fileMetadata)
            #expect(metadata.length == nil, "\(length)")
        }
    }

    @Test func incomingAudioKeepsItsLength() throws {
        let db = try AppDatabase.inMemory()
        let file = try #require(try db.ingest(try parse(announced(length: "42000"))).newAttachment)
        #expect(file.duration == 42)
        #expect(file.isAudio)
        #expect(try db.attachment(messageId: file.messageId)?.duration == 42)
    }

    @Test func lengthOfSomethingThatIsNotAudioIsIgnored() throws {
        let db = try AppDatabase.inMemory()
        let stanza = announced(length: "42000", type: "audio/mp4", name: "report.pdf")
        let file = try #require(try db.ingest(try parse(stanza)).newAttachment)
        #expect(file.duration == nil)
    }

    @Test func encryptedMessageIgnoresTheLength() throws {
        let stanza = announced(length: "42000")
        let inbound = try #require(InboundMessage(parseStanza(stanza) as Martin.Message, account: me, source: .live, encryption: .omemo))
        #expect(inbound.fileMetadata == nil)
        let db = try AppDatabase.inMemory()
        let file = try #require(try db.ingest(inbound).newAttachment)
        #expect(file.duration == nil)
    }

    @Test func lengthSurvivesAnAnnouncementThatArrivesFirst() throws {
        let db = try AppDatabase.inMemory()
        let announcement = """
            <message from='alice@example.org/dino' to='me@example.org/yapnest' type='chat' id='m1'>
              <file-sharing xmlns='urn:xmpp:sfs:0' id='sfs-1'>
                <file xmlns='urn:xmpp:file:metadata:0'><media-type>audio/mp4</media-type><length>3000</length></file>
              </file-sharing>
            </message>
            """
        let sources = """
            <message from='alice@example.org/dino' to='me@example.org/yapnest' type='chat' id='m2'>
              <body>https://up.example/x/v.m4a</body>
              <x xmlns='jabber:x:oob'><url>https://up.example/x/v.m4a</url></x>
              <sources xmlns='urn:xmpp:sfs:0' id='sfs-1'>
                <url-data xmlns='http://jabber.org/protocol/url-data' target='https://up.example/x/v.m4a'/>
              </sources>
            </message>
            """
        _ = try db.ingest(try parse(announcement))
        let file = try #require(try db.ingest(try parse(sources)).newAttachment)
        #expect(file.duration == 3)
    }

    @Test func aDownloadMeasuresTheDurationAndKeepsTheAnnouncedOneOtherwise() throws {
        let db = try AppDatabase.inMemory()
        let file = try #require(try db.ingest(try parse(announced(length: "42000"))).newAttachment)
        try db.setDownloaded(messageId: file.messageId, localFile: "a.m4a", size: 1, mimeType: nil, width: nil, height: nil)
        #expect(try db.attachment(messageId: file.messageId)?.duration == 42)
        try db.setDownloaded(messageId: file.messageId, localFile: "a.m4a", size: 1, mimeType: nil, width: nil, height: nil, duration: 7.5)
        #expect(try db.attachment(messageId: file.messageId)?.duration == 7.5)
    }

    @Test func migrationAddsTheDuration() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v33-message-quickResponses")
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO attachment (messageId, url, name, state) VALUES (7, 'https://up.example/a.m4a', 'a.m4a', 'remote')")
        }
        try AppDatabase.migrator.migrate(queue)
        let kept = try queue.read { try Attachment.fetchOne($0, key: 7) }
        #expect(kept?.name == "a.m4a")
        #expect(kept?.duration == nil)
    }

    @Test func outgoingAudioIsDescribedWithItsLength() throws {
        let sound = try makeSound(seconds: 2)
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let store = AttachmentStore(directory: sound.deletingLastPathComponent())
        let attachment = Attachment(
            messageId: 1, url: "https://up.example/x/clip.caf", name: "Voice message.m4a", mimeType: "audio/mp4", size: 1,
            duration: 2.0, localFile: "clip.caf", state: .ready,
        )
        let metadata = try #require(FileMetadata.outgoing(for: attachment, in: store))
        #expect(metadata.length == 2.0)
        #expect(metadata.mediaType == "audio/mp4")
        #expect(metadata.size == sound.fileSize)
        #expect(metadata.thumbnail == nil && metadata.width == nil)

        let url = "https://up.example/x/voice.m4a"
        let stanza = OutboundStanza.text(url, to: .direct(alice), id: "m1")
        OutboundStanza.addFile(url: url, metadata: metadata, encrypted: false, to: stanza)
        let text = stanza.element.stringValue
        #expect(text.contains("<length>2000</length>"))
        stanza.from = Martin.JID(me.martin)
        let received = try #require(try parse(text).fileMetadata)
        #expect(received.length == 2.0)
        #expect(received.size == sound.fileSize)
    }

    @Test func encryptedAudioSendsNoLength() throws {
        let sound = try makeSound()
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let store = AttachmentStore(directory: sound.deletingLastPathComponent())
        let attachment = Attachment(
            messageId: 1, url: nil, name: "Voice message.m4a", mimeType: "audio/mp4", duration: 1, localFile: "clip.caf", state: .ready,
        )
        let url = "aesgcm://up.example/x/voice.m4a#0123"
        let stanza = OutboundStanza.text(url, to: .direct(alice), id: "m1")
        let before = stanza.element.stringValue
        OutboundStanza.addFile(url: url, metadata: FileMetadata.outgoing(for: attachment, in: store), encrypted: true, to: stanza)
        #expect(stanza.element.stringValue == before)
        #expect(!before.contains("length"))
    }

    @Test func importedAudioKnowsItsDuration() async throws {
        let sound = try makeSound(seconds: 1.5, named: "Voice message.caf")
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let store = AttachmentStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let imported = try await store.importFile(at: sound, name: "Voice message.caf", asPhoto: false)
        let duration = try #require(imported.duration)
        #expect(abs(duration - 1.5) < 0.01)
        let text = try await store.importFile(at: sound, name: "notes.txt", asPhoto: false)
        #expect(text.duration == nil)
    }
}

struct AudioWaveformTests {
    @Test func barsFollowTheLoudness() throws {
        let sound = try makeSound(seconds: 1)
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let bars = try #require(AudioWaveform.levels(for: sound))
        #expect(bars.count == AudioWaveform.barCount)
        let half = bars.count / 2
        #expect(bars[..<half].allSatisfy { $0 > 200 }, "\(bars)")
        #expect(bars[half...].allSatisfy { $0 < 10 }, "\(bars)")
    }

    @Test func barsAreKeptBesideTheFile() throws {
        let sound = try makeSound()
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let first = try #require(AudioWaveform.levels(for: sound))
        let cache = AudioWaveform.cacheURL(for: sound)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        // The cache answers: with the sound gone, the bars are still there.
        try FileManager.default.removeItem(at: sound)
        #expect(AudioWaveform.levels(for: sound) == first)
    }

    @Test func removingAnAttachmentRemovesItsBars() throws {
        let sound = try makeSound()
        let store = AttachmentStore(directory: sound.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = AudioWaveform.levels(for: sound)
        store.remove(Attachment(messageId: 1, url: nil, name: "clip.caf", localFile: "clip.caf", state: .ready))
        #expect(!FileManager.default.fileExists(atPath: sound.path))
        #expect(!FileManager.default.fileExists(atPath: AudioWaveform.cacheURL(for: sound).path))
    }

    @Test func aFileThatIsNotSoundHasNoBars() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "x.m4a")
        try Data("not audio".utf8).write(to: file)
        #expect(AudioWaveform.levels(for: file) == nil)
        #expect(AudioWaveform.duration(of: file) == nil)
    }

    @Test func durationIsReadFromTheFile() throws {
        let sound = try makeSound(seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        let duration = try #require(AudioWaveform.duration(of: sound))
        #expect(abs(duration - 2.5) < 0.01)
    }

    @Test func aNearlySilentSoundIsNotBlownUp() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "quiet.caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<8000 { samples[index] = Float(sin(Double(index) * 0.3)) * 0.001 }
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
        let bars = try #require(AudioWaveform.levels(for: url))
        #expect(bars.max()! < 40)
    }
}

struct VoiceRecordingRulesTests {
    @Test func aShortPressLocksTheRecording() {
        #expect(VoiceRecordingRules.release(pressDuration: 0.1, willCancel: false) == .lock)
        #expect(VoiceRecordingRules.release(pressDuration: VoiceRecordingRules.tapDuration, willCancel: false) == .send)
    }

    @Test func aHoldIsSentOnRelease() {
        #expect(VoiceRecordingRules.release(pressDuration: 4, willCancel: false) == .send)
    }

    @Test func slidingFarEnoughCancelsEvenAShortPress() {
        #expect(VoiceRecordingRules.release(pressDuration: 4, willCancel: true) == .cancel)
        #expect(VoiceRecordingRules.release(pressDuration: 0.1, willCancel: true) == .cancel)
    }

    @Test func recordingsUnderHalfASecondAreDropped() {
        #expect(!VoiceRecordingRules.isSendable(0.49))
        #expect(VoiceRecordingRules.isSendable(0.5))
        #expect(VoiceRecordingRules.maximumDuration == 900)
    }

    @Test func meterMapsDecibelsToALevel() {
        #expect(VoiceRecordingRules.meterLevel(decibels: -160) == 0)
        #expect(VoiceRecordingRules.meterLevel(decibels: -50) == 0)
        #expect(VoiceRecordingRules.meterLevel(decibels: -25) == 0.5)
        #expect(VoiceRecordingRules.meterLevel(decibels: 0) == 1)
        #expect(VoiceRecordingRules.meterLevel(decibels: 6) == 1)
        #expect(VoiceRecordingRules.meterLevel(decibels: -.infinity) == 0)
    }
}
