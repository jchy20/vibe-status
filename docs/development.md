# Development

[Back to the README](../README.md)

## Build from source

For development or a local source build, install full Xcode from the Mac App Store and Git, then clone this repository:

```sh
git clone https://github.com/jchy20/vibe-status.git
cd vibe-status
```

Build with the full Xcode toolchain for this command only. Setting `DEVELOPER_DIR` this way does not change your system-wide developer-tool selection:

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

The first build may take a few minutes while Xcode downloads Swift package dependencies.

You can also open `VibeStatus.xcodeproj` in Xcode, select the **VibeStatus** scheme, and press **Run**.

## Tests and project generation

Run the Swift package tests:

```sh
swift test --disable-sandbox
```

Check the Claude Code helper scripts:

```sh
python3 -m py_compile \
  Tools/claude_status_hook.py \
  Tools/claude_usage_statusline.py \
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

The generated Xcode project is committed, so testers do not need XcodeGen. After adding or removing source files, contributors can regenerate it with:

```sh
brew install xcodegen
sh scripts/generate_project.sh
```

Protocol exploration notes and diagnostic tools live in [the protocol notes](protocol-spike.md) and [`Tools/`](../Tools/).

## Troubleshooting

### `xcodebuild` says that Xcode is required

Confirm that full Xcode is installed at `/Applications/Xcode.app`, then run `xcodebuild` with the one-command `DEVELOPER_DIR` prefix shown above. You can verify that toolchain without changing the system-wide selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -version
```

## Releases

See [Releasing Vibe Status](releasing.md) for packaging and publishing through GitHub Actions and Homebrew.
