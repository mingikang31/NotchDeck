import AppKit
import SwiftUI

/// `NSVisualEffectView` masked to the notch silhouette.
///
/// Behind-window blending is composited by the window server, which does not honor
/// SwiftUI clip shapes, so the silhouette is applied through `maskImage` instead and
/// regenerated whenever the size or curvature changes (i.e. every animation frame).
final class NotchVisualEffectView: NSVisualEffectView {
    var earRadius: CGFloat = 0 {
        didSet { if earRadius != oldValue { needsLayout = true } }
    }

    var bottomRadius: CGFloat = 0 {
        didSet { if bottomRadius != oldValue { needsLayout = true } }
    }

    private struct MaskKey: Equatable {
        var size: CGSize
        var earRadius: CGFloat
        var bottomRadius: CGFloat
        var scale: CGFloat
    }

    private var renderedMaskKey: MaskKey?

    override func layout() {
        super.layout()
        refreshMask()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderedMaskKey = nil
        needsLayout = true
    }

    private func refreshMask() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = MaskKey(size: bounds.size, earRadius: earRadius, bottomRadius: bottomRadius, scale: scale)
        guard key != renderedMaskKey, bounds.width >= 1, bounds.height >= 1 else { return }
        renderedMaskKey = key
        maskImage = NotchMaskShape(earRadius: earRadius, bottomRadius: bottomRadius)
            .maskImage(size: bounds.size, scale: scale)
    }
}

struct NotchMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    func makeNSView(context: Context) -> NotchVisualEffectView {
        let view = NotchVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.material = material
        return view
    }

    /// Only touches properties that changed: re-assigning `material` (even to the same value) can make the
    /// effect view rebuild its blur, a likely source of the background "pulsing" when content updates.
    func updateNSView(_ view: NotchVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        view.earRadius = earRadius
        view.bottomRadius = bottomRadius
    }
}
