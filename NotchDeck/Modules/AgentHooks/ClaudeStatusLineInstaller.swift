import Foundation

/// Connects Claude Code's status line to NotchDeck, for live plan usage.
///
/// Claude Code passes its status line command a JSON snapshot after every response; for Pro / Max /
/// Ultra subscribers it includes `rate_limits.five_hour` / `seven_day` (`used_percentage` 0–100,
/// `resets_at` epoch seconds). That's the only documented live source of plan usage (hooks don't get
/// it, and the copy cached in `~/.claude.json` is only refreshed now and then).
///
/// NotchDeck installs a small script as the status line: it forwards the snapshot to NotchDeck's local
/// server (127.0.0.1, token-checked, in the background so it never slows Claude Code) and prints a
/// compact "Session 85% · Week 38%". A status line you already had is kept: the script runs it and
/// prints its output instead, and removing NotchDeck's restores it.
nonisolated enum ClaudeStatusLineInstaller {
    static let path = "/notchdeck/statusline"
    static let scriptName = "claude-statusline.sh"

    enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Another status line is configured (NotchDeck would wrap it).
        case otherStatusLine
        case unreadable(String)
    }

    static func defaultScriptURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "NotchDeck/\(scriptName)")
    }

    static func previousURL(scriptURL: URL) -> URL {
        scriptURL.deletingLastPathComponent().appending(path: "claude-statusline-previous.json")
    }

    /// The `statusLine.command` value: the script's absolute path, quoted (it contains a space).
    static func command(scriptURL: URL) -> String {
        "\"\(scriptURL.path)\""
    }

    static func isNotchDeck(_ statusLine: [String: Any]?) -> Bool {
        (statusLine?["command"] as? String)?.contains(scriptName) == true
    }

    static func status(of settings: [String: Any]) -> Status {
        let statusLine = settings["statusLine"] as? [String: Any]
        if isNotchDeck(statusLine) { return .installed }
        return statusLine == nil ? .notInstalled : .otherStatusLine
    }

    static func status(at settingsURL: URL) -> Status {
        do { return status(of: try AgentHookInstaller.readSettings(at: settingsURL)) } catch { return .unreadable(error.localizedDescription) }
    }

    /// POSIX single-quoted.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func script(port: Int, token: String, previousCommand: String?) -> String {
        let url = "http://127.0.0.1:\(port)\(path)"
        return """
        #!/bin/sh
        # Installed by NotchDeck (Settings → AI & Agents → Usage). Forwards Claude Code's status-line data,
        # including plan usage, to NotchDeck on this Mac, then prints the status line. Remove it there.
        input=$(cat)
        printf '%s' "$input" | /usr/bin/curl -s -m 1 -o /dev/null -X POST \\
          -H 'Content-Type: application/json' -H \(shellQuoted("\(AgentHookInstaller.tokenHeader): \(token)")) \\
          --data-binary @- \(shellQuoted(url)) >/dev/null 2>&1 &
        previous=\(shellQuoted(previousCommand ?? ""))
        if [ -n "$previous" ]; then
          printf '%s' "$input" | /bin/sh -c "$previous"
          exit 0
        fi
        if command -v jq >/dev/null 2>&1; then
          printf '%s' "$input" | jq -r '[(.rate_limits.five_hour.used_percentage // empty | "Session \\(floor)%"), (.rate_limits.seven_day.used_percentage // empty | "Week \\(floor)%")] | join(" · ")' 2>/dev/null
        fi
        exit 0

        """
    }

    static func installing(into settings: [String: Any], scriptURL: URL) -> [String: Any] {
        var settings = settings
        settings["statusLine"] = ["type": "command", "command": command(scriptURL: scriptURL), "padding": 0]
        return settings
    }

    /// Writes the script (owner-only: it holds the local token) and points Claude Code at it.
    static func install(settingsURL: URL, scriptURL: URL = defaultScriptURL(), port: Int, token: String) throws {
        let settings = try AgentHookInstaller.readSettings(at: settingsURL)
        let existing = settings["statusLine"] as? [String: Any]
        var previous: [String: Any]?
        if let existing, !isNotchDeck(existing) {
            previous = existing
            let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: previousURL(scriptURL: scriptURL), options: .atomic)
        } else if let saved = try? Data(contentsOf: previousURL(scriptURL: scriptURL)) {
            previous = try? JSONSerialization.jsonObject(with: saved) as? [String: Any]
        }
        try writeScript(at: scriptURL, port: port, token: token, previousCommand: previous?["command"] as? String)
        try AgentHookInstaller.writeSettings(installing(into: settings, scriptURL: scriptURL), to: settingsURL)
    }

    /// Keeps the script's port / token current (called when the hook server settings change).
    static func refreshScript(settingsURL: URL, scriptURL: URL = defaultScriptURL(), port: Int, token: String) {
        guard status(at: settingsURL) == .installed else { return }
        let previous = (try? Data(contentsOf: previousURL(scriptURL: scriptURL)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        try? writeScript(at: scriptURL, port: port, token: token, previousCommand: previous?["command"] as? String)
    }

    /// Removes NotchDeck's status line, restoring the one you had before (if any).
    static func uninstall(settingsURL: URL, scriptURL: URL = defaultScriptURL()) throws {
        var settings = try AgentHookInstaller.readSettings(at: settingsURL)
        guard isNotchDeck(settings["statusLine"] as? [String: Any]) else { return }
        let previousFile = previousURL(scriptURL: scriptURL)
        if let data = try? Data(contentsOf: previousFile), let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try AgentHookInstaller.writeSettings(settings, to: settingsURL)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: previousFile)
    }

    private static func writeScript(at url: URL, port: Int, token: String, previousCommand: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script(port: port, token: token, previousCommand: previousCommand).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
