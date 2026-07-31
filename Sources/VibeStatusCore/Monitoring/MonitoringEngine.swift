import Foundation

/// Merges independently replaceable host snapshots. Counts are always derived
/// from the merged session collection, never incremented as separate state.
public actor MonitoringEngine {
    private struct SourceID: Hashable {
        let hostID: String
        let agent: AgentKind
    }

    private var sources: [SourceID: HostSnapshot] = [:]
    private var continuations:
        [UUID: AsyncStream<DashboardSnapshot>.Continuation] = [:]

    public init() {}

    public func currentSnapshot() -> DashboardSnapshot {
        makeDashboardSnapshot()
    }

    public func snapshots() -> AsyncStream<DashboardSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<DashboardSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.yield(makeDashboardSnapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(identifier)
            }
        }
        return pair.stream
    }

    public func replaceHost(_ snapshot: HostSnapshot) {
        let sourceID = SourceID(hostID: snapshot.hostID, agent: snapshot.agent)
        sources[sourceID] = HostSnapshot(
            hostID: snapshot.hostID,
            agent: snapshot.agent,
            sessions: snapshot.sessions.filter {
                $0.hostID == snapshot.hostID && $0.agent == snapshot.agent
            },
            issues: snapshot.issues.filter {
                $0.hostID == snapshot.hostID && $0.agent == snapshot.agent
            }
        )
        publish()
    }

    public func markHostDisconnected(
        hostID: String,
        agent: AgentKind = .codex,
        message: String,
        at date: Date = Date()
    ) {
        sources[SourceID(hostID: hostID, agent: agent)] = .init(
            hostID: hostID,
            agent: agent,
            sessions: [],
            issues: [
                .init(
                    hostID: hostID,
                    agent: agent,
                    kind: .disconnected,
                    message: message,
                    updatedAt: date
                ),
            ]
        )
        publish()
    }

    public func removeHost(
        _ hostID: String,
        agent: AgentKind? = nil
    ) {
        if let agent {
            sources.removeValue(forKey: SourceID(hostID: hostID, agent: agent))
        } else {
            let sourceIDs = sources.keys.filter { $0.hostID == hostID }
            for sourceID in sourceIDs {
                sources.removeValue(forKey: sourceID)
            }
        }
        publish()
    }

    private func makeDashboardSnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            sessions: sources.values.flatMap(\.sessions),
            issues: sources.values.flatMap(\.issues)
        )
    }

    private func publish() {
        let snapshot = makeDashboardSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
