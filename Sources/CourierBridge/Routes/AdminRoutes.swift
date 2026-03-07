import Vapor
import CourierCore

struct EmojiIndexResponse: Content {
    let emojiCount: Int
    let durationSeconds: Double
    let indexedAt: String
}

struct EmojiIndexStatusResponse: Content {
    let hasIndex: Bool
    let indexedAt: String?
    let emojiCount: Int
}

func adminRoutes(_ app: RoutesBuilder) {
    let admin = app.grouped("admin")

    // POST /api/admin/index-emoji?chat=<chatRowID>
    admin.post("index-emoji") { req -> EmojiIndexResponse in
        guard let chatRowID = req.query[Int64.self, at: "chat"] else {
            throw Abort(.badRequest, reason: "Missing required 'chat' query parameter (chat row ID)")
        }

        let chats = try req.appState.queries.recentChats(limit: 1000)
        guard let chat = chats.first(where: { $0.rowID == chatRowID }) else {
            throw Abort(.notFound, reason: "Chat not found")
        }

        let start = Date()
        req.logger.info("Starting emoji index scan")
        let positions = try await req.appState.uiAutomation.indexEmojiPicker(
            chatIdentifier: chat.guid
        )
        req.logger.info("indexEmojiPicker returned \(positions.count) positions in \(Date().timeIntervalSince(start))s")

        try req.appState.bridgeDB.clearEmojiPositions()
        try req.appState.bridgeDB.storeEmojiPositions(positions)

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        try req.appState.bridgeDB.setEmojiIndexTimestamp(timestamp)

        let duration = Date().timeIntervalSince(start)
        req.logger.info("Emoji index complete, returning response")

        return EmojiIndexResponse(
            emojiCount: positions.count,
            durationSeconds: duration,
            indexedAt: timestamp
        )
    }

    // GET /api/admin/emoji-index-status
    admin.get("emoji-index-status") { req -> EmojiIndexStatusResponse in
        let count = try req.appState.bridgeDB.emojiPositionCount()
        let timestamp = try req.appState.bridgeDB.getEmojiIndexTimestamp()

        return EmojiIndexStatusResponse(
            hasIndex: count > 0,
            indexedAt: timestamp,
            emojiCount: count
        )
    }
}
