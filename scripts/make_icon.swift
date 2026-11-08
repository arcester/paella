// Draws the Paella app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make_icon.swift
import AppKit

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
var seed: UInt64 = 42 // deterministic "random" so the icon is reproducible
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

// Enamelled steel: scattered white specks inside the current clip.
func speckles(_ rect: CGRect, count: Int, size: CGFloat = 1) {
    for _ in 0..<count {
        let p = CGPoint(x: rect.minX + rnd() * rect.width, y: rect.minY + rnd() * rect.height)
        ctx.setFillColor(rgb(0xFFFFFF, 0.12 + rnd() * 0.18))
        ctx.fillEllipse(in: circle(p, (1.5 + rnd() * 2.5) * size))
    }
}

// Background: macOS-grid squircle (824 pt inside 1024), flat blue, soft shadow.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tile); ctx.setFillColor(rgb(0x2D6BD3)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tile); ctx.clip()

let center = CGPoint(x: 512, y: 535)
let panR: CGFloat = 310, riceR: CGFloat = 272
let tilt: CGFloat = 0.42 // vertical squash: pan seen almost edge-on, tipped slightly toward the viewer
let depth: CGFloat = 62  // visible height of the pan's side wall

// Steam: three wavy wisps rising from the pan (it's an app about heat).
ctx.setLineCap(.round); ctx.setLineWidth(22); ctx.setStrokeColor(rgb(0xFFFFFF, 0.8))
for dx in [-100.0, 0, 100] as [CGFloat] {
    let p = CGMutablePath(); let x = 512 + dx
    let y0 = center.y - 165 // just above the rim
    p.move(to: CGPoint(x: x, y: y0))
    p.addCurve(to: CGPoint(x: x, y: y0 - 100), control1: CGPoint(x: x + 36, y: y0 - 33), control2: CGPoint(x: x - 36, y: y0 - 67))
    ctx.addPath(p); ctx.strokePath()
}

// Shadow on the table, then the pan's sloped side wall (a paellera flares out toward the rim).
let baseR = panR * 0.82
ctx.setFillColor(rgb(0x0B2A66, 0.45))
ctx.fillEllipse(in: CGRect(x: center.x - baseR * 1.15, y: center.y + depth - baseR * tilt * 0.7, width: baseR * 2.3, height: baseR * tilt * 2 * 0.85))
let wall = CGMutablePath()
wall.move(to: CGPoint(x: center.x - panR, y: center.y))
for k in 0...60 { // front half of the base ellipse, left to right
    let t = CGFloat.pi - CGFloat(k) / 60 * .pi
    wall.addLine(to: CGPoint(x: center.x + cos(t) * baseR, y: center.y + depth + sin(t) * baseR * tilt))
}
wall.addLine(to: CGPoint(x: center.x + panR, y: center.y))
wall.closeSubpath()
ctx.saveGState(); ctx.addPath(wall); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x151515), rgb(0x4A4A4A), rgb(0x151515)]), start: CGPoint(x: center.x - panR, y: 0),
                       end: CGPoint(x: center.x + panR, y: 0), options: [])
speckles(wall.boundingBox, count: 420, size: 0.55)
ctx.restoreGState()

// Everything on top of the pan is drawn flat and then squashed into perspective.
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: 1, y: tilt); ctx.translateBy(x: -center.x, y: -center.y)

// Handles and rim.
ctx.setStrokeColor(rgb(0x2B2B2B)); ctx.setLineWidth(30)
for side in [-1.0, 1.0] as [CGFloat] {
    ctx.strokeEllipse(in: CGRect(x: center.x + side * (panR + 26) - 46, y: center.y - 50, width: 92, height: 100))
}
ctx.saveGState(); ctx.addEllipse(in: circle(center, panR)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x1E1E1E), rgb(0x5A5A5A)]), start: CGPoint(x: center.x, y: center.y - panR),
                       end: CGPoint(x: center.x, y: center.y + panR), options: [])
speckles(circle(center, panR), count: 700, size: 0.7)
ctx.restoreGState()

// Rice: saffron, darker toward the edge (socarrat), with grain texture.
ctx.saveGState(); ctx.addEllipse(in: circle(center, riceR)); ctx.clip()
ctx.drawRadialGradient(gradient([rgb(0xFFD84A), rgb(0xF2B321), rgb(0xC8761A)]), startCenter: center, startRadius: 0,
                       endCenter: center, endRadius: riceR, options: [])
for _ in 0..<420 {
    let a = rnd() * 2 * .pi, r = sqrt(rnd()) * riceR
    let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: rnd() * .pi)
    ctx.setFillColor(rgb(0xFFF1B0, 0.55)); ctx.fillEllipse(in: CGRect(x: -9, y: -4, width: 18, height: 8))
    ctx.restoreGState()
}

// Red pepper strips laid radially.
ctx.setLineCap(.round); ctx.setLineWidth(24); ctx.setStrokeColor(rgb(0xD1261C))
for i in 0..<6 {
    let a = CGFloat(i) / 6 * 2 * .pi + 0.3
    ctx.move(to: CGPoint(x: center.x + cos(a) * 70, y: center.y + sin(a) * 70))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * 200, y: center.y + sin(a) * 200))
    ctx.strokePath()
}

// Peas.
ctx.setFillColor(rgb(0x4E9E2E))
for _ in 0..<26 {
    let a = rnd() * 2 * .pi, r = 40 + rnd() * 190
    ctx.fillEllipse(in: circle(CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r), 11))
}

// Shrimp: curled orange arcs with segment lines, between the peppers.
for i in 0..<3 {
    let a = CGFloat(i) / 3 * 2 * .pi + 1.0
    let c = CGPoint(x: center.x + cos(a) * 150, y: center.y + sin(a) * 150)
    ctx.setLineWidth(40); ctx.setStrokeColor(rgb(0xF4693A))
    ctx.addArc(center: c, radius: 42, startAngle: a + 0.4, endAngle: a + 0.4 + 4.2, clockwise: false); ctx.strokePath()
    ctx.setLineWidth(5); ctx.setStrokeColor(rgb(0xFFB08A))
    for k in 1..<5 {
        let t = a + 0.4 + CGFloat(k) * 0.85
        ctx.move(to: CGPoint(x: c.x + cos(t) * 24, y: c.y + sin(t) * 24))
        ctx.addLine(to: CGPoint(x: c.x + cos(t) * 60, y: c.y + sin(t) * 60)); ctx.strokePath()
    }
}

ctx.restoreGState()

// Lemon wedge on the rim.
let lemon = CGPoint(x: center.x + 170, y: center.y + 150)
ctx.setFillColor(rgb(0xFFE74D)); ctx.addArc(center: lemon, radius: 62, startAngle: .pi * 0.15, endAngle: .pi * 1.15, clockwise: false)
ctx.closePath(); ctx.fillPath()
ctx.setStrokeColor(rgb(0xF4F0C0)); ctx.setLineWidth(9)
ctx.addArc(center: lemon, radius: 58, startAngle: .pi * 0.15, endAngle: .pi * 1.15, clockwise: false); ctx.strokePath()
ctx.restoreGState() // squash

// Rolled lip: drawn unsquashed so it keeps an even thickness all round.
let lip = CGRect(x: center.x - panR, y: center.y - panR * tilt, width: panR * 2, height: panR * tilt * 2)
ctx.setStrokeColor(rgb(0x262626)); ctx.setLineWidth(16); ctx.strokeEllipse(in: lip)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(4); ctx.strokeEllipse(in: lip.offsetBy(dx: 0, dy: -3))
ctx.restoreGState() // tile clip

// Write PNGs at every iconset size and pack them with iconutil.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset); try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let full = ctx.makeImage()!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
// Same PNGs as an Xcode asset catalog (the Xcode target uses it instead of the .icns).
let appiconset = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
try? fm.removeItem(at: appiconset); try! fm.createDirectory(at: appiconset, withIntermediateDirectories: true)
var images: [String] = []
for name in try! fm.contentsOfDirectory(atPath: iconset.path).sorted() {
    try! fm.copyItem(at: iconset.appendingPathComponent(name), to: appiconset.appendingPathComponent(name))
    let base = name.dropFirst(5).prefix { $0 != "x" }
    images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(name.contains("@2x") ? "2x" : "1x")","size":"\#(base)x\#(base)"}"#)
}
try! #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#
    .write(toFile: "Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

try! NSBitmapImageRep(cgImage: full).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
print("Wrote Resources/AppIcon.icns")
