#if canImport(AVFoundation)
import AVFoundation
import Foundation
import LifetitlesCore
import Testing
@testable import LifetitlesApple

struct FileAudioSourceTests {
    @Test func replaysAOneSecondRecordingAs16kHzMonoChunks() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, sampleRate: 44_100, seconds: 1)

        let source = FileAudioSource(url: url, chunkDuration: .milliseconds(100))
        var chunks: [AudioChunk] = []
        for await chunk in try await source.makeStream() {
            chunks.append(chunk)
        }

        // Resampling can add or drop a few frames, so allow a small margin around 16,000.
        let totalSamples = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(totalSamples - 16_000) < 200)
        #expect(chunks.first?.samples.count == 1_600)
        #expect(chunks.first?.streamOffset == Duration.zero)
        #expect(chunks.dropFirst().first?.streamOffset == Duration.milliseconds(100))
    }

    @Test func rejectsAFileThatDoesNotExist() async {
        let url = Self.temporaryURL()
        let source = FileAudioSource(url: url)

        await #expect(throws: (any Error).self) {
            _ = try await source.makeStream()
        }
    }

    // MARK: - Helpers

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifetitles-test-\(UUID().uuidString).wav")
    }

    /// Writes a 440 Hz tone. Done in its own function so the file is closed
    /// (released) before the test reads it back.
    private static func writeTone(to url: URL, sampleRate: Double, seconds: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(sampleRate) * AVAudioFrameCount(seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let channel = try #require(buffer.floatChannelData?[0])
        let step = Float(2 * Double.pi * 440 / sampleRate)
        for frame in 0..<Int(frameCount) {
            channel[frame] = 0.5 * sin(step * Float(frame))
        }
        try file.write(from: buffer)
    }
}
#endif
