import Foundation

/// A language identifier for when the spoken language is already known.
///
/// It always reports the same language with full confidence. Pair it with
/// `Pipeline.Configuration.minimumDetectionAudio` set to `.zero` so the pipeline
/// does not wait to "detect" a language it was told.
public struct SingleLanguageIdentifier: LanguageIdentifier {
    public let language: Locale.Language

    public init(language: Locale.Language) {
        self.language = language
    }

    public func identify(audio: [Float]) async throws -> LanguageGuess {
        LanguageGuess(probabilities: [language: 1.0])
    }
}
