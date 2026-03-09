import Foundation

public enum ConversationEventType: String, Sendable, Codable, Equatable {
    case messageCreated
    case messageEdited
    case messageDeleted
    case reactionSet
    case reactionRemoved
    case messageReadUpdated
    case messageDeliveredUpdated
}

public struct NormalizedAttachment: Sendable, Codable, Equatable {
    public let attachmentID: String
    public let transferName: String?
    public let mimeType: String?
    public let totalBytes: Int64
    public let isSticker: Bool

    public init(attachment: Attachment) {
        self.attachmentID = attachment.guid
        self.transferName = attachment.transferName
        self.mimeType = attachment.resolvedMimeType
        self.totalBytes = attachment.totalBytes
        self.isSticker = attachment.isSticker
    }
}

public struct MessageCreatedEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let senderID: String?
    public let isFromMe: Bool
    public let service: String?
    public let sentAt: Date
    public let text: String?
    public let richText: RichText?
    public let attachments: [NormalizedAttachment]
    public let replyToMessageID: String?
}

public struct MessageEditedEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let editedAt: Date
    public let text: String?
    public let richText: RichText?
}

public struct MessageDeletedEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let deletedAt: Date
}

public struct ConversationReactionEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let actorID: String?
    public let isFromMe: Bool
    public let sentAt: Date
    public let partIndex: Int
    public let reactionType: String
    public let emoji: String?
}

public struct MessageReadUpdatedEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let readAt: Date
}

public struct MessageDeliveredUpdatedEventPayload: Sendable, Codable, Equatable {
    public let messageID: String
    public let deliveredAt: Date
}

public enum ConversationEventPayload: Sendable, Equatable {
    case messageCreated(MessageCreatedEventPayload)
    case messageEdited(MessageEditedEventPayload)
    case messageDeleted(MessageDeletedEventPayload)
    case reactionSet(ConversationReactionEventPayload)
    case reactionRemoved(ConversationReactionEventPayload)
    case messageReadUpdated(MessageReadUpdatedEventPayload)
    case messageDeliveredUpdated(MessageDeliveredUpdatedEventPayload)
}

public struct NormalizedConversationEvent: Sendable, Codable, Equatable {
    public let conversationID: String
    public let conversationVersion: Int
    public let eventSequence: Int64
    public let eventType: ConversationEventType
    public let payload: ConversationEventPayload

    public init(
        conversationID: String,
        conversationVersion: Int,
        eventSequence: Int64,
        payload: ConversationEventPayload
    ) {
        self.conversationID = conversationID
        self.conversationVersion = conversationVersion
        self.eventSequence = eventSequence
        self.payload = payload
        self.eventType = payload.eventType
    }

    enum CodingKeys: String, CodingKey {
        case conversationID
        case conversationVersion
        case eventSequence
        case eventType
        case payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(conversationVersion, forKey: .conversationVersion)
        try container.encode(eventSequence, forKey: .eventSequence)
        try container.encode(eventType, forKey: .eventType)

        switch payload {
        case .messageCreated(let value):
            try container.encode(value, forKey: .payload)
        case .messageEdited(let value):
            try container.encode(value, forKey: .payload)
        case .messageDeleted(let value):
            try container.encode(value, forKey: .payload)
        case .reactionSet(let value):
            try container.encode(value, forKey: .payload)
        case .reactionRemoved(let value):
            try container.encode(value, forKey: .payload)
        case .messageReadUpdated(let value):
            try container.encode(value, forKey: .payload)
        case .messageDeliveredUpdated(let value):
            try container.encode(value, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        conversationVersion = try container.decode(Int.self, forKey: .conversationVersion)
        eventSequence = try container.decode(Int64.self, forKey: .eventSequence)
        eventType = try container.decode(ConversationEventType.self, forKey: .eventType)

        switch eventType {
        case .messageCreated:
            payload = .messageCreated(try container.decode(MessageCreatedEventPayload.self, forKey: .payload))
        case .messageEdited:
            payload = .messageEdited(try container.decode(MessageEditedEventPayload.self, forKey: .payload))
        case .messageDeleted:
            payload = .messageDeleted(try container.decode(MessageDeletedEventPayload.self, forKey: .payload))
        case .reactionSet:
            payload = .reactionSet(try container.decode(ConversationReactionEventPayload.self, forKey: .payload))
        case .reactionRemoved:
            payload = .reactionRemoved(try container.decode(ConversationReactionEventPayload.self, forKey: .payload))
        case .messageReadUpdated:
            payload = .messageReadUpdated(try container.decode(MessageReadUpdatedEventPayload.self, forKey: .payload))
        case .messageDeliveredUpdated:
            payload = .messageDeliveredUpdated(
                try container.decode(MessageDeliveredUpdatedEventPayload.self, forKey: .payload)
            )
        }
    }
}

extension ConversationEventPayload {
    fileprivate var eventType: ConversationEventType {
        switch self {
        case .messageCreated: return .messageCreated
        case .messageEdited: return .messageEdited
        case .messageDeleted: return .messageDeleted
        case .reactionSet: return .reactionSet
        case .reactionRemoved: return .reactionRemoved
        case .messageReadUpdated: return .messageReadUpdated
        case .messageDeliveredUpdated: return .messageDeliveredUpdated
        }
    }
}
