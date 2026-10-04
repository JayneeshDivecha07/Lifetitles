import Foundation
#if canImport(os)
import os
#endif

/// Records when each utterance reaches each pipeline milestone and turns the
/// timestamps into delays measured from the moment speech started.
///
/// On Apple platforms every mark is also a signpost, so the delays show up in
/// Instruments (os_signpost) next to CPU and energy use.
public actor LatencyTracker {
    private var marks: [Int: [LatencyEvent: ContinuousClock.Instant]] = [:]

    #if canImport(os)
    private let signposter = OSSignposter(subsystem: "app.lifetitles", category: "pipeline")
    #endif

    public init() {}

    /// Records that `event` happened for the given utterance.
    ///
    /// - Parameter instant: When it happened. Defaults to now. Tests pass fixed instants.
    public func mark(_ event: LatencyEvent, utterance: Int, at instant: ContinuousClock.Instant? = nil) {
        marks[utterance, default: [:]][event] = instant ?? ContinuousClock.now
        emitSignpost(for: event, utterance: utterance)
    }

    /// Returns the delays for one utterance, or `nil` if its speech start was never marked.
    public func report(for utterance: Int) -> LatencyReport? {
        guard let events = marks[utterance], let speechStart = events[.speechStarted] else {
            return nil
        }
        return LatencyReport(
            utterance: utterance,
            timeToLanguageLock: events[.languageLocked].map { speechStart.duration(to: $0) },
            timeToFirstPartialText: events[.firstPartialText].map { speechStart.duration(to: $0) },
            timeToFirstTranslation: events[.firstTranslation].map { speechStart.duration(to: $0) }
        )
    }

    /// Returns the delays for every utterance, in the order they started.
    public func allReports() -> [LatencyReport] {
        marks.keys.sorted().compactMap { report(for: $0) }
    }

    private func emitSignpost(for event: LatencyEvent, utterance: Int) {
        #if canImport(os)
        // Signpost names must be fixed strings, so each event is spelled out.
        switch event {
        case .speechStarted: signposter.emitEvent("speechStarted", "utterance \(utterance)")
        case .languageLocked: signposter.emitEvent("languageLocked", "utterance \(utterance)")
        case .firstPartialText: signposter.emitEvent("firstPartialText", "utterance \(utterance)")
        case .firstTranslation: signposter.emitEvent("firstTranslation", "utterance \(utterance)")
        }
        #endif
    }
}

/// A milestone an utterance passes on its way through the pipeline.
public enum LatencyEvent: Sendable, Hashable {
    case speechStarted
    case languageLocked
    case firstPartialText
    case firstTranslation
}

/// Delays for one utterance, measured from the moment speech started.
/// A value is `nil` when the utterance never reached that milestone.
public struct LatencyReport: Sendable, Equatable, CustomStringConvertible {
    public let utterance: Int
    public let timeToLanguageLock: Duration?
    public let timeToFirstPartialText: Duration?
    public let timeToFirstTranslation: Duration?

    public var description: String {
        "utterance \(utterance): "
            + "language locked \(Self.format(timeToLanguageLock)), "
            + "first text \(Self.format(timeToFirstPartialText)), "
            + "first translation \(Self.format(timeToFirstTranslation))"
    }

    private static func format(_ delay: Duration?) -> String {
        guard let delay else { return "n/a" }
        return String(format: "%.2f s", delay.inSeconds)
    }
}
