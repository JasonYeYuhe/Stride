#!/usr/bin/env swift
// Stride - App Store Screenshot Generator
// Generates iPhone 6.7" (1290x2796) + iPad Pro 12.9" (2048x2732) screenshots
// Usage: swift scripts/generate_screenshots.swift

import Cocoa

// Stride brand colors
let bgCard = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
let accentGreen = NSColor(calibratedRed: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)
let accentGreenLight = NSColor(calibratedRed: 0.204, green: 0.780, blue: 0.349, alpha: 0.12)
let textPrimary = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
let textSecondary = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
let textTertiary = NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1.0)

let habitColors: [NSColor] = [
    accentGreen,
    NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1.0),
    NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1.0),
    NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),
]

struct ScreenSize {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat  // relative to iPhone baseline

    // Content area width (centered, with margins)
    var contentWidth: CGFloat { min(width - margin * 2, 1130 * scale) }
    var margin: CGFloat { (width - min(width - 160 * scale, 1130 * scale)) / 2 }

    static let iPhone = ScreenSize(width: 1290, height: 2796, scale: 1.0)
    static let iPad = ScreenSize(width: 2048, height: 2732, scale: 1.15)
}

var S = ScreenSize.iPhone

func createCanvas() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(S.width), pixelsHigh: Int(S.height),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: S.width, height: S.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0),
    ])!
    bg.draw(in: NSRect(x: 0, y: 0, width: S.width, height: S.height), angle: -90)
    return rep
}

func finishCanvas(_ rep: NSBitmapImageRep) {
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Drawing Helpers

func sz(_ v: CGFloat) -> CGFloat { v * S.scale }

func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat? = nil, centered: Bool = false) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let style = NSMutableParagraphStyle()
    style.alignment = centered ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if let maxWidth = maxWidth {
        let rect = NSRect(x: point.x, y: point.y, width: maxWidth, height: size * 1.5)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    } else {
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

func drawRoundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, shadow: Bool = false) {
    if shadow {
        let shadowRect = NSRect(x: rect.minX + 2, y: rect.minY - 4, width: rect.width, height: rect.height)
        NSColor(calibratedWhite: 0.0, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: shadowRect, xRadius: radius, yRadius: radius).fill()
    }
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
}

func drawCircle(at center: NSPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    color.setFill()
    path.fill()
}

func drawTitleBanner(_ title: String, _ subtitle: String) {
    drawText(title, at: NSPoint(x: 0, y: S.height - sz(220)), size: sz(72), weight: .bold, color: textPrimary, maxWidth: S.width, centered: true)
    drawText(subtitle, at: NSPoint(x: 0, y: S.height - sz(300)), size: sz(40), weight: .medium, color: textSecondary, maxWidth: S.width, centered: true)
}

// MARK: - Screenshot 1: Today View

func drawTodayView() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("Build Better Habits", "Track your daily progress with one tap")

    let margin = S.margin
    let w = S.contentWidth
    var y = S.height - sz(420)

    // Date strip
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let dates = ["24", "25", "26", "27", "28", "29", "30"]
    let dayW = w / 7
    for (i, day) in days.enumerated() {
        let dx = margin + CGFloat(i) * dayW + dayW / 2
        let isToday = i == 3
        if isToday {
            drawRoundedRect(NSRect(x: dx - sz(36), y: y - sz(80), width: sz(72), height: sz(100)), radius: sz(20), fill: accentGreen)
            drawText(day, at: NSPoint(x: dx - sz(20), y: y + sz(4)), size: sz(24), weight: .medium, color: .white)
            drawText(dates[i], at: NSPoint(x: dx - sz(16), y: y - sz(60)), size: sz(36), weight: .bold, color: .white)
        } else {
            drawText(day, at: NSPoint(x: dx - sz(20), y: y + sz(4)), size: sz(24), weight: .medium, color: textTertiary)
            drawText(dates[i], at: NSPoint(x: dx - sz(16), y: y - sz(60)), size: sz(36), weight: .semibold, color: textPrimary)
        }
    }
    y -= sz(160)

    // Progress ring
    let ringCenter = NSPoint(x: S.width / 2, y: y - sz(120))
    let ringR = sz(100)
    let ringPath = NSBezierPath()
    ringPath.appendArc(withCenter: ringCenter, radius: ringR, startAngle: 0, endAngle: 360)
    ringPath.lineWidth = sz(16)
    accentGreenLight.setStroke()
    ringPath.stroke()
    let progressPath = NSBezierPath()
    progressPath.appendArc(withCenter: ringCenter, radius: ringR, startAngle: 90, endAngle: 90 - 270, clockwise: true)
    progressPath.lineWidth = sz(16)
    accentGreen.setStroke()
    progressPath.lineCapStyle = .round
    progressPath.stroke()
    drawText("3/4", at: NSPoint(x: ringCenter.x - sz(40), y: ringCenter.y - sz(25)), size: sz(52), weight: .bold, color: textPrimary)
    drawText("75% done today", at: NSPoint(x: 0, y: y - sz(260)), size: sz(30), weight: .medium, color: textSecondary, maxWidth: S.width, centered: true)
    y -= sz(310)

    // Habit cards
    let habits: [(String, String, NSColor, Bool)] = [
        ("🏃", "Morning Run", habitColors[0], true),
        ("📖", "Read 30 min", habitColors[1], true),
        ("💧", "Drink Water", habitColors[2], true),
        ("🧘", "Meditate", habitColors[3], false),
        ("✍️", "Journal", habitColors[4], false),
    ]

    for (emoji, name, color, done) in habits {
        let cardH = sz(110)
        let cardRect = NSRect(x: margin, y: y - cardH, width: w, height: cardH)
        drawRoundedRect(cardRect, radius: sz(20), fill: bgCard, shadow: true)
        drawRoundedRect(NSRect(x: cardRect.minX + sz(16), y: cardRect.minY + sz(20), width: sz(6), height: cardH - sz(40)), radius: sz(3), fill: color)
        drawText(emoji, at: NSPoint(x: margin + sz(36), y: cardRect.minY + sz(28)), size: sz(48), weight: .regular, color: textPrimary)
        drawText(name, at: NSPoint(x: margin + sz(100), y: cardRect.minY + sz(36)), size: sz(34), weight: .semibold, color: textPrimary)

        if done {
            drawCircle(at: NSPoint(x: cardRect.maxX - sz(50), y: cardRect.midY), radius: sz(24), color: color)
            drawText("✓", at: NSPoint(x: cardRect.maxX - sz(64), y: cardRect.midY - sz(18)), size: sz(32), weight: .bold, color: .white)
        } else {
            let circPath = NSBezierPath(ovalIn: NSRect(x: cardRect.maxX - sz(74), y: cardRect.midY - sz(24), width: sz(48), height: sz(48)))
            circPath.lineWidth = sz(3)
            textTertiary.setStroke()
            circPath.stroke()
        }
        y -= cardH + sz(16)
    }

    finishCanvas(rep)
    return rep
}

// MARK: - Screenshot 2: Stats View

func drawStatsView() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("See Your Progress", "Detailed insights into every habit")

    let margin = S.margin
    let w = S.contentWidth
    var y = S.height - sz(420)

    let stats: [(String, String, String)] = [
        ("🔥", "Current Streak", "14 days"),
        ("🏆", "Best Streak", "21 days"),
        ("📊", "30-Day Rate", "87%"),
    ]

    let cardW = (w - sz(40)) / 3
    for (i, stat) in stats.enumerated() {
        let cx = margin + CGFloat(i) * (cardW + sz(20))
        let cardRect = NSRect(x: cx, y: y - sz(180), width: cardW, height: sz(180))
        drawRoundedRect(cardRect, radius: sz(20), fill: bgCard, shadow: true)
        drawText(stat.0, at: NSPoint(x: cx + cardW / 2 - sz(24), y: cardRect.maxY - sz(60)), size: sz(44), weight: .regular, color: textPrimary)
        drawText(stat.2, at: NSPoint(x: cx + sz(10), y: cardRect.minY + sz(60)), size: sz(30), weight: .bold, color: textPrimary, maxWidth: cardW - sz(20), centered: true)
        drawText(stat.1, at: NSPoint(x: cx + sz(10), y: cardRect.minY + sz(24)), size: sz(20), weight: .medium, color: textSecondary, maxWidth: cardW - sz(20), centered: true)
    }
    y -= sz(230)

    // Weekly bar chart
    drawRoundedRect(NSRect(x: margin, y: y - sz(400), width: w, height: sz(400)), radius: sz(24), fill: bgCard, shadow: true)
    drawText("This Week", at: NSPoint(x: margin + sz(24), y: y - sz(50)), size: sz(32), weight: .bold, color: textPrimary)

    let barDays = ["M", "T", "W", "T", "F", "S", "S"]
    let barValues: [CGFloat] = [0.8, 1.0, 0.6, 0.8, 1.0, 0.4, 0.0]
    let barW = (w - sz(120)) / 7
    let maxBarH = sz(220)

    for (i, day) in barDays.enumerated() {
        let bx = margin + sz(48) + CGFloat(i) * barW + barW / 2 - sz(20)
        let by = y - sz(360)
        let bh = max(sz(8), barValues[i] * maxBarH)

        drawRoundedRect(NSRect(x: bx, y: by, width: sz(40), height: maxBarH), radius: sz(8), fill: accentGreenLight)
        drawRoundedRect(NSRect(x: bx, y: by, width: sz(40), height: bh), radius: sz(8), fill: accentGreen)
        drawText(day, at: NSPoint(x: bx + sz(8), y: by - sz(36)), size: sz(26), weight: .medium, color: textSecondary)
    }
    y -= sz(440)

    // Heatmap
    drawRoundedRect(NSRect(x: margin, y: y - sz(320), width: w, height: sz(320)), radius: sz(24), fill: bgCard, shadow: true)
    drawText("Activity Heatmap", at: NSPoint(x: margin + sz(24), y: y - sz(50)), size: sz(32), weight: .bold, color: textPrimary)

    let cellSize = sz(28)
    let cellGap = sz(6)
    let heatmapX = margin + sz(40)
    let heatmapY = y - sz(280)
    let pattern: [CGFloat] = [0.9, 0.7, 0.5, 1.0, 0.8, 0.0, 0.3, 0.6, 1.0, 0.9, 0.4, 0.8, 1.0, 0.7]

    for week in 0..<12 {
        for day in 0..<7 {
            let cx = heatmapX + CGFloat(week) * (cellSize + cellGap)
            let cy = heatmapY + CGFloat(day) * (cellSize + cellGap)
            let intensity = pattern[(week * 7 + day) % pattern.count]
            let color = intensity == 0 ? accentGreenLight : accentGreen.withAlphaComponent(0.3 + intensity * 0.7)
            drawRoundedRect(NSRect(x: cx, y: cy, width: cellSize, height: cellSize), radius: sz(6), fill: color)
        }
    }

    finishCanvas(rep)
    return rep
}

// MARK: - Screenshot 3: Widgets

func drawWidgets() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("Widgets & Reminders", "Stay on track right from your Home Screen")

    let margin = S.margin
    let w = S.contentWidth
    var y = S.height - sz(420)

    // Large widget
    let widgetH = sz(380)
    let widgetRect = NSRect(x: margin, y: y - widgetH, width: w, height: widgetH)
    drawRoundedRect(widgetRect, radius: sz(28), fill: bgCard, shadow: true)

    drawText("Today's Habits", at: NSPoint(x: margin + sz(24), y: widgetRect.maxY - sz(52)), size: sz(28), weight: .bold, color: textPrimary)
    drawText("3 of 5 complete", at: NSPoint(x: margin + sz(24), y: widgetRect.maxY - sz(86)), size: sz(22), weight: .medium, color: textSecondary)

    let widgetHabits: [(String, String, NSColor, Bool)] = [
        ("🏃", "Morning Run", habitColors[0], true),
        ("📖", "Read 30 min", habitColors[1], true),
        ("💧", "Drink Water", habitColors[2], true),
        ("🧘", "Meditate", habitColors[3], false),
        ("✍️", "Journal", habitColors[4], false),
    ]

    var wy = widgetRect.maxY - sz(130)
    for (emoji, name, color, done) in widgetHabits {
        let rowH = sz(44)
        drawText(emoji, at: NSPoint(x: margin + sz(28), y: wy - sz(6)), size: sz(28), weight: .regular, color: textPrimary)
        drawText(name, at: NSPoint(x: margin + sz(70), y: wy - sz(4)), size: sz(26), weight: .medium, color: done ? textSecondary : textPrimary)
        if done {
            drawCircle(at: NSPoint(x: widgetRect.maxX - sz(44), y: wy + sz(12)), radius: sz(14), color: color)
            drawText("✓", at: NSPoint(x: widgetRect.maxX - sz(54), y: wy - sz(2)), size: sz(20), weight: .bold, color: .white)
        } else {
            let c = NSBezierPath(ovalIn: NSRect(x: widgetRect.maxX - sz(58), y: wy - sz(2), width: sz(28), height: sz(28)))
            c.lineWidth = sz(2)
            textTertiary.setStroke()
            c.stroke()
        }
        wy -= rowH
    }

    y -= widgetH + sz(30)

    // Two small widgets
    let smallW = (w - sz(20)) / 2
    let smallH = sz(200)

    let streakRect = NSRect(x: margin, y: y - smallH, width: smallW, height: smallH)
    drawRoundedRect(streakRect, radius: sz(24), fill: bgCard, shadow: true)
    drawText("🔥", at: NSPoint(x: margin + smallW / 2 - sz(28), y: streakRect.maxY - sz(80)), size: sz(56), weight: .regular, color: textPrimary)
    drawText("14", at: NSPoint(x: margin + smallW / 2 - sz(24), y: streakRect.minY + sz(60)), size: sz(52), weight: .bold, color: textPrimary)
    drawText("day streak", at: NSPoint(x: margin + sz(10), y: streakRect.minY + sz(24)), size: sz(24), weight: .medium, color: textSecondary, maxWidth: smallW - sz(20), centered: true)

    let compRect = NSRect(x: margin + smallW + sz(20), y: y - smallH, width: smallW, height: smallH)
    drawRoundedRect(compRect, radius: sz(24), fill: bgCard, shadow: true)
    drawText("📊", at: NSPoint(x: compRect.minX + smallW / 2 - sz(28), y: compRect.maxY - sz(80)), size: sz(56), weight: .regular, color: textPrimary)
    drawText("87%", at: NSPoint(x: compRect.minX + smallW / 2 - sz(42), y: compRect.minY + sz(60)), size: sz(52), weight: .bold, color: accentGreen)
    drawText("this month", at: NSPoint(x: compRect.minX + sz(10), y: compRect.minY + sz(24)), size: sz(24), weight: .medium, color: textSecondary, maxWidth: smallW - sz(20), centered: true)

    y -= smallH + sz(50)

    drawText("Lock Screen • Home Screen • StandBy", at: NSPoint(x: 0, y: y), size: sz(30), weight: .semibold, color: textSecondary, maxWidth: S.width, centered: true)
    y -= sz(50)
    drawText("Widgets keep your habits visible — no need to open the app.", at: NSPoint(x: margin, y: y), size: sz(28), weight: .regular, color: textTertiary, maxWidth: w, centered: false)

    finishCanvas(rep)
    return rep
}

// MARK: - Save

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed PNG for \(path)")
        return
    }
    try! png.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

// MARK: - Generate

let scriptPath = CommandLine.arguments[0]
let scriptDir = (scriptPath as NSString).deletingLastPathComponent
let baseDir = scriptDir.isEmpty ? "." : scriptDir
let outDir = baseDir + "/../build/ios-screenshots"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iPhone 6.7" (1290x2796)
print("Generating iPhone 6.7\" screenshots (1290x2796)...")
S = .iPhone
savePNG(drawTodayView(), to: outDir + "/01_today_6.7.png")
savePNG(drawStatsView(), to: outDir + "/02_stats_6.7.png")
savePNG(drawWidgets(), to: outDir + "/03_widgets_6.7.png")

// iPad Pro 12.9" (2048x2732)
print("\nGenerating iPad Pro 12.9\" screenshots (2048x2732)...")
S = .iPad
savePNG(drawTodayView(), to: outDir + "/01_today_ipad.png")
savePNG(drawStatsView(), to: outDir + "/02_stats_ipad.png")
savePNG(drawWidgets(), to: outDir + "/03_widgets_ipad.png")

print("\nDone!")
