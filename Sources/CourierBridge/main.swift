import AppKit
import Carbon.HIToolbox.Events
import Foundation
import Vapor

nonisolated(unsafe) var statusBarController: StatusBarController?
nonisolated(unsafe) var appleEventHandler: AppleEventHandler?

func terminateBridgeProcess() {
    DispatchQueue.main.async {
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        statusBarController?.removeStatusItem()
        statusBarController = nil
        exit(0)
    }
}

final class AppleEventHandler: NSObject {
    @objc func handleQuitAppleEvent(_: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        terminateBridgeProcess()
    }
}

let application = await MainActor.run { () -> NSApplication in
    let application = NSApplication.shared
    application.applicationIconImage = AppIcon.applicationImage()
    application.finishLaunching()
    return application
}

appleEventHandler = AppleEventHandler()
NSAppleEventManager.shared().setEventHandler(
    appleEventHandler!,
    andSelector: #selector(AppleEventHandler.handleQuitAppleEvent(_:withReplyEvent:)),
    forEventClass: AEEventClass(kCoreEventClass),
    andEventID: AEEventID(kAEQuitApplication)
)

let preflightIssues = await MainActor.run {
    AppLaunchPreflight.run()
}

let preflightResult = await MainActor.run {
    AppLaunchPreflight.presentIfNeeded(preflightIssues)
}

switch preflightResult {
case .continueLaunch:
    break
case .quit:
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
application.setActivationPolicy(.accessory)

let launchAtLoginManager = LaunchAtLoginManager()
try? launchAtLoginManager.configureForCurrentLaunch()
let updater = GitHubUpdater()

// Create menu bar controller (must happen on main thread before NSApp.run())
statusBarController = StatusBarController(
    appState: app.appState,
    launchAtLoginManager: launchAtLoginManager,
    updater: updater
)

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
