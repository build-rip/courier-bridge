import Vapor
import CourierCore

func attachmentRoutes(_ app: RoutesBuilder) {
    // GET /api/attachments/:id - serve an attachment file
    app.get("attachments", ":id") { req -> Response in
        guard let attachmentRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid attachment ID")
        }

        guard let attachment = try req.appState.queries.attachment(rowID: attachmentRowID) else {
            throw Abort(.notFound, reason: "Attachment not found")
        }

        guard let filePath = attachment.resolvedPath else {
            throw Abort(.notFound, reason: "Attachment file path not available")
        }

        guard FileManager.default.fileExists(atPath: filePath) else {
            throw Abort(.notFound, reason: "Attachment file not found on disk")
        }

        var headers = HTTPHeaders()
        if let mimeType = attachment.resolvedMimeType {
            headers.contentType = HTTPMediaType(
                type: String(mimeType.split(separator: "/").first ?? "application"),
                subType: String(mimeType.split(separator: "/").last ?? "octet-stream")
            )
        }
        if let transferName = attachment.transferName {
            headers.add(
                name: .contentDisposition,
                value: "inline; filename=\"\(transferName)\""
            )
        }

        return try await req.fileio.asyncStreamFile(at: filePath, advancedETagComparison: false)
    }

    // GET /api/messages/:id/attachments - list attachments for a message
    app.get("messages", ":id", "attachments") { req -> [AttachmentResponse] in
        guard let messageRowID = req.parameters.get("id", as: Int64.self) else {
            throw Abort(.badRequest, reason: "Invalid message ID")
        }
        let attachments = try req.appState.queries.attachments(forMessageRowID: messageRowID)
        return attachments.map(AttachmentResponse.init)
    }
}

struct AttachmentResponse: Content {
    let rowID: Int64
    let guid: String
    let mimeType: String?
    let transferName: String?
    let totalBytes: Int64
    let isSticker: Bool

    init(from attachment: Attachment) {
        self.rowID = attachment.rowID
        self.guid = attachment.guid
        self.mimeType = attachment.resolvedMimeType
        self.transferName = attachment.transferName
        self.totalBytes = attachment.totalBytes
        self.isSticker = attachment.isSticker
    }
}
