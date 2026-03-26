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
        #else
        Color(.systemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(macOS)
        Color(NSColor.underPageBackgroundColor)
        #else
        Color(.tertiarySystemBackground)
        #endif
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
