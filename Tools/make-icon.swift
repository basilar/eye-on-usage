// Draws the app icon's three variants into EonUsage/Assets.xcassets/AppIcon.appiconset.
//
//   swift Tools/make-icon.swift
//
// The icon is a redrawing of the E.ON mark — an eye with a lightning bolt cut through the
// crescent above it — squared off to fill the tile rather than sitting as a circle inside
// it, which reads better once iOS has masked it. The geometry lives here rather than in a
// pile of exported PNGs so it can actually be adjusted: every proportion below is taken
// off the reference and expressed in a 1024 grid.
//
// Checked down to 60 px, where the bolt and pupil still separate.

import AppKit

// Geometry is written in a 1024 grid with a top-left origin, the way the reference reads.
let S: CGFloat = 1024

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255,
            green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: 1)
}

struct Scheme { let name: String; let background: NSColor; let mark: NSColor }

let schemes = [
    // The reference's vermillion, and its off-white rather than a clinical pure white.
    Scheme(name: "AppIcon-light",  background: rgb(0xF0300A), mark: rgb(0xFDFCF9)),
    // Deeper, so the tile sits back on a dark home screen instead of glaring off it.
    Scheme(name: "AppIcon-dark",   background: rgb(0xB82508), mark: rgb(0xF7F3EC)),
    // Tinted icons are mapped by luminance, so this one is pure greyscale.
    Scheme(name: "AppIcon-tinted", background: rgb(0x1A1A1A), mark: rgb(0xFFFFFF)),
]

// The eye, proportioned off the reference: width 0.78 of the tile, height 0.48 of its own
// width, sitting a little above centre so the crescent above it has room for the bolt.
let eyeCentre = CGPoint(x: 512, y: 556)
let halfWidth: CGFloat = 406
let apexRise: CGFloat = 196
let pupilRadius: CGFloat = 122

/// A lid, as a true circular arc through both tips and the apex — the shape a lens
/// actually is. Bezier control points were the first attempt and drew a kite.
func lid(rising: Bool) -> [CGPoint] {
    let radius = (halfWidth * halfWidth + apexRise * apexRise) / (2 * apexRise)
    let centre = CGPoint(x: eyeCentre.x,
                         y: rising ? eyeCentre.y + radius - apexRise
                                   : eyeCentre.y - radius + apexRise)
    // Angle from the arc's own centre out to a tip, measured off the horizontal. The
    // tips are mirrored in x, not in y, so the far tip is at pi minus this — negating
    // the angle mirrors the wrong way and sweeps the arc right off the tile.
    let base = atan2(radius - apexRise, halfWidth)
    let (start, end): (CGFloat, CGFloat) = rising ? (base - .pi, -base) : (base, .pi - base)
    let steps = 240
    return (0...steps).map { i in
        let t = start + (end - start) * CGFloat(i) / CGFloat(steps)
        return CGPoint(x: centre.x + radius * cos(t), y: centre.y + radius * sin(t))
    }
}

func eyePath() -> NSBezierPath {
    let path = NSBezierPath()
    let top = lid(rising: true), bottom = lid(rising: false)
    path.move(to: top[0])
    for p in top.dropFirst() { path.line(to: p) }
    for p in bottom { path.line(to: p) }
    path.close()
    return path
}

/// The bolt is a gap, not a glyph: a constant-width zigzag cut from the top edge down
/// into the eye, so the two whites join and a wedge of red is left stranded to its right.
func boltPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 604, y: -30))
    path.line(to: CGPoint(x: 502, y: 196))
    path.line(to: CGPoint(x: 622, y: 172))
    path.line(to: CGPoint(x: 522, y: 440))
    path.lineWidth = 70
    path.lineJoinStyle = .miter
    path.lineCapStyle = .butt
    path.miterLimit = 10
    return path
}

for scheme in schemes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("no bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.setAllowsAntialiasing(true)
    // Flip to a top-left origin so the numbers above read as they are drawn.
    ctx.cgContext.translateBy(x: 0, y: S)
    ctx.cgContext.scaleBy(x: 1, y: -1)

    scheme.background.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: S, height: S)).fill()

    scheme.mark.setFill()
    eyePath().fill()
    scheme.mark.setStroke()
    boltPath().stroke()

    scheme.background.setFill()
    NSBezierPath(ovalIn: CGRect(x: eyeCentre.x - pupilRadius, y: eyeCentre.y - pupilRadius,
                                width: pupilRadius * 2, height: pupilRadius * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    let out = "EonUsage/Assets.xcassets/AppIcon.appiconset/\(scheme.name).png"
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
