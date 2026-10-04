#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import LifetitlesCore

/// The format every pipeline stage after the audio source uses: 16 kHz, mono, 32-bit float.
enum PipelineAudioFormat {
    static func make() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
    }
}

enum AudioConversionError: Error, LocalizedError {
    case couldNotCreateBuffer
    case conversionFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateBuffer:
            return "Could not allocate memory for converting audio."
        case .conversionFailed(let reason):
            return "Could not convert audio between formats: \(reason)."
        }
    }
}

/// Converts a stream of buffers from one format to another, one buffer at a time.
///
/// The underlying converter keeps its state between calls, so resampling stays smooth
/// across buffer boundaries. Use one instance per stream, and call it from one thread at a time.
final class StreamingAudioConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // Room for the exact ratio plus a few frames, because the resampler can emit slightly more.
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioConversionError.couldNotCreateBuffer
        }

        let handOver = OneShotBuffer(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if let buffer = handOver.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            // No more input for this call. Not the end of the stream, so the converter keeps its state.
            inputStatus.pointee = .noDataNow
            return nil
        }

        if status == .error {
            throw AudioConversionError.conversionFailed(
                reason: conversionError?.localizedDescription ?? "the converter gave no reason"
            )
        }
        return output
    }
}

/// Hands a buffer to the converter once, then nothing.
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        let taken = buffer
        buffer = nil
        return taken
    }
}

extension AVAudioPCMBuffer {
    /// The samples of the first channel, for buffers in 32-bit float format. Empty for other formats.
    var firstChannelSamples: [Float] {
        guard let channel = floatChannelData?[0], frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(frameLength)))
    }
}
#endif
