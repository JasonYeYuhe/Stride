// A blank-frame check for the PNGs scripts/a11y_sweep.sh and scripts/screenshots.sh produce
// (RELEASE-1.4.2.md W8: "a blank-frame check on every PNG"). Compiled by those scripts with
// `xcrun swiftc -O`, never run from a build.
//
//   frame_check <png>...      one line per file: "ok|BLANK <ink>% <colours> <file>"; exit 1 if any
//                             is blank, 2 if any cannot be read.
//
// Why: under load a simulator capture can come back as the window with no content drawn — the
// status bar, a title and the tab bar over an empty page (RELEASE-1.4.1.md: three iPhone
// Statistics frames for the 1.4.1 store set). Such a frame is not uniform (the bars have text),
// so the check looks only at the BAND between them, 16 % to 88 % of the height, where every
// captured screen draws its content, and asks how much of it differs from its own dominant colour
// ("ink"). A real screen has cards, rows or text there. Measured 2026-11-14: the sparsest real
// frames, the paywall's `unlocked` and `restored` fixtures, 6.7 %; 1.4.1's store frames and free
// sweep 12–70 %; the two blank frames 1.4.1's iPhone sweep kept (02_stats_trend, 04_paywall: the
// status bar over white) 0.00 %, one colour. Blank: ink under STRIDE_FRAME_MIN_INK percent (default
// 0.3), or at most 2 colours in the band, or the whole image ≥ 90 % transparent (a window capture
// with nothing in it).
import CoreGraphics
import Foundation
import ImageIO

let minInk = Double(ProcessInfo.processInfo.environment["STRIDE_FRAME_MIN_INK"] ?? "") ?? 0.3
var blank = 0, unreadable = 0

for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
        print("UNREADABLE \(path)")
        unreadable += 1
        continue
    }
    // Sampled at a fixed width, the height in proportion, so every device reads alike.
    let width = 320
    let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else {
        print("UNREADABLE \(path)")
        unreadable += 1
        continue
    }
    var transparent = 0
    for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 8 { transparent += 1 }
    // Row 0 of the bitmap context is the image's BOTTOM row (CoreGraphics' origin): the band
    // 16 %–88 % from the top is rows 12 %–84 % from the bottom.
    let first = Int(Double(height) * 0.12), last = Int(Double(height) * 0.84)
    var colours: [UInt32: Int] = [:]
    for row in first..<max(first + 1, last) {
        for column in 0..<width {
            let i = (row * width + column) * 4
            // 5 bits a channel: anti-aliased edges and gradients count as ink, compression noise does not.
            let key = UInt32(pixels[i] >> 3) << 10 | UInt32(pixels[i + 1] >> 3) << 5 | UInt32(pixels[i + 2] >> 3)
            colours[key, default: 0] += 1
        }
    }
    let band = colours.values.reduce(0, +)
    let ink = band > 0 ? 100 * Double(band - (colours.values.max() ?? 0)) / Double(band) : 0
    let isBlank = transparent * 100 / (width * height) >= 90 || colours.count <= 2 || ink < minInk
    if isBlank { blank += 1 }
    print(String(format: "%@ %6.2f%% %5d %@", isBlank ? "BLANK" : "ok   ", ink, colours.count, path))
}
exit(unreadable > 0 ? 2 : blank > 0 ? 1 : 0)
