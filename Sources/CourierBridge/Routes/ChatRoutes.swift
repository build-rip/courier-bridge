import Vapor
import CourierCore

struct ChatListResponse: Content {
    let chats: [ChatResponse]
}

struct ChatResponse: Content {
    let rowID: Int64
    let guid: String
    let chatIdentifier: String
    let displayName: String?
    let serviceName: String?
    let isGroup: Bool
    let lastMessageDate: Date?
    let lastMessageText: String?
    let lastMessageRichText: RichText?
    let lastMessageIsFromMe: Bool?
    let maxMessageRowID: Int64
    let maxReactionRowID: Int64
    let hasUnreads: Bool
    let unreadCount: Int
    let firstUnreadText: String?
    let lastReadMessageDate: Date?
    let maxReadReceiptDate: Date?
    let maxDeliveryReceiptDate: Date?

    init(from chat: ChatWithLastMessage) {
        self.rowID = chat.rowID
        self.guid = chat.guid
        self.chatIdentifier = chat.chatIdentifier
        self.displayName = chat.displayName
        self.serviceName = ServiceAlias.publicValue(chat.serviceName)
        self.isGroup = chat.isGroup
        self.lastMessageDate = chat.lastMessageDateAsDate
        self.lastMessageText = chat.resolvedLastMessageText
        self.lastMessageRichText = chat.lastMessageRichText
        self.lastMessageIsFromMe = chat.lastMessageIsFromMe
        self.maxMessageRowID = chat.maxMessageRowID
        self.maxReactionRowID = chat.maxReactionRowID
        self.hasUnreads = chat.hasUnreads
        self.unreadCount = chat.unreadCount
        self.firstUnreadText = chat.resolvedFirstUnreadText
        self.lastReadMessageDate = chat.lastReadMessageDateAsDate
        self.maxReadReceiptDate = chat.maxReadReceiptDateAsDate
        self.maxDeliveryReceiptDate = chat.maxDeliveryReceiptDateAsDate
    }
}

struct ChatSyncResponse: Content {
    let messages: [SyncMessageResponse]
    let reactions: [SyncReactionResponse]
    let readReceipts: [SyncReadReceiptResponse]
    let deliveryReceipts: [SyncDeliveryReceiptResponse]
    let hasMoreMessages: Bool
    let hasMoreReactions: Bool
    let hasMoreReadReceipts: Bool
    let hasMoreDeliveryReceipts: Bool
}

struct ParticipantResponse: Content {
    let rowID: Int64
    let id: String
    let service: String?

    init(from handle: Handle) {
        self.rowID = handle.rowID
        self.id = handle.id
        self.service = ServiceAlias.publicValue(handle.service)
    }
}

struct SyncResponse: Content {
    let messages: [SyncMessageResponse]
    let reactions: [SyncReactionResponse]
}

struct SyncMessageResponse: Content {
    let chatRowID: Int64
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

    init(from message: Message, chatRowID: Int64, senderID: String?) {
        self.chatRowID = chatRowID
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

struct SyncReadReceiptResponse: Content {
    let rowID: Int64
    let guid: String
    let dateRead: Date

    init(from message: Message) {
        self.rowID = message.rowID
        self.guid = message.guid
        self.dateRead = message.dateReadAsDate!
    }
}

struct SyncDeliveryReceiptResponse: Content {
    let rowID: Int64
    let guid: String
    let dateDelivered: Date

    init(from message: Message) {
        self.rowID = message.rowID
        self.guid = message.guid
        self.dateDelivered = message.dateDeliveredAsDate!
    }
}

struct SyncReactionResponse: Content {
    let chatRowID: Int64
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

    init(from message: Message, chatRowID: Int64, senderID: String?) {
        self.chatRowID = chatRowID
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

func chatRoutes(_ app: RoutesBuilder) {
    let chats = app.grouped("chats")

    // GET /api/chats - list recent chats
    chats.get { req -> ChatListResponse in
        let limit = req.query[Int.self, at: "limit"] ?? 50
        let chats = try req.appState.queries.recentChats(limit: limit)
        return ChatListResponse(chats: chats.map(ChatResponse.init))
    }

    // GET /api/chats/:id/messages - paginated messages for a chat (excludes reactions)
    chats.get(":id", "messages") { req -> [MessageResponse] in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let limit = req.query[Int.self, at: "limit"] ?? 50
        let afterRowID = req.query[Int64.self, at: "after"]
        let messages = try req.appState.queries.messages(
            forChatRowID: chatRowID,
            afterRowID: afterRowID,
            limit: limit
        )
        return try messages.map { message in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: message.handleID,
                isFromMe: message.isFromMe
            )
            return MessageResponse(from: message, senderID: senderID)
        }
    }

    // GET /api/chats/:id/reactions - reactions for a chat
    chats.get(":id", "reactions") { req -> [ReactionResponse] in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let limit = req.query[Int.self, at: "limit"] ?? 200
        let afterRowID = req.query[Int64.self, at: "after"]
        let reactions = try req.appState.queries.reactions(
            forChatRowID: chatRowID,
            afterRowID: afterRowID,
            limit: limit
        )
        return try reactions.map { message in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: message.handleID,
                isFromMe: message.isFromMe
            )
            return ReactionResponse(from: message, senderID: senderID)
        }
    }

    // GET /api/chats/:id/sync - per-chat sync (messages + reactions)
    chats.get(":id", "sync") { req -> ChatSyncResponse in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let msgAfter = req.query[Int64.self, at: "msgAfter"] ?? 0
        let rxnAfter = req.query[Int64.self, at: "rxnAfter"] ?? 0
        let readAfter = req.query[Int64.self, at: "readAfter"] ?? 0
        let deliveryAfter = req.query[Int64.self, at: "deliveryAfter"] ?? 0
        let limit = req.query[Int.self, at: "limit"] ?? 500

        let result = try req.appState.queries.syncChat(
            chatRowID: chatRowID,
            msgAfter: msgAfter,
            rxnAfter: rxnAfter,
            readAfter: readAfter,
            deliveryAfter: deliveryAfter,
            limit: limit
        )

        let messages = try result.messages.map { message in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: message.handleID,
                isFromMe: message.isFromMe
            )
            return SyncMessageResponse(from: message, chatRowID: chatRowID, senderID: senderID)
        }

        let reactions = try result.reactions.map { message in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: message.handleID,
                isFromMe: message.isFromMe
            )
            return SyncReactionResponse(from: message, chatRowID: chatRowID, senderID: senderID)
        }

        let readReceipts = result.readReceipts
            .filter { $0.dateReadAsDate != nil }
            .map { SyncReadReceiptResponse(from: $0) }

        let deliveryReceipts = result.deliveryReceipts
            .filter { $0.dateDeliveredAsDate != nil }
            .map { SyncDeliveryReceiptResponse(from: $0) }

        return ChatSyncResponse(
            messages: messages,
            reactions: reactions,
            readReceipts: readReceipts,
            deliveryReceipts: deliveryReceipts,
            hasMoreMessages: result.messages.count >= limit,
            hasMoreReactions: result.reactions.count >= limit,
            hasMoreReadReceipts: result.readReceipts.count >= limit,
            hasMoreDeliveryReceipts: result.deliveryReceipts.count >= limit
        )
    }

    // POST /api/chats/:id/read - mark a chat as read
    chats.post(":id", "read") { req -> Response in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let chats = try req.appState.queries.recentChats(limit: 1000)
        guard let chat = chats.first(where: { $0.rowID == chatRowID }) else {
            throw Abort(.notFound, reason: "Chat not found")
        }
        try await req.appState.uiAutomation.markChatAsRead(chatIdentifier: chat.guid)
        return Response(status: .accepted)
    }

    // GET /api/chats/:id/participants - chat participants
    chats.get(":id", "participants") { req -> [ParticipantResponse] in
        guard let chatRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid chat ID")
        }
        let handles = try req.appState.queries.handles(forChatRowID: chatRowID)
        return handles.map(ParticipantResponse.init)
    }

    // GET /api/sync?after=ROWID&limit=N - fetch new messages and reactions across all chats
    app.get("sync") { req -> SyncResponse in
        guard let afterRowID = req.query[Int64.self, at: "after"] else {
            throw Abort(.badRequest, reason: "Missing required 'after' query parameter (ROWID)")
        }
        let limit = req.query[Int.self, at: "limit"] ?? 500

        let newMessages = try req.appState.queries.newMessagesWithChatIDs(afterRowID: afterRowID, limit: limit)
        let newReactions = try req.appState.queries.newReactionsWithChatIDs(afterRowID: afterRowID, limit: limit)

        let messages = try newMessages.map { pair in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: pair.message.handleID,
                isFromMe: pair.message.isFromMe
            )
            return SyncMessageResponse(from: pair.message, chatRowID: pair.chatRowID, senderID: senderID)
        }

        let reactions = try newReactions.map { pair in
            let senderID = try req.appState.queries.resolveSenderID(
                handleID: pair.message.handleID,
                isFromMe: pair.message.isFromMe
            )
            return SyncReactionResponse(from: pair.message, chatRowID: pair.chatRowID, senderID: senderID)
        }

        return SyncResponse(messages: messages, reactions: reactions)
    }
}
