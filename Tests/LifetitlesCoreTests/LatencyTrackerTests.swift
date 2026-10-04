import Testing
@testable import LifetitlesCore

struct LatencyTrackerTests {
    @Test func measuresEachDelayFromTheStartOfSpeech() async {
        let tracker = LatencyTracker()
        let start = ContinuousClock.now

        await tracker.mark(.speechStarted, utterance: 1, at: start)
        await tracker.mark(.languageLocked, utterance: 1, at: start + .milliseconds(900))
        await tracker.mark(.firstTranslation, utterance: 1, at: start + .milliseconds(1_400))

        let report = await tracker.report(for: 1)
        #expect(report?.timeToLanguageLock == Duration.milliseconds(900))
        #expect(report?.timeToFirstTranslation == Duration.milliseconds(1_400))
    }

    @Test func leavesMilestonesThatWereNeverReachedEmpty() async {
        let tracker = LatencyTracker()
        await tracker.mark(.speechStarted, utterance: 1)

        let report = await tracker.report(for: 1)
        #expect(report?.timeToLanguageLock == nil)
        #expect(report?.timeToFirstPartialText == nil)
        #expect(report?.timeToFirstTranslation == nil)
    }

    @Test func hasNoReportWithoutASpeechStart() async {
        let tracker = LatencyTracker()
        await tracker.mark(.languageLocked, utterance: 1)

        #expect(await tracker.report(for: 1) == nil)
        #expect(await tracker.report(for: 2) == nil)
    }

    @Test func keepsUtterancesApartAndInOrder() async {
        let tracker = LatencyTracker()
        await tracker.mark(.speechStarted, utterance: 2)
        await tracker.mark(.speechStarted, utterance: 1)

        let reports = await tracker.allReports()
        #expect(reports.map(\.utterance) == [1, 2])
    }
}
