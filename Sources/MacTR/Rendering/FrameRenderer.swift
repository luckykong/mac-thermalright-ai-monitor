// FrameRenderer.swift — Protocol for display set renderers
//
// Each display set implements this protocol.
// The frame loop calls render() to get a CGImage, then encodes it to JPEG.

import CoreGraphics
import CThermalSensor
import Foundation
import ImageIO

// MARK: - Protocol

protocol FrameRenderer {
    /// Render a full 1920x480 frame. Returns CGImage in device orientation.
    func render() -> CGImage?
}

// MARK: - JPEG Encoding

enum JPEGEncoder {

    // One reusable RGBA raster replaces the old Core Image brightness pipeline.
    // CIContext retained per-frame intermediates on the always-on LCD path.
    nonisolated(unsafe) private static var processingCtx: CGContext?
    private static let encodeLock = NSLock()

    /// Encode CGImage to JPEG Data with 180° rotation and brightness adjustment.
    /// Reduces quality if over 650KB (matches Python behavior).
    static func encode(
        _ image: CGImage, brightness: Int = 1, rotate: Bool = true, maxBytes: Int = 650_000
    ) -> Data? {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return autoreleasepool {
            let w = image.width
            let h = image.height
            var finalImage = image

            if !rotate || brightness > 1 {
                if processingCtx == nil
                    || processingCtx!.width != w
                    || processingCtx!.height != h
                {
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    processingCtx = CGContext(
                        data: nil,
                        width: w,
                        height: h,
                        bitsPerComponent: 8,
                        bytesPerRow: w * 4,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue)
                }
                guard let ctx = processingCtx else { return nil }
                ctx.saveGState()
                ctx.setBlendMode(.copy)
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                if !rotate {
                    ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
                    ctx.scaleBy(x: -1, y: -1)
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()

                if brightness > 1 {
                    multiplyRGB(
                        context: ctx,
                        factor: Brightness.factor(for: brightness))
                }
                guard let processed = ctx.makeImage() else { return nil }
                finalImage = processed
            }

            // Encode to JPEG with quality reduction loop
            var quality = 0.9
            while quality > 0.3 {
                if let data = jpegData(from: finalImage, quality: quality) {
                    if data.count <= maxBytes || quality <= 0.3 {
                        return data
                    }
                }
                quality -= 0.05
            }
            return jpegData(from: finalImage, quality: 0.3)
        }
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func multiplyRGB(context: CGContext, factor: CGFloat) {
        guard factor > 1, let raw = context.data else { return }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        mactrMultiplyRGB(
            bytes,
            context.width * context.height,
            Double(factor))
    }
}
