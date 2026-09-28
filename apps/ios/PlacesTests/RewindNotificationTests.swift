import XCTest
import PlacesCore
@testable import Places

final class RewindNotificationTests: XCTestCase {
    func testMonthlyNotificationStillOpensTheRightMonthAfterTravellingWest() throws {
        var departure = Calendar(identifier: .gregorian)
        departure.timeZone = TimeZone(identifier: "Europe/Athens")!
        let month = departure.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let request = try XCTUnwrap(RewindRequest.notification(kind: "monthly", period: month.timeIntervalSince1970))
        var arrival = Calendar(identifier: .gregorian)
        arrival.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(arrival.component(.month, from: request.month), 9)
        XCTAssertFalse(request.reviewWeek)
    }
    func testWeeklyNotificationPreservesItsReviewPeriodAndOtherKindsAreIgnored() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try XCTUnwrap(RewindRequest.notification(kind: "weekly", period: start.timeIntervalSince1970))
        XCTAssertEqual(request.month, start)
        XCTAssertTrue(request.reviewWeek)
        XCTAssertNil(RewindRequest.notification(kind: "location-access", period: start.timeIntervalSince1970))
    }
}
