import Foundation

/// Which files are sound, and which of those the player can play. A voice
/// message is an audio file like any other, and what clients call one varies:
/// Conversations sends Opus in Ogg, Monal and Siskin AAC in MPEG-4. So the
/// extension counts when the media type is missing or generic.
public enum AudioFormat {
    static let extensions: Set<String> = ["m4a", "aac", "mp3", "ogg", "opus", "oga", "wav", "caf"]
    /// Containers and codecs AVAudioPlayer can't decode.
    static let unplayableExtensions: Set<String> = ["ogg", "opus", "oga"]
    static let unplayableTypes: Set<String> = ["audio/ogg", "audio/opus", "application/ogg", "audio/x-opus+ogg"]

    public static func isAudio(mimeType: String?, name: String) -> Bool {
        if let type = mimeType?.lowercased(), !type.isEmpty, type != "application/octet-stream" {
            return type.hasPrefix("audio/") || unplayableTypes.contains(type)
        }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isPlayable(mimeType: String?, name: String) -> Bool {
        if unplayableExtensions.contains((name as NSString).pathExtension.lowercased()) { return false }
        if let type = mimeType?.lowercased(), unplayableTypes.contains(type) { return false }
        return true
    }

    /// Names that clients give the sound they record for a voice message, as
    /// checked in their sources. A message carries no marker for one, so the
    /// name is all there is, and only these are taken for voice:
    /// - Yapnest and Gajim: "Voice message.m4a", "voice-message-20260101-101010.ogg".
    /// - Conversations and Cheogram: "RECORDING_20260101_101010123.m4a" (.oga when
    ///   it records Opus, .mp4 on some devices).
    /// - Monal: a UUID and ".m4a".
    /// Dino and Siskin record nothing, and send what is picked under its own name.
    static let voiceNamePatterns = [
        "^voice[ _-]message.*",
        "^RECORDING_[0-9]{8}_[0-9]{6,9}\\.(m4a|mp4|oga|ogg|opus)$",
        "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\.m4a$",
    ]

    /// Whether a sound is someone's voice message rather than a song or a
    /// recording that was picked: by its name alone, as above.
    public static func isVoiceClip(mimeType: String?, name: String) -> Bool {
        guard isAudio(mimeType: mimeType, name: name) else { return false }
        return voiceNamePatterns.contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A length as a clock reads it: "0:07", "12:30", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
