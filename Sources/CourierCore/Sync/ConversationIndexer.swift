import CryptoKit
import Foundation

public struct ReducedReactionState: Sendable, Codable, Equatable {
    public let actorID: String?
    public let isFromMe: Bool
    public let sentAt: Date
    public let partIndex: Int
    public let reactionType: String
    public let emoji: String?
}

public struct ReducedMessageState: Sendable, Codable, Equatable {
    public let messageID: String
    public let senderID: String?
    public let isFromMe: Bool
    public let service: String?
    public let sentAt: Date
    public var text: String?
    public var richText: RichText?
    public let attachments: [NormalizedAttachment]
    public let replyToMessageID: String?
    public var editedAt: Date?
    public var deletedAt: Date?
    public var deliveredAt: Date?
    public var readAt: Date?
    public var reactions: [ReducedReactionState]
}

public struct ReducedConversationState: Sendable, Codable, Equatable {
    public let conversation: ConversationDescriptor
    public let conversationVersion: Int
    public let participants: [ConversationParticipant]
    public let messages: [ReducedMessageState]
}

public enum ConversationEventReducer {
    public static func reduce(
        conversation: ConversationDescriptor,
        participants: [ConversationParticipant],
        conversationVersion: Int,
        events: [NormalizedConversationEvent]
    ) -> ReducedConversationState {
        var messagesByID: [String: ReducedMessageState] = [:]
        var reactionKeysByMessageID: [String: [ReactionIdentity: ReducedReactionState]] = [:]

        for event in events {
            switch event.payload {
            case .messageCreated(let payload):
                messagesByID[payload.messageID] = ReducedMessageState(
                    messageID: payload.messageID,
                    senderID: payload.senderID,
                    isFromMe: payload.isFromMe,
                    service: payload.service,
                    sentAt: payload.sentAt,
                    text: payload.text,
                    richText: payload.richText,
                    attachments: payload.attachments,
                    replyToMessageID: payload.replyToMessageID,
                    editedAt: nil,
                    deletedAt: nil,
                    deliveredAt: nil,
                    readAt: nil,
                    reactions: []
                )
            case .messageEdited(let payload):
                guard var message = messagesByID[payload.messageID] else { continue }
                message.text = payload.text
                message.richText = payload.richText
                message.editedAt = payload.editedAt
                messagesByID[payload.messageID] = message
            case .messageDeleted(let payload):
                guard var message = messagesByID[payload.messageID] else { continue }
                message.deletedAt = payload.deletedAt
                messagesByID[payload.messageID] = message
            case .messageDeliveredUpdated(let payload):
                guard var message = messagesByID[payload.messageID] else { continue }
                message.deliveredAt = payload.deliveredAt
                messagesByID[payload.messageID] = message
            case .messageReadUpdated(let payload):
                guard var message = messagesByID[payload.messageID] else { continue }
                message.readAt = payload.readAt
                messagesByID[payload.messageID] = message
            case .reactionSet(let payload):
                guard messagesByID[payload.messageID] != nil else { continue }
                reactionKeysByMessageID[payload.messageID, default: [:]][ReactionIdentity(payload: payload)] =
                    ReducedReactionState(
                        actorID: payload.actorID,
                        isFromMe: payload.isFromMe,
                        sentAt: payload.sentAt,
                        partIndex: payload.partIndex,
                        reactionType: payload.reactionType,
                        emoji: payload.emoji
                    )
            case .reactionRemoved(let payload):
                reactionKeysByMessageID[payload.messageID]?[ReactionIdentity(payload: payload)] = nil
            }
        }

        let messages = messagesByID.values
            .map { message -> ReducedMessageState in
                var copy = message
                copy.reactions = (reactionKeysByMessageID[message.messageID] ?? [:]).values.sorted(by: reactionSort)
                return copy
            }
            .sorted(by: messageSort)

        return ReducedConversationState(
            conversation: conversation,
            conversationVersion: conversationVersion,
            participants: participants.sorted { $0.identifier < $1.identifier },
            messages: messages
        )
    }
}

public struct IndexedConversation: Sendable, Codable, Equatable {
    public let conversation: ConversationDescriptor
    public let conversationVersion: Int
    public let events: [NormalizedConversationEvent]
    public let diagnostics: ConversationSourceDiagnostics
    public let reducedState: ReducedConversationState
    public let finalStateHash: String

    public var latestEventSequence: Int64 {
        events.last?.eventSequence ?? 0
    }
}

public struct ConversationIndexer: Sendable {
    public let conversationVersion: Int

    public init(conversationVersion: Int) {
        self.conversationVersion = conversationVersion
    }

    public func index(snapshot: ConversationSourceSnapshot) throws -> IndexedConversation {
        let events = normalize(snapshot: snapshot)
        let reducedState = ConversationEventReducer.reduce(
            conversation: snapshot.conversation,
            participants: snapshot.participants,
            conversationVersion: conversationVersion,
            events: events
        )
        let finalStateHash = try hash(state: reducedState)

        return IndexedConversation(
            conversation: snapshot.conversation,
            conversationVersion: conversationVersion,
            events: events,
            diagnostics: snapshot.diagnostics,
            reducedState: reducedState,
            finalStateHash: finalStateHash
        )
    }

    private func normalize(snapshot: ConversationSourceSnapshot) -> [NormalizedConversationEvent] {
        let candidates = snapshot.messages.flatMap { sourceMessage in
            normalize(sourceMessage: sourceMessage)
        }

        let sortedCandidates = candidates.sorted {
            if $0.sortTimestamp != $1.sortTimestamp {
                return $0.sortTimestamp < $1.sortTimestamp
            }
            if $0.rowID != $1.rowID {
                return $0.rowID < $1.rowID
            }
            return $0.order < $1.order
        }

        return sortedCandidates.enumerated().map { index, candidate in
            NormalizedConversationEvent(
                conversationID: snapshot.conversation.conversationID,
                conversationVersion: conversationVersion,
                eventSequence: Int64(index + 1),
                payload: candidate.payload
            )
        }
    }

    private func normalize(sourceMessage: ConversationSourceMessage) -> [EventCandidate] {
        let message = sourceMessage.message
        var events: [EventCandidate] = []

        if message.isRegularMessage {
            events.append(
                EventCandidate(
                    sortTimestamp: message.date,
                    rowID: message.rowID,
                    order: 0,
                    payload: .messageCreated(
                        MessageCreatedEventPayload(
                            messageID: message.guid,
                            senderID: sourceMessage.senderID,
                            isFromMe: message.isFromMe,
                            service: ServiceAlias.publicValue(message.service),
                            sentAt: message.dateAsDate,
                            text: message.resolvedText,
                            richText: message.resolvedRichText,
                            attachments: sourceMessage.attachments.map(NormalizedAttachment.init),
                            replyToMessageID: message.replyToGUID.map(Message.stripGUIDPrefix)
                        )
                    )
                )
            )

            if let editedAt = message.dateEditedAsDate {
                events.append(
                    EventCandidate(
                        sortTimestamp: message.dateEdited,
                        rowID: message.rowID,
                        order: 1,
                        payload: .messageEdited(
                            MessageEditedEventPayload(
                                messageID: message.guid,
                                editedAt: editedAt,
                                text: message.resolvedText,
                                richText: message.resolvedRichText
                            )
                        )
                    )
                )
            }

            if let deliveredAt = message.dateDeliveredAsDate {
                events.append(
                    EventCandidate(
                        sortTimestamp: message.dateDelivered,
                        rowID: message.rowID,
                        order: 2,
                        payload: .messageDeliveredUpdated(
                            MessageDeliveredUpdatedEventPayload(
                                messageID: message.guid,
                                deliveredAt: deliveredAt
                            )
                        )
                    )
                )
            }

            if let readAt = message.dateReadAsDate {
                events.append(
                    EventCandidate(
                        sortTimestamp: message.dateRead,
                        rowID: message.rowID,
                        order: 3,
                        payload: .messageReadUpdated(
                            MessageReadUpdatedEventPayload(
                                messageID: message.guid,
                                readAt: readAt
                            )
                        )
                    )
                )
            }

            if message.isCurrentlyRetracted, let deletedAt = message.dateRetractedAsDate {
                events.append(
                    EventCandidate(
                        sortTimestamp: message.dateRetracted,
                        rowID: message.rowID,
                        order: 4,
                        payload: .messageDeleted(
                            MessageDeletedEventPayload(
                                messageID: message.guid,
                                deletedAt: deletedAt
                            )
                        )
                    )
                )
            }

            return events
        }

        guard message.isReaction,
              let targetMessageID = message.cleanAssociatedMessageGUID,
              let reactionType = message.reactionTypeName
        else {
            return events
        }

        let reactionPayload = ConversationReactionEventPayload(
            messageID: targetMessageID,
            actorID: sourceMessage.senderID,
            isFromMe: message.isFromMe,
            sentAt: message.dateAsDate,
            partIndex: message.reactionPartIndex,
            reactionType: reactionType,
            emoji: message.associatedMessageEmoji ?? message.reactionEmoji
        )

        events.append(
            EventCandidate(
                sortTimestamp: message.date,
                rowID: message.rowID,
                order: 0,
                payload: message.isReactionRemoval ? .reactionRemoved(reactionPayload) : .reactionSet(reactionPayload)
            )
        )

        return events
    }

    private func hash(state: ReducedConversationState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ConversationRebuildRun: Sendable {
    public let indexedConversations: [IndexedConversation]
    public let diagnostics: ConversationSourceDiagnostics

    public init(indexedConversations: [IndexedConversation], diagnostics: ConversationSourceDiagnostics) {
        self.indexedConversations = indexedConversations
        self.diagnostics = diagnostics
    }
}

public struct ConversationRebuildMismatch: Sendable, Codable, Equatable {
    public let conversationID: String
    public let expectedHash: String
    public let actualHash: String
    public let passIndex: Int
}

public struct ConversationRebuildVerificationReport: Sendable {
    public let runs: [ConversationRebuildRun]
    public let mismatches: [ConversationRebuildMismatch]

    public var isStable: Bool {
        mismatches.isEmpty
    }
}

public struct ConversationRebuildVerifier: Sendable {
    private let queries: ChatQueries
    private let indexer: ConversationIndexer

    public init(queries: ChatQueries, conversationVersion: Int) {
        self.queries = queries
        self.indexer = ConversationIndexer(conversationVersion: conversationVersion)
    }

    public func rebuildAll() throws -> ConversationRebuildRun {
        let snapshots = try queries.allConversationSnapshots()
        let indexedConversations = try snapshots.map(indexer.index)
        let diagnostics = snapshots
            .map(\.diagnostics)
            .reduce(ConversationSourceDiagnostics.empty) { partialResult, value in
                partialResult.merged(with: value)
            }

        return ConversationRebuildRun(indexedConversations: indexedConversations, diagnostics: diagnostics)
    }

    public func verifyStableRebuilds(passes: Int = 2) throws -> ConversationRebuildVerificationReport {
        let passCount = max(1, passes)
        let runs = try (0..<passCount).map { _ in
            try rebuildAll()
        }

        guard let baseline = runs.first else {
            return ConversationRebuildVerificationReport(runs: [], mismatches: [])
        }

        let baselineHashes = Dictionary(
            uniqueKeysWithValues: baseline.indexedConversations.map { ($0.conversation.conversationID, $0.finalStateHash) }
        )

        var mismatches: [ConversationRebuildMismatch] = []
        for (index, run) in runs.enumerated().dropFirst() {
            let hashes = Dictionary(
                uniqueKeysWithValues: run.indexedConversations.map { ($0.conversation.conversationID, $0.finalStateHash) }
            )

            let allConversationIDs = Set(baselineHashes.keys).union(hashes.keys)
            for conversationID in allConversationIDs.sorted() {
                let expected = baselineHashes[conversationID] ?? "<missing>"
                let actual = hashes[conversationID] ?? "<missing>"
                if expected != actual {
                    mismatches.append(
                        ConversationRebuildMismatch(
                            conversationID: conversationID,
                            expectedHash: expected,
                            actualHash: actual,
                            passIndex: index
                        )
                    )
                }
            }
        }

        return ConversationRebuildVerificationReport(runs: runs, mismatches: mismatches)
    }
}

private struct EventCandidate {
    let sortTimestamp: Int64
    let rowID: Int64
    let order: Int
    let payload: ConversationEventPayload
}

private struct ReactionIdentity: Hashable {
    let actorID: String?
    let isFromMe: Bool
    let partIndex: Int
    let reactionType: String
    let emoji: String?

    init(payload: ConversationReactionEventPayload) {
        self.actorID = payload.actorID
        self.isFromMe = payload.isFromMe
        self.partIndex = payload.partIndex
        self.reactionType = payload.reactionType
        self.emoji = payload.emoji
    }
}

private func messageSort(_ lhs: ReducedMessageState, _ rhs: ReducedMessageState) -> Bool {
    if lhs.sentAt != rhs.sentAt {
        return lhs.sentAt < rhs.sentAt
    }
    return lhs.messageID < rhs.messageID
}

private func reactionSort(_ lhs: ReducedReactionState, _ rhs: ReducedReactionState) -> Bool {
    if lhs.partIndex != rhs.partIndex {
        return lhs.partIndex < rhs.partIndex
    }
    if lhs.reactionType != rhs.reactionType {
        return lhs.reactionType < rhs.reactionType
    }
    if lhs.emoji != rhs.emoji {
        return (lhs.emoji ?? "") < (rhs.emoji ?? "")
    }
    if lhs.actorID != rhs.actorID {
        return (lhs.actorID ?? "") < (rhs.actorID ?? "")
    }
    if lhs.isFromMe != rhs.isFromMe {
        return lhs.isFromMe == false
    }
    return lhs.sentAt < rhs.sentAt
}
