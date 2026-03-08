import AppKit
import Foundation

enum AppIcon {
    static func applicationImage() -> NSImage? {
        guard let url = applicationIconURL() else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    static func statusBarImage() -> NSImage? {
        guard let url = statusBarIconURL(),
              let image = NSImage(contentsOf: url)?.copy() as? NSImage else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func applicationIconURL() -> URL? {
        iconURL(named: "icon.svg", fallbacks: ["AppIcon.icns"])
    }

    private static func statusBarIconURL() -> URL? {
        iconURL(named: "menu-bar-icon.svg", fallbacks: ["icon.svg", "AppIcon.icns"])
    }

    private static func iconURL(named preferredFileName: String, fallbacks: [String]) -> URL? {
        let fileNames = [preferredFileName] + fallbacks

        if let mainResourceURL = Bundle.main.resourceURL,
           let iconURL = bundledIconURL(in: mainResourceURL, fileNames: fileNames) {
            return iconURL
        }

        if let resourceBundleURL = BridgeAppConfiguration.resourceBundleURL,
           let iconURL = bundledIconURL(in: resourceBundleURL, fileNames: fileNames) {
            return iconURL
        }

        guard !BridgeAppConfiguration.isBundledApp else {
            return nil
        }

        let searchRoots = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ]

        for root in searchRoots {
            for fileName in fileNames {
                if let iconURL = repositoryIconURL(startingFrom: root, fileName: fileName) {
                    return iconURL
                }
            }
        }

        return nil
    }

    private static func bundledIconURL(in directory: URL, fileNames: [String]) -> URL? {
        for fileName in fileNames {
            let iconURL = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: iconURL.path) {
                return iconURL
            }
        }

        return nil
    }

    private static func repositoryIconURL(startingFrom directory: URL?, fileName: String) -> URL? {
        guard let directory else {
            return nil
        }

        var currentDirectory = directory.standardizedFileURL
        while true {
            let packageURL = currentDirectory.appendingPathComponent("Package.swift")
            let iconURLs = [
                currentDirectory.appendingPathComponent(fileName),
                currentDirectory.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(fileName)
            ]
            if FileManager.default.fileExists(atPath: packageURL.path) {
                for iconURL in iconURLs where FileManager.default.fileExists(atPath: iconURL.path) {
                    return iconURL
                }
            }

            let parentDirectory = currentDirectory.deletingLastPathComponent()
            if parentDirectory.path == currentDirectory.path {
                return nil
            }

            currentDirectory = parentDirectory
        }
    }
}
