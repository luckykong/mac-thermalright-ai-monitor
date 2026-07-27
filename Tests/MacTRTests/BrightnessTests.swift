import CoreGraphics
import CThermalSensor
import Foundation
import ImageIO
import Testing
@testable import MacTR

@Suite("Brightness preserves colour")
struct BrightnessTests {

    /// Runs one RGBA pixel through the brightness pass exactly as the encoder
    /// does. Direct, so the assertions are not blurred by JPEG's colour
    /// round-trip — that is covered separately below.
    private func brighten(
        _ rgb: (Int, Int, Int), level: Int
    ) -> (r: Int, g: Int, b: Int) {
        var pixel: [UInt8] = [
            UInt8(rgb.0), UInt8(rgb.1), UInt8(rgb.2), 255,
        ]
        pixel.withUnsafeMutableBufferPointer { buffer in
            mactrMultiplyRGB(
                buffer.baseAddress, 1, Double(Brightness.factor(for: level)))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test("A vivid colour keeps its channel ratios instead of clipping to white")
    func saturationSurvives() {
        // Bongo Cat's paws — per-channel gain plus clipping made these
        // (255,255,255) at the default brightness.
        let paw = brighten((244, 150, 174), level: 5)
        #expect(paw.r == 255, "the brightest channel should reach the ceiling")
        #expect(paw != (255, 255, 255))
        // 255/244 gain applied to every channel keeps the ratios intact.
        #expect(paw.g == Int((150.0 * 255.0 / 244.0).rounded()))
        #expect(paw.b == Int((174.0 * 255.0 / 244.0).rounded()))

        let red = brighten((239, 68, 68), level: 5)
        #expect(red.r == 255)
        #expect(red.r - red.g > 180, "a clipped red used to land near (255,152,128)")
        #expect(red.g == red.b)
    }

    @Test("Dark pixels still receive the full brightness factor")
    func darkPixelsGetFullGain() {
        // Nothing here is near the ceiling, so the cap must not engage.
        let factor = Double(Brightness.factor(for: 5))
        let dark = brighten((30, 34, 48), level: 5)
        #expect(dark.r == Int((30 * factor).rounded()))
        #expect(dark.g == Int((34 * factor).rounded()))
        #expect(dark.b == Int((48 * factor).rounded()))
    }

    @Test("Brightness level 1 is a no-op")
    func level1IsIdentity() {
        #expect(brighten((244, 150, 174), level: 1) == (244, 150, 174))
    }

    @Test("Pure black stays black")
    func blackStaysBlack() {
        #expect(brighten((0, 0, 0), level: 10) == (0, 0, 0))
    }

    /// Builds a solid-colour image, runs it through the real encode path, and
    /// reads the colour back out of the JPEG.
    private func roundTrip(
        red: Int, green: Int, blue: Int, brightness: Int
    ) throws -> (r: Int, g: Int, b: Int) {
        let width = 16
        let height = 16
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let source = try #require(context.makeImage())

        let jpeg = try #require(JPEGEncoder.encode(
            source, brightness: brightness, rotate180: false))

        let decodeSource = try #require(
            CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(
            CGImageSourceCreateImageAtIndex(decodeSource, 0, nil))
        let readback = try #require(CGContext(
            data: nil, width: decoded.width, height: decoded.height,
            bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        readback.draw(
            decoded,
            in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let pixels = try #require(readback.data)
            .assumingMemoryBound(to: UInt8.self)
        // Sample the middle, away from any block-edge ringing.
        let offset = (decoded.height / 2) * decoded.width * 4
            + (decoded.width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    /// Bongo Cat's paws are the worst case: with per-channel gain and clipping
    /// at the default brightness they came out of the encoder pure white.
    @Test("Pink survives the brightness pass instead of clipping to white")
    func pinkStaysPink() throws {
        let (r, g, b) = try roundTrip(red: 244, green: 150, blue: 174, brightness: 5)

        #expect(r > 235, "the brightest channel should reach the ceiling")
        #expect(r - g > 45, "pink must keep a clear red-over-green margin")
        #expect(b > g + 10, "and stay pink rather than turning orange")
    }

    @Test("Accent red stays red rather than washing out to salmon")
    func redStaysRed() throws {
        let (r, g, b) = try roundTrip(red: 239, green: 68, blue: 68, brightness: 5)

        #expect(r > 235)
        #expect(r - g > 130, "a washed-out red would sit near (255,152,128)")
        #expect(abs(g - b) < 25, "red's two low channels stay balanced")
    }


}
