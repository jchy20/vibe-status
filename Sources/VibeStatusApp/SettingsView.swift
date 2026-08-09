import SwiftUI
import VibeStatusCore

struct SettingsView: View {
    @Bindable var model: DashboardModel
    @State private var hostToDelete: HostProfile?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    model.showDashboard()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .liquidGlassButton()

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("Settings")
                        .font(.headline)
                    Text("Remote monitoring")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlassPanel(cornerRadius: 17)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Remote Hosts", systemImage: "server.rack")
                            .font(.headline)

                        ForEach($model.hosts) { $host in
                            VStack(alignment: .trailing, spacing: 5) {
                                HostEditorRow(
                                    host: $host,
                                    validationState: model.validationStates[host.id] ?? .idle,
                                    validate: { model.validate(host: host) },
                                    invalidate: {
                                        model.invalidateValidation(hostID: host.id)
                                    }
                                )

                                Button("Remove", role: .destructive) {
                                    hostToDelete = host
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .padding(.trailing, 5)
                            }
                        }

                        Button {
                            model.showOnboarding()
                        } label: {
                            Label("Add from SSH Config", systemImage: "plus")
                        }
                        .liquidGlassButton()
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Toggle("Launch Vibe Status at login", isOn: $model.launchAtLogin)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.secondary)

                            Text("Session names, paths, statuses, and diagnostics stay in memory and are discarded when the app quits.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .liquidGlassPanel(cornerRadius: 16, tint: Color.green.opacity(0.035))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)

            HStack {
                Button("Quit Vibe Status") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Save") {
                    model.saveSettings()
                }
                .liquidGlassButton(prominent: true)
                .disabled(!model.canSaveSettings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassPanel(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .confirmationDialog(
            "Remove \(hostToDelete?.displayName ?? "remote host")?",
            isPresented: Binding(
                get: { hostToDelete != nil },
                set: { if !$0 { hostToDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard
                    let hostToDelete,
                    let index = model.hosts.firstIndex(of: hostToDelete)
                else {
                    return
                }
                model.removeHosts(at: IndexSet(integer: index))
                self.hostToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                hostToDelete = nil
            }
        }
    }
}
