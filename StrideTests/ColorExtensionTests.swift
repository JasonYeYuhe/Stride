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

    // MARK: - Contrast (gate 8, 2026-10-17)

    func testTheContrastRatioIsWCAGs() throws {
        XCTAssertEqual(ColorContrast.ratio(.black, .white), 21, accuracy: 0.001)
        XCTAssertEqual(ColorContrast.ratio(.white, .white), 1, accuracy: 0.001)
        // The capture's measurement: Morning Run's green "Edit history" on the light card.
        let green = try XCTUnwrap(ColorContrast.RGB(hex: "#34C759"))
        XCTAssertEqual(ColorContrast.ratio(green, ColorContrast.lightCard), 1.99, accuracy: 0.01)
        XCTAssertEqual(ColorContrast.RGB(hex: "  #FFCC00 "), ColorContrast.RGB(0xFFCC00))
        XCTAssertNil(ColorContrast.RGB(hex: "#GGGGGG"))
    }

    /// Every palette colour as text on either card reads at 4.5:1 or better, and keeps its hue: a
    /// shade of it, never another colour. A colour that already reads is left exactly as it is.
    func testEveryPaletteColourIsReadableAsTextOnEitherCard() throws {
        for habitColor in HabitColor.all {
            let color = try XCTUnwrap(ColorContrast.RGB(hex: habitColor.hex))
            for card in [ColorContrast.lightCard, ColorContrast.darkCard] {
                let text = ColorContrast.readable(color, on: card)
                let ratio = ColorContrast.ratio(text, card)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(habitColor.name) on \(card)")
                if ColorContrast.ratio(color, card) >= 4.5 {
                    XCTAssertEqual(text, color, "\(habitColor.name) already reads on \(card)")
                } else {
                    // Just as far as it takes, not all the way to black or white.
                    XCTAssertLessThan(ratio, 4.6, "\(habitColor.name) on \(card): darkened past the need")
                    let order = { (c: ColorContrast.RGB) in [c.red, c.green, c.blue].enumerated().sorted { $0.element < $1.element }.map(\.offset) }
                    XCTAssertEqual(order(text), order(color), "\(habitColor.name) on \(card): the same hue")
                }
            }
        }
        let yellow = try XCTUnwrap(ColorContrast.RGB(hex: "#FFCC00"))
        XCTAssertLessThan(ColorContrast.ratio(yellow, ColorContrast.lightCard), 1.4, "the case that was invisible")
    }

    /// White on a habit-colour fill (History's day digits and note dot, the heatmap's note dot)
    /// stays white where it reaches 3:1, and turns black where it does not.
    func testContentOnAFillTurnsDarkOnlyWhereWhiteIsNotRead() throws {
        let dark = Set(try HabitColor.all.filter {
            ColorContrast.prefersDarkContent(on: try XCTUnwrap(ColorContrast.RGB(hex: $0.hex)))
        }.map(\.name))
        XCTAssertEqual(dark, ["Green", "Orange", "Teal", "Yellow"])
        for habitColor in HabitColor.all {
            let fill = try XCTUnwrap(ColorContrast.RGB(hex: habitColor.hex))
            let content: ColorContrast.RGB = ColorContrast.prefersDarkContent(on: fill) ? .black : .white
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(content, fill), 3.5, habitColor.name)
        }
    }

    /// Small text on a habit-colour fill (Top 5 Streaks' "Current" chip) asks for 4.5:1: white
    /// read 2.2:1 on Green and 1.5:1 on Yellow, and even Blue, Purple, Red and Pink, which keep
    /// white at 3:1, fall short of 4.5 with it (4.0 to 3.6). The fill is the habit's colour in
    /// light and dark mode alike, so one check covers both. Any fill gets one of the two at
    /// 4.58:1 or more.
    func testSmallTextOnAHabitColourFillReadsAtFourAndAHalfToOne() throws {
        for habitColor in HabitColor.all {
            let fill = try XCTUnwrap(ColorContrast.RGB(hex: habitColor.hex))
            let text = ColorContrast.content(on: fill, minimum: ColorContrast.textMinimum)
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(text, fill), ColorContrast.textMinimum, habitColor.name)
            XCTAssertLessThan(ColorContrast.ratio(.white, fill), ColorContrast.textMinimum, "\(habitColor.name): white did not")
        }
        XCTAssertEqual(ColorContrast.content(on: ColorContrast.RGB(0x1C1C1E), minimum: ColorContrast.textMinimum), .white,
                       "a dark fill keeps white")
        // The default stays the 3:1 mark rule: History's digits keep white on Blue.
        XCTAssertEqual(ColorContrast.content(on: ColorContrast.RGB(0x007AFF)), .white)
    }
}
