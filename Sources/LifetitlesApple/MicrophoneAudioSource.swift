#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import LifetitlesCore

/// Live audio from the microphone, or from Bluetooth headphones such as AirPods when they are connected.
///
/// Whatever the hardware delivers (often 48 kHz, sometimes 16 kHz or 24 kHz over Bluetooth) is converted to
/// 16 kHz mono and regrouped into 100 ms chunks. The microphone runs for as long as the stream is being read,
/// and stops when the reader stops or its task is cancelled.
///
/// Not handled yet: phone calls and other apps interrupting the audio, and headphones being
/// connected or removed while listening. Stop and start again after either.
public struct MicrophoneAudioSource: AudioSource {
    public let chunkDuration: Duration

    public init(chunkDuration: Duration = .milliseconds(100)) {
        self.chunkDuration = chunkDuration
    }

    public func makeStream() async throws -> AsyncStream<AudioChunk> {
        try await Self.requestMicrophonePermission()
        try Self.activateAudioSession()

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneError.noInputAvailable
        }
        guard
            let pipelineFormat = PipelineAudioFormat.make(),
            let converter = StreamingAudioConverter(from: inputFormat, to: pipelineFormat)
        else {
            throw MicrophoneError.unsupportedInputFormat
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let tap = TapHandler(
            converter: converter,
            assembler: ChunkAssembler(chunkDuration: chunkDuration),
            continuation: continuation
        )

        // The tap runs on an audio thread. It only touches `tap`, which is built for that.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            tap.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            Self.deactivateAudioSession()
            throw MicrophoneError.engineFailedToStart(reason: error.localizedDescription)
        }

        let runningEngine = RunningEngine(engine)
        continuation.onTermination = { _ in
            runningEngine.stop()
            Self.deactivateAudioSession()
        }
        return stream
    }

    // MARK: - Permission and audio session

    private static func requestMicrophonePermission() async throws {
        #if os(iOS) || os(visionOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw MicrophoneError.permissionDenied
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw MicrophoneError.permissionDenied
            }
        @unknown default:
            throw MicrophoneError.permissionDenied
        }
        #endif
    }

    private static func activateAudioSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord, so spoken translations can be added later without changing this.
            // Bluetooth HFP is what lets AirPods and other headsets act as the microphone.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw MicrophoneError.audioSessionFailed(reason: error.localizedDescription)
        }
        #endif
    }

    private static func deactivateAudioSession() {
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

public enum MicrophoneError: Error, LocalizedError {
    case permissionDenied
    case noInputAvailable
    case unsupportedInputFormat
    case audioSessionFailed(reason: String)
    case engineFailedToStart(reason: String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone."
        case .noInputAvailable:
            return "No microphone is available. Connect headphones with a microphone or check that nothing else is using it."
        case .unsupportedInputFormat:
            return "The microphone uses an audio format this app cannot convert."
        case .audioSessionFailed(let reason):
            return "Could not set up audio for recording: \(reason)."
        case .engineFailedToStart(let reason):
            return "Could not start the microphone: \(reason)."
        }
    }
}

/// Receives each buffer from the microphone, converts it and passes on finished chunks.
/// The microphone calls `handle` one buffer at a time, so the lock only guards against `deinit` races.
private final class TapHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: StreamingAudioConverter
    private var assembler: ChunkAssembler
    private let continuation: AsyncStream<AudioChunk>.Continuation

    init(
        converter: StreamingAudioConverter,
        assembler: ChunkAssembler,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        self.converter = converter
        self.assembler = assembler
        self.continuation = continuation
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        // A buffer that fails to convert is dropped. The next one is unaffected.
        guard let converted = try? converter.convert(buffer) else { return }
        let samples = converted.firstChannelSamples
        guard !samples.isEmpty else { return }

        for chunk in assembler.append(samples, capturedAt: ContinuousClock.now) {
            continuation.yield(chunk)
        }
    }
}

/// Lets the stream's termination handler stop the engine without capturing it directly.
private final class RunningEngine: @unchecked Sendable {
    private let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
#endif
