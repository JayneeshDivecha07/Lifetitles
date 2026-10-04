import Foundation

/// The simplest segmenter: it translates only text the recogniser has marked final.
///
/// Text never changes after it is final, so nothing flickers, but subtitles appear
/// only when the recogniser finishes a phrase. Replace it with a segmenter that
/// splits at pauses or sentence ends to show text sooner.
public struct FinalOnlySegmenter: Segmenter {
    public init() {}

    public func segments(from updates: AsyncStream<TranscriptUpdate>) -> AsyncStream<TextSegment> {
        AsyncStream<TextSegment> { continuation in
            let task = Task {
                for await update in updates where update.isFinal {
                    let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    continuation.yield(TextSegment(text: text, language: update.language))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
