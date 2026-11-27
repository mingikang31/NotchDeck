import SwiftUI

private enum UsagePalette {
    static let accent = Color(red: 0.20, green: 0.55, blue: 0.93)   // #338CED, magnitude
    static let track = accent.opacity(0.18)
}

/// Expanded Usage: tokens and cost per source (AI Chat, Claude Code, Codex), by model, plan limits,
/// and configured MCP servers.
struct UsageModuleView: View {
    let tokens: ThemeTokens

    @Environment(UsageStore.self) private var usage
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        @Bindable var usage = usage
        let range = usage.range
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Range", selection: $usage.range) {
                    ForEach(UsageStore.Range.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                if let refreshed = usage.lastRefresh {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.secondaryText)
                }
                NotchIconButton(symbol: "arrow.clockwise", help: "Refresh now", tokens: tokens) {
                    Task { await usage.refresh() }
                }
                .disabled(usage.isRefreshing)
                NotchIconButton(symbol: "dollarsign.circle", help: "Prices (Settings → Modules → Usage)", tokens: tokens) {
                    settingsOpener.open(.modules)
                }
            }

            HStack(spacing: 8) {
                ForEach(UsageSource.allCases) { source in
                    SourceCard(source: source, totals: usage.totals(for: source, in: range), tokens: tokens)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ModelBreakdown(models: usage.modelTotals(in: range), tokens: tokens)
                    LimitsSection(tokens: tokens)
                    MCPSection(tokens: tokens)
                    Text("Claude Code and Codex costs are estimates at API list prices (subscriptions aren't billed per token). "
                         + "Read from ~/.claude and ~/.codex on this Mac; nothing is uploaded.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
        }
        .onAppear { usage.viewAppeared() }
        .onDisappear { usage.viewDisappeared() }
    }
}

private struct SourceCard: View {
    let source: UsageSource
    let totals: UsageStore.Totals
    let tokens: ThemeTokens

    var body: some View {
        NotchCard(tokens: tokens) {
            VStack(alignment: .leading, spacing: 3) {
                NotchSectionHeader(title: source.displayName, symbol: source.symbol, tokens: tokens)
                Text(UsageFormat.cost(totals, estimate: source.costIsEstimate))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(totals.requests == 0 ? tokens.secondaryText : tokens.primaryText)
                    .help(totals.hasUnpriced ? "Some models have no price yet. Add one in Settings → Modules → Usage." : "")
                Text("\(UsageFormat.tokens(totals.tokens.total)) tokens · \(totals.requests) \(source == .codex ? "turns" : "requests")")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
                Text("in \(UsageFormat.tokens(totals.tokens.input)) · cache \(UsageFormat.tokens(totals.tokens.cacheRead + totals.tokens.cacheWrite5m + totals.tokens.cacheWrite1h)) · out \(UsageFormat.tokens(totals.tokens.output))")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// Meter rows by model: share of the range's tokens, with tokens and cost.
private struct ModelBreakdown: View {
    let models: [UsageStore.ModelTotals]
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("BY MODEL").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
            if models.isEmpty {
                Text("No usage in this range yet.").font(.system(size: 10.5)).foregroundStyle(tokens.secondaryText)
            }
            let largest = max(models.first?.totals.tokens.total ?? 1, 1)
            ForEach(models.prefix(6)) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.source.symbol).font(.system(size: 9)).frame(width: 14).foregroundStyle(tokens.secondaryText)
                    Text(row.model).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(width: 170, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(UsagePalette.track)
                            Capsule().fill(UsagePalette.accent)
                                .frame(width: max(4, proxy.size.width * CGFloat(row.totals.tokens.total) / CGFloat(largest)))
                        }
                    }
                    .frame(height: 6)
                    Text(UsageFormat.tokens(row.totals.tokens.total))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    Text(UsageFormat.cost(row.totals, estimate: row.source.costIsEstimate))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }
}

private struct LimitsSection: View {
    let tokens: ThemeTokens

    @Environment(UsageStore.self) private var usage

    var body: some View {
        let claude = usage.currentClaudeLimit()
        let codex = usage.codexPlan
        if claude != nil || codex != nil {
            VStack(alignment: .leading, spacing: 5) {
                Text("PLAN LIMITS").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
                if let claude {
                    HStack(spacing: 6) {
                        Image(systemName: claude.status == "rejected" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(claude.status == "rejected" ? NotchStatusColor.critical : NotchStatusColor.warning)
                        Text("Claude Code: \(claude.status == "rejected" ? "\(claude.kindDescription) reached" : "close to the \(claude.kindDescription)")"
                             + (claude.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                            .font(.system(size: 10.5))
                    }
                }
                if let codex, let window = codex.primary {
                    PlanWindowRow(label: "Codex\(codex.plan.map { " (\($0) plan)" } ?? "")", window: window, tokens: tokens)
                    if let secondary = codex.secondary {
                        PlanWindowRow(label: "Codex", window: secondary, tokens: tokens)
                    }
                }
            }
        }
    }
}

private struct PlanWindowRow: View {
    let label: String
    let window: CodexPlanStatus.Window
    let tokens: ThemeTokens

    var body: some View {
        let fraction = min(max(window.usedPercent / 100, 0), 1)
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10.5)).frame(width: 120, alignment: .leading).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsagePalette.track)
                    Capsule().fill(fraction >= 0.9 ? NotchStatusColor.critical : fraction >= 0.75 ? NotchStatusColor.warning : UsagePalette.accent)
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text("\(Int(window.usedPercent.rounded()))% of \(window.description)"
                 + (window.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
    }
}

private struct MCPSection: View {
    let tokens: ThemeTokens

    @Environment(UsageStore.self) private var usage

    var body: some View {
        let active = Set(usage.activeSessions().flatMap(\.mcpUsed))
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP SERVERS").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
            if usage.mcpServers.isEmpty {
                Text("None configured for Claude Code or Codex.").font(.system(size: 10.5)).foregroundStyle(tokens.secondaryText)
            }
            ForEach(usage.mcpServers) { server in
                HStack(spacing: 6) {
                    Circle()
                        .fill(active.contains(server.name) ? NotchStatusColor.good : tokens.secondaryText.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(server.name).font(.system(size: 10.5, weight: .medium))
                    Text("\(server.agent.displayName) · \(server.scope) · \(server.transport)")
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.secondaryText)
                    Spacer()
                    if active.contains(server.name) {
                        Text("used this session").font(.system(size: 9.5)).foregroundStyle(NotchStatusColor.good)
                    }
                }
            }
        }
    }
}

/// One-line usage summary shown under the agent approval queue.
struct AgentUsageStrip: View {
    let tokens: ThemeTokens

    @Environment(UsageStore.self) private var usage

    var body: some View {
        let sessions = usage.activeSessions()
        let claude = usage.totals(for: .claudeCode, in: .today)
        let codex = usage.totals(for: .codex, in: .today)
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.fill").font(.system(size: 9)).foregroundStyle(tokens.secondaryText)
            if let session = sessions.first {
                Text("\(session.source.displayName) · \(session.project ?? "session"): \(UsageFormat.tokens(session.totals.tokens.total)) tok \(UsageFormat.cost(session.totals, estimate: true))")
                    .lineLimit(1)
                if !session.mcpUsed.isEmpty {
                    Text("MCP: \(session.mcpUsed.prefix(3).joined(separator: ", "))")
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text("Today: Claude Code \(UsageFormat.tokens(claude.tokens.total)) \(UsageFormat.cost(claude, estimate: true)) · Codex \(UsageFormat.tokens(codex.tokens.total))")
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
            if let plan = usage.codexPlan?.primary {
                Text("plan \(Int(plan.usedPercent.rounded()))%")
                    .foregroundStyle(tokens.secondaryText)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .onAppear { usage.viewAppeared() }
        .onDisappear { usage.viewDisappeared() }
        .help("Estimated at API list prices. Full breakdown in the Usage tab.")
    }
}
