import Foundation
import GRDB

public struct Message: Sendable, Codable, FetchableRecord {
    public let rowID: Int64
    public let guid: String
    public let text: String?
    public let attributedBody: Data?
    public let handleID: Int64
    public let date: Int64
    public let dateRead: Int64
    public let dateDelivered: Int64
    public let isRead: Bool
    public let isFromMe: Bool
    public let service: String?
    public let associatedMessageGUID: String?
    public let associatedMessageType: Int64
    public let associatedMessageEmoji: String?
    public let replyToGUID: String?
    public let partCount: Int64
    public let dateEdited: Int64
    public let dateRetracted: Int64
    public let dateRecovered: Int64
    public let messageActionType: Int64
    public let itemType: Int64
    public let groupTitle: String?
    public let isAudioMessage: Bool
    public let cacheHasAttachments: Bool
    public let balloonBundleID: String?
    public let threadOriginatorGuid: String?
    public let payloadData: Data?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case rowID = "ROWID"
        case guid
        case text
        case attributedBody = "attributedBody"
        case handleID = "handle_id"
        case date
        case dateRead = "date_read"
        case dateDelivered = "date_delivered"
        case isRead = "is_read"
        case isFromMe = "is_from_me"
        case service
        case associatedMessageGUID = "associated_message_guid"
        case associatedMessageType = "associated_message_type"
        case associatedMessageEmoji = "associated_message_emoji"
        case replyToGUID = "reply_to_guid"
        case partCount = "part_count"
        case dateEdited = "date_edited"
        case dateRetracted = "date_retracted"
        case dateRecovered = "date_recovered"
        case messageActionType = "message_action_type"
        case itemType = "item_type"
        case groupTitle = "group_title"
        case isAudioMessage = "is_audio_message"
        case cacheHasAttachments = "cache_has_attachments"
        case balloonBundleID = "balloon_bundle_id"
        case threadOriginatorGuid = "thread_originator_guid"
        case payloadData = "payload_data"
    }

    /// The decoded text content, preferring `text` and falling back to `attributedBody`.
    public var resolvedText: String? {
        if let text, !text.isEmpty {
            return text
        }
        if let attributedBody {
            return AttributedBodyParser.extractText(from: attributedBody)
        }
        return nil
    }

    /// Parse the attributedBody to extract both plain text and rich text formatting.
    /// Returns nil if no attributedBody data is present.
    public var parsedBody: ParsedBody? {
        guard let attributedBody else { return nil }
        return AttributedBodyParser.parse(from: attributedBody)
    }

    /// The resolved rich text for this message, if any formatting is present.
    /// Returns nil if the message has no formatting or no attributedBody.
    public var resolvedRichText: RichText? {
        // Only extract rich text from attributedBody -- plain text messages don't have formatting
        guard let attributedBody else { return nil }
        let parsed = AttributedBodyParser.parse(from: attributedBody)
        return parsed.richText
    }

    /// Parsed link preview metadata for URLBalloonProvider messages.
    public var linkMetadata: LinkPreviewMetadata? {
        guard balloonBundleID == "com.apple.messages.URLBalloonProvider",
              let payloadData else { return nil }
        return LinkPreviewParser.parse(from: payloadData)
    }

    public var dateAsDate: Date {
        AppleDate.toDate(date)
    }

    public var dateReadAsDate: Date? {
        dateRead == 0 ? nil : AppleDate.toDate(dateRead)
    }

    public var dateDeliveredAsDate: Date? {
        dateDelivered == 0 ? nil : AppleDate.toDate(dateDelivered)
    }

    public var dateEditedAsDate: Date? {
        dateEdited == 0 ? nil : AppleDate.toDate(dateEdited)
    }

    public var dateRetractedAsDate: Date? {
        dateRetracted == 0 ? nil : AppleDate.toDate(dateRetracted)
    }

    public var dateRecoveredAsDate: Date? {
        dateRecovered == 0 ? nil : AppleDate.toDate(dateRecovered)
    }

    public var isEdited: Bool {
        dateEdited != 0
    }

    public var isRetracted: Bool {
        dateRetracted != 0
    }

    public var isRecovered: Bool {
        dateRecovered != 0
    }

    public var isCurrentlyRetracted: Bool {
        isRetracted && !isRecovered
    }

    /// Whether this message is a reaction/tapback rather than a regular message.
    public var isReaction: Bool {
        associatedMessageType >= 2000 && associatedMessageType < 4000
    }

    public var isRegularMessage: Bool {
        associatedMessageType == 0
    }

    /// The tapback type if this is a reaction.
    public var reactionType: ReactionType? {
        ReactionType(rawValue: associatedMessageType)
    }

    /// The cleaned associated message GUID with Messages prefixes stripped.
    /// Raw format: "p:0/AABBCCDD-..." or "bp:AABBCCDD-..." → "AABBCCDD-..."
    public var cleanAssociatedMessageGUID: String? {
        guard let guid = associatedMessageGUID else { return nil }
        return Message.stripGUIDPrefix(guid)
    }

    /// Strip Messages GUID prefixes like "p:0/", "p:1/", "bp:".
    public static func stripGUIDPrefix(_ guid: String) -> String {
        // "p:0/UUID", "p:1/UUID" etc. — take everything after the first slash
        if guid.hasPrefix("p:"),
           let slashIndex = guid.firstIndex(of: "/") {
            return String(guid[guid.index(after: slashIndex)...])
        }
        // "bp:UUID" — drop the "bp:" prefix
        if guid.hasPrefix("bp:") {
            return String(guid.dropFirst(3))
        }
        return guid
    }

    /// The reaction type as a clean string (love, like, etc.) if this is a reaction.
    public var reactionTypeName: String? {
        guard isReaction else { return nil }
        let base = associatedMessageType >= 3000 ? associatedMessageType - 1000 : associatedMessageType
        switch base {
        case 2000: return "love"
        case 2001: return "like"
        case 2002: return "dislike"
        case 2003: return "laugh"
        case 2004: return "emphasis"
        case 2005: return "question"
        case 2006: return "emoji"
        case 2007: return "sticker"
        default: return nil
        }
    }

    /// Whether this reaction is a removal (type 3000-3005 for standard, 3006 for emoji, 3007 for sticker).
    public var isReactionRemoval: Bool {
        associatedMessageType >= 3000 && associatedMessageType < 4000
    }

    /// The emoji character for emoji reactions (type 2006/3006).
    /// Extracted from the attributedBody text which contains "Reacted {emoji} to ..." or localized equivalent.
    public var reactionEmoji: String? {
        let base = associatedMessageType >= 3000 ? associatedMessageType - 1000 : associatedMessageType
        guard base == 2006 else { return nil }
        guard let attributedBody else { return nil }
        guard let text = AttributedBodyParser.extractText(from: attributedBody) else { return nil }
        for char in text {
            if char.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) {
                return String(char)
            }
        }
        return nil
    }

    /// The 0-based part index this reaction targets.
    /// Extracted from the `p:N/GUID` format in `associatedMessageGUID`.
    /// Parts are numbered sequentially left-to-right through the message body —
    /// each text segment and each U+FFFC attachment placeholder is one part.
    public var reactionPartIndex: Int {
        guard let guid = associatedMessageGUID,
              guid.hasPrefix("p:"),
              let slashIndex = guid.firstIndex(of: "/"),
              let n = Int(guid[guid.index(guid.startIndex, offsetBy: 2)..<slashIndex])
        else { return 0 }
        return n
    }
}

public enum ReactionType: Int64, Sendable, Codable {
    case love = 2000
    case like = 2001
    case dislike = 2002
    case laugh = 2003
    case emphasis = 2004
    case question = 2005
    case emoji = 2006
    case sticker = 2007
    // Removal variants (add 1000)
    case removeLove = 3000
    case removeLike = 3001
    case removeDislike = 3002
    case removeLaugh = 3003
    case removeEmphasis = 3004
    case removeQuestion = 3005
    case removeEmoji = 3006
    case removeSticker = 3007
}
