import Foundation

/// Regroups audio of any buffer size into chunks of one fixed length.
///
/// A microphone delivers buffers whose size depends on the device and the system.
/// The pipeline expects steady chunks (100 ms by default), so a live source feeds
/// whatever it receives into this and passes on the chunks that come out.
public struct ChunkAssembler: Sendable {
    public let samplesPerChunk: Int

    private var pending: [Float] = []
    private var samplesEmitted = 0

    /// - Parameter chunkDuration: The length of each chunk, rounded to a whole number of samples.
    ///   At least one sample.
    public init(chunkDuration: Duration = .milliseconds(100)) {
        self.samplesPerChunk = max(1, chunkDuration.audioSampleCount)
    }

    /// Adds samples and returns every complete chunk now available, oldest first.
    /// Samples that do not fill a chunk are kept for the next call.
    ///
    /// - Parameter capturedAt: When these samples arrived. Every chunk returned from this call
    ///   carries this time, which is when the pipeline first sees it.
    public mutating func append(_ samples: [Float], capturedAt: ContinuousClock.Instant) -> [AudioChunk] {
        pending.append(contentsOf: samples)

        var chunks: [AudioChunk] = []
        var start = 0
        while pending.count - start >= samplesPerChunk {
            let end = start + samplesPerChunk
            chunks.append(AudioChunk(
                samples: Array(pending[start..<end]),
                streamOffset: Duration.audio(sampleCount: samplesEmitted),
                capturedAt: capturedAt
            ))
            samplesEmitted += samplesPerChunk
            start = end
        }
        if start > 0 {
            pending.removeFirst(start)
        }
        return chunks
    }

    /// How many samples are waiting for the rest of their chunk.
    public var pendingSampleCount: Int {
        pending.count
    }
}
