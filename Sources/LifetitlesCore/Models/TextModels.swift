import Foundation

/// Text from the speech recogniser. Until `isFinal` is true, later updates may rewrite earlier words.
public struct TranscriptUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let language: Locale.Language

    public init(text: String, isFinal: Bool, language: Locale.Language) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
    }
}

/// Text that the segmenter has judged stable enough to translate.
public struct TextSegment: Sendable, Equatable {
    public let text: String
    public let language: Locale.Language

    public init(text: String, language: Locale.Language) {
        self.text = text
        self.language = language
    }
}

/// A translated segment, kept together with the text it came from.
public struct Translation: Sendable, Equatable {
    public let sourceText: String
    public let translatedText: String
    public let sourceLanguage: Locale.Language
    public let targetLanguage: Locale.Language

    public init(
        sourceText: String,
        translatedText: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}
