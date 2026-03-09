import Foundation

public struct ConversationCursorUpdate: Sendable, Codable, Equatable {
    public let conversationID: String
    public let conversationVersion: Int
    public let latestEventSequence: Int64

    public init(conversationID: String, conversationVersion: Int, latestEventSequence: Int64) {
        self.conversationID = conversationID
        self.conversationVersion = conversationVersion
        self.latestEventSequence = latestEventSequence
    }
}

public struct ConversationCursorUpdateEnvelope: Sendable, Codable, Equatable {
    public let type: String
    public let payload: ConversationCursorUpdate
    public let timestamp: Date

    public init(payload: ConversationCursorUpdate, timestamp: Date = Date()) {
        self.type = "conversationCursorUpdated"
        self.payload = payload
        self.timestamp = timestamp
    }
}
