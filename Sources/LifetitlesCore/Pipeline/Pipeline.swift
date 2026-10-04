import Foundation

/// Connects the stages: audio in, translated text out.
///
/// The pipeline treats each stretch of speech as one *utterance*:
/// 1. Silence is held in a short ring buffer, so the start of speech is not lost.
/// 2. When speech starts, audio is collected until the language is identified with
///    enough confidence, or until `Configuration.maximumDetectionAudio` is reached.
/// 3. Everything collected so far is replayed into the speech recogniser, which then
///    receives live audio until `Configuration.silenceTimeout` of silence ends the utterance.
/// 4. Recognised text goes through the segmenter and translator to the output.
///
/// Utterances are recognised and translated concurrently, so a slow translation never
/// stops the pipeline from listening to the next utterance.
public struct Pipeline: Sendable {
    public typealias ErrorHandler = @Sendable (any Error) -> Void

    /// Delays for every utterance so far. See `LatencyTracker.allReports()`.
    public let latencyTracker: LatencyTracker

    private let audioSource: any AudioSource
    private let speechActivityDetector: any SpeechActivityDetector
    private let languageIdentifier: any LanguageIdentifier
    private let speechRecognizer: any SpeechRecognizer
    private let segmenter: any Segmenter
    private let translator: any TextTranslator
    private let output: any OutputSink
    private let configuration: Configuration
    private let onError: ErrorHandler

    /// - Parameter onError: Called when one segment fails to translate. The pipeline carries on
    ///   with the next segment. Errors from the audio source and the language identifier
    ///   are thrown from `run()` instead.
    public init(
        audioSource: any AudioSource,
        speechActivityDetector: any SpeechActivityDetector,
        languageIdentifier: any LanguageIdentifier,
        speechRecognizer: any SpeechRecognizer,
        segmenter: any Segmenter = FinalOnlySegmenter(),
        translator: any TextTranslator,
        output: any OutputSink,
        latencyTracker: LatencyTracker = LatencyTracker(),
        configuration: Configuration = Configuration(),
        onError: @escaping ErrorHandler = { _ in }
    ) {
        self.audioSource = audioSource
        self.speechActivityDetector = speechActivityDetector
        self.languageIdentifier = languageIdentifier
        self.speechRecognizer = speechRecognizer
        self.segmenter = segmenter
        self.translator = translator
        self.output = output
        self.latencyTracker = latencyTracker
        self.configuration = configuration
        self.onError = onError
    }

    /// Listens and translates until the audio source ends or the calling task is cancelled.
    /// Returns once every utterance has been translated and shown.
    ///
    /// - Throws: When the audio source cannot start or language identification fails.
    public func run() async throws {
        let audio = try await audioSource.makeStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var state = State.idle
            var preRoll = AudioRingBuffer(duration: configuration.preRoll)
            var utteranceCount = 0

            for await chunk in audio {
                let isSpeech = await speechActivityDetector.containsSpeech(chunk)

                switch state {
                case .idle:
                    if isSpeech {
                        utteranceCount += 1
                        let detecting = await beginDetecting(utterance: utteranceCount, firstSpeechChunk: chunk, preRoll: preRoll)
                        preRoll.removeAll()
                        state = .detecting(detecting)
                    } else {
                        preRoll.append(chunk.samples)
                    }

                case .detecting(let detecting):
                    switch try await detect(detecting, adding: chunk, isSpeech: isSpeech) {
                    case .keepListening(let updated):
                        state = .detecting(updated)
                    case .languageFound(let updated, let language):
                        let input = await startUtterance(updated, language: language, in: &group)
                        state = .recognising(Recognising(input: input, silence: updated.silence))
                    case .giveUp:
                        state = .idle
                    }

                case .recognising(var recognising):
                    recognising.input.yield(chunk)
                    recognising.silence = isSpeech ? Duration.zero : recognising.silence + chunk.duration
                    state = .recognising(recognising)
                }

                if case .recognising(let recognising) = state, recognising.silence >= configuration.silenceTimeout {
                    recognising.input.finish()
                    state = .idle
                }
            }

            try await finishOpenUtterance(state, in: &group)
        }
    }

    public struct Configuration: Sendable {
        /// The language to translate into. English by default.
        public var targetLanguage: Locale.Language

        /// Audio kept from just before speech was detected, so the first syllable is not lost.
        public var preRoll: Duration

        /// Language identification waits until this much speech has been heard.
        public var minimumDetectionAudio: Duration

        /// After this much speech the pipeline uses the best guess, even if it is not confident.
        public var maximumDetectionAudio: Duration

        /// How long to wait before repeating language identification while still unsure.
        public var detectionInterval: Duration

        /// The probability the top language needs for the pipeline to commit to it early.
        public var confidenceThreshold: Double

        /// How long silence must last before an utterance counts as finished.
        public var silenceTimeout: Duration

        public init(
            targetLanguage: Locale.Language = Locale.Language(identifier: "en"),
            preRoll: Duration = .milliseconds(500),
            minimumDetectionAudio: Duration = .seconds(1),
            maximumDetectionAudio: Duration = .seconds(3),
            detectionInterval: Duration = .milliseconds(500),
            confidenceThreshold: Double = 0.8,
            silenceTimeout: Duration = .milliseconds(800)
        ) {
            self.targetLanguage = targetLanguage
            self.preRoll = preRoll
            self.minimumDetectionAudio = minimumDetectionAudio
            self.maximumDetectionAudio = maximumDetectionAudio
            self.detectionInterval = detectionInterval
            self.confidenceThreshold = confidenceThreshold
            self.silenceTimeout = silenceTimeout
        }
    }

    // MARK: - Starting an utterance

    private func beginDetecting(utterance: Int, firstSpeechChunk chunk: AudioChunk, preRoll: AudioRingBuffer) async -> Detecting {
        await latencyTracker.mark(.speechStarted, utterance: utterance, at: chunk.capturedAt)

        let leadIn = preRoll.snapshot()
        let leadInLength = Duration.audio(sampleCount: leadIn.count)
        return Detecting(
            utterance: utterance,
            startOffset: max(Duration.zero, chunk.streamOffset - leadInLength),
            startedAt: chunk.capturedAt,
            audio: leadIn + chunk.samples,
            silence: Duration.zero,
            lastIdentifiedSampleCount: nil
        )
    }

    // MARK: - Identifying the language

    private func detect(_ detecting: Detecting, adding chunk: AudioChunk, isSpeech: Bool) async throws -> DetectionOutcome {
        var detecting = detecting
        detecting.audio.append(contentsOf: chunk.samples)
        detecting.silence = isSpeech ? Duration.zero : detecting.silence + chunk.duration

        let utteranceEnded = detecting.silence >= configuration.silenceTimeout
        guard shouldIdentify(detecting, utteranceEnded: utteranceEnded) else {
            return .keepListening(detecting)
        }

        detecting.lastIdentifiedSampleCount = detecting.audio.count
        let guess = try await languageIdentifier.identify(audio: detecting.audio)

        // Waiting longer cannot help once the utterance has ended or the audio limit is reached.
        let audioLength = Duration.audio(sampleCount: detecting.audio.count)
        let mustDecide = utteranceEnded || audioLength >= configuration.maximumDetectionAudio

        guard let best = guess.mostLikely else {
            return mustDecide ? .giveUp : .keepListening(detecting)
        }
        if best.probability >= configuration.confidenceThreshold || mustDecide {
            return .languageFound(detecting, best.language)
        }
        return .keepListening(detecting)
    }

    private func shouldIdentify(_ detecting: Detecting, utteranceEnded: Bool) -> Bool {
        if utteranceEnded {
            return true
        }
        let audioLength = Duration.audio(sampleCount: detecting.audio.count)
        guard audioLength >= configuration.minimumDetectionAudio else {
            return false
        }
        guard let lastCount = detecting.lastIdentifiedSampleCount else {
            return true
        }
        return detecting.audio.count - lastCount >= configuration.detectionInterval.audioSampleCount
    }

    // MARK: - Recognising and translating

    /// Starts recognition for one utterance in the background and returns the stream to feed it live audio.
    private func startUtterance(
        _ detecting: Detecting,
        language: Locale.Language,
        in group: inout ThrowingTaskGroup<Void, any Error>
    ) async -> AsyncStream<AudioChunk>.Continuation {
        await latencyTracker.mark(.languageLocked, utterance: detecting.utterance)

        // The recogniser first receives everything heard while the language was still uncertain.
        let (audio, input) = AsyncStream<AudioChunk>.makeStream()
        input.yield(AudioChunk(samples: detecting.audio, streamOffset: detecting.startOffset, capturedAt: detecting.startedAt))

        let utterance = detecting.utterance
        group.addTask { await self.runUtterance(utterance, language: language, audio: audio) }
        return input
    }

    /// Recognises, segments, translates and shows one utterance. Ends when `audio` ends.
    private func runUtterance(_ utterance: Int, language: Locale.Language, audio: AsyncStream<AudioChunk>) async {
        let tracker = latencyTracker
        let output = self.output
        let updates = speechRecognizer
            .transcribe(audio: audio, language: language)
            .onFirstElement { await tracker.mark(.firstPartialText, utterance: utterance) }
            .onEachElement { await output.showRecognisedText($0) }

        var isFirstTranslation = true
        for await segment in segmenter.segments(from: updates) {
            do {
                let translation = try await translateIfNeeded(segment)
                if isFirstTranslation {
                    isFirstTranslation = false
                    await tracker.mark(.firstTranslation, utterance: utterance)
                }
                await output.show(translation)
            } catch {
                onError(error)
            }
        }
    }

    private func translateIfNeeded(_ segment: TextSegment) async throws -> Translation {
        let target = configuration.targetLanguage
        // Speech already in the target language is shown as it is, with no translation engine involved.
        if let code = segment.language.languageCode, code == target.languageCode {
            return Translation(
                sourceText: segment.text,
                translatedText: segment.text,
                sourceLanguage: segment.language,
                targetLanguage: target
            )
        }
        return try await translator.translate(segment, to: target)
    }

    // MARK: - Ending

    /// Handles an utterance that is still open when the audio ends.
    private func finishOpenUtterance(_ state: State, in group: inout ThrowingTaskGroup<Void, any Error>) async throws {
        switch state {
        case .idle:
            return
        case .recognising(let recognising):
            recognising.input.finish()
        case .detecting(let detecting):
            // The audio ended while the language was still uncertain, so use the best guess available.
            guard !Task.isCancelled else { return }
            let guess = try await languageIdentifier.identify(audio: detecting.audio)
            guard let best = guess.mostLikely else { return }
            let input = await startUtterance(detecting, language: best.language, in: &group)
            input.finish()
        }
    }

    // MARK: - State

    private enum State {
        case idle
        case detecting(Detecting)
        case recognising(Recognising)
    }

    /// Speech has started, but the language is not known yet.
    private struct Detecting {
        let utterance: Int
        let startOffset: Duration
        let startedAt: ContinuousClock.Instant
        var audio: [Float]
        var silence: Duration
        var lastIdentifiedSampleCount: Int?
    }

    /// The language is known and the recogniser is receiving live audio.
    private struct Recognising {
        let input: AsyncStream<AudioChunk>.Continuation
        var silence: Duration
    }

    private enum DetectionOutcome {
        case keepListening(Detecting)
        case languageFound(Detecting, Locale.Language)
        case giveUp
    }
}
