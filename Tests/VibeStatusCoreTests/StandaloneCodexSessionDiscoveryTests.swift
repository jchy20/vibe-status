import Foundation
import XCTest
@testable import VibeStatusCore

final class StandaloneCodexSessionDiscoveryTests: XCTestCase {
    func testParsesCanonicalThreadIDsAndDeduplicates() throws {
        let first = "019ff2d0-9f0d-7723-8c58-a6bbed013ce5"
        let second = "019ff341-30a7-75e0-8246-225df25b4eb1"

        XCTAssertEqual(
            try SSHStandaloneCodexSessionDiscoverer.parseThreadIDs(
                "\(first)\n\(second)\n\(first)\n"
            ),
            [first, second]
        )
    }

    func testAllowsEmptyDiscoveryOutput() throws {
        XCTAssertEqual(
            try SSHStandaloneCodexSessionDiscoverer.parseThreadIDs("\n"),
            []
        )
    }

    func testRejectsNoncanonicalOrContaminatedOutput() {
        let malformed = [
            "019FF2D0-9F0D-7723-8C58-A6BBED013CE5",
            "019ff2d09f0d77238c58a6bbed013ce5",
            "019ff2d0-9f0d-7723-8c58-a6bbed013ce5 extra",
            " 019ff2d0-9f0d-7723-8c58-a6bbed013ce5",
            "../../019ff2d0-9f0d-7723-8c58-a6bbed013ce5",
            "warning: unavailable",
        ]

        for output in malformed {
            XCTAssertThrowsError(
                try SSHStandaloneCodexSessionDiscoverer.parseThreadIDs(output),
                output
            ) { error in
                XCTAssertEqual(
                    error as? StandaloneCodexSessionDiscoveryError,
                    .malformedOutput
                )
            }
        }
    }

    func testBuildsReadOnlyStandaloneDiscoveryPlan() throws {
        let plan = try SSHCommandBuilder
            .standaloneCodexSessionDiscoveryPlan(alias: "build-host")

        XCTAssertEqual(
            plan.remoteCommand,
            SSHCommandBuilder.standaloneCodexSessionDiscoveryCommand
        )
        XCTAssertTrue(plan.remoteCommand.contains("thread-writer-locks"))
        XCTAssertTrue(
            plan.remoteCommand.contains(
                "lock_snapshot=$(lslocks -n -o PID,TYPE,MODE,PATH"
            )
        )
        XCTAssertTrue(plan.remoteCommand.contains("|| exit 69"))
        XCTAssertTrue(plan.remoteCommand.contains("lock_type != \"FLOCK\""))
        XCTAssertTrue(plan.remoteCommand.contains("lock_mode != \"WRITE\""))
        XCTAssertFalse(plan.remoteCommand.contains("lsof"))
        XCTAssertTrue(plan.remoteCommand.contains("sed -n '2p'"))
        XCTAssertTrue(
            plan.remoteCommand.contains(
                "[ \"$subcommand_argument\" = \"app-server\" ]"
            )
        )
        XCTAssertTrue(plan.remoteCommand.contains("exit 69"))
        XCTAssertFalse(plan.remoteCommand.contains("rm "))
        XCTAssertFalse(plan.remoteCommand.contains("kill "))
        XCTAssertEqual(plan.arguments.suffix(2).first, "build-host")
        XCTAssertEqual(plan.arguments.last, plan.remoteCommand)
    }

    func testDiscoveryMapsUnsupportedExitStatus() async throws {
        do {
            _ = try SSHStandaloneCodexSessionDiscoverer.parseResult(
                result(exiting: 69),
                alias: "build-host"
            )
            XCTFail("Expected unsupported discovery")
        } catch {
            XCTAssertEqual(
                error as? StandaloneCodexSessionDiscoveryError,
                .unsupported
            )
        }
    }

    func testDiscoveryPreservesSSHFailureDiagnostics() async throws {
        do {
            _ = try SSHStandaloneCodexSessionDiscoverer.parseResult(
                result(exiting: 7, standardError: "permission denied"),
                alias: "build-host"
            )
            XCTFail("Expected SSH command failure")
        } catch {
            XCTAssertEqual(
                error as? StandaloneCodexSessionDiscoveryError,
                .sshExited(
                    alias: "build-host",
                    status: 7,
                    diagnostics: "permission denied"
                )
            )
        }
    }

    private func result(
        exiting status: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) -> SSHCommandResult {
        SSHCommandResult(
            termination: .init(status: status, reason: .exit),
            standardOutput: Data(standardOutput.utf8),
            standardError: Data(standardError.utf8)
        )
    }
}
