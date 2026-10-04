import Foundation

// One protocol per pipeline stage. The pipeline only knows these protocols, so each
// stage can be swapped (on-device or cloud, real or fake) without touching the others.
// Every stage is `Sendable` so it can be shared across the pipeline's concurrent tasks.

/// Supplies audio: a microphone, Bluetooth headphones, smart glasses, or a recorded file.
public protocol AudioSource: Sendable {
    /// Starts the source and returns its audio as 16 kHz mono chunks.
    ///
    /// Stop the source by cancelling the task that reads the stream or by ending the read.
    /// A source that holds hardware must release it when the stream ends.
    ///
    /// - Throws: When the source cannot start, for example because microphone access was denied.
    func makeStream() async throws -> AsyncStream<AudioChunk>
}

/// Tells speech from silence and background noise.
public protocol SpeechActivityDetector: Sendable {
    /// Returns `true` when the chunk contains speech.
    func containsSpeech(_ chunk: AudioChunk) async -> Bool
}

/// Works out which language is being spoken.
public protocol LanguageIdentifier: Sendable {
    /// Returns language probabilities for the audio heard so far in one utterance.
    /// The pipeline calls this repeatedly with a growing amount of audio.
    ///
    /// - Throws: When identification fails. The pipeline stops and passes the error on.
    func identify(audio: [Float]) async throws -> LanguageGuess
}

/// Turns speech in a known language into text while the person is still speaking.
public protocol SpeechRecognizer: Sendable {
    /// Returns text updates for one utterance. The stream must end after the `audio` stream ends.
    func transcribe(audio: AsyncStream<AudioChunk>, language: Locale.Language) -> AsyncStream<TranscriptUpdate>
}

/// Decides which recognised text is stable enough to translate.
public protocol Segmenter: Sendable {
    /// Returns segments to translate, in speaking order. The stream must end after `updates` ends.
    func segments(from updates: AsyncStream<TranscriptUpdate>) -> AsyncStream<TextSegment>
}

/// Translates text into the target language.
public protocol TextTranslator: Sendable {
    /// - Throws: When the language pair is not supported or the translation engine fails.
    ///   The pipeline reports the error and carries on with the next segment.
    func translate(_ segment: TextSegment, to target: Locale.Language) async throws -> Translation
}

/// Shows or speaks the result: subtitles on screen, text on glasses, or synthesised speech.
public protocol OutputSink: Sendable {
    func show(_ translation: Translation) async

    /// Called with text as it is being recognised, before it is translated.
    /// Non-final updates may be rewritten by later ones. Implementing this is optional.
    func showRecognisedText(_ update: TranscriptUpdate) async
}

extension OutputSink {
    public func showRecognisedText(_ update: TranscriptUpdate) async {}
}
