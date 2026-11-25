// Puts a UI capture (shot-*.png, without the native frame) inside a macOS window:
// rounded corners, thin border, shadow and the three buttons (close, minimize, zoom).
//
//   swift scripts/frame-screenshot.swift input.png output.png
//
// The captures come from `make screenshots` (the app's JT_SHOTS mode in DEBUG).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift scripts/frame-screenshot.swift input.png output.png"); exit(1)
}
let w = CGFloat(cg.width), h = CGFloat(cg.height)
let scale: CGFloat = 2                   // captures are taken at 2x
let pad = 44 * scale
let radius = 12 * scale
let size = CGSize(width: w + pad * 2, height: h + pad * 2)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let frame = CGRect(x: pad, y: pad, width: w, height: h)
let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Window shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.55))
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 0.04, green: 0.05, blue: 0.055, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Content.
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(cg, in: frame)

// Window buttons, centered in the tab bar (38 pt), like in the app.
let colors: [(CGFloat, CGFloat, CGFloat)] = [(1.0, 0.373, 0.341), (0.996, 0.737, 0.18), (0.157, 0.784, 0.251)]
for (i, c) in colors.enumerated() {
    let cx = frame.minX + (20 + CGFloat(i) * 20) * scale
    let cy = frame.maxY - 19 * scale
    let r = 6 * scale
    ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
    ctx.setLineWidth(0.5 * scale)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}
ctx.restoreGState()

// Thin glass border.
ctx.addPath(path)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
ctx.setLineWidth(1 * scale)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("ok: \(args[2])")
