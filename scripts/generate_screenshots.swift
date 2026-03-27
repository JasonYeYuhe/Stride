#!/usr/bin/env swift
// Stride - App Store Screenshot Generator
// Generates iPhone 6.7" (1290x2796) screenshots
// Usage: swift scripts/generate_screenshots.swift

import Cocoa

let screenWidth: CGFloat = 1290
let screenHeight: CGFloat = 2796

// Stride brand colors
let bgWhite = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
let bgCard = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
let accentGreen = NSColor(calibratedRed: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)  // #34C759
let accentGreenLight = NSColor(calibratedRed: 0.204, green: 0.780, blue: 0.349, alpha: 0.12)
let textPrimary = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
let textSecondary = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
let textTertiary = NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1.0)

let habitColors: [NSColor] = [
    accentGreen,
    NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),   // blue
    NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1.0),   // orange
    NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1.0), // purple
    NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),  // red
]

func createCanvas() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(screenWidth), pixelsHigh: Int(screenHeight),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: screenWidth, height: screenHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Light gradient background
    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0),
    ])!
    bg.draw(in: NSRect(x: 0, y: 0, width: screenWidth, height: screenHeight), angle: -90)
    return rep
}

func finishCanvas(_ rep: NSBitmapImageRep) {
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Drawing Helpers

func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat? = nil, centered: Bool = false) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let style = NSMutableParagraphStyle()
    style.alignment = centered ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if let maxWidth = maxWidth {
        let rect = NSRect(x: point.x, y: point.y, width: maxWidth, height: size * 4)
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
    drawText(title, at: NSPoint(x: 0, y: screenHeight - 220), size: 72, weight: .bold, color: textPrimary, maxWidth: screenWidth, centered: true)
    drawText(subtitle, at: NSPoint(x: 0, y: screenHeight - 300), size: 40, weight: .medium, color: textSecondary, maxWidth: screenWidth, centered: true)
}

// MARK: - Screenshot 1: Today View

func drawTodayView() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("Build Better Habits", "Track your daily progress with one tap")

    let margin: CGFloat = 80
    let w = screenWidth - margin * 2
    var y = screenHeight - 420

    // Date strip
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let dates = ["24", "25", "26", "27", "28", "29", "30"]
    let dayW = w / 7
    for (i, day) in days.enumerated() {
        let dx = margin + CGFloat(i) * dayW + dayW / 2
        let isToday = i == 3
        if isToday {
            drawRoundedRect(NSRect(x: dx - 36, y: y - 80, width: 72, height: 100), radius: 20, fill: accentGreen)
            drawText(day, at: NSPoint(x: dx - 20, y: y + 4), size: 24, weight: .medium, color: .white)
            drawText(dates[i], at: NSPoint(x: dx - 16, y: y - 60), size: 36, weight: .bold, color: .white)
        } else {
            drawText(day, at: NSPoint(x: dx - 20, y: y + 4), size: 24, weight: .medium, color: textTertiary)
            drawText(dates[i], at: NSPoint(x: dx - 16, y: y - 60), size: 36, weight: .semibold, color: textPrimary)
        }
    }
    y -= 160

    // Progress ring area
    let ringCenter = NSPoint(x: screenWidth / 2, y: y - 120)
    let ringR: CGFloat = 100
    // Background ring
    let ringPath = NSBezierPath()
    ringPath.appendArc(withCenter: ringCenter, radius: ringR, startAngle: 0, endAngle: 360)
    ringPath.lineWidth = 16
    accentGreenLight.setStroke()
    ringPath.stroke()
    // Progress ring (75%)
    let progressPath = NSBezierPath()
    progressPath.appendArc(withCenter: ringCenter, radius: ringR, startAngle: 90, endAngle: 90 - 270, clockwise: true)
    progressPath.lineWidth = 16
    accentGreen.setStroke()
    progressPath.lineCapStyle = .round
    progressPath.stroke()
    drawText("3/4", at: NSPoint(x: ringCenter.x - 40, y: ringCenter.y - 25), size: 52, weight: .bold, color: textPrimary)
    drawText("75% done today", at: NSPoint(x: 0, y: y - 260), size: 30, weight: .medium, color: textSecondary, maxWidth: screenWidth, centered: true)
    y -= 310

    // Habit cards
    let habits: [(String, String, NSColor, Bool)] = [
        ("🏃", "Morning Run", habitColors[0], true),
        ("📖", "Read 30 min", habitColors[1], true),
        ("💧", "Drink Water", habitColors[2], true),
        ("🧘", "Meditate", habitColors[3], false),
        ("✍️", "Journal", habitColors[4], false),
    ]

    for (emoji, name, color, done) in habits {
        let cardH: CGFloat = 110
        let cardRect = NSRect(x: margin, y: y - cardH, width: w, height: cardH)
        drawRoundedRect(cardRect, radius: 20, fill: bgCard, shadow: true)

        // Color accent left bar
        drawRoundedRect(NSRect(x: cardRect.minX + 16, y: cardRect.minY + 20, width: 6, height: cardH - 40), radius: 3, fill: color)

        // Emoji
        drawText(emoji, at: NSPoint(x: margin + 36, y: cardRect.minY + 28), size: 48, weight: .regular, color: textPrimary)

        // Name
        drawText(name, at: NSPoint(x: margin + 100, y: cardRect.minY + 36), size: 34, weight: .semibold, color: textPrimary)

        // Checkmark
        if done {
            drawCircle(at: NSPoint(x: cardRect.maxX - 50, y: cardRect.midY), radius: 24, color: color)
            drawText("✓", at: NSPoint(x: cardRect.maxX - 64, y: cardRect.midY - 18), size: 32, weight: .bold, color: .white)
        } else {
            // Empty circle
            let circPath = NSBezierPath(ovalIn: NSRect(x: cardRect.maxX - 74, y: cardRect.midY - 24, width: 48, height: 48))
            circPath.lineWidth = 3
            textTertiary.setStroke()
            circPath.stroke()
        }

        y -= cardH + 16
    }

    finishCanvas(rep)
    return rep
}

// MARK: - Screenshot 2: Stats View

func drawStatsView() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("See Your Progress", "Detailed insights into every habit")

    let margin: CGFloat = 80
    let w = screenWidth - margin * 2
    var y = screenHeight - 420

    // Overall stats cards
    let stats: [(String, String, String)] = [
        ("🔥", "Current Streak", "14 days"),
        ("🏆", "Best Streak", "21 days"),
        ("📊", "30-Day Rate", "87%"),
    ]

    let cardW = (w - 40) / 3
    for (i, stat) in stats.enumerated() {
        let cx = margin + CGFloat(i) * (cardW + 20)
        let cardRect = NSRect(x: cx, y: y - 180, width: cardW, height: 180)
        drawRoundedRect(cardRect, radius: 20, fill: bgCard, shadow: true)
        drawText(stat.0, at: NSPoint(x: cx + cardW / 2 - 24, y: cardRect.maxY - 60), size: 44, weight: .regular, color: textPrimary)
        drawText(stat.2, at: NSPoint(x: cx + 10, y: cardRect.minY + 60), size: 30, weight: .bold, color: textPrimary, maxWidth: cardW - 20, centered: true)
        drawText(stat.1, at: NSPoint(x: cx + 10, y: cardRect.minY + 24), size: 20, weight: .medium, color: textSecondary, maxWidth: cardW - 20, centered: true)
    }
    y -= 230

    // Weekly bar chart
    drawRoundedRect(NSRect(x: margin, y: y - 400, width: w, height: 400), radius: 24, fill: bgCard, shadow: true)
    drawText("This Week", at: NSPoint(x: margin + 24, y: y - 50), size: 32, weight: .bold, color: textPrimary)

    let barDays = ["M", "T", "W", "T", "F", "S", "S"]
    let barValues: [CGFloat] = [0.8, 1.0, 0.6, 0.8, 1.0, 0.4, 0.0]
    let barW: CGFloat = (w - 120) / 7
    let maxBarH: CGFloat = 220

    for (i, day) in barDays.enumerated() {
        let bx = margin + 48 + CGFloat(i) * barW + barW / 2 - 20
        let by = y - 360
        let bh = max(8, barValues[i] * maxBarH)

        // Bar background
        drawRoundedRect(NSRect(x: bx, y: by, width: 40, height: maxBarH), radius: 8, fill: accentGreenLight)
        // Bar value
        drawRoundedRect(NSRect(x: bx, y: by, width: 40, height: bh), radius: 8, fill: accentGreen)
        // Day label
        drawText(day, at: NSPoint(x: bx + 8, y: by - 36), size: 26, weight: .medium, color: textSecondary)
    }
    y -= 440

    // 12-week heatmap
    drawRoundedRect(NSRect(x: margin, y: y - 320, width: w, height: 320), radius: 24, fill: bgCard, shadow: true)
    drawText("Activity Heatmap", at: NSPoint(x: margin + 24, y: y - 50), size: 32, weight: .bold, color: textPrimary)

    let cellSize: CGFloat = 28
    let cellGap: CGFloat = 6
    let heatmapX = margin + 40
    let heatmapY = y - 280

    // Seed for pseudo-random but deterministic pattern
    let pattern: [CGFloat] = [0.9, 0.7, 0.5, 1.0, 0.8, 0.0, 0.3, 0.6, 1.0, 0.9, 0.4, 0.8, 1.0, 0.7]

    for week in 0..<12 {
        for day in 0..<7 {
            let cx = heatmapX + CGFloat(week) * (cellSize + cellGap)
            let cy = heatmapY + CGFloat(day) * (cellSize + cellGap)
            let intensity = pattern[(week * 7 + day) % pattern.count]
            let color = intensity == 0 ? accentGreenLight : accentGreen.withAlphaComponent(0.3 + intensity * 0.7)
            drawRoundedRect(NSRect(x: cx, y: cy, width: cellSize, height: cellSize), radius: 6, fill: color)
        }
    }

    finishCanvas(rep)
    return rep
}

// MARK: - Screenshot 3: Widgets

func drawWidgets() -> NSBitmapImageRep {
    let rep = createCanvas()
    drawTitleBanner("Widgets & Reminders", "Stay on track right from your Home Screen")

    let margin: CGFloat = 80
    let w = screenWidth - margin * 2
    var y = screenHeight - 420

    // Simulated Home Screen with widgets
    // Large widget
    let widgetH: CGFloat = 380
    let widgetRect = NSRect(x: margin, y: y - widgetH, width: w, height: widgetH)
    drawRoundedRect(widgetRect, radius: 28, fill: bgCard, shadow: true)

    drawText("Today's Habits", at: NSPoint(x: margin + 24, y: widgetRect.maxY - 52), size: 28, weight: .bold, color: textPrimary)
    drawText("3 of 5 complete", at: NSPoint(x: margin + 24, y: widgetRect.maxY - 86), size: 22, weight: .medium, color: textSecondary)

    let widgetHabits: [(String, String, NSColor, Bool)] = [
        ("🏃", "Morning Run", habitColors[0], true),
        ("📖", "Read 30 min", habitColors[1], true),
        ("💧", "Drink Water", habitColors[2], true),
        ("🧘", "Meditate", habitColors[3], false),
        ("✍️", "Journal", habitColors[4], false),
    ]

    var wy = widgetRect.maxY - 130
    for (emoji, name, color, done) in widgetHabits {
        let rowH: CGFloat = 44
        drawText(emoji, at: NSPoint(x: margin + 28, y: wy - 6), size: 28, weight: .regular, color: textPrimary)
        drawText(name, at: NSPoint(x: margin + 70, y: wy - 4), size: 26, weight: .medium, color: done ? textSecondary : textPrimary)
        if done {
            drawCircle(at: NSPoint(x: widgetRect.maxX - 44, y: wy + 12), radius: 14, color: color)
            drawText("✓", at: NSPoint(x: widgetRect.maxX - 54, y: wy - 2), size: 20, weight: .bold, color: .white)
        } else {
            let c = NSBezierPath(ovalIn: NSRect(x: widgetRect.maxX - 58, y: wy - 2, width: 28, height: 28))
            c.lineWidth = 2
            textTertiary.setStroke()
            c.stroke()
        }
        wy -= rowH
    }

    y -= widgetH + 30

    // Two small widgets side by side
    let smallW = (w - 20) / 2
    let smallH: CGFloat = 200

    // Streak widget
    let streakRect = NSRect(x: margin, y: y - smallH, width: smallW, height: smallH)
    drawRoundedRect(streakRect, radius: 24, fill: bgCard, shadow: true)
    drawText("🔥", at: NSPoint(x: margin + smallW / 2 - 28, y: streakRect.maxY - 80), size: 56, weight: .regular, color: textPrimary)
    drawText("14", at: NSPoint(x: margin + smallW / 2 - 24, y: streakRect.minY + 60), size: 52, weight: .bold, color: textPrimary)
    drawText("day streak", at: NSPoint(x: margin + 10, y: streakRect.minY + 24), size: 24, weight: .medium, color: textSecondary, maxWidth: smallW - 20, centered: true)

    // Completion widget
    let compRect = NSRect(x: margin + smallW + 20, y: y - smallH, width: smallW, height: smallH)
    drawRoundedRect(compRect, radius: 24, fill: bgCard, shadow: true)
    drawText("📊", at: NSPoint(x: compRect.minX + smallW / 2 - 28, y: compRect.maxY - 80), size: 56, weight: .regular, color: textPrimary)
    drawText("87%", at: NSPoint(x: compRect.minX + smallW / 2 - 42, y: compRect.minY + 60), size: 52, weight: .bold, color: accentGreen)
    drawText("this month", at: NSPoint(x: compRect.minX + 10, y: compRect.minY + 24), size: 24, weight: .medium, color: textSecondary, maxWidth: smallW - 20, centered: true)

    y -= smallH + 50

    // Lock Screen widget preview label
    drawText("Lock Screen • Home Screen • StandBy", at: NSPoint(x: 0, y: y), size: 30, weight: .semibold, color: textSecondary, maxWidth: screenWidth, centered: true)
    y -= 50
    drawText("Widgets keep your habits visible — no need to open the app.", at: NSPoint(x: margin, y: y), size: 28, weight: .regular, color: textTertiary, maxWidth: w, centered: false)

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

print("Generating Stride iOS screenshots (1290x2796)...")
print("")

savePNG(drawTodayView(), to: outDir + "/01_today_6.7.png")
savePNG(drawStatsView(), to: outDir + "/02_stats_6.7.png")
savePNG(drawWidgets(), to: outDir + "/03_widgets_6.7.png")

print("")
print("Done! Screenshots saved to: \(outDir)")
