#if canImport(Speech) && canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import LifetitlesCore
@preconcurrency import Speech

/// Speech recognition that runs on the device, using Apple's `SpeechAnalyzer` (iOS 26 and later).
///
/// Each utterance gets its own analyzer. Audio goes in as the pipeline delivers it, and text comes out
/// while the person is still speaking: tentative text first, then final text for each phrase.
///
/// Call `prepare(for:)` once at launch. It downloads the language model if the device does not have
/// it yet, so the first utterance is not delayed by a download.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public struct AppleSpeechRecognizer: SpeechRecognizer {
    private let onError: @Sendable (any Error) -> Void

    /// - Parameter onError: Called when recognising one utterance fails, for example because the
    ///   language model is missing. The pipeline carries on with the next utterance.
    public init(onError: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.onError = onError
    }

    public func transcribe(
        audio: AsyncStream<AudioChunk>,
        language: Locale.Language
    ) -> AsyncStream<TranscriptUpdate> {
        let onError = self.onError
        return AsyncStream<TranscriptUpdate> { continuation in
            let task = Task {
                do {
                    try await Self.recognise(audio: audio, language: language, into: continuation)
                } catch {
                    if !Task.isCancelled {
                        onError(error)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Makes sure the speech model for `language` is on the device, downloading it if needed.
    ///
    /// - Throws: `SpeechRecognitionError` if speech recognition is unavailable or the language is
    ///   not supported, or an error from the download.
    public static func prepare(for language: Locale.Language) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognitionError.speechRecognitionUnavailable
        }
        let locale = try await supportedLocale(for: language)
        let transcriber = makeTranscriber(locale: locale)
        try await installModelIfNeeded(for: transcriber)
    }

    // MARK: - One utterance

    private static func recognise(
        audio: AsyncStream<AudioChunk>,
        language: Locale.Language,
        into continuation: AsyncStream<TranscriptUpdate>.Continuation
    ) async throws {
        let locale = try await supportedLocale(for: language)
        let transcriber = makeTranscriber(locale: locale)
        try await installModelIfNeeded(for: transcriber)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechRecognitionError.noCompatibleAudioFormat
        }
        guard let pipelineFormat = PipelineAudioFormat.make() else {
            throw SpeechRecognitionError.noCompatibleAudioFormat
        }
        // The analyzer silently produces no text if it is given audio in the wrong format,
        // so anything that differs from what it asked for is converted first.
        let converter: StreamingAudioConverter?
        if formatsMatch(pipelineFormat, analyzerFormat) {
            converter = nil
        } else {
            guard let needed = StreamingAudioConverter(from: pipelineFormat, to: analyzerFormat) else {
                throw SpeechRecognitionError.noCompatibleAudioFormat
            }
            converter = needed
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let results = Task {
            for try await result in transcriber.results {
                continuation.yield(TranscriptUpdate(
                    text: String(result.text.characters),
                    isFinal: result.isFinal,
                    language: language
                ))
            }
        }

        do {
            try await analyzer.start(inputSequence: inputs)

            for await chunk in audio {
                guard let buffer = try makeBuffer(from: chunk, format: pipelineFormat, converter: converter) else {
                    continue
                }
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
            }
            inputBuilder.finish()

            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                return
            }
            // Turns any tentative text into final text before the analyzer closes,
            // so the last words of the utterance are not lost.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
        } catch {
            inputBuilder.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }

    // MARK: - Helpers

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Tentative results while speaking, delivered with a smaller context window for speed.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func supportedLocale(for language: Locale.Language) async throws -> Locale {
        let requested = Locale(identifier: language.minimalIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw SpeechRecognitionError.languageNotSupported(language.minimalIdentifier)
        }
        return locale
    }

    private static func installModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private static func formatsMatch(_ first: AVAudioFormat, _ second: AVAudioFormat) -> Bool {
        first.sampleRate == second.sampleRate
            && first.channelCount == second.channelCount
            && first.commonFormat == second.commonFormat
            && first.isInterleaved == second.isInterleaved
    }

    /// Turns a pipeline chunk into a buffer in the analyzer's format. Returns `nil` for an empty chunk.
    private static func makeBuffer(
        from chunk: AudioChunk,
        format: AVAudioFormat,
        converter: StreamingAudioConverter?
    ) throws -> AVAudioPCMBuffer? {
        guard !chunk.samples.isEmpty else { return nil }

        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else {
            throw AudioConversionError.couldNotCreateBuffer
        }
        buffer.frameLength = frameCount
        chunk.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }

        guard let converter else { return buffer }
        return try converter.convert(buffer)
    }
}

public enum SpeechRecognitionError: Error, LocalizedError {
    case speechRecognitionUnavailable
    case languageNotSupported(String)
    case noCompatibleAudioFormat

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionUnavailable:
            return "On-device speech recognition is not available on this device."
        case .languageNotSupported(let language):
            return "Speech recognition does not support the language \"\(language)\" on this device."
        case .noCompatibleAudioFormat:
            return "Speech recognition did not offer an audio format this app can produce."
        }
    }
}
#endif
