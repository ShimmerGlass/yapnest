import Foundation
import YapnestKit

/// One entry of a WebRTC statistics report: its type and its numbers and
/// strings. Apart from WebRTC's objects so the reading can be tested.
struct CallStat {
    var type: String
    var values: [String: Any]

    func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { values[key] as? String }
    func flag(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue }
}

enum CallCodec: String, DiagEnum {
    case opus, pcmu, pcma, g722, vp8, vp9, h264, h265, av1, other, none

    init(mimeType: String?) {
        guard let mimeType else {
            self = .none
            return
        }
        let name = mimeType.split(separator: "/").last.map { $0.lowercased() } ?? ""
        self = name == "hevc" ? .h265 : CallCodec(rawValue: name) ?? .other
    }
}

enum CallRelayProtocol: String, DiagEnum {
    case udp, tcp, tls, other

    init(_ name: String?) {
        self = name.flatMap { CallRelayProtocol(rawValue: $0.lowercased()) } ?? .other
    }
}

enum CallQualityLimit: String, DiagEnum {
    case none, cpu, bandwidth, other

    init(_ name: String?) {
        self = name.map { CallQualityLimit(rawValue: $0) ?? .other } ?? .none
    }
}

enum CallIceConnection: String, DiagEnum {
    case new, checking, connected, completed, failed, disconnected, closed, unknown
}

enum CallIceGathering: String, DiagEnum {
    case new, gathering, complete, unknown
}

/// The figures of a report the log wants. Counters that add up over the call
/// are kept as they are, so two readings give an average over what happened
/// between them (`CallStatsSummary`). Times are in seconds, as WebRTC has them.
struct CallStatsReading: Equatable {
    /// The path the call uses, which is what changes when ICE moves it.
    struct Path: Equatable {
        var local: CallCandidateKind
        var remote: CallCandidateKind
        var relayProtocol: CallRelayProtocol?
    }

    struct AudioIn: Equatable {
        var codec: CallCodec = .none
        var jitterBufferDelay: Double?
        var jitterBufferTargetDelay: Double?
        var jitterBufferMinimumDelay: Double?
        var jitterBufferEmittedCount: Double?
        var jitter: Double?
        var packetsLost: Double?
        var concealedSamples: Double?
        var totalSamplesReceived: Double?
        var playoutDelay: Double?
        var playoutSamples: Double?
    }

    struct VideoIn: Equatable {
        var codec: CallCodec = .none
        var framesDecoded: Double?
        var framesDropped: Double?
        var totalDecodeTime: Double?
        var jitterBufferDelay: Double?
        var jitterBufferEmittedCount: Double?
        var picture = Picture()
        var powerEfficientDecoder: Bool?
    }

    struct VideoOut: Equatable {
        var codec: CallCodec = .none
        var picture = Picture()
        var qualityLimit: CallQualityLimit = .none
        var powerEfficientEncoder: Bool?
    }

    struct Picture: Equatable {
        var width: Double?
        var height: Double?
        var framesPerSecond: Double?
    }

    /// What each kind of media is coded with, which may only be known after
    /// the first reading.
    var codecs: Codecs {
        Codecs(audio: audioIn?.codec ?? .none, video: videoIn?.codec ?? videoOut?.codec ?? .none)
    }

    struct Codecs: Equatable {
        var audio: CallCodec
        var video: CallCodec
    }

    var path: Path?
    var roundTripTime: Double?
    var audioIn: AudioIn?
    var videoIn: VideoIn?
    var videoOut: VideoOut?

    init(_ stats: [String: CallStat]) {
        let byType = Dictionary(grouping: stats.values, by: \.type)
        func codec(of stat: CallStat) -> CallCodec {
            CallCodec(mimeType: stat.string("codecId").flatMap { stats[$0] }?.string("mimeType"))
        }
        func rtp(_ type: String, _ kind: String) -> [CallStat] {
            (byType[type] ?? []).filter { ($0.string("kind") ?? $0.string("mediaType")) == kind }
        }
        func picture(_ stat: CallStat) -> Picture {
            Picture(width: stat.number("frameWidth"), height: stat.number("frameHeight"), framesPerSecond: stat.number("framesPerSecond"))
        }

        if let chosen = Self.selectedPair(stats, byType) {
            func candidate(_ key: String) -> CallStat? { chosen.string(key).flatMap { stats[$0] } }
            let local = candidate("localCandidateId")
            let kind = CallCandidateKind(sdpType: local?.string("candidateType"))
            path = Path(
                local: kind, remote: CallCandidateKind(sdpType: candidate("remoteCandidateId")?.string("candidateType")),
                relayProtocol: kind == .relay ? CallRelayProtocol(local?.string("relayProtocol")) : nil)
            roundTripTime = chosen.number("currentRoundTripTime")
        }

        if let stat = rtp("inbound-rtp", "audio").first {
            var audio = AudioIn(codec: codec(of: stat))
            audio.jitterBufferDelay = stat.number("jitterBufferDelay")
            audio.jitterBufferTargetDelay = stat.number("jitterBufferTargetDelay")
            audio.jitterBufferMinimumDelay = stat.number("jitterBufferMinimumDelay")
            audio.jitterBufferEmittedCount = stat.number("jitterBufferEmittedCount")
            audio.jitter = stat.number("jitter")
            audio.packetsLost = stat.number("packetsLost")
            audio.concealedSamples = stat.number("concealedSamples")
            audio.totalSamplesReceived = stat.number("totalSamplesReceived")
            if let playout = (byType["media-playout"] ?? []).first(where: { $0.string("kind") == "audio" }) {
                audio.playoutDelay = playout.number("totalPlayoutDelay")
                audio.playoutSamples = playout.number("totalSamplesCount")
            }
            audioIn = audio
        }

        if let stat = rtp("inbound-rtp", "video").first {
            videoIn = VideoIn(
                codec: codec(of: stat), framesDecoded: stat.number("framesDecoded"),
                framesDropped: stat.number("framesDropped"), totalDecodeTime: stat.number("totalDecodeTime"),
                jitterBufferDelay: stat.number("jitterBufferDelay"),
                jitterBufferEmittedCount: stat.number("jitterBufferEmittedCount"),
                picture: picture(stat), powerEfficientDecoder: stat.flag("powerEfficientDecoder"))
        }

        // Several streams are simulcast layers; the biggest shows what goes out.
        if let stat = rtp("outbound-rtp", "video").max(by: { ($0.number("frameWidth") ?? 0) < ($1.number("frameWidth") ?? 0) }) {
            videoOut = VideoOut(
                codec: codec(of: stat), picture: picture(stat),
                qualityLimit: CallQualityLimit(stat.string("qualityLimitationReason")),
                powerEfficientEncoder: stat.flag("powerEfficientEncoder"))
        }
    }

    /// The pair the transport uses, else the nominated one that succeeded.
    static func selectedPair(_ stats: [String: CallStat], _ byType: [String: [CallStat]]) -> CallStat? {
        let selectedId = (byType["transport"] ?? []).lazy.compactMap { $0.string("selectedCandidatePairId") }.first
        return selectedId.flatMap { stats[$0] }
            ?? (byType["candidate-pair"] ?? []).first { $0.flag("nominated") == true && $0.string("state") == "succeeded" }
    }
}

/// What a reading says, with the averages taken over the time since
/// `previous`, so a delay that creeps up shows as it does, and not diluted by
/// the call's start. Times are in seconds.
struct CallStatsSummary: Equatable {
    var roundTripTime: Double?
    var audioJitterBuffer: Double?
    var audioJitterBufferTarget: Double?
    var audioJitterBufferMinimum: Double?
    var audioJitter: Double?
    var audioPlayout: Double?
    var audioPacketsLost: Int?
    /// Of every thousand samples in the interval.
    var audioConcealedPermille: Int?
    var videoDecode: Double?
    var videoJitterBuffer: Double?
    var videoFramesDecoded: Int?
    var videoFramesDropped: Int?

    init(_ reading: CallStatsReading, since previous: CallStatsReading?) {
        let audio = reading.audioIn, before = previous?.audioIn
        let video = reading.videoIn, videoBefore = previous?.videoIn
        roundTripTime = reading.roundTripTime
        audioJitterBuffer = Self.mean(audio, before, \.jitterBufferDelay, per: \.jitterBufferEmittedCount)
        audioJitterBufferTarget = Self.mean(audio, before, \.jitterBufferTargetDelay, per: \.jitterBufferEmittedCount)
        audioJitterBufferMinimum = Self.mean(audio, before, \.jitterBufferMinimumDelay, per: \.jitterBufferEmittedCount)
        audioJitter = audio?.jitter
        audioPlayout = Self.mean(audio, before, \.playoutDelay, per: \.playoutSamples)
        audioPacketsLost = audio?.packetsLost.map { Int($0) }
        audioConcealedPermille = Self.mean(audio, before, \.concealedSamples, per: \.totalSamplesReceived).map { Int(($0 * 1000).rounded()) }
        videoDecode = Self.mean(video, videoBefore, \.totalDecodeTime, per: \.framesDecoded)
        videoJitterBuffer = Self.mean(video, videoBefore, \.jitterBufferDelay, per: \.jitterBufferEmittedCount)
        videoFramesDecoded = video?.framesDecoded.map { Int($0) }
        videoFramesDropped = video?.framesDropped.map { Int($0) }
    }

    /// The change in a sum over the change in its count, nil when nothing
    /// was counted since.
    static func mean<Root>(_ now: Root?, _ previous: Root?, _ sum: KeyPath<Root, Double?>, per count: KeyPath<Root, Double?>) -> Double? {
        guard let now, let total = now[keyPath: sum], let counted = now[keyPath: count] else { return nil }
        let delta = counted - (previous?[keyPath: count] ?? 0)
        guard delta > 0 else { return nil }
        return (total - (previous?[keyPath: sum] ?? 0)) / delta
    }
}

/// Reads the connection's statistics now and then and writes what they say to
/// the diagnostics log. It holds no reference to the media, so a report that
/// arrives after the call has closed does no harm.
final class CallStatsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: CallStatsReading?

    func record(_ stats: [String: CallStat]) {
        let reading = CallStatsReading(stats)
        let before = lock.withLock { () -> CallStatsReading? in
            defer { previous = reading }
            return previous
        }
        let summary = CallStatsSummary(reading, since: before)
        let codecs = reading.codecs
        if before == nil || before?.codecs != codecs {
            DiagLog.info(.calls, "Call media codecs", .value("audio", codecs.audio), .value("video", codecs.video))
        }
        if before == nil || before?.path != reading.path {
            var fields: [DiagField] = []
            if let path = reading.path {
                fields += [.value("local", path.local), .value("remote", path.remote)]
                if let relay = path.relayProtocol { fields.append(.value("relayProtocol", relay)) }
            } else {
                fields.append(.bool("pair", false))
            }
            DiagLog.info(.calls, "Call path", fields: fields)
        }
        if reading.audioIn != nil {
            var fields: [DiagField] = []
            fields.add("rtt", summary.roundTripTime)
            fields.add("jbDelay", summary.audioJitterBuffer)
            fields.add("jbTarget", summary.audioJitterBufferTarget)
            fields.add("jbMinimum", summary.audioJitterBufferMinimum)
            fields.add("jitter", summary.audioJitter)
            fields.add("playout", summary.audioPlayout)
            fields.add("lostTotal", summary.audioPacketsLost)
            fields.add("concealedPermille", summary.audioConcealedPermille)
            DiagLog.info(.calls, "Call audio in", fields: fields)
        }
        if let video = reading.videoIn {
            var fields: [DiagField] = []
            fields.add("decodedTotal", summary.videoFramesDecoded)
            fields.add("droppedTotal", summary.videoFramesDropped)
            fields.add("decode", summary.videoDecode)
            fields.add("jbDelay", summary.videoJitterBuffer)
            fields.add(video.picture, powerEfficient: video.powerEfficientDecoder)
            DiagLog.info(.calls, "Call video in", fields: fields)
        }
        if let video = reading.videoOut {
            var fields: [DiagField] = [.value("limit", video.qualityLimit)]
            fields.add(video.picture, powerEfficient: video.powerEfficientEncoder)
            DiagLog.info(.calls, "Call video out", fields: fields)
        }
    }
}

private extension [DiagField] {
    mutating func add(_ key: StaticString, _ count: Int?) {
        if let count { append(.int(key, count)) }
    }

    mutating func add(_ key: StaticString, _ seconds: Double?) {
        if let seconds { append(.duration(key, seconds)) }
    }

    mutating func add(_ picture: CallStatsReading.Picture, powerEfficient: Bool?) {
        add("width", picture.width.map { Int($0) })
        add("height", picture.height.map { Int($0) })
        add("fps", picture.framesPerSecond.map { Int($0.rounded()) })
        if let powerEfficient { append(.bool("powerEfficient", powerEfficient)) }
    }
}
