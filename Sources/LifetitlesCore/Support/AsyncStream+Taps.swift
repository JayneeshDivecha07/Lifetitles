import Foundation

extension AsyncStream where Element: Sendable {
    /// Returns a stream with the same elements that runs `action` once, when the first element passes through.
    /// The pipeline uses this to timestamp "first text" without changing the stream.
    func onFirstElement(_ action: @escaping @Sendable () async -> Void) -> AsyncStream<Element> {
        AsyncStream<Element> { continuation in
            let task = Task {
                var isFirst = true
                for await element in self {
                    if isFirst {
                        isFirst = false
                        await action()
                    }
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns a stream with the same elements that runs `action` for each one before passing it on.
    /// The pipeline uses this to show live text without changing the stream.
    func onEachElement(_ action: @escaping @Sendable (Element) async -> Void) -> AsyncStream<Element> {
        AsyncStream<Element> { continuation in
            let task = Task {
                for await element in self {
                    await action(element)
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
