import AppKit
import SwiftUI

/// The notch silhouette: a body with continuous-curvature (squircle) bottom corners and
/// two concave "ears" at the top that flare outward into the menu bar, so the surface
/// reads as physically extruded from the hardware camera housing.
///
///     ╲___                         ___╱   ← ears (concave, radius = earRadius)
///         │                       │
///         │         body          │
///          ╲_____________________╱       ← bottom corners (continuous, bottomRadius)
///
/// Both radii are animatable so springs morph the curvature along with the size.
nonisolated struct NotchMaskShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let body = rect.insetBy(dx: ear, dy: 0)
        let bottom = max(0, min(bottomRadius, body.width / 2, body.height - ear))

        // Apple's own continuous-corner curve for the bottom corners.
        let bodyPath = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: 0
            ),
            style: .continuous
        ).path(in: body)

        guard ear > 0.01 else { return bodyPath }

        // Ear fillets overlap the body by 1pt so the union yields one clean outline
        // (no interior seam when stroking the glass border).
        var ears = Path()
        ears.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ears.addQuadCurve(
            to: CGPoint(x: body.minX, y: rect.minY + ear),
            control: CGPoint(x: body.minX, y: rect.minY)
        )
        ears.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY + ear))
        ears.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY))
        ears.closeSubpath()

        ears.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        ears.addQuadCurve(
            to: CGPoint(x: body.maxX, y: rect.minY + ear),
            control: CGPoint(x: body.maxX, y: rect.minY)
        )
        ears.addLine(to: CGPoint(x: body.maxX - 1, y: rect.minY + ear))
        ears.addLine(to: CGPoint(x: body.maxX - 1, y: rect.minY))
        ears.closeSubpath()

        return bodyPath.union(ears)
    }
}

extension NotchMaskShape {
    /// Renders the silhouette into an image suitable for `NSVisualEffectView.maskImage`
    /// (behind-window materials ignore SwiftUI clipping, so they need a real mask).
    func maskImage(size: CGSize, scale: CGFloat) -> NSImage? {
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // SwiftUI paths are top-left origin; CoreGraphics bitmaps are bottom-left.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(path(in: CGRect(origin: .zero, size: size)).cgPath)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}
