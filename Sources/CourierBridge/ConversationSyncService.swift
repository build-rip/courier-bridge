import CourierCore
import Foundation

struct SourcePollCursor: Sendable {
    let messageRowID: Int64
    let readTimestamp: Int64
    let deliveryTimestamp: Int64
    let editedTimestamp: Int64
    let retractedTimestamp: Int64
    let recoveredTimestamp: Int64
}

actor ConversationSyncService {
    private let queries: ChatQueries
    private let bridgeDB: BridgeDatabase
    private let wsController: WebSocketController
    private let indexer: ConversationIndexer
    private var sourceCursor: SourcePollCursor?
    private var isStarted = false

    init(
        queries: ChatQueries,
        bridgeDB: BridgeDatabase,
        wsController: WebSocketController,
        conversationVersion: Int
    ) {
        self.queries = queries
        self.bridgeDB = bridgeDB
        self.wsController = wsController
        self.indexer = ConversationIndexer(conversationVersion: conversationVersion)
    }

    func start() async throws {
        guard !isStarted else { return }

        let snapshots = try queries.allConversationSnapshots()
        let indexedConversations = try snapshots.map(indexer.index)
        try bridgeDB.replaceAllConversationIndexes(indexedConversations)
        sourceCursor = try currentSourceCursor()
        isStarted = true
    }

    func processSourceChanges() async {
        do {
            try await start()

            let previousCursor = sourceCursor ?? SourcePollCursor(
                messageRowID: 0,
                readTimestamp: 0,
                deliveryTimestamp: 0,
                editedTimestamp: 0,
                retractedTimestamp: 0,
                recoveredTimestamp: 0
            )
            let currentCursor = try currentSourceCursor()
            let affectedChatRowIDs = try queries.affectedChatRowIDs(
                messageAfterRowID: previousCursor.messageRowID,
                readChangedAfterTimestamp: previousCursor.readTimestamp,
                deliveryChangedAfterTimestamp: previousCursor.deliveryTimestamp,
                editedChangedAfterTimestamp: previousCursor.editedTimestamp,
                retractedChangedAfterTimestamp: previousCursor.retractedTimestamp,
                recoveredChangedAfterTimestamp: previousCursor.recoveredTimestamp
            )
            sourceCursor = currentCursor

            guard !affectedChatRowIDs.isEmpty else { return }

            var updatedSummaries: [StoredConversationSummary] = []
            for chatRowID in affectedChatRowIDs.sorted() {
                guard let snapshot = try queries.conversationSnapshot(forChatRowID: chatRowID) else { continue }
                let indexedConversation = try indexer.index(snapshot: snapshot)
                try bridgeDB.replaceConversationIndex(indexedConversation)
                if let summary = try bridgeDB.conversationSummary(id: snapshot.conversation.conversationID) {
                    updatedSummaries.append(summary)
                }
            }

            for summary in updatedSummaries {
                await wsController.broadcast(
                    cursorUpdate: ConversationCursorUpdate(
                        conversationID: summary.conversationID,
                        conversationVersion: summary.conversationVersion,
                        latestEventSequence: summary.latestEventSequence
                    )
                )
            }
        } catch {
            print("[ConversationSyncService] Error processing source changes: \(error)")
        }
    }

    func conversationSummaries() throws -> [StoredConversationSummary] {
        try bridgeDB.listConversationSummaries()
    }

    func conversationSummary(id: String) throws -> StoredConversationSummary? {
        try bridgeDB.conversationSummary(id: id)
    }

    func fetchEvents(
        conversationID: String,
        conversationVersion: Int,
        afterSequence: Int64,
        limit: Int
    ) throws -> [NormalizedConversationEvent] {
        try bridgeDB.fetchConversationEvents(
            conversationID: conversationID,
            conversationVersion: conversationVersion,
            afterSequence: afterSequence,
            limit: limit
        )
    }

    func currentCursorUpdate(conversationID: String) throws -> ConversationCursorUpdate? {
        guard let summary = try bridgeDB.conversationSummary(id: conversationID) else { return nil }
        return ConversationCursorUpdate(
            conversationID: summary.conversationID,
            conversationVersion: summary.conversationVersion,
            latestEventSequence: summary.latestEventSequence
        )
    }

    private func currentSourceCursor() throws -> SourcePollCursor {
        SourcePollCursor(
            messageRowID: try queries.maxMessageRowID(),
            readTimestamp: try queries.maxDateRead(),
            deliveryTimestamp: try queries.maxDateDelivered(),
            editedTimestamp: try queries.maxDateEdited(),
            retractedTimestamp: try queries.maxDateRetracted(),
            recoveredTimestamp: try queries.maxDateRecovered()
        )
    }
}
