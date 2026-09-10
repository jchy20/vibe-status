import Foundation

public protocol StandaloneCodexSessionDiscovering: Sendable {
    func activeThreadIDs() async throws -> Set<String>
}

public enum StandaloneCodexSessionDiscoveryError:
    Error,
    Equatable,
    LocalizedError
{
    case unsupported
    case sshExited(alias: String, status: Int32, diagnostics: String)
    case malformedOutput

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This host cannot safely inspect standalone Codex sessions."
        case let .sshExited(alias, status, diagnostics):
            let detail = diagnostics
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "Standalone Codex discovery on \(alias) exited with status \(status).\(suffix)"
        case .malformedOutput:
            return "Standalone Codex discovery returned an invalid thread identifier."
        }
    }
}

public struct SSHStandaloneCodexSessionDiscoverer:
    StandaloneCodexSessionDiscovering,
    Sendable
{
    public let alias: String
    public let runner: SSHOneShotCommandRunner

    public init(
        alias: String,
        runner: SSHOneShotCommandRunner = .init(timeout: 10)
    ) {
        self.alias = alias
        self.runner = runner
    }

    public func activeThreadIDs() async throws -> Set<String> {
        let plan = try SSHCommandBuilder
            .standaloneCodexSessionDiscoveryPlan(alias: alias)
        let result = try await runner.run(plan)

        return try Self.parseResult(result, alias: alias)
    }

    static func parseResult(
        _ result: SSHCommandResult,
        alias: String
    ) throws -> Set<String> {
        if result.termination.status
            == SSHCommandBuilder.standaloneCodexDiscoveryUnsupportedStatus {
            throw StandaloneCodexSessionDiscoveryError.unsupported
        }
        guard result.termination.status == 0 else {
            throw StandaloneCodexSessionDiscoveryError.sshExited(
                alias: alias,
                status: result.termination.status,
                diagnostics: result.standardErrorText
            )
        }
        return try Self.parseThreadIDs(result.standardOutputText)
    }

    public static func parseThreadIDs(_ output: String) throws -> Set<String> {
        var identifiers: Set<String> = []
        for rawLine in output.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            guard isCanonicalThreadID(line) else {
                throw StandaloneCodexSessionDiscoveryError.malformedOutput
            }
            identifiers.insert(line)
        }
        return identifiers
    }

    private static func isCanonicalThreadID(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        for (index, byte) in value.utf8.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { return false }
            } else {
                let isDigit = byte >= 48 && byte <= 57
                let isLowercaseHex = byte >= 97 && byte <= 102
                guard isDigit || isLowercaseHex else { return false }
            }
        }
        return true
    }
}
