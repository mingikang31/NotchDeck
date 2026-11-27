import SwiftUI

/// Expanded World Clock: an analog face per city (light by day, dark by night), with the day and
/// hour offset from here and the digital time. Cities are managed in Settings → Modules.
struct WorldClockModuleView: View {
    let tokens: ThemeTokens

    @Environment(SettingsStore.self) private var settings
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        let cities = settings.worldClockCities
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cities) { city in
                        CityClock(city: city, date: context.date, tokens: tokens)
                            .contextMenu {
                                Button("Move Left") { move(city, by: -1) }.disabled(cities.first == city)
                                Button("Move Right") { move(city, by: 1) }.disabled(cities.last == city)
                                Divider()
                                Button("Remove \(city.name)") { settings.worldClockCities.removeAll { $0 == city } }
                            }
                    }
                    Button { settingsOpener.open(.modules) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 58, height: 58)
                                .background(tokens.controlFill, in: Circle())
                            Text(cities.isEmpty ? "Add a city" : "Add")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add or remove cities in Settings → Modules → World Clock")
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private func move(_ city: WorldClockCity, by delta: Int) {
        var cities = settings.worldClockCities
        guard let index = cities.firstIndex(of: city) else { return }
        let target = min(max(index + delta, 0), cities.count - 1)
        cities.swapAt(index, target)
        settings.worldClockCities = cities
    }
}

private struct CityClock: View {
    let city: WorldClockCity
    let date: Date
    let tokens: ThemeTokens

    var body: some View {
        VStack(spacing: 4) {
            AnalogClockFace(date: date, timeZone: city.timeZone, isDay: city.isDaytime(at: date))
                .frame(width: 58, height: 58)
            Text(city.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 84)
            Text(city.relativeDescription(at: date))
                .font(.system(size: 9.5))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
            Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: city.timeZone)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .frame(width: 84)
        .accessibilityElement(children: .combine)
    }
}

/// Analog face: hour ticks, hour / minute hands and an orange second hand.
struct AnalogClockFace: View {
    let date: Date
    let timeZone: TimeZone
    let isDay: Bool

    var body: some View {
        let parts = components
        let face = isDay ? Color.white : Color(white: 0.12)
        let ink = isDay ? Color.black : Color.white
        ZStack {
            Circle().fill(face)
            Circle().strokeBorder(Color.white.opacity(isDay ? 0 : 0.18), lineWidth: 1)
            ForEach(0..<12, id: \.self) { tick in
                Capsule()
                    .fill(ink.opacity(tick % 3 == 0 ? 0.85 : 0.4))
                    .frame(width: tick % 3 == 0 ? 2 : 1.2, height: tick % 3 == 0 ? 6 : 4)
                    .offset(y: -23)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            Hand(length: 14, width: 3, color: ink, angle: (parts.hour + parts.minute / 60) * 30)
            Hand(length: 21, width: 2, color: ink, angle: (parts.minute + parts.second / 60) * 6)
            Hand(length: 22, width: 1, color: .orange, angle: parts.second * 6)
            Circle().fill(Color.orange).frame(width: 4, height: 4)
        }
    }

    private var components: (hour: Double, minute: Double, second: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (Double((c.hour ?? 0) % 12), Double(c.minute ?? 0), Double(c.second ?? 0))
    }
}

private struct Hand: View {
    let length: CGFloat
    let width: CGFloat
    let color: Color
    let angle: Double

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
    }
}
