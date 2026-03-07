import Foundation

enum BridgeAppConfiguration {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "rip.build.courier.bridge"
    static let appName = stringValue(for: "CFBundleName", default: "Courier Bridge")
    static let marketingVersion = stringValue(for: "CFBundleShortVersionString", default: "dev")
    static let buildNumber = Int(stringValue(for: "CFBundleVersion", default: "0")) ?? 0
    static let githubRepository = stringValue(for: "CourierGitHubRepository", default: "build-rip/courier-bridge")
    static let releaseAssetPrefix = stringValue(for: "CourierReleaseAssetPrefix", default: "Courier-Bridge-")
    static let releaseAssetSuffix = stringValue(for: "CourierReleaseAssetSuffix", default: ".zip")

    static var releasesURL: URL {
        URL(string: "https://github.com/\(githubRepository)/releases")!
    }

    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var appBundleURL: URL? {
        isBundledApp ? Bundle.main.bundleURL : nil
    }

    static var executableURL: URL? {
        Bundle.main.executableURL
    }

    static var resourceBundleURL: URL? {
        let bundleName = "courier-bridge_CourierBridge.bundle"
        if let resourceURL = Bundle.main.resourceURL {
            let bundledURL = resourceURL.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: bundledURL.path) {
                return bundledURL
            }
        }

        let fallbackURL = Bundle.main.bundleURL.appendingPathComponent(bundleName)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }

        return nil
    }

    static var publicResourcesURL: URL? {
        resourceBundleURL?.appendingPathComponent("Public", isDirectory: true)
    }

    private static func stringValue(for key: String, default defaultValue: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? defaultValue
    }
}
