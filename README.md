# Vibe Status

Vibe Status is a native macOS menu-bar app for keeping an eye on Codex and
Claude Code tasks running on remote machines. It connects through hosts already
configured in OpenSSH and shows when a task is working, waiting for you, or
ready for its next turn.

The menu-bar counters use three states:

- Yellow — waiting for user input or approval
- Blue — working
- Green — ready for the next turn

Open the menu-bar popover to see tasks grouped by state and remote host.
Vibe Status focuses on top-level tasks, so Codex subagents and temporary side
conversations do not clutter the list. Each task is labeled with its agent.

> **Beta:** Vibe Status is currently distributed as source. Testers clone the
> repository and build the app locally. A paid Apple Developer account is not
> required for local builds.

## Requirements

- macOS 14 or newer
- A full Xcode installation from the Mac App Store
- Git
- Access to this repository
- One or more literal host aliases in `~/.ssh/config`
- Non-interactive SSH authentication using a key or SSH agent
- Codex CLI 0.145.0 or a compatible newer version on each remote host
- Optional: Claude Code with lifecycle-hook support and Python 3.8 or newer on
  hosts where Claude Code status should be monitored (tested with Claude Code
  2.1.212)

## Build and run the beta

After you have been granted access to the repository:

```sh
git clone https://github.com/jchy20/vibe-status.git
cd vibe-status
```

Build with the full Xcode toolchain for this command only. Setting
`DEVELOPER_DIR` this way does not change your system-wide developer-tool
selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project VibeStatus.xcodeproj \
  -scheme VibeStatus \
  -configuration Debug \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

open DerivedData/Build/Products/Debug/VibeStatus.app
```

The first build may take a few minutes while Xcode downloads Swift package
dependencies.

You can also open `VibeStatus.xcodeproj` in Xcode, select the **VibeStatus**
scheme, and press **Run**.

## Prepare a remote host

Vibe Status uses the aliases already defined in `~/.ssh/config`. For example:

```sshconfig
Host my-mac
    HostName example.com
    User james
    IdentityFile ~/.ssh/id_ed25519
```

Before opening Vibe Status, verify that the connection succeeds without a
password or MFA prompt:

```sh
ssh -T my-mac true
```

Also confirm that Codex is installed on the remote host. Vibe Status can usually
discover it automatically from the remote `PATH`, `$HOME/.local/bin/codex`, or
the remote account's login shell.

### Enable Claude Code status

Claude Code status is optional. It uses Claude Code's lifecycle hooks to write
small state records that Vibe Status reads over SSH. From this repository, run:

```sh
./scripts/configure_claude_status_remote.sh <ssh-alias>
```

The installer copies a hook to `~/.local/lib/vibe-status/`, merges Vibe Status
entries into `~/.claude/settings.json`, and creates a timestamped backup before
changing an existing settings file. Other Claude Code settings and hooks are
preserved.

Claude Code watches its settings file for changes, so active sessions normally
pick up the hooks without a restart. The next lifecycle event publishes the
session's status. To remove only the Vibe Status hooks:

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

If automatic detection fails, enter the absolute remote path to Codex or a path
beginning with `$HOME/`.

## Privacy and remote access

Vibe Status uses the system `/usr/bin/ssh` client and your existing SSH
configuration. It does not store passwords, private keys, or SSH-agent
credentials.

The app reads metadata needed to display loaded task names, prompt previews,
working directories, states, and timestamps. It does not send prompts, approve
requests, or cache transcripts. Codex task metadata and diagnostics remain in
memory and are discarded when the app exits. Host configuration and preferences
are stored locally in `UserDefaults`.

The optional Claude Code hook stores only a session identifier, the first line
of the latest submitted prompt, working directory, display state, and update
timestamp under `~/.local/state/vibe-status/claude/` on the remote host. It
removes the record on a normal Claude Code session exit. The app ignores records
older than 24 hours.

There is no analytics or telemetry.

## Troubleshooting

### `xcodebuild` says that Xcode is required

Confirm that full Xcode is installed at `/Applications/Xcode.app`, then run
`xcodebuild` with the one-command `DEVELOPER_DIR` prefix shown above. You can
verify that toolchain without changing the system-wide selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -version
```

### SSH asks for a password or MFA code

Vibe Status intentionally uses non-interactive SSH. Configure key- or
agent-based authentication until this succeeds without prompting:

```sh
ssh -T <ssh-alias> true
```

### Codex cannot be found

In the host settings, enter the absolute path returned by this command:

```sh
ssh <ssh-alias> 'command -v codex'
```

### Claude Code tasks do not appear

Confirm the hook is installed and wait for the active session's next lifecycle
event:

```sh
ssh <ssh-alias> 'test -x ~/.local/lib/vibe-status/claude_status_hook.py'
ssh <ssh-alias> 'ls ~/.local/state/vibe-status/claude/'
```

Re-running `configure_claude_status_remote.sh` is safe and replaces only the
Vibe Status hook entries.

## Development

Run the Swift package tests:

```sh
swift test --disable-sandbox
```

Check the Claude Code helper scripts:

```sh
python3 -m py_compile \
  Tools/claude_status_hook.py \
  scripts/configure_claude_status.py
sh -n scripts/configure_claude_status_remote.sh
```

Run the macOS app and core tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project VibeStatus.xcodeproj \
  -scheme VibeStatus \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The generated Xcode project is committed, so testers do not need XcodeGen.
After adding or removing source files, contributors can regenerate it with:

```sh
brew install xcodegen
sh scripts/generate_project.sh
```

Protocol exploration notes and diagnostic tools live in
[`docs/protocol-spike.md`](docs/protocol-spike.md) and `Tools/`.

## Distribution

The repository currently supports local development builds only. Debug builds
are not signed or notarized for general distribution. A future release process
will publish signed and notarized builds separately from the source repository.
