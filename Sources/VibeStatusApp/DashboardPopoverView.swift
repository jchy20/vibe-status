import SwiftUI
import VibeStatusCore

struct DashboardPopoverView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            Group {
                switch model.destination {
                case .dashboard:
                    DashboardView(model: model)
                case .onboarding:
                    OnboardingView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
        }
        .frame(width: 400, height: 560)
    }
}

private struct DashboardView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                UsageSummary(
                    usage: model.usage,
                    hostLabel: model.hostLabel(for:)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .liquidGlassPanel(
                    cornerRadius: 18,
                    tint: Color.accentColor.opacity(0.05)
                )

                if model.sessions.isEmpty && !model.hasIssues {
                    ContentUnavailableView {
                        Label("No Loaded Tasks", systemImage: "terminal")
                    } description: {
                        Text("Loaded Codex and Claude Code tasks on your enabled remote hosts will appear here.")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .liquidGlassPanel(cornerRadius: 20)
                } else {
                    StatusOverview(model: model)

                    if model.hasIssues {
                        IssuesSection(model: model)
                    }

                    ForEach(nonemptyStatuses, id: \.self) { status in
                        SessionGroup(
                            status: status,
                            sessions: model.sessions(for: status),
                            hostLabel: model.hostLabel(for:)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .dashboardScrollSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DashboardFooter(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var nonemptyStatuses: [TaskDisplayStatus] {
        TaskDisplayStatus.allCases.filter { !model.sessions(for: $0).isEmpty }
    }
}

private extension View {
    @ViewBuilder
    func dashboardScrollSurface() -> some View {
        if #available(macOS 26.0, *) {
            scrollContentBackground(.hidden)
                .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            scrollContentBackground(.hidden)
        }
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    var rotation: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 15, height: 15)
                .rotationEffect(.degrees(rotation))
                .animation(
                    isDisabled
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: rotation
                )
        }
        .liquidGlassButton(isCircular: true)
        .help(help)
        .disabled(isDisabled)
    }
}

private struct UsageSummary: View {
    let usage: [UsageWindowSnapshot]
    let hostLabel: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Usage remaining", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))

            if groups.isEmpty {
                Text("Waiting for provider data…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Label(group.agent.displayName, systemImage: group.agent.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        if groupCount(for: group.agent) > 1 {
                            Text(groupLabel(group))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 2)

                        HStack(spacing: 9) {
                            ForEach(group.windows) { window in
                                UsageMeter(window: window)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groups: [UsageGroup] {
        let values = Dictionary(grouping: usage) {
            UsageGroupKey(
                scopeID: $0.accountScopeID ?? "host:\($0.hostID)",
                agent: $0.agent
            )
        }
        return values.map { key, windows in
            UsageGroup(
                scopeID: key.scopeID,
                hostIDs: Set(windows.map(\.hostID)),
                agent: key.agent,
                windows: windows.sorted {
                    $0.windowDurationMinutes < $1.windowDurationMinutes
                }
            )
        }.sorted {
            if $0.agent != $1.agent {
                return $0.agent == .codex
            }
            return $0.scopeID.localizedStandardCompare($1.scopeID) == .orderedAscending
        }
    }

    private func groupCount(for agent: AgentKind) -> Int {
        groups.count { $0.agent == agent }
    }

    private func groupLabel(_ group: UsageGroup) -> String {
        guard let hostID = group.displayHostID else {
            return "Shared account"
        }
        return hostLabel(hostID)
    }
}

private struct UsageGroupKey: Hashable {
    let scopeID: String
    let agent: AgentKind
}

private struct UsageGroup: Identifiable {
    let scopeID: String
    let hostIDs: Set<String>
    let agent: AgentKind
    let windows: [UsageWindowSnapshot]

    var id: String { "\(scopeID):\(agent.rawValue)" }

    var displayHostID: String? {
        hostIDs.count == 1 ? hostIDs.first : nil
    }
}

private struct UsageMeter: View {
    let window: UsageWindowSnapshot

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Text(windowLabel)
                    .foregroundStyle(.secondary)
                Text(percentageLabel)
                    .fontWeight(.semibold)
            }
            .font(.caption2.monospacedDigit())

            ProgressView(value: window.remainingPercentage, total: 100)
                .progressViewStyle(.linear)
                .tint(meterColor)
                .frame(width: 76)
        }
        .help(resetDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(windowLabel), \(Int(window.remainingPercentage.rounded())) percent remaining, \(resetDescription)"
        )
    }

    private var windowLabel: String {
        let minutes = window.windowDurationMinutes
        if minutes == 7 * 24 * 60 { return "Week" }
        if minutes.isMultiple(of: 24 * 60) {
            return "\(minutes / (24 * 60))d"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private var percentageLabel: String {
        "\(Int(window.remainingPercentage.rounded()))%"
    }

    private var meterColor: Color {
        switch window.remainingPercentage {
        case ..<15: .red
        case ..<35: .orange
        default: .accentColor
        }
    }

    private var resetDescription: String {
        "Resets \(window.resetsAt.formatted(.relative(presentation: .named)))"
    }
}

private struct StatusOverview: View {
    @Bindable var model: DashboardModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TaskDisplayStatus.allCases, id: \.self) { status in
                StatusSummaryCard(
                    status: status,
                    count: model.sessions(for: status).count
                )
            }
        }
    }
}

private struct StatusSummaryCard: View {
    let status: TaskDisplayStatus
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                StatusDot(color: status.color, size: 7)

                Text(status.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Text("\(count)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .liquidGlassPanel(cornerRadius: 15, tint: status.color.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.displayName), \(count) tasks")
    }
}

private struct SessionGroup: View {
    let status: TaskDisplayStatus
    let sessions: [SessionSnapshot]
    let hostLabel: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: status.color, size: 8)

                Text(status.displayName)
                    .font(.subheadline.weight(.semibold))

                Text("\(sessions.count) \(sessions.count == 1 ? "task" : "tasks")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(status.displayName), \(sessions.count) tasks")

            LiquidGlassContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            hostLabel: hostLabel(session.hostID)
                        )
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSnapshot
    let hostLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: session.status.color, size: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    MetadataPill(hostLabel)

                    MetadataPill(
                        session.agent.displayName,
                        systemImage: session.agent.systemImage
                    )

                    if let directoryName = session.workingDirectoryName {
                        MetadataPill(directoryName, systemImage: "folder")
                    }

                    Spacer(minLength: 0)

                    if session.status != .ready {
                        Text(session.updatedAt, style: .relative)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .liquidGlassPanel(
            cornerRadius: 15,
            tint: session.status.color.opacity(0.055)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let summary = "\(session.name), \(session.agent.displayName), "
            + "\(session.status.displayName), \(hostLabel)"
        guard session.status != .ready else { return summary }
        return "\(summary), updated \(session.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

private struct MetadataPill: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.065), in: Capsule())
    }
}

private struct StatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: size + 7, height: size + 7)
            }
    }
}

private struct IssuesSection: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Issues", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            if let transientIssue = model.transientIssue {
                IssueRow(hostID: nil, message: transientIssue, retry: nil)
            }

            ForEach(model.issues) { issue in
                IssueRow(
                    hostID: "\(model.hostLabel(for: issue.hostID)) · \(issue.agent.displayName)",
                    message: issue.message,
                    retry: { model.retry(hostID: issue.hostID) }
                )
            }
        }
    }
}

private struct IssueRow: View {
    let hostID: String?
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let hostID {
                    Text(hostID)
                        .font(.caption.weight(.semibold))
                }

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
                    .liquidGlassButton()
            }
        }
        .padding(10)
        .liquidGlassPanel(cornerRadius: 14, tint: Color.orange.opacity(0.09))
    }
}

private struct DashboardFooter: View {
    @Bindable var model: DashboardModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)

            Text(
                "Monitoring \(model.sessions.count) "
                    + "\(model.sessions.count == 1 ? "task" : "tasks")"
            )

            Spacer()

            GlassIconButton(
                systemName: "arrow.clockwise",
                help: "Refresh all remote hosts",
                isDisabled: model.isRefreshing,
                rotation: model.isRefreshing ? 360 : 0
            ) {
                model.refresh()
            }

            GlassIconButton(systemName: "gearshape", help: "Settings") {
                model.showSettings()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassPanel(cornerRadius: 14)
    }
}

struct LiquidGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.13),
                    Color.clear,
                    Color.purple.opacity(colorScheme == .dark ? 0.16 : 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(colorScheme == .dark ? 0.13 : 0.09))
                .frame(width: 250, height: 250)
                .blur(radius: 65)
                .offset(x: 150, y: -245)

            Circle()
                .fill(Color.indigo.opacity(colorScheme == .dark ? 0.14 : 0.07))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -170, y: 235)
        }
        .ignoresSafeArea()
    }
}

struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
        }
    }
}

private struct LiquidGlassButtonModifier: ViewModifier {
    let isCircular: Bool
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(isCircular ? .circle : .capsule)
            } else {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(isCircular ? .circle : .capsule)
            }
        } else {
            if prominent {
                content
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(isCircular ? .circle : .capsule)
            } else {
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(isCircular ? .circle : .capsule)
            }
        }
    }
}

extension View {
    func liquidGlassPanel(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil
    ) -> some View {
        modifier(LiquidGlassPanelModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func liquidGlassButton(
        isCircular: Bool = false,
        prominent: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassButtonModifier(
                isCircular: isCircular,
                prominent: prominent
            )
        )
    }
}

private extension AgentKind {
    var systemImage: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "sparkles"
        }
    }
}

private extension TaskDisplayStatus {
    var color: Color {
        switch self {
        case .needsAttention:
            Color(nsColor: StatusPalette.needsAttention)
        case .working:
            Color(nsColor: StatusPalette.working)
        case .ready:
            Color(nsColor: StatusPalette.ready)
        }
    }
}
