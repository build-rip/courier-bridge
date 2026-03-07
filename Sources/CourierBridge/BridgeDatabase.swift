import Foundation
import GRDB
import CourierCore

/// Local SQLite database for storing paired devices, refresh tokens, and config.
/// Stored at ~/.courier-bridge/bridge.db
final class BridgeDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    init() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".courier-bridge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("bridge.db").path
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
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
