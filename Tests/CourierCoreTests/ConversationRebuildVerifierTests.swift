import Foundation
import GRDB
import Testing
@testable import CourierCore

@Suite("Conversation Rebuild Verifier")
struct ConversationRebuildVerifierTests {
    @Test("Stable hashes across repeated rebuilds")
    func stableHashesAcrossRebuilds() throws {
        let fixture = try ChatDBFixture()
        defer { fixture.cleanup() }

        try fixture.seed()

        let queries = ChatQueries(db: try ChatDatabase(path: fixture.path))
        let verifier = ConversationRebuildVerifier(queries: queries, conversationVersion: 7)
        let report = try verifier.verifyStableRebuilds(passes: 3)

        #expect(report.isStable)
        #expect(report.runs.count == 3)

        let indexedConversation = try #require(report.runs.first?.indexedConversations.first)
        #expect(indexedConversation.latestEventSequence == 10)
        #expect(indexedConversation.events.count == 10)
        #expect(indexedConversation.events.first?.eventType == .messageCreated)

        let messagesByID = Dictionary(
            uniqueKeysWithValues: indexedConversation.reducedState.messages.map { ($0.messageID, $0) }
        )

        let editedMessage = try #require(messagesByID["m-2"])
        #expect(editedMessage.editedAt != nil)
        #expect(editedMessage.reactions.isEmpty)

        let deletedMessage = try #require(messagesByID["m-3"])
        #expect(deletedMessage.deletedAt != nil)

        let recoveredMessage = try #require(messagesByID["m-4"])
        #expect(recoveredMessage.deletedAt == nil)

        let outgoingMessage = try #require(messagesByID["m-1"])
        #expect(outgoingMessage.attachments.count == 1)
        #expect(outgoingMessage.deliveredAt != nil)
        #expect(outgoingMessage.readAt != nil)
    }

    @Test("Diagnostics capture mutation-related source buckets")
    func diagnosticsCaptureSpecialBuckets() throws {
        let fixture = try ChatDBFixture()
        defer { fixture.cleanup() }

        try fixture.seed()

        let queries = ChatQueries(db: try ChatDatabase(path: fixture.path))
        let verifier = ConversationRebuildVerifier(queries: queries, conversationVersion: 7)
        let run = try verifier.rebuildAll()

        #expect(run.diagnostics.editedCount == 1)
        #expect(run.diagnostics.retractedCount == 2)
        #expect(run.diagnostics.recoveredCount == 1)
        #expect(run.diagnostics.associatedMessageTypeBuckets == [
            SourceValueBucket(value: 1000, count: 1),
            SourceValueBucket(value: 2001, count: 1),
            SourceValueBucket(value: 3001, count: 1),
            SourceValueBucket(value: 4000, count: 1),
        ])
        #expect(run.diagnostics.itemTypeBuckets == [SourceValueBucket(value: 42, count: 1)])
        #expect(run.diagnostics.messageActionTypeBuckets == [SourceValueBucket(value: 7, count: 1)])
        #expect(run.diagnostics.unknownAssociatedMessageTypeBuckets == [
            SourceValueBucket(value: 1000, count: 1),
            SourceValueBucket(value: 4000, count: 1),
        ])
    }
}

private struct ChatDBFixture {
    let path: String

    init() throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("courier-core-tests-\(UUID().uuidString).sqlite")
            .path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func seed() throws {
        let dbQueue = try DatabaseQueue(path: path)
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

            let t1 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_000))
            let t2 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_010))
            let t3 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_020))
            let t4 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_030))
            let t5 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_040))
            let t6 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_050))
            let t7 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_060))
            let t8 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_070))
            let t9 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_080))
            let t10 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_090))
            let t11 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_100))
            let t12 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_110))
            let t13 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_120))
            let t14 = AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_130))

            try db.execute(
                sql: "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, service_name) VALUES (1, 'chat-1', 'chat123', 'Test Chat', 'iMessage')"
            )

            try db.execute(sql: "INSERT INTO handle (ROWID, id, service, country) VALUES (1, '+15555550100', 'iMessage', 'US')")
            try db.execute(sql: "INSERT INTO handle (ROWID, id, service, country) VALUES (2, '+15555550200', 'iMessage', 'US')")
            try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")
            try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 2)")

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, text, handle_id, date, date_read, date_delivered, is_read, is_from_me,
                        service, associated_message_type, cache_has_attachments
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [100, "m-1", "hello", 0, t1, t3, t2, 1, 1, "SMS", 0, 1]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, text, handle_id, date, is_read, is_from_me, service,
                        associated_message_type, date_edited
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [101, "m-2", "edited body", 1, t4, 1, 0, "iMessage", 0, t5]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, text, handle_id, date, is_read, is_from_me, service,
                        associated_message_type, date_retracted
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [102, "m-3", "deleted body", 2, t6, 0, 0, "iMessage", 0, t7]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, text, handle_id, date, is_read, is_from_me, service,
                        associated_message_type, date_retracted, date_recovered
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [103, "m-4", "recovered body", 1, t8, 0, 0, "iMessage", 0, t9, t10]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, handle_id, date, is_read, is_from_me, service,
                        associated_message_guid, associated_message_type
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [104, "r-1", 1, t11, 1, 0, "iMessage", "p:0/m-2", 2001]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, handle_id, date, is_read, is_from_me, service,
                        associated_message_guid, associated_message_type
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [105, "r-2", 1, t12, 1, 0, "iMessage", "p:0/m-2", 3001]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, handle_id, date, is_read, is_from_me, service,
                        associated_message_type
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [106, "u-1", 1, t13, 1, 0, "iMessage", 1000]
            )

            try db.execute(
                sql: """
                    INSERT INTO message (
                        ROWID, guid, handle_id, date, is_read, is_from_me, service,
                        associated_message_type, item_type, message_action_type
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [107, "u-2", 2, t14, 1, 0, "iMessage", 4000, 42, 7]
            )

            for messageID in [100, 101, 102, 103, 104, 105, 106, 107] {
                try db.execute(
                    sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, ?)",
                    arguments: [messageID]
                )
            }

            try db.execute(
                sql: """
                    INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_sticker)
                    VALUES (200, 'a-1', '/tmp/file.jpg', 'image/jpeg', 'file.jpg', 128, 0)
                    """
            )
            try db.execute(sql: "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 200)")
        }
    }
}
