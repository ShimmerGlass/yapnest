import Testing
import YapnestKit
@testable import YapnestCallMedia

private func stat(_ type: String, _ values: [String: Any]) -> CallStat {
    CallStat(type: type, values: values)
}

private func report(
    selected: Bool = true, remoteType: String = "srflx", localType: String = "host",
    audio: [String: Any] = [:],
) -> [String: CallStat] {
    var stats: [String: CallStat] = [
        "T": stat("transport", selected ? ["selectedCandidatePairId": "P"] : [:]),
        "P": stat("candidate-pair", [
            "localCandidateId": "L", "remoteCandidateId": "R", "currentRoundTripTime": 0.012,
            "nominated": true, "state": "succeeded",
        ]),
        "L": stat("local-candidate", ["candidateType": localType, "relayProtocol": "tls"]),
        "R": stat("remote-candidate", ["candidateType": remoteType]),
        "C": stat("codec", ["mimeType": "audio/opus"]),
    ]
    var inbound: [String: Any] = ["kind": "audio", "codecId": "C"]
    inbound.merge(audio) { $1 }
    stats["A"] = stat("inbound-rtp", inbound)
    return stats
}

struct CallStatsTests {
    @Test func theTransportsPairIsTheOneRead() {
        var stats = report()
        stats["Other"] = stat("candidate-pair", [
            "localCandidateId": "L", "remoteCandidateId": "R", "currentRoundTripTime": 0.9,
        ])
        let reading = CallStatsReading(stats)
        #expect(reading.roundTripTime == 0.012)
        #expect(reading.path?.local == .host)
        #expect(reading.path?.remote == .srflx)
        #expect(reading.path?.relayProtocol == nil)
    }

    @Test func withoutASelectedPairTheNominatedSucceededOneIsRead() {
        var stats = report(selected: false)
        stats["Waiting"] = stat("candidate-pair", ["localCandidateId": "L", "remoteCandidateId": "R", "currentRoundTripTime": 0.9])
        #expect(CallStatsReading(stats).roundTripTime == 0.012)
        stats["P"] = nil
        #expect(CallStatsReading(stats).path == nil)
    }

    @Test func aRelayedPairSaysWhichProtocolReachesTheRelay() {
        let path = CallStatsReading(report(localType: "relay")).path
        #expect(path?.local == .relay)
        #expect(path?.relayProtocol == .tls)
    }

    @Test func aCandidateTypeOrCodecWeDoNotKnowIsOther() {
        var stats = report(remoteType: "something-new")
        stats["C"] = stat("codec", ["mimeType": "audio/lyra"])
        let reading = CallStatsReading(stats)
        #expect(reading.path?.remote == .unknown)
        #expect(reading.audioIn?.codec == .other)
        #expect(CallCodec(mimeType: "video/HEVC") == .h265)
        #expect(CallRelayProtocol("DTLS") == .other)
        #expect(CallCodec(mimeType: "video/H264") == .h264)
        #expect(CallCodec(mimeType: "video/VP9") == .vp9)
        #expect(CallCodec(mimeType: nil) == CallCodec.none)
        #expect(CallQualityLimit("something") == .other)
        #expect(CallQualityLimit("none") == CallQualityLimit.none)
    }

    @Test func theJitterBufferAverageCoversTheTimeSinceTheLastReading() {
        let first = CallStatsReading(report(audio: [
            "jitterBufferDelay": 10.0, "jitterBufferEmittedCount": 1000.0,
            "jitterBufferMinimumDelay": 8.0, "jitterBufferTargetDelay": 9.0,
        ]))
        let second = CallStatsReading(report(audio: [
            "jitterBufferDelay": 70.0, "jitterBufferEmittedCount": 2000.0,
            "jitterBufferMinimumDelay": 68.0, "jitterBufferTargetDelay": 69.0,
        ]))
        let firstSummary = CallStatsSummary(first, since: nil)
        #expect(firstSummary.audioJitterBuffer == 0.01)
        let summary = CallStatsSummary(second, since: first)
        #expect(summary.audioJitterBuffer == 0.06)
        #expect(summary.audioJitterBufferMinimum == 0.06)
        #expect(summary.audioJitterBufferTarget == 0.06)
        #expect(summary.roundTripTime == 0.012)
    }

    @Test func aReadingWithNothingNewLeavesTheAverageOut() {
        let audio: [String: Any] = ["jitterBufferDelay": 10.0, "jitterBufferEmittedCount": 1000.0]
        let reading = CallStatsReading(report(audio: audio))
        #expect(CallStatsSummary(reading, since: reading).audioJitterBuffer == nil)
    }

    @Test func concealmentAndPlayoutAreAveragedOverTheInterval() {
        var stats = report(audio: ["concealedSamples": 100.0, "totalSamplesReceived": 1000.0, "jitter": 0.004, "packetsLost": 3])
        stats["M"] = stat("media-playout", ["kind": "audio", "totalPlayoutDelay": 2.0, "totalSamplesCount": 100.0])
        let first = CallStatsReading(stats)
        var later = report(audio: ["concealedSamples": 150.0, "totalSamplesReceived": 2000.0])
        later["M"] = stat("media-playout", ["kind": "audio", "totalPlayoutDelay": 6.0, "totalSamplesCount": 200.0])
        let summary = CallStatsSummary(CallStatsReading(later), since: first)
        #expect(summary.audioConcealedPermille == 50)
        #expect(summary.audioPlayout == 0.04)
        let initial = CallStatsSummary(first, since: nil)
        #expect(initial.audioJitter == 0.004)
        #expect(initial.audioPacketsLost == 3)
        #expect(initial.audioConcealedPermille == 100)
    }

    @Test func missingFieldsAndStreamsAreLeftOut() {
        let reading = CallStatsReading(["X": stat("something", [:])])
        #expect(reading.path == nil)
        #expect(reading.audioIn == nil)
        #expect(reading.videoIn == nil)
        #expect(reading.videoOut == nil)
        let summary = CallStatsSummary(reading, since: nil)
        #expect(summary.roundTripTime == nil)
        #expect(summary.videoDecode == nil)
    }

    @Test func videoIsReadFromBothDirections() {
        var stats = report()
        stats["V"] = stat("codec", ["mimeType": "video/VP8"])
        stats["VI"] = stat("inbound-rtp", [
            "kind": "video", "codecId": "V", "framesDecoded": 100.0, "framesDropped": 4.0, "totalDecodeTime": 0.5,
            "frameWidth": 1280, "frameHeight": 720, "framesPerSecond": 29.6, "powerEfficientDecoder": true,
        ])
        stats["VO"] = stat("outbound-rtp", [
            "kind": "video", "codecId": "V", "frameWidth": 640, "frameHeight": 360,
            "qualityLimitationReason": "cpu", "powerEfficientEncoder": false,
        ])
        stats["VO2"] = stat("outbound-rtp", ["kind": "video", "frameWidth": 320])
        let reading = CallStatsReading(stats)
        #expect(reading.videoIn?.codec == .vp8)
        #expect(reading.videoIn?.powerEfficientDecoder == true)
        #expect(reading.videoOut?.picture.width == 640)
        #expect(reading.videoOut?.qualityLimit == .cpu)
        #expect(reading.videoOut?.powerEfficientEncoder == false)
        let summary = CallStatsSummary(reading, since: nil)
        #expect(summary.videoDecode == 0.005)
        #expect(summary.videoFramesDropped == 4)
    }

    @Test func theCodecsAreReportedAgainWhenTheyChange() {
        var stats = report()
        stats["A"] = stat("inbound-rtp", ["kind": "audio"])
        let early = CallStatsReading(stats).codecs
        #expect(early == CallStatsReading.Codecs(audio: .none, video: .none))
        stats = report()
        stats["V"] = stat("codec", ["mimeType": "video/VP8"])
        stats["VI"] = stat("inbound-rtp", ["kind": "video", "codecId": "V"])
        let later = CallStatsReading(stats).codecs
        #expect(later == CallStatsReading.Codecs(audio: .opus, video: .vp8))
        #expect(early != later)
    }
}
