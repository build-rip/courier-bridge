import Vapor
import JWT
import CourierCore

/// Shared application state accessible from routes.
struct AppState: Sendable {
    let chatDB: ChatDatabase
    let queries: ChatQueries
    let poller: MessagePoller
    let fileWatcher: FileWatcher
    let sender: AppleScriptSender
    let uiAutomation: UIAutomation
    let bridgeDB: BridgeDatabase
    let wsController: WebSocketController
}

/// Storage key for AppState.
struct AppStateKey: StorageKey {
    typealias Value = AppState
}

extension Application {
    var appState: AppState {
        get { storage[AppStateKey.self]! }
        set { storage[AppStateKey.self] = newValue }
    }
}

extension Request {
    var appState: AppState {
        application.appState
    }
}

func configure(_ app: Application) async throws {
    // Initialize Messages database
    let chatDB = try ChatDatabase()
    let queries = ChatQueries(db: chatDB)

    print("[Bridge] Connected to Messages database at \(chatDB.path)")
    let count = try queries.messageCount()
    print("[Bridge] Found \(count) messages")

    // Initialize bridge database (for auth/pairing)
    let bridgeDB = try BridgeDatabase()

    // Initialize message poller and file watcher
    let poller = try MessagePoller(queries: queries)
    let fileWatcher = try FileWatcher(dbPath: chatDB.path) {
        Task { await poller.onChange() }
    }

    // Initialize sender
    let sender = AppleScriptSender()
    let uiAutomation = UIAutomation()

    // Initialize WebSocket controller
    let wsController = WebSocketController()

    let state = AppState(
        chatDB: chatDB,
        queries: queries,
        poller: poller,
        fileWatcher: fileWatcher,
        sender: sender,
        uiAutomation: uiAutomation,
        bridgeDB: bridgeDB,
        wsController: wsController
    )
    app.appState = state

    // Configure JWT
    let secret = try bridgeDB.getOrCreateHMACSecret()
    await app.jwt.keys.add(hmac: HMACKey(from: secret), digestAlgorithm: .sha256)

    // Serve static files
    if let publicResourcesURL = BridgeAppConfiguration.publicResourcesURL {
        app.middleware.use(FileMiddleware(publicDirectory: publicResourcesURL.path))
    }

    // Register routes
    try registerRoutes(app)

    // Start file watcher and event streaming
    fileWatcher.start()
    await poller.start()

    // Start broadcasting events to WebSocket clients
    let eventStream = await poller.eventStream()
    Task {
        for await event in eventStream {
            await wsController.broadcast(event: event)
        }
    }

    let port = Int(Environment.get("PORT") ?? "7820") ?? 7820
    app.http.server.configuration.port = port
    app.http.server.configuration.reuseAddress = true
    print("[Bridge] Server starting on http://localhost:\(port)")
}
