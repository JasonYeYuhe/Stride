// A blank-frame check for the PNGs scripts/a11y_sweep.sh, scripts/screenshots.sh and
// scripts/mac_variant/capture.sh produce (RELEASE-1.4.2.md W8: "a blank-frame check on every PNG").
// Compiled by those scripts with `xcrun swiftc -O`, never part of a build.
//
//   frame_check [--full-width] <png>...
//       one line per file: "ok|BLANK <ink>% <colours> <file>"; exit 1 if any is blank, 2 if any
//       cannot be read.
//
// Why: under load a simulator capture can come back as the window with nothing drawn in it — the
// status bar, maybe a large title and the tab bar, over an empty page (RELEASE-1.4.1.md: three
// iPhone Statistics frames for the 1.4.1 store set). Such a frame is not uniform, so the check looks
// only at the BAND between the bars, 16 % to 88 % of the height from the top, where every captured
// screen draws its content, and asks how much of it differs from its own dominant colour ("ink").
//
// Regular width (an image at least 0.6 as wide as it is tall: the iPad, a Mac window) samples only
// the DETAIL column, from 34 % of the width to the right edge: an iPad's sidebar (about 32 % in
// portrait) or a Mac window's has text of its own, and must not hide an empty detail pane. A sheet
// over the page is centred, so most of it is in that column. `--full-width` samples the whole width
// (capture.sh's sheet-alone captures, which have no sidebar).
//
// Sampling: the image is drawn at 320 px wide (its height in proportion) with high-quality
// interpolation, so a pixel is an area average and thin text still counts as ink.
//
// Thresholds, measured 2026-11-14 (W8 review), in the band:
//   - real frames: the sparsest, the paywall's `unlocked` and `restored` fixtures, 6.9 % and 7.2 %;
//     1.4.1's Mac store frames 3.4 %; everything else 9–55 %;
//   - blank: the two frames 1.4.1's iPhone sweep kept (the status bar over white) 0.00 %; synthetic
//     ones made from real captures, "status bar, large title and tab bar over an empty page" 0.02 %
//     and an iPad "sidebar beside an empty detail pane" 0.06 %. (The first version of this check
//     measured 12–84 % and the whole width, and passed those two at 0.74 % and 5.3 %.)
// Blank: ink under STRIDE_FRAME_MIN_INK percent (default 0.3), or at most 2 colours in the sampled
// area, or the whole image at least 90 % transparent (a window capture with nothing in it).
import CoreGraphics
import Foundation
import ImageIO

let minInk = Double(ProcessInfo.processInfo.environment["STRIDE_FRAME_MIN_INK"] ?? "") ?? 0.3
var fullWidth = false
var blank = 0, unreadable = 0

for path in CommandLine.arguments.dropFirst() {
    if path == "--full-width" { fullWidth = true; continue }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
        print("UNREADABLE \(path)")
        unreadable += 1
        continue
    }
    let width = 320
    let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .high
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
    // A bitmap context's memory starts with the image's TOP row (drawing flips into it), so rows
    // are counted from the top: 16 %–88 %.
    let first = Int(Double(height) * 0.16), last = max(first + 1, Int(Double(height) * 0.88))
    let regular = !fullWidth && Double(image.width) >= 0.6 * Double(image.height)
    let left = regular ? Int(Double(width) * 0.34) : 0
    var colours: [UInt32: Int] = [:]
    for row in first..<last {
        for column in left..<width {
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
