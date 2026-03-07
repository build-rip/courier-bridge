import Foundation
import GRDB

public final class ChatDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String? = nil) throws {
        let dbPath = path ?? Self.defaultPath
        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    private static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Messages/chat.db"
    }

    public var path: String {
        dbQueue.path
    }
}
