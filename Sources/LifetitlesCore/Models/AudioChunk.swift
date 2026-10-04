import Foundation

/// A short slice of mono audio at `AudioFormat.sampleRate`.
public struct AudioChunk: Sendable {
    public let samples: [Float]

    /// Where the first sample sits within the whole audio stream.
    public let streamOffset: Duration

    /// When the chunk entered the pipeline. Latency is measured from this moment.
    public let capturedAt: ContinuousClock.Instant

    public init(samples: [Float], streamOffset: Duration, capturedAt: ContinuousClock.Instant) {
        self.samples = samples
        self.streamOffset = streamOffset
        self.capturedAt = capturedAt
    }

    public var duration: Duration {
        Duration.audio(sampleCount: samples.count)
    }
}

/// Every stage after the audio source works with audio in this format.
/// Sources that capture at another rate, such as a microphone, convert before they emit.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
}
