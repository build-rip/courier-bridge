import AppKit
import Foundation
import Vapor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    private(set) var statusBarController: StatusBarController?
    private var vaporApp: Application?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.applicationImage()

        // Check permissions before proceeding (presents modal UI if needed,
        // temporarily switching to .regular activation policy so it's visible)
        let checks = AppLaunchPreflight.run()
        let result = AppLaunchPreflight.presentIfNeeded(checks)

        switch result {
        case .quit:
            NSApp.terminate(nil)
            return
        case .continueLaunch:
            break
        }

        // Enter menu-bar-only mode
        NSApp.setActivationPolicy(.accessory)

        // Perform async setup (Vapor, menu bar, etc.) now that the run loop
        // is active and MainActor tasks drain properly.
        Task {
            await self.startServices()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        statusBarController?.removeStatusItem()
        return .terminateNow
    }

    // MARK: - Activation Policy Management

    /// Switch to `.regular` activation policy and bring the app to the
    /// foreground. Call this before presenting any window or alert so that
    /// the UI is visible even though the app normally runs as a menu-bar
    /// accessory (no Dock icon).
    func activateForUserInteraction() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Return to `.accessory` (menu-bar-only) activation policy if there
    /// are no windows that still require the app to be in the foreground.
    func returnToAccessoryModeIfAppropriate() {
        if let controller = statusBarController, controller.hasVisibleWindow {
            return
        }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Service Startup

    private func startServices() async {
        do {
            let env = try Environment.detect()
            let app = try await Application.make(env)
            try await configure(app)
            self.vaporApp = app

            let launchAtLoginManager = LaunchAtLoginManager()
            try? launchAtLoginManager.configureForCurrentLaunch()
            let updater = GitHubUpdater()

            statusBarController = StatusBarController(
                appState: app.appState,
                launchAtLoginManager: launchAtLoginManager,
                updater: updater
            )

            // Start Vapor server on a non-MainActor executor so it doesn't
            // block the run loop.
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

            await updater.performBackgroundCheckIfNeeded()
        } catch {
            AppLaunchPreflight.presentLaunchFailure(error)
            NSApp.terminate(nil)
        }
    }
}
