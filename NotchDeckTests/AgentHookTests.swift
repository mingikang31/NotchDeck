import Foundation
import Testing
@testable import NotchDeck

// MARK: - HTTP parsing

struct HTTPParsingTests {
    @Test func parsesHeadersAndBodyOnceComplete() {
        let raw = "POST /notchdeck/stop HTTP/1.1\r\nHost: 127.0.0.1\r\nX-NotchDeck-Token: abc\r\nContent-Length: 11\r\n\r\n{\"a\":true}\n"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/notchdeck/stop")
        #expect(request.headers["x-notchdeck-token"] == "abc")
        #expect(request.body == Data("{\"a\":true}\n".utf8))
    }

    @Test func waitsForTheWholeBody() {
        let partial = "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        #expect(HTTPRequest.parse(Data(partial.utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-".utf8)) == .incomplete)
    }

    @Test func rejectsOversizedBodies() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes + 1)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .invalid("Body too large"))
    }

    @Test func emptyResponseMeansNoDecision() {
        let text = String(decoding: HTTPResponse.empty.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(!text.contains("Content-Type"))
    }
}

// MARK: - Installer

struct ClaudeHookInstallerTests {
    private let claude = HookAgent.claudeCode
    private let existing: [String: Any] = [
        "model": "opus",
        "permissions": ["allow": ["Bash(npm test)"]],
        "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/guard.sh"]]]],
            "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
        ],
    ]

    @Test func installKeepsEverythingElse() throws {
        let installed = AgentHookInstaller.installing(into: existing, agent: claude, port: 49152, token: "t1")
        #expect(installed["model"] as? String == "opus")
        #expect((installed["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(npm test)"])
        let hooks = try #require(installed["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)          // user's + NotchDeck's
        let permission = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let handler = try #require((permission["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "http")
        #expect(handler["url"] as? String == "http://127.0.0.1:49152/notchdeck/permission-request")
        #expect((handler["headers"] as? [String: String])?["X-NotchDeck-Token"] == "t1")
        #expect(handler["onFailure"] == nil) // never block Claude Code if NotchDeck is away
        #expect(AgentHookInstaller.status(of: installed, port: 49152, token: "t1") == .installed)
    }

    @Test func reinstallReplacesInsteadOfDuplicating() throws {
        let once = AgentHookInstaller.installing(into: existing, agent: claude, port: 49152, token: "t1")
        #expect(AgentHookInstaller.status(of: once, port: 50000, token: "t1") == .needsUpdate)
        let twice = AgentHookInstaller.installing(into: once, agent: claude, port: 50000, token: "t1")
        let hooks = try #require(twice["hooks"] as? [String: Any])
        #expect((hooks["PermissionRequest"] as? [[String: Any]])?.count == 1)
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
        #expect(AgentHookInstaller.status(of: twice, port: 50000, token: "t1") == .installed)
    }

    @Test func uninstallRestoresTheOriginalHooks() throws {
        let removed = AgentHookInstaller.removing(from: AgentHookInstaller.installing(into: existing, agent: claude, port: 49152, token: "t1"))
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse", "Stop"])
        #expect(AgentHookInstaller.status(of: removed, port: 49152, token: "t1") == .notInstalled)
        #expect(AgentHookInstaller.removing(from: AgentHookInstaller.installing(into: [:], agent: claude, port: 1, token: "x"))["hooks"] == nil)
    }

    @Test func fileInstallBacksUpAndRefusesBrokenJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "settings.json")

        try AgentHookInstaller.install(at: file, agent: claude, port: 49152, token: "t1")   // no file yet: created
        #expect(AgentHookInstaller.status(at: file, port: 49152, token: "t1") == .installed)
        try AgentHookInstaller.uninstall(at: file)
        #expect(FileManager.default.fileExists(atPath: file.path + ".notchdeck-backup"))

        try Data("{ not json".utf8).write(to: file)
        #expect(throws: AgentHookInstaller.InstallError.self) {
            try AgentHookInstaller.install(at: file, agent: claude, port: 49152, token: "t1")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json") // untouched
    }
}

// MARK: - Previews & decisions

struct ApprovalPreviewTests {
    @Test func bashAndEditPreviews() {
        let bash = ToolPreview.make(toolName: "Bash", input: ["command": "rm -rf node_modules", "description": "Clean"])
        #expect(bash.primary == "rm -rf node_modules")
        #expect(bash.detail == "Clean")

        let edit = ToolPreview.make(toolName: "Edit", input: [
            "file_path": "/p/a.swift", "old_string": "let a = 1\nlet b = 2\nlet c = 3", "new_string": "let a = 1\nlet b = 20\nlet c = 3",
        ])
        #expect(edit.primary == "/p/a.swift")
        #expect(edit.diff?.map(\.kind) == [.context, .removed, .added, .context])
        #expect(edit.diff?.filter { $0.kind == .added }.map(\.text) == ["let b = 20"])
    }

    @Test func mcpToolsShowServerAndToolAndJSON() {
        let preview = ToolPreview.make(toolName: "mcp__github__create_issue", input: ["title": "Bug"])
        #expect(preview.title == "Use github → create_issue")
        #expect(preview.body?.contains("\"title\" : \"Bug\"") == true)
    }

    @Test func cardKeyBindings() {
        #expect(AgentHookStore.keyAction(keyCode: 53, modifiers: []) == .deny)                       // Esc
        #expect(AgentHookStore.keyAction(keyCode: 36, modifiers: .command) == .approve)              // ⌘↩
        #expect(AgentHookStore.keyAction(keyCode: 76, modifiers: .command) == .approve)              // ⌘ keypad Enter
        #expect(AgentHookStore.keyAction(keyCode: 36, modifiers: [.command, .shift]) == .alwaysApprove)
        #expect(AgentHookStore.keyAction(keyCode: 36, modifiers: []) == nil)                         // plain Return: ignored
        #expect(AgentHookStore.keyAction(keyCode: 53, modifiers: .command) == nil)
        #expect(AgentHookStore.keyAction(keyCode: 36, modifiers: [.command, .capsLock]) == .approve) // Caps Lock doesn't matter
    }

    @Test func decisionBodiesMatchClaudeCodeSchema() throws {
        let allow = try #require(AgentHookStore.responseBody(for: .approved, allowSuggestions: []))
        let allowDecision = try #require((allow["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect((allow["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "PermissionRequest")
        #expect(allowDecision["behavior"] as? String == "allow")

        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                   "rules": [["toolName": "Bash", "ruleContent": "npm test"]]]
        let always = try #require(AgentHookStore.responseBody(for: .alwaysApproved, allowSuggestions: [rule]))
        let alwaysDecision = try #require((always["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect((alwaysDecision["updatedPermissions"] as? [[String: Any]])?.count == 1)

        let deny = try #require(AgentHookStore.responseBody(for: .denied, allowSuggestions: []))
        let denyDecision = try #require((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(denyDecision["behavior"] as? String == "deny")
        #expect(denyDecision["message"] as? String != nil)

        #expect(AgentHookStore.responseBody(for: .handedBack, allowSuggestions: []) == nil)
    }
}

// MARK: - End to end through the real loopback server

struct AgentHookServerTests {
    private func makeStore() -> (AgentHookStore, SettingsStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchDeckHooks.\(UUID().uuidString)")!)
        settings.agentServerPort = Int.random(in: 51_000...59_000)
        settings.agentChimeEnabled = false
        let dir = FileManager.default.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        let urls: [HookAgent: URL] = [.claudeCode: dir.appending(path: "claude/settings.json"), .codex: dir.appending(path: "codex/hooks.json")]
        return (AgentHookStore(settings: settings, configURLs: urls), settings)
    }

    private func waitForServer(_ store: AgentHookStore) async {
        for _ in 0..<200 {
            if case .running = store.serverState { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func post(_ path: String, port: Int, token: String, body: [String: Any]) -> Task<(Int, Data), Error> {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return Task.detached {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-NotchDeck-Token")
            request.httpBody = payload
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    private let bashRequest: [String: Any] = [
        "hook_event_name": "PermissionRequest", "cwd": "/Users/me/project", "tool_name": "Bash",
        "tool_input": ["command": "npm test"],
        "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                    "rules": [["toolName": "Bash", "ruleContent": "npm test"]]]],
    ]

    private func waitForPending(_ store: AgentHookStore, count: Int) async {
        for _ in 0..<300 where store.pending.count != count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func approvalRoundTrip() async throws {
        let (store, settings) = makeStore()
        var opened = 0
        store.onApprovalNeeded = { opened += 1 }
        store.setActive(true)
        defer { store.setActive(false) }
        await waitForServer(store)

        let call = post("/notchdeck/permission-request", port: settings.agentServerPort, token: settings.agentHookToken, body: bashRequest)
        await waitForPending(store, count: 1)
        #expect(opened == 1)
        #expect(store.current?.preview.primary == "npm test")
        #expect(store.current?.projectName == "project")
        #expect(store.current?.canAlwaysAllow == true)

        store.alwaysApprove()
        let (status, data) = try await call.value
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decision = try #require((json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedPermissions"] as? [[String: Any]])?.first?["destination"] as? String == "localSettings")
        #expect(store.pending.isEmpty)
        #expect(store.activity.first?.text.hasPrefix("Always allowed") == true)
    }

    @Test func denyAndQueueOrdering() async throws {
        let (store, settings) = makeStore()
        store.setActive(true)
        defer { store.setActive(false) }
        await waitForServer(store)

        let first = post("/notchdeck/permission-request", port: settings.agentServerPort, token: settings.agentHookToken, body: bashRequest)
        await waitForPending(store, count: 1)
        var second = bashRequest
        second["tool_input"] = ["command": "git push"]
        let next = post("/notchdeck/permission-request", port: settings.agentServerPort, token: settings.agentHookToken, body: second)
        await waitForPending(store, count: 2)

        store.deny()
        let denied = try JSONSerialization.jsonObject(with: try await first.value.1) as? [String: Any]
        #expect(((denied?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String == "deny")
        #expect(store.current?.preview.primary == "git push")

        store.handBack()
        let (status, body) = try await next.value
        #expect(status == 200)
        #expect(body.isEmpty) // no decision: Claude Code asks in the terminal
    }

    @Test func wrongTokenIsRefused() async throws {
        let (store, settings) = makeStore()
        store.setActive(true)
        defer { store.setActive(false) }
        await waitForServer(store)
        let (status, _) = try await post("/notchdeck/permission-request", port: settings.agentServerPort, token: "nope", body: bashRequest).value
        #expect(status == 403)
        #expect(store.pending.isEmpty)
    }

    @Test func requestIsWithdrawnWhenClaudeCodeHangsUp() async throws {
        let (store, settings) = makeStore()
        store.setActive(true)
        defer { store.setActive(false) }
        await waitForServer(store)
        let call = post("/notchdeck/permission-request", port: settings.agentServerPort, token: settings.agentHookToken, body: bashRequest)
        await waitForPending(store, count: 1)
        call.cancel()
        await waitForPending(store, count: 0)
        #expect(store.pending.isEmpty)
        #expect(store.activity.first?.text.hasPrefix("Answered in the terminal") == true)
    }

    @Test func stopEventPulsesAndAnswersImmediately() async throws {
        let (store, settings) = makeStore()
        store.setActive(true)
        defer { store.setActive(false) }
        await waitForServer(store)
        let (status, body) = try await post("/notchdeck/stop", port: settings.agentServerPort, token: settings.agentHookToken,
                                            body: ["hook_event_name": "Stop", "cwd": "/Users/me/notchdeck", "last_assistant_message": "All done."]).value
        #expect(status == 200)
        #expect(body.isEmpty)
        for _ in 0..<100 where store.lastFinished == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.lastFinished?.project == "notchdeck")
        #expect(store.lastFinished?.message == "All done.")
    }
}

// MARK: - Codex

struct CodexHookTests {
    @Test func installWritesCurlCommandHooksAndKeepsOthers() throws {
        let existing: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "^Bash$", "hooks": [["type": "command", "command": "python3 policy.py"]]]]]]
        let installed = AgentHookInstaller.installing(into: existing, agent: .codex, port: 47823, token: "tok")
        let hooks = try #require(installed["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        let handler = try #require(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        let command = try #require(handler["command"] as? String)
        #expect(command.hasPrefix("/usr/bin/curl -sf"))
        #expect(command.contains("http://127.0.0.1:47823/notchdeck/codex/permission-request"))
        #expect(command.contains("X-NotchDeck-Token: tok"))
        #expect(command.hasSuffix("|| true"))
        #expect(AgentHookInstaller.status(of: installed, port: 47823, token: "tok") == .installed)
        #expect(AgentHookInstaller.status(of: installed, port: 47823, token: "other") == .needsUpdate)

        let again = AgentHookInstaller.installing(into: installed, agent: .codex, port: 47900, token: "tok")
        #expect(((again["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.count == 1)
        let removed = AgentHookInstaller.removing(from: again)
        #expect(Set((removed["hooks"] as? [String: Any] ?? [:]).keys) == ["PreToolUse"])
    }

    @Test func routesDistinguishAgents() {
        #expect(HookAgent.route("/notchdeck/permission-request")! == (HookAgent.claudeCode, true))
        #expect(HookAgent.route("/notchdeck/codex/stop")! == (HookAgent.codex, false))
        #expect(HookAgent.route("/notchdeck/other") == nil)
    }

    @Test func codexShellAndPatchPreviews() {
        #expect(ToolPreview.shellCommand(["bash", "-lc", "git status && ls"]) == "git status && ls")
        #expect(ToolPreview.shellCommand(["rg", "-n", "two words"]) == "rg -n 'two words'")
        #expect(ToolPreview.make(toolName: "Bash", input: ["command": "make test"]).primary == "make test")

        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@ func run()
         let a = 1
        -let b = 2
        +let b = 3
        *** Add File: README.md
        +# Hello
        *** End Patch
        """
        let preview = ToolPreview.make(toolName: "apply_patch", input: ["command": patch])
        #expect(preview.title == "Edit 2 files")
        #expect(preview.primary == "Sources/App.swift\nREADME.md")
        #expect(preview.diff?.filter { $0.kind == .added }.map(\.text) == ["let b = 3", "# Hello"])
        #expect(preview.diff?.filter { $0.kind == .removed }.map(\.text) == ["let b = 2"])
    }

    /// Runs the exact command the installer writes for Codex, the way Codex runs it: hook JSON on stdin,
    /// decision JSON expected on stdout.
    private func runInstalledCommand(port: Int, token: String, stdin: [String: Any]) async throws -> (status: Int32, stdout: String) {
        let settings = AgentHookInstaller.installing(into: [:], agent: .codex, port: port, token: token)
        let command = try #require(((((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"]) as? [[String: Any]])?.first?["command"] as? String)
        let input = try JSONSerialization.data(withJSONObject: stdin)
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let inPipe = Pipe(), outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            inPipe.fileHandleForWriting.write(input)
            try inPipe.fileHandleForWriting.close()
            let output = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }.value
    }

    private let codexRequest: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/Users/me/api", "model": "gpt-5",
        "tool_name": "Bash", "tool_input": ["command": ["bash", "-lc", "npm publish"], "description": "Publish the package"],
    ]

    @Test func installedCommandRoundTripsADecision() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchDeckCodex.\(UUID().uuidString)")!)
        settings.agentServerPort = Int.random(in: 51_000...59_000)
        settings.agentChimeEnabled = false
        let store = AgentHookStore(settings: settings, configURLs: [:])
        store.setActive(true)
        defer { store.setActive(false) }
        for _ in 0..<200 { if case .running = store.serverState { break }; try? await Task.sleep(for: .milliseconds(10)) }

        let run = Task { try await runInstalledCommand(port: settings.agentServerPort, token: settings.agentHookToken, stdin: codexRequest) }
        for _ in 0..<300 where store.pending.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.current?.agent == .codex)
        #expect(store.current?.preview.primary == "npm publish")
        #expect(store.current?.canAlwaysAllow == false) // Codex sends no permission_suggestions
        store.deny()

        let (status, stdout) = try await run.value
        #expect(status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let decision = (json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
    }

    @Test func installedCommandIsSilentWhenNotchDeckIsAway() async throws {
        // Nothing listens on this port: curl must print nothing and exit 0, so Codex shows its own prompt.
        let (status, stdout) = try await runInstalledCommand(port: Int.random(in: 40_000...40_999), token: "t", stdin: codexRequest)
        #expect(status == 0)
        #expect(stdout.isEmpty)
    }
}
