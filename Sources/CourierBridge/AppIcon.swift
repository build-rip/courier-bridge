import AppKit
import Foundation

enum AppIcon {
    static func applicationImage() -> NSImage? {
        guard let url = iconURL() else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    static func statusBarImage() -> NSImage? {
        guard let image = applicationImage()?.copy() as? NSImage else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func iconURL() -> URL? {
        let candidateURLs = [
            Bundle.main.resourceURL?.appendingPathComponent("icon.svg"),
            Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
            BridgeAppConfiguration.resourceBundleURL?.appendingPathComponent("icon.svg"),
            BridgeAppConfiguration.resourceBundleURL?.appendingPathComponent("AppIcon.icns"),
            repositoryIconURL(startingFrom: Bundle.main.executableURL?.deletingLastPathComponent()),
            repositoryIconURL(startingFrom: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)),
        ]

        return candidateURLs.compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func repositoryIconURL(startingFrom directory: URL?) -> URL? {
        guard let directory else {
            return nil
        }

        var currentDirectory = directory.standardizedFileURL
        while true {
            let packageURL = currentDirectory.appendingPathComponent("Package.swift")
            let iconURL = currentDirectory.appendingPathComponent("icon.svg")
            if FileManager.default.fileExists(atPath: packageURL.path),
               FileManager.default.fileExists(atPath: iconURL.path) {
                return iconURL
            }

            let parentDirectory = currentDirectory.deletingLastPathComponent()
            if parentDirectory.path == currentDirectory.path {
                return nil
            }

            currentDirectory = parentDirectory
        }
    }
}
