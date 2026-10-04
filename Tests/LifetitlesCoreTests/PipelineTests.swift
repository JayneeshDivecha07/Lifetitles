import Foundation
import Testing
@testable import LifetitlesCore

/// Every test here fails after one minute instead of hanging, for example if a stage never ends its stream.
@Suite(.timeLimit(.minutes(1)))
struct PipelineTests {
    /// 0.3 s of silence, 1.5 s of speech, then 1 s of silence.
    private static let oneUtterance = makeChunks(
        repeated(false, times: 3) + repeated(true, times: 15) + repeated(false, times: 10)
    )

    private static func makePipeline(
        chunks: [AudioChunk],
        spokenLanguage: String = "fr",
        languageIdentifier: (any LanguageIdentifier)? = nil,
        translator: any TextTranslator = PrefixTranslator(),
        output: CollectingOutput,
        tracker: LatencyTracker = LatencyTracker(),
        configuration: Pipeline.Configuration = Pipeline.Configuration(),
        onError: @escaping Pipeline.ErrorHandler = { _ in }
    ) -> Pipeline {
        Pipeline(
            audioSource: ScriptedAudioSource(chunks: chunks),
            speechActivityDetector: LevelSpeechDetector(),
            languageIdentifier: languageIdentifier ?? FixedLanguageIdentifier(code: spokenLanguage),
            speechRecognizer: CountingRecognizer(),
            translator: translator,
            output: output,
            latencyTracker: tracker,
            configuration: configuration,
            onError: onError
        )
    }

    // MARK: - The main path

    @Test func translatesFrenchSpeechIntoEnglish() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output)

        try await pipeline.run()

        let shown = await output.translations
        #expect(shown.count == 1)
        #expect(shown.first?.sourceLanguage == Locale.Language(identifier: "fr"))
        #expect(shown.first?.targetLanguage == Locale.Language(identifier: "en"))
        #expect(shown.first?.translatedText.hasPrefix(PrefixTranslator.prefix) == true)
    }

    @Test func replaysAudioHeardBeforeTheLanguageWasKnown() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output)

        try await pipeline.run()

        // The language is locked after about one second of speech. The recogniser must
        // still receive that first second, so the total is well above what arrived afterwards.
        let shown = await output.translations
        #expect(receivedSampleCount(in: shown.first) >= 16_000)
    }

    @Test func includesTheSilenceJustBeforeSpeechStarts() async throws {
        let output = CollectingOutput()
        // The audio ends with the speech, so nothing after it reaches the recogniser
        // and the total can be checked exactly.
        let endsWithSpeech = makeChunks(repeated(false, times: 3) + repeated(true, times: 15))
        let pipeline = Self.makePipeline(chunks: endsWithSpeech, output: output)

        try await pipeline.run()

        // 3 silent chunks (4,800 samples) fit inside the 0.5 s pre-roll, so the recogniser
        // receives them ahead of the 15 speech chunks (24,000 samples).
        let shown = await output.translations
        #expect(receivedSampleCount(in: shown.first) == 4_800 + 24_000)
    }

    @Test func locksTheLanguageAsSoonAsItIsConfident() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output)

        try await pipeline.run()

        // The language is checked once at least 1 s of audio has been heard. The 4,800-sample
        // pre-roll plus 7 speech chunks reach exactly 16,000 samples, and the guess is
        // confident, so that is the audio replayed to the recogniser. Waiting longer would
        // make the replay bigger.
        let shown = await output.translations
        #expect(firstChunkSampleCount(in: shown.first) == 16_000)
    }

    @Test func showsSpeechInTheTargetLanguageWithoutTranslating() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(
            chunks: Self.oneUtterance,
            spokenLanguage: "en",
            translator: ForbiddenTranslator(),
            output: output
        )

        try await pipeline.run()

        let shown = await output.translations
        #expect(shown.count == 1)
        #expect(shown.first?.translatedText == shown.first?.sourceText)
    }

    @Test func translatesIntoAnotherTargetLanguageWhenAsked() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(
            chunks: Self.oneUtterance,
            spokenLanguage: "fr",
            output: output,
            configuration: Pipeline.Configuration(targetLanguage: Locale.Language(identifier: "de"))
        )

        try await pipeline.run()

        let shown = await output.translations
        #expect(shown.first?.targetLanguage == Locale.Language(identifier: "de"))
    }

    // MARK: - Silence and failure

    @Test func showsNothingWhenThereIsOnlySilence() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: makeChunks(repeated(false, times: 20)), output: output)

        try await pipeline.run()

        #expect(await output.translations.isEmpty)
    }

    @Test func dropsAnUtteranceWhenNoLanguageCanBeIdentified() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(
            chunks: Self.oneUtterance,
            languageIdentifier: NoCandidatesLanguageIdentifier(),
            output: output
        )

        try await pipeline.run()

        #expect(await output.translations.isEmpty)
    }

    @Test func reportsATranslationErrorAndStillFinishes() async throws {
        let output = CollectingOutput()
        let errorLog = ErrorLog()
        let pipeline = Self.makePipeline(
            chunks: Self.oneUtterance,
            translator: ForbiddenTranslator(),
            output: output,
            onError: { errorLog.record($0) }
        )

        try await pipeline.run()

        #expect(errorLog.errors.count == 1)
        #expect(await output.translations.isEmpty)
    }

    // MARK: - Language identification

    @Test func usesTheBestGuessWhenConfidenceNeverReachesTheThreshold() async throws {
        let output = CollectingOutput()
        let unsure = ConfigurableLanguageIdentifier(probabilities: ["fr": 0.5, "en": 0.4])
        let fourSecondsOfSpeech = makeChunks(repeated(true, times: 40) + repeated(false, times: 10))
        let pipeline = Self.makePipeline(chunks: fourSecondsOfSpeech, languageIdentifier: unsure, output: output)

        try await pipeline.run()

        // It keeps listening up to the 3 s detection limit (48,000 samples), then commits
        // to the best guess and replays exactly that much audio.
        let shown = await output.translations
        #expect(shown.count == 1)
        #expect(shown.first?.sourceLanguage == Locale.Language(identifier: "fr"))
        #expect(firstChunkSampleCount(in: shown.first) == 48_000)
    }

    @Test func decidesWhenTheUtteranceEndsBeforeTheMinimumDetectionAudio() async throws {
        let output = CollectingOutput()
        let shortSpeech = makeChunks(repeated(true, times: 5) + repeated(false, times: 10))
        let patient = Pipeline.Configuration(
            minimumDetectionAudio: .seconds(5),
            maximumDetectionAudio: .seconds(10)
        )
        let pipeline = Self.makePipeline(chunks: shortSpeech, output: output, configuration: patient)

        try await pipeline.run()

        #expect(await output.translations.count == 1)
    }

    // MARK: - Where the audio stops

    @Test func translatesWhenAudioEndsWhileTheLanguageIsStillUncertain() async throws {
        let output = CollectingOutput()
        let abruptEnd = makeChunks(repeated(true, times: 5))
        let patient = Pipeline.Configuration(
            minimumDetectionAudio: .seconds(5),
            maximumDetectionAudio: .seconds(10)
        )
        let pipeline = Self.makePipeline(chunks: abruptEnd, output: output, configuration: patient)

        try await pipeline.run()

        #expect(await output.translations.count == 1)
    }

    @Test func translatesWhenAudioEndsMidSentence() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: makeChunks(repeated(true, times: 15)), output: output)

        try await pipeline.run()

        #expect(await output.translations.count == 1)
    }

    // MARK: - Several utterances

    @Test func handlesTwoUtterancesSeparatedBySilence() async throws {
        let output = CollectingOutput()
        let twoUtterances = makeChunks(
            repeated(true, times: 15) + repeated(false, times: 12) + repeated(true, times: 15) + repeated(false, times: 12)
        )
        let pipeline = Self.makePipeline(chunks: twoUtterances, output: output)

        try await pipeline.run()

        #expect(await output.translations.count == 2)
    }

    @Test func keepsOneUtteranceAcrossAShortPause() async throws {
        let output = CollectingOutput()
        // A half-second pause is shorter than the 0.8 s silence timeout.
        let withPause = makeChunks(
            repeated(true, times: 10) + repeated(false, times: 5) + repeated(true, times: 10) + repeated(false, times: 12)
        )
        let pipeline = Self.makePipeline(chunks: withPause, output: output)

        try await pipeline.run()

        #expect(await output.translations.count == 1)
    }

    @Test func handlesFiftyUtterancesInARow() async throws {
        let output = CollectingOutput()
        let tracker = LatencyTracker()
        let pattern = (0..<50).flatMap { _ in repeated(true, times: 12) + repeated(false, times: 10) }
        let pipeline = Self.makePipeline(chunks: makeChunks(pattern), output: output, tracker: tracker)

        try await pipeline.run()

        #expect(await output.translations.count == 50)
        #expect(await tracker.allReports().count == 50)
    }

    // MARK: - Latency

    @Test func recordsLatencyForEachMilestone() async throws {
        let output = CollectingOutput()
        let tracker = LatencyTracker()
        let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output, tracker: tracker)

        try await pipeline.run()

        let report = await tracker.report(for: 1)
        #expect(report?.timeToLanguageLock != nil)
        #expect(report?.timeToFirstPartialText != nil)
        #expect(report?.timeToFirstTranslation != nil)
    }

    // MARK: - Stopping and load

    @Test func stopsWhenTheCallingTaskIsCancelled() async throws {
        let pipeline = Pipeline(
            audioSource: EndlessAudioSource(),
            speechActivityDetector: LevelSpeechDetector(),
            languageIdentifier: FixedLanguageIdentifier(code: "fr"),
            speechRecognizer: CountingRecognizer(),
            translator: PrefixTranslator(),
            output: CollectingOutput()
        )

        let running = Task { try await pipeline.run() }
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()

        // Returns only once run() has ended. The suite's time limit fails the test if it never does.
        _ = await running.result
    }

    @Test func keepsConcurrentPipelinesApart() async throws {
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let output = CollectingOutput()
                    let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output)
                    try? await pipeline.run()
                    return await output.translations.count
                }
            }
            var results: [Int] = []
            for await count in group {
                results.append(count)
            }
            return results
        }

        #expect(counts.count == 200)
        #expect(counts.allSatisfy { $0 == 1 })
    }
}
