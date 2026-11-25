// Generates the Ronic JustTerminal logo: a white "R" on a black background, with green characters
// raining down behind it like terminal output. Same geometry as the Ronic family
// (rounded square, SF Pro Rounded Black, glass shine at the top).
//
//   swift branding/make-icons.swift [output-folder]
//
// Outputs: logo-<N>.png for N in 16…1024 (rounded square, transparent background).
// Use ./branding/make-icons.sh to also generate AppIcon.icns (macOS) and the .ico (Windows).
import AppKit
import CoreText
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "branding/out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Vector path of a letter (SF Pro Rounded Black, as in Ronic Mirror and MacToWindows).
func glyphPath(_ char: String, size: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("SFProRounded-Black" as CFString, size, nil)
    let fallback = NSFont.systemFont(ofSize: size, weight: .black) as CTFont
    let useFont = (CTFontCopyPostScriptName(font) as String).contains("Rounded") ? font : fallback
    var unichars = Array(char.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
    CTFontGetGlyphsForCharacters(useFont, &unichars, &glyphs, unichars.count)
    return CTFontCreatePathForGlyph(useFont, glyphs[0], nil)!
}

/// Deterministic pseudo-random generator: the logo comes out identical on every run.
struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }
}

let rainChars = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ0123456789$#<>_/=*+")

/// Draws a character centered at (x, y) using CoreText (with automatic font fallback).
func drawChar(_ ch: Character, ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, fill: CGColor) {
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: x - b.midX, y: y - b.midY)
    CTLineDraw(line, ctx)
}

func render(size px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let small = px <= 48   // menos colunas e caracteres maiores
    let tiny = px <= 24    // 16–24 px: just a green background glow, bigger R

    // ---- Fundo: quadrado arredondado preto ----
    let inset = s * 0.04
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()

    let base = CGGradient(colorsSpace: cs, colors: [color(0x0B120E), color(0x030504)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // ---- Green character rain ----
    if tiny {
        let glow = CGGradient(colorsSpace: cs, colors: [color(0x18E07A, 0.35), color(0x18E07A, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                               endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.55, options: [])
    } else {
        var rng = LCG(state: 0x5EED_2026)
        let columns = small ? 7 : 15
        let colW = rect.width / CGFloat(columns)
        let charSize = colW * 0.92
        let rowH = charSize * 1.08
        let rows = Int(rect.height / rowH) + 2
        for c in 0..<columns {
            let x = rect.minX + colW * (CGFloat(c) + 0.5)
            // Each column is a "drop": bright head and a trail that fades upward.
            let head = Int(rng.next() * Double(rows + 4))
            let tail = 4 + Int(rng.next() * Double(rows / 2 + 3))
            let depth = 0.45 + rng.next() * 0.55          // columns "further back" are dimmer
            for r in 0..<rows {
                let dist = head - r                        // rows above the head (r grows downward)
                guard dist >= 0, dist <= tail else { continue }
                let y = rect.maxY - rowH * (CGFloat(r) + 0.5)
                let ch = rainChars[Int(rng.next() * Double(rainChars.count)) % rainChars.count]
                if dist == 0 {
                    drawChar(ch, ctx: ctx, x: x, y: y, size: charSize, fill: color(0xD8FFE6, 0.95 * depth))
                } else {
                    let fade = 1 - CGFloat(dist) / CGFloat(tail + 1)
                    drawChar(ch, ctx: ctx, x: x, y: y, size: charSize, fill: color(0x19E27B, (0.15 + 0.75 * fade) * depth))
                }
            }
        }
    }

    // ---- Dark vignette in the center: the R stands out from the rain ----
    let vignette = CGGradient(colorsSpace: cs, colors: [color(0x000000, tiny ? 0.2 : 0.78), color(0x000000, 0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                           endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.42, options: [])

    // ---- The white R, with a soft green glow ----
    let glyph = glyphPath("R", size: s * (tiny ? 0.72 : 0.56))
    let gb = glyph.boundingBoxOfPath
    // At large sizes, the "R + cursor" pair is what gets centered.
    let shiftX = small ? 0 : s * 0.06
    var t = CGAffineTransform(translationX: s / 2 - gb.width / 2 - gb.minX - shiftX, y: (s - gb.height) / 2 - gb.minY)
    let letter = glyph.copy(using: &t)!
    let lb = letter.boundingBoxOfPath

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: color(0x19E27B, tiny ? 0.5 : 0.65))
    ctx.addPath(letter)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle vertical gradient on the letter (white → ice), for depth.
    ctx.saveGState()
    ctx.addPath(letter)
    ctx.clip()
    let metal = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xFFFFFF), color(0xDDE8E2)] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: lb.maxY), end: CGPoint(x: 0, y: lb.minY), options: [])
    ctx.restoreGState()

    // ---- Blinking terminal cursor next to the R (detail for large sizes only) ----
    if !small {
        let cw = s * 0.085, ch = s * 0.024
        let cursor = CGRect(x: lb.maxX + s * 0.035, y: lb.minY, width: cw, height: ch)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.025, color: color(0x19E27B, 0.9))
        ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil))
        ctx.setFillColor(color(0x3CF59A))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // ---- Glass shine at the top (same as the Ronic family) ----
    let shine = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: s * 0.3, y: s * 0.98), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.3, y: s * 0.98), endRadius: s * 0.7, options: [])

    ctx.restoreGState()

    // Thin glass border.
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 20, 24, 32, 40, 48, 64, 128, 180, 256, 512, 1024] {
    let url = outDir.appendingPathComponent("logo-\(size).png")
    try render(size: size).write(to: url)
}
print("Icons written to \(outDir.path)")
