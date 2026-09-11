# Vibe Status Homebrew tap

The public [Vibe Status repository](https://github.com/jchy20/vibe-status) is also
the tap. It contains `Casks/vibe-status.rb`, generated from the published ZIP.

Requires macOS 14 Sonoma or newer. The prebuilt app supports Apple Silicon and
Intel Macs; users do not need Xcode or an Apple Developer account.

```sh
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
brew install --cask jchy20/vibe-status/vibe-status
open -a VibeStatus
```

**The beta is not notarized by Apple.** If macOS blocks it and you trust the
release, first try opening it, then select **System Settings → Privacy &
Security → Open Anyway** and confirm. See
[Apple's instructions](https://support.apple.com/en-us/102445).

To update:

```sh
brew update
brew upgrade --cask jchy20/vibe-status/vibe-status
```

To uninstall:

```sh
brew uninstall --cask jchy20/vibe-status/vibe-status
```

Add `--zap` to remove the app's saved preferences. This does not uninstall remote
Claude Code hooks. The app uses Homebrew-managed upgrades.

The release workflow updates the cask automatically after verifying the public
ZIP checksum. Maintainers can find packaging and recovery instructions in
[Releasing Vibe Status](../../docs/releasing.md).
