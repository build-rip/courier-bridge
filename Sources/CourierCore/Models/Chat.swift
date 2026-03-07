import Foundation
import GRDB

public struct Chat: Sendable, Codable, FetchableRecord {
    public let rowID: Int64
    public let guid: String
    public let chatIdentifier: String
    public let displayName: String?
    public let serviceName: String?
    public let groupID: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case rowID = "ROWID"
        case guid
        case chatIdentifier = "chat_identifier"
        case displayName = "display_name"
        case serviceName = "service_name"
        case groupID = "group_id"
    }

    /// Whether this is a group chat (has multiple participants).
    public var isGroup: Bool {
        chatIdentifier.hasPrefix("chat")
    }
}
