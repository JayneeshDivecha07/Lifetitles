import Foundation

extension Duration {
    /// This duration as a fractional number of seconds.
    package var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// How many samples of audio at `AudioFormat.sampleRate` last this long, rounded to the nearest sample.
    package var audioSampleCount: Int {
        Int((inSeconds * AudioFormat.sampleRate).rounded())
    }

    /// The length of `sampleCount` samples of audio at `AudioFormat.sampleRate`.
    package static func audio(sampleCount: Int) -> Duration {
        // Whole nanoseconds, not fractional seconds, so 1,600 samples equal exactly 100 ms
        // and a run of silent chunks adds up to exactly the silence timeout.
        let nanoseconds = (Double(sampleCount) * 1_000_000_000 / AudioFormat.sampleRate).rounded()
        return Duration.nanoseconds(Int64(nanoseconds))
    }
}
