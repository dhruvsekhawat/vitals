import XCTest
@testable import VitalsCore

final class FormatTests: XCTestCase {

    // MARK: bytes

    func testBytesBelowOneGigabyteAreWholeMegabytes() {
        XCTAssertEqual(Format.bytes(0), "0 MB")
        XCTAssertEqual(Format.bytes(512 * MB), "512 MB")
        // 1 GB minus one byte is still 1023 MB, never "1.0 GB".
        XCTAssertEqual(Format.bytes(GB - 1), "1023 MB")
    }

    func testBytesBetweenOneAndTenGigabytesHaveOneDecimal() {
        XCTAssertEqual(Format.bytes(GB), "1.0 GB")
        XCTAssertEqual(Format.bytes(1_610_612_736), "1.5 GB")   // 1.5 * 2^30
        XCTAssertEqual(Format.bytes(9_985_798_963), "9.3 GB")   // 9.3 * 2^30, truncated
    }

    func testBytesAtTenGigabytesAndAboveAreWholeGigabytes() {
        XCTAssertEqual(Format.bytes(10 * GB), "10 GB")
        XCTAssertEqual(Format.bytes(34 * GB), "34 GB")
        XCTAssertEqual(Format.bytes(15 * GB + 900 * MB), "16 GB")   // 15.88 rounds up
    }

    // MARK: duration

    func testDurationNeverReportsLessThanOneMinute() {
        XCTAssertEqual(Format.duration(0), "1m")
        XCTAssertEqual(Format.duration(59), "1m")
    }

    func testDurationMinutesHoursDays() {
        XCTAssertEqual(Format.duration(60), "1m")
        XCTAssertEqual(Format.duration(45 * 60), "45m")
        XCTAssertEqual(Format.duration(61 * 60), "1h")
        XCTAssertEqual(Format.duration(47 * 3600), "47h")
        XCTAssertEqual(Format.duration(48 * 3600), "2d")
        XCTAssertEqual(Format.duration(19 * 86400), "19d")
    }

    // MARK: ago

    func testAgoUnderAMinuteIsJustNow() {
        XCTAssertEqual(Format.ago(T0, now: T0), "just now")
        XCTAssertEqual(Format.ago(T0.addingTimeInterval(-59), now: T0), "just now")
    }

    func testAgoUsesDurationSuffix() {
        XCTAssertEqual(Format.ago(T0.addingTimeInterval(-120), now: T0), "2m ago")
        XCTAssertEqual(Format.ago(T0.addingTimeInterval(-3 * 86400), now: T0), "3d ago")
    }

    // MARK: uptime

    func testUptimeUnderADayIsHoursOnly() {
        XCTAssertEqual(Format.uptime(5 * 3600), "5h")
        XCTAssertEqual(Format.uptime(0), "0h")
    }

    func testUptimeWithDaysShowsDaysAndHours() {
        XCTAssertEqual(Format.uptime(41 * 86400 + 8 * 3600), "41d 8h")
        XCTAssertEqual(Format.uptime(86400), "1d 0h")
    }
}
