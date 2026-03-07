import AppKit
import Foundation

@MainActor
final class GitHubUpdater {
    enum State {
        case idle
        case checking
        case updateAvailable(Release)
        case downloading(Release)
    }

    struct Release {
        let name: String
        let tagName: String
        let htmlURL: URL
        let asset: Asset
        let body: String?
        let buildNumber: Int
    }

    struct Asset {
        let name: String
        let downloadURL: URL
    }

    private struct GitHubRelease: Decodable {
        struct GitHubAsset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let htmlURL: URL
        let body: String?
        let draft: Bool
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case draft
            case assets
        }

        var availableRelease: Release? {
            guard !draft else { return nil }
            guard let buildNumber = parseBuildNumber(from: tagName) else { return nil }
            guard let asset = assets.first(where: { asset in
                asset.name.hasPrefix(BridgeAppConfiguration.releaseAssetPrefix) &&
                    asset.name.hasSuffix(BridgeAppConfiguration.releaseAssetSuffix)
            }) else {
                return nil
            }

            return Release(
                name: name ?? tagName,
                tagName: tagName,
                htmlURL: htmlURL,
                asset: Asset(name: asset.name, downloadURL: asset.browserDownloadURL),
                body: body,
                buildNumber: buildNumber
            )
        }

        private func parseBuildNumber(from tagName: String) -> Int? {
            tagName.split(separator: "-").reversed().compactMap { Int($0) }.first
        }
    }

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "githubUpdaterLastCheckDate"
    private let autoCheckInterval: TimeInterval = 12 * 60 * 60

    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    func performBackgroundCheckIfNeeded() async {
        guard BridgeAppConfiguration.isBundledApp else { return }
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        guard lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= autoCheckInterval else {
            return
        }

        await checkForUpdates(userInitiated: false)
    }

    func performPrimaryAction() {
        switch state {
        case .updateAvailable(let release):
            Task { await promptForInstall(release: release) }
        case .idle, .checking, .downloading:
            Task { await checkForUpdates(userInitiated: true) }
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard BridgeAppConfiguration.isBundledApp else {
            if userInitiated {
                NSWorkspace.shared.open(BridgeAppConfiguration.releasesURL)
            }
            return
        }

        switch state {
        case .checking, .downloading:
            return
        case .idle, .updateAvailable:
            break
        }

        state = .checking

        do {
            let release = try await fetchLatestRelease()
            defaults.set(Date(), forKey: lastCheckKey)

            guard let release else {
                state = .idle
                if userInitiated {
                    showAlert(title: "You’re Up to Date", message: "\(BridgeAppConfiguration.appName) is already on the latest available build.")
                }
                return
            }

            state = .updateAvailable(release)
            if userInitiated {
                await promptForInstall(release: release)
            } else {
                NSApp.requestUserAttention(.informationalRequest)
            }
        } catch {
            state = .idle
            if userInitiated {
                showAlert(title: "Update Check Failed", message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(BridgeAppConfiguration.githubRepository)/releases?per_page=10")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(BridgeAppConfiguration.appName)/\(BridgeAppConfiguration.marketingVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UpdaterError.invalidResponse
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases
            .compactMap(\.availableRelease)
            .first { $0.buildNumber > BridgeAppConfiguration.buildNumber }
    }

    private func promptForInstall(release: Release) async {
        let alert = NSAlert()
        alert.messageText = release.name
        alert.informativeText = "A newer build of \(BridgeAppConfiguration.appName) is available. Download and install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Open Release Page")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try await downloadAndInstall(release: release)
            } catch {
                state = .updateAvailable(release)
                showAlert(title: "Update Install Failed", message: error.localizedDescription, style: .warning)
            }
        } else if response == .alertThirdButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func downloadAndInstall(release: Release) async throws {
        guard let currentAppURL = BridgeAppConfiguration.appBundleURL else {
            throw UpdaterError.notInstalledFromAppBundle
        }

        let parentDirectory = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            NSWorkspace.shared.open(release.htmlURL)
            throw UpdaterError.unwritableInstallLocation
        }

        state = .downloading(release)

        var request = URLRequest(url: release.asset.downloadURL)
        request.setValue("\(BridgeAppConfiguration.appName)/\(BridgeAppConfiguration.marketingVersion)", forHTTPHeaderField: "User-Agent")
        let (downloadedArchiveURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UpdaterError.invalidResponse
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-update-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = tempRoot.appendingPathComponent(release.asset.name)
        let extractedDirectory = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloadedArchiveURL, to: archiveURL)
        try runProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path])

        let replacementAppURL = try findAppBundle(in: extractedDirectory)
        try stageInstallScript(sourceAppURL: replacementAppURL, destinationAppURL: currentAppURL, tempRoot: tempRoot)
        NSApp.terminate(nil)
    }

    private func findAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        for child in contents {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                if let app = try? findAppBundle(in: child) {
                    return app
                }
            }
        }
        throw UpdaterError.missingAppBundle
    }

    private func stageInstallScript(sourceAppURL: URL, destinationAppURL: URL, tempRoot: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-install-update-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/zsh
        set -euo pipefail
        while kill -0 \(pid) 2>/dev/null; do
            sleep 1
        done
        rm -rf \(shellQuoted(destinationAppURL.path))
        ditto \(shellQuoted(sourceAppURL.path)) \(shellQuoted(destinationAppURL.path))
        xattr -dr com.apple.quarantine \(shellQuoted(destinationAppURL.path)) >/dev/null 2>&1 || true
        open \(shellQuoted(destinationAppURL.path))
        rm -rf \(shellQuoted(tempRoot.path))
        rm -f \(shellQuoted(scriptURL.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.helperFailed
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum UpdaterError: LocalizedError {
    case invalidResponse
    case helperFailed
    case missingAppBundle
    case notInstalledFromAppBundle
    case unwritableInstallLocation

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unexpected response while checking for or downloading an update."
        case .helperFailed:
            return "A helper process failed while preparing the update."
        case .missingAppBundle:
            return "The downloaded archive did not contain a bridge app bundle."
        case .notInstalledFromAppBundle:
            return "Automatic installation only works from the packaged bridge app."
        case .unwritableInstallLocation:
            return "The bridge app is installed in a location that cannot be updated automatically."
        }
    }
}
