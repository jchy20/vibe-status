# Vibe Status

A macOS menu-bar app for monitoring Codex and Claude Code tasks on remote machines through SSH.

- **Yellow:** waiting for input or approval
- **Blue:** working
- **Green:** ready for the next turn

Select the menu-bar icon to see tasks grouped by status and host. Codex subagents are hidden to keep the list focused.

## Install

Requires macOS 14 or newer. Supports Apple Silicon and Intel Macs.

```sh
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
brew install --cask jchy20/vibe-status/vibe-status
open -a VibeStatus
```

You can also download the ZIP from [GitHub Releases](https://github.com/jchy20/vibe-status/releases), extract it, and move `VibeStatus.app` to Applications. Xcode and an Apple Developer account are not required.

**This beta is not notarized by Apple.** If macOS blocks the first launch and you trust the release, try opening the app, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. See [Apple's instructions](https://support.apple.com/en-us/102445).

To update:

```sh
brew update
brew upgrade --cask jchy20/vibe-status/vibe-status
```

## Setup

Add your remote hosts to `~/.ssh/config` and configure SSH keys or an SSH agent. Each host must connect without asking for a password or MFA code:

```sh
ssh -T <ssh-alias> true
```

For Codex monitoring, install Codex CLI 0.145.0 or a compatible newer version on each remote host.

1. Open Vibe Status and select your SSH aliases.
2. Leave the Codex path empty for automatic detection, or enter its remote path.
3. Test your hosts, then select **Start Monitoring**.

See the [setup guide](docs/setup.md) for SSH examples and troubleshooting.

### Enable Claude Code status

Claude Code monitoring requires an optional helper on each remote host. Follow the [Claude Code setup instructions](docs/setup.md#enable-claude-code-status) to install or remove it.

## Limitations and privacy

Codex tasks started outside Vibe Status require a Linux host with `lslocks` to appear. These tasks show working or ready; waiting for input or approval is shown as working.

Vibe Status uses your existing SSH configuration. It does not store SSH credentials, send prompts, or approve requests. There is no analytics or telemetry. See [privacy and remote access](docs/privacy.md) for what the app and optional helpers read and store.

## Development

- [Build from source and run tests](docs/development.md)
- [Package and publish a release](docs/releasing.md)
- [Protocol notes](docs/protocol-spike.md)
