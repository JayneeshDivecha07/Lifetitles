#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import LifetitlesCore

/// Replays a recorded audio file as if it were live.
///
/// A microphone never gives the same audio twice, so this source is what makes
/// latency and accuracy measurable: the same clip goes through the same pipeline
/// every run. It reads the whole file into memory, so use short test clips.
public struct FileAudioSource: AudioSource {
    public let url: URL

    /// How much audio each chunk holds.
    public let chunkDuration: Duration

    /// When `true`, chunks arrive at the speed of real time, like a microphone.
    /// When `false`, they arrive as fast as the pipeline reads them, which suits unit tests.
    public let isPaced: Bool

    public init(url: URL, chunkDuration: Duration = .milliseconds(100), isPaced: Bool = false) {
        self.url = url
        self.chunkDuration = chunkDuration
        self.isPaced = isPaced
    }

    public func makeStream() async throws -> AsyncStream<AudioChunk> {
        let samples = try Self.loadMono16kHzSamples(from: url)
        let samplesPerChunk = max(1, chunkDuration.audioSampleCount)
        let chunkDuration = self.chunkDuration
        let isPaced = self.isPaced

        return AsyncStream<AudioChunk> { continuation in
            let task = Task {
                let clock = ContinuousClock()
                var start = 0
                while start < samples.count, !Task.isCancelled {
                    let end = min(start + samplesPerChunk, samples.count)
                    continuation.yield(AudioChunk(
                        samples: Array(samples[start..<end]),
                        streamOffset: Duration.audio(sampleCount: start),
                        capturedAt: clock.now
                    ))
                    start = end
                    if isPaced {
                        try? await Task.sleep(for: chunkDuration)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the file and converts it to mono audio at `AudioFormat.sampleRate`.
    private static func loadMono16kHzSamples(from url: URL) throws -> [Float] {
        let fileName = url.lastPathComponent
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        guard file.length > 0 else {
            throw FileAudioSourceError.emptyFile(fileName: fileName)
        }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw FileAudioSourceError.unsupportedFormat(fileName: fileName)
        }

        let inputFrameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            throw FileAudioSourceError.unsupportedFormat(fileName: fileName)
        }
        try file.read(into: inputBuffer)

        // Extra room because the resampler can emit a few frames more than the exact ratio.
        let rateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(inputFrameCount) * rateRatio).rounded(.up)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw FileAudioSourceError.unsupportedFormat(fileName: fileName)
        }

        let input = ConversionInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if input.wasHandedOver {
                inputStatus.pointee = .endOfStream
                return nil
            }
            input.wasHandedOver = true
            inputStatus.pointee = .haveData
            return input.buffer
        }

        guard status != .error, let channel = outputBuffer.floatChannelData?[0] else {
            let reason = conversionError?.localizedDescription ?? "the converter gave no reason"
            throw FileAudioSourceError.conversionFailed(fileName: fileName, reason: reason)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}

/// Hands the whole input buffer to the converter once, then reports the end of the stream.
/// A class, not a captured variable, because the converter's callback can run on another thread
/// and Swift 6 rejects mutating a captured variable there. The converter calls it one at a time.
private final class ConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasHandedOver = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public enum FileAudioSourceError: Error, LocalizedError {
    case emptyFile(fileName: String)
    case unsupportedFormat(fileName: String)
    case conversionFailed(fileName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile(let fileName):
            return "\(fileName) contains no audio. Use a recording that lasts at least a fraction of a second."
        case .unsupportedFormat(let fileName):
            return "Could not read the audio format of \(fileName). Use a WAV, M4A or MP3 recording."
        case .conversionFailed(let fileName, let reason):
            return "Could not convert \(fileName) to 16 kHz mono audio: \(reason)."
        }
    }
}
#endif
