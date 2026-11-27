import Foundation

/// A city on the world clock.
nonisolated struct WorldClockCity: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var timeZoneID: String

    var id: String { "\(timeZoneID)|\(name)" }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// Today / Tomorrow / Yesterday relative to here, plus the offset ("Today, +3HRS").
    func relativeDescription(at date: Date, local: TimeZone = .current, calendar: Calendar = .current) -> String {
        let offset = timeZone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        var there = calendar
        there.timeZone = timeZone
        var here = calendar
        here.timeZone = local
        let thereDay = there.dateComponents([.year, .month, .day], from: date)
        let hereDay = here.dateComponents([.year, .month, .day], from: date)
        let dayShift = here.dateComponents([.day], from: here.date(from: hereDay) ?? date, to: here.date(from: thereDay) ?? date).day ?? 0
        let day = switch dayShift {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: dayShift > 0 ? "+\(dayShift) days" : "\(dayShift) days"
        }
        guard offset != 0 else { return day }
        let hours = Double(offset) / 3600
        let amount = hours == hours.rounded() ? "\(Int(abs(hours)))" : String(format: "%.1f", abs(hours)).replacingOccurrences(of: ".5", with: "½")
        return "\(day), \(offset > 0 ? "+" : "−")\(amount)HR\(abs(hours) == 1 ? "" : "S")"
    }

    /// Hour 6:00–17:59 there draws the light (day) face.
    func isDaytime(at date: Date, calendar: Calendar = .current) -> Bool {
        var there = calendar
        there.timeZone = timeZone
        let hour = there.component(.hour, from: date)
        return (6..<18).contains(hour)
    }
}

/// Cities to search: every time zone's own city, plus well-known cities that share another
/// city's zone (San Francisco → Los Angeles time, Mumbai → Kolkata, …).
nonisolated enum CityCatalog {
    static let aliases: [(String, String)] = [
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"), ("San Diego", "America/Los_Angeles"),
        ("Cupertino", "America/Los_Angeles"), ("Las Vegas", "America/Los_Angeles"), ("Portland", "America/Los_Angeles"),
        ("Boston", "America/New_York"), ("Washington, D.C.", "America/New_York"), ("Miami", "America/New_York"),
        ("Atlanta", "America/New_York"), ("Philadelphia", "America/New_York"), ("Austin", "America/Chicago"),
        ("Dallas", "America/Chicago"), ("Houston", "America/Chicago"), ("Salt Lake City", "America/Denver"),
        ("Montreal", "America/Toronto"), ("Rio de Janeiro", "America/Sao_Paulo"), ("Beijing", "Asia/Shanghai"),
        ("Shenzhen", "Asia/Shanghai"), ("Mumbai", "Asia/Kolkata"), ("New Delhi", "Asia/Kolkata"),
        ("Bangalore", "Asia/Kolkata"), ("Hyderabad", "Asia/Kolkata"), ("Osaka", "Asia/Tokyo"), ("Kyoto", "Asia/Tokyo"),
        ("Busan", "Asia/Seoul"), ("Hanoi", "Asia/Bangkok"), ("Abu Dhabi", "Asia/Dubai"), ("Tel Aviv", "Asia/Jerusalem"),
        ("Munich", "Europe/Berlin"), ("Frankfurt", "Europe/Berlin"), ("Barcelona", "Europe/Madrid"), ("Milan", "Europe/Rome"),
        ("Geneva", "Europe/Zurich"), ("Edinburgh", "Europe/London"), ("Manchester", "Europe/London"),
        ("St. Petersburg", "Europe/Moscow"), ("Cape Town", "Africa/Johannesburg"), ("Wellington", "Pacific/Auckland"),
        ("Canberra", "Australia/Sydney"),
    ]

    static let all: [WorldClockCity] = {
        let zoneCities = TimeZone.knownTimeZoneIdentifiers.compactMap { id -> WorldClockCity? in
            let parts = id.split(separator: "/")
            guard parts.count >= 2, !["Etc", "SystemV", "US", "Canada", "Mexico", "Brazil", "Chile"].contains(String(parts[0])) else { return nil }
            return WorldClockCity(name: cityName(for: id), timeZoneID: id)
        }
        return (zoneCities + aliases.map { WorldClockCity(name: $0.0, timeZoneID: $0.1) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires".
    static func cityName(for timeZoneID: String) -> String {
        (timeZoneID.split(separator: "/").last.map(String.init) ?? timeZoneID).replacingOccurrences(of: "_", with: " ")
    }

    /// Region shown under a search result ("America", "Europe", …).
    static func region(for timeZoneID: String) -> String {
        timeZoneID.split(separator: "/").first.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? ""
    }

    static func search(_ query: String, limit: Int = 8) -> [WorldClockCity] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix = all.filter { $0.name.range(of: trimmed, options: options.union(.anchored)) != nil }
        let contains = all.filter { $0.name.range(of: trimmed, options: options) != nil && !prefix.contains($0) }
        return Array((prefix + contains).prefix(limit))
    }

    /// Here, plus three well-spread cities.
    static var defaults: [WorldClockCity] {
        let local = TimeZone.current.identifier
        var cities = [WorldClockCity(name: cityName(for: local), timeZoneID: local)]
        for (name, id) in [("New York", "America/New_York"), ("London", "Europe/London"), ("Tokyo", "Asia/Tokyo")] where id != local {
            cities.append(WorldClockCity(name: name, timeZoneID: id))
        }
        return cities
    }
}
