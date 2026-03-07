import Foundation

/// Actor that polls the Messages database for new messages using a ROWID cursor.
/// Triggered by FileWatcher notifications, with 250ms debounce.
public actor MessagePoller {
    private let queries: ChatQueries
    private var lastRowID: Int64
    private var lastReadTimestamp: Int64
    private var lastDeliveryTimestamp: Int64
    private var debounceTask: Task<Void, Never>?
    private var continuation: AsyncStream<MessageEvent>.Continuation?
    private var isRunning = false

    public init(queries: ChatQueries) throws {
        self.queries = queries
        self.lastRowID = try queries.maxMessageRowID()
        self.lastReadTimestamp = try queries.maxDateRead()
        self.lastDeliveryTimestamp = try queries.maxDateDelivered()
    }

    /// Create the event stream. Only one stream can be active at a time.
    public func eventStream() -> AsyncStream<MessageEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Called by FileWatcher when a change is detected. Debounces 250ms.
    public func onChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.poll()
        }
    }

    /// Poll for new messages since the last known ROWID.
    private func poll() {
        guard let continuation else { return }

        do {
            let newMessages = try queries.newMessages(afterRowID: lastRowID)

            for message in newMessages {
                let chatRowID = try queries.chatRowID(forMessageRowID: message.rowID)
                guard let chatRowID else { continue }

                let senderID = try queries.resolveSenderID(
                    handleID: message.handleID,
                    isFromMe: message.isFromMe
                )

                if message.isReaction {
                    let event = MessageEvent.reaction(
                        ReactionEventPayload(message: message, chatRowID: chatRowID, senderID: senderID)
                    )
                    continuation.yield(event)
                } else {
                    let event = MessageEvent.newMessage(
                        MessageEventPayload(message: message, chatRowID: chatRowID, senderID: senderID)
                    )
                    continuation.yield(event)
                }

                if message.rowID > lastRowID {
                    lastRowID = message.rowID
                }
            }

            // Check for read receipt changes
            let readChanges = try queries.messagesWithReadChanges(afterTimestamp: lastReadTimestamp)
            for pair in readChanges {
                guard let dateRead = pair.message.dateReadAsDate else { continue }
                let event = MessageEvent.readReceipt(
                    ReadReceiptPayload(message: pair.message, chatRowID: pair.chatRowID, dateRead: dateRead)
                )
                continuation.yield(event)
                if pair.message.dateRead > lastReadTimestamp {
                    lastReadTimestamp = pair.message.dateRead
                }
            }

            // Check for delivery receipt changes
            let deliveryChanges = try queries.messagesWithDeliveryChanges(afterTimestamp: lastDeliveryTimestamp)
            for pair in deliveryChanges {
                guard let dateDelivered = pair.message.dateDeliveredAsDate else { continue }
                let event = MessageEvent.deliveryReceipt(
                    DeliveryReceiptPayload(message: pair.message, chatRowID: pair.chatRowID, dateDelivered: dateDelivered)
                )
                continuation.yield(event)
                if pair.message.dateDelivered > lastDeliveryTimestamp {
                    lastDeliveryTimestamp = pair.message.dateDelivered
                }
            }
        } catch {
            // Log but don't crash on polling errors
            print("[MessagePoller] Error polling: \(error)")
        }
    }

    /// Start polling. Sets up initial state.
    public func start() {
        isRunning = true
    }

    /// Stop polling and clean up.
    public func stop() {
        isRunning = false
        debounceTask?.cancel()
        continuation?.finish()
        continuation = nil
    }

    /// Get the current cursor position for status reporting.
    public func currentRowID() -> Int64 {
        lastRowID
    }
}
