import AppKit
import ApplicationServices
import CourierCore
import Foundation

struct AppLaunchPreflight {
    struct Issue: Sendable {
        let title: String
        let details: String
        let isBlocking: Bool
        let kind: Kind
    }

    enum Kind: Sendable {
        case fullDiskAccess
        case accessibility
    }

    @MainActor
    static func run() -> [Issue] {
        var issues: [Issue] = []

        do {
            let chatDB = try ChatDatabase()
            _ = try ChatQueries(db: chatDB).messageCount()
        } catch {
            issues.append(Issue(
                title: "Full Disk Access is required",
                details: "Courier Bridge could not read your Messages database. Add Courier Bridge to System Settings > Privacy & Security > Full Disk Access, then reopen it.",
                isBlocking: true,
                kind: .fullDiskAccess
            ))
        }

        let accessibilityTrusted = AccessibilityHelper().isAccessibilityTrusted()
        if !accessibilityTrusted {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            issues.append(Issue(
                title: "Accessibility access is recommended",
                details: "Courier Bridge can launch without Accessibility, but sending, tapbacks, and some automation features will not work until you enable System Settings > Privacy & Security > Accessibility for Courier Bridge.",
                isBlocking: false,
                kind: .accessibility
            ))
        }

        return issues
    }

    @MainActor
    static func presentIfNeeded(_ issues: [Issue]) -> Bool {
        guard !issues.isEmpty else { return true }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let blockingIssues = issues.filter(\.isBlocking)
        let alert = NSAlert()
        alert.alertStyle = blockingIssues.isEmpty ? .warning : .critical
        alert.messageText = blockingIssues.isEmpty
            ? "Courier Bridge needs additional setup"
            : "Courier Bridge cannot start yet"
        alert.informativeText = issues
            .map { "- \($0.title)\n\($0.details)" }
            .joined(separator: "\n\n")

        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: blockingIssues.isEmpty ? "Continue Anyway" : "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }

        return blockingIssues.isEmpty && response != .alertFirstButtonReturn
            ? true
            : blockingIssues.isEmpty && response == .alertFirstButtonReturn
    }

    @MainActor
    static func presentLaunchFailure(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Courier Bridge failed to start"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }
}
