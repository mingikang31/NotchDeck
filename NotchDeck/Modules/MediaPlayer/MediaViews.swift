import SwiftUI

/// Expanded Now Playing: artwork with ambient glow, metadata, scrub bar, transport controls,
/// output device picker.
struct MediaModuleView: View {
    let tokens: ThemeTokens

    @Environment(NowPlayingStore.self) private var media
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if let snapshot = media.snapshot {
            HStack(alignment: .center, spacing: 16) {
                ArtworkView(image: media.artwork, glowColors: glowColors, glowOpacity: tokens.glowOpacity, size: 84)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.title.isEmpty ? "Unknown Title" : snapshot.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text([snapshot.artist, snapshot.album].filter { !$0.isEmpty }.joined(separator: " — "))
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        AudioVisualizer(isPlaying: media.isPlaying, style: settings.visualizerStyle, colors: glowColors)
                            .frame(width: 22, height: 16)
                    }

                    ScrubBar(tokens: tokens, accent: glowColors.first ?? .white)

                    HStack(spacing: 18) {
                        TransportButton(symbol: "backward.fill", size: 13) { media.perform(.previous) }
                        TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 18) { media.perform(.playPause) }
                        TransportButton(symbol: "forward.fill", size: 13) { media.perform(.next) }
                        Spacer()
                        LyricsToggle(tokens: tokens)
                        OutputDevicePicker(tokens: tokens)
                        Text(snapshot.source.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
        } else {
            NothingPlayingView(tokens: tokens)
        }
    }

    private var glowColors: [Color] {
        settings.accentColor.colors(artworkPalette: media.palette)
    }
}

/// Turns time-synced lyrics under the collapsed notch on or off; the tooltip says what was found.
private struct LyricsToggle: View {
    let tokens: ThemeTokens

    @Environment(SettingsStore.self) private var settings
    @Environment(LyricsStore.self) private var lyrics

    var body: some View {
        Button {
            settings.lyricsEnabled.toggle()
        } label: {
            Image(systemName: settings.lyricsEnabled ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.lyricsEnabled ? tokens.primaryText : tokens.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(settings.lyricsEnabled ? "Turn lyrics off" : "Turn lyrics on")
    }

    private var help: String {
        guard settings.lyricsEnabled else {
            return "Show time-synced lyrics under the notch while music plays (looks up songs on lrclib.net)"
        }
        return switch lyrics.state {
        case .off: "Lyrics on"
        case .loading: "Lyrics on · looking up this song…"
        case .synced: "Lyrics on · following along. Click to turn off."
        case .unsynced: "Lyrics on · this song's lyrics have no timings, so they can't follow along"
        case .instrumental: "Lyrics on · instrumental track"
        case .notFound: "Lyrics on · no lyrics found for this song"
        case .failed: "Lyrics on · couldn't reach lrclib.net"
        }
    }
}

/// Album art (or a placeholder) with the ambient glow behind it.
struct ArtworkView: View {
    let image: NSImage?
    let glowColors: [Color]
    let glowOpacity: Double
    let size: CGFloat

    var body: some View {
        art
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
            .background {
                art
                    .frame(width: size, height: size)
                    .blur(radius: size * 0.22)
                    .scaleEffect(1.12)
                    .opacity(glowOpacity)
            }
            .animation(.smooth(duration: 0.4), value: image)
    }

    @ViewBuilder
    private var art: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: glowColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
        }
    }
}

/// Elapsed / remaining with a draggable track that seeks on release.
private struct ScrubBar: View {
    let tokens: ThemeTokens
    let accent: Color

    @Environment(NowPlayingStore.self) private var media
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(media.snapshot?.duration ?? 0, 0)
            let livePosition = media.position(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? livePosition / duration : 0)

            VStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tokens.controlFill)
                        Capsule().fill(accent.opacity(0.9))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                    .frame(height: dragFraction == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                            }
                            .onEnded { _ in
                                if let dragFraction, duration > 0 { media.perform(.seek(dragFraction * duration)) }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 10)

                HStack {
                    Text(Self.format(fraction * duration))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - fraction * duration)))
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(tokens.secondaryText)
            }
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

private struct OutputDevicePicker: View {
    let tokens: ThemeTokens
    @Environment(NowPlayingStore.self) private var media

    var body: some View {
        Menu {
            ForEach(media.outputDevices) { device in
                Button {
                    media.selectOutputDevice(device)
                } label: {
                    if device.id == media.currentOutputDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Image(systemName: currentDevice?.symbolName ?? "hifispeaker")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output: \(currentDevice?.name ?? "Unknown")")
        .onAppear { media.refreshOutputDevices() }
    }

    private var currentDevice: AudioOutputDevice? {
        media.outputDevices.first { $0.id == media.currentOutputDeviceID }
    }
}

private struct NothingPlayingView: View {
    let tokens: ThemeTokens
    @Environment(NowPlayingStore.self) private var media

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 60, height: 60)
                .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if let issue = media.consentIssue {
                    Text("Allow NotchDeck to control \(issue.source.displayName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(issue.isDenied
                         ? "Access is off. Turn on \(issue.source.displayName) under NotchDeck in Automation settings."
                         : "macOS should ask you now. No prompt? Click Ask Again, or switch it on in Automation settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Ask Again") { media.askForConsentAgain(issue.source) }
                            .controlSize(.small)
                        Button("Open Automation Settings") { media.openAutomationSettings() }
                            .controlSize(.small)
                    }
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Start something in Music or Spotify.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                    HStack(spacing: 8) {
                        ForEach(MediaSource.allCases.filter(media.isInstalled), id: \.self) { source in
                            Button("Open \(source.displayName)") { media.launch(source) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Spacer()
        }
    }
}

/// Live audio visualizer. Real per-app audio levels would need a system audio tap, so this is
/// a lively procedural animation that runs only while playing and settles when paused.
/// The animated bars / wave beside the album art. Not driven by the audio (macOS doesn't share other
/// apps' audio levels): it's a decorative loop, so it runs as Core Animation keyframes in the system's
/// render server. NotchDeck does no per-frame work, and it's smooth at the display's refresh rate.
struct AudioVisualizer: View {
    let isPlaying: Bool
    let style: VisualizerStyle
    let colors: [Color]
    var barCount = 4

    var body: some View {
        if style != .off {
            VisualizerLayerRepresentable(
                isPlaying: isPlaying,
                style: style,
                colors: (colors.isEmpty ? [.white] : colors).map { NSColor($0).cgColor },
                barCount: barCount
            )
        }
    }
}

private struct VisualizerLayerRepresentable: NSViewRepresentable {
    let isPlaying: Bool
    let style: VisualizerStyle
    let colors: [CGColor]
    let barCount: Int

    func makeNSView(context: Context) -> VisualizerLayerView {
        let view = VisualizerLayerView()
        update(view)
        return view
    }

    func updateNSView(_ view: VisualizerLayerView, context: Context) { update(view) }

    private func update(_ view: VisualizerLayerView) {
        view.configure(style: style, barCount: barCount, colors: colors, isPlaying: isPlaying)
    }
}

/// Layer-hosting view whose bars / wave animate with repeating keyframe animations.
final class VisualizerLayerView: NSView {
    /// Bars loop every 6 s: each bar's frequencies are whole multiples of 1/6 Hz, so the loop is seamless.
    static let barLoop: TimeInterval = 6
    static let keyframeRate: Double = 30
    /// The wave advances 6 rad/s, repeating every 2π/6 s.
    static let waveLoop: TimeInterval = 2 * .pi / 6

    private(set) var style: VisualizerStyle = .bars
    private(set) var isPlaying = false
    private var colors: [CGColor] = []
    private var barCount = 4
    private var builtFor: (size: CGSize, style: VisualizerStyle, bars: Int)?
    private var barLayers: [CAGradientLayer] = []
    private var waveGradient: CAGradientLayer?
    private var waveMask: CAShapeLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(style: VisualizerStyle, barCount: Int, colors: [CGColor], isPlaying: Bool) {
        let structureChanged = style != self.style || barCount != self.barCount
        self.style = style
        self.barCount = barCount
        if colors != self.colors {
            self.colors = colors
            applyColors()
        }
        if structureChanged {
            builtFor = nil
            needsLayout = true
        }
        if isPlaying != self.isPlaying {
            self.isPlaying = isPlaying
            applyMotion(animated: true)
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        if let built = builtFor, built.size == size, built.style == style, built.bars == barCount { return }
        rebuild(size: size)
    }

    private func rebuild(size: CGSize) {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        barLayers = []
        waveGradient = nil
        waveMask = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .bars:
            let spacing: CGFloat = 2
            let width = max(1, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            for index in 0..<barCount {
                let bar = CAGradientLayer()
                bar.cornerRadius = width / 2
                bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                bar.position = CGPoint(x: CGFloat(index) * (width + spacing) + width / 2, y: size.height / 2)
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: restingHeight(width: width, height: size.height))
                layer?.addSublayer(bar)
                barLayers.append(bar)
            }
        case .wave:
            let gradient = CAGradientLayer()
            gradient.frame = CGRect(origin: .zero, size: size)
            let mask = CAShapeLayer()
            mask.frame = gradient.bounds
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = 2
            mask.lineCap = .round
            mask.lineJoin = .round
            mask.path = Self.wavePath(size: size, phase: 0, amplitude: size.height * 0.05)
            gradient.mask = mask
            layer?.addSublayer(gradient)
            waveGradient = gradient
            waveMask = mask
        case .off:
            break
        }
        CATransaction.commit()
        builtFor = (size, style, barCount)
        applyColors()
        applyMotion(animated: false)
    }

    private func applyColors() {
        let colors = self.colors.isEmpty ? [NSColor.white.cgColor] : self.colors
        let stops = colors.count == 1 ? [colors[0], colors[0]] : colors
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers { bar.colors = stops }
        waveGradient?.colors = stops
        CATransaction.commit()
    }

    private func restingHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        max(width, height * 0.18)
    }

    /// Starts the looping animation while playing; eases to a low resting shape when paused.
    private func applyMotion(animated: Bool) {
        let size = bounds.size
        guard size.width >= 1 else { return }
        for (index, bar) in barLayers.enumerated() {
            let width = bar.bounds.width
            let rest = CGRect(x: 0, y: 0, width: width, height: restingHeight(width: width, height: size.height))
            if isPlaying {
                let frames = Int(Self.barLoop * Self.keyframeRate)
                let animation = CAKeyframeAnimation(keyPath: "bounds")
                animation.values = (0...frames).map { frame in
                    let t = Double(frame) / Self.keyframeRate
                    let height = max(width, size.height * Self.barLevel(index: index, time: t))
                    return NSValue(rect: CGRect(x: 0, y: 0, width: width, height: height))
                }
                animation.duration = Self.barLoop
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                animation.isRemovedOnCompletion = false
                bar.add(animation, forKey: "level")
            } else {
                // Ease from wherever the bar is to rest.
                let current = bar.presentation()?.bounds ?? bar.bounds
                bar.removeAnimation(forKey: "level")
                bar.bounds = rest
                if animated {
                    let settle = CABasicAnimation(keyPath: "bounds")
                    settle.fromValue = NSValue(rect: current)
                    settle.toValue = NSValue(rect: rest)
                    settle.duration = 0.3
                    settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    bar.add(settle, forKey: "settle")
                }
            }
        }
        if let mask = waveMask {
            let rest = Self.wavePath(size: size, phase: 0, amplitude: size.height * 0.05)
            if isPlaying {
                let frames = 32
                let animation = CAKeyframeAnimation(keyPath: "path")
                animation.values = (0...frames).map { frame in
                    Self.wavePath(size: size, phase: Double(frame) / Double(frames) * 2 * .pi, amplitude: size.height * 0.38)
                }
                animation.duration = Self.waveLoop
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                animation.isRemovedOnCompletion = false
                mask.add(animation, forKey: "wave")
            } else {
                mask.removeAnimation(forKey: "wave")
                CATransaction.begin()
                CATransaction.setDisableActions(!animated)
                CATransaction.setAnimationDuration(0.3)
                mask.path = rest
                CATransaction.commit()
            }
        }
    }

    /// Same motion as before (two sines per bar), with frequencies rounded to whole cycles per loop.
    static func barLevel(index: Int, time: TimeInterval) -> Double {
        let cycles = [5.0, 7.0, 6.0, 8.0, 5.0, 7.0]           // per 6-second loop (≈ 5.1, 7.3, 6.2, 8.4 rad/s)
        let omega = 2 * .pi / barLoop
        let phase = Double(index) * 1.7
        let primary = 0.5 + 0.5 * sin(time * omega * cycles[index % cycles.count] + phase)
        let secondary = 0.5 + 0.5 * sin(time * omega * 2 + phase * 0.6)
        return 0.22 + 0.78 * (0.7 * primary + 0.3 * secondary)
    }

    /// The wave across the width: three half-cycles under a sine envelope (ends pinned to the middle).
    static func wavePath(size: CGSize, phase: Double, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let steps = max(Int(size.width.rounded(.up)), 8)
        for step in 0...steps {
            let x = size.width * CGFloat(step) / CGFloat(steps)
            let progress = Double(step) / Double(steps)
            let y = size.height / 2 + amplitude * CGFloat(sin(progress * .pi * 3 + phase) * sin(progress * .pi))
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
