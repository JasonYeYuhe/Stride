import XCTest
import SwiftUI
import Foundation

final class ColorExtensionTests: XCTestCase {

    // MARK: - Valid hex

    func testValidHexWithHash() {
        let color = Color(hex: "#FF0000")
        XCTAssertNotNil(color)
    }

    func testValidHexWithoutHash() {
        let color = Color(hex: "00FF00")
        XCTAssertNotNil(color)
    }

    func testValidHexBlack() {
        let color = Color(hex: "#000000")
        XCTAssertNotNil(color)
    }

    func testValidHexWhite() {
        let color = Color(hex: "#FFFFFF")
        XCTAssertNotNil(color)
    }

    func testValidHexLowercase() {
        let color = Color(hex: "#ff9500")
        XCTAssertNotNil(color)
    }

    func testValidHexWithWhitespace() {
        let color = Color(hex: "  #34C759  ")
        XCTAssertNotNil(color)
    }

    // MARK: - Invalid hex

    func testInvalidHexReturnsNil() {
        let color = Color(hex: "ZZZZZZ")
        XCTAssertNil(color)
    }

    func testEmptyStringReturnsNil() {
        let color = Color(hex: "")
        XCTAssertNil(color)
    }

    func testInvalidCharactersReturnsNil() {
        let color = Color(hex: "#GGGGGG")
        XCTAssertNil(color)
    }

    // MARK: - HabitColor

    func testAllHabitColorsAreValid() {
        for habitColor in HabitColor.all {
            let color = Color(hex: habitColor.hex)
            XCTAssertNotNil(color, "HabitColor '\(habitColor.name)' has invalid hex: \(habitColor.hex)")
        }
    }
}
