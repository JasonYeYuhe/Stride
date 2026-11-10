import SwiftUI

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Cross-platform background colors
extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #elseif os(watchOS)
        Color.black
        #else
        Color(.systemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #elseif os(watchOS)
        Color(.darkGray)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(macOS)
        Color(NSColor.underPageBackgroundColor)
        #elseif os(watchOS)
        Color.gray.opacity(0.3)
        #else
        Color(.tertiarySystemBackground)
        #endif
    }
}

// MARK: - Contrast (WCAG 2)

/// A habit colour's contrast where it is drawn as text, or under text (RELEASE-1.4.1.md gate 8,
/// 2026-10-17). The colour is the user's pick and fills its shapes as it is — the heatmap, the
/// History circles, the check. As TEXT on a card it is checked here first: the palette's Yellow
/// measured 1.35:1 on the light card, Green 1.99:1 and Orange 1.97:1, under the 4.5:1 body text
/// needs. And text drawn ON a habit-colour fill turns dark where white would not be read.
enum ColorContrast {
    /// sRGB components, 0...1.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `0xRRGGBB`.
        init(_ hex: UInt32) {
            self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        /// "#RRGGBB", read as `Color(hex:)` reads it; nil where that is nil.
        init?(hex: String) {
            let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            var rgb: UInt64 = 0
            guard Scanner(string: digits).scanHexInt64(&rgb) else { return nil }
            self.init(UInt32(truncatingIfNeeded: rgb & 0xFFFFFF))
        }

        var color: Color { Color(red: red, green: green, blue: blue) }

        static let white = RGB(0xFFFFFF)
        static let black = RGB(0x000000)
        /// `Habit.color`'s fallback for a hex that does not parse (`.green`, the palette's Green).
        static let fallback = RGB(0x34C759)
    }

    /// The card a habit colour's text sits on: `Color.appSecondaryBackground` on iOS
    /// (secondarySystemBackground). The Mac's light card (controlBackgroundColor) is white, which
    /// a colour that clears #F2F2F7 clears too.
    static let lightCard = RGB(0xF2F2F7)
    static let darkCard = RGB(0x1C1C1E)

    /// WCAG 2 AA for body text (1.4.3).
    static let textMinimum = 4.5
    /// WCAG 2 AA for large text and for marks that are not text (1.4.3, 1.4.11).
    static let markMinimum = 3.0

    /// Relative luminance (WCAG 2).
    static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// The contrast ratio, 1...21.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` as text on `background`: unchanged where it reaches `minimum`, otherwise mixed with
    /// black (on a light background; white on a dark one) just as far as it takes — the same hue,
    /// darker. On the light card Green #34C759 becomes #217F39, Orange #A35F00 and Yellow #876C00.
    static func readable(_ color: RGB, on background: RGB, minimum: Double = textMinimum) -> RGB {
        guard ratio(color, background) < minimum else { return color }
        let toward: RGB = ratio(.black, background) >= ratio(.white, background) ? .black : .white
        func mixed(_ t: Double) -> RGB {
            RGB(red: color.red + (toward.red - color.red) * t, green: color.green + (toward.green - color.green) * t,
                blue: color.blue + (toward.blue - color.blue) * t)
        }
        // The ratio grows with the mix, so the least mix that reaches it is a bisection away.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if ratio(mixed(mid), background) >= minimum { high = mid } else { low = mid }
        }
        return mixed(high)
    }

    /// Text and marks drawn ON a fill of `fill`: white while white reaches `minimum` there, as the
    /// app always drew it, and black where black reads better — the palette's Green, Orange, Teal
    /// and Yellow (white 2.2, 2.2, 1.9 and 1.5:1; black 9.5:1 and up). Blue, Purple, Red and
    /// Pink keep white (4.0 to 3.6:1), the level of the system's own white-on-tint buttons.
    static func prefersDarkContent(on fill: RGB, minimum: Double = markMinimum) -> Bool {
        let white = ratio(.white, fill)
        return white < minimum && ratio(.black, fill) > white
    }
}

extension Color {
    /// A habit colour (`colorHex`) as text on a card in `scheme`: the colour itself where it is
    /// readable there, a darker (or, on the dark card, lighter) shade of it where it is not
    /// (`ColorContrast.readable`).
    static func readableText(hex: String, in scheme: ColorScheme) -> Color {
        let color = ColorContrast.RGB(hex: hex) ?? .fallback
        let card = scheme == .dark ? ColorContrast.darkCard : ColorContrast.lightCard
        return ColorContrast.readable(color, on: card).color
    }

    /// Text and marks on a fill of the habit colour `hex`: white, or black where white would not
    /// be read (`ColorContrast.prefersDarkContent`).
    static func content(onFillHex hex: String) -> Color {
        ColorContrast.prefersDarkContent(on: ColorContrast.RGB(hex: hex) ?? .fallback) ? .black : .white
    }
}

struct HabitColor: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
    var color: Color { Color(hex: hex) ?? .green }

    static let all: [HabitColor] = [
        HabitColor(name: "Green", hex: "#34C759"),
        HabitColor(name: "Blue", hex: "#007AFF"),
        HabitColor(name: "Purple", hex: "#AF52DE"),
        HabitColor(name: "Orange", hex: "#FF9500"),
        HabitColor(name: "Red", hex: "#FF3B30"),
        HabitColor(name: "Pink", hex: "#FF2D55"),
        HabitColor(name: "Teal", hex: "#5AC8FA"),
        HabitColor(name: "Yellow", hex: "#FFCC00"),
    ]
}

struct HabitEmoji {
    static let all: [String] = [
        "⭐", "💪", "📚", "🏃", "💧", "🧘", "✍️", "🎯",
        "💤", "🍎", "🎸", "🧹", "💊", "🌱", "🎨", "💻",
        "🏋️", "🚶", "🧠", "❤️", "☀️", "🌙", "🔥", "✅"
    ]
}
