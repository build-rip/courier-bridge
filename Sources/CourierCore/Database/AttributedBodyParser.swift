import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Rich Text Data Structures

/// A single run of text with consistent formatting attributes.
public struct RichTextPart: Sendable, Codable, Equatable {
    public let text: String
    public let attributes: RichTextAttributes

    public init(text: String, attributes: RichTextAttributes = RichTextAttributes()) {
        self.text = text
        self.attributes = attributes
    }
}

/// Formatting attributes for a rich text part.
public struct RichTextAttributes: Sendable, Codable, Equatable {
    public var bold: Bool?
    public var italic: Bool?
    public var strikethrough: Bool?
    public var underline: Bool?
    public var link: String?
    public var mention: String?  // The mentioned handle ID (phone/email)
    public var attachmentIndex: Int?  // 0-based index into the message's attachment list

    public init(
        bold: Bool? = nil,
        italic: Bool? = nil,
        strikethrough: Bool? = nil,
        underline: Bool? = nil,
        link: String? = nil,
        mention: String? = nil,
        attachmentIndex: Int? = nil
    ) {
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.underline = underline
        self.link = link
        self.mention = mention
        self.attachmentIndex = attachmentIndex
    }

    /// Returns true if all attributes are nil (no formatting).
    public var isEmpty: Bool {
        bold == nil && italic == nil && strikethrough == nil
            && underline == nil && link == nil && mention == nil
            && attachmentIndex == nil
    }
}

/// Structured rich text representation of a message body.
public struct RichText: Sendable, Codable, Equatable {
    public let parts: [RichTextPart]

    public init(parts: [RichTextPart]) {
        self.parts = parts
    }

    /// Returns true if the message has any formatting (not all parts are plain text).
    public var hasFormatting: Bool {
        parts.contains { !$0.attributes.isEmpty }
    }
}

/// Result of parsing an attributedBody blob.
public struct ParsedBody: Sendable {
    /// The plain text content, cleaned of any prefix/control characters.
    public let text: String?
    /// Structured rich text with formatting attributes. Nil if no formatting is present.
    public let richText: RichText?
}

// MARK: - Parser

public enum AttributedBodyParser {
    /// Extract plain text from an Messages attributedBody blob.
    ///
    /// On macOS Ventura+, many messages have `text=NULL` and the actual text
    /// is stored in the `attributedBody` column as an NSKeyedArchiver blob.
    public static func extractText(from data: Data) -> String? {
        return parse(from: data).text
    }

    /// Parse an Messages attributedBody blob into plain text and rich text parts.
    ///
    /// Returns a `ParsedBody` with:
    /// - `text`: Clean plain text (no control/prefix characters)
    /// - `richText`: Structured rich text with formatting, only if the message has formatting
    public static func parse(from data: Data) -> ParsedBody {
        // Try NSKeyedUnarchiver first (proper approach)
        if let result = parseViaUnarchiver(data) {
            return result
        }
        // Fall back to byte-marker scanning for plain text only
        let text = extractViaByteScanning(data)
        return ParsedBody(text: text, richText: nil)
    }

    // MARK: - NSKeyedUnarchiver / NSUnarchiver approach

    private static func parseViaUnarchiver(_ data: Data) -> ParsedBody? {
        // Try NSKeyedUnarchiver first (bplist00 format)
        let unarchived: NSAttributedString?
        if let keyed = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSAttributedString.self, NSString.self, NSDictionary.self,
                        NSArray.self, NSNumber.self, NSURL.self, NSData.self],
            from: data
        ) as? NSAttributedString {
            unarchived = keyed
        } else {
            // Fall back to NSUnarchiver for streamtyped format (used by most Messages attributedBody blobs).
            // NSUnarchiver is deprecated but is the only way to decode streamtyped archives.
            unarchived = unarchiveStreamtyped(data)
        }
        guard let unarchived else { return nil }

        let plainText = unarchived.string
        guard !plainText.isEmpty else { return nil }

        // Clean the plain text: remove the Unicode Object Replacement Character
        // (U+FFFC) that Messages uses as a placeholder for attachments/invisible objects
        let cleanText = cleanPlainText(plainText)
        guard !cleanText.isEmpty else { return nil }

        // Extract rich text attributes
        let richText = extractRichText(from: unarchived, cleanText: cleanText)

        return ParsedBody(
            text: cleanText,
            richText: richText?.hasFormatting == true ? richText : nil
        )
    }

    /// Clean plain text by removing control characters.
    /// Preserves U+FFFC (Object Replacement Character) — these are attachment placeholders
    /// that indicate where inline attachments appear within the text.
    private static func cleanPlainText(_ text: String) -> String {
        var cleaned = text

        // Remove invisible/control characters that Messages may inject
        // but preserve normal whitespace (spaces, newlines, tabs) and U+FFFC (attachment placeholders)
        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            if scalar.value >= 0x20 { return true }  // space and above (includes U+FFFC)
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
            return false
        })

        // Trim leading/trailing whitespace that may remain after removals
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    /// Extract structured rich text from an NSAttributedString.
    private static func extractRichText(from attrString: NSAttributedString, cleanText: String) -> RichText? {
        let fullRange = NSRange(location: 0, length: attrString.length)
        guard fullRange.length > 0 else { return nil }

        var parts: [RichTextPart] = []
        var attachmentCounter = 0
        let nsString = attrString.string as NSString

        attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let substring = nsString.substring(with: range)

            // Emit U+FFFC (Object Replacement Character) as an attachment placeholder part
            if substring == "\u{FFFC}" {
                var richAttrs = RichTextAttributes()
                richAttrs.attachmentIndex = attachmentCounter
                attachmentCounter += 1
                parts.append(RichTextPart(text: "\u{FFFC}", attributes: richAttrs))
                return
            }

            // Clean this substring the same way we clean the full text
            let cleanedSubstring = cleanPartText(substring)
            if cleanedSubstring.isEmpty { return }

            var richAttrs = RichTextAttributes()

            // Check for bold/italic via NSFont
            #if canImport(AppKit)
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    richAttrs.bold = true
                }
                if traits.contains(.italic) {
                    richAttrs.italic = true
                }
            }
            #endif

            // Check for links (NSLink attribute)
            if let link = attrs[.link] {
                if let url = link as? URL {
                    richAttrs.link = url.absoluteString
                } else if let urlString = link as? String {
                    richAttrs.link = urlString
                }
            }

            // Check for strikethrough
            if let strikethrough = attrs[.strikethroughStyle] as? Int, strikethrough != 0 {
                richAttrs.strikethrough = true
            }

            // Check for underline
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
                richAttrs.underline = true
            }

            // Check for Messages mention attribute
            // Messages stores mentions using __kIMMessagePartAttributeName
            let mentionKey = NSAttributedString.Key(rawValue: "__kIMMessagePartAttributeName")
            if let mentionValue = attrs[mentionKey] {
                // The mention value is typically a dictionary or string with the handle info
                if let mentionDict = mentionValue as? [String: Any],
                   let handleID = mentionDict["__kIMDataDetectedAttributeMonogramHandleKey"] as? String {
                    richAttrs.mention = handleID
                } else if let mentionString = mentionValue as? String {
                    richAttrs.mention = mentionString
                }
            }

            // Also check for the newer mention key used in recent macOS versions
            let mentionKey2 = NSAttributedString.Key(rawValue: "__kIMMentionConfirmedMention")
            if let mentionValue = attrs[mentionKey2] as? String, richAttrs.mention == nil {
                richAttrs.mention = mentionValue
            }

            parts.append(RichTextPart(text: cleanedSubstring, attributes: richAttrs))
        }

        // Merge adjacent parts with identical attributes to keep the output clean
        let mergedParts = mergeParts(parts)

        guard !mergedParts.isEmpty else { return nil }
        return RichText(parts: mergedParts)
    }

    /// Clean a substring from a rich text part (remove control characters, preserve U+FFFC).
    private static func cleanPartText(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            if scalar.value >= 0x20 { return true }  // space and above (includes U+FFFC)
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
            return false
        })
    }

    /// Merge adjacent parts that have the same attributes.
    private static func mergeParts(_ parts: [RichTextPart]) -> [RichTextPart] {
        guard !parts.isEmpty else { return [] }

        var merged: [RichTextPart] = []
        var current = parts[0]

        for i in 1..<parts.count {
            let next = parts[i]
            if current.attributes == next.attributes {
                current = RichTextPart(
                    text: current.text + next.text,
                    attributes: current.attributes
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        return merged
    }

    // MARK: - Legacy NSUnarchiver for streamtyped format

    @available(macOS, deprecated: 10.13, message: "Required for decoding streamtyped archives from Messages")
    private static func unarchiveStreamtyped(_ data: Data) -> NSAttributedString? {
        NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString
    }

    // MARK: - Byte scanning fallback

    /// Scan for text between known byte markers in the attributedBody blob.
    /// This is a last-resort fallback when NSKeyedUnarchiver fails.
    /// Improved to avoid picking up internal archive structure as text.
    private static func extractViaByteScanning(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }

        // Strategy: look for the NSString content within the keyed archive.
        // The actual message text in an NSKeyedArchiver blob for NSAttributedString
        // is stored as a UTF-8 string typically preceded by a length indicator.
        //
        // We look for the "NSString" class key followed by the actual string data.
        // The string is usually stored after a specific header pattern.

        // Find "NSString" or "NS.string" markers in the binary plist
        let nsStringMarker = [UInt8]("NS.string".utf8)

        var candidateTexts: [String] = []

        for i in 0..<(bytes.count - nsStringMarker.count) {
            var matches = true
            for j in 0..<nsStringMarker.count {
                if bytes[i + j] != nsStringMarker[j] {
                    matches = false
                    break
                }
            }
            if !matches { continue }

            // Found "NS.string" marker -- the text content should follow nearby
            // Scan forward to find a plausible UTF-8 text run
            let searchStart = i + nsStringMarker.count
            let searchEnd = min(searchStart + 200, bytes.count)

            for k in searchStart..<searchEnd {
                // Look for a length-prefixed string: length byte followed by printable UTF-8
                let remaining = bytes.count - k
                if remaining < 2 { continue }

                let possibleLen = Int(bytes[k])
                if possibleLen > 0 && possibleLen < remaining - 1 {
                    let textStart = k + 1
                    let textEnd = textStart + possibleLen
                    if textEnd <= bytes.count {
                        let subdata = Data(bytes[textStart..<textEnd])
                        if let text = String(data: subdata, encoding: .utf8),
                           !text.isEmpty,
                           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" })
                        {
                            candidateTexts.append(text)
                        }
                    }
                }
            }
        }

        // Return the longest candidate (most likely the actual message text)
        return candidateTexts.max(by: { $0.count < $1.count })
    }
}
