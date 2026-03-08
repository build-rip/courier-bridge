import AppKit
import CourierCore
import Foundation
import SwiftUI

struct AppLaunchPreflight {
    enum PromptResult: Sendable {
        case continueLaunch
        case quit
    }

    struct Check: Sendable {
        let kind: Kind
        let isGranted: Bool

        var isBlocking: Bool {
            true
        }

        var title: String {
            switch kind {
            case .fullDiskAccess:
                return "Full Disk Access"
            case .accessibility:
                return "Accessibility"
            }
        }

        var statusText: String {
            if isGranted {
                return "Enabled"
            }

            switch kind {
            case .fullDiskAccess:
                return "Required"
            case .accessibility:
                return "Required"
            }
        }

        var details: String {
            switch kind {
            case .fullDiskAccess:
                return isGranted
                    ? "Courier Bridge can read the Messages database."
                    : "Courier Bridge cannot read the Messages database until you allow it in Privacy & Security > Full Disk Access."
            case .accessibility:
                return isGranted
                    ? "Sending and automation features can control Messages."
                    : "Courier Bridge cannot automate Messages until you allow it in Privacy & Security > Accessibility."
            }
        }

        var buttonTitle: String {
            switch kind {
            case .fullDiskAccess:
                return "Open Setting"
            case .accessibility:
                return "Open Setting"
            }
        }

        fileprivate var settingsURLs: [URL] {
            switch kind {
            case .fullDiskAccess:
                return [
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!,
                    URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!,
                ]
            case .accessibility:
                return [
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
                    URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!,
                ]
            }
        }
    }

    enum Kind: Sendable, CaseIterable {
        case fullDiskAccess
        case accessibility
    }

    @MainActor
    final class PermissionPromptModel: ObservableObject {
        @Published private(set) var checks: [Check]

        private var refreshTimer: Timer?
        private var activationObserver: NSObjectProtocol?
        private let requestContinue: @MainActor () -> Void

        init(checks: [Check], requestContinue: @escaping @MainActor () -> Void) {
            self.checks = checks
            self.requestContinue = requestContinue
        }

        func startMonitoring() {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }

            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }

        func stopMonitoring() {
            refreshTimer?.invalidate()
            refreshTimer = nil

            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }

        func check(for kind: Kind) -> Check {
            checks.first(where: { $0.kind == kind }) ?? Check(kind: kind, isGranted: false)
        }

        func openSettings(for kind: Kind) {
            AppLaunchPreflight.openSettings(for: kind)
        }

        private func refresh() {
            let refreshedChecks = AppLaunchPreflight.run()
            checks = refreshedChecks

            if refreshedChecks.allSatisfy(\.isGranted) {
                requestContinue()
            }
        }
    }

    @MainActor
    final class PermissionPromptWindowDelegate: NSObject, NSWindowDelegate {
        private let requestQuit: () -> Void

        init(requestQuit: @escaping () -> Void) {
            self.requestQuit = requestQuit
        }

        func windowWillClose(_ notification: Notification) {
            requestQuit()
        }
    }

    struct PermissionPromptView: View {
        @ObservedObject var model: PermissionPromptModel
        let hasBlockingChecks: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Open each missing permission from the matching section below. When both sections show Ready, Courier Bridge continues automatically.")
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Kind.allCases, id: \.self) { kind in
                    section(for: model.check(for: kind))
                }

                Text("System Settings may ask to quit or relaunch Courier Bridge while applying privacy changes. If it does, let macOS handle that flow and the app will recheck permissions on the next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 430, alignment: .leading)
            .padding(.top, 6)
        }

        private func section(for check: Check) -> some View {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(check.title)
                            .font(.headline)
                        Text(check.statusText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor(for: check))
                    }

                    Text(check.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Group {
                    if check.isGranted {
                        Button("👍 Ready") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    } else {
                        Button(check.buttonTitle) {
                            model.openSettings(for: check.kind)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private func statusColor(for check: Check) -> Color {
            if check.isGranted {
                return .green
            }

            return check.isBlocking ? .red : .orange
        }
    }

    @MainActor
    static func run() -> [Check] {
        return [
            Check(kind: .fullDiskAccess, isGranted: hasFullDiskAccess()),
            Check(kind: .accessibility, isGranted: AccessibilityHelper().isAccessibilityTrusted()),
        ]
    }

    @MainActor
    static func presentIfNeeded(_ checks: [Check]) -> PromptResult {
        let incompleteChecks = checks.filter { !$0.isGranted }
        guard !incompleteChecks.isEmpty else { return .continueLaunch }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Courier Bridge cannot start yet"
        alert.informativeText = ""

        var didRequestQuit = false
        let windowDelegate = PermissionPromptWindowDelegate {
            didRequestQuit = true
            alert.window.orderOut(nil)
            NSApp.stopModal(withCode: .abort)
        }

        let alertWindow = alert.window
        alertWindow.level = .floating
        alertWindow.isReleasedWhenClosed = false
        alertWindow.delegate = windowDelegate
        alertWindow.styleMask.insert(.closable)

        var didResolvePermissions = false
        let promptModel = PermissionPromptModel(checks: checks) {
            didResolvePermissions = true
            alert.window.orderOut(nil)
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        promptModel.startMonitoring()

        let accessoryView = NSHostingView(rootView: PermissionPromptView(
            model: promptModel,
            hasBlockingChecks: true
        ))
        accessoryView.frame = NSRect(origin: .zero, size: accessoryView.fittingSize)
        alert.accessoryView = accessoryView

        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        promptModel.stopMonitoring()
        alertWindow.delegate = nil

        if didResolvePermissions {
            return .continueLaunch
        }

        if didRequestQuit {
            return .quit
        }

        _ = response
        return .quit
    }

    @MainActor
    static func presentLaunchFailure(_ error: Error) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Courier Bridge failed to start"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    private static func hasFullDiskAccess() -> Bool {
        do {
            let chatDB = try ChatDatabase()
            _ = try ChatQueries(db: chatDB).messageCount()
            return true
        } catch {
            return false
        }
    }


    @MainActor
    private static func openSettings(for kind: Kind) {
        let check = Check(kind: kind, isGranted: false)
        for url in check.settingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
