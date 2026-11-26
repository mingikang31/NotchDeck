import AppKit
import SwiftUI

/// The three visual states of a notch surface.
nonisolated enum NotchState: Equatable, Sendable {
    /// Idle: the surface exactly covers the hardware cutout (or fallback pill).
    case collapsed
    /// The cursor is dwelling over the notch; the surface swells slightly as feedback.
    case peek
    /// Fully opened command center.
    case expanded
}

/// User-selectable expanded sizes (Appearance presets; full UI lands in Phase 2).
nonisolated enum NotchSizePreset: String, CaseIterable, Identifiable, Sendable {
    case compact, medium, large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Width of the expanded body (excluding the flared "ears").
    var expandedBodyWidth: CGFloat {
        switch self {
        case .compact: 520
        case .medium: 600
        case .large: 680
        }
    }

    /// Height below the cutout for the tall layout (AI Chat needs room for a conversation).
    var tallContentHeight: CGFloat {
        switch self {
        case .compact: 300
        case .medium: 360
        case .large: 440
        }
    }

    /// Height available for content *below* the cutout strip.
    var contentHeight: CGFloat {
        switch self {
        case .compact: 130
        case .medium: 150
        case .large: 190
        }
    }
}

/// Which expanded size to use: standard modules, or the taller conversation layout.
nonisolated enum ExpandedLayout: Equatable, Sendable {
    case standard, tall
}

/// Size and curvature of the notch silhouette for a given state.
nonisolated struct NotchShapeMetrics: Equatable, Sendable {
    /// The main body (the part that sits under / extends the hardware notch).
    var bodySize: CGSize
    /// Radius of the concave top "ears" that flare outward into the menu bar.
    var earRadius: CGFloat
    /// Continuous corner radius of the bottom corners.
    var bottomRadius: CGFloat

    /// Full bounding size of the silhouette including both ears.
    var shapeSize: CGSize {
        CGSize(width: bodySize.width + 2 * earRadius, height: bodySize.height)
    }
}

/// Pure geometry for one display: where the cutout is, how large each state is,
/// where the panel sits, and which screen regions count as "inside" for hover.
///
/// All rects are in global AppKit screen coordinates (origin bottom-left of the
/// primary display), the same space as `NSEvent.mouseLocation` and `NSWindow.frame`.
nonisolated struct NotchGeometry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A real camera housing reported by `NSScreen.auxiliaryTopLeftArea/RightArea`.
        case hardwareNotch
        /// External monitor or pre-notch Mac: a virtual top-center pill.
        case fallbackPill
    }

    // MARK: Tunables

    /// Room around the expanded silhouette for the drop shadow.
    static let shadowPadding: CGFloat = 36
    /// How much the surface swells while the cursor dwells on it.
    static let peekGrowth = CGSize(width: 14, height: 4)
    /// Extra slop around the cutout that still counts as hovering it.
    static let hoverSlop: CGFloat = 6
    /// Extra slop around the expanded surface before auto-collapse kicks in.
    static let exitSlop: CGFloat = 14
    /// Minimum gap between the expanded surface and the screen edges.
    static let minimumScreenMargin: CGFloat = 24
    /// Fallback pill size on displays without a notch.
    static let fallbackPillWidth: CGFloat = 164
    static let fallbackPillDefaultHeight: CGFloat = 24

    // Curvature per state. The collapsed values approximate the physical
    // notch's own fillets so the drawn silhouette disappears into the hardware.
    static let collapsedEarRadius: CGFloat = 4
    static let collapsedBottomRadius: CGFloat = 8
    static let peekEarRadius: CGFloat = 6
    static let peekBottomRadius: CGFloat = 10
    static let expandedEarRadius: CGFloat = 12
    static let expandedBottomRadius: CGFloat = 24

    // MARK: Stored geometry

    let kind: Kind
    let screenFrame: CGRect
    /// The hardware notch rect, or the virtual pill rect on non-notch displays.
    let cutout: CGRect
    let expandedBodySize: CGSize
    /// Expanded size for the tall (chat) layout: same width, more height.
    let tallExpandedBodySize: CGSize
    /// Panel frame for the standard layout: large enough for the expanded state + shadow, so
    /// the window never resizes mid-animation (resizing NSWindows per frame stutters).
    let panelFrame: CGRect
    /// Panel frame while the tall layout is (or is becoming) visible. Same top edge and width.
    let tallPanelFrame: CGRect

    func panelFrame(for layout: ExpandedLayout) -> CGRect {
        layout == .tall ? tallPanelFrame : panelFrame
    }

    /// Height of the strip occupied by the cutout; expanded content starts below it.
    var topInset: CGFloat { cutout.height }

    // MARK: Per-state metrics

    /// Widest live-activity "wing" (content beside the cutout) that still fits the panel.
    var maximumWingWidth: CGFloat {
        max(0, (expandedBodySize.width - cutout.width - Self.peekGrowth.width) / 2)
    }

    /// - Parameter wing: width of the live-activity content shown on *each* side of the cutout
    ///   while collapsed or peeking (album art + visualizer, next meeting). 0 when idle.
    func metrics(for state: NotchState, wing: CGFloat = 0, layout: ExpandedLayout = .standard) -> NotchShapeMetrics {
        let wing = min(max(wing, 0), maximumWingWidth)
        return switch state {
        case .collapsed:
            NotchShapeMetrics(
                bodySize: CGSize(width: cutout.width + 2 * wing, height: cutout.height),
                earRadius: Self.collapsedEarRadius,
                bottomRadius: Self.collapsedBottomRadius
            )
        case .peek:
            NotchShapeMetrics(
                bodySize: CGSize(
                    width: cutout.width + 2 * wing + Self.peekGrowth.width,
                    height: cutout.height + Self.peekGrowth.height
                ),
                earRadius: Self.peekEarRadius,
                bottomRadius: Self.peekBottomRadius
            )
        case .expanded:
            NotchShapeMetrics(
                bodySize: layout == .tall ? tallExpandedBodySize : expandedBodySize,
                earRadius: Self.expandedEarRadius,
                bottomRadius: Self.expandedBottomRadius
            )
        }
    }

    /// Global rect of the full silhouette (ears included), top-anchored and centered on the cutout.
    func shapeRect(for state: NotchState, wing: CGFloat = 0, layout: ExpandedLayout = .standard) -> CGRect {
        let size = metrics(for: state, wing: wing, layout: layout).shapeSize
        return CGRect(
            x: cutout.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Global rect of the body only (ears excluded).
    func bodyRect(for state: NotchState, wing: CGFloat = 0) -> CGRect {
        let m = metrics(for: state, wing: wing)
        return shapeRect(for: state, wing: wing).insetBy(dx: m.earRadius, dy: 0)
    }

    /// Region in which the pointer is considered "on" the notch for the given state.
    /// Extends above the screen's top edge so the very top pixel row is included.
    func interactionZone(for state: NotchState, wing: CGFloat = 0, layout: ExpandedLayout = .standard) -> CGRect {
        switch state {
        case .collapsed:
            bodyRect(for: .collapsed, wing: wing).insetBy(dx: -Self.hoverSlop, dy: -Self.hoverSlop)
        case .peek:
            shapeRect(for: .peek, wing: wing).insetBy(dx: -Self.hoverSlop, dy: -Self.hoverSlop)
        case .expanded:
            shapeRect(for: .expanded, layout: layout).insetBy(dx: -Self.exitSlop, dy: -Self.exitSlop)
        }
    }

    // MARK: Construction

    /// Computes geometry from raw screen values. Kept free of `NSScreen` so it is unit-testable.
    ///
    /// The notch width is derived from the *widths* of the auxiliary areas rather than
    /// their origins, so the math is correct whether AppKit reports those rects in
    /// screen-local or global coordinates (it matters on secondary displays).
    static func compute(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        preset: NotchSizePreset
    ) -> NotchGeometry {
        let kind: Kind
        let cutout: CGRect

        if safeAreaTop > 0,
           let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
           left.width > 0, right.width > 0,
           screenFrame.width - left.width - right.width > 0 {
            let notchWidth = screenFrame.width - left.width - right.width
            cutout = CGRect(
                x: screenFrame.minX + left.width,
                y: screenFrame.maxY - safeAreaTop,
                width: notchWidth,
                height: safeAreaTop
            )
            kind = .hardwareNotch
        } else {
            let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
            let height = (18...44).contains(menuBarHeight) ? menuBarHeight : fallbackPillDefaultHeight
            cutout = CGRect(
                x: screenFrame.midX - fallbackPillWidth / 2,
                y: screenFrame.maxY - height,
                width: fallbackPillWidth,
                height: height
            )
            kind = .fallbackPill
        }

        let maxBodyWidth = screenFrame.width - 2 * expandedEarRadius - 2 * minimumScreenMargin
        let expandedBodySize = CGSize(
            width: max(cutout.width, min(preset.expandedBodyWidth, maxBodyWidth)),
            height: cutout.height + preset.contentHeight
        )

        // Even integer width keeps the panel origin on whole points when the cutout
        // center is integral, so the silhouette lands on exact device pixels.
        let expandedShapeWidth = expandedBodySize.width + 2 * expandedEarRadius
        let panelWidth = (((expandedShapeWidth + 2 * shadowPadding) / 2).rounded(.up)) * 2
        let panelHeight = (expandedBodySize.height + shadowPadding).rounded(.up)
        let panelFrame = CGRect(
            x: cutout.midX - panelWidth / 2,
            y: screenFrame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        // Tall layout: capped at 70% of the screen so it never swallows a small display.
        let tallBodyHeight = min(cutout.height + preset.tallContentHeight, (screenFrame.height * 0.7).rounded(.down))
        let tallExpandedBodySize = CGSize(width: expandedBodySize.width, height: max(expandedBodySize.height, tallBodyHeight))
        let tallPanelHeight = (tallExpandedBodySize.height + shadowPadding).rounded(.up)
        let tallPanelFrame = CGRect(
            x: panelFrame.minX,
            y: screenFrame.maxY - tallPanelHeight,
            width: panelWidth,
            height: tallPanelHeight
        )

        return NotchGeometry(
            kind: kind,
            screenFrame: screenFrame,
            cutout: cutout,
            expandedBodySize: expandedBodySize,
            tallExpandedBodySize: tallExpandedBodySize,
            panelFrame: panelFrame,
            tallPanelFrame: tallPanelFrame
        )
    }
}

// MARK: - Spring animation metrics

enum NotchMotion {
    /// Springs tuned per destination: a lively open, a quick peek, a well-damped close.
    /// SwiftUI drives these from the display link, so they run at 120 Hz on ProMotion panels.
    static func animation(to state: NotchState) -> Animation {
        switch state {
        case .expanded: .spring(response: 0.42, dampingFraction: 0.78)
        case .peek: .spring(response: 0.26, dampingFraction: 0.72)
        case .collapsed: .spring(response: 0.34, dampingFraction: 0.92)
        }
    }

    static let themeSwitch: Animation = .smooth(duration: 0.35)
}

// MARK: - NSScreen bridging

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    func notchGeometry(preset: NotchSizePreset) -> NotchGeometry {
        NotchGeometry.compute(
            screenFrame: frame,
            visibleFrame: visibleFrame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea,
            auxiliaryTopRight: auxiliaryTopRightArea,
            preset: preset
        )
    }

    var hasHardwareNotch: Bool {
        notchGeometry(preset: .medium).kind == .hardwareNotch
    }
}
