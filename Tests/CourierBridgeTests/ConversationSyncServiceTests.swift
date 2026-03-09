import Foundation
import GRDB
import Testing
@testable import CourierBridge
@testable import CourierCore

@Suite("Conversation Sync Service")
struct ConversationSyncServiceTests {
    @Test("Startup rebuild persists initial conversation summaries")
    func startupRebuildPersistsInitialConversationSummaries() async throws {
        let fixture = try ConversationSyncFixture()
        defer { fixture.cleanup() }

        try fixture.seedInitialState()

        let service = try makeService(chatDBPath: fixture.chatDBPath, bridgeDBPath: fixture.bridgeDBPath)

        try await service.start()

        let summaries = try await service.conversationSummaries()
        #expect(summaries.count == 1)

        let summary = try #require(summaries.first)
        #expect(summary.conversationID == "chat-1")
        #expect(summary.conversationVersion == BridgeSyncContract.currentConversationVersion)
        #expect(summary.latestEventSequence == 1)
    }

    @Test("Processing source changes reindexes affected conversation")
    func processSourceChangesReindexesAffectedConversation() async throws {
        let fixture = try ConversationSyncFixture()
        defer { fixture.cleanup() }

        try fixture.seedInitialState()

        let service = try makeService(chatDBPath: fixture.chatDBPath, bridgeDBPath: fixture.bridgeDBPath)
        try await service.start()

        try fixture.appendMessage(rowID: 101, guid: "m-2", text: "follow up", dateOffset: 10)
        await service.processSourceChanges()

        let summary = try #require(try await service.conversationSummary(id: "chat-1"))
        #expect(summary.latestEventSequence == 2)

        let events = try await service.fetchEvents(
            conversationID: "chat-1",
            conversationVersion: BridgeSyncContract.currentConversationVersion,
            afterSequence: 1,
            limit: 10
        )
        #expect(events.count == 1)
        #expect(events.first?.eventType == .messageCreated)

        if case .messageCreated(let payload) = try #require(events.first?.payload) {
            #expect(payload.messageID == "m-2")
            #expect(payload.text == "follow up")
        } else {
            Issue.record("Expected messageCreated payload")
        }
    }
}

private func makeService(chatDBPath: String, bridgeDBPath: String) throws -> ConversationSyncService {
    let chatDB = try ChatDatabase(path: chatDBPath)
    let queries = ChatQueries(db: chatDB)
    let bridgeDB = try BridgeDatabase(path: bridgeDBPath)
    let wsController = WebSocketController()
    return ConversationSyncService(
        queries: queries,
        bridgeDB: bridgeDB,
        wsController: wsController,
        conversationVersion: BridgeSyncContract.currentConversationVersion
    )
}

private struct ConversationSyncFixture {
    let chatDBPath: String
    let bridgeDBPath: String

    init() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        chatDBPath = tempDir.appendingPathComponent("chat-sync-tests-\(UUID().uuidString).sqlite").path
        bridgeDBPath = tempDir.appendingPathComponent("bridge-sync-tests-\(UUID().uuidString).sqlite").path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: chatDBPath)
        try? FileManager.default.removeItem(atPath: bridgeDBPath)
    }

    func seedInitialState() throws {
        let dbQueue = try DatabaseQueue(path: chatDBPath)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE chat (
                    guid TEXT NOT NULL,
                    chat_identifier TEXT NOT NULL,
                    display_name TEXT,
                    service_name TEXT,
                    group_id TEXT,
                    last_read_message_timestamp INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE handle (
                    id TEXT NOT NULL,
                    service TEXT,
                    country TEXT
                );

                CREATE TABLE message (
                    guid TEXT NOT NULL,
                    text TEXT,
                    attributedBody BLOB,
                    handle_id INTEGER NOT NULL DEFAULT 0,
                    date INTEGER NOT NULL,
                    date_read INTEGER NOT NULL DEFAULT 0,
                    date_delivered INTEGER NOT NULL DEFAULT 0,
                    is_read INTEGER NOT NULL DEFAULT 0,
                    is_from_me INTEGER NOT NULL DEFAULT 0,
                    service TEXT,
                    associated_message_guid TEXT,
                    associated_message_type INTEGER NOT NULL DEFAULT 0,
                    associated_message_emoji TEXT,
                    reply_to_guid TEXT,
                    part_count INTEGER NOT NULL DEFAULT 0,
                    date_edited INTEGER NOT NULL DEFAULT 0,
                    date_retracted INTEGER NOT NULL DEFAULT 0,
                    date_recovered INTEGER NOT NULL DEFAULT 0,
                    message_action_type INTEGER NOT NULL DEFAULT 0,
                    item_type INTEGER NOT NULL DEFAULT 0,
                    group_title TEXT,
                    is_audio_message INTEGER NOT NULL DEFAULT 0,
                    cache_has_attachments INTEGER NOT NULL DEFAULT 0,
                    balloon_bundle_id TEXT,
                    thread_originator_guid TEXT,
                    payload_data BLOB
                );

                CREATE TABLE chat_message_join (
                    chat_id INTEGER NOT NULL,
                    message_id INTEGER NOT NULL
                );

                CREATE TABLE chat_handle_join (
                    chat_id INTEGER NOT NULL,
                    handle_id INTEGER NOT NULL
                );

                CREATE TABLE attachment (
                    guid TEXT NOT NULL,
                    filename TEXT,
                    mime_type TEXT,
                    transfer_name TEXT,
                    total_bytes INTEGER NOT NULL DEFAULT 0,
                    is_sticker INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE message_attachment_join (
                    message_id INTEGER NOT NULL,
                    attachment_id INTEGER NOT NULL
                );
                """)

            try db.execute(
                sql: "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, service_name) VALUES (1, 'chat-1', 'chat123', 'Test Chat', 'iMessage')"
            )
            try db.execute(sql: "INSERT INTO handle (ROWID, id, service, country) VALUES (1, '+15555550100', 'iMessage', 'US')")
            try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")

            try insertMessage(
                db: db,
                rowID: 100,
                guid: "m-1",
                text: "hello",
                date: AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_000))
            )
        }
    }

    func appendMessage(rowID: Int64, guid: String, text: String, dateOffset: TimeInterval) throws {
        let dbQueue = try DatabaseQueue(path: chatDBPath)
        try dbQueue.write { db in
            try insertMessage(
                db: db,
                rowID: rowID,
                guid: guid,
                text: text,
                date: AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_000 + dateOffset))
            )
        }
    }

    private func insertMessage(db: Database, rowID: Int64, guid: String, text: String, date: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO message (
                    ROWID, guid, text, handle_id, date, date_read, date_delivered, is_read, is_from_me,
                    service, associated_message_type, cache_has_attachments
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [rowID, guid, text, 1, date, 0, 0, 0, 0, "iMessage", 0, 0]
        )
        try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, ?)", arguments: [rowID])
    }
}
