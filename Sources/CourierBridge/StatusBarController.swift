import AppKit
import SwiftUI
import CoreImage

// MARK: - SwiftUI Views

private let bridgeURLDefaultsKey = "bridgePublicURL"
private let cloudflareTunnelDocsURL = URL(string: "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/")!

private struct BridgeStatusCheckResponse: Decodable {
    let online: Bool
}

private enum BridgeURLValidationState {
    case idle
    case testing
    case success(String)
    case failure(String)
}

private enum BridgeURLValidationError: LocalizedError {
    case empty
    case invalid
    case unsupportedScheme
    case unexpectedStatus(Int)
    case invalidResponse
    case offlineBridge

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter the public URL for this bridge first."
        case .invalid:
            return "Enter a valid bridge URL, including http:// or https://."
        case .unsupportedScheme:
            return "The bridge URL must use http:// or https://."
        case .unexpectedStatus(let statusCode):
            return "The bridge responded with HTTP \(statusCode) instead of a healthy status response."
        case .invalidResponse:
            return "The bridge returned an unexpected response while checking /api/status."
        case .offlineBridge:
            return "The bridge reported that it is offline."
        }
    }
}

private func normalizedBridgeURLString(_ rawValue: String) throws -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw BridgeURLValidationError.empty }
    guard var components = URLComponents(string: trimmed), components.host != nil else {
        throw BridgeURLValidationError.invalid
    }

    guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        throw BridgeURLValidationError.unsupportedScheme
    }

    components.query = nil
    components.fragment = nil

    if components.path.isEmpty {
        components.path = ""
    } else if components.path != "/" {
        components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    guard let url = components.url else {
        throw BridgeURLValidationError.invalid
    }

    let absoluteString = url.absoluteString
    if absoluteString.hasSuffix("/") && components.path.isEmpty {
        return String(absoluteString.dropLast())
    }

    return absoluteString
}

private func bridgeStatusURL(from rawValue: String) throws -> URL {
    let normalized = try normalizedBridgeURLString(rawValue)
    guard var components = URLComponents(string: normalized) else {
        throw BridgeURLValidationError.invalid
    }

    let basePath = components.path == "/" ? "" : components.path
    components.path = basePath + "/api/status"
    components.query = nil
    components.fragment = nil

    guard let url = components.url else {
        throw BridgeURLValidationError.invalid
    }

    return url
}

private func validateBridgeURL(_ rawValue: String) async throws -> String {
    let normalized = try normalizedBridgeURLString(rawValue)
    let url = try bridgeStatusURL(from: normalized)

    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10

    let session = URLSession(configuration: configuration)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw BridgeURLValidationError.invalidResponse
    }

    guard 200..<300 ~= httpResponse.statusCode else {
        throw BridgeURLValidationError.unexpectedStatus(httpResponse.statusCode)
    }

    let decoded = try? JSONDecoder().decode(BridgeStatusCheckResponse.self, from: data)
    guard let decoded else {
        throw BridgeURLValidationError.invalidResponse
    }

    guard decoded.online else {
        throw BridgeURLValidationError.offlineBridge
    }

    return normalized
}

@Observable
private class PairingState {
    var code: String = ""
    var bridgeURL: String?
    var qrPayload: String?
    var expiresAt: Date = .distantFuture
    var approvalInfo: ApprovalInfo?

    struct ApprovalInfo {
        let deviceName: String?
        let ipAddress: String?
        let country: String?
    }
}

@Observable
private class BridgeURLSettingsState {
    var bridgeURL: String
    var validationState: BridgeURLValidationState = .idle
    var lastValidatedURL: String?

    init(bridgeURL: String) {
        self.bridgeURL = bridgeURL
    }

    var trimmedBridgeURL: String {
        bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canTestConnection: Bool {
        !trimmedBridgeURL.isEmpty && !isTesting
    }

    var canSaveAndContinue: Bool {
        lastValidatedURL == trimmedBridgeURL && !isTesting
    }

    var isTesting: Bool {
        if case .testing = validationState {
            return true
        }
        return false
    }

    func updateBridgeURL(_ newValue: String) {
        bridgeURL = newValue

        if lastValidatedURL != newValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            lastValidatedURL = nil
            validationState = .idle
        }
    }
}

private struct BridgeURLSettingsView: View {
    let state: BridgeURLSettingsState
    let onTestConnection: () -> Void
    let onSaveAndContinue: () -> Void
    let onCancel: () -> Void

    private var validationMessage: String? {
        switch state.validationState {
        case .idle:
            return nil
        case .testing:
            return "Checking that the bridge can reach itself at that public URL..."
        case .success(let message), .failure(let message):
            return message
        }
    }

    private var validationColor: Color {
        switch state.validationState {
        case .idle:
            return .secondary
        case .testing:
            return .secondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bridge Address")
                .font(.title2.weight(.semibold))

            Text("Before pairing a device, this bridge needs a reliable public address that your phone can reach.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("1. The bridge needs a reliable address.")
                Text("2. Pairing is protected with approval and short-lived codes, so publishing the bridge is safe when you control the URL.")
                Text("3. Tailscale is a good option if you already use it, but you do not need to learn Tailscale just to get started.")
                Text("4. Cloudflare Tunnel is another option for exposing a local bridge securely.")
            }
            .font(.body)

            HStack(spacing: 8) {
                Text("If you want to use Cloudflare Tunnel, follow Cloudflare's guide for serving a local app through a tunnel.")
                    .foregroundStyle(.secondary)
                Link("More Info", destination: cloudflareTunnelDocsURL)
            }
            .font(.subheadline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Public bridge URL")
                    .font(.headline)

                TextField(
                    "https://bridge.example.com",
                    text: Binding(
                        get: { state.bridgeURL },
                        set: { state.updateBridgeURL($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Text("We will request /api/status at the public URL and make sure the bridge reports a healthy status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.subheadline)
                        .foregroundStyle(validationColor)
                }
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(state.isTesting ? "Testing..." : "Test Connection", action: onTestConnection)
                    .disabled(!state.canTestConnection)

                Button("Save and Continue", action: onSaveAndContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canSaveAndContinue)
            }
        }
        .padding(24)
        .frame(width: 540, height: 420)
    }
}

private struct PairingWindowView: View {
    let state: PairingState
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let approval = state.approvalInfo {
                approvalView(approval)
            } else {
                pairingCodeView
            }

            CountdownView(expiresAt: state.expiresAt)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 400)
    }

    private var pairingCodeView: some View {
        VStack(spacing: 20) {
            if let qrPayload = state.qrPayload {
                Text("Scan this QR code with your phone")
                    .font(.headline)

                QRCodeView(string: qrPayload)
                    .frame(width: 200, height: 200)

                dividerWithText("or")

                manualPairingSection
            } else {
                Text("Pair your device")
                    .font(.headline)

                Text("Install the app and choose \"Pair manually\", then enter:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                manualPairingTable
            }
        }
    }

    private var manualPairingSection: some View {
        VStack(spacing: 8) {
            Text("Install the app and choose \"Pair manually\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            manualPairingTable
        }
    }

    private var manualPairingTable: some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            if let url = state.bridgeURL {
                GridRow {
                    Text("Server")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(url)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            GridRow {
                Text("Code")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(state.code)
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
    }

    private func dividerWithText(_ text: String) -> some View {
        HStack {
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
        }
    }

    private func approvalView(_ approval: PairingState.ApprovalInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A device wants to pair with this bridge.")
                .font(.headline)
                .padding(.bottom, 4)

            if let name = approval.deviceName {
                Text("Device: \(name)")
            }
            if let ip = approval.ipAddress {
                Text("IP Address: \(ip)")
            }
            if let country = approval.country {
                Text("Country: \(country)")
            }

            Spacer().frame(height: 8)

            HStack {
                Spacer()
                Button("Deny") { onDeny() }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { onAllow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CountdownView: View {
    let expiresAt: Date

    @State private var remaining: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
            .font(.subheadline)
            .onAppear { updateRemaining() }
            .onReceive(timer) { _ in updateRemaining() }
    }

    private func updateRemaining() {
        remaining = max(0, Int(expiresAt.timeIntervalSinceNow))
    }
}

private struct QRCodeView: NSViewRepresentable {
    let string: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = generateQRCode()
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}

    private func generateQRCode() -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        let scale = 200.0 / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - StatusBarController

@MainActor
final class StatusBarController: NSObject {
    private let appState: AppState
    private let launchAtLoginManager: LaunchAtLoginManager
    private let updater: GitHubUpdater
    private let startTime = Date()

    private let statusItem: NSStatusItem
    private let uptimeItem = NSMenuItem(title: "Uptime: --", action: nil, keyEquivalent: "")
    private let messagesItem = NSMenuItem(title: "Messages: --", action: nil, keyEquivalent: "")
    private let clientsItem = NSMenuItem(title: "Connected Clients: --", action: nil, keyEquivalent: "")
    private let versionItem = NSMenuItem(title: "Version: --", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

    private var statusTimer: Timer?
    private var pairingWindow: NSWindow?
    private var pairingState: PairingState?
    private var bridgeURLSettingsState: BridgeURLSettingsState?
    private var expiryTimer: Timer?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private let defaults = UserDefaults.standard

    init(appState: AppState, launchAtLoginManager: LaunchAtLoginManager, updater: GitHubUpdater) {
        self.appState = appState
        self.launchAtLoginManager = launchAtLoginManager
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        setupMenuBarIcon()
        setupMenu()
        setupMainMenu()
        configureUpdater()
        startStatusUpdates()
    }

    // MARK: - Menu Setup

    private func setupMenuBarIcon() {
        if let button = statusItem.button {
            button.image = AppIcon.statusBarImage() ?? NSImage(systemSymbolName: "message.fill", accessibilityDescription: "Courier Bridge")
            button.image?.isTemplate = false
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        uptimeItem.isEnabled = false
        messagesItem.isEnabled = false
        clientsItem.isEnabled = false
        versionItem.isEnabled = false

        menu.addItem(uptimeItem)
        menu.addItem(messagesItem)
        menu.addItem(clientsItem)
        versionItem.title = "Version: \(BridgeAppConfiguration.marketingVersion) (\(BridgeAppConfiguration.buildNumber))"
        menu.addItem(versionItem)
        menu.addItem(.separator())

        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLoginManager.isEnabled ? .on : .off
        launchAtLoginItem.isHidden = !launchAtLoginManager.isAvailable
        menu.addItem(launchAtLoginItem)

        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let pairItem = NSMenuItem(title: "Pair a New Device", action: #selector(beginPairingFlow), keyEquivalent: "")
        pairItem.target = self
        menu.addItem(pairItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Until Restart", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (Cmd+Q override)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Until Restart", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (Cmd+C, Cmd+A, etc.)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu (Cmd+W)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeWindowAction), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func closeWindowAction() {
        pairingWindow?.close()
    }

    /// Whether any window managed by this controller is currently visible.
    var hasVisibleWindow: Bool {
        pairingWindow?.isVisible == true
    }

    private func configureUpdater() {
        updater.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.updateItem.title = "Check for Updates…"
                self.updateItem.isEnabled = true
            case .checking:
                self.updateItem.title = "Checking for Updates…"
                self.updateItem.isEnabled = false
            case .updateAvailable(let release):
                self.updateItem.title = "Install Update: \(release.name)"
                self.updateItem.isEnabled = true
            case .downloading:
                self.updateItem.title = "Downloading Update…"
                self.updateItem.isEnabled = false
            }
        }
    }

    // MARK: - Status Updates

    private func startStatusUpdates() {
        updateStatus()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func updateStatus() {
        let uptime = Date().timeIntervalSince(startTime)
        uptimeItem.title = "Uptime: \(formatUptime(uptime))"

        if let count = try? appState.queries.messageCount() {
            messagesItem.title = "Messages: \(count.formatted())"
        }

        Task {
            let clients = await appState.wsController.clientCount
            clientsItem.title = "Connected Clients: \(clients)"
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - Pairing

    @objc private func beginPairingFlow() {
        showBridgeURLSettings()
    }

    private func showBridgeURLSettings() {
        closePairingWindow()

        let state = BridgeURLSettingsState(bridgeURL: currentBridgeURL() ?? "")
        bridgeURLSettingsState = state

        let hostingView = NSHostingView(rootView: BridgeURLSettingsView(
            state: state,
            onTestConnection: { [weak self] in self?.testBridgeURL() },
            onSaveAndContinue: { [weak self] in self?.saveBridgeURLAndContinue() },
            onCancel: { [weak self] in self?.closePairingWindow() }
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bridge Address"
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pairingWindow = window
        AppDelegate.shared.activateForUserInteraction()
    }

    private func testBridgeURL() {
        guard let state = bridgeURLSettingsState else { return }
        let candidate = state.trimmedBridgeURL
        state.validationState = .testing

        Task { [weak self] in
            do {
                let normalizedURL = try await validateBridgeURL(candidate)
                await MainActor.run {
                    guard let self, self.bridgeURLSettingsState === state else { return }
                    state.updateBridgeURL(normalizedURL)
                    state.lastValidatedURL = normalizedURL
                    state.validationState = .success("Connection succeeded. The bridge can reach itself at \(normalizedURL).")
                }
            } catch {
                await MainActor.run {
                    guard let self, self.bridgeURLSettingsState === state else { return }
                    state.lastValidatedURL = nil
                    state.validationState = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func saveBridgeURLAndContinue() {
        guard let state = bridgeURLSettingsState, state.canSaveAndContinue else { return }

        defaults.set(state.trimmedBridgeURL, forKey: bridgeURLDefaultsKey)

        guard let code = try? appState.bridgeDB.createPairingCode() else { return }
        showPairingWindow(code: code)
    }

    private func showPairingWindow(code: String) {
        closePairingWindow()

        let state = PairingState()
        state.code = code
        state.expiresAt = Date().addingTimeInterval(300)

        if let bridgeURL = currentBridgeURL() {
            state.bridgeURL = bridgeURL
            state.qrPayload = "{\"host\":\"\(bridgeURL)\",\"code\":\"\(code)\"}"
        }

        self.pairingState = state
        bridgeURLSettingsState = nil

        let hostingView = NSHostingView(rootView: PairingWindowView(
            state: state,
            onAllow: { [weak self] in self?.allowPairing() },
            onDeny: { [weak self] in self?.denyPairing() }
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair a New Device"
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pairingWindow = window
        AppDelegate.shared.activateForUserInteraction()

        startExpiryTimer()
    }

    // MARK: - Approval

    /// Called from DispatchQueue.main (not via @MainActor hop)
    func handleApprovalRequest(
        deviceName: String?,
        ipAddress: String?,
        country: String?,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        // If there's already a pending approval, deny it
        if let existing = approvalContinuation {
            existing.resume(returning: false)
        }
        approvalContinuation = continuation
        transitionToApproval(deviceName: deviceName, ipAddress: ipAddress, country: country)
    }

    private func transitionToApproval(deviceName: String?, ipAddress: String?, country: String?) {
        let state: PairingState
        if let existing = pairingState {
            state = existing
        } else {
            state = PairingState()
            state.expiresAt = Date().addingTimeInterval(300)
            self.pairingState = state
        }

        state.approvalInfo = PairingState.ApprovalInfo(
            deviceName: deviceName,
            ipAddress: ipAddress,
            country: country
        )

        // Replace content view entirely to guarantee the UI updates
        let hostingView = NSHostingView(rootView: PairingWindowView(
            state: state,
            onAllow: { [weak self] in self?.allowPairing() },
            onDeny: { [weak self] in self?.denyPairing() }
        ))

        if let window = pairingWindow {
            window.title = "Pairing Request"
            window.contentView = hostingView
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Pairing Request"
            window.level = .floating
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            pairingWindow = window
            startExpiryTimer()
        }

        AppDelegate.shared.activateForUserInteraction()
    }

    private func allowPairing() {
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
        closePairingWindow()
        AppDelegate.shared.returnToAccessoryModeIfAppropriate()
    }

    private func denyPairing() {
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        closePairingWindow()
        AppDelegate.shared.returnToAccessoryModeIfAppropriate()
    }

    // MARK: - Expiry

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkExpiry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func checkExpiry() {
        guard let state = pairingState else { return }
        if state.expiresAt.timeIntervalSinceNow <= 0 {
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            closePairingWindow()
            AppDelegate.shared.returnToAccessoryModeIfAppropriate()
        }
    }

    private func closePairingWindow() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        bridgeURLSettingsState = nil
        pairingState = nil
        pairingWindow?.close()
        pairingWindow = nil
    }

    private func currentBridgeURL() -> String? {
        if let bridgeURL = ProcessInfo.processInfo.environment["BRIDGE_URL"], !bridgeURL.isEmpty {
            return bridgeURL
        }

        guard let savedBridgeURL = defaults.string(forKey: bridgeURLDefaultsKey), !savedBridgeURL.isEmpty else {
            return nil
        }

        return savedBridgeURL
    }

    /// Remove the status item from the menu bar.
    func removeStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLoginItem.state != .on
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginItem.state = enabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Change Launch Setting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            AppDelegate.shared.activateForUserInteraction()
            alert.runModal()
            AppDelegate.shared.returnToAccessoryModeIfAppropriate()
        }
    }

    @objc private func checkForUpdates() {
        updater.performPrimaryAction()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension StatusBarController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            expiryTimer?.invalidate()
            expiryTimer = nil
            bridgeURLSettingsState = nil
            pairingState = nil
            pairingWindow = nil
            AppDelegate.shared.returnToAccessoryModeIfAppropriate()
        }
    }
}
