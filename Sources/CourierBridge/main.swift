import AppKit
import Vapor

nonisolated(unsafe) var statusBarController: StatusBarController?

let preflightIssues = await MainActor.run {
    AppLaunchPreflight.run()
}

let shouldContinueLaunch = await MainActor.run {
    AppLaunchPreflight.presentIfNeeded(preflightIssues)
}

guard shouldContinueLaunch else {
    exit(1)
}

var env = try Environment.detect()
let app = try await Application.make(env)

do {
    try await configure(app)
} catch {
    await MainActor.run {
        AppLaunchPreflight.presentLaunchFailure(error)
    }
    exit(1)
}

// Set activation policy before creating UI elements
NSApplication.shared.setActivationPolicy(.accessory)

let launchAtLoginManager = LaunchAtLoginManager()
try? launchAtLoginManager.configureForCurrentLaunch()
let updater = GitHubUpdater()

// Create menu bar controller (must happen on main thread before NSApp.run())
statusBarController = StatusBarController(
    appState: app.appState,
    launchAtLoginManager: launchAtLoginManager,
    updater: updater
)

// Handle SIGTERM gracefully — remove the menu bar icon and exit.
// NSApp.run() swallows SIGTERM by default, so we need our own handler.
// Use a global queue since the main queue may not process GCD events
// under NSApp.run(), then hop to the main run loop for UI cleanup.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termSource.setEventHandler {
    RunLoop.main.perform {
        statusBarController?.removeStatusItem()
        statusBarController = nil
        exit(0)
    }
}
termSource.resume()

// Start Vapor in a detached task so it runs on the general executor,
// not the main actor (which NSApp.run() will block)
Task.detached {
    do {
        try await app.execute()
    } catch {
        app.logger.error("Vapor server error: \(error)")
    }
    await MainActor.run {
        NSApp.terminate(nil)
    }
}

Task { @MainActor in
    await updater.performBackgroundCheckIfNeeded()
}

NSApp.run()

try? await app.asyncShutdown()
