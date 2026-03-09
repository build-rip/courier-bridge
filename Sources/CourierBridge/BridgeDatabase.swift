import Foundation
import GRDB
import CourierCore

/// Local SQLite database for storing paired devices, refresh tokens, and config.
/// Stored at ~/.courier-bridge/bridge.db
final class BridgeDatabase: Sendable {
    private let dbQueue: DatabaseQueue
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(path: String? = nil) throws {
        let resolvedPath = path ?? Self.defaultPath.path
        let directory = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        dbQueue = try DatabaseQueue(path: resolvedPath)
        try migrate()
    }

    private static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".courier-bridge")
            .appendingPathComponent("bridge.db")
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS config (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS paired_devices (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    refresh_token TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    last_seen_at TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pairing_codes (
                    code TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    expires_at TEXT NOT NULL,
                    used INTEGER NOT NULL DEFAULT 0
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversations (
                    conversation_id TEXT PRIMARY KEY,
                    chat_guid TEXT NOT NULL,
                    chat_identifier TEXT,
                    display_name TEXT,
                    service_name TEXT,
                    conversation_version INTEGER NOT NULL,
                    latest_event_sequence INTEGER NOT NULL DEFAULT 0,
                    indexed_at TEXT,
                    source_fingerprint TEXT,
                    index_status TEXT NOT NULL DEFAULT 'pending'
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_events (
                    conversation_id TEXT NOT NULL,
                    conversation_version INTEGER NOT NULL,
                    event_sequence INTEGER NOT NULL,
                    event_type TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, conversation_version, event_sequence)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_message_index (
                    conversation_id TEXT NOT NULL,
                    message_guid TEXT NOT NULL,
                    exists_in_latest_state INTEGER NOT NULL DEFAULT 1,
                    is_targetable INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (conversation_id, message_guid)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_index_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL,
                    conversation_version INTEGER NOT NULL,
                    final_state_hash TEXT,
                    started_at TEXT NOT NULL DEFAULT (datetime('now')),
                    completed_at TEXT,
                    status TEXT NOT NULL,
                    diagnostics_json TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_unknown_classifications (
                    conversation_id TEXT NOT NULL,
                    source_kind TEXT NOT NULL,
                    source_value INTEGER NOT NULL,
                    occurrences INTEGER NOT NULL,
                    PRIMARY KEY (conversation_id, source_kind, source_value)
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversations_chat_guid ON conversations(chat_guid)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_lookup ON conversation_events(conversation_id, conversation_version, event_sequence)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_message_index_guid ON conversation_message_index(message_guid)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_index_runs_conversation ON conversation_index_runs(conversation_id, started_at)")

            try Self.addColumnIfNeeded(db, table: "conversations", definition: "chat_identifier TEXT")
            try Self.addColumnIfNeeded(db, table: "conversations", definition: "display_name TEXT")
            try Self.addColumnIfNeeded(db, table: "conversations", definition: "service_name TEXT")

            // Migrate emoji_positions: drop old schema with category column
            let hasOldSchema = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM pragma_table_info('emoji_positions') WHERE name = 'category'"
            ) != nil
            if hasOldSchema {
                try db.execute(sql: "DROP TABLE emoji_positions")
            }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS emoji_positions (
                    emoji TEXT PRIMARY KEY,
                    scroll_position REAL NOT NULL
                )
                """)
        }
    }

    private static func addColumnIfNeeded(_ db: Database, table: String, definition: String) throws {
        let columnName = definition.split(separator: " ").first.map(String.init) ?? definition
        let hasColumn = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM pragma_table_info('\(table)') WHERE name = ?",
            arguments: [columnName]
        ) != nil

        if !hasColumn {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
        }
    }

    // MARK: - Config

    func getOrCreateHMACSecret() throws -> Data {
        try dbQueue.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value FROM config WHERE key = 'hmac_secret'") {
                let hex: String = row["value"]
                return Data(hexString: hex)!
            }

            // Generate a new 256-bit secret
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let secret = Data(bytes)
            try db.execute(
                sql: "INSERT INTO config (key, value) VALUES ('hmac_secret', ?)",
                arguments: [secret.hexString]
            )
            return secret
        }
    }

    // MARK: - Pairing

    func createPairingCode() throws -> String {
        let code = generateCode()
        let expiresAt = Date().addingTimeInterval(300) // 5 minutes
        let formatter = ISO8601DateFormatter()

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO pairing_codes (code, expires_at) VALUES (?, ?)",
                arguments: [code, formatter.string(from: expiresAt)]
            )
        }
        return code
    }

    func redeemPairingCode(_ code: String) throws -> Bool {
        try dbQueue.write { db in
            let formatter = ISO8601DateFormatter()
            let now = formatter.string(from: Date())

            guard try Row.fetchOne(
                db,
                sql: "SELECT * FROM pairing_codes WHERE code = ? AND used = 0 AND expires_at > ?",
                arguments: [code, now]
            ) != nil else {
                return false
            }

            try db.execute(
                sql: "UPDATE pairing_codes SET used = 1 WHERE code = ?",
                arguments: [code]
            )
            return true
        }
    }

    // MARK: - Devices

    func addDevice(id: String, name: String?, refreshToken: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO paired_devices (id, name, refresh_token) VALUES (?, ?, ?)",
                arguments: [id, name, refreshToken]
            )
        }
    }

    func findDeviceByRefreshToken(_ token: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try PairedDevice.fetchOne(
                db,
                sql: "SELECT * FROM paired_devices WHERE refresh_token = ?",
                arguments: [token]
            )
        }
    }

    func listDevices() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try PairedDevice.fetchAll(db, sql: "SELECT * FROM paired_devices ORDER BY created_at DESC")
        }
    }

    func deleteDevice(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM paired_devices WHERE id = ?", arguments: [id])
        }
    }

    func updateLastSeen(deviceID: String) throws {
        let formatter = ISO8601DateFormatter()
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE paired_devices SET last_seen_at = ? WHERE id = ?",
                arguments: [formatter.string(from: Date()), deviceID]
            )
        }
    }

    // MARK: - Emoji Positions

    func lookupEmojiPosition(_ emoji: String) throws -> EmojiPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT emoji, scroll_position FROM emoji_positions WHERE emoji = ?",
                arguments: [emoji]
            ) else { return nil }
            return EmojiPosition(
                emoji: row["emoji"],
                scrollPosition: row["scroll_position"]
            )
        }
    }

    func storeEmojiPositions(_ positions: [EmojiPosition]) throws {
        try dbQueue.write { db in
            for pos in positions {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO emoji_positions (emoji, scroll_position) VALUES (?, ?)",
                    arguments: [pos.emoji, pos.scrollPosition]
                )
            }
        }
    }

    func clearEmojiPositions() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM emoji_positions")
        }
    }

    func emojiPositionCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emoji_positions") ?? 0
        }
    }

    func getEmojiIndexTimestamp() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM config WHERE key = 'emoji_index_timestamp'"
            )
        }
    }

    func setEmojiIndexTimestamp(_ timestamp: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO config (key, value) VALUES ('emoji_index_timestamp', ?)",
                arguments: [timestamp]
            )
        }
    }

    // MARK: - Conversation Sync

    func replaceAllConversationIndexes(_ indexedConversations: [IndexedConversation]) throws {
        try dbQueue.write { db in
            let currentConversationIDs = indexedConversations.map { $0.conversation.conversationID }

            if currentConversationIDs.isEmpty {
                try db.execute(sql: "DELETE FROM conversation_unknown_classifications")
                try db.execute(sql: "DELETE FROM conversation_index_runs")
                try db.execute(sql: "DELETE FROM conversation_message_index")
                try db.execute(sql: "DELETE FROM conversation_events")
                try db.execute(sql: "DELETE FROM conversations")
                return
            }

            let placeholders = databasePlaceholders(count: currentConversationIDs.count)
            try db.execute(
                sql: "DELETE FROM conversation_unknown_classifications WHERE conversation_id NOT IN (\(placeholders))",
                arguments: StatementArguments(currentConversationIDs)
            )
            try db.execute(
                sql: "DELETE FROM conversation_index_runs WHERE conversation_id NOT IN (\(placeholders))",
                arguments: StatementArguments(currentConversationIDs)
            )
            try db.execute(
                sql: "DELETE FROM conversation_message_index WHERE conversation_id NOT IN (\(placeholders))",
                arguments: StatementArguments(currentConversationIDs)
            )
            try db.execute(
                sql: "DELETE FROM conversation_events WHERE conversation_id NOT IN (\(placeholders))",
                arguments: StatementArguments(currentConversationIDs)
            )
            try db.execute(
                sql: "DELETE FROM conversations WHERE conversation_id NOT IN (\(placeholders))",
                arguments: StatementArguments(currentConversationIDs)
            )

            for indexedConversation in indexedConversations {
                try replaceConversationIndex(indexedConversation, in: db)
            }
        }
    }

    func replaceConversationIndex(_ indexedConversation: IndexedConversation) throws {
        try dbQueue.write { db in
            try replaceConversationIndex(indexedConversation, in: db)
        }
    }

    func listConversationSummaries() throws -> [StoredConversationSummary] {
        try dbQueue.read { db in
            try StoredConversationSummary.fetchAll(
                db,
                sql: """
                    SELECT conversation_id, chat_guid, chat_identifier, display_name, service_name,
                           conversation_version, latest_event_sequence, indexed_at, source_fingerprint, index_status
                    FROM conversations
                    ORDER BY indexed_at DESC, conversation_id ASC
                    """
            )
        }
    }

    func conversationSummary(id: String) throws -> StoredConversationSummary? {
        try dbQueue.read { db in
            try StoredConversationSummary.fetchOne(
                db,
                sql: """
                    SELECT conversation_id, chat_guid, chat_identifier, display_name, service_name,
                           conversation_version, latest_event_sequence, indexed_at, source_fingerprint, index_status
                    FROM conversations
                    WHERE conversation_id = ?
                    LIMIT 1
                    """,
                arguments: [id]
            )
        }
    }

    func fetchConversationEvents(
        conversationID: String,
        conversationVersion: Int,
        afterSequence: Int64,
        limit: Int
    ) throws -> [NormalizedConversationEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT event_sequence, event_type, payload_json
                    FROM conversation_events
                    WHERE conversation_id = ?
                      AND conversation_version = ?
                      AND event_sequence > ?
                    ORDER BY event_sequence ASC
                    LIMIT ?
                    """,
                arguments: [conversationID, conversationVersion, afterSequence, limit]
            )

            return try rows.map { row in
                let eventSequence: Int64 = row["event_sequence"]
                let payloadJSON: String = row["payload_json"]
                let payloadData = Data(payloadJSON.utf8)
                var event = try decoder.decode(NormalizedConversationEvent.self, from: payloadData)
                if event.eventSequence != eventSequence {
                    event = NormalizedConversationEvent(
                        conversationID: event.conversationID,
                        conversationVersion: event.conversationVersion,
                        eventSequence: eventSequence,
                        payload: event.payload
                    )
                }
                return event
            }
        }
    }

    private func replaceConversationIndex(_ indexedConversation: IndexedConversation, in db: Database) throws {
        let conversation = indexedConversation.conversation
        let indexedAt = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            sql: """
                INSERT INTO conversations (
                    conversation_id,
                    chat_guid,
                    chat_identifier,
                    display_name,
                    service_name,
                    conversation_version,
                    latest_event_sequence,
                    indexed_at,
                    source_fingerprint,
                    index_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    chat_guid = excluded.chat_guid,
                    chat_identifier = excluded.chat_identifier,
                    display_name = excluded.display_name,
                    service_name = excluded.service_name,
                    conversation_version = excluded.conversation_version,
                    latest_event_sequence = excluded.latest_event_sequence,
                    indexed_at = excluded.indexed_at,
                    source_fingerprint = excluded.source_fingerprint,
                    index_status = excluded.index_status
                """,
            arguments: [
                conversation.conversationID,
                conversation.chatGUID,
                conversation.chatIdentifier,
                conversation.displayName,
                ServiceAlias.publicValue(conversation.serviceName),
                indexedConversation.conversationVersion,
                indexedConversation.latestEventSequence,
                indexedAt,
                indexedConversation.finalStateHash,
                "ready",
            ]
        )

        try db.execute(sql: "DELETE FROM conversation_events WHERE conversation_id = ?", arguments: [conversation.conversationID])
        for event in indexedConversation.events {
            let payloadJSON = try String(decoding: encoder.encode(event), as: UTF8.self)
            try db.execute(
                sql: """
                    INSERT INTO conversation_events (
                        conversation_id,
                        conversation_version,
                        event_sequence,
                        event_type,
                        payload_json
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conversation.conversationID,
                    indexedConversation.conversationVersion,
                    event.eventSequence,
                    event.eventType.rawValue,
                    payloadJSON,
                ]
            )
        }

        try db.execute(sql: "DELETE FROM conversation_message_index WHERE conversation_id = ?", arguments: [conversation.conversationID])
        for message in indexedConversation.reducedState.messages {
            let existsInLatestState = message.deletedAt == nil
            try db.execute(
                sql: """
                    INSERT INTO conversation_message_index (
                        conversation_id,
                        message_guid,
                        exists_in_latest_state,
                        is_targetable
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [conversation.conversationID, message.messageID, existsInLatestState, existsInLatestState]
            )
        }

        try db.execute(sql: "DELETE FROM conversation_unknown_classifications WHERE conversation_id = ?", arguments: [conversation.conversationID])
        for bucket in indexedConversation.diagnostics.unknownAssociatedMessageTypeBuckets {
            try db.execute(
                sql: """
                    INSERT INTO conversation_unknown_classifications (
                        conversation_id,
                        source_kind,
                        source_value,
                        occurrences
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [conversation.conversationID, "associated_message_type", bucket.value, bucket.count]
            )
        }

        let diagnosticsJSON = try String(decoding: encoder.encode(indexedConversation.diagnostics), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO conversation_index_runs (
                    conversation_id,
                    conversation_version,
                    final_state_hash,
                    completed_at,
                    status,
                    diagnostics_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                conversation.conversationID,
                indexedConversation.conversationVersion,
                indexedConversation.finalStateHash,
                indexedAt,
                "completed",
                diagnosticsJSON,
            ]
        )
    }

    private func databasePlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    // MARK: - Helpers

    private func generateCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // Omit confusing chars
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}

struct PairedDevice: Codable, FetchableRecord, Sendable {
    let id: String
    let name: String?
    let refreshToken: String
    let createdAt: String
    let lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct StoredConversationSummary: Codable, FetchableRecord, Sendable {
    let conversationID: String
    let chatGUID: String
    let chatIdentifier: String?
    let displayName: String?
    let serviceName: String?
    let conversationVersion: Int
    let latestEventSequence: Int64
    let indexedAt: String?
    let sourceFingerprint: String?
    let indexStatus: String

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case chatGUID = "chat_guid"
        case chatIdentifier = "chat_identifier"
        case displayName = "display_name"
        case serviceName = "service_name"
        case conversationVersion = "conversation_version"
        case latestEventSequence = "latest_event_sequence"
        case indexedAt = "indexed_at"
        case sourceFingerprint = "source_fingerprint"
        case indexStatus = "index_status"
    }
}

// MARK: - Data hex helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
