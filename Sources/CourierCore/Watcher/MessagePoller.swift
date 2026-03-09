import Foundation

/// Debounces file watcher notifications into a poll stream.
public actor MessagePoller {
    private var debounceTask: Task<Void, Never>?
    private var continuation: AsyncStream<Void>.Continuation?

    public init() {}

    public func eventStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func onChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.continuation?.yield(())
        }
    }

    public func start() {}

    public func stop() {
        debounceTask?.cancel()
        continuation?.finish()
        continuation = nil
    }
}
