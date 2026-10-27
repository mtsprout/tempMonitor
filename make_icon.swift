// One-off tool that draws AppIcon.png (1024x1024): a larger, static version
// of the menu bar thermometer glyph — tube + bulb, green mercury fixed at a
// 67C reading — on a black rounded-square background. Not part of the app
// itself; run once (or whenever the icon design changes) via:
//
//   swift make_icon.swift
//
// then rebuild AppIcon.icns from the PNG (see README's "Package as an app
// bundle" section for the sips/iconutil steps).

import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Background: rounded square with a soft vertical gradient, subtle border.
let bgRect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: canvas * 0.22, yRadius: canvas * 0.22)
let gradient = NSGradient(colors: [
    NSColor(white: 0.12, alpha: 1.0),
    NSColor(white: 0.0, alpha: 1.0),
])
gradient?.draw(in: bgPath, angle: -90)
NSColor(white: 0.30, alpha: 1.0).setStroke()
bgPath.lineWidth = canvas * 0.006
bgPath.stroke()

// Thermometer geometry, scaled up from the same tube/bulb proportions the
// menu bar icon uses (bulbDiameter : tubeWidth ≈ 8 : 3.4). Sized and
// positioned to leave clear room below for the "67°" label so it doesn't
// collide with the bulb.
let bulbDiameter: CGFloat = canvas * 0.26
let tubeWidth: CGFloat = bulbDiameter * 0.425
let bulbCenterX = canvas / 2
let bulbCenterY = canvas * 0.40
let tubeBottom = bulbCenterY // tube visually merges into the bulb's center
let tubeTop = canvas * 0.88
let tubeHeight = tubeTop - tubeBottom
let tubeRect = NSRect(x: bulbCenterX - tubeWidth / 2, y: tubeBottom, width: tubeWidth, height: tubeHeight)
let bulbRect = NSRect(x: bulbCenterX - bulbDiameter / 2, y: bulbCenterY - bulbDiameter / 2, width: bulbDiameter, height: bulbDiameter)

let inkColor = NSColor(white: 0.85, alpha: 1.0)
let mercuryColor = NSColor.systemGreen

let tubePath = NSBezierPath(roundedRect: tubeRect, xRadius: tubeWidth / 2, yRadius: tubeWidth / 2)
inkColor.withAlphaComponent(0.7).setStroke()
tubePath.lineWidth = canvas * 0.006
tubePath.stroke()

// Fill to a fixed 67C reading, using the app's own chart scale (floor 30,
// ceiling tjMax+5 = 105) so the fill level matches what the real app would
// show at 67C — not an arbitrary fraction.
let chartFloor: CGFloat = 30
let chartCeiling: CGFloat = 105
let reading: CGFloat = 67
let fraction = min(max((reading - chartFloor) / (chartCeiling - chartFloor), 0), 1)
let fillHeight = tubeHeight * fraction
NSGraphicsContext.saveGraphicsState()
tubePath.addClip()
mercuryColor.setFill()
NSBezierPath(rect: NSRect(x: tubeRect.minX, y: tubeRect.minY, width: tubeRect.width, height: fillHeight)).fill()
NSGraphicsContext.restoreGraphicsState()

let bulbPath = NSBezierPath(ovalIn: bulbRect)
mercuryColor.setFill()
bulbPath.fill()
inkColor.withAlphaComponent(0.7).setStroke()
bulbPath.lineWidth = canvas * 0.006
bulbPath.stroke()

// "67°" beneath the thermometer, bold and green to match the mercury.
let text = "67°"
let font = NSFont.systemFont(ofSize: canvas * 0.15, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: mercuryColor]
let textSize = text.size(withAttributes: attributes)
let textOrigin = NSPoint(x: bulbCenterX - textSize.width / 2, y: canvas * 0.07)
text.draw(at: textOrigin, withAttributes: attributes)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render PNG")
}

let outputURL = URL(fileURLWithPath: "AppIcon.png")
try png.write(to: outputURL)
print("Wrote \(outputURL.path)")
