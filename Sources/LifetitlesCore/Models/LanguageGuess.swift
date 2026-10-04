import Foundation

/// How likely each candidate language is to be the one being spoken.
///
/// A guess holds probabilities, not a single answer, so the pipeline can wait
/// for more audio when the top two languages are close.
public struct LanguageGuess: Sendable {
    public let probabilities: [Locale.Language: Double]

    public init(probabilities: [Locale.Language: Double]) {
        self.probabilities = probabilities
    }

    /// The most likely language, or `nil` when there are no candidates.
    public var mostLikely: (language: Locale.Language, probability: Double)? {
        guard let top = probabilities.max(by: { $0.value < $1.value }) else { return nil }
        return (language: top.key, probability: top.value)
    }
}
