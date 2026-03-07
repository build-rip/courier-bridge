import Foundation
import GRDB

public struct Handle: Sendable, Codable, FetchableRecord {
    public let rowID: Int64
    public let id: String  // phone number or email
    public let service: String?
    public let country: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case rowID = "ROWID"
        case id
        case service
        case country
    }
}
