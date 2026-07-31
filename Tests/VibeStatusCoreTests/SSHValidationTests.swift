import Darwin
import Foundation
import XCTest
@testable import VibeStatusCore

final class SSHValidationTests: XCTestCase {
    func testAcceptsOnlyLiteralSSHConfigAliases() {
        for alias in ["compute-a", "build_host", "gpu.example.1", "A1"] {
            XCTAssertTrue(SSHInputValidator.isValidAlias(alias), alias)
        }

        for alias in ["", "-host", "user@host", "host name", "wild*", "host\nnext"] {
            XCTAssertFalse(SSHInputValidator.isValidAlias(alias), alias)
        }
    }

    func testExecutablePathValidation() throws {
        XCTAssertEqual(
            try SSHInputValidator.parseExecutablePath("$HOME/.local/bin/codex"),
            .homeRelative(".local/bin/codex")
        )
        XCTAssertEqual(
            try SSHInputValidator.parseExecutablePath("/opt/codex-1/bin/codex"),
            .absolute("/opt/codex-1/bin/codex")
        )

        XCTAssertThrowsError(try SSHInputValidator.parseExecutablePath("codex"))
        XCTAssertThrowsError(try SSHInputValidator.parseExecutablePath("$HOME/a;touch"))
        XCTAssertThrowsError(try SSHInputValidator.parseExecutablePath("/tmp/a\ncommand"))
    }

    func testPOSIXQuotingEscapesSingleQuotes() throws {
        XCTAssertEqual(try POSIXShell.quote("alpha beta"), "'alpha beta'")
        XCTAssertEqual(try POSIXShell.quote("a'b"), "'a'\"'\"'b'")
        XCTAssertEqual(
            try POSIXShell.renderExecutablePath("$HOME/.local/bin/codex"),
            "\"$HOME\"/'.local/bin/codex'"
        )
    }

    func testLaunchPlanUsesFixedNonInteractiveSSHOptions() throws {
        let profile = HostProfile(
            alias: "compute-a",
            codexPath: HostProfile.suggestedCodexPath
        )

        let plan = try SSHCommandBuilder.launchPlan(for: profile)

        XCTAssertEqual(plan.executableURL.path, "/usr/bin/ssh")
        XCTAssertEqual(
            plan.remoteCommand,
            "\"$HOME\"/'.local/bin/codex' app-server daemon start 1>&2 && "
                + "exec \"$HOME\"/'.local/bin/codex' app-server proxy"
        )
        XCTAssertEqual(
            plan.arguments,
            [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "ClearAllForwardings=yes",
                "-o", "RemoteCommand=none",
                "-o", "PermitLocalCommand=no",
                "--",
                "compute-a",
                plan.remoteCommand,
            ]
        )
    }

    func testBuildsReadOnlyOnboardingProbePlans() throws {
        let profile = HostProfile(
            alias: "build-host",
            codexPath: HostProfile.suggestedCodexPath
        )

        let inspection = try SSHCommandBuilder.configurationInspectionPlan(alias: profile.alias)
        XCTAssertEqual(
            inspection.arguments,
            [
                "-G",
                "-o", "BatchMode=yes",
                "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no",
                "--",
                "build-host",
            ]
        )

        let version = try SSHCommandBuilder.codexVersionProbePlan(for: profile)
        XCTAssertEqual(
            version.remoteCommand,
            "\"$HOME\"/'.local/bin/codex' --version"
        )

        let daemon = try SSHCommandBuilder.daemonVersionProbePlan(for: profile)
        XCTAssertEqual(
            daemon.remoteCommand,
            "\"$HOME\"/'.local/bin/codex' app-server daemon version"
        )

        let capability = try SSHCommandBuilder.daemonCapabilityProbePlan(for: profile)
        XCTAssertEqual(
            capability.remoteCommand,
            "\"$HOME\"/'.local/bin/codex' app-server daemon --help"
        )

        let discovery = try SSHCommandBuilder.codexDiscoveryProbePlan(
            alias: profile.alias
        )
        XCTAssertEqual(discovery.remoteCommand, SSHCommandBuilder.codexDiscoveryCommand)
        XCTAssertTrue(discovery.remoteCommand.contains("command -v codex"))
        XCTAssertEqual(discovery.arguments.suffix(2).first, profile.alias)
    }

    func testBuildsReadOnlyClaudeStatusSnapshotPlan() throws {
        let plan = try SSHCommandBuilder.claudeStatusSnapshotPlan(
            alias: "build-host"
        )

        XCTAssertEqual(
            plan.remoteCommand,
            SSHCommandBuilder.claudeStatusSnapshotCommand
        )
        XCTAssertTrue(plan.remoteCommand.contains("VIBE_STATUS_CLAUDE_STATE_DIR"))
        XCTAssertTrue(plan.remoteCommand.contains("printf '[]"))
        XCTAssertEqual(plan.arguments.suffix(2).first, "build-host")
    }

    func testExtractsLastSafeAbsoluteCodexPathFromDiscoveryOutput() {
        let output = """
        shell startup message
        /home/example/.local/bin/codex
        """

        XCTAssertEqual(
            SSHHostValidator.resolvedCodexPath(in: output),
            "/home/example/.local/bin/codex"
        )
        XCTAssertNil(
            SSHHostValidator.resolvedCodexPath(
                in: "codex\n/tmp/codex;unsafe\n"
            )
        )
    }

    func testBoundedDiagnosticRingRetainsNewestBytesAndLines() {
        let byteRing = BoundedDiagnosticRing(maximumBytes: 5, maximumLines: 10)
        byteRing.append("1234567")
        XCTAssertEqual(byteRing.snapshotText(), "34567")

        let lineRing = BoundedDiagnosticRing(maximumBytes: 1_024, maximumLines: 2)
        lineRing.append("first\nsecond\nthird")
        XCTAssertEqual(lineRing.snapshotLines(), ["second", "third"])

        lineRing.clear()
        XCTAssertEqual(lineRing.snapshotData(), Data())
    }

    func testUnstartedTransportDoesNotExposeDescriptors() throws {
        let transport = try SSHProcessTransport(
            profile: HostProfile(
                alias: "compute-a",
                codexPath: "/opt/codex/bin/codex"
            )
        )

        XCTAssertFalse(transport.isRunning)
        XCTAssertThrowsError(try transport.duplicatePipeDescriptors()) { error in
            XCTAssertEqual(error as? SSHProcessTransportError, .notRunning)
        }
    }

    func testOneShotRunnerKeepsStandardOutputAndErrorSeparate() async throws {
        let plan = SSHLaunchPlan(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'protocol-bytes'; printf 'diagnostic-warning' >&2; exit 7",
            ],
            remoteCommand: ""
        )

        let result = try await SSHOneShotCommandRunner().run(plan)

        XCTAssertEqual(result.termination, .init(status: 7, reason: .exit))
        XCTAssertEqual(result.standardOutputText, "protocol-bytes")
        XCTAssertEqual(result.standardErrorText, "diagnostic-warning")
    }
}
