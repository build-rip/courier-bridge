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
        if let mainResourceURL = Bundle.main.resourceURL,
           let iconURL = bundledIconURL(in: mainResourceURL) {
            return iconURL
        }

        if let resourceBundleURL = BridgeAppConfiguration.resourceBundleURL,
           let iconURL = bundledIconURL(in: resourceBundleURL) {
            return iconURL
        }

        guard !BridgeAppConfiguration.isBundledApp else {
            return nil
        }

        if let iconURL = repositoryIconURL(startingFrom: Bundle.main.executableURL?.deletingLastPathComponent()) {
            return iconURL
        }

        return repositoryIconURL(startingFrom: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }

    private static func bundledIconURL(in directory: URL) -> URL? {
        for fileName in ["AppIcon.icns", "icon.svg"] {
            let iconURL = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: iconURL.path) {
                return iconURL
            }
        }

        return nil
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
