import Foundation

/// Watches the Messages chat.db files for changes using kqueue/DispatchSource.
public final class FileWatcher: Sendable {
    private let onChange: @Sendable () -> Void
    private let sources: [DispatchSourceFileSystemObject]
    private let queue: DispatchQueue

    /// Create a watcher on the chat.db, chat.db-wal, and chat.db-shm files.
    public init(dbPath: String, onChange: @escaping @Sendable () -> Void) throws {
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.courier-bridge.filewatcher")

        let paths = [dbPath, "\(dbPath)-wal", "\(dbPath)-shm"]
        var createdSources: [DispatchSourceFileSystemObject] = []

        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename],
                queue: queue
            )
            source.setEventHandler { [onChange] in
                onChange()
            }
            source.setCancelHandler {
                close(fd)
            }
            createdSources.append(source)
        }

        guard !createdSources.isEmpty else {
            throw FileWatcherError.noFilesToWatch
        }

        self.sources = createdSources
    }

    public func start() {
        for source in sources {
            source.resume()
        }
    }

    public func stop() {
        for source in sources {
            source.cancel()
        }
    }
}

public enum FileWatcherError: Error {
    case noFilesToWatch
}
