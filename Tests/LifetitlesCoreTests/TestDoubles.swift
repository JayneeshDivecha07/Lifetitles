import Foundation
@testable import LifetitlesCore

// Small fake stages. Each does one predictable thing, so a test can say exactly
// what the pipeline should produce.

/// Builds 100 ms of audio: a steady tone when `isSpeech` is true, silence otherwise.
func makeChunk(index: Int, isSpeech: Bool) -> AudioChunk {
    let samplesPerChunk = 1_600
    return AudioChunk(
        samples: [Float](repeating: isSpeech ? 0.5 : 0, count: samplesPerChunk),
        streamOffset: .milliseconds(index * 100),
        capturedAt: ContinuousClock.now
    )
}

/// Builds chunks from a pattern of speech (`true`) and silence (`false`), 100 ms each.
func makeChunks(_ pattern: [Bool]) -> [AudioChunk] {
    pattern.enumerated().map { index, isSpeech in
        makeChunk(index: index, isSpeech: isSpeech)
    }
}

func repeated(_ isSpeech: Bool, times: Int) -> [Bool] {
    [Bool](repeating: isSpeech, count: times)
}

/// The numbers in `CountingRecognizer`'s text, in order: total samples, then first chunk size.
private func countingRecognizerNumbers(in translation: Translation?) -> [Int] {
    translation?.sourceText
        .split(separator: " ")
        .compactMap { Int($0) } ?? []
}

/// Total samples the recogniser received, or 0 if there is no translation.
func receivedSampleCount(in translation: Translation?) -> Int {
    countingRecognizerNumbers(in: translation).first ?? 0
}

/// Size of the first chunk the recogniser received, or 0 if there is no translation.
/// That chunk is the replay of everything heard before the language was locked.
func firstChunkSampleCount(in translation: Translation?) -> Int {
    let numbers = countingRecognizerNumbers(in: translation)
    return numbers.count > 1 ? numbers[1] : 0
}

struct ScriptedAudioSource: AudioSource {
    let chunks: [AudioChunk]

    func makeStream() async throws -> AsyncStream<AudioChunk> {
        AsyncStream<AudioChunk> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

/// Produces a speech chunk every 10 ms until whoever reads it stops.
struct EndlessAudioSource: AudioSource {
    func makeStream() async throws -> AsyncStream<AudioChunk> {
        AsyncStream<AudioChunk> { continuation in
            let task = Task {
                var index = 0
                while !Task.isCancelled {
                    continuation.yield(makeChunk(index: index, isSpeech: true))
                    index += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Treats any chunk with a loud enough sample as speech.
struct LevelSpeechDetector: SpeechActivityDetector {
    func containsSpeech(_ chunk: AudioChunk) async -> Bool {
        chunk.samples.contains { abs($0) > 0.1 }
    }
}

/// Always reports the same language with high confidence.
struct FixedLanguageIdentifier: LanguageIdentifier {
    let code: String

    func identify(audio: [Float]) async throws -> LanguageGuess {
        LanguageGuess(probabilities: [
            Locale.Language(identifier: code): 0.95,
            Locale.Language(identifier: "xx"): 0.05,
        ])
    }
}

/// Always reports the same probabilities, whatever audio it hears.
struct ConfigurableLanguageIdentifier: LanguageIdentifier {
    let probabilities: [String: Double]

    func identify(audio: [Float]) async throws -> LanguageGuess {
        LanguageGuess(probabilities: Dictionary(
            uniqueKeysWithValues: probabilities.map { (Locale.Language(identifier: $0.key), $0.value) }
        ))
    }
}

/// Reports no candidate languages at all.
struct NoCandidatesLanguageIdentifier: LanguageIdentifier {
    func identify(audio: [Float]) async throws -> LanguageGuess {
        LanguageGuess(probabilities: [:])
    }
}

/// Counts the samples it receives and reports the total, and the size of the first chunk,
/// as one final transcript. The first chunk is the replay of audio heard before the language
/// was locked, so its size shows exactly when the pipeline decided.
struct CountingRecognizer: SpeechRecognizer {
    static let prefix = "received"

    func transcribe(audio: AsyncStream<AudioChunk>, language: Locale.Language) -> AsyncStream<TranscriptUpdate> {
        AsyncStream<TranscriptUpdate> { continuation in
            let task = Task {
                var total = 0
                var firstChunk: Int?
                for await chunk in audio {
                    if firstChunk == nil {
                        firstChunk = chunk.samples.count
                    }
                    total += chunk.samples.count
                }
                continuation.yield(TranscriptUpdate(
                    text: "\(Self.prefix) \(total) samples, first chunk \(firstChunk ?? 0) samples",
                    isFinal: true,
                    language: language
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct PrefixTranslator: TextTranslator {
    static let prefix = "translated:"

    func translate(_ segment: TextSegment, to target: Locale.Language) async throws -> Translation {
        Translation(
            sourceText: segment.text,
            translatedText: "\(Self.prefix) \(segment.text)",
            sourceLanguage: segment.language,
            targetLanguage: target
        )
    }
}

/// Fails the test run if the pipeline asks it to translate anything.
struct ForbiddenTranslator: TextTranslator {
    struct WasCalled: Error {}

    func translate(_ segment: TextSegment, to target: Locale.Language) async throws -> Translation {
        throw WasCalled()
    }
}

actor CollectingOutput: OutputSink {
    private(set) var translations: [Translation] = []
    private(set) var recognisedUpdates: [TranscriptUpdate] = []

    func show(_ translation: Translation) async {
        translations.append(translation)
    }

    func showRecognisedText(_ update: TranscriptUpdate) async {
        recognisedUpdates.append(update)
    }
}

/// Remembers the errors the pipeline reports.
final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrors: [any Error] = []

    func record(_ error: any Error) {
        lock.withLock { storedErrors.append(error) }
    }

    var errors: [any Error] {
        lock.withLock { storedErrors }
    }
}

/// Reports one partial update, then one final update, for every utterance.
struct PartialThenFinalRecognizer: SpeechRecognizer {
    func transcribe(audio: AsyncStream<AudioChunk>, language: Locale.Language) -> AsyncStream<TranscriptUpdate> {
        AsyncStream<TranscriptUpdate> { continuation in
            let task = Task {
                for await _ in audio {}
                continuation.yield(TranscriptUpdate(text: "bon", isFinal: false, language: language))
                continuation.yield(TranscriptUpdate(text: "bonjour", isFinal: true, language: language))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Plays raw samples through a `ChunkAssembler` in buffers of an awkward size,
/// the way a microphone delivers audio that does not line up with 100 ms chunks.
struct SamplesAudioSource: AudioSource {
    let samples: [Float]
    let bufferSize: Int

    func makeStream() async throws -> AsyncStream<AudioChunk> {
        AsyncStream<AudioChunk> { continuation in
            var assembler = ChunkAssembler()
            var start = 0
            while start < samples.count {
                let end = min(start + bufferSize, samples.count)
                for chunk in assembler.append(Array(samples[start..<end]), capturedAt: ContinuousClock.now) {
                    continuation.yield(chunk)
                }
                start = end
            }
            continuation.finish()
        }
    }
}

/// A steady 440 Hz tone, or silence when `amplitude` is 0. Its loudness (RMS) is about 0.7 x `amplitude`.
func makeTone(seconds: Double, amplitude: Float) -> [Float] {
    let count = Int(seconds * AudioFormat.sampleRate)
    let step = Float(2 * Double.pi * 440 / AudioFormat.sampleRate)
    return (0..<count).map { amplitude * sin(step * Float($0)) }
}
