// Renders the Clipd app icon at every size macOS wants.
//
// Drawn in code rather than shipped as a binary asset so the shape can be
// tweaked and re-rendered, and so the repository carries no opaque blob whose
// source nobody has.
//
// The silhouette is deliberately simple: a clipboard with three lines. Anything
// more detailed turns to mush at 16 points, which is where it is seen most.

import AppKit
import CoreGraphics

let outputDirectory = CommandLine.arguments[1]

/// Apple's icon grid: the shape occupies about 82% of the canvas, leaving the
/// margin the system expects for shadows and alignment with other icons.
let contentRatio: CGFloat = 0.82

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let scale = s / 1024  // design at 1024 and scale, so proportions never drift

    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // ---- the rounded square
    let inset = s * (1 - contentRatio) / 2
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    // 22.37% is Apple's corner radius ratio for the squircle. A plain rounded
    // rect is not the true superellipse, but at these sizes the difference is
    // invisible and it avoids shipping a bezier nobody can edit.
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner,
                          cornerHeight: corner, transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    // Indigo to violet, top to bottom. Picked to match the blue accent the
    // selected card and Link cards already use, rather than inventing a third
    // colour for the app to be known by.
    let colours = [
        CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1),
        CGColor(red: 0.55, green: 0.30, blue: 0.90, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colours, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    // A soft highlight across the top, which is what stops a flat gradient
    // looking like a placeholder.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 1, alpha: 0.18),
                                    CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.midY),
                               options: [])
    context.restoreGState()

    // ---- the clipboard
    let boardWidth = 470 * scale
    let boardHeight = 590 * scale
    let board = CGRect(x: (s - boardWidth) / 2, y: (s - boardHeight) / 2 - 18 * scale,
                       width: boardWidth, height: boardHeight)
    let boardRadius = 58 * scale

    // A drop shadow so the white board separates from the gradient rather than
    // floating on it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale),
                      blur: 34 * scale, color: CGColor(gray: 0, alpha: 0.28))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: board, cornerWidth: boardRadius,
                           cornerHeight: boardRadius, transform: nil))
    context.fillPath()
    context.restoreGState()

    // ---- the clip at the top
    let clipWidth = 210 * scale
    let clipHeight = 118 * scale
    let clip = CGRect(x: (s - clipWidth) / 2, y: board.maxY - clipHeight * 0.52,
                      width: clipWidth, height: clipHeight)
    context.setFillColor(CGColor(red: 0.30, green: 0.34, blue: 0.80, alpha: 1))
    context.addPath(CGPath(roundedRect: clip, cornerWidth: 34 * scale,
                           cornerHeight: 34 * scale, transform: nil))
    context.fillPath()

    // ---- three lines, standing for the copied text
    //
    // Dropped entirely below 32 points. At 16 the lines merge into a grey smear
    // and the icon reads better as a clean silhouette.
    if size >= 32 {
        let lineHeight = 46 * scale
        let lineInset = 78 * scale
        let widths: [CGFloat] = [1.0, 1.0, 0.62]
        var y = board.maxY - 210 * scale
        context.setFillColor(CGColor(red: 0.62, green: 0.66, blue: 0.78, alpha: 1))
        for factor in widths {
            let width = (board.width - lineInset * 2) * factor
            let line = CGRect(x: board.minX + lineInset, y: y,
                              width: width, height: lineHeight)
            context.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2,
                                   cornerHeight: lineHeight / 2, transform: nil))
            context.fillPath()
            y -= lineHeight * 2.15
        }
    }

    guard let image = context.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("no png")
    }
    return png
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(size: size)
    let url = URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent("icon_\(size).png")
    try! data.write(to: url)
    print("  icon_\(size).png  \(data.count) bytes")
}
