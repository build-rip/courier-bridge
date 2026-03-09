import CourierCore
import Vapor

struct SendMessageRequest: Content {
    let text: String
    let recipient: String?
    let conversationVersion: Int?
    let fromEventSequence: Int64?
}

struct TapbackRequest: Content {
    let type: String
    let messageGUID: String
    let partIndex: Int?
    let emoji: String?
    let conversationVersion: Int?
    let fromEventSequence: Int64?
}

struct MarkReadRequest: Content {
    let conversationVersion: Int?
    let fromEventSequence: Int64?
}

struct MutationResponse: Content {
    let result: String
    let conversationVersion: Int?
    let latestEventSequence: Int64?
    let failureReason: String?
}

func messageRoutes(_ app: RoutesBuilder) {
    let conversations = app.grouped("conversations")

    conversations.post(":id", "messages") { req async throws -> MutationResponse in
        guard let conversationID = req.parameters.get("id"), !conversationID.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid conversation ID")
        }

        let body = try req.content.decode(SendMessageRequest.self)
        let appState = req.appState
        let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)

        do {
            let chat: Chat?
            if body.recipient == nil {
                guard let chatValue = try appState.queries.chat(guid: conversationID) else {
                    throw Abort(.notFound, reason: "Conversation not found")
                }
                chat = chatValue
            } else {
                chat = nil
            }

            await enqueueMutationOperation(req: req, description: "send message") {
                if let recipient = body.recipient {
                    try await appState.sender.send(text: body.text, to: recipient)
                } else if let chat {
                    try await appState.sender.sendToChat(text: body.text, chatIdentifier: chat.guid)
                }
            }

            return MutationResponse(
                result: "success",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: nil
            )
        } catch {
            let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)
            return MutationResponse(
                result: "failed",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: mutationFailureReason(error)
            )
        }
    }

    conversations.post(":id", "tapback") { req async throws -> MutationResponse in
        try await performTapbackMutation(req: req, shouldRemove: false)
    }

    conversations.delete(":id", "tapback") { req async throws -> MutationResponse in
        try await performTapbackMutation(req: req, shouldRemove: true)
    }

    conversations.post(":id", "read") { req async throws -> MutationResponse in
        guard let conversationID = req.parameters.get("id"), !conversationID.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid conversation ID")
        }

        _ = (try? req.content.decode(MarkReadRequest.self)) ?? MarkReadRequest(
            conversationVersion: nil,
            fromEventSequence: nil
        )
        let appState = req.appState
        let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)

        do {
            guard let chat = try appState.queries.chat(guid: conversationID) else {
                throw Abort(.notFound, reason: "Conversation not found")
            }

            await enqueueMutationOperation(req: req, description: "mark conversation read") {
                try await appState.uiAutomation.markChatAsRead(chatIdentifier: chat.guid)
            }

            return MutationResponse(
                result: "success",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: nil
            )
        } catch {
            let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)
            return MutationResponse(
                result: "failed",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: mutationFailureReason(error)
            )
        }
    }
}

private func performTapbackMutation(req: Request, shouldRemove: Bool) async throws -> MutationResponse {
    guard let conversationID = req.parameters.get("id"), !conversationID.isEmpty else {
        throw Abort(.badRequest, reason: "Invalid conversation ID")
    }

    let body = try req.content.decode(TapbackRequest.self)
    let appState = req.appState
    let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)

    do {
        let context = try resolveTapbackContext(
            queries: appState.queries,
            conversationID: conversationID,
            request: body
        )

        let existing = try appState.queries.myReactionOnMessage(
            targetGUID: body.messageGUID,
            partIndex: context.partIndex,
            chatRowID: context.chat.rowID,
            reactionType: body.type,
            emoji: body.emoji
        )

        if shouldRemove, existing == nil {
            return MutationResponse(
                result: "success",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: nil
            )
        }

        if !shouldRemove, existing != nil {
            return MutationResponse(
                result: "success",
                conversationVersion: cursor?.conversationVersion,
                latestEventSequence: cursor?.latestEventSequence,
                failureReason: nil
            )
        }

        await enqueueMutationOperation(req: req, description: shouldRemove ? "remove tapback" : "add tapback") {
            try await performTapbackUI(
                uiAutomation: appState.uiAutomation,
                bridgeDB: appState.bridgeDB,
                body: body,
                message: context.message,
                chat: context.chat,
                partIndex: context.partIndex
            )
        }

        return MutationResponse(
            result: "success",
            conversationVersion: cursor?.conversationVersion,
            latestEventSequence: cursor?.latestEventSequence,
            failureReason: nil
        )
    } catch {
        let cursor = try await appState.syncService.currentCursorUpdate(conversationID: conversationID)
        return MutationResponse(
            result: "failed",
            conversationVersion: cursor?.conversationVersion,
            latestEventSequence: cursor?.latestEventSequence,
            failureReason: mutationFailureReason(error)
        )
    }
}

private struct TapbackContext: Sendable {
    let chat: Chat
    let message: Message
    let partIndex: Int
}

private func resolveTapbackContext(
    queries: ChatQueries,
    conversationID: String,
    request: TapbackRequest
) throws -> TapbackContext {
    guard let chat = try queries.chat(guid: conversationID) else {
        throw Abort(.notFound, reason: "Conversation not found")
    }

    guard let message = try queries.messageInChat(guid: request.messageGUID, chatRowID: chat.rowID) else {
        throw Abort(.notFound, reason: "Message not found in this conversation")
    }

    if request.type == "emoji" {
        guard let emoji = request.emoji, !emoji.isEmpty else {
            throw Abort(.badRequest, reason: "Missing required 'emoji' field for emoji tapback")
        }
        _ = emoji
    } else if TapbackType(rawValue: request.type) == nil {
        throw Abort(
            .badRequest,
            reason: "Invalid tapback type. Valid: \(TapbackType.allCases.map(\.rawValue).joined(separator: ", ")), emoji"
        )
    }

    let partIndex = request.partIndex ?? 0
    if partIndex == 0, message.resolvedText?.isEmpty != false {
        throw Abort(.badRequest, reason: "Cannot target this message - it has no text content")
    }

    return TapbackContext(chat: chat, message: message, partIndex: partIndex)
}

private func performTapbackUI(
    uiAutomation: UIAutomation,
    bridgeDB: BridgeDatabase,
    body: TapbackRequest,
    message: Message,
    chat: Chat,
    partIndex: Int
) async throws {
    if body.type == "emoji" {
        let emoji = body.emoji!
        let cachedPosition = try? bridgeDB.lookupEmojiPosition(emoji)
        if partIndex == 0 {
            guard let messageText = message.resolvedText, !messageText.isEmpty else {
                throw Abort(.badRequest, reason: "Cannot target this message - it has no text content")
            }
            try await uiAutomation.sendEmojiTapback(
                emoji: emoji,
                messageText: messageText,
                chatIdentifier: chat.guid,
                cachedPosition: cachedPosition
            )
        } else {
            try await uiAutomation.sendEmojiTapback(
                emoji: emoji,
                messageText: message.resolvedText,
                partIndex: partIndex,
                chatIdentifier: chat.guid,
                cachedPosition: cachedPosition
            )
        }
        return
    }

    let tapbackType = TapbackType(rawValue: body.type)!
    if partIndex == 0 {
        guard let messageText = message.resolvedText, !messageText.isEmpty else {
            throw Abort(.badRequest, reason: "Cannot target this message - it has no text content")
        }
        try await uiAutomation.sendTargetedTapback(
            tapbackType,
            messageText: messageText,
            chatIdentifier: chat.guid
        )
    } else {
        try await uiAutomation.sendTargetedTapback(
            tapbackType,
            messageText: message.resolvedText,
            partIndex: partIndex,
            chatIdentifier: chat.guid
        )
    }
}

private func mutationFailureReason(_ error: Error) -> String {
    if let abort = error as? AbortError {
        return abort.reason
    }
    return String(describing: error)
}

private func enqueueMutationOperation(
    req: Request,
    description: String,
    operation: @escaping @Sendable () async throws -> Void
) async {
    let logger = req.logger
    let executor = req.appState.mutationExecutor
    await executor.enqueue {
        do {
            try await operation()
        } catch {
            logger.error("Mutation automation failed for \(description): \(String(describing: error))")
        }
    }
}
