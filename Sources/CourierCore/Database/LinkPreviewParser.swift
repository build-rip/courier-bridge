import Foundation

/// Metadata extracted from a URLBalloonProvider message's payload_data.
public struct LinkPreviewMetadata: Sendable {
    public let title: String?
    public let subtitle: String?
    public let url: String?
}

/// Parses NSKeyedArchiver-encoded payload_data blobs from URLBalloonProvider messages
/// to extract rich link preview metadata (title, summary, URL).
public enum LinkPreviewParser {

    public static func parse(from data: Data) -> LinkPreviewMetadata? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }

        guard let objects = plist["$objects"] as? [Any] else {
            return nil
        }

        // Object at index 1 should have a "richLinkMetadata" UID referencing the metadata dict
        guard objects.count > 1,
              let topObject = objects[1] as? [String: Any],
              let metadataUID = uidValue(topObject["richLinkMetadata"]),
              metadataUID < objects.count,
              let metadataDict = objects[metadataUID] as? [String: Any]
        else {
            return nil
        }

        let title = resolveString(key: "title", from: metadataDict, objects: objects)
        let summary = resolveString(key: "summary", from: metadataDict, objects: objects)

        // Prefer originalURL, fall back to URL
        let url = resolveString(key: "originalURL", from: metadataDict, objects: objects)
            ?? resolveString(key: "URL", from: metadataDict, objects: objects)

        guard title != nil || summary != nil || url != nil else {
            return nil
        }

        return LinkPreviewMetadata(title: title, subtitle: summary, url: url)
    }

    // MARK: - Private helpers

    /// Extract an integer index from a CFKeyedArchiverUID (plist UID) value.
    ///
    /// `PropertyListSerialization` decodes CFKeyedArchiverUID as an opaque `__NSCFType`
    /// that doesn't bridge to any Swift type. We parse the integer from its description
    /// string which has the stable format `<CFKeyedArchiverUID ...>{value = N}`.
    private static func uidValue(_ value: Any?) -> Int? {
        guard let value else { return nil }

        // Direct integer (some contexts)
        if let idx = value as? Int {
            return idx
        }

        // CF$UID dict (XML plist round-trip)
        if let dict = value as? [String: Any], let idx = dict["CF$UID"] as? Int {
            return idx
        }

        // Opaque CFKeyedArchiverUID — parse from description: "{value = N}"
        let desc = String(describing: value)
        guard let marker = desc.range(of: "{value = "),
              let closing = desc[marker.upperBound...].firstIndex(of: "}") else {
            return nil
        }
        return Int(desc[marker.upperBound..<closing])
    }

    /// Resolve a string value from a metadata dict key, following UID references.
    private static func resolveString(key: String, from dict: [String: Any], objects: [Any]) -> String? {
        guard let ref = dict[key] else { return nil }

        // Direct string value
        if let str = ref as? String {
            return str.isEmpty ? nil : str
        }

        // UID reference to another object in $objects
        if let idx = uidValue(ref), idx < objects.count {
            // The referenced object might be a string directly
            if let str = objects[idx] as? String, str != "$null" {
                return str.isEmpty ? nil : str
            }
            // Or it might be a dict with NS.relative (for NSURL)
            if let urlDict = objects[idx] as? [String: Any],
               let relativeRef = urlDict["NS.relative"],
               let relIdx = uidValue(relativeRef),
               relIdx < objects.count,
               let str = objects[relIdx] as? String, str != "$null" {
                return str.isEmpty ? nil : str
            }
        }

        return nil
    }
}
