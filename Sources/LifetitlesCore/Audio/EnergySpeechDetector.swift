import Foundation

/// A first, simple speech detector: a chunk counts as speech when it is clearly louder
/// than the background noise.
///
/// It works for quiet and moderately noisy rooms. It cannot tell speech from other loud
/// sounds, and steady noise louder than about 0.03 RMS is always treated as speech.
/// Replace it with a model-based detector when that matters. The `SpeechActivityDetector`
/// protocol is the only thing the pipeline depends on.
public actor EnergySpeechDetector: SpeechActivityDetector {
    public struct Configuration: Sendable {
        /// Chunks quieter than this (RMS, on a 0 to 1 scale) are never speech, however quiet the room.
        public var minimumLevel: Float

        /// How many times louder than the background noise a chunk must be to count as speech.
        public var speechToNoiseRatio: Float

        /// The background noise estimate never rises above this, so loud steady noise does not
        /// raise the bar until speech is missed.
        public var maximumNoiseFloor: Float

        /// How long to keep reporting speech after the level drops, so quiet word endings
        /// and short gaps between words do not split an utterance.
        public var hangover: Duration

        /// How fast the noise estimate follows a louder chunk, per chunk (0 to 1). Kept small so
        /// a few seconds of speech barely move it.
        public var noiseFloorRiseRate: Float

        /// How fast the noise estimate follows a quieter chunk, per chunk (0 to 1).
        public var noiseFloorFallRate: Float

        public init(
            minimumLevel: Float = 0.01,
            speechToNoiseRatio: Float = 3,
            maximumNoiseFloor: Float = 0.01,
            hangover: Duration = .milliseconds(300),
            noiseFloorRiseRate: Float = 0.003,
            noiseFloorFallRate: Float = 0.1
        ) {
            self.minimumLevel = minimumLevel
            self.speechToNoiseRatio = speechToNoiseRatio
            self.maximumNoiseFloor = maximumNoiseFloor
            self.hangover = hangover
            self.noiseFloorRiseRate = noiseFloorRiseRate
            self.noiseFloorFallRate = noiseFloorFallRate
        }
    }

    private let configuration: Configuration
    private var noiseFloor: Float = 0
    private var hangoverRemaining: Duration = .zero

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func containsSpeech(_ chunk: AudioChunk) async -> Bool {
        let level = Self.rootMeanSquare(of: chunk.samples)

        // Compare against the noise estimate from before this chunk, then learn from it.
        let threshold = max(configuration.minimumLevel, noiseFloor * configuration.speechToNoiseRatio)
        let isLoudEnough = level >= threshold
        updateNoiseFloor(toward: level)

        if isLoudEnough {
            hangoverRemaining = configuration.hangover
            return true
        }
        if hangoverRemaining > Duration.zero {
            hangoverRemaining = max(Duration.zero, hangoverRemaining - chunk.duration)
            return true
        }
        return false
    }

    private func updateNoiseFloor(toward level: Float) {
        let rate = level > noiseFloor ? configuration.noiseFloorRiseRate : configuration.noiseFloorFallRate
        noiseFloor += (level - noiseFloor) * rate
        noiseFloor = min(noiseFloor, configuration.maximumNoiseFloor)
    }

    /// The loudness of the samples: the square root of the mean of their squares.
    private static func rootMeanSquare(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
