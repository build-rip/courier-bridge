import Foundation
import Testing
@testable import CourierBridge
@testable import CourierCore

@Suite("Bridge Database Conversation Sync")
struct BridgeDatabaseConversationSyncTests {
    @Test("Persists conversation summaries and event pages")
    func persistsConversationSummariesAndEvents() throws {
        let fixture = try BridgeDatabaseFixture()
        defer { fixture.cleanup() }

        let db = try BridgeDatabase(path: fixture.path)
        let indexedConversation = try makeIndexedConversation(conversationID: "chat-1", messageID: "m-1")

        try db.replaceConversationIndex(indexedConversation)

        let summaries = try db.listConversationSummaries()
        #expect(summaries.count == 1)

        let summary = try #require(summaries.first)
        #expect(summary.conversationID == "chat-1")
        #expect(summary.conversationVersion == 3)
        #expect(summary.latestEventSequence == Int64(indexedConversation.events.count))

        let firstPage = try db.fetchConversationEvents(
            conversationID: "chat-1",
            conversationVersion: 3,
            afterSequence: 0,
            limit: 1
        )
        #expect(firstPage.count == 1)
        #expect(firstPage.first?.eventType == .messageCreated)

        let secondPage = try db.fetchConversationEvents(
            conversationID: "chat-1",
            conversationVersion: 3,
            afterSequence: 1,
            limit: 10
        )
        #expect(secondPage.count == indexedConversation.events.count - 1)
    }

    @Test("replaceAllConversationIndexes removes stale conversations")
    func replaceAllConversationIndexesRemovesStaleConversations() throws {
        let fixture = try BridgeDatabaseFixture()
        defer { fixture.cleanup() }

        let db = try BridgeDatabase(path: fixture.path)
        let first = try makeIndexedConversation(conversationID: "chat-1", messageID: "m-1")
        let second = try makeIndexedConversation(conversationID: "chat-2", messageID: "m-2")

        try db.replaceAllConversationIndexes([first, second])
        #expect(try db.listConversationSummaries().count == 2)

        try db.replaceAllConversationIndexes([first])

        let summaries = try db.listConversationSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.conversationID == "chat-1")
        #expect(try db.conversationSummary(id: "chat-2") == nil)
    }
}

private struct BridgeDatabaseFixture {
    let path: String

    init() throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-db-tests-\(UUID().uuidString).sqlite")
            .path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func makeIndexedConversation(conversationID: String, messageID: String) throws -> IndexedConversation {
    let snapshot = ConversationSourceSnapshot(
        conversation: ConversationDescriptor(
            rowID: 1,
            conversationID: conversationID,
            chatGUID: conversationID,
            chatIdentifier: "chat:\(conversationID)",
            displayName: "Test \(conversationID)",
            serviceName: "iMessage",
            groupID: nil
        ),
        participants: [
            ConversationParticipant(handleID: 1, identifier: "+15555550100", service: "iMessage", country: "US"),
        ],
        messages: [
            ConversationSourceMessage(
                message: Message(
                    rowID: 1,
                    guid: messageID,
                    text: "hello",
                    attributedBody: nil,
                    handleID: 1,
                    date: AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_000)),
                    dateRead: AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_010)),
                    dateDelivered: AppleDate.fromDate(Date(timeIntervalSince1970: 1_700_000_005)),
                    isRead: true,
                    isFromMe: false,
                    service: "iMessage",
                    associatedMessageGUID: nil,
                    associatedMessageType: 0,
                    associatedMessageEmoji: nil,
                    replyToGUID: nil,
                    partCount: 0,
                    dateEdited: 0,
                    dateRetracted: 0,
                    dateRecovered: 0,
                    messageActionType: 0,
                    itemType: 0,
                    groupTitle: nil,
                    isAudioMessage: false,
                    cacheHasAttachments: false,
                    balloonBundleID: nil,
                    threadOriginatorGuid: nil,
                    payloadData: nil
                ),
                senderID: "+15555550100",
                attachments: []
            ),
        ]
    )

    return try ConversationIndexer(conversationVersion: 3).index(snapshot: snapshot)
}
