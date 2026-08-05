import Foundation
import Observation
import ServiceManagement
import VibeStatusCore

enum HostValidationState: Equatable, Sendable {
    case idle
    case validating
    case valid(version: String, resolvedCodexPath: String?)
    case invalid(message: String)

    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }
}

struct HostValidationResult: Equatable, Sendable {
    var isValid: Bool
    var version: String?
    var message: String?
    var resolvedCodexPath: String? = nil
}

protocol DashboardClient: Sendable {
    func snapshots() async -> AsyncStream<DashboardSnapshot>
    func start(hosts: [HostProfile]) async
    func reconfigure(hosts: [HostProfile]) async
    func refresh() async
    func retry(hostID: String) async
    func suspend() async
    func resume() async
    func stop() async
    func discoverSSHAliases() async -> [String]
    func validate(host: HostProfile) async -> HostValidationResult
}

struct UnconfiguredDashboardClient: DashboardClient {
    func snapshots() async -> AsyncStream<DashboardSnapshot> {
        AsyncStream { _ in }
    }

    func start(hosts: [HostProfile]) async {}
    func reconfigure(hosts: [HostProfile]) async {}
    func refresh() async {}
    func retry(hostID: String) async {}
    func suspend() async {}
    func resume() async {}
    func stop() async {}
    func discoverSSHAliases() async -> [String] { [] }

    func validate(host: HostProfile) async -> HostValidationResult {
        HostValidationResult(
            isValid: false,
            message: "The monitoring service has not been configured."
        )
    }
}

@MainActor
@Observable
final class DashboardModel {
    enum Destination: Equatable {
        case dashboard
        case onboarding
        case settings
    }

    private enum DefaultsKey {
        static let onboardingComplete = "onboardingComplete.v1"
    }

    private(set) var snapshot: DashboardSnapshot?
    private(set) var validationStates: [UUID: HostValidationState] = [:]
    private(set) var discoveredAliases: [String] = []
    private(set) var isRefreshing = false
    private(set) var transientIssue: String?

    var hosts: [HostProfile]
    var destination: Destination
    var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            updateLaunchAtLogin()
        }
    }

    private let client: any DashboardClient
    private let defaults: UserDefaults
    private let configurationStore: UserDefaultsConfigurationStore
    private var monitoringTask: Task<Void, Never>?

    init(
        client: any DashboardClient,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        configurationStore = UserDefaultsConfigurationStore(userDefaults: defaults)

        let configuration = (try? configurationStore.load()) ?? .empty
        hosts = configuration.hosts

        let onboardingComplete = defaults.bool(forKey: DefaultsKey.onboardingComplete)
        destination = onboardingComplete && Self.isUsable(configuration)
            ? .dashboard
            : .onboarding
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var sessions: [SessionSnapshot] {
        snapshot?.sessions ?? []
    }

    var issues: [HostIssue] {
        snapshot?.issues ?? []
    }

    var usage: [UsageWindowSnapshot] {
        snapshot?.usage ?? []
    }

    var menuBarCounts: StatusCounts {
        snapshot?.counts ?? .zero
    }

    var enabledHostCount: Int {
        hosts.count(where: \.isEnabled)
    }

    var hasIssues: Bool {
        !issues.isEmpty || transientIssue != nil
    }

    var canCompleteOnboarding: Bool {
        let enabledHosts = hosts.filter(\.isEnabled)
        guard !enabledHosts.isEmpty, enabledAliasesAreUnique else {
            return false
        }
        return enabledHosts.allSatisfy {
            SSHInputValidator.isValidAlias($0.alias)
                && validationStates[$0.id]?.isValid == true
        }
    }

    var enabledAliasesAreUnique: Bool {
        var aliases: Set<String> = []
        for host in hosts where host.isEnabled {
            let normalized = host.alias
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, aliases.insert(normalized).inserted else {
                return false
            }
        }
        return true
    }

    var canSaveSettings: Bool {
        guard enabledAliasesAreUnique else { return false }
        return hosts.allSatisfy { host in
            guard host.isEnabled else { return true }
            guard SSHInputValidator.isValidAlias(host.alias) else { return false }

            let path = host.codexPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return (try? SSHInputValidator.parseExecutablePath(path)) != nil
            }
            return validationStates[host.id]?.isValid == true
        }
    }

    func sessions(for status: TaskDisplayStatus) -> [SessionSnapshot] {
        snapshot?.sessions(with: status) ?? []
    }

    func hostLabel(for hostID: String) -> String {
        hosts.first(where: { $0.alias == hostID })?.displayName ?? hostID
    }

    func start() {
        guard destination != .onboarding, monitoringTask == nil else { return }
        let client = self.client
        let configuredHosts = hosts

        monitoringTask = Task { [weak self] in
            await client.start(hosts: configuredHosts)
            let updates = await client.snapshots()

            for await update in updates {
                guard !Task.isCancelled else { break }
                self?.snapshot = update
                self?.isRefreshing = false
            }
        }
    }

    func stop() async {
        monitoringTask?.cancel()
        monitoringTask = nil
        await client.stop()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let client = self.client

        Task { [weak self] in
            await client.refresh()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(1))
            self?.isRefreshing = false
        }
    }

    func retry(hostID: String) {
        let client = self.client
        Task {
            await client.retry(hostID: hostID)
        }
    }

    func suspend() {
        let client = self.client
        Task {
            await client.suspend()
        }
    }

    func resume() {
        let client = self.client
        Task {
            await client.resume()
        }
    }

    func showDashboard() {
        destination = .dashboard
    }

    func showSettings() {
        destination = .settings
    }

    func showOnboarding() {
        destination = .onboarding
        discoverAliases()
    }

    func discoverAliases() {
        let client = self.client
        Task { [weak self] in
            let aliases = await client.discoverSSHAliases()
            guard !Task.isCancelled else { return }
            self?.discoveredAliases = aliases
        }
    }

    func validate(host: HostProfile) {
        validationStates[host.id] = .validating
        let client = self.client
        let validatedHost = host

        Task { [weak self] in
            let result = await client.validate(host: validatedHost)
            guard !Task.isCancelled else { return }
            guard self?.hosts.first(where: { $0.id == validatedHost.id })
                == validatedHost
            else {
                return
            }
            self?.validationStates[validatedHost.id] = result.isValid
                ? .valid(
                    version: result.version ?? "Codex found",
                    resolvedCodexPath: result.resolvedCodexPath
                )
                : .invalid(message: result.message ?? "Connection failed")
        }
    }

    func invalidateValidation(hostID: UUID) {
        validationStates[hostID] = .idle
    }

    func completeOnboarding() {
        guard canCompleteOnboarding else { return }
        applyResolvedCodexPaths()
        guard persistHosts() else { return }
        defaults.set(true, forKey: DefaultsKey.onboardingComplete)
        destination = .dashboard
        if monitoringTask == nil {
            start()
        } else {
            reconfigure()
        }
    }

    func saveSettings() {
        applyResolvedCodexPaths()
        guard persistHosts() else { return }
        if hosts.isEmpty {
            defaults.set(false, forKey: DefaultsKey.onboardingComplete)
            destination = .onboarding
        } else {
            destination = .dashboard
        }
        reconfigure()
    }

    func resetOnboarding() {
        defaults.set(false, forKey: DefaultsKey.onboardingComplete)
        destination = .onboarding
        discoverAliases()
    }

    func addHost(alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !hosts.contains(where: {
                $0.alias.caseInsensitiveCompare(trimmed) == .orderedSame
            })
        else {
            return
        }
        hosts.append(HostProfile(alias: trimmed))
    }

    func removeHosts(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            validationStates.removeValue(forKey: hosts[index].id)
            hosts.remove(at: index)
        }
    }

    func removeHost(id: UUID) {
        validationStates.removeValue(forKey: id)
        hosts.removeAll(where: { $0.id == id })
    }

    private func reconfigure() {
        let client = self.client
        let configuredHosts = hosts
        Task {
            await client.reconfigure(hosts: configuredHosts)
        }
    }

    private func applyResolvedCodexPaths() {
        for index in hosts.indices {
            guard
                hosts[index].codexPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                let validationState = validationStates[hosts[index].id],
                case let .valid(_, resolvedCodexPath) = validationState,
                let resolvedCodexPath
            else {
                continue
            }
            hosts[index].codexPath = resolvedCodexPath
        }
    }

    @discardableResult
    private func persistHosts() -> Bool {
        do {
            try configurationStore.save(
                VibeStatusConfiguration(
                    hosts: hosts,
                    preferences: VibeStatusPreferences(launchAtLogin: launchAtLogin)
                )
            )
            transientIssue = nil
            return true
        } catch {
            transientIssue = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            transientIssue = nil
        } catch {
            transientIssue = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    private static func isUsable(_ configuration: VibeStatusConfiguration) -> Bool {
        guard !configuration.hosts.isEmpty else { return false }
        return configuration.hosts
            .filter(\.isEnabled)
            .allSatisfy {
                !$0.codexPath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
    }
}

private extension Collection {
    func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
        try reduce(into: 0) { result, element in
            if try predicate(element) {
                result += 1
            }
        }
    }
}
