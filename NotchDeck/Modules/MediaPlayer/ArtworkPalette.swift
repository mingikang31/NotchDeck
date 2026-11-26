import CoreGraphics
import SwiftUI

/// Dynamic color extraction from album artwork, for the ambient glow and visualizer.
nonisolated enum ArtworkPalette {
    nonisolated struct RGB: Equatable, Sendable {
        var red: Double, green: Double, blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        var saturation: Double {
            let maxC = max(red, green, blue), minC = min(red, green, blue)
            return maxC == 0 ? 0 : (maxC - minC) / maxC
        }

        var brightness: Double { max(red, green, blue) }
    }

    /// Returns `[vibrant, average]`: the most saturated reasonably bright color, and the mean.
    /// Downsamples to 24×24 so this costs microseconds.
    static func extract(from image: CGImage) -> [RGB] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var sum = RGB(red: 0, green: 0, blue: 0)
        var vibrant: RGB?
        var bestScore = -1.0
        var counted = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 {
            let rgb = RGB(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255)
            sum.red += rgb.red; sum.green += rgb.green; sum.blue += rgb.blue
            counted += 1
            // Favor saturated colors, but ignore near-black pixels that are "saturated" by noise.
            let score = rgb.saturation * (rgb.brightness > 0.25 ? rgb.brightness : 0)
            if score > bestScore { bestScore = score; vibrant = rgb }
        }
        guard counted > 0 else { return [] }
        let average = RGB(red: sum.red / counted, green: sum.green / counted, blue: sum.blue / counted)
        return [vibrant ?? average, average]
    }
}
