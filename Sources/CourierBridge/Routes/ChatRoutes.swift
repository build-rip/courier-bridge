import CourierCore
import Vapor

struct ConversationListResponse: Content {
    let conversations: [ConversationSummaryResponse]
}

struct ConversationSummaryResponse: Content {
    let conversationId: String
    let chatGuid: String
    let chatIdentifier: String?
    let displayName: String?
    let serviceName: String?
    let conversationVersion: Int
    let latestEventSequence: Int64
    let indexedAt: String?
    let indexStatus: String

    init(from summary: StoredConversationSummary) {
        self.conversationId = summary.conversationID
        self.chatGuid = summary.chatGUID
        self.chatIdentifier = summary.chatIdentifier
        self.displayName = summary.displayName
        self.serviceName = summary.serviceName
        self.conversationVersion = summary.conversationVersion
        self.latestEventSequence = summary.latestEventSequence
        self.indexedAt = summary.indexedAt
        self.indexStatus = summary.indexStatus
    }
}

struct ConversationEventsResponse: Content {
    let conversationId: String
    let conversationVersion: Int
    let latestEventSequence: Int64
    let from: Int64
    let nextFrom: Int64
    let hasMore: Bool
    let events: [NormalizedConversationEvent]
}

struct ConversationResyncRequiredResponse: Content {
    let resyncRequired: Bool
    let conversationId: String
    let conversationVersion: Int
    let latestEventSequence: Int64
}

func chatRoutes(_ app: RoutesBuilder) {
    let conversations = app.grouped("conversations")

    conversations.get { req async throws -> ConversationListResponse in
        let summaries = try await req.appState.syncService.conversationSummaries()
        return ConversationListResponse(conversations: summaries.map(ConversationSummaryResponse.init))
    }

    conversations.get(":id", "events") { req async throws -> Response in
        guard let conversationID = req.parameters.get("id"), !conversationID.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid conversation ID")
        }

        guard let summary = try await req.appState.syncService.conversationSummary(id: conversationID) else {
            throw Abort(.notFound, reason: "Conversation not found")
        }

        guard let requestedVersion = req.query[Int.self, at: "conversationVersion"] else {
            throw Abort(.badRequest, reason: "Missing required 'conversationVersion' query parameter")
        }

        let from = req.query[Int64.self, at: "from"] ?? 0
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 500, 1), 1_000)

        if requestedVersion != summary.conversationVersion {
            let response = ConversationResyncRequiredResponse(
                resyncRequired: true,
                conversationId: summary.conversationID,
                conversationVersion: summary.conversationVersion,
                latestEventSequence: summary.latestEventSequence
            )
            return try jsonResponse(req: req, status: .conflict, body: response)
        }

        let events = try await req.appState.syncService.fetchEvents(
            conversationID: conversationID,
            conversationVersion: requestedVersion,
            afterSequence: from,
            limit: limit
        )
        let nextFrom = events.last?.eventSequence ?? from
        let response = ConversationEventsResponse(
            conversationId: summary.conversationID,
            conversationVersion: summary.conversationVersion,
            latestEventSequence: summary.latestEventSequence,
            from: from,
            nextFrom: nextFrom,
            hasMore: nextFrom < summary.latestEventSequence,
            events: events
        )
        return try jsonResponse(req: req, status: .ok, body: response)
    }
}

private func jsonResponse<T: Content>(req: Request, status: HTTPStatus, body: T) throws -> Response {
    let response = Response(status: status)
    try response.content.encode(body)
    return response
}
