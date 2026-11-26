import Foundation

nonisolated enum MeetingProvider: String, Sendable {
    case zoom, googleMeet, teams, webex

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Teams"
        case .webex: "Webex"
        }
    }
}

nonisolated struct MeetingLink: Equatable, Sendable {
    var provider: MeetingProvider
    var url: URL
}

/// Finds video-call links in an event's URL, location and notes.
nonisolated enum MeetingLinkParser {
    /// Returns the first meeting link across `texts`, in order (pass URL, location, notes).
    static func firstLink(in texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            if let link = link(in: text) { return link }
        }
        return nil
    }

    static func link(in text: String) -> MeetingLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let provider = provider(for: url) else { continue }
            return MeetingLink(provider: provider, url: normalized(url))
        }
        return nil
    }

    static func provider(for url: URL) -> MeetingProvider? {
        guard let host = url.host?.lowercased() else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("zoom.us") || matches("zoomgov.com") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        if matches("teams.microsoft.com") || matches("teams.live.com") { return .teams }
        if matches("webex.com") { return .webex }
        return nil
    }

    /// Data detectors return scheme-less matches as http; meeting services all serve https.
    private static func normalized(_ url: URL) -> URL {
        guard url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}
