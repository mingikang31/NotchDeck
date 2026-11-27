import SwiftUI

/// Expanded Agent Hooks: the approval card when Claude Code is waiting, otherwise status + activity.
struct AgentHooksModuleView: View {
    let tokens: ThemeTokens

    @Environment(AgentHookStore.self) private var hooks
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let approval = hooks.current {
                ApprovalCard(approval: approval, queued: hooks.pending.count - 1, tokens: tokens)
                    .id(approval.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                IdleAgentView(tokens: tokens) { settingsOpener.open(.aiAgents) }
            }
            // Live session tokens / estimated cost and MCP servers in use, next to the queue.
            AgentUsageStrip(tokens: tokens)
        }
    }
}

private struct ApprovalCard: View {
    let approval: PendingApproval
    let queued: Int
    let tokens: ThemeTokens

    @Environment(AgentHookStore.self) private var hooks

    var body: some View {
        let preview = approval.preview
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(approval.agent.displayName) wants to \(preview.title.prefix(1).lowercased() + preview.title.dropFirst())")
                        .font(.system(size: 13, weight: .semibold))
                    Text(approval.projectName.isEmpty ? approval.cwd : "\(approval.projectName) · \(approval.cwd)")
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if queued > 0 {
                    Text("+\(queued) waiting")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tokens.controlFill, in: Capsule())
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let primary = preview.primary {
                        Label {
                            Text(primary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: preview.symbol).foregroundStyle(tokens.secondaryText)
                        }
                    }
                    if let detail = preview.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(tokens.secondaryText)
                    }
                    if let diff = preview.diff, !diff.isEmpty {
                        DiffView(lines: diff)
                    }
                    if let body = preview.body {
                        Text(body)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Text(approval.canAlwaysAllow
                     ? "Esc deny · ⌘↩ approve · ⌘⇧↩ always · 2 min → terminal"
                     : "Esc deny · ⌘↩ approve · 2 min → terminal")
                    .font(.system(size: 9.5))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                Spacer()
                Button("Deny") { hooks.deny() }
                    .controlSize(.small)
                if approval.canAlwaysAllow {
                    Button("Always Allow") { hooks.alwaysApprove() }
                        .controlSize(.small)
                        .help("Approve and let Claude Code stop asking for this (its own suggested rule)")
                }
                Button("Approve") { hooks.approve() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
    }
}

private struct DiffView: View {
    let lines: [ToolPreview.DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(marker(line.kind)).frame(width: 10)
                    Text(line.text.isEmpty ? " " : line.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(line.kind))
                .foregroundStyle(line.kind == .context ? Color.white.opacity(0.6) : Color.white)
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func marker(_ kind: ToolPreview.DiffKind) -> String {
        switch kind {
        case .context: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private func background(_ kind: ToolPreview.DiffKind) -> Color {
        switch kind {
        case .context: Color.black.opacity(0.25)
        case .removed: Color.red.opacity(0.28)
        case .added: Color.green.opacity(0.25)
        }
    }
}

private struct IdleAgentView: View {
    let tokens: ThemeTokens
    let openSettings: () -> Void

    @Environment(AgentHookStore.self) private var hooks

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(statusTitle, systemImage: "circle.fill")
                    .labelStyle(StatusDotLabelStyle(color: statusColor))
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if connected.isEmpty || HookAgent.allCases.contains(where: { hooks.status(for: $0) == .needsUpdate }) {
                    Button("Set Up in Settings…", action: openSettings).controlSize(.small)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text("RECENT").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
                if hooks.activity.isEmpty {
                    Text("Approvals and finished tasks will appear here.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.secondaryText)
                }
                ForEach(hooks.activity.prefix(3)) { entry in
                    HStack(spacing: 5) {
                        Image(systemName: entry.symbol).font(.system(size: 10))
                        Text(entry.text).font(.system(size: 10.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connected: [HookAgent] { HookAgent.allCases.filter { hooks.status(for: $0) == .installed } }

    private var statusTitle: String {
        if case .failed = hooks.serverState { return "Hook server stopped" }
        guard !connected.isEmpty else { return "No coding agent connected" }
        guard case .running = hooks.serverState else { return "Starting…" }
        return "Watching " + connected.map(\.displayName).joined(separator: " and ")
    }

    private var statusDetail: String {
        if case .failed(let reason) = hooks.serverState { return reason }
        if let stale = HookAgent.allCases.first(where: { hooks.status(for: $0) == .needsUpdate }) {
            return "The \(stale.displayName) hook points at an old port. Update it in Settings → AI & Agents."
        }
        if let broken = HookAgent.allCases.compactMap({ agent -> String? in
            if case .unreadable(let reason) = hooks.status(for: agent) { return reason }
            return nil
        }).first { return broken }
        return connected.isEmpty
            ? "Install the Claude Code or Codex hook to approve tool use from the notch."
            : "Permission requests pop up here for Approve / Deny. When a task finishes, the notch chimes."
    }

    private var statusColor: Color {
        if case .failed = hooks.serverState { return .red }
        guard !connected.isEmpty, case .running = hooks.serverState else { return .orange }
        return .green
    }
}
