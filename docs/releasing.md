# Releasing Vibe Status

The release process builds one universal macOS 14+ app, signs all its executable
code with Developer ID and the hardened runtime, notarizes it, staples Apple's
ticket, and publishes the final ZIP and checksum on GitHub Releases. A cask for
that exact ZIP is then committed to `jchy20/homebrew-tap`.

The first public binary requires Apple signing credentials and an initialized
public tap. Source builds remain available until those are configured.

## One-time Apple setup

Enroll in the Apple Developer Program if needed. Create a **Developer ID
Application** certificate and install it with its private key in your Mac's
Keychain. An Apple Development certificate or a Developer ID Installer
certificate does not substitute for it. Verify the identity is available:

```sh
security find-identity -v -p codesigning
```

Create an app-specific password for the Apple Account used for notarization.
Store the notarization credentials interactively in Keychain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool store-credentials vibe-status-notary
```

Enter your Apple Account, developer team ID, and app-specific password when
prompted. Keep private keys and passwords in Keychain or GitHub Actions secrets.

Apple references: [Developer ID](https://developer.apple.com/developer-id/) and
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Create the Homebrew tap

With GitHub CLI installed and authenticated as an account that can create
repositories for `jchy20`:

```sh
gh auth login
bash scripts/setup_homebrew_tap.sh
```

This creates public repository `jchy20/homebrew-tap` if necessary and initializes
its README. Existing repository contents are preserved. The cask is added only
after a real signed release exists; there is no placeholder checksum.

The install command will be:

```sh
brew install --cask jchy20/tap/vibe-status
```

## Configure GitHub Actions

In `jchy20/vibe-status`, add these **Actions repository secrets** under Settings
→ Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the exported Developer ID Application certificate **and private key** in a password-protected `.p12` file |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` file |
| `DEVELOPER_ID_APPLICATION` | Exact certificate name from `security find-identity`, or its 40-character SHA-1 identity |
| `APPLE_ID` | Apple Account email used for notarization |
| `APPLE_TEAM_ID` | Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with **Contents: read and write** access to `jchy20/homebrew-tap` |

The source repository must remain public so Homebrew can download release
assets without authentication. The tap token also reads public release metadata
and downloads the public ZIP to verify its checksum.

To upload the certificate without printing it, use GitHub CLI:

```sh
base64 -i /path/to/DeveloperID.p12 | \
  gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo jchy20/vibe-status
```

The workflow creates a temporary signing keychain, imports the identity, stores
notarization credentials there, and removes the keychain after the run. It uses
GitHub's repository token to publish the release and the separate tap token only
for tap access. See [GitHub's signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Publish a release

Use a stable version in `X.Y.Z` format. From the source repository's Actions tab,
select **Release → Run workflow** and enter the version, or run:

```sh
gh workflow run release.yml --repo jchy20/vibe-status -f version=0.1.0
```

Pushing a matching `vX.Y.Z` tag also triggers the workflow. A manual run refuses
an existing tag that points to a different source commit. The workflow runs the
distribution and Xcode tests before signing. Build numbers come from the Actions
run number. A release is initially created as a draft with all assets attached,
then published. Existing released versions are never overwritten.

The workflow publishes:

- `VibeStatus-X.Y.Z.zip`: the signed and stapled universal app.
- `VibeStatus-X.Y.Z.zip.sha256`: checksum of that final ZIP.
- `vibe-status.rb`: the generated cask, also written to the tap.

The cask generator verifies the archive's identity, version, macOS requirement,
architectures, Developer ID signature, hardened runtime, and stapled ticket.
The tap updater downloads the published ZIP and checks the checksum again before
committing. It refuses downgrades or replacements of an existing version.

After publishing, verify on a Mac with Homebrew:

```sh
brew install --cask jchy20/tap/vibe-status
brew audit --cask --online jchy20/tap/vibe-status
open -a VibeStatus
```

Check launch and SSH connection on supported hardware before describing a release
as tested on that hardware. Building both architectures alone is not an Intel
runtime test.

## Local packaging

With the signing identity and notarization profile already in Keychain:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE=vibe-status-notary
bash scripts/build_release.sh 0.1.0 1
python3 scripts/generate_homebrew_cask.py 0.1.0 \
  dist/releases/0.1.0/VibeStatus-0.1.0.zip \
  --output dist/releases/0.1.0/vibe-status.rb
```

Release output is under `dist/releases/X.Y.Z/`. The script fails before building
if signing or notarization credentials are missing. It never overwrites an
existing output directory. Intermediate logs from failed builds remain in a
printed staging path beneath `dist/`.

If your notarization profile is stored in a custom keychain, also set
`NOTARYTOOL_KEYCHAIN` to that keychain's path. The GitHub workflow uses this to
keep notarization credentials in its temporary signing keychain.

For a local compile/package check without Apple credentials:

```sh
bash scripts/build_release.sh --unsigned 0.1.0 1
```

This produces `dist/unsigned/0.1.0/VibeStatus-0.1.0-unsigned.zip`, which is for
local validation only. Signed releases use a separate output path, and the cask
generator rejects unsigned builds.

## Recover a tap update

If publishing succeeded but updating Homebrew failed, fix tap access and update
the tap without rebuilding or replacing the released ZIP:

```sh
mkdir -p dist/tap-recovery/0.1.0
gh release download v0.1.0 --repo jchy20/vibe-status \
  --pattern vibe-status.rb --dir dist/tap-recovery/0.1.0
python3 scripts/update_homebrew_tap.py 0.1.0 \
  dist/tap-recovery/0.1.0/vibe-status.rb
```

The updater is a no-op when the current cask already matches. If an earlier run
left an unpublished draft release, inspect it before removing the draft and
retrying. Never replace the ZIP for an already published version; release a new
version instead.
