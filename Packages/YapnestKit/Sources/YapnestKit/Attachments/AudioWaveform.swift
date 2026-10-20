import Accelerate
import AVFoundation
import Foundation

/// The outline of a sound drawn in its bubble: a loudness for each of a
/// fixed number of bars, from 0 (quiet) to 255. It is worked out from the
/// whole file, which means decoding it, so a result is kept beside the file
/// in the attachment store and the file is read again only if that is lost.
public enum AudioWaveform {
    public static let barCount = 48

    /// Where the bars of `file` are kept.
    static func cacheURL(for file: URL) -> URL {
        file.appendingPathExtension("waveform")
    }

    /// The bars for the sound at `file`, from the cache if it has them. Nil
    /// if the file can't be decoded. Call it off the main thread.
    public static func levels(for file: URL, bars: Int = barCount) -> [UInt8]? {
        let cache = cacheURL(for: file)
        if let stored = try? Data(contentsOf: cache), stored.count == bars { return [UInt8](stored) }
        guard let computed = compute(file, bars: bars) else { return nil }
        try? Data(computed).write(to: cache, options: .atomic)
        return computed
    }

    /// How long the sound at `file` plays, if it can be read.
    public static func duration(of file: URL) -> TimeInterval? {
        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// The root mean square of each bar's share of the samples, scaled so the
    /// loudest bar is full unless the whole sound is nearly silent, which
    /// would otherwise be blown up into noise.
    static func compute(_ file: URL, bars: Int) -> [UInt8]? {
        guard bars > 0, let audio = try? AVAudioFile(forReading: file), audio.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 32768) else { return nil }
        let total = audio.length
        var sums = [Double](repeating: 0, count: bars)
        var counts = [Int](repeating: 0, count: bars)
        while audio.framePosition < total {
            let start = audio.framePosition
            do { try audio.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            // Cut at the frames where one bar ends and the next begins, so each
            // piece is summed in one go.
            var cursor = 0
            while cursor < frames {
                let bar = min(bars - 1, Int((start + AVAudioFramePosition(cursor)) * AVAudioFramePosition(bars) / total))
                let barEnd = ((AVAudioFramePosition(bar) + 1) * total + AVAudioFramePosition(bars) - 1) / AVAudioFramePosition(bars)
                let end = bar == bars - 1 ? frames : min(frames, max(cursor + 1, Int(barEnd - start)))
                var squares: Float = 0
                vDSP_svesq(channels[0] + cursor, 1, &squares, vDSP_Length(end - cursor))
                sums[bar] += Double(squares)
                counts[bar] += end - cursor
                cursor = end
            }
        }
        guard counts.contains(where: { $0 > 0 }) else { return nil }
        let loudness = zip(sums, counts).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
        let scale = max(loudness.max() ?? 0, 0.02)
        return loudness.map { UInt8(min(1, $0 / scale) * 255) }
    }
}
