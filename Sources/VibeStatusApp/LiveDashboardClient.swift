import Foundation
import Network
import VibeStatusCore

/// App-facing coordinator for the per-host supervisors.
///
/// The engine is the sole source of UI snapshots. Reconfiguration replaces
/// supervisors only when their profile changed, and every supervisor creates a
/// fresh transport/RPC client for each reconnect generation.
actor LiveDashboardClient: DashboardClient {
    private struct Entry {
        let profile: HostProfile
        let codexSupervisor: ClusterSupervisor
        let claudeSupervisor: ClaudeStatusSupervisor
    }

    private let engine = MonitoringEngine()
    private let hostValidator = SSHHostValidator()
    private let aliasDiscovery = SSHConfigAliasDiscovery()
    private let clientVersion: String

    private var entries: [String: Entry] = [:]
    private var configuredHosts: [HostProfile] = []
    private var isStarted = false
    private var isSuspended = false
    private var networkAvailable = true
    private var pathMonitor: NWPathMonitor?

    init(clientVersion: String = "0.1.0") {
        self.clientVersion = clientVersion
    }

    func snapshots() async -> AsyncStream<DashboardSnapshot> {
        await engine.snapshots()
    }

    func start(hosts: [HostProfile]) async {
        configuredHosts = hosts
        guard !isStarted else {
            await applyConfiguration()
            return
        }
        isStarted = true
        startPathMonitor()
        await applyConfiguration()
    }

    func reconfigure(hosts: [HostProfile]) async {
        configuredHosts = hosts
        guard isStarted else { return }
        await applyConfiguration()
    }

    func refresh() async {
        guard isStarted, !isSuspended, networkAvailable else { return }
        for entry in entries.values {
            await stop(entry)
            await start(entry)
        }
    }

    func retry(hostID: String) async {
        guard isStarted, !isSuspended, networkAvailable,
              let entry = entries[hostID]
        else {
            return
        }
        await stop(entry)
        await start(entry)
    }

    func stop() async {
        isStarted = false
        pathMonitor?.cancel()
        pathMonitor = nil
        let existing = entries.values
        entries.removeAll()
        for entry in existing {
            await stop(entry)
        }
    }

    func suspend() async {
        guard !isSuspended else { return }
        isSuspended = true
        for entry in entries.values {
            await entry.codexSupervisor.suspend()
            await entry.claudeSupervisor.suspend()
        }
    }

    func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        guard isStarted, networkAvailable else { return }
        for entry in entries.values {
            await start(entry)
        }
    }

    func discoverSSHAliases() async -> [String] {
        (try? aliasDiscovery.discover()) ?? []
    }

    func validate(host: HostProfile) async -> HostValidationResult {
        do {
            let result = try await hostValidator.validate(host)
            if let version = Self.semanticVersion(in: result.codexVersion) {
                let baseline = [0, 145, 0]
                if version.lexicographicallyPrecedes(baseline) {
                    return HostValidationResult(
                        isValid: false,
                        version: result.codexVersion,
                        message: "Codex CLI 0.145.0 or newer is required.",
                        resolvedCodexPath: result.resolvedCodexPath
                    )
                }
                let suffix = version == baseline
                    ? ""
                    : " — newer protocol, not yet tested"
                return HostValidationResult(
                    isValid: true,
                    version: result.codexVersion + suffix,
                    message: result.diagnostics.isEmpty ? nil : result.diagnostics,
                    resolvedCodexPath: result.resolvedCodexPath
                )
            }
            return HostValidationResult(
                isValid: true,
                version: result.codexVersion,
                message: result.diagnostics.isEmpty ? nil : result.diagnostics,
                resolvedCodexPath: result.resolvedCodexPath
            )
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return HostValidationResult(
                isValid: false,
                version: nil,
                message: detail,
                resolvedCodexPath: nil
            )
        }
    }

    private static func semanticVersion(in value: String) -> [Int]? {
        guard let match = value.firstMatch(
            of: /(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)/
        ) else {
            return nil
        }
        return [
            Int(match.output.major) ?? 0,
            Int(match.output.minor) ?? 0,
            Int(match.output.patch) ?? 0,
        ]
    }

    private func applyConfiguration() async {
        let enabledHosts = configuredHosts.filter(\.isEnabled)
        let desired = Dictionary(
            enabledHosts.map { ($0.alias, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        for (alias, entry) in entries
        where desired[alias] == nil || desired[alias] != entry.profile {
            await stop(entry)
            entries.removeValue(forKey: alias)
        }

        for profile in enabledHosts where entries[profile.alias] == nil {
            let version = clientVersion
            let codexSupervisor = ClusterSupervisor(
                hostID: profile.alias,
                engine: engine,
                sessionFactory: {
                    let transport = NIOWebSocketTextTransport(profile: profile)
                    return CodexRPCClient(
                        transport: transport,
                        clientInformation: .init(version: version)
                    )
                }
            )
            let claudeSupervisor = ClaudeStatusSupervisor(
                hostID: profile.alias,
                engine: engine,
                loader: SSHClaudeStatusLoader(alias: profile.alias)
            )
            let entry = Entry(
                profile: profile,
                codexSupervisor: codexSupervisor,
                claudeSupervisor: claudeSupervisor
            )
            entries[profile.alias] = entry
            if networkAvailable, !isSuspended {
                await start(entry)
            } else {
                await engine.markHostDisconnected(
                    hostID: profile.alias,
                    message: networkAvailable
                        ? "\(profile.alias) is paused while this Mac sleeps."
                        : "\(profile.alias) is paused while the network is offline."
                )
            }
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task {
                await self?.setNetworkAvailable(available)
            }
        }
        let queueLabel = "\(Bundle.main.bundleIdentifier ?? "VibeStatus").network"
        monitor.start(queue: DispatchQueue(label: queueLabel))
        pathMonitor = monitor
    }

    private func setNetworkAvailable(_ available: Bool) async {
        guard networkAvailable != available else { return }
        networkAvailable = available

        if available {
            guard isStarted, !isSuspended else { return }
            for entry in entries.values {
                await start(entry)
            }
        } else {
            for entry in entries.values {
                await entry.codexSupervisor.suspend()
                await entry.claudeSupervisor.suspend()
                await engine.markHostDisconnected(
                    hostID: entry.profile.alias,
                    message: "\(entry.profile.alias) is paused while the network is offline."
                )
            }
        }
    }

    private func start(_ entry: Entry) async {
        await entry.codexSupervisor.start()
        await entry.claudeSupervisor.start()
    }

    private func stop(_ entry: Entry) async {
        await entry.codexSupervisor.stop(removeHost: true)
        await entry.claudeSupervisor.stop(removeHost: true)
    }
}
