import Foundation

public struct ConversationDescriptor: Sendable, Codable, Equatable {
    public let rowID: Int64
    public let conversationID: String
    public let chatGUID: String
    public let chatIdentifier: String
    public let displayName: String?
    public let serviceName: String?
    public let groupID: String?

    public init(
        rowID: Int64,
        conversationID: String,
        chatGUID: String,
        chatIdentifier: String,
        displayName: String?,
        serviceName: String?,
        groupID: String?
    ) {
        self.rowID = rowID
        self.conversationID = conversationID
        self.chatGUID = chatGUID
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.serviceName = serviceName
        self.groupID = groupID
    }
}

public struct ConversationParticipant: Sendable, Codable, Equatable {
    public let handleID: Int64
    public let identifier: String
    public let service: String?
    public let country: String?

    public init(handleID: Int64, identifier: String, service: String?, country: String?) {
        self.handleID = handleID
        self.identifier = identifier
        self.service = service
        self.country = country
    }
}

public struct ConversationSourceMessage: Sendable, Codable {
    public let message: Message
    public let senderID: String?
    public let attachments: [Attachment]

    public init(message: Message, senderID: String?, attachments: [Attachment]) {
        self.message = message
        self.senderID = senderID
        self.attachments = attachments
    }
}

public struct ConversationSourceSnapshot: Sendable, Codable {
    public let conversation: ConversationDescriptor
    public let participants: [ConversationParticipant]
    public let messages: [ConversationSourceMessage]

    public init(
        conversation: ConversationDescriptor,
        participants: [ConversationParticipant],
        messages: [ConversationSourceMessage]
    ) {
        self.conversation = conversation
        self.participants = participants
        self.messages = messages
    }

    public var diagnostics: ConversationSourceDiagnostics {
        ConversationSourceDiagnostics(messages: messages)
    }
}

public struct SourceValueBucket: Sendable, Codable, Equatable {
    public let value: Int64
    public let count: Int

    public init(value: Int64, count: Int) {
        self.value = value
        self.count = count
    }
}

public struct ConversationSourceDiagnostics: Sendable, Codable, Equatable {
    public let editedCount: Int
    public let retractedCount: Int
    public let recoveredCount: Int
    public let associatedMessageTypeBuckets: [SourceValueBucket]
    public let itemTypeBuckets: [SourceValueBucket]
    public let messageActionTypeBuckets: [SourceValueBucket]
    public let unknownAssociatedMessageTypeBuckets: [SourceValueBucket]

    public init(
        editedCount: Int,
        retractedCount: Int,
        recoveredCount: Int,
        associatedMessageTypeBuckets: [SourceValueBucket],
        itemTypeBuckets: [SourceValueBucket],
        messageActionTypeBuckets: [SourceValueBucket],
        unknownAssociatedMessageTypeBuckets: [SourceValueBucket]
    ) {
        self.editedCount = editedCount
        self.retractedCount = retractedCount
        self.recoveredCount = recoveredCount
        self.associatedMessageTypeBuckets = associatedMessageTypeBuckets
        self.itemTypeBuckets = itemTypeBuckets
        self.messageActionTypeBuckets = messageActionTypeBuckets
        self.unknownAssociatedMessageTypeBuckets = unknownAssociatedMessageTypeBuckets
    }

    public init(messages: [ConversationSourceMessage]) {
        let sourceMessages = messages.map(\.message)
        self.init(
            editedCount: sourceMessages.filter(\.isEdited).count,
            retractedCount: sourceMessages.filter(\.isRetracted).count,
            recoveredCount: sourceMessages.filter(\.isRecovered).count,
            associatedMessageTypeBuckets: Self.buckets(from: sourceMessages.map(\.associatedMessageType).filter { $0 != 0 }),
            itemTypeBuckets: Self.buckets(from: sourceMessages.map(\.itemType).filter { $0 != 0 }),
            messageActionTypeBuckets: Self.buckets(from: sourceMessages.map(\.messageActionType).filter { $0 != 0 }),
            unknownAssociatedMessageTypeBuckets: Self.buckets(
                from: sourceMessages
                    .map(\.associatedMessageType)
                    .filter { $0 != 0 && !Self.isKnownAssociatedMessageType($0) }
            )
        )
    }

    public func merged(with other: ConversationSourceDiagnostics) -> ConversationSourceDiagnostics {
        ConversationSourceDiagnostics(
            editedCount: editedCount + other.editedCount,
            retractedCount: retractedCount + other.retractedCount,
            recoveredCount: recoveredCount + other.recoveredCount,
            associatedMessageTypeBuckets: Self.mergeBuckets(associatedMessageTypeBuckets, other.associatedMessageTypeBuckets),
            itemTypeBuckets: Self.mergeBuckets(itemTypeBuckets, other.itemTypeBuckets),
            messageActionTypeBuckets: Self.mergeBuckets(messageActionTypeBuckets, other.messageActionTypeBuckets),
            unknownAssociatedMessageTypeBuckets: Self.mergeBuckets(
                unknownAssociatedMessageTypeBuckets,
                other.unknownAssociatedMessageTypeBuckets
            )
        )
    }

    public static var empty: ConversationSourceDiagnostics {
        ConversationSourceDiagnostics(
            editedCount: 0,
            retractedCount: 0,
            recoveredCount: 0,
            associatedMessageTypeBuckets: [],
            itemTypeBuckets: [],
            messageActionTypeBuckets: [],
            unknownAssociatedMessageTypeBuckets: []
        )
    }

    private static func buckets(from values: [Int64]) -> [SourceValueBucket] {
        let counts = values.reduce(into: [Int64: Int]()) { partialResult, value in
            partialResult[value, default: 0] += 1
        }

        return counts
            .map { SourceValueBucket(value: $0.key, count: $0.value) }
            .sorted { lhs, rhs in lhs.value < rhs.value }
    }

    private static func mergeBuckets(
        _ lhs: [SourceValueBucket],
        _ rhs: [SourceValueBucket]
    ) -> [SourceValueBucket] {
        let merged = (lhs + rhs).reduce(into: [Int64: Int]()) { partialResult, bucket in
            partialResult[bucket.value, default: 0] += bucket.count
        }

        return merged
            .map { SourceValueBucket(value: $0.key, count: $0.value) }
            .sorted { $0.value < $1.value }
    }

    private static func isKnownAssociatedMessageType(_ value: Int64) -> Bool {
        value >= 2000 && value < 4000
    }
}
