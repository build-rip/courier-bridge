import Foundation

@MainActor
final class LaunchAtLoginManager {
    private let defaults = UserDefaults.standard
    private let defaultsKey = "launchAtLoginEnabled"

    var isAvailable: Bool {
        BridgeAppConfiguration.isBundledApp
    }

    var isEnabled: Bool {
        guard isAvailable else { return false }
        if defaults.object(forKey: defaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: defaultsKey)
    }

    func configureForCurrentLaunch() throws {
        guard isAvailable else { return }
        if defaults.object(forKey: defaultsKey) == nil {
            defaults.set(true, forKey: defaultsKey)
        }
        try syncRegistration()
    }

    func setEnabled(_ enabled: Bool) throws {
        defaults.set(enabled, forKey: defaultsKey)
        try syncRegistration()
    }

    private func syncRegistration() throws {
        if isEnabled {
            try installLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
    }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(BridgeAppConfiguration.bundleIdentifier).plist")
    }

    private func installLaunchAgent() throws {
        guard let executablePath = BridgeAppConfiguration.executableURL?.path else {
            throw LaunchAtLoginError.missingExecutable
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(BridgeAppConfiguration.bundleIdentifier.xmlEscaped)</string>
            <key>LimitLoadToSessionType</key>
            <array>
                <string>Aqua</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>COURIER_LAUNCHED_AT_LOGIN</key>
                <string>1</string>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath.xmlEscaped)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """

        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private func removeLaunchAgent() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "The bridge app executable could not be located."
        }
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
