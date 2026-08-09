import SwiftUI
import VibeStatusCore

struct OnboardingView: View {
    @Bindable var model: DashboardModel
    @State private var manualAlias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect remote hosts")
                        .font(.title2.weight(.semibold))
                    Text("Choose hosts from the SSH configuration already on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .liquidGlassPanel(cornerRadius: 18, tint: Color.accentColor.opacity(0.045))
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.secondary)

                        Text("No passwords or private keys are stored. Authentication, ProxyJump, and host-key verification remain managed by OpenSSH.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .liquidGlassPanel(cornerRadius: 15, tint: Color.green.opacity(0.035))

                    VStack(alignment: .leading, spacing: 7) {
                        Label("SSH Config", systemImage: "terminal")
                            .font(.headline)

                        if model.discoveredAliases.isEmpty {
                            Text("No literal SSH aliases were found. Add one manually below after configuring it in ~/.ssh/config.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(model.discoveredAliases, id: \.self) { alias in
                                    Button {
                                        model.addHost(alias: alias)
                                    } label: {
                                        Label(alias, systemImage: "plus")
                                    }
                                    .controlSize(.small)
                                    .liquidGlassButton()
                                    .disabled(
                                        model.hosts.contains(where: {
                                            $0.alias.caseInsensitiveCompare(alias) == .orderedSame
                                        })
                                    )
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Remote Hosts", systemImage: "server.rack")
                            .font(.headline)

                        if model.hosts.isEmpty {
                            Text("Select an SSH alias above or add one manually.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .liquidGlassPanel(cornerRadius: 14)
                        } else {
                            ForEach($model.hosts) { $host in
                                HostEditorRow(
                                    host: $host,
                                    validationState: model.validationStates[host.id] ?? .idle,
                                    validate: { model.validate(host: host) },
                                    invalidate: {
                                        model.invalidateValidation(hostID: host.id)
                                    },
                                    remove: {
                                        model.removeHost(id: host.id)
                                    }
                                )
                            }
                        }

                        if !model.enabledAliasesAreUnique {
                            Label(
                                "Each enabled remote host must use a unique SSH alias.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }

                    HStack {
                        TextField("Additional SSH alias", text: $manualAlias)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addManualAlias)

                        Button("Add", action: addManualAlias)
                            .liquidGlassButton()
                            .disabled(manualAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)

            HStack {
                Text("Test every enabled host first. Monitoring may start Codex’s existing app-server daemon, but never installs or updates Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Start Monitoring") {
                    model.completeOnboarding()
                }
                .liquidGlassButton(prominent: true)
                .disabled(!model.canCompleteOnboarding)
            }
            .padding(12)
            .liquidGlassPanel(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .task {
            model.discoverAliases()
        }
    }

    private func addManualAlias() {
        model.addHost(alias: manualAlias)
        manualAlias = ""
    }
}

struct HostEditorRow: View {
    @Binding var host: HostProfile
    let validationState: HostValidationState
    let validate: () -> Void
    let invalidate: () -> Void
    let remove: (() -> Void)?

    init(
        host: Binding<HostProfile>,
        validationState: HostValidationState,
        validate: @escaping () -> Void,
        invalidate: @escaping () -> Void,
        remove: (() -> Void)? = nil
    ) {
        _host = host
        self.validationState = validationState
        self.validate = validate
        self.invalidate = invalidate
        self.remove = remove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle("", isOn: $host.isEnabled)
                    .labelsHidden()

                TextField("SSH alias", text: $host.alias)
                    .textFieldStyle(.roundedBorder)

                Button("Test", action: validate)
                    .controlSize(.small)
                    .disabled(!host.isEnabled || host.alias.isEmpty || isValidating)

                if let remove {
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove remote host")
                }
            }

            HStack {
                TextField("Display name", text: $host.displayName)
                    .textFieldStyle(.roundedBorder)

                TextField(
                    "Auto-detect Codex, or enter its remote path",
                    text: $host.codexPath
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            validationLabel
                .padding(.leading, 25)
        }
        .padding(10)
        .liquidGlassPanel(cornerRadius: 14, tint: Color.accentColor.opacity(0.035))
        .onChange(of: host.alias) { _, _ in invalidate() }
        .onChange(of: host.codexPath) { _, _ in invalidate() }
        .onChange(of: host.isEnabled) { _, _ in invalidate() }
    }

    private var isValidating: Bool {
        validationState == .validating
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch validationState {
        case .idle:
            if host.codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Codex will be detected automatically. Enter an absolute path only if detection fails.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Using the configured remote executable path.")
                    .foregroundStyle(.secondary)
            }
        case .validating:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing non-interactive SSH…")
            }
        case let .valid(version, resolvedCodexPath):
            VStack(alignment: .leading, spacing: 2) {
                Label(version, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if host.codexPath.isEmpty, let resolvedCodexPath {
                    Text("Found at \(resolvedCodexPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case let .invalid(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var size = CGSize.zero
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + subviewSize.width > availableWidth {
                size.width = max(size.width, lineWidth)
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth == 0 ? 0 : spacing) + subviewSize.width
            lineHeight = max(lineHeight, subviewSize.height)
        }

        size.width = max(size.width, lineWidth)
        size.height += lineHeight
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: point,
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
