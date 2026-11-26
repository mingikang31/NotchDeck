import Foundation

/// Coding agents NotchDeck can act as an approval gate for.
nonisolated enum HookAgent: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The file NotchDeck adds its hooks to.
    var defaultConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch self {
        case .claudeCode: home.appending(path: ".claude/settings.json")
        case .codex: home.appending(path: ".codex/hooks.json")
        }
    }

    /// The agent's config folder exists, so it's (very likely) installed.
    var isPresentOnThisMac: Bool {
        FileManager.default.fileExists(atPath: defaultConfigURL.deletingLastPathComponent().path)
    }

    /// Endpoint paths on the local hook server.
    var permissionPath: String {
        self == .codex ? "/notchdeck/codex/permission-request" : "/notchdeck/permission-request"
    }

    var stopPath: String {
        self == .codex ? "/notchdeck/codex/stop" : "/notchdeck/stop"
    }

    func permissionURL(port: Int) -> String { "http://127.0.0.1:\(port)\(permissionPath)" }
    func stopURL(port: Int) -> String { "http://127.0.0.1:\(port)\(stopPath)" }

    /// Maps a request path back to its agent and endpoint.
    static func route(_ path: String) -> (agent: HookAgent, isPermission: Bool)? {
        for agent in allCases {
            if path == agent.permissionPath { return (agent, true) }
            if path == agent.stopPath { return (agent, false) }
        }
        return nil
    }
}

/// Adds / removes NotchDeck's hooks in each agent's config file.
///
/// - **Claude Code** (`~/.claude/settings.json`): `http` hooks. Claude Code POSTs straight to NotchDeck.
/// - **Codex** (`~/.codex/hooks.json`): Codex supports only `command` hooks, so each hook is a single
///   `/usr/bin/curl` command that forwards the hook's JSON to NotchDeck and prints the decision. If
///   NotchDeck isn't running, curl prints nothing and exits 0, so Codex shows its normal prompt.
///
/// Every other key and hook in the files is preserved; NotchDeck's handlers are recognized by the
/// `/notchdeck/` path in their URL or command.
nonisolated enum AgentHookInstaller {
    static let pathMarker = "/notchdeck/"
    static let tokenHeader = "X-NotchDeck-Token"

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Installed, but for a different port or token (e.g. the port was changed).
        case needsUpdate
        case unreadable(String)
    }

    enum InstallError: LocalizedError {
        case unparseable(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unparseable(let path, let reason):
                "\(path) isn't valid JSON (\(reason)), so NotchDeck won't modify it. Fix the file and try again."
            }
        }
    }

    // MARK: Handlers

    private static func handler(for agent: HookAgent, url: String, token: String, timeout: Int, status: String?) -> [String: Any] {
        switch agent {
        case .claudeCode:
            var handler: [String: Any] = ["type": "http", "url": url, "headers": [tokenHeader: token], "timeout": timeout]
            if let status { handler["statusMessage"] = status }
            return handler
        case .codex:
            // -f: no output on HTTP errors; `Expect:` stops curl's 1 s "100-continue" wait on large bodies;
            // `|| true`: a missing NotchDeck is a silent no-op, never a failed hook.
            let command = "/usr/bin/curl -sf --max-time \(timeout - 10) -H 'Expect:' -H 'Content-Type: application/json' "
                + "-H '\(tokenHeader): \(token)' --data-binary @- \(url) || true"
            var handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
            if let status { handler["statusMessage"] = status }
            return handler
        }
    }

    // MARK: Pure transforms (unit-tested)

    /// `settings` with NotchDeck's PermissionRequest and Stop hooks (replacing any older NotchDeck entries).
    static func installing(into settings: [String: Any], agent: HookAgent, port: Int, token: String) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var permission = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permission.append([
            "matcher": "*",
            // The agents' default is 600 s; NotchDeck hands back to the terminal well before that.
            "hooks": [handler(for: agent, url: agent.permissionURL(port: port), token: token, timeout: 600,
                              status: "Waiting for approval in the notch…")],
        ])
        hooks["PermissionRequest"] = permission

        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        stop.append(["hooks": [handler(for: agent, url: agent.stopURL(port: port), token: token, timeout: 15, status: nil)]])
        hooks["Stop"] = stop

        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without any NotchDeck hook handlers; empty groups / events / `hooks` are dropped.
    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter { !isNotchDeck($0) }
                guard !kept.isEmpty else { return nil }
                var group = group
                group["hooks"] = kept
                return group
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        var settings = settings
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func status(of settings: [String: Any], port: Int, token: String) -> Status {
        let events = settings["hooks"] as? [String: Any] ?? [:]
        var installedEvents = Set<String>()
        var allCurrent = true
        for (event, value) in events {
            for group in value as? [[String: Any]] ?? [] {
                for handler in (group["hooks"] as? [[String: Any]] ?? []) where isNotchDeck(handler) {
                    installedEvents.insert(event)
                    if !isCurrent(handler, port: port, token: token) { allCurrent = false }
                }
            }
        }
        guard !installedEvents.isEmpty else { return .notInstalled }
        return allCurrent && installedEvents.isSuperset(of: ["PermissionRequest", "Stop"]) ? .installed : .needsUpdate
    }

    private static func handlerText(_ handler: [String: Any]) -> String {
        (handler["url"] as? String ?? "") + " " + (handler["command"] as? String ?? "")
    }

    private static func isNotchDeck(_ handler: [String: Any]) -> Bool {
        handlerText(handler).contains(pathMarker)
    }

    private static func isCurrent(_ handler: [String: Any], port: Int, token: String) -> Bool {
        let text = handlerText(handler)
        let headerToken = (handler["headers"] as? [String: String])?[tokenHeader]
        return text.contains("http://127.0.0.1:\(port)/") && (headerToken == token || text.contains("\(tokenHeader): \(token)"))
    }

    // MARK: File operations

    static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        let path = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unparseable(path: path, reason: "the top level isn't an object")
            }
            return object
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.unparseable(path: path, reason: error.localizedDescription)
        }
    }

    static func status(at url: URL, port: Int, token: String) -> Status {
        do {
            return status(of: try readSettings(at: url), port: port, token: token)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    static func install(at url: URL, agent: HookAgent, port: Int, token: String) throws {
        let current = try readSettings(at: url)
        try write(installing(into: current, agent: agent, port: port, token: token), to: url)
    }

    static func uninstall(at url: URL) throws {
        let current = try readSettings(at: url)
        try write(removing(from: current), to: url)
    }

    /// Backs up the existing file (`<name>.notchdeck-backup`), then writes atomically.
    private static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("notchdeck-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
