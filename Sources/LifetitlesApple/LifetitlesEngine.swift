#if canImport(Translation) && canImport(Speech) && canImport(AVFoundation) && !os(visionOS)
import Foundation
import LifetitlesCore
import Observation
@preconcurrency import Translation

/// Everything a screen needs: it prepares the speech and translation models, listens through the
/// microphone, and publishes the subtitles and status for the view to show.
///
/// By default it listens for French and shows English. Use it from SwiftUI like this:
///
///     let engine = LifetitlesEngine()
///     ...
///     .task { await engine.prepare() }
///     .translationTask(engine.languageDownload) { session in
///         await engine.finishLanguageDownload(using: session)
///     }
///     ...
///     engine.start()   // later: engine.stop()
@available(iOS 26.0, macOS 26.0, *)
@MainActor
@Observable
public final class LifetitlesEngine {
    /// Where the engine is in its life.
    public enum Phase: Equatable, Sendable {
        /// Nothing has been prepared yet.
        case idle
        /// Checking or downloading models. The text says which.
        case preparing(String)
        /// The person must approve a language download. See `languageDownload`.
        case needsLanguageDownload
        /// Ready to listen. Call `start()`.
        case ready
        /// Listening and translating.
        case listening
        /// Something went wrong. The text says what and what to try.
        case failed(String)
    }

    public let sourceLanguage: Locale.Language
    public let targetLanguage: Locale.Language

    public private(set) var phase: Phase = .idle

    /// The subtitles and live text to show.
    public private(set) var timeline = SubtitleTimeline()

    /// A problem that did not stop listening, for example one phrase that could not be recognised.
    public private(set) var notice: String?

    /// How long the most recent phrase took, for example "utterance 3: language locked 0.12 s, ...".
    public private(set) var latestLatency = ""

    /// Set when the person must approve a language download. Pass it to SwiftUI's `translationTask`.
    public var languageDownload: TranslationSession.Configuration?

    @ObservationIgnored private var translator: AppleTextTranslator?
    @ObservationIgnored private var listeningTask: Task<Void, Never>?

    public init(
        sourceLanguage: Locale.Language = Locale.Language(identifier: "fr"),
        targetLanguage: Locale.Language = Locale.Language(identifier: "en")
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    // MARK: - Preparing

    /// Checks the speech model and the translation languages, downloading the speech model if needed.
    /// Safe to call again after a failure.
    public func prepare() async {
        switch phase {
        case .idle, .failed:
            break
        default:
            return
        }

        do {
            phase = .preparing("Checking the speech model")
            try await AppleSpeechRecognizer.prepare(for: sourceLanguage)

            phase = .preparing("Checking the translation languages")
            switch await AppleTextTranslator.readiness(from: sourceLanguage, to: targetLanguage) {
            case .ready:
                becomeReady()
            case .needsDownload:
                phase = .needsLanguageDownload
                languageDownload = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
            case .unsupported:
                phase = .failed(
                    "Apple's Translation does not support \(sourceLanguage.minimalIdentifier) to \(targetLanguage.minimalIdentifier) on this device."
                )
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Asks the person to approve the language download. Call this from SwiftUI's `translationTask`,
    /// which provides the session. The session is only valid inside that call.
    public func finishLanguageDownload(using session: TranslationSession) async {
        languageDownload = nil
        do {
            try await session.prepareTranslation()
        } catch {
            phase = .failed("The translation languages were not downloaded: \(error.localizedDescription)")
            return
        }

        if await AppleTextTranslator.readiness(from: sourceLanguage, to: targetLanguage) == .ready {
            becomeReady()
        } else {
            phase = .failed("The translation languages are still not installed. Try again.")
        }
    }

    private func becomeReady() {
        translator = AppleTextTranslator(source: sourceLanguage, target: targetLanguage)
        phase = .ready
    }

    // MARK: - Listening

    /// Starts listening through the microphone. Does nothing unless the engine is ready.
    public func start() {
        guard phase == .ready, let translator else { return }

        timeline.clear()
        notice = nil
        latestLatency = ""
        phase = .listening

        let pipeline = makePipeline(translator: translator, tracker: LatencyTracker())
        listeningTask = Task { [weak self] in
            do {
                try await pipeline.run()
                self?.listeningEnded(error: nil)
            } catch {
                self?.listeningEnded(error: error)
            }
        }
    }

    /// Stops listening. Subtitles stay on screen until the next `start()`.
    public func stop() {
        listeningTask?.cancel()
        listeningTask = nil
        if phase == .listening {
            phase = .ready
        }
    }

    private func listeningEnded(error: (any Error)?) {
        listeningTask = nil
        if let error {
            phase = .failed(error.localizedDescription)
        } else if phase == .listening {
            phase = .ready
        }
    }

    private func makePipeline(translator: AppleTextTranslator, tracker: LatencyTracker) -> Pipeline {
        let reportNotice: @Sendable (any Error) -> Void = { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.notice = message }
        }

        return Pipeline(
            audioSource: MicrophoneAudioSource(),
            speechActivityDetector: EnergySpeechDetector(),
            // The spoken language is fixed, so nothing needs identifying. A minimum of zero
            // starts recognition at once instead of waiting to hear enough audio to decide.
            languageIdentifier: SingleLanguageIdentifier(language: sourceLanguage),
            speechRecognizer: AppleSpeechRecognizer(onError: reportNotice),
            segmenter: FinalOnlySegmenter(),
            translator: translator,
            output: EngineOutput(engine: self, tracker: tracker),
            latencyTracker: tracker,
            configuration: Pipeline.Configuration(
                targetLanguage: targetLanguage,
                minimumDetectionAudio: .zero
            ),
            onError: reportNotice
        )
    }

    // MARK: - Receiving results from the pipeline

    fileprivate func receive(recognisedText update: TranscriptUpdate) {
        timeline.showRecognisedText(update)
    }

    fileprivate func receive(translation: Translation, latency: String) {
        timeline.add(translation)
        latestLatency = latency
    }
}

/// Passes the pipeline's output to the engine, which lives on the main actor.
@available(iOS 26.0, macOS 26.0, *)
private struct EngineOutput: OutputSink {
    let engine: LifetitlesEngine
    let tracker: LatencyTracker

    func show(_ translation: Translation) async {
        let latency = await tracker.allReports().last?.description ?? ""
        await engine.receive(translation: translation, latency: latency)
    }

    func showRecognisedText(_ update: TranscriptUpdate) async {
        await engine.receive(recognisedText: update)
    }
}
#endif
