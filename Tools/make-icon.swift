// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the project root:  swift Tools/make-icon.swift
//
// Design: a white prompter screen on an indigo tile. The first lines of
// "text" are black (already spoken) and the rest gray (still ahead), like
// the app itself, with a small red listening dot.
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024  // design on a 1024 grid, scale to the target size

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Tile: Apple's macOS icon grid puts an 824pt rounded square in a 1024 canvas.
    let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.36, blue: 0.85, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.40, alpha: 1))!
        .draw(in: tile, angle: -90)

    // Prompter screen.
    let screen = NSBezierPath(roundedRect: rect(196, 300, 632, 440), xRadius: 44 * s, yRadius: 44 * s)
    NSColor.white.setFill()
    screen.fill()

    // Lines of "text": (y, [(width, isSpoken)]) — centered, like the app.
    let black = NSColor(white: 0.08, alpha: 1)
    let gray = NSColor(white: 0.78, alpha: 1)
    let rows: [(CGFloat, [(CGFloat, Bool)])] = [
        (620, [(150, true), (110, true), (170, true)]),
        (530, [(120, true), (140, false), (160, false)]),
        (440, [(180, false), (100, false), (130, false)]),
        (350, [(140, false), (170, false)]),
    ]
    let barHeight: CGFloat = 46, gap: CGFloat = 26
    for (y, words) in rows {
        let total = words.reduce(0) { $0 + $1.0 } + gap * CGFloat(words.count - 1)
        var x = 512 - total / 2
        for (w, spoken) in words {
            (spoken ? black : gray).setFill()
            NSBezierPath(roundedRect: rect(x, y, w, barHeight), xRadius: barHeight / 2 * s, yRadius: barHeight / 2 * s).fill()
            x += w + gap
        }
    }

    // Listening dot.
    NSColor(srgbRed: 0.93, green: 0.26, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect(770, 682, 30, 30)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))

try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
