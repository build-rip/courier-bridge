import Foundation

/// Events emitted when new messages/changes are detected.
public enum MessageEvent: Sendable {
    case newMessage(MessageEventPayload)
    case reaction(ReactionEventPayload)
    case readReceipt(ReadReceiptPayload)
    case deliveryReceipt(DeliveryReceiptPayload)
}

public struct MessageEventPayload: Sendable, Codable {
    public let messageRowID: Int64
    public let chatRowID: Int64
    public let guid: String
    public let text: String?
    public let richText: RichText?
    public let senderID: String?
    public let isFromMe: Bool
    public let service: String?
    public let date: Date
    public let isRead: Bool
    public let hasAttachments: Bool
    public let balloonBundleID: String?
    public let threadOriginatorGuid: String?
    public let linkPreviewTitle: String?
    public let linkPreviewSubtitle: String?
    public let linkPreviewURL: String?

    public init(message: Message, chatRowID: Int64, senderID: String?) {
        self.messageRowID = message.rowID
        self.chatRowID = chatRowID
        self.guid = message.guid
        self.text = message.resolvedText
        self.richText = message.resolvedRichText
        self.senderID = senderID
        self.isFromMe = message.isFromMe
        self.service = ServiceAlias.publicValue(message.service)
        self.date = message.dateAsDate
        self.isRead = message.isRead
        self.hasAttachments = message.cacheHasAttachments
        self.balloonBundleID = message.balloonBundleID
        self.threadOriginatorGuid = message.threadOriginatorGuid
        let lm = message.linkMetadata
        self.linkPreviewTitle = lm?.title
        self.linkPreviewSubtitle = lm?.subtitle
        self.linkPreviewURL = lm?.url
    }
}

public struct ReactionEventPayload: Sendable, Codable {
    public let messageRowID: Int64
    public let chatRowID: Int64
    public let guid: String
    public let targetMessageGUID: String
    public let partIndex: Int
    public let reactionType: String
    public let emoji: String?
    public let isRemoval: Bool
    public let senderID: String?
    public let isFromMe: Bool
    public let date: Date

    public init(message: Message, chatRowID: Int64, senderID: String?) {
        self.messageRowID = message.rowID
        self.chatRowID = chatRowID
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

public struct ReadReceiptPayload: Sendable, Codable {
    public let messageRowID: Int64
    public let chatRowID: Int64
    public let guid: String
    public let dateRead: Date

    public init(message: Message, chatRowID: Int64, dateRead: Date) {
        self.messageRowID = message.rowID
        self.chatRowID = chatRowID
        self.guid = message.guid
        self.dateRead = dateRead
    }
}

public struct DeliveryReceiptPayload: Sendable, Codable {
    public let messageRowID: Int64
    public let chatRowID: Int64
    public let guid: String
    public let dateDelivered: Date

    public init(message: Message, chatRowID: Int64, dateDelivered: Date) {
        self.messageRowID = message.rowID
        self.chatRowID = chatRowID
        self.guid = message.guid
        self.dateDelivered = dateDelivered
    }
}

/// Wraps a MessageEvent for JSON serialization over WebSocket.
public struct MessageEventEnvelope: Sendable, Codable {
    public let type: String
    public let payload: MessageEventJSON
    public let timestamp: Date

    public init(event: MessageEvent) {
        self.timestamp = Date()
        switch event {
        case .newMessage(let payload):
            self.type = "newMessage"
            self.payload = .newMessage(payload)
        case .reaction(let payload):
            self.type = "reaction"
            self.payload = .reaction(payload)
        case .readReceipt(let payload):
            self.type = "readReceipt"
            self.payload = .readReceipt(payload)
        case .deliveryReceipt(let payload):
            self.type = "deliveryReceipt"
            self.payload = .deliveryReceipt(payload)
        }
    }
}

public enum MessageEventJSON: Sendable, Codable {
    case newMessage(MessageEventPayload)
    case reaction(ReactionEventPayload)
    case readReceipt(ReadReceiptPayload)
    case deliveryReceipt(DeliveryReceiptPayload)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .newMessage(let p): try container.encode(p)
        case .reaction(let p): try container.encode(p)
        case .readReceipt(let p): try container.encode(p)
        case .deliveryReceipt(let p): try container.encode(p)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let p = try? container.decode(MessageEventPayload.self) {
            self = .newMessage(p)
        } else if let p = try? container.decode(ReactionEventPayload.self) {
            self = .reaction(p)
        } else if let p = try? container.decode(ReadReceiptPayload.self) {
            self = .readReceipt(p)
        } else {
            self = .deliveryReceipt(try container.decode(DeliveryReceiptPayload.self))
        }
    }
}
