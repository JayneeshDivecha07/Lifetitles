import Foundation

/// One finished subtitle: what was said and its translation.
public struct SubtitleLine: Sendable, Equatable, Identifiable {
    public let id: Int
    public let sourceText: String
    public let translatedText: String
}

/// What a subtitle screen shows: the most recent finished lines, plus the words being
/// recognised right now.
///
/// This holds no user-interface code, so any screen (iPhone, Vision Pro, glasses) can use it
/// and its behaviour is tested without a screen.
public struct SubtitleTimeline: Sendable, Equatable {
    /// Finished subtitles, oldest first. Never more than `maximumLines`.
    public private(set) var lines: [SubtitleLine] = []

    /// Words recognised so far in the phrase being spoken, before translation. Empty when
    /// nothing is being said. This text can change as recognition improves.
    public private(set) var liveText = ""

    public let maximumLines: Int

    private var nextID = 0

    /// - Parameter maximumLines: How many finished lines to keep. At least 1.
    public init(maximumLines: Int = 6) {
        self.maximumLines = max(1, maximumLines)
    }

    /// Shows recognised text as it arrives. A final update clears the live text, because the
    /// finished phrase is about to arrive as a translated line.
    public mutating func showRecognisedText(_ update: TranscriptUpdate) {
        liveText = update.isFinal ? "" : update.text
    }

    /// Adds a finished, translated line and drops the oldest if there are too many.
    public mutating func add(_ translation: Translation) {
        lines.append(SubtitleLine(
            id: nextID,
            sourceText: translation.sourceText,
            translatedText: translation.translatedText
        ))
        nextID += 1
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }

    /// Removes every line and the live text.
    public mutating func clear() {
        lines = []
        liveText = ""
    }
}
