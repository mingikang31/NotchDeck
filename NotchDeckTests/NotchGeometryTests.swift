import CoreGraphics
import SwiftUI
import Testing
@testable import NotchDeck

/// Values captured from a real 14" MacBook Pro (1512×982 pt, 32 pt notch).
private enum MBP14 {
    static let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let visible = CGRect(x: 0, y: 61, width: 1512, height: 888)
    static let auxLeft = CGRect(x: 0, y: 950, width: 663.5, height: 32)
    static let auxRight = CGRect(x: 848.5, y: 950, width: 663.5, height: 32)

    static func geometry(preset: NotchSizePreset = .medium) -> NotchGeometry {
        .compute(
            screenFrame: frame, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight, preset: preset
        )
    }
}

struct NotchGeometryTests {
    @Test func hardwareNotchMatchesAuxiliaryAreas() {
        let g = MBP14.geometry()
        #expect(g.kind == .hardwareNotch)
        #expect(g.cutout == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(g.topInset == 32)
    }

    @Test func collapsedBodyCoversCutoutExactly() {
        let g = MBP14.geometry()
        #expect(g.bodyRect(for: .collapsed) == g.cutout)
        #expect(g.shapeRect(for: .collapsed).maxY == MBP14.frame.maxY)
    }

    @Test func panelIsTopAnchoredCenteredAndPixelAligned() {
        let g = MBP14.geometry()
        #expect(g.panelFrame.maxY == MBP14.frame.maxY)
        #expect(g.panelFrame.midX == g.cutout.midX)
        #expect(g.panelFrame.minX == g.panelFrame.minX.rounded())
        #expect(g.panelFrame.width.truncatingRemainder(dividingBy: 2) == 0)
    }

    @Test(arguments: NotchSizePreset.allCases)
    func everyStateFitsInsidePanel(preset: NotchSizePreset) {
        let g = MBP14.geometry(preset: preset)
        for state in [NotchState.collapsed, .peek, .expanded] {
            #expect(g.panelFrame.contains(g.shapeRect(for: state)))
            #expect(g.shapeRect(for: state).midX == g.cutout.midX)
        }
    }

    @Test func interactionZonesAreNested() {
        let g = MBP14.geometry()
        #expect(g.interactionZone(for: .peek).contains(g.interactionZone(for: .collapsed)))
        #expect(g.interactionZone(for: .expanded).contains(g.interactionZone(for: .peek)))
        // The very top pixel row (y == maxY) must count as hovering.
        #expect(g.interactionZone(for: .collapsed).contains(CGPoint(x: 756, y: 982)))
        // Menu bar items just beside the notch must not trigger hover.
        #expect(!g.interactionZone(for: .collapsed).contains(CGPoint(x: 640, y: 970)))
    }

    @Test func fallbackPillOnExternalDisplayUsesMenuBarHeight() {
        // 1920×1080 display to the right of the built-in, with a 25 pt menu bar.
        let frame = CGRect(x: 1512, y: -98, width: 1920, height: 1080)
        let visible = CGRect(x: 1512, y: -98, width: 1920, height: 1055)
        let g = NotchGeometry.compute(
            screenFrame: frame, visibleFrame: visible, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, preset: .medium
        )
        #expect(g.kind == .fallbackPill)
        #expect(g.cutout.midX == frame.midX)
        #expect(g.cutout.height == 25)
        #expect(g.cutout.maxY == frame.maxY)
        #expect(g.panelFrame.maxY == frame.maxY)
    }

    @Test func fallbackPillWithoutMenuBarUsesDefaultHeight() {
        let frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let g = NotchGeometry.compute(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, preset: .medium
        )
        #expect(g.kind == .fallbackPill)
        #expect(g.cutout.height == NotchGeometry.fallbackPillDefaultHeight)
    }

    @Test func notchOnOffsetScreenUsesWidthsNotOrigins() {
        // Built-in placed left of a primary external display; aux rects given in global coords.
        let frame = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let left = CGRect(x: -1512, y: 950, width: 663.5, height: 32)
        let right = CGRect(x: -663.5, y: 950, width: 663.5, height: 32)
        let g = NotchGeometry.compute(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 32,
            auxiliaryTopLeft: left, auxiliaryTopRight: right, preset: .medium
        )
        #expect(g.kind == .hardwareNotch)
        #expect(g.cutout == CGRect(x: -848.5, y: 950, width: 185, height: 32))
    }

    @Test func expandedWidthClampsOnNarrowScreens() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let g = NotchGeometry.compute(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, preset: .large
        )
        #expect(g.shapeRect(for: .expanded).width <= frame.width - 2 * NotchGeometry.minimumScreenMargin)
    }
}

struct NotchMaskShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    private let path = NotchMaskShape(earRadius: 10, bottomRadius: 24).path(in: CGRect(x: 0, y: 0, width: 200, height: 100))

    @Test func boundsSpanFullRectIncludingEars() {
        let bounds = path.boundingRect
        #expect(abs(bounds.minX - rect.minX) < 0.5)
        #expect(abs(bounds.maxX - rect.maxX) < 0.5)
        #expect(abs(bounds.minY - rect.minY) < 0.5)
        #expect(abs(bounds.maxY - rect.maxY) < 0.5)
    }

    @Test func earsFlareOutwardAtTopOnly() {
        #expect(path.contains(CGPoint(x: 8, y: 1)))        // inside left ear, near the body
        #expect(!path.contains(CGPoint(x: 2, y: 8)))       // below the ear curve
        #expect(!path.contains(CGPoint(x: 5, y: 50)))      // beside the body
        #expect(path.contains(CGPoint(x: 192, y: 1)))      // inside right ear
    }

    @Test func bottomCornersAreRounded() {
        #expect(path.contains(CGPoint(x: 100, y: 50)))
        #expect(!path.contains(CGPoint(x: 11, y: 99)))
        #expect(!path.contains(CGPoint(x: 189, y: 99)))
        #expect(path.contains(CGPoint(x: 100, y: 99)))
    }

    @Test func zeroEarDegeneratesToPlainBody() {
        let flat = NotchMaskShape(earRadius: 0, bottomRadius: 8).path(in: rect)
        #expect(flat.contains(CGPoint(x: 1, y: 1)))
    }

    @Test func maskImageMatchesRequestedSize() throws {
        let image = try #require(NotchMaskShape(earRadius: 10, bottomRadius: 24).maskImage(size: rect.size, scale: 2))
        #expect(image.size == rect.size)
    }

    /// Guards against a vertically flipped glass mask (ears would render at the bottom).
    @Test func maskImageIsUprightForAppKit() throws {
        let scale: CGFloat = 2
        let image = try #require(NotchMaskShape(earRadius: 10, bottomRadius: 24).maskImage(size: rect.size, scale: scale))
        var proposed = CGRect(origin: .zero, size: rect.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))

        // Redraw into a known RGBA layout; row 0 of the buffer is the image's top row.
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func alpha(x: CGFloat, yFromTop: CGFloat) -> UInt8 {
            let px = Int(x * scale), row = Int(yFromTop * scale)
            return pixels[(row * width + px) * 4 + 3]
        }

        #expect(alpha(x: 8, yFromTop: 0.5) > 200)   // inside the left ear, top edge
        #expect(alpha(x: 8, yFromTop: 99.5) == 0)   // same x at the bottom: outside
        #expect(alpha(x: 100, yFromTop: 99.5) > 200) // bottom-center: inside the body
        #expect(alpha(x: 11, yFromTop: 99.5) == 0)   // rounded bottom-left corner
    }
}
