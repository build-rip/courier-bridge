import Vapor
import CourierCore

struct MessageResponse: Content {
    let rowID: Int64
    let guid: String
    let text: String?
    let richText: RichText?
    let senderID: String?
    let date: Date
    let dateRead: Date?
    let dateDelivered: Date?
    let isRead: Bool
    let isFromMe: Bool
    let service: String?
    let hasAttachments: Bool
    let balloonBundleID: String?
    let threadOriginatorGuid: String?
    let linkPreviewTitle: String?
    let linkPreviewSubtitle: String?
    let linkPreviewURL: String?

    init(from message: Message, senderID: String?) {
        self.rowID = message.rowID
        self.guid = message.guid
        self.text = message.resolvedText
        self.richText = message.resolvedRichText
        self.senderID = senderID
        self.date = message.dateAsDate
        self.dateRead = message.dateReadAsDate
        self.dateDelivered = message.dateDeliveredAsDate
        self.isRead = message.isRead
        self.isFromMe = message.isFromMe
        self.service = ServiceAlias.publicValue(message.service)
        self.hasAttachments = message.cacheHasAttachments
        self.balloonBundleID = message.balloonBundleID
        self.threadOriginatorGuid = message.threadOriginatorGuid
        let lm = message.linkMetadata
        self.linkPreviewTitle = lm?.title
        self.linkPreviewSubtitle = lm?.subtitle
        self.linkPreviewURL = lm?.url
    }
}

struct ReactionResponse: Content {
    let rowID: Int64
    let guid: String
    let targetMessageGUID: String
    let partIndex: Int
    let reactionType: String
    let emoji: String?
    let isRemoval: Bool
    let senderID: String?
    let isFromMe: Bool
    let date: Date

    init(from message: Message, senderID: String?) {
        self.rowID = message.rowID
        self.guid = message.guid
        self.targetMessageGUID = message.cleanAssociatedMessageGUID ?? ""
        self.partIndex = message.reactionPartIndex
        self.reactionType = message.reactionTypeName ?? "unknown"
        self.emoji = message.reactionEmoji
        self.isRemoval = message.isReactionRemoval
        self.senderID = senderID
        self.isFromMe = message.isFromMe
        self.date = message.dateAsDate
    }
}

struct SendMessageRequest: Content {
    let text: String
    let recipient: String?  // For direct messages by phone/email
}

struct TapbackRequest: Content {
    let type: String  // love, like, dislike, laugh, emphasis, question, emoji
    let messageGUID: String
    let partIndex: Int?  // 0-based part index (0 = text, 1+ = attachments). Defaults to 0.
    let emoji: String?  // Required when type is "emoji". The emoji character to react with.
}

func messageRoutes(_ app: RoutesBuilder) {
    // POST /api/chats/:id/messages - send a message
    app.post("chats", ":id", "messages") { req -> Response in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let body = try req.content.decode(SendMessageRequest.self)

        if let recipient = body.recipient {
            try await req.appState.sender.send(text: body.text, to: recipient)
        } else {
            // Look up chat identifier for AppleScript
            let chats = try req.appState.queries.recentChats(limit: 1000)
            guard let chat = chats.first(where: { $0.rowID == chatRowID }) else {
                throw Abort(.notFound, reason: "Chat not found")
            }
            try await req.appState.sender.sendToChat(
                text: body.text,
                chatIdentifier: chat.guid
            )
        }

        return Response(status: .accepted)
    }

    // POST /api/chats/:id/tapback - send a tapback reaction (idempotent: no-op if already present)
    app.post("chats", ":id", "tapback") { req -> Response in
        let (body, chat, message, partIndex) = try parseTapbackRequest(req)

        // Idempotency: if this exact reaction already exists, skip the UI toggle
        let existing = try req.appState.queries.myReactionOnMessage(
            targetGUID: body.messageGUID,
            partIndex: partIndex,
            chatRowID: chat.rowID,
            reactionType: body.type,
            emoji: body.emoji
        )
        if existing != nil {
            return Response(status: .accepted)
        }

        try await performTapbackUI(req: req, body: body, message: message, chat: chat, partIndex: partIndex)
        return Response(status: .accepted)
    }

    // DELETE /api/chats/:id/tapback - remove a tapback reaction (idempotent: no-op if already absent)
    app.delete("chats", ":id", "tapback") { req -> Response in
        let (body, chat, message, partIndex) = try parseTapbackRequest(req)

        // Idempotency: if this reaction doesn't exist, skip the UI toggle
        let existing = try req.appState.queries.myReactionOnMessage(
            targetGUID: body.messageGUID,
            partIndex: partIndex,
            chatRowID: chat.rowID,
            reactionType: body.type,
            emoji: body.emoji
        )
        if existing == nil {
            return Response(status: .accepted)
        }

        try await performTapbackUI(req: req, body: body, message: message, chat: chat, partIndex: partIndex)
        return Response(status: .accepted)
    }
}

/// Parse and validate a tapback request, returning the body, chat, message, and resolved partIndex.
private func parseTapbackRequest(_ req: Request) throws -> (TapbackRequest, ChatWithLastMessage, Message, Int) {
    guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
        throw Abort(.badRequest, reason: "Invalid chat ID")
    }
    let body = try req.content.decode(TapbackRequest.self)

    let chats = try req.appState.queries.recentChats(limit: 1000)
    guard let chat = chats.first(where: { $0.rowID == chatRowID }) else {
        throw Abort(.notFound, reason: "Chat not found")
    }

    guard let message = try req.appState.queries.messageInChat(
        guid: body.messageGUID,
        chatRowID: chatRowID
    ) else {
        throw Abort(.notFound, reason: "Message not found in this chat")
    }

    // Validate type
    if body.type == "emoji" {
        guard let emoji = body.emoji, !emoji.isEmpty else {
            throw Abort(.badRequest, reason: "Missing required 'emoji' field for emoji tapback")
        }
        _ = emoji // suppress unused warning
    } else {
        guard TapbackType(rawValue: body.type) != nil else {
            throw Abort(.badRequest, reason: "Invalid tapback type. Valid: \(TapbackType.allCases.map(\.rawValue).joined(separator: ", ")), emoji")
        }
    }

    let partIndex = body.partIndex ?? 0
    return (body, chat, message, partIndex)
}

/// Trigger the UI automation to toggle a tapback (used by both POST and DELETE).
private func performTapbackUI(
    req: Request,
    body: TapbackRequest,
    message: Message,
    chat: ChatWithLastMessage,
    partIndex: Int
) async throws {
    if body.type == "emoji" {
        let emoji = body.emoji!
        let cachedPosition = try? req.appState.bridgeDB.lookupEmojiPosition(emoji)
        if partIndex == 0 {
            guard let messageText = message.resolvedText, !messageText.isEmpty else {
                throw Abort(.badRequest, reason: "Cannot target this message — it has no text content")
            }
            try await req.appState.uiAutomation.sendEmojiTapback(
                emoji: emoji,
                messageText: messageText,
                chatIdentifier: chat.guid,
                cachedPosition: cachedPosition
            )
        } else {
            try await req.appState.uiAutomation.sendEmojiTapback(
                emoji: emoji,
                messageText: message.resolvedText,
                partIndex: partIndex,
                chatIdentifier: chat.guid,
                cachedPosition: cachedPosition
            )
        }
    } else {
        let tapbackType = TapbackType(rawValue: body.type)!
        if partIndex == 0 {
            guard let messageText = message.resolvedText, !messageText.isEmpty else {
                throw Abort(.badRequest, reason: "Cannot target this message — it has no text content (image-only messages are not supported for targeted tapback on part 0)")
            }
            try await req.appState.uiAutomation.sendTargetedTapback(
                tapbackType,
                messageText: messageText,
                chatIdentifier: chat.guid
            )
        } else {
            try await req.appState.uiAutomation.sendTargetedTapback(
                tapbackType,
                messageText: message.resolvedText,
                partIndex: partIndex,
                chatIdentifier: chat.guid
            )
        }
    }
}
