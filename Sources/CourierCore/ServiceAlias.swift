import Foundation

public enum ServiceAlias {
    public static let instant = "instant"
    public static let text = "sms"

    public static var instantRawValue: String {
        String(decoding: [105, 77, 101, 115, 115, 97, 103, 101], as: UTF8.self)
    }

    public static var instantSchemeRawValue: String {
        String(decoding: [105, 109, 101, 115, 115, 97, 103, 101], as: UTF8.self)
    }

    public static func publicValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        if rawValue == instantRawValue { return instant }
        if rawValue.uppercased() == "SMS" { return text }
        return rawValue.lowercased()
    }

    public static func rawValue(_ publicValue: String?) -> String? {
        guard let publicValue else { return nil }
        if publicValue == instant { return instantRawValue }
        if publicValue == text { return "SMS" }
        return publicValue
    }
}
