import AppKit
import Observation
import OSLog

/// What an approval card shows for a tool call.
nonisolated struct ToolPreview: Equatable, Sendable {
    enum DiffKind: Equatable, Sendable { case context, removed, added }
    nonisolated struct DiffLine: Equatable, Sendable {
        var kind: DiffKind
        var text: String
    }

    var title: String
    var symbol: String
    /// Command, file path, URL or query.
    var primary: String?
    var detail: String?
    var diff: [DiffLine]?
    /// File content or the raw input as pretty JSON.
    var body: String?

    static func make(toolName: String, input: [String: Any]) -> ToolPreview {
        func string(_ key: String) -> String? { input[key] as? String }
        switch toolName {
        case "Bash", "shell", "local_shell", "exec_command", "container.exec":
            return ToolPreview(title: "Run a command", symbol: "terminal", primary: shellCommand(input["command"]), detail: string("description"))
        case "apply_patch":
            return patchPreview(string("command") ?? string("patch") ?? string("input") ?? "", description: string("description"))
        case "Edit":
            return ToolPreview(title: "Edit a file", symbol: "pencil", primary: string("file_path"),
                               diff: lineDiff(old: string("old_string") ?? "", new: string("new_string") ?? ""))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let diff = edits.flatMap { lineDiff(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "") }
            return ToolPreview(title: "Edit a file (\(edits.count) changes)", symbol: "pencil", primary: string("file_path"), diff: diff)
        case "Write":
            return ToolPreview(title: "Write a file", symbol: "doc.badge.plus", primary: string("file_path"),
                               body: (string("content")).map { truncated($0, lines: 80) })
        case "Read":
            return ToolPreview(title: "Read a file", symbol: "doc.text", primary: string("file_path"))
        case "NotebookEdit":
            return ToolPreview(title: "Edit a notebook", symbol: "book", primary: string("notebook_path"),
                               body: string("new_source").map { truncated($0, lines: 60) })
        case "WebFetch":
            return ToolPreview(title: "Fetch a web page", symbol: "globe", primary: string("url"), detail: string("prompt"))
        case "WebSearch":
            return ToolPreview(title: "Search the web", symbol: "magnifyingglass", primary: string("query"))
        default:
            let name = toolName.hasPrefix("mcp__") ? toolName.split(separator: "__").dropFirst().joined(separator: " → ") : toolName
            return ToolPreview(title: "Use \(name)", symbol: "wrench.and.screwdriver", body: prettyJSON(input))
        }
    }

    /// Codex sends shell commands either as a string or as an argv array (often `["bash", "-lc", "…"]`).
    static func shellCommand(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let argv = value as? [String], !argv.isEmpty else { return nil }
        if argv.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(argv[0]), ["-lc", "-c"].contains(argv[1]) {
            return argv[2...].joined(separator: " ")
        }
        return argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    /// Codex `apply_patch` envelopes: `*** Update File: path` / `*** Add File:` / `*** Delete File:` headers
    /// followed by `+` / `-` / ` ` lines.
    static func patchPreview(_ patch: String, description: String?) -> ToolPreview {
        var files: [String] = []
        var lines: [DiffLine] = []
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("*** ") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] where raw.hasPrefix(prefix) {
                    let file = String(raw.dropFirst(prefix.count))
                    files.append(prefix == "*** Delete File: " ? "\(file) (delete)" : file)
                    if prefix != "*** Move to: " { lines.append(DiffLine(kind: .context, text: "── \(file)")) }
                }
                continue
            }
            if raw.hasPrefix("@@") { lines.append(DiffLine(kind: .context, text: raw)); continue }
            if raw.hasPrefix("+") { lines.append(DiffLine(kind: .added, text: String(raw.dropFirst()))) }
            else if raw.hasPrefix("-") { lines.append(DiffLine(kind: .removed, text: String(raw.dropFirst()))) }
            else if raw.hasPrefix(" ") { lines.append(DiffLine(kind: .context, text: String(raw.dropFirst()))) }
        }
        let title = files.count > 1 ? "Edit \(files.count) files" : "Edit a file"
        return ToolPreview(title: title, symbol: "pencil", primary: files.isEmpty ? nil : files.joined(separator: "\n"),
                           detail: description, diff: lines.isEmpty ? nil : Array(lines.prefix(400)),
                           body: lines.isEmpty && !patch.isEmpty ? truncated(patch, lines: 80) : nil)
    }

    /// Old/new text as removed/added lines around the common unchanged lines (up to 2 lines of context).
    static func lineDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldLines.count, newLines.count) - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }

        var lines: [DiffLine] = []
        lines += oldLines[max(0, prefix - 2)..<prefix].map { DiffLine(kind: .context, text: $0) }
        lines += oldLines[prefix..<(oldLines.count - suffix)].map { DiffLine(kind: .removed, text: $0) }
        lines += newLines[prefix..<(newLines.count - suffix)].map { DiffLine(kind: .added, text: $0) }
        lines += newLines[(newLines.count - suffix)..<min(newLines.count, newLines.count - suffix + 2)].map { DiffLine(kind: .context, text: $0) }
        return lines
    }

    private static func truncated(_ text: String, lines: Int) -> String {
        let all = text.components(separatedBy: "\n")
        guard all.count > lines else { return text }
        return all.prefix(lines).joined(separator: "\n") + "\n… \(all.count - lines) more lines"
    }

    private static func prettyJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A Claude Code permission request waiting for the user.
final class PendingApproval: Identifiable {
    let id = UUID()
    let agent: HookAgent
    let toolName: String
    let preview: ToolPreview
    let cwd: String
    let receivedAt = Date()
    /// Claude Code's own "don't ask again" suggestions (`permission_suggestions`) with behavior allow.
    let allowSuggestions: [[String: Any]]
    fileprivate let exchange: HTTPExchange

    var projectName: String { (cwd as NSString).lastPathComponent }
    var canAlwaysAllow: Bool { !allowSuggestions.isEmpty }

    init(agent: HookAgent, toolName: String, preview: ToolPreview, cwd: String, allowSuggestions: [[String: Any]], exchange: HTTPExchange) {
        self.agent = agent
        self.toolName = toolName
        self.preview = preview
        self.cwd = cwd
        self.allowSuggestions = allowSuggestions
        self.exchange = exchange
    }
}

/// Claude Code integration: local hook server, approval queue, completion pulses, hook installer.
@Observable
final class AgentHookStore {
    enum Decision: Equatable {
        case approved, alwaysApproved, denied
        /// No answer: Claude Code shows its normal terminal prompt instead.
        case handedBack
        /// Claude Code stopped waiting (answered in the terminal, or timed out).
        case withdrawn
    }

    struct ActivityEntry: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var text: String
        var symbol: String
    }

    struct FinishedEvent: Equatable {
        var agent: HookAgent
        var project: String
        var message: String
        var date: Date
    }

    /// Unanswered requests are handed back to Claude Code's terminal prompt after this long.
    static let handBackAfter: Duration = .seconds(120)
    static let finishedPulseDuration: TimeInterval = 6

    private(set) var pending: [PendingApproval] = []
    private(set) var serverState: LocalHTTPServer.State = .stopped
    private(set) var hookStatus: [HookAgent: AgentHookInstaller.Status] = [:]
    private(set) var hookError: [HookAgent: String] = [:]
    private(set) var activity: [ActivityEntry] = []
    private(set) var lastFinished: FinishedEvent?

    var current: PendingApproval? { pending.first }

    /// Wired by the container: show the approval card / tuck the notch away again.
    @ObservationIgnored var onApprovalNeeded: () -> Void = {}
    @ObservationIgnored var onQueueEmptied: () -> Void = {}
    /// A Claude Code / Codex task finished (its usage log has new entries).
    @ObservationIgnored var onTaskFinished: () -> Void = {}

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let configURLs: [HookAgent: URL]
    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var observingPort = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "AgentHooks")

    init(settings: SettingsStore, configURLs: [HookAgent: URL] = [:]) {
        self.settings = settings
        self.configURLs = configURLs
        if settings.agentHookToken.isEmpty {
            settings.agentHookToken = Self.makeToken()
        }
        refreshHookStatus()
    }

    static func makeToken() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: Server lifecycle

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        logger.notice("Agent hooks \(active ? "starting" : "stopping", privacy: .public) (port \(self.settings.agentServerPort))")
        if active {
            startServer()
            if !observingPort {
                observingPort = true
                observeContinuously({ [weak self] in self?.settings.agentServerPort ?? 0 }) { [weak self] _ in
                    guard let self, self.isActive else { return }
                    self.startServer()
                    self.refreshHookStatus()
                }
            }
        } else {
            pending.forEach { finish($0, .handedBack) }
            server?.stop()
            server = nil
            serverState = .stopped
        }
    }

    private func startServer() {
        server?.stop()
        let server = LocalHTTPServer(handler: { [weak self] exchange in
            Task { @MainActor in self?.handle(exchange) }
        }, stateChanged: { [weak self] state in
            Task { @MainActor in
                self?.serverState = state
                self?.logger.notice("Hook server: \(String(describing: state), privacy: .public)")
            }
        })
        server.start(port: UInt16(clamping: settings.agentServerPort))
        self.server = server
    }

    // MARK: Requests

    func handle(_ exchange: HTTPExchange) {
        let request = exchange.request
        guard request.method == "POST" else { return exchange.respond(.json(["error": "POST only"], status: 400)) }
        guard request.headers[AgentHookInstaller.tokenHeader.lowercased()] == settings.agentHookToken else {
            logger.notice("Rejected hook request with a missing or wrong token")
            return exchange.respond(.json(["error": "Forbidden"], status: 403))
        }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard let route = HookAgent.route(request.path) else {
            return exchange.respond(.json(["error": "Not found"], status: 404))
        }
        if route.isPermission {
            enqueue(json, agent: route.agent, exchange: exchange)
        } else {
            exchange.respond(.empty)
            finished(json, agent: route.agent)
        }
    }

    private func enqueue(_ json: [String: Any], agent: HookAgent, exchange: HTTPExchange) {
        let toolName = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let suggestions = (json["permission_suggestions"] as? [[String: Any]] ?? []).filter { $0["behavior"] as? String == "allow" }
        let approval = PendingApproval(
            agent: agent,
            toolName: toolName,
            preview: .make(toolName: toolName, input: input),
            cwd: json["cwd"] as? String ?? "",
            allowSuggestions: suggestions,
            exchange: exchange
        )
        pending.append(approval)
        let id = approval.id
        exchange.onCancel { [weak self] in
            Task { @MainActor in self?.withdraw(id) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.handBackAfter)
            guard let self, let approval = self.pending.first(where: { $0.id == id }) else { return }
            self.finish(approval, .handedBack)
        }
        onApprovalNeeded()
    }

    private func withdraw(_ id: PendingApproval.ID) {
        guard let approval = pending.first(where: { $0.id == id }) else { return }
        finish(approval, .withdrawn)
    }

    // MARK: Decisions

    /// What a key press does while an approval card is showing (nil = not ours).
    enum KeyAction: Equatable { case approve, alwaysApprove, deny }

    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyAction? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        let isReturn = keyCode == 36 || keyCode == 76 // Return, keypad Enter
        switch (keyCode, mods) {
        case (53, []): return .deny                                    // Esc
        case _ where isReturn && mods == [.command]: return .approve   // ⌘↩
        case _ where isReturn && mods == [.command, .shift]: return .alwaysApprove // ⌘⇧↩
        default: return nil
        }
    }

    func perform(_ action: KeyAction) {
        switch action {
        case .approve: approve()
        case .alwaysApprove: alwaysApprove()
        case .deny: deny()
        }
    }

    func approve() { if let current { finish(current, .approved) } }
    func alwaysApprove() { if let current, current.canAlwaysAllow { finish(current, .alwaysApproved) } }
    func deny() { if let current { finish(current, .denied) } }
    func handBack() { if let current { finish(current, .handedBack) } }

    /// The JSON Claude Code expects from a PermissionRequest hook (nil = empty body, no decision).
    static func responseBody(for decision: Decision, allowSuggestions: [[String: Any]]) -> [String: Any]? {
        let behavior: [String: Any]
        switch decision {
        case .approved:
            behavior = ["behavior": "allow"]
        case .alwaysApproved:
            behavior = ["behavior": "allow", "updatedPermissions": allowSuggestions]
        case .denied:
            behavior = ["behavior": "deny", "message": "The user denied this from NotchDeck."]
        case .handedBack, .withdrawn:
            return nil
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": behavior]]
    }

    private func finish(_ approval: PendingApproval, _ decision: Decision) {
        guard let index = pending.firstIndex(where: { $0.id == approval.id }) else { return }
        pending.remove(at: index)
        if decision != .withdrawn {
            let body = Self.responseBody(for: decision, allowSuggestions: approval.allowSuggestions)
            approval.exchange.respond(body.map { HTTPResponse.json($0) } ?? .empty)
        }
        let verb = switch decision {
        case .approved: "Approved"
        case .alwaysApproved: "Always allowed"
        case .denied: "Denied"
        case .handedBack: "Handed back to the terminal"
        case .withdrawn: "Answered in the terminal"
        }
        let symbol = switch decision {
        case .approved, .alwaysApproved: "checkmark.circle"
        case .denied: "xmark.circle"
        case .handedBack, .withdrawn: "arrow.uturn.left.circle"
        }
        log("\(verb): \(approval.agent.displayName) · \(approval.preview.title.lowercased()) · \(approval.projectName)", symbol: symbol)
        if pending.isEmpty { onQueueEmptied() }
    }

    // MARK: Completion

    private func finished(_ json: [String: Any], agent: HookAgent) {
        let cwd = json["cwd"] as? String ?? ""
        let event = FinishedEvent(
            agent: agent,
            project: cwd.isEmpty ? agent.displayName : (cwd as NSString).lastPathComponent,
            message: (json["last_assistant_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            date: Date()
        )
        lastFinished = event
        onTaskFinished()
        log("\(agent.displayName) finished · \(event.project)", symbol: "sparkles")
        if settings.agentChimeEnabled { NSSound(named: "Glass")?.play() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedPulseDuration))
            if self?.lastFinished == event { self?.lastFinished = nil }
        }
    }

    /// Whether the collapsed "Claude finished" pulse should still show.
    var isShowingFinishedPulse: Bool {
        guard let lastFinished else { return false }
        return Date().timeIntervalSince(lastFinished.date) < Self.finishedPulseDuration
    }

    private func log(_ text: String, symbol: String) {
        activity.insert(ActivityEntry(date: Date(), text: text, symbol: symbol), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }

    // MARK: Hook installation

    func configURL(for agent: HookAgent) -> URL { configURLs[agent] ?? agent.defaultConfigURL }

    func refreshHookStatus() {
        for agent in HookAgent.allCases {
            hookStatus[agent] = AgentHookInstaller.status(at: configURL(for: agent), port: settings.agentServerPort, token: settings.agentHookToken)
        }
    }

    func status(for agent: HookAgent) -> AgentHookInstaller.Status { hookStatus[agent] ?? .notInstalled }

    /// At least one agent is wired to NotchDeck.
    var isAnyHookInstalled: Bool { HookAgent.allCases.contains { status(for: $0) == .installed } }

    func installHook(_ agent: HookAgent) {
        do {
            try AgentHookInstaller.install(at: configURL(for: agent), agent: agent, port: settings.agentServerPort, token: settings.agentHookToken)
            hookError[agent] = nil
        } catch {
            hookError[agent] = error.localizedDescription
        }
        refreshHookStatus()
    }

    func uninstallHook(_ agent: HookAgent) {
        do {
            try AgentHookInstaller.uninstall(at: configURL(for: agent))
            hookError[agent] = nil
        } catch {
            hookError[agent] = error.localizedDescription
        }
        refreshHookStatus()
    }

    /// Sends a sample request through the real server, exactly as Claude Code would.
    func sendTestRequest(as agent: HookAgent = .claudeCode) {
        let port = settings.agentServerPort
        let token = settings.agentHookToken
        Task.detached {
            guard let url = URL(string: agent.permissionURL(port: port)) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: AgentHookInstaller.tokenHeader)
            let sample: [String: Any] = [
                "hook_event_name": "PermissionRequest",
                "cwd": FileManager.default.homeDirectoryForCurrentUser.appending(path: "NotchDeck-test").path,
                "tool_name": "Bash",
                "tool_input": ["command": "echo \"Hello from NotchDeck\"", "description": "Test request (nothing will run)"],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: sample)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
