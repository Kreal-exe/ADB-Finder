// Renders AppIcon.png (1024×1024): swift tools/make-icon.swift AppIcon.png
//
// The Finder face, redrawn in dark green, with Android antennae on top.
// Geometry follows the macOS Finder icon on the standard 824 pt icon grid.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
// Coordinates below are measured top-down, like in an image editor.
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: size - y) }

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

let greenTop = rgb(0x27B062), greenBottom = rgb(0x0B5A30)    // Finder's blue half
let paleTop = rgb(0xF1F5F2), paleBottom = rgb(0xD3DED7)      // Finder's white half
let ink = rgb(0x14271C)

// Antennae, under the tile so their roots are hidden.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor(white: 0, alpha: 0.30).cgColor)
for (root, tip, color) in [(pt(330, 160), pt(262, 26), greenTop), (pt(694, 160), pt(762, 26), paleTop)] {
    let a = NSBezierPath()
    a.lineWidth = 30
    a.lineCapStyle = .round
    a.move(to: root)
    a.line(to: tip)
    color.setStroke()
    a.stroke()
}
ctx.restoreGState()

// Tile shadow, as on the system icon.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(white: 0, alpha: 0.30).cgColor)
greenBottom.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

// Left half.
NSGradient(colors: [greenTop, greenBottom])!.draw(in: tile, angle: -90)

// Right half: the profile, with Finder's squared-off nose.
let face = NSBezierPath()
face.move(to: pt(553, 80))
face.curve(to: pt(452, 505), controlPoint1: pt(528, 250), controlPoint2: pt(452, 390))
face.line(to: pt(451, 556))
face.curve(to: pt(474, 581), controlPoint1: pt(451, 572), controlPoint2: pt(458, 581))
face.line(to: pt(552, 581))
face.curve(to: pt(572, 603), controlPoint1: pt(566, 581), controlPoint2: pt(572, 589))
face.curve(to: pt(624, 944), controlPoint1: pt(574, 720), controlPoint2: pt(600, 860))
face.line(to: pt(944, 944))
face.line(to: pt(944, 80))
face.close()
ctx.saveGState()
face.addClip()
NSGradient(colors: [paleTop, paleBottom])!.draw(in: tile, angle: -90)
ctx.restoreGState()

// Eyes: dark capsules on both halves.
for x in [CGFloat(318), CGFloat(706)] {
    let eye = NSBezierPath(roundedRect: NSRect(x: x - 17, y: size - 420, width: 34, height: 88), xRadius: 17, yRadius: 17)
    ink.setFill()
    eye.fill()
}

// Smile across both halves.
let smile = NSBezierPath()
smile.lineWidth = 26
smile.lineCapStyle = .round
smile.move(to: pt(270, 655))
smile.curve(to: pt(752, 652), controlPoint1: pt(380, 792), controlPoint2: pt(640, 792))
ink.setStroke()
smile.stroke()

ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
