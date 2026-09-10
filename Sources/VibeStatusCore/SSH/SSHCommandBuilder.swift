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

    /// Returned when the remote platform cannot inspect active thread-writer
    /// locks without installing software or changing Codex state.
    public static let standaloneCodexDiscoveryUnsupportedStatus: Int32 = 69

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
    usage_file="${VIBE_STATUS_CLAUDE_USAGE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/vibe-status/claude-usage.json}"
    printf '{"sessions":['
    separator=''
    if [ -d "$state_dir" ]; then
      for path in "$state_dir"/*.json; do
        [ -f "$path" ] || continue
        printf '%s' "$separator"
        cat "$path" || exit 1
        separator=','
      done
    fi
    printf '],"usage":'
    if [ -f "$usage_file" ]; then
      cat "$usage_file" || exit 1
    else
      printf 'null'
    fi
    printf '}\\n'
    """

    /// Reports canonical Codex thread IDs whose writer locks are owned by a
    /// standalone `codex` process. The managed app-server is excluded because
    /// its loaded threads are already observed through the RPC connection.
    ///
    /// This command is deliberately read-only. Linux uses the kernel lock
    /// inventory exposed by `lslocks`. Other platforms exit with a stable
    /// unsupported status instead of attempting to install tools or infer
    /// activity from stale lock-file presence.
    public static let standaloneCodexSessionDiscoveryCommand = """
    lock_dir="${CODEX_HOME:-$HOME/.codex}/thread-writer-locks"
    [ -d "$lock_dir" ] || exit 0

    platform=$(uname -s 2>/dev/null) || exit 69
    case "$platform" in
      Linux)
        command -v awk >/dev/null 2>&1 || exit 69
        command -v lslocks >/dev/null 2>&1 || exit 69
        command -v sed >/dev/null 2>&1 || exit 69
        command -v tr >/dev/null 2>&1 || exit 69
        lock_snapshot=$(lslocks -n -o PID,TYPE,MODE,PATH 2>/dev/null) \
          || exit 69

        lock_candidates=$( \
          printf '%s\\n' "$lock_snapshot" |
          awk -v prefix="$lock_dir/" '
          function is_hex(value) {
            return value != "" && value !~ /[^0-9a-f]/
          }
          function is_thread_id(value) {
            return length(value) == 36 \
              && substr(value, 9, 1) == "-" \
              && substr(value, 14, 1) == "-" \
              && substr(value, 19, 1) == "-" \
              && substr(value, 24, 1) == "-" \
              && is_hex(substr(value, 1, 8)) \
              && is_hex(substr(value, 10, 4)) \
              && is_hex(substr(value, 15, 4)) \
              && is_hex(substr(value, 20, 4)) \
              && is_hex(substr(value, 25, 12))
          }
          {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            pid = line
            sub(/[[:space:]].*$/, "", pid)
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            lock_type = line
            sub(/[[:space:]].*$/, "", lock_type)
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            lock_mode = line
            sub(/[[:space:]].*$/, "", lock_mode)
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            if (lock_type != "FLOCK" || lock_mode != "WRITE") next
            if (index(line, prefix) != 1) next
            name = substr(line, length(prefix) + 1)
            if (index(name, "/") != 0 \
                || substr(name, length(name) - 4) != ".lock") next
            name = substr(name, 1, length(name) - 5)
            if (pid ~ /^[0-9]+$/ && is_thread_id(name)) {
              print pid "|" name
            }
          }
          '
        ) || exit 69

        printf '%s\\n' "$lock_candidates" |
        while IFS='|' read -r pid thread_id; do
          [ -r "/proc/$pid/comm" ] || continue
          IFS= read -r process_name < "/proc/$pid/comm" || continue
          [ "$process_name" = "codex" ] || continue
          [ -r "/proc/$pid/cmdline" ] || continue
          subcommand_argument=$( \
            tr '\\000' '\\n' < "/proc/$pid/cmdline" 2>/dev/null \
              | sed -n '2p' \
          ) || continue
          [ "$subcommand_argument" = "app-server" ] && continue
          printf '%s\\n' "$thread_id"
        done
        ;;
      *)
        exit 69
        ;;
    esac
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

    public static func standaloneCodexSessionDiscoveryPlan(
        alias: String
    ) throws -> SSHLaunchPlan {
        try SSHInputValidator.validateAlias(alias)
        return SSHLaunchPlan(
            executableURL: sshExecutableURL,
            arguments: arguments(
                alias: alias,
                remoteCommand: standaloneCodexSessionDiscoveryCommand
            ),
            remoteCommand: standaloneCodexSessionDiscoveryCommand
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
