import SwiftUI

/// Root of every notch panel: the animated silhouette (collapsed pill / peek / expanded),
/// its theme surface, and the expanded content.
struct NotchRootView: View {
    let model: NotchViewModel

    @Environment(ThemeEngine.self) private var themeEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(LiveActivityCoordinator.self) private var liveActivity
    @Environment(\.settingsOpener) private var settingsOpener
    @Environment(LicenseManager.self) private var license

    var body: some View {
        let geometry = model.geometry
        let state = model.state
        let activity = liveActivity.current
        let wing = min(activity?.wingWidth ?? 0, geometry.maximumWingWidth)
        let activeModule = ExpandedShellView.resolvedSelection(
            model.selectedModule, enabled: license.isUnlocked ? settings.enabledModules : []
        )
        let layout: ExpandedLayout = activeModule == .aiChat ? .tall : .standard
        let metrics = geometry.metrics(for: state, wing: wing, layout: layout)
        let expandedMetrics = geometry.metrics(for: .expanded, layout: layout)
        let tokens = themeEngine.tokens

        ZStack(alignment: .top) {
            NotchBody(
                metrics: metrics,
                theme: themeEngine.current,
                tokens: tokens,
                // On real hardware the collapsed silhouette sits over the camera housing,
                // so it stays pure black in both themes to stay invisible.
                hardwareBlackness: geometry.kind == .hardwareNotch && state == .collapsed ? 1 : 0,
                shadowOpacity: state == .expanded ? tokens.shadowOpacity : 0
            ) {
                if state == .expanded {
                    ExpandedShellView(model: model)
                        .frame(
                            width: expandedMetrics.shapeSize.width,
                            height: expandedMetrics.shapeSize.height
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.96, anchor: .top))
                                    .animation(.easeOut(duration: 0.22).delay(0.06)),
                                removal: .opacity.animation(.easeIn(duration: 0.1))
                            )
                        )
                } else if let activity {
                    LiveActivityWings(
                        activity: activity,
                        cutoutWidth: geometry.cutout.width + (state == .peek ? NotchGeometry.peekGrowth.width : 0),
                        wing: wing,
                        height: metrics.bodySize.height
                    )
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .animation(NotchMotion.animation(to: .peek), value: activity)
            .onTapGesture {
                if model.state != .expanded { model.onTap() }
            }
            // Right-click the notch: always-reachable Settings / Quit, even when the menu bar
            // icon is hidden behind the notch by menu bar overflow.
            .contextMenu {
                Button("Settings…") {
                    model.onRequestCollapse()
                    settingsOpener.open(.general)
                }
                Divider()
                Button("Quit NotchDeck") { NSApp.terminate(nil) }
            }
            // Optional: on non-notch displays, keep the idle pill invisible until hovered.
            // The hover zone stays live, so the pill still appears on approach.
            .opacity(settings.hidesIdlePill && geometry.kind == .fallbackPill && state == .collapsed && activity == nil ? 0 : 1)

            if settings.showsGeometryOutline {
                GeometryOutline(geometry: geometry, showsLabel: state == .collapsed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// The silhouette itself. Conforms to `Animatable` so SwiftUI re-evaluates it every frame
/// with interpolated size + curvature; that keeps the AppKit material mask, the clip, the
/// stroke and the shadow in perfect lockstep during springs.
struct NotchBody<Content: View>: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    let theme: NotchTheme
    let tokens: ThemeTokens
    let hardwareBlackness: Double
    let shadowOpacity: Double
    let content: Content

    init(
        metrics: NotchShapeMetrics,
        theme: NotchTheme,
        tokens: ThemeTokens,
        hardwareBlackness: Double,
        shadowOpacity: Double,
        @ViewBuilder content: () -> Content
    ) {
        width = metrics.shapeSize.width
        height = metrics.shapeSize.height
        earRadius = metrics.earRadius
        bottomRadius = metrics.bottomRadius
        self.theme = theme
        self.tokens = tokens
        self.hardwareBlackness = hardwareBlackness
        self.shadowOpacity = shadowOpacity
        self.content = content()
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(earRadius, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            earRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    var body: some View {
        let shape = NotchMaskShape(earRadius: earRadius, bottomRadius: bottomRadius)

        ZStack(alignment: .top) {
            NotchShadow(shape: shape, tokens: tokens)
                .frame(width: width, height: height)
                .opacity(shadowOpacity > 0 ? 1 : 0)

            ZStack(alignment: .top) {
                surface(shape)
                    .frame(width: width, height: height)
                content
            }
            .frame(width: width, height: height, alignment: .top)
            .clipShape(shape)
            .contentShape(shape)
        }
    }

    @ViewBuilder
    private func surface(_ shape: NotchMaskShape) -> some View {
        ZStack {
            if theme == .frostedGlass, let material = tokens.material {
                ZStack {
                    NotchMaterialView(material: material, earRadius: earRadius, bottomRadius: bottomRadius)
                    shape.fill(tokens.materialTint)
                    if let border = tokens.borderGradient {
                        // 2pt stroke clipped by the shape = a crisp 1pt *inner* border. The top
                        // point is masked off so no line is drawn along the screen's top edge.
                        shape.stroke(border, lineWidth: 2)
                            .clipShape(shape)
                            .mask(alignment: .top) {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: 1)
                                    Color.black
                                }
                            }
                    }
                }
                .transition(.opacity)
            }

            shape.fill(Color.black)
                .opacity(theme == .classicBlack ? 1 : hardwareBlackness)
        }
    }
}

/// Drop shadow only, with the silhouette's interior knocked out so it never darkens
/// the translucent glass material.
private struct NotchShadow: View {
    let shape: NotchMaskShape
    let tokens: ThemeTokens

    var body: some View {
        shape.fill(Color.black)
            .shadow(
                color: .black.opacity(tokens.shadowOpacity),
                radius: tokens.shadowRadius,
                y: tokens.shadowYOffset
            )
            .mask {
                Rectangle()
                    .padding(-NotchGeometry.shadowPadding)
                    .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// Debug overlay: a 1pt red line hugging the outside of the computed cutout, which should
/// trace the physical notch edge exactly when geometry is correct.
private struct GeometryOutline: View {
    let geometry: NotchGeometry
    let showsLabel: Bool

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .strokeBorder(Color.red, lineWidth: 1)
                .frame(width: geometry.cutout.width + 2, height: geometry.cutout.height + 1)
            if showsLabel {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
            }
        }
        .allowsHitTesting(false)
    }

    private var label: String {
        let c = geometry.cutout
        let kind = geometry.kind == .hardwareNotch ? "notch" : "pill"
        return "\(kind) \(c.width.pt)×\(c.height.pt) @ x \(c.minX.pt)–\(c.maxX.pt)"
    }
}

extension CGFloat {
    /// Compact point formatting: "185", "663.5".
    var pt: String {
        Double(self).formatted(FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).grouping(.never))
    }
}
