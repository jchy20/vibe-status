import Foundation

public struct ThreadProjector: Sendable {
    public let maximumNameLength: Int

    public init(maximumNameLength: Int = 80) {
        self.maximumNameLength = max(8, maximumNameLength)
    }

    public func isTransientThread(_ thread: CodexThread) -> Bool {
        thread.ephemeral
    }

    public func isRootThread(_ thread: CodexThread) -> Bool {
        if isTransientThread(thread) {
            return false
        }
        if thread.parentThreadID != nil {
            return false
        }
        if let sessionID = thread.sessionID, sessionID != thread.id {
            return false
        }

        let excludedTokens = [
            "subagent",
            "sub_agent",
            "sub-agent",
            "memoryconsolidation",
            "memory_consolidation",
            "memory-consolidation",
        ]
        if let source = thread.source {
            let sourceTokens = source.normalizedStringTokens
            if sourceTokens.contains(where: { token in
                excludedTokens.contains(where: token.contains)
            }) {
                return false
            }
        }

        if let role = thread.agentRole?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !role.isEmpty,
           role != "root",
           role != "main" {
            return false
        }
        return true
    }

    public func displayName(for thread: CodexThread) -> String {
        if let name = nonempty(thread.name) {
            return truncated(name)
        }
        if let preview = thread.preview {
            let firstLine = preview
                .split(whereSeparator: \.isNewline)
                .lazy
                .map(String.init)
                .compactMap(nonempty)
                .first
            if let firstLine {
                return truncated(firstLine)
            }
        }
        if let cwd = nonempty(thread.cwd) {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty {
                return truncated(basename)
            }
        }
        return String(thread.id.prefix(8))
    }

    public func hostSnapshot(
        hostID: String,
        threads: [CodexThread],
        now: Date = Date()
    ) -> HostSnapshot {
        var sessions: [SessionSnapshot] = []
        var issues: [HostIssue] = []
        let rootThreads = threads.filter(isRootThread)
        var transientForksByParent: [String: [CodexThread]] = [:]
        for thread in threads where isTransientThread(thread) {
            guard let parentID = transientParentID(
                for: thread,
                rootThreads: rootThreads
            ) else {
                continue
            }
            transientForksByParent[parentID, default: []].append(thread)
        }

        for thread in rootThreads {
            let transientForks = transientForksByParent[thread.id] ?? []
            let updatedAt = ([thread] + transientForks)
                .compactMap { $0.recencyAt ?? $0.updatedAt }
                .max()
                ?? now
            switch thread.status.kind {
            case .notLoaded:
                continue
            case .idle:
                sessions.append(
                    session(
                        hostID: hostID,
                        thread: thread,
                        updatedAt: updatedAt,
                        status: strongestStatus(
                            parent: .ready,
                            transientForks: transientForks
                        )
                    )
                )
            case .active:
                sessions.append(
                    session(
                        hostID: hostID,
                        thread: thread,
                        updatedAt: updatedAt,
                        status: strongestStatus(
                            parent: activeStatus(for: thread),
                            transientForks: transientForks
                        )
                    )
                )
            case .systemError:
                issues.append(
                    .init(
                        id: "\(hostID):thread:\(thread.id):systemError",
                        hostID: hostID,
                        agent: .codex,
                        kind: .systemError,
                        message: "\(displayName(for: thread)) reported a system error.",
                        updatedAt: updatedAt
                    )
                )
            case let .unknown(value):
                issues.append(
                    .init(
                        id: "\(hostID):thread:\(thread.id):unknownStatus",
                        hostID: hostID,
                        agent: .codex,
                        kind: .compatibility,
                        message: "\(displayName(for: thread)) has unsupported status “\(value)”.",
                        updatedAt: updatedAt
                    )
                )
            }
        }
        return .init(
            hostID: hostID,
            agent: .codex,
            sessions: sessions,
            issues: issues
        )
    }

    private func transientParentID(
        for thread: CodexThread,
        rootThreads: [CodexThread]
    ) -> String? {
        if let forkedFromID = thread.forkedFromID {
            return forkedFromID
        }

        // Metadata-only thread/read can omit forkedFromId for an already
        // running side conversation. Codex defines sessionId as the identifier
        // shared by a session tree, so it remains a safe startup fallback for
        // ephemeral threads while self-valued session IDs stay suppressed.
        guard let sessionID = thread.sessionID, sessionID != thread.id else {
            return inferredTransientParentID(
                for: thread,
                rootThreads: rootThreads
            )
        }
        return sessionID
    }

    private func inferredTransientParentID(
        for thread: CodexThread,
        rootThreads: [CodexThread]
    ) -> String? {
        // Codex 0.145 can rebuild an already-loaded /side thread with no
        // relationship fields and a self-valued sessionId. Infer a parent only
        // while the side thread is active and exactly one visible root shares
        // its working directory. Ambiguous matches remain suppressed.
        guard thread.status.kind == .active,
              let cwd = nonempty(thread.cwd) else {
            return nil
        }
        let matches = rootThreads.filter {
            $0.status.kind != .notLoaded && nonempty($0.cwd) == cwd
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    private func strongestStatus(
        parent: TaskDisplayStatus,
        transientForks: [CodexThread]
    ) -> TaskDisplayStatus {
        transientForks.reduce(parent) { current, thread in
            guard thread.status.kind == .active else {
                // An idle side conversation is finished and must not keep the
                // main thread working or create an additional ready task.
                return current
            }
            let child = activeStatus(for: thread)
            return child.sortOrder < current.sortOrder ? child : current
        }
    }

    private func activeStatus(for thread: CodexThread) -> TaskDisplayStatus {
        let needsAttention =
            thread.status.activeFlags.contains("waitingOnApproval")
            || thread.status.activeFlags.contains("waitingOnUserInput")
        return needsAttention ? .needsAttention : .working
    }

    private func session(
        hostID: String,
        thread: CodexThread,
        updatedAt: Date,
        status: TaskDisplayStatus
    ) -> SessionSnapshot {
        .init(
            hostID: hostID,
            agent: .codex,
            threadID: thread.id,
            name: displayName(for: thread),
            cwd: thread.cwd,
            updatedAt: updatedAt,
            status: status
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func truncated(_ value: String) -> String {
        guard value.count > maximumNameLength else { return value }
        let end = value.index(
            value.startIndex,
            offsetBy: maximumNameLength - 1
        )
        return "\(value[..<end])…"
    }
}
