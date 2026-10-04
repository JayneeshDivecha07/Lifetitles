import LifetitlesApple
import LifetitlesCore
import SwiftUI
import Translation

struct ContentView: View {
    let engine: LifetitlesEngine

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            subtitles
            liveText
            controls
        }
        .task {
            await engine.prepare()
        }
        // When translation needs a language download, this shows Apple's approval sheet.
        .translationTask(engine.languageDownload) { session in
            await engine.finishLanguageDownload(using: session)
        }
    }

    // MARK: - Pieces

    private var statusBar: some View {
        VStack(spacing: 4) {
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
            if let notice = engine.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var subtitles: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(engine.timeline.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.translatedText)
                            .font(.title2.weight(.semibold))
                        Text(line.sourceText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }

    private var liveText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.timeline.liveText.isEmpty ? " " : engine.timeline.liveText)
                .font(.body.italic())
                .foregroundStyle(.secondary)
            if !engine.latestLatency.isEmpty {
                Text(engine.latestLatency)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var controls: some View {
        switch engine.phase {
        case .failed:
            Button("Try again") {
                Task { await engine.prepare() }
            }
            .buttonStyle(.borderedProminent)
            .padding()
        case .ready:
            Button {
                engine.start()
            } label: {
                Label("Listen", systemImage: "mic.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        case .listening:
            Button {
                engine.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .padding()
        default:
            ProgressView()
                .padding()
        }
    }

    // MARK: - Text

    private var isFailure: Bool {
        if case .failed = engine.phase { return true }
        return false
    }

    private var statusText: String {
        switch engine.phase {
        case .idle:
            return "Starting"
        case .preparing(let step):
            return "\(step)"
        case .needsLanguageDownload:
            return "Approve the language download to continue."
        case .ready:
            return "Ready. Tap Listen, then speak French."
        case .listening:
            return "Listening for French"
        case .failed(let message):
            return message
        }
    }
}
