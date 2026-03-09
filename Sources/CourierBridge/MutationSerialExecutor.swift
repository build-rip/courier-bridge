import Foundation

actor MutationSerialExecutor {
    private var tail: Task<Void, Never> = Task {}

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            _ = await previous.result
            await operation()
        }
    }
}
