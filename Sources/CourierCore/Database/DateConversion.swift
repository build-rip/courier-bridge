import Foundation

public enum AppleDate {
    /// Apple's Core Data epoch: 2001-01-01 00:00:00 UTC
    private static let coreDataEpochOffset: TimeInterval = 978307200

    /// Convert Messages nanosecond timestamp to Date.
    /// Messages stores dates as nanoseconds since 2001-01-01 UTC.
    public static func toDate(_ nanoseconds: Int64) -> Date {
        guard nanoseconds != 0 else { return .distantPast }
        let seconds = TimeInterval(nanoseconds) / 1_000_000_000
        let unixTimestamp = seconds + coreDataEpochOffset
        return Date(timeIntervalSince1970: unixTimestamp)
    }

    /// Convert Date to Messages nanosecond timestamp.
    public static func fromDate(_ date: Date) -> Int64 {
        let unixTimestamp = date.timeIntervalSince1970
        let seconds = unixTimestamp - coreDataEpochOffset
        return Int64(seconds * 1_000_000_000)
    }
}
