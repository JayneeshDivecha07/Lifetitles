#if canImport(Translation) && !os(visionOS)
import Foundation
import LifetitlesCore
@preconcurrency import Translation

/// Whether a language pair can be translated right now.
public enum TranslationReadiness: Equatable, Sendable {
    /// Both languages are on the device. Translation works offline.
    case ready
    /// Supported, but the language data must be downloaded first, which needs the person's approval.
    case needsDownload
    /// Not supported by Apple's Translation framework.
    case unsupported
}

/// Translation that runs on the device, using Apple's Translation framework (iOS 26 and later).
///
/// One translator handles one language pair. The languages must already be installed: call
/// `readiness(from:to:)` first, and if the answer is `.needsDownload`, use SwiftUI's
/// `translationTask` with `prepareTranslation()` to ask the person to approve the download.
///
/// Apple's Translation framework does not list visionOS as supported, so this type is not built
/// there. A Vision Pro app needs a different `TextTranslator`.
@available(iOS 26.0, macOS 26.0, *)
public actor AppleTextTranslator: TextTranslator {
    private let session: TranslationSession
    private let source: Locale.Language
    private let target: Locale.Language

    public init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
        if #available(iOS 26.4, macOS 26.4, *) {
            // The faster of Apple's two strategies, which suits live subtitles.
            self.session = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            self.session = TranslationSession(installedSource: source, target: target)
        }
    }

    public func translate(_ segment: TextSegment, to target: Locale.Language) async throws -> Translation {
        guard Self.isSameLanguage(segment.language, source), Self.isSameLanguage(target, self.target) else {
            throw AppleTranslationError.wrongLanguagePair(
                expected: "\(source.minimalIdentifier) to \(self.target.minimalIdentifier)",
                requested: "\(segment.language.minimalIdentifier) to \(target.minimalIdentifier)"
            )
        }
        let response = try await session.translate(segment.text)
        return Translation(
            sourceText: segment.text,
            translatedText: response.targetText,
            sourceLanguage: segment.language,
            targetLanguage: target
        )
    }

    /// Whether Apple can translate this pair now, later after a download, or never.
    public static func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            return .ready
        case .supported:
            return .needsDownload
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    private static func isSameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        first.languageCode != nil && first.languageCode == second.languageCode
    }
}

public enum AppleTranslationError: Error, LocalizedError {
    case wrongLanguagePair(expected: String, requested: String)

    public var errorDescription: String? {
        switch self {
        case .wrongLanguagePair(let expected, let requested):
            return "This translator handles \(expected), but was asked for \(requested)."
        }
    }
}
#endif
