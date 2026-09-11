# Vibe Status Homebrew tap

This is the README seed for `jchy20/homebrew-tap`.

Installation is available once `Casks/vibe-status.rb` is present in this tap.
That file is generated from a published, signed and notarized release; an empty
tap means the first signed release is still pending.

Vibe Status is a macOS menu-bar app that displays the status of Codex and Claude
Code tasks on remote hosts. It requires macOS 14 Sonoma or later and supports
Apple silicon and Intel Macs.

To install:

```sh
brew install --cask jchy20/tap/vibe-status
open -a VibeStatus
```

To update:

```sh
brew update
brew upgrade --cask vibe-status
```

To uninstall:

```sh
brew uninstall --cask vibe-status
```

Use `brew uninstall --cask --zap vibe-status` to also remove the app's saved
preferences. This does not uninstall remote Claude Code hooks.

See the [Vibe Status repository](https://github.com/jchy20/vibe-status) for setup
instructions, source code, and issues. Direct downloads are available from
[GitHub Releases](https://github.com/jchy20/vibe-status/releases) once published.

## Maintaining the cask

Generate the cask on macOS from the exact signed, notarized and stapled ZIP
published on GitHub Releases. From the Vibe Status source checkout:

```sh
python3 scripts/generate_homebrew_cask.py 0.1.0 \
  dist/releases/0.1.0/VibeStatus-0.1.0.zip \
  --output dist/releases/0.1.0/vibe-status.rb
```

The generator verifies the bundle version, identifier, minimum macOS version,
universal architectures, Developer ID signature, hardened runtime and stapled
notarization ticket, then computes the ZIP's SHA-256. Unsigned preview builds
are rejected. There is no placeholder cask or checksum to publish.

Copy the generated file to `Casks/vibe-status.rb` in this tap and validate it
against the public release before committing an update:

```sh
brew style --cask jchy20/tap/vibe-status
brew audit --cask --online jchy20/tap/vibe-status
```

The app currently uses Homebrew-managed upgrades. Its cask intentionally does
not declare automatic in-app updates.
