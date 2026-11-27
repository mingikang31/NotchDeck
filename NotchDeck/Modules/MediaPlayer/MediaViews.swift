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
struct AudioVisualizer: View {
    let isPlaying: Bool
    let style: VisualizerStyle
    let colors: [Color]
    var barCount = 4

    var body: some View {
        if style != .off {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                GeometryReader { proxy in
                    switch style {
                    case .bars: bars(t: t, size: proxy.size)
                    case .wave: wave(t: t, size: proxy.size)
                    case .off: EmptyView()
                    }
                }
            }
            .animation(.easeOut(duration: 0.3), value: isPlaying)
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: colors.isEmpty ? [.white] : colors, startPoint: .top, endPoint: .bottom)
    }

    private func level(_ index: Int, _ t: TimeInterval) -> Double {
        guard isPlaying else { return 0.18 }
        let speeds = [5.1, 7.3, 6.2, 8.4, 5.7, 6.9]
        let phase = Double(index) * 1.7
        let primary = 0.5 + 0.5 * sin(t * speeds[index % speeds.count] + phase)
        let secondary = 0.5 + 0.5 * sin(t * 2.3 + phase * 0.6)
        return 0.22 + 0.78 * (0.7 * primary + 0.3 * secondary)
    }

    private func bars(t: TimeInterval, size: CGSize) -> some View {
        let spacing: CGFloat = 2
        let width = max(1, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        return HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(gradient)
                    .frame(width: width, height: max(width, size.height * level(index, t)))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func wave(t: TimeInterval, size: CGSize) -> some View {
        Path { path in
            let amplitude = size.height * (isPlaying ? 0.38 : 0.05)
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            for x in stride(from: 0, through: size.width, by: 1) {
                let progress = x / max(size.width, 1)
                let y = size.height / 2 + amplitude * sin(progress * .pi * 3 + t * 6) * sin(progress * .pi)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
