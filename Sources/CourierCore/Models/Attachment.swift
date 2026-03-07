import Foundation
import GRDB

public struct Attachment: Sendable, Codable, FetchableRecord {
    public let rowID: Int64
    public let guid: String
    public let filename: String?
    public let mimeType: String?
    public let transferName: String?
    public let totalBytes: Int64
    public let isSticker: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case rowID = "ROWID"
        case guid
        case filename
        case mimeType = "mime_type"
        case transferName = "transfer_name"
        case totalBytes = "total_bytes"
        case isSticker = "is_sticker"
    }

    /// Resolve the full filesystem path for this attachment.
    /// Messages stores paths with `~/` prefix that needs expansion.
    public var resolvedPath: String? {
        guard let filename else { return nil }
        if filename.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return filename.replacingOccurrences(of: "~", with: home, range: filename.startIndex..<filename.index(after: filename.startIndex))
        }
        return filename
    }

    /// Resolve the MIME type, detecting from file magic bytes if the database value is null.
    /// Plugin payload attachments (link preview thumbnails) have null mime_type but are JPEG/PNG images.
    public var resolvedMimeType: String? {
        if let mimeType { return mimeType }
        guard let path = resolvedPath,
              transferName?.hasSuffix(".pluginPayloadAttachment") == true else { return nil }
        return Attachment.detectMimeType(atPath: path)
    }

    /// Detect MIME type from file magic bytes.
    private static func detectMimeType(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 8)
        guard header.count >= 3 else { return nil }
        let bytes = [UInt8](header)
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if header.count >= 8 &&
           bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
           bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A {
            return "image/png"
        }
        if header.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        return "application/octet-stream"
    }
}
