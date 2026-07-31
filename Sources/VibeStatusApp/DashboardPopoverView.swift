import SwiftUI
import VibeStatusCore

struct DashboardPopoverView: View {
    @Bindable var model: DashboardModel

    var body: some View {
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
        .frame(width: 400, height: 560)
        .background(.background)
    }
}

private struct DashboardView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model)
            Divider()

            if model.sessions.isEmpty && !model.hasIssues {
                ContentUnavailableView {
                    Label("No Loaded Tasks", systemImage: "terminal")
                } description: {
                    Text("Loaded Codex and Claude Code tasks on your enabled remote hosts will appear here.")
                } actions: {
                    Button("Refresh") {
                        model.refresh()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.hasIssues {
                            IssuesSection(model: model)
                        }

                        ForEach(TaskDisplayStatus.allCases, id: \.self) { status in
                            SessionGroup(
                                status: status,
                                sessions: model.sessions(for: status),
                                hostLabel: model.hostLabel(for:)
                            )
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            DashboardFooter()
        }
    }
}

private struct DashboardHeader: View {
    @Bindable var model: DashboardModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vibe Status")
                    .font(.headline)

                Text(connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isRefreshing ? .degrees(360) : .zero)
                    .animation(
                        model.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: model.isRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .help("Refresh all remote hosts")
            .disabled(model.isRefreshing)

            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var connectionSummary: String {
        let count = model.enabledHostCount
        return "\(count) enabled \(count == 1 ? "host" : "hosts")"
    }
}

private struct SessionGroup: View {
    let status: TaskDisplayStatus
    let sessions: [SessionSnapshot]
    let hostLabel: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)

                Text(status.displayName)
                    .font(.subheadline.weight(.semibold))

                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(status.displayName), \(sessions.count) tasks")

            if sessions.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 14)
            } else {
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

private struct SessionRow: View {
    let session: SessionSnapshot
    let hostLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(hostLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())

                    Label(session.agent.displayName, systemImage: session.agent.systemImage)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())

                    if let directoryName = session.workingDirectoryName {
                        Label(directoryName, systemImage: "folder")
                            .lineLimit(1)
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
        .padding(9)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
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
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardFooter: View {
    var body: some View {
        HStack {
            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
