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

    /// Where the quality search starts. Frame size barely moves between frames,
    /// so restarting at 0.9 every time re-encoded the whole image several times
    /// per frame just to rediscover the same answer. Guarded by `encodeLock`.
    nonisolated(unsafe) private static var lastGoodQuality = 0.9

    /// One line, not one per frame: if a frame cannot be made to fit, neither
    /// can the next one, and the loop runs several times a second.
    nonisolated(unsafe) private static var reportedOversize = false

    /// Encode a CGImage to JPEG for the LCD, optionally rotating 180° and
    /// brightening. Reduces quality if over 650KB (matches Python behavior).
    ///
    /// `rotate180` says plainly what it does. It used to be called `rotate`
    /// with the inverted meaning — `if !rotate { …rotate… }`, defaulting to
    /// `true` — so the parameter name, its default and the doc comment all
    /// contradicted each other. The panel is normally mounted upside down
    /// relative to the rendered frame, and the user-facing "Rotate 180°"
    /// switch is for panels mounted the other way up, so it *disables* this.
    static func encode(
        _ image: CGImage,
        brightness: Int = 1,
        rotate180: Bool = true,
        maxBytes: Int = maxJPEGSize
    ) -> Data? {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return autoreleasepool {
            let w = image.width
            let h = image.height
            var finalImage = image

            if rotate180 || brightness > 1 {
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
                if rotate180 {
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

            // Encode to JPEG, stepping quality down until it fits. Resume just
            // above the last quality that worked so the value drifts back up
            // when frames get cheaper, without re-probing from 0.9 every time.
            var quality = min(lastGoodQuality + 0.05, 0.9)
            while quality > 0.3 {
                if let data = jpegData(from: finalImage, quality: quality),
                   data.count <= maxBytes
                {
                    lastGoodQuality = quality
                    return data
                }
                quality -= 0.05
            }
            lastGoodQuality = 0.3
            // The floor was returned unchecked, so a frame that will not fit at
            // any quality still reached the wire and made LYProtocol throw
            // frameTooLarge — which the engine cannot tell apart from a real USB
            // failure. Drop the frame instead and let the next one try.
            guard let atFloor = jpegData(from: finalImage, quality: 0.3),
                  atFloor.count <= maxBytes
            else {
                if !reportedOversize {
                    reportedOversize = true
                    log("[JPEG] Frame exceeds \(maxBytes) bytes even at minimum"
                        + " quality; dropping it. Logged once.")
                }
                return nil
            }
            return atFloor
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
