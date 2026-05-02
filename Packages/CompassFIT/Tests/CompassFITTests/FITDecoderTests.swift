import Testing
import Foundation
@testable import CompassFIT

@Suite("FITTimestamp")
struct FITTimestampTests {

    @Test("FIT epoch is 1989-12-31 UTC")
    func epochIs1989() {
        let epoch = FITTimestamp.date(fromFITTimestamp: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let components = cal.dateComponents([.year, .month, .day], from: epoch)
        #expect(components.year == 1989)
        #expect(components.month == 12)
        #expect(components.day == 31)
    }

    @Test("FIT timestamp adds seconds to epoch")
    func addsSeconds() {
        let then = FITTimestamp.date(fromFITTimestamp: 3600)
        let diff = then.timeIntervalSince(FITTimestamp.epoch)
        #expect(diff == 3600)
    }
}
