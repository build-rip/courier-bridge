import Foundation
import GRDB

public struct ChatQueries: Sendable {
    private let db: ChatDatabase

    public init(db: ChatDatabase) {
        self.db = db
    }

    // MARK: - Chats

    /// Fetch recent chats ordered by most recent message, with per-chat max rowIDs for sync.
    public func recentChats(limit: Int = 50) throws -> [ChatWithLastMessage] {
        try db.read { db in
            let sql = """
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name,
                       c.service_name, c.group_id, c.last_read_message_timestamp,
                       MAX(m.date) as last_message_date,
                       MAX(CASE WHEN m.associated_message_type IS NULL OR m.associated_message_type < 2000
                           THEN m.ROWID ELSE 0 END) as max_message_row_id,
                       MAX(CASE WHEN m.associated_message_type >= 2000
                           THEN m.ROWID ELSE 0 END) as max_reaction_row_id,
                       MAX(CASE WHEN m.is_from_me = 1 THEN m.date_read ELSE 0 END) as max_read_receipt_date,
                       MAX(CASE WHEN m.is_from_me = 1 THEN m.date_delivered ELSE 0 END) as max_delivery_receipt_date,
                       m.text as last_message_text,
                       m.attributedBody as last_message_attributed_body,
                       m.is_from_me as last_message_is_from_me,
                       (
                           SELECT COUNT(*) FROM message m2
                           JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
                           WHERE cmj2.chat_id = c.ROWID
                             AND m2.is_from_me = 0
                             AND m2.is_read = 0
                             AND (m2.associated_message_type IS NULL OR m2.associated_message_type < 2000)
                        ) as unread_count,
                       (SELECT m3.text FROM message m3
                        JOIN chat_message_join cmj3 ON cmj3.message_id = m3.ROWID
                        WHERE cmj3.chat_id = c.ROWID
                          AND m3.is_from_me = 0
                          AND m3.is_read = 0
                          AND (m3.associated_message_type IS NULL OR m3.associated_message_type < 2000)
                        ORDER BY m3.date ASC
                        LIMIT 1) as first_unread_text,
                       (SELECT m4.attributedBody FROM message m4
                        JOIN chat_message_join cmj4 ON cmj4.message_id = m4.ROWID
                        WHERE cmj4.chat_id = c.ROWID
                          AND m4.is_from_me = 0
                          AND m4.is_read = 0
                          AND (m4.associated_message_type IS NULL OR m4.associated_message_type < 2000)
                        ORDER BY m4.date ASC
                        LIMIT 1) as first_unread_attributed_body
                FROM chat c
                JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                JOIN message m ON m.ROWID = cmj.message_id
                GROUP BY c.ROWID
                ORDER BY last_message_date DESC
                LIMIT ?
                """
            return try ChatWithLastMessage.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    /// Fetch messages and reactions for a specific chat, for per-chat sync.
    /// Messages with ROWID > msgAfter and reactions with ROWID > rxnAfter, both sorted ASC.
    public func syncChat(
        chatRowID: Int64,
        msgAfter: Int64,
        rxnAfter: Int64,
        readAfter: Int64,
        deliveryAfter: Int64,
        limit: Int
    ) throws -> (messages: [Message], reactions: [Message], readReceipts: [Message], deliveryReceipts: [Message]) {
        try db.read { db in
            let msgSQL = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.ROWID > ?
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            let messages = try Message.fetchAll(db, sql: msgSQL, arguments: [chatRowID, msgAfter, limit])

            let rxnSQL = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.ROWID > ?
                  AND m.associated_message_type >= 2000
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            let reactions = try Message.fetchAll(db, sql: rxnSQL, arguments: [chatRowID, rxnAfter, limit])

            let readSQL = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.date_read > ?
                  AND m.is_from_me = 1
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.date_read ASC
                LIMIT ?
                """
            let readReceipts = try Message.fetchAll(db, sql: readSQL, arguments: [chatRowID, readAfter, limit])

            let deliverySQL = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.date_delivered > ?
                  AND m.is_from_me = 1
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.date_delivered ASC
                LIMIT ?
                """
            let deliveryReceipts = try Message.fetchAll(db, sql: deliverySQL, arguments: [chatRowID, deliveryAfter, limit])

            return (
                messages: messages,
                reactions: reactions,
                readReceipts: readReceipts,
                deliveryReceipts: deliveryReceipts
            )
        }
    }

    // MARK: - Messages

    /// Fetch messages for a chat, optionally after a given ROWID, newest first.
    /// Excludes reactions (associated_message_type >= 2000).
    public func messages(
        forChatRowID chatRowID: Int64,
        afterRowID: Int64? = nil,
        limit: Int = 50
    ) throws -> [Message] {
        try db.read { db in
            var sql = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                """
            var arguments: [any DatabaseValueConvertible] = [chatRowID]

            if let afterRowID {
                sql += " AND m.ROWID > ?"
                arguments.append(afterRowID)
            }

            sql += " ORDER BY m.date DESC LIMIT ?"
            arguments.append(limit)

            return try Message.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Fetch reactions for a chat, optionally after a given ROWID.
    public func reactions(
        forChatRowID chatRowID: Int64,
        afterRowID: Int64? = nil,
        limit: Int = 200
    ) throws -> [Message] {
        try db.read { db in
            var sql = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.associated_message_type >= 2000
                """
            var arguments: [any DatabaseValueConvertible] = [chatRowID]

            if let afterRowID {
                sql += " AND m.ROWID > ?"
                arguments.append(afterRowID)
            }

            sql += " ORDER BY m.date DESC LIMIT ?"
            arguments.append(limit)

            return try Message.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Fetch new messages across all chats after a given ROWID.
    public func newMessages(afterRowID: Int64, limit: Int = 100) throws -> [Message] {
        try db.read { db in
            let sql = """
                SELECT m.*
                FROM message m
                WHERE m.ROWID > ?
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            return try Message.fetchAll(db, sql: sql, arguments: [afterRowID, limit])
        }
    }

    /// Fetch new messages across all chats after a given ROWID, with chat IDs.
    /// Excludes reactions. Used for post-reconnect sync.
    public func newMessagesWithChatIDs(afterRowID: Int64, limit: Int = 500) throws -> [(message: Message, chatRowID: Int64)] {
        try db.read { db in
            let sql = """
                SELECT m.*, cmj.chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.ROWID > ?
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [afterRowID, limit])
            return try rows.map { row in
                let message = try Message(row: row)
                let chatRowID: Int64 = row["chat_id"]
                return (message: message, chatRowID: chatRowID)
            }
        }
    }

    /// Fetch new reactions across all chats after a given ROWID, with chat IDs.
    /// Used for post-reconnect sync.
    public func newReactionsWithChatIDs(afterRowID: Int64, limit: Int = 500) throws -> [(message: Message, chatRowID: Int64)] {
        try db.read { db in
            let sql = """
                SELECT m.*, cmj.chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.ROWID > ?
                  AND m.associated_message_type >= 2000
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [afterRowID, limit])
            return try rows.map { row in
                let message = try Message(row: row)
                let chatRowID: Int64 = row["chat_id"]
                return (message: message, chatRowID: chatRowID)
            }
        }
    }

    // MARK: - Handles / Participants

    /// Fetch handles (participants) for a chat.
    public func handles(forChatRowID chatRowID: Int64) throws -> [Handle] {
        try db.read { db in
            let sql = """
                SELECT h.*
                FROM handle h
                JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
                WHERE chj.chat_id = ?
                """
            return try Handle.fetchAll(db, sql: sql, arguments: [chatRowID])
        }
    }

    /// Look up a handle by its ROWID to resolve handleID → phone/email.
    public func handle(rowID: Int64) throws -> Handle? {
        try db.read { db in
            try Handle.fetchOne(db, sql: "SELECT * FROM handle WHERE ROWID = ?", arguments: [rowID])
        }
    }

    /// Resolve a handleID to a sender identifier (phone number or email).
    /// Returns nil if isFromMe is true or the handle is not found.
    public func resolveSenderID(handleID: Int64, isFromMe: Bool) throws -> String? {
        guard !isFromMe else { return nil }
        guard handleID > 0 else { return nil }
        return try handle(rowID: handleID)?.id
    }

    // MARK: - Attachments

    /// Fetch attachments for a message.
    public func attachments(forMessageRowID messageRowID: Int64) throws -> [Attachment] {
        try db.read { db in
            let sql = """
                SELECT a.*
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                WHERE maj.message_id = ?
                """
            return try Attachment.fetchAll(db, sql: sql, arguments: [messageRowID])
        }
    }

    /// Fetch a single attachment by ROWID.
    public func attachment(rowID: Int64) throws -> Attachment? {
        try db.read { db in
            try Attachment.fetchOne(db, sql: "SELECT * FROM attachment WHERE ROWID = ?", arguments: [rowID])
        }
    }

    // MARK: - Cursors

    /// Get the maximum message ROWID (used for change detection cursor).
    public func maxMessageRowID() throws -> Int64 {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
    }

    /// Get the total message count (for health checks).
    public func messageCount() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
    }

    /// Look up a message by GUID within a specific chat.
    public func messageInChat(guid: String, chatRowID: Int64) throws -> Message? {
        try db.read { db in
            let sql = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.guid = ?
                LIMIT 1
                """
            return try Message.fetchOne(db, sql: sql, arguments: [chatRowID, guid])
        }
    }

    // MARK: - Reaction State

    /// Check if the current user has an active (non-removed) reaction on a specific message+part.
    ///
    /// For standard tapbacks, matches on `reactionTypeName`. For emoji tapbacks, also matches on the emoji character.
    /// Returns the most recent matching reaction if it's an add (not a removal), or nil if the reaction
    /// doesn't exist or was removed.
    public func myReactionOnMessage(
        targetGUID: String,
        partIndex: Int,
        chatRowID: Int64,
        reactionType: String,
        emoji: String? = nil
    ) throws -> Message? {
        let associatedGUID = "p:\(partIndex)/\(targetGUID)"

        let reactions: [Message] = try db.read { db in
            let sql = """
                SELECT m.*
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                  AND m.is_from_me = 1
                  AND m.associated_message_guid = ?
                  AND m.associated_message_type >= 2000
                ORDER BY m.ROWID DESC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [chatRowID, associatedGUID])
        }

        // Find the most recent reaction matching this type (and emoji if applicable)
        for reaction in reactions {
            guard reaction.reactionTypeName == reactionType else { continue }
            if reactionType == "emoji" {
                guard reaction.reactionEmoji == emoji else { continue }
            }
            // Found the most recent matching reaction — if it's an add, return it; if removal, return nil
            return reaction.isReactionRemoval ? nil : reaction
        }

        return nil
    }

    /// Get the chat ROWID for a given message ROWID.
    public func chatRowID(forMessageRowID messageRowID: Int64) throws -> Int64? {
        try db.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT chat_id FROM chat_message_join WHERE message_id = ?",
                arguments: [messageRowID]
            )
        }
    }

    // MARK: - Read/Delivery Cursors

    /// Get the maximum date_read timestamp across all messages.
    public func maxDateRead() throws -> Int64 {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(date_read) FROM message WHERE is_from_me = 1") ?? 0
        }
    }

    /// Get the maximum date_delivered timestamp across all outgoing messages.
    public func maxDateDelivered() throws -> Int64 {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(date_delivered) FROM message WHERE is_from_me = 1") ?? 0
        }
    }

    /// Fetch messages whose date_read changed after the given timestamp, with chat IDs.
    /// Excludes reactions. Used for detecting read receipt changes.
    public func messagesWithReadChanges(afterTimestamp: Int64) throws -> [(message: Message, chatRowID: Int64)] {
        try db.read { db in
            let sql = """
                SELECT m.*, cmj.chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.date_read > ?
                  AND m.is_from_me = 1
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.date_read ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [afterTimestamp])
            return try rows.map { row in
                let message = try Message(row: row)
                let chatRowID: Int64 = row["chat_id"]
                return (message: message, chatRowID: chatRowID)
            }
        }
    }

    /// Fetch outgoing messages whose date_delivered changed after the given timestamp, with chat IDs.
    /// Excludes reactions. Used for detecting delivery receipt changes.
    public func messagesWithDeliveryChanges(afterTimestamp: Int64) throws -> [(message: Message, chatRowID: Int64)] {
        try db.read { db in
            let sql = """
                SELECT m.*, cmj.chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.date_delivered > ?
                  AND m.is_from_me = 1
                  AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000)
                ORDER BY m.date_delivered ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [afterTimestamp])
            return try rows.map { row in
                let message = try Message(row: row)
                let chatRowID: Int64 = row["chat_id"]
                return (message: message, chatRowID: chatRowID)
            }
        }
    }
}

// MARK: - Composite types

public struct ChatWithLastMessage: Sendable, Codable, FetchableRecord {
    public let rowID: Int64
    public let guid: String
    public let chatIdentifier: String
    public let displayName: String?
    public let serviceName: String?
    public let groupID: String?
    public let lastReadMessageTimestamp: Int64
    public let lastMessageDate: Int64?
    public let maxMessageRowID: Int64
    public let maxReactionRowID: Int64
    public let maxReadReceiptDate: Int64
    public let maxDeliveryReceiptDate: Int64
    public let lastMessageText: String?
    public let lastMessageAttributedBody: Data?
    public let lastMessageIsFromMe: Bool?
    public let unreadCount: Int
    public let firstUnreadText: String?
    public let firstUnreadAttributedBody: Data?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case rowID = "ROWID"
        case guid
        case chatIdentifier = "chat_identifier"
        case displayName = "display_name"
        case serviceName = "service_name"
        case groupID = "group_id"
        case lastReadMessageTimestamp = "last_read_message_timestamp"
        case lastMessageDate = "last_message_date"
        case maxMessageRowID = "max_message_row_id"
        case maxReactionRowID = "max_reaction_row_id"
        case maxReadReceiptDate = "max_read_receipt_date"
        case maxDeliveryReceiptDate = "max_delivery_receipt_date"
        case lastMessageText = "last_message_text"
        case lastMessageAttributedBody = "last_message_attributed_body"
        case lastMessageIsFromMe = "last_message_is_from_me"
        case unreadCount = "unread_count"
        case firstUnreadText = "first_unread_text"
        case firstUnreadAttributedBody = "first_unread_attributed_body"
    }

    public var hasUnreads: Bool {
        unreadCount > 0
    }

    public var lastReadMessageDateAsDate: Date? {
        lastReadMessageTimestamp == 0 ? nil : AppleDate.toDate(lastReadMessageTimestamp)
    }

    public var maxReadReceiptDateAsDate: Date? {
        maxReadReceiptDate == 0 ? nil : AppleDate.toDate(maxReadReceiptDate)
    }

    public var maxDeliveryReceiptDateAsDate: Date? {
        maxDeliveryReceiptDate == 0 ? nil : AppleDate.toDate(maxDeliveryReceiptDate)
    }

    public var resolvedFirstUnreadText: String? {
        if let firstUnreadText, !firstUnreadText.isEmpty {
            return firstUnreadText
        }
        if let firstUnreadAttributedBody {
            return AttributedBodyParser.extractText(from: firstUnreadAttributedBody)
        }
        return nil
    }

    public var resolvedLastMessageText: String? {
        if let lastMessageText, !lastMessageText.isEmpty {
            return lastMessageText
        }
        if let lastMessageAttributedBody {
            return AttributedBodyParser.extractText(from: lastMessageAttributedBody)
        }
        return nil
    }

    /// The resolved rich text for the last message, if any formatting is present.
    public var lastMessageRichText: RichText? {
        guard let lastMessageAttributedBody else { return nil }
        let parsed = AttributedBodyParser.parse(from: lastMessageAttributedBody)
        return parsed.richText
    }

    public var lastMessageDateAsDate: Date? {
        guard let lastMessageDate else { return nil }
        return AppleDate.toDate(lastMessageDate)
    }

    /// Whether this is a group chat.
    public var isGroup: Bool {
        chatIdentifier.hasPrefix("chat")
    }
}
