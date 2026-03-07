import Testing
import Foundation
@testable import CourierCore

@Suite("AppleDate Conversion Tests")
struct DateConversionTests {
    @Test("Convert nanosecond timestamp to Date")
    func toDate() {
        // 2024-01-15 12:00:00 UTC
        let ns: Int64 = 727012800_000_000_000
        let date = AppleDate.toDate(ns)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        #expect(components.year == 2024)
        #expect(components.month == 1)
        #expect(components.day == 15)
        #expect(components.hour == 12)
    }

    @Test("Zero timestamp returns distantPast")
    func zeroTimestamp() {
        let date = AppleDate.toDate(0)
        #expect(date == .distantPast)
    }

    @Test("Round-trip conversion")
    func roundTrip() {
        let now = Date()
        let ns = AppleDate.fromDate(now)
        let roundTripped = AppleDate.toDate(ns)
        #expect(abs(now.timeIntervalSince(roundTripped)) < 0.000001)
    }
}
