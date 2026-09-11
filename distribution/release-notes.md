Native macOS menu-bar monitoring for Codex and Claude Code tasks on remote hosts.

Requires macOS 14 or newer. The ZIP includes a prebuilt universal app for Apple
Silicon and Intel Macs. Xcode and an Apple Developer account are not needed to
install it.

**This beta is not notarized by Apple.** macOS may block its first launch. If you
trust this release, first try opening the app, then open **System Settings →
Privacy & Security → Open Anyway** and confirm. See
[Apple's instructions](https://support.apple.com/en-us/102445).

Download the ZIP, extract it, move `VibeStatus.app` to Applications, and open it.
The SHA-256 checksum is attached alongside the ZIP.

After the Homebrew tap update finishes, install with:

```sh
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
brew install --cask jchy20/vibe-status/vibe-status
```

Configure your SSH aliases and key-based authentication before connecting.
Optional Claude Code status still uses the helper installer documented in the
[README](https://github.com/jchy20/vibe-status#enable-claude-code-status).
