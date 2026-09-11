Native macOS menu-bar monitoring for Codex and Claude Code tasks on remote hosts.

Requires macOS 14 or newer. The ZIP includes a universal app for Apple Silicon and
Intel Macs, signed with Developer ID and notarized by Apple.

Download the ZIP, extract it, move `VibeStatus.app` to Applications, and open it.
The SHA-256 checksum is attached alongside the ZIP.

After the Homebrew tap update finishes, install with:

```sh
brew install --cask jchy20/tap/vibe-status
```

Configure your SSH aliases and key-based authentication before connecting.
Optional Claude Code status still uses the helper installer documented in the
[README](https://github.com/jchy20/vibe-status#enable-claude-code-status).
