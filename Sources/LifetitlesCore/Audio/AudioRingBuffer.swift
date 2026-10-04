import Foundation

/// Keeps the most recent audio and drops the oldest when full.
///
/// Speech detection reacts a little after someone starts talking. The pipeline keeps
/// the audio just before that moment here, so the first syllable is not lost.
public struct AudioRingBuffer: Sendable {
    public let capacity: Int

    /// The number of samples currently held, never more than `capacity`.
    public private(set) var count = 0

    private var storage: [Float]
    private var writeIndex = 0

    /// - Parameter capacity: The most samples to keep. Must be at least 1.
    public init(capacity: Int) {
        precondition(capacity >= 1, "AudioRingBuffer capacity must be at least 1 sample, got \(capacity)")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// - Parameter duration: How much audio to keep, rounded to the nearest sample, with a minimum of one sample.
    public init(duration: Duration) {
        self.init(capacity: max(1, duration.audioSampleCount))
    }

    public mutating func append(_ samples: [Float]) {
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(count + samples.count, capacity)
    }

    /// Returns the held samples, oldest first.
    public func snapshot() -> [Float] {
        // Until the buffer first fills, samples sit at the start of `storage`.
        // After that, the oldest sample is the one the next write would replace.
        if count < capacity {
            return Array(storage[0..<count])
        }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    public mutating func removeAll() {
        count = 0
        writeIndex = 0
    }
}
