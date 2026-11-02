import Foundation

/// Which files are sound, and which of those the player can play. A voice
/// message is an audio file like any other, and what clients call one varies:
/// Conversations sends Opus in Ogg, Monal AAC in MPEG-4. So the
/// extension counts when the media type is missing or generic.
public enum AudioFormat {
    static let extensions: Set<String> = ["m4a", "aac", "mp3", "ogg", "opus", "oga", "wav", "caf", "flac", "aif", "aiff"]
    /// What AVAudioPlayer decodes. A list of what plays rather than of what
    /// doesn't: a format missing from a deny-list (WebM, WMA, Matroska) would
    /// get a player that can't play it.
    static let playableExtensions: Set<String> = ["m4a", "aac", "mp3", "wav", "caf", "aif", "aiff", "flac", "mp4"]
    static let playableTypes: Set<String> = [
        "audio/mpeg", "audio/mp3", "audio/x-mpeg", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/mp4a-latm", "audio/aac", "audio/x-aac",
        "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave", "audio/x-caf", "audio/aiff", "audio/x-aiff", "audio/flac", "audio/x-flac",
    ]
    static let unplayableTypes: Set<String> = ["audio/ogg", "audio/opus", "application/ogg", "audio/x-opus+ogg"]

    /// A media type as a name: without its parameters (`; codecs=opus`),
    /// lowercased. Nil when it says nothing.
    static func essence(of mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let type = mimeType.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
        return type.isEmpty || type == "application/octet-stream" ? nil : type
    }

    public static func isAudio(mimeType: String?, name: String) -> Bool {
        if let type = essence(of: mimeType) {
            return type.hasPrefix("audio/") || unplayableTypes.contains(type)
        }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isPlayable(mimeType: String?, name: String) -> Bool {
        let type = essence(of: mimeType)
        if let type, unplayableTypes.contains(type) { return false }
        if let type, playableTypes.contains(type) { return true }
        return playableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Names that clients give the sound they record for a voice message, as
    /// checked in their sources. A message carries no marker for one, so the
    /// name is all there is, and only these are taken for voice:
    /// - Yapnest and Gajim: "Voice message.m4a", "voice-message-20260101-101010.ogg".
    /// - Conversations and Cheogram: "RECORDING_20260101_101010123.m4a" (.oga when
    ///   it records Opus, .mp4 on some devices).
    /// - Monal: a UUID and ".m4a".
    /// Dino and Siskin record nothing, and send what is picked under its own name.
    /// Matched by hand rather than by regular expressions: a row asks on every
    /// render, and these shapes are simple.
    static func hasVoiceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasPrefix("voice"), let separator = lowered.dropFirst(5).first, " _-".contains(separator),
           lowered.dropFirst(6).hasPrefix("message") {
            return true
        }
        return isConversationsRecordingName(lowered) || isMonalRecordingName(lowered)
    }

    /// "recording_20260101_101010123.m4a": 8 digits, 6 to 9 digits, and an extension Conversations uses.
    private static func isConversationsRecordingName(_ lowered: String) -> Bool {
        guard lowered.hasPrefix("recording_") else { return false }
        let parts = lowered.dropFirst("recording_".count).split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[0].allSatisfy(isASCIIDigit) else { return false }
        let tail = parts[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard tail.count == 2, (6...9).contains(tail[0].count), tail[0].allSatisfy(isASCIIDigit) else { return false }
        return ["m4a", "mp4", "oga", "ogg", "opus"].contains(tail[1])
    }

    /// "3f2504e0-4f89-41d3-9a0c-0305e82c3301.m4a": a UUID and ".m4a".
    private static func isMonalRecordingName(_ lowered: String) -> Bool {
        guard lowered.hasSuffix(".m4a") else { return false }
        let groups = lowered.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isHexDigit } }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Whether a sound is someone's voice message rather than a song or a
    /// recording that was picked: by its name alone, as above.
    public static func isVoiceClip(mimeType: String?, name: String) -> Bool {
        guard isAudio(mimeType: mimeType, name: name) else { return false }
        return hasVoiceName(name)
    }

    /// A length as a clock reads it: "0:07", "12:30", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
