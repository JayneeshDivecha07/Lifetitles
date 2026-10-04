import Foundation
import Testing
@testable import LifetitlesCore

// MARK: - ChunkAssembler

struct ChunkAssemblerTests {
    private let now = ContinuousClock.now

    @Test func regroupsOddSizedBuffersIntoWholeChunks() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))
        var chunks: [AudioChunk] = []
        // 5,000 samples in buffers of 700, 1,300, 1,000, 2,000: three whole chunks (4,800) and 200 left over.
        for size in [700, 1_300, 1_000, 2_000] {
            chunks += assembler.append([Float](repeating: 0.5, count: size), capturedAt: now)
        }

        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.samples.count == 1_600 })
        #expect(assembler.pendingSampleCount == 200)
    }

    @Test func numbersChunksByTheirPositionInTheStream() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))
        let chunks = assembler.append([Float](repeating: 0, count: 4_800), capturedAt: now)

        #expect(chunks.map(\.streamOffset) == [
            Duration.zero, Duration.milliseconds(100), Duration.milliseconds(200),
        ])
    }

    @Test func keepsOffsetsContinuousAcrossCalls() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))
        _ = assembler.append([Float](repeating: 0, count: 2_400), capturedAt: now)
        let later = assembler.append([Float](repeating: 0, count: 2_400), capturedAt: now)

        // 2,400 + 2,400 = 4,800 samples: chunks start at 0, 100 ms and 200 ms. The first came from
        // the first call, so the second call returns the chunks starting at 100 ms and 200 ms.
        #expect(later.map(\.streamOffset) == [Duration.milliseconds(100), Duration.milliseconds(200)])
    }

    @Test func keepsTheSampleOrder() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))
        let ramp = (0..<3_200).map { Float($0) }
        let chunks = assembler.append(Array(ramp[0..<1_000]), capturedAt: now)
            + assembler.append(Array(ramp[1_000..<3_200]), capturedAt: now)

        #expect(chunks.flatMap(\.samples) == ramp)
    }

    @Test func returnsNothingUntilAChunkIsFull() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))

        #expect(assembler.append([], capturedAt: now).isEmpty)
        #expect(assembler.append([Float](repeating: 0, count: 1_599), capturedAt: now).isEmpty)
        #expect(assembler.append([0], capturedAt: now).count == 1)
        #expect(assembler.pendingSampleCount == 0)
    }

    @Test func handlesOneHugeBuffer() {
        var assembler = ChunkAssembler(chunkDuration: .milliseconds(100))
        let chunks = assembler.append([Float](repeating: 0, count: 16_000 * 60), capturedAt: now)

        #expect(chunks.count == 600)
        #expect(chunks.last?.streamOffset == Duration.milliseconds(59_900))
    }
}

// MARK: - EnergySpeechDetector

struct EnergySpeechDetectorTests {
    /// Feeds the detector chunks of the given amplitude and returns what it decided for each.
    private func decisions(_ detector: EnergySpeechDetector, amplitude: Float, chunks: Int) async -> [Bool] {
        var result: [Bool] = []
        for index in 0..<chunks {
            let chunk = AudioChunk(
                samples: makeTone(seconds: 0.1, amplitude: amplitude),
                streamOffset: .milliseconds(index * 100),
                capturedAt: ContinuousClock.now
            )
            result.append(await detector.containsSpeech(chunk))
        }
        return result
    }

    @Test func treatsSilenceAsNotSpeech() async {
        let result = await decisions(EnergySpeechDetector(), amplitude: 0, chunks: 20)

        #expect(result.allSatisfy { !$0 })
    }

    @Test func treatsQuietRoomNoiseAsNotSpeech() async {
        // Amplitude 0.004 is about 0.003 RMS, well under the 0.01 minimum.
        let result = await decisions(EnergySpeechDetector(), amplitude: 0.004, chunks: 50)

        #expect(result.allSatisfy { !$0 })
    }

    @Test func detectsSpeechAsSoonAsItStarts() async {
        let detector = EnergySpeechDetector()
        _ = await decisions(detector, amplitude: 0, chunks: 10)
        let result = await decisions(detector, amplitude: 0.3, chunks: 5)

        #expect(result.allSatisfy { $0 })
    }

    @Test func keepsReportingSpeechForTheHangoverThenStops() async {
        let detector = EnergySpeechDetector()
        _ = await decisions(detector, amplitude: 0.3, chunks: 5)
        let afterwards = await decisions(detector, amplitude: 0, chunks: 8)

        // A 300 ms hangover with 100 ms chunks: three more "speech" chunks, then silence.
        #expect(afterwards == [true, true, true, false, false, false, false, false])
    }

    @Test func absorbsModerateSteadyNoiseOnceItHasLastedLongEnough() async {
        let detector = EnergySpeechDetector()
        // Amplitude 0.03 is about 0.021 RMS: louder than the minimum, quieter than the 0.03 ceiling.
        let noise = await decisions(detector, amplitude: 0.03, chunks: 600)

        #expect(noise.first == true)
        #expect(noise.last == false)

        // Speech on top of that noise is still detected.
        let speech = await decisions(detector, amplitude: 0.4, chunks: 3)
        #expect(speech.allSatisfy { $0 })
    }

    @Test func neverAbsorbsVeryLoudSteadyNoise() async {
        // Documented limit: noise above about 0.03 RMS counts as speech however long it lasts.
        let noise = await decisions(EnergySpeechDetector(), amplitude: 0.2, chunks: 1_000)

        #expect(noise.allSatisfy { $0 })
    }

    @Test func detectsEveryBurstOfSpeechInALongConversation() async {
        let detector = EnergySpeechDetector()
        for burst in 1...30 {
            _ = await decisions(detector, amplitude: 0.002, chunks: 10)
            let speech = await decisions(detector, amplitude: 0.1, chunks: 15)
            #expect(speech.first == true, "burst \(burst) was missed")
        }
    }
}

// MARK: - SubtitleTimeline

struct SubtitleTimelineTests {
    private func translation(_ source: String, _ translated: String) -> Translation {
        Translation(
            sourceText: source,
            translatedText: translated,
            sourceLanguage: Locale.Language(identifier: "fr"),
            targetLanguage: Locale.Language(identifier: "en")
        )
    }

    private func update(_ text: String, isFinal: Bool) -> TranscriptUpdate {
        TranscriptUpdate(text: text, isFinal: isFinal, language: Locale.Language(identifier: "fr"))
    }

    @Test func addsLinesOldestFirst() {
        var timeline = SubtitleTimeline()
        timeline.add(translation("un", "one"))
        timeline.add(translation("deux", "two"))

        #expect(timeline.lines.map(\.translatedText) == ["one", "two"])
        #expect(timeline.lines.map(\.sourceText) == ["un", "deux"])
    }

    @Test func dropsTheOldestLinesBeyondTheMaximum() {
        var timeline = SubtitleTimeline(maximumLines: 3)
        for number in 1...5 {
            timeline.add(translation("\(number)", "n\(number)"))
        }

        #expect(timeline.lines.map(\.translatedText) == ["n3", "n4", "n5"])
    }

    @Test func givesEveryLineAUniqueIDThatSurvivesTrimming() {
        var timeline = SubtitleTimeline(maximumLines: 2)
        for number in 1...5 {
            timeline.add(translation("\(number)", "n\(number)"))
        }

        #expect(timeline.lines.map(\.id) == [3, 4])
    }

    @Test func showsPartialTextAndClearsItOnTheFinalUpdate() {
        var timeline = SubtitleTimeline()
        timeline.showRecognisedText(update("bon", isFinal: false))
        #expect(timeline.liveText == "bon")

        timeline.showRecognisedText(update("bonjour", isFinal: false))
        #expect(timeline.liveText == "bonjour")

        timeline.showRecognisedText(update("bonjour", isFinal: true))
        #expect(timeline.liveText == "")
    }

    @Test func clearRemovesEverything() {
        var timeline = SubtitleTimeline()
        timeline.add(translation("un", "one"))
        timeline.showRecognisedText(update("deux", isFinal: false))
        timeline.clear()

        #expect(timeline.lines.isEmpty)
        #expect(timeline.liveText.isEmpty)
    }

    @Test func keepsAtLeastOneLine() {
        var timeline = SubtitleTimeline(maximumLines: 0)
        timeline.add(translation("un", "one"))
        timeline.add(translation("deux", "two"))

        #expect(timeline.maximumLines == 1)
        #expect(timeline.lines.map(\.translatedText) == ["two"])
    }
}

// MARK: - SingleLanguageIdentifier

struct SingleLanguageIdentifierTests {
    @Test func alwaysReportsTheKnownLanguageWithFullConfidence() async throws {
        let french = Locale.Language(identifier: "fr")
        let guess = try await SingleLanguageIdentifier(language: french).identify(audio: [0.1, 0.2])

        #expect(guess.mostLikely?.language == french)
        #expect(guess.mostLikely?.probability == 1.0)
    }
}

// MARK: - The pieces working together

struct KnownLanguagePipelineTests {
    private static let knownLanguage = Pipeline.Configuration(minimumDetectionAudio: .zero)

    private static func makePipeline(
        chunks: [AudioChunk],
        output: CollectingOutput,
        recognizer: any SpeechRecognizer = CountingRecognizer(),
        tracker: LatencyTracker = LatencyTracker()
    ) -> Pipeline {
        Pipeline(
            audioSource: ScriptedAudioSource(chunks: chunks),
            speechActivityDetector: LevelSpeechDetector(),
            languageIdentifier: SingleLanguageIdentifier(language: Locale.Language(identifier: "fr")),
            speechRecognizer: recognizer,
            translator: PrefixTranslator(),
            output: output,
            latencyTracker: tracker,
            configuration: knownLanguage
        )
    }

    private static let oneUtterance = makeChunks(
        repeated(false, times: 3) + repeated(true, times: 15) + repeated(false, times: 10)
    )

    @Test func startsRecognisingAsSoonAsSpeechIsConfirmed() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(chunks: Self.oneUtterance, output: output)

        try await pipeline.run()

        // The language is known, so there is nothing to wait for. Recognition starts on the
        // chunk after speech begins, with the 4,800-sample pre-roll and two speech chunks (3,200).
        let shown = await output.translations
        #expect(firstChunkSampleCount(in: shown.first) == 4_800 + 3_200)
    }

    @Test func showsLiveTextBeforeTheTranslationAndOnlyTranslatesTheFinalText() async throws {
        let output = CollectingOutput()
        let pipeline = Self.makePipeline(
            chunks: Self.oneUtterance,
            output: output,
            recognizer: PartialThenFinalRecognizer()
        )

        try await pipeline.run()

        let updates = await output.recognisedUpdates
        #expect(updates.map(\.text) == ["bon", "bonjour"])
        #expect(updates.map(\.isFinal) == [false, true])

        let shown = await output.translations
        #expect(shown.map(\.sourceText) == ["bonjour"])
    }

    @Test func worksEndToEndWithTheRealDetectorAndAssemblerOnAwkwardBufferSizes() async throws {
        // 1 s of near-silence, 1.5 s of a loud tone, 1.5 s of near-silence, twice over,
        // delivered in buffers of 1,237 samples that do not line up with 100 ms chunks.
        let quiet = makeTone(seconds: 1, amplitude: 0.001)
        let loud = makeTone(seconds: 1.5, amplitude: 0.3)
        let tail = makeTone(seconds: 1.5, amplitude: 0.001)
        let samples = quiet + loud + tail + loud + tail

        let output = CollectingOutput()
        let tracker = LatencyTracker()
        let pipeline = Pipeline(
            audioSource: SamplesAudioSource(samples: samples, bufferSize: 1_237),
            speechActivityDetector: EnergySpeechDetector(),
            languageIdentifier: SingleLanguageIdentifier(language: Locale.Language(identifier: "fr")),
            speechRecognizer: CountingRecognizer(),
            translator: PrefixTranslator(),
            output: output,
            latencyTracker: tracker,
            configuration: Self.knownLanguage
        )

        try await pipeline.run()

        let shown = await output.translations
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { $0.translatedText.hasPrefix(PrefixTranslator.prefix) })
        #expect(await tracker.allReports().count == 2)
    }
}
