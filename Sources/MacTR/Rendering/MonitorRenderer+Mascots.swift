// MonitorRenderer+Mascots.swift — Bongo Cat and the bitmap helper he shares
// with Pikachu's lightning in the CPU card.

import AppKit
import CoreGraphics
import Foundation

extension MonitorRenderer {

    // MARK: - Compact Bongo Cat

    func drawBongoCat(_ ctx: CGContext, cx: Int, baseY: Int,
                              tapping: Bool, phase: Bool, scale: CGFloat) {
        let dark = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)
        let pink = CGColor(red: 244/255, green: 150/255, blue: 174/255, alpha: 1)
        let keyboard = CGColor(red: 210/255, green: 216/255, blue: 230/255, alpha: 1)
        let center = CGFloat(cx)
        let base = CGFloat(baseY)
        let keyboardWidth = 152 * scale
        let keyboardHeight = 15 * scale
        let keyboardX = center - keyboardWidth / 2
        let keyboardY = base - keyboardHeight
        let keyboardRect = CGRect(
            x: keyboardX, y: keyboardY, width: keyboardWidth, height: keyboardHeight)
        let keyboardPath = CGPath(
            roundedRect: keyboardRect, cornerWidth: 4 * scale,
            cornerHeight: 4 * scale, transform: nil)
        ctx.setFillColor(keyboard)
        ctx.addPath(keyboardPath)
        ctx.fillPath()
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(max(0.7, 1.5 * scale))
        ctx.addPath(keyboardPath)
        ctx.strokePath()

        if let cat = BongoCatAsset.image {
            let catWidth = 148 * scale
            let catHeight = catWidth * CGFloat(cat.height) / CGFloat(cat.width)
            let rect = CGRect(
                x: center - catWidth / 2,
                y: keyboardY - 4 * scale - catHeight,
                width: catWidth, height: catHeight)
            drawImageUpright(ctx, cat, in: rect)
        }

        let pawRX = 13 * scale
        let pawRY = 10 * scale
        let downY = keyboardY + 2 * scale
        let upY = keyboardY - 14 * scale
        let leftY = tapping ? (phase ? upY : downY) : downY
        let rightY = tapping ? (phase ? downY : upY) : downY
        for (px, py) in [(center - 34 * scale, leftY), (center + 34 * scale, rightY)] {
            let rect = CGRect(
                x: px - pawRX, y: py - pawRY, width: pawRX * 2, height: pawRY * 2)
            ctx.setFillColor(pink)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(dark)
            ctx.setLineWidth(max(0.7, 2 * scale))
            ctx.strokeEllipse(in: rect)
        }

        if !tapping {
            Draw.text(ctx, "z", x: Int(center + 28 * scale), y: Int(keyboardY - 35 * scale),
                      font: Fonts.system(max(8, 12 * scale), weight: .bold),
                      color: Color.textL)
        }
    }

    /// Draw a CGImage upright inside `rect` within the flipped (y-down) context.
    /// `flipX` mirrors it horizontally (for facing left/right).
    func drawImageUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect,
                                 flipX: Bool = false) {
        ctx.saveGState()
        // These sprites are drawn well below their native size; the default
        // filter loses the small high-contrast details (cheeks, outlines).
        ctx.interpolationQuality = .high
        if flipX {
            ctx.translateBy(x: rect.maxX, y: rect.minY + rect.height)
            ctx.scaleBy(x: -1, y: -1)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

}
