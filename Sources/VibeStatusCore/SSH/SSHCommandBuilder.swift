import Foundation

public struct SSHLaunchPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let remoteCommand: String

    public init(executableURL: URL, arguments: [String], remoteCommand: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.remoteCommand = remoteCommand
    }
}

public enum SSHCommandBuilder {
    public static let sshExecutableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Uses only fixed shell text. The result is validated locally before it
    /// is stored or interpolated into another remote command.
    public static let codexDiscoveryCommand = """
    if command -v codex >/dev/null 2>&1; then
      command -v codex
    elif [ -x "$HOME/.local/bin/codex" ]; then
      printf '%s\\n' "$HOME/.local/bin/codex"
    elif [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then
      "$SHELL" -lic 'command -v codex'
    else
      exit 127
    fi
    """

    /// Reads only Vibe Status's hook-owned Claude Code state files. The hook
    /// writes one JSON object per session using an atomic rename.
    public static let claudeStatusSnapshotCommand = """
    state_dir="${VIBE_STATUS_CLAUDE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vibe-status/claude}"
    if [ ! -d "$state_dir" ]; then
      printf '[]\\n'
      exit 0
    fi
    printf '['
    separator=''
    for path in "$state_dir"/*.json; do
      [ -f "$path" ] || continue
      printf '%s' "$separator"
      cat "$path" || exit 1
      separator=','
    done
    printf ']\\n'
    """

    public static func daemonProxyCommand(codexPath: String) throws -> String {
        let executable = try POSIXShell.renderExecutablePath(codexPath)
        return "\(executable) app-server daemon start 1>&2 && exec \(executable) app-server proxy"
    }

    public static func codexVersionCommand(codexPath: String) throws -> String {
        "\(try POSIXShell.renderExecutablePath(codexPath)) --version"
    }

    public static func daemonVersionCommand(codexPath: String) throws -> String {
        "\(try POSIXShell.renderExecutablePath(codexPath)) app-server daemon version"
    }

    public static func daemonCapabilityCommand(codexPath: String) throws -> String {
        "\(try POSIXShell.renderExecutablePath(codexPath)) app-server daemon --help"
    }

    public static func configurationInspectionPlan(alias: String) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(alias)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: [
                "-G",
                "-o", "BatchMode=yes",
                "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no",
                "--",
                alias,
            ],
            remoteCommand: ""
        )
    }

    public static func codexDiscoveryProbePlan(alias: String) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(alias)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: arguments(alias: alias, remoteCommand: codexDiscoveryCommand),
            remoteCommand: codexDiscoveryCommand
        )
    }

    public static func claudeStatusSnapshotPlan(
        alias: String
    ) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(alias)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: arguments(
                alias: alias,
                remoteCommand: claudeStatusSnapshotCommand
            ),
            remoteCommand: claudeStatusSnapshotCommand
        )
    }

    public static func codexVersionProbePlan(for profile: HostProfile) throws -> SSHLaunchPlan {
        try probePlan(
            for: profile,
            remoteCommand: codexVersionCommand(codexPath: profile.codexPath)
        )
    }

    public static func daemonVersionProbePlan(for profile: HostProfile) throws -> SSHLaunchPlan {
        try probePlan(
            for: profile,
            remoteCommand: daemonVersionCommand(codexPath: profile.codexPath)
        )
    }

    public static func daemonCapabilityProbePlan(
        for profile: HostProfile
    ) throws -> SSHLaunchPlan {
        try probePlan(
            for: profile,
            remoteCommand: daemonCapabilityCommand(codexPath: profile.codexPath)
        )
    }

    public static func launchPlan(for profile: HostProfile) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(profile.alias)
        let remoteCommand = try daemonProxyCommand(codexPath: profile.codexPath)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: arguments(alias: profile.alias, remoteCommand: remoteCommand),
            remoteCommand: remoteCommand
        )
    }

    public static func arguments(alias: String, remoteCommand: String) -> [String] {
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
            alias,
            remoteCommand,
        ]
    }

    private static func probePlan(
        for profile: HostProfile,
        remoteCommand: String
    ) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(profile.alias)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: arguments(alias: profile.alias, remoteCommand: remoteCommand),
            remoteCommand: remoteCommand
        )
    }
}
