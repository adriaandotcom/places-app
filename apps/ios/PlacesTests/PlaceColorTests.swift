import SwiftUI
import XCTest
@testable import Places

@MainActor final class PlaceColorTests: XCTestCase {
    func testCustomColorsRoundTripAndWideGamutStaysValid() {
        for hex in ["FFFFFF", "000000", "12AB90"] {
            XCTAssertEqual(Palette.hex(Palette.accent(0, hex: hex)), hex)
        }
        let wide = Color(uiColor: UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1))
        let hex = Palette.hex(wide)
        XCTAssertEqual(hex.count, 6)
        XCTAssertNotNil(UInt(hex, radix: 16))
        XCTAssertEqual(Palette.hex(Palette.accent(0, hex: hex)), hex)
    }
    func testCustomIconsKeepReadableContrast() {
        XCTAssertEqual(Palette.hex(Palette.iconInk(0, hex: "FFFFFF")), "000000")
        XCTAssertEqual(Palette.hex(Palette.iconInk(0, hex: "000000")), "FFFFFF")
    }
}
