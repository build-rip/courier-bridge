import Foundation
import GRDB
import Testing
@testable import CourierCore

@Suite("ChatQueries Attachment Lookup")
struct ChatQueriesAttachmentLookupTests {
    @Test("Attachment lookup accepts GUIDs and legacy row IDs")
    func attachmentLookupAcceptsGuidAndRowID() throws {
        let fixture = try AttachmentLookupFixture()
        defer { fixture.cleanup() }

        try fixture.seed()

        let queries = ChatQueries(db: try ChatDatabase(path: fixture.path))

        let byGuid = try #require(try queries.attachment(identifier: "at_0_message-1"))
        #expect(byGuid.rowID == 200)
        #expect(byGuid.guid == "at_0_message-1")

        let byRowID = try #require(try queries.attachment(identifier: "200"))
        #expect(byRowID.rowID == 200)
        #expect(byRowID.guid == "at_0_message-1")
    }
}

private struct AttachmentLookupFixture {
    let path: String

    init() throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chat-attachment-lookup-")
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("sqlite")
            .path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func seed() throws {
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE attachment (
                    guid TEXT NOT NULL,
                    filename TEXT,
                    mime_type TEXT,
                    transfer_name TEXT,
                    total_bytes INTEGER NOT NULL DEFAULT 0,
                    is_sticker INTEGER NOT NULL DEFAULT 0
                );
                """)

            try db.execute(
                sql: """
                    INSERT INTO attachment (
                        ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_sticker
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [200, "at_0_message-1", "~/Library/Messages/test.jpg", "image/jpeg", "test.jpg", 12345, 0]
            )
        }
    }
}
