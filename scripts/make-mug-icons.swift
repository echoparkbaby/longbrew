#!/usr/bin/env swift
//
// Generates the menu-bar mug artwork. Run when the art changes:
//
//     swift scripts/make-mug-icons.swift
//
// Writes 36×36 template PNGs to Sources/longbrew/Resources/MenuBar/. 36px is
// exactly 18pt at 2×, so the shipped icon is pixel-perfect on a Retina bar and
// downscales cleanly on anything else. This script IS the source of the art —
// the PNGs are build output that happens to be committed.
//
import AppKit

let side = 36                    // px, = 18pt @2×
let S = CGFloat(side)
let stroke: CGFloat = 2.6

// The mug sits in the same place in every state, so toggling doesn't make the
// menu bar jump. Steam grows into the reserved band above it.
let body   = NSRect(x: 3, y: 4.5, width: 22.5, height: 23)
let liquid = NSRect(x: 6.2, y: 7.7, width: 16.1, height: 15)
let handleCenter = NSPoint(x: body.maxX, y: body.midY)
let handleRadius: CGFloat = 7

/// Lightning bolt, in a 0…1 box, y up. Knocked out of the liquid so it reads at 18pt.
let boltPoints: [(CGFloat, CGFloat)] = [
    (0.58, 1.00), (0.00, 0.42), (0.40, 0.42),
    (0.42, 0.00), (1.00, 0.56), (0.60, 0.56),
]
let boltBox = NSRect(x: 10.6, y: 9.0, width: 8.0, height: 12.6)

func path(_ points: [(CGFloat, CGFloat)], in box: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    for (i, pt) in points.enumerated() {
        let point = NSPoint(x: box.minX + pt.0 * box.width,
                            y: box.minY + pt.1 * box.height)
        i == 0 ? p.move(to: point) : p.line(to: point)
    }
    p.close()
    return p
}

func render(steam: Bool, charge: Bool) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.setShouldAntialias(true)
    NSColor.black.set()

    // Handle first: it tucks behind the body outline, which hides the join.
    let handle = NSBezierPath()
    handle.appendArc(withCenter: handleCenter, radius: handleRadius,
                     startAngle: -66, endAngle: 66)
    handle.lineWidth = stroke
    handle.lineCapStyle = .round
    handle.stroke()

    let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
    outline.lineWidth = stroke
    outline.stroke()

    if steam || charge {
        NSBezierPath(roundedRect: liquid, xRadius: 1.4, yRadius: 1.4).fill()
    }
    if charge {
        // Cut the bolt out rather than drawing it on top: at 18pt a filled bolt on
        // a filled mug is a smudge, negative space is a bolt.
        ctx.setBlendMode(.clear)
        path(boltPoints, in: boltBox).fill()
        ctx.setBlendMode(.normal)
        NSColor.black.set()
    }
    if steam || charge {
        // Three wisps, the middle one taller. Even heights read as a comb, not steam.
        // Short on purpose: every point of steam is a point the mug doesn't get,
        // and the mug is the subject.
        for (x, top) in [(CGFloat(7.6), CGFloat(34.0)), (14.2, 35.6), (20.8, 34.0)] {
            let wisp = NSBezierPath()
            wisp.move(to: NSPoint(x: x, y: 29.3))
            wisp.curve(to: NSPoint(x: x, y: top),
                       controlPoint1: NSPoint(x: x - 2.5, y: 30.9),
                       controlPoint2: NSPoint(x: x + 2.5, y: 32.7))
            wisp.lineWidth = 2.0
            wisp.lineCapStyle = .round
            wisp.stroke()
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/longbrew/Resources/MenuBar")
for (name, steam, charge) in [("mug-empty", false, false),
                              ("mug-steam", true, false),
                              ("mug-charge", true, true)] {
    let url = dir.appendingPathComponent("\(name)-template-\(side).png")
    try render(steam: steam, charge: charge).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
