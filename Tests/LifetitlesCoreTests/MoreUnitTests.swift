import Foundation
import Testing
@testable import LifetitlesCore

struct FinalOnlySegmenterTests {
    private func segments(from updates: [TranscriptUpdate]) async -> [TextSegment] {
        let input = AsyncStream<TranscriptUpdate> { continuation in
            for update in updates {
                continuation.yield(update)
            }
            continuation.finish()
        }
        var result: [TextSegment] = []
        for await segment in FinalOnlySegmenter().segments(from: input) {
            result.append(segment)
        }
        return result
    }

    private let french = Locale.Language(identifier: "fr")

    @Test func ignoresPartialUpdates() async {
        let result = await segments(from: [
            TranscriptUpdate(text: "bon", isFinal: false, language: french),
            TranscriptUpdate(text: "bonjour", isFinal: true, language: french),
        ])

        #expect(result == [TextSegment(text: "bonjour", language: french)])
    }

    @Test func trimsWhitespaceAndSkipsEmptyText() async {
        let result = await segments(from: [
            TranscriptUpdate(text: "  salut \n", isFinal: true, language: french),
            TranscriptUpdate(text: "   ", isFinal: true, language: french),
        ])

        #expect(result == [TextSegment(text: "salut", language: french)])
    }

    @Test func keepsSegmentsInSpeakingOrder() async {
        let result = await segments(from: [
            TranscriptUpdate(text: "un", isFinal: true, language: french),
            TranscriptUpdate(text: "deux", isFinal: true, language: french),
            TranscriptUpdate(text: "trois", isFinal: true, language: french),
        ])

        #expect(result.map(\.text) == ["un", "deux", "trois"])
    }
}

struct LanguageGuessTests {
    @Test func picksTheMostProbableLanguage() {
        let guess = LanguageGuess(probabilities: [
            Locale.Language(identifier: "fr"): 0.7,
            Locale.Language(identifier: "en"): 0.2,
            Locale.Language(identifier: "es"): 0.1,
        ])

        #expect(guess.mostLikely?.language == Locale.Language(identifier: "fr"))
        #expect(guess.mostLikely?.probability == 0.7)
    }

    @Test func hasNoMostLikelyLanguageWithoutCandidates() {
        #expect(LanguageGuess(probabilities: [:]).mostLikely == nil)
    }
}

struct DurationAudioTests {
    @Test func convertsSampleCountsToExactDurations() {
        #expect(Duration.audio(sampleCount: 1_600) == Duration.milliseconds(100))
        #expect(Duration.audio(sampleCount: 16_000) == Duration.seconds(1))
        #expect(Duration.audio(sampleCount: 0) == Duration.zero)
    }

    @Test func convertsDurationsBackToSampleCounts() {
        #expect(Duration.milliseconds(100).audioSampleCount == 1_600)
        #expect(Duration.milliseconds(500).audioSampleCount == 8_000)
        #expect(Duration.seconds(3).audioSampleCount == 48_000)
    }

    @Test func eightChunksOfSilenceAddUpToExactlyTheSilenceTimeout() {
        let chunk = makeChunk(index: 0, isSpeech: false)
        let total = (0..<8).reduce(Duration.zero) { sum, _ in sum + chunk.duration }

        #expect(total == Pipeline.Configuration().silenceTimeout)
    }
}
