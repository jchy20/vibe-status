# Setup and troubleshooting

[Back to the README](../README.md)

## Requirements

- macOS 14 or newer
- One or more literal host aliases in `~/.ssh/config`
- Non-interactive SSH authentication using a key or SSH agent
- Codex CLI 0.145.0 or a compatible newer version on each remote host
- `lslocks` on remote Linux hosts to include Codex tasks started outside Vibe Status's managed app-server
- Optional: Claude Code with lifecycle-hook support and Python 3.8 or newer on hosts where Claude Code status should be monitored (tested with Claude Code 2.1.212)

## Prepare a remote host

Vibe Status uses the aliases already defined in `~/.ssh/config`. For example:

```sshconfig
Host my-mac
    HostName example.com
    User james
    IdentityFile ~/.ssh/id_ed25519
```

Before opening Vibe Status, verify that the connection succeeds without a password or MFA prompt:

```sh
ssh -T my-mac true
```

Also confirm that Codex is installed on the remote host. Vibe Status can usually discover it automatically from the remote `PATH`, `$HOME/.local/bin/codex`, or the remote account's login shell.

### Enable Claude Code status

Claude Code status is optional. It uses Claude Code's lifecycle hooks to write small state records that Vibe Status reads over SSH. Clone this repository and run the installer:

```sh
git clone https://github.com/jchy20/vibe-status.git
cd vibe-status
./scripts/configure_claude_status_remote.sh <ssh-alias>
```

The installer copies lifecycle and usage helpers to `~/.local/lib/vibe-status/`, merges Vibe Status entries into `~/.claude/settings.json`, and creates a timestamped backup before changing an existing settings file. If you already use a custom Claude Code status line, Vibe Status delegates to it and restores it during uninstall. Other Claude Code settings and hooks are preserved.

Claude Code watches its settings file for changes, so active sessions normally pick up the hooks without a restart. The next lifecycle event publishes the session's status. To remove only the Vibe Status hooks:

```sh
./scripts/configure_claude_status_remote.sh --uninstall <ssh-alias>
```

## First-run setup

1. Launch Vibe Status and select its menu-bar icon.
2. Select one or more discovered SSH aliases, or enter a literal alias.
3. Optionally give each host a friendlier display name.
4. Leave the Codex path empty for automatic detection.
5. Test every enabled host.
6. Select **Start Monitoring**.

If automatic detection fails, enter the absolute remote path to Codex or a path beginning with `$HOME/`.

## Troubleshooting

### SSH asks for a password or MFA code

Vibe Status intentionally uses non-interactive SSH. Configure key- or agent-based authentication until this succeeds without prompting:

```sh
ssh -T <ssh-alias> true
```

### Codex cannot be found

In the host settings, enter the absolute path returned by this command:

```sh
ssh <ssh-alias> 'command -v codex'
```

### A standalone Codex task does not appear

Independently launched Codex tasks currently require `lslocks`, normally provided by util-linux on remote Linux hosts. Confirm it is available:

```sh
ssh <ssh-alias> 'command -v lslocks'
```

If it is unavailable, or the remote host is not Linux, Vibe Status continues showing tasks owned by its managed app-server; only independently launched tasks are omitted.

### Claude Code tasks do not appear

Confirm the hook is installed and wait for the active session's next lifecycle event:

```sh
ssh <ssh-alias> 'test -x ~/.local/lib/vibe-status/claude_status_hook.py'
ssh <ssh-alias> 'ls ~/.local/state/vibe-status/claude/'
```

Re-running `configure_claude_status_remote.sh` is safe and replaces only the Vibe Status hook entries.
