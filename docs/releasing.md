# Releasing Vibe Status

Vibe Status uses a prebuilt, unnotarized app distributed through a personal
Homebrew tap. The public `jchy20/vibe-status` repository holds both the source
and `Casks/vibe-status.rb`; there is no separate tap repository.

The default release workflow requires **no paid Apple Developer account, Apple
credentials, or custom GitHub token**. GitHub Actions uses its automatically
provided repository token to publish release assets and update the cask.

## What users install

Each release contains a universal macOS 14+ app for Apple Silicon and Intel.
Its executables and embedded frameworks have local ad-hoc signatures that allow
their code integrity to be checked. The app is **not signed with Developer ID
and is not notarized by Apple**.

Users install it with:

```sh
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
brew install --cask jchy20/vibe-status/vibe-status
open -a VibeStatus
```

The explicit repository URL is necessary because this tap shares the app's
source repository rather than using a repository named `homebrew-*`.

If macOS blocks the first launch, a user who trusts the release can try opening
it, then select **System Settings → Privacy & Security → Open Anyway** and
confirm. This is a per-app approval. Homebrew retains the normal quarantine
attribute; the cask does not change macOS security settings or remove quarantine.
See [Apple's first-launch instructions](https://support.apple.com/en-us/102445).

This distribution is for our personal tap. It does not meet the notarization
requirements of the official `homebrew/cask` catalog.

## Publish a release

After the source changes and tests are ready, push a new version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Versions use `X.Y.Z` without leading zeroes. Tag creation triggers
`.github/workflows/release.yml`, which:

1. Runs the distribution and Xcode Release tests.
2. Builds the universal app and signs its nested code locally.
3. Validates the packaged app, creates the ZIP and checksum, and generates the cask.
4. Creates a draft GitHub release with all assets, then publishes it.
5. Downloads the published ZIP, verifies the checksum, and commits the cask to
   `Casks/vibe-status.rb` on the repository's default branch.

The workflow can also be started from **Actions → Release → Run workflow** with
a version, or with an authenticated GitHub CLI:

```sh
gh workflow run release.yml --repo jchy20/vibe-status -f version=0.1.0
```

Build numbers come from the Actions run number. Manual runs reject version tags
that point to a different commit. Published versions are not overwritten: use a
new version when changing app binaries. After the workflow's cask commit, update
your local checkout with `git pull --ff-only`.

The repository must remain public for unauthenticated Homebrew downloads.
GitHub Actions must be enabled and allowed to write repository contents. Branch
rules, if added later, must permit the cask update or the updater will need to
create a pull request instead.

## Release assets

- `VibeStatus-X.Y.Z.zip`: prebuilt, ad-hoc-signed universal app.
- `VibeStatus-X.Y.Z.zip.sha256`: checksum of that exact ZIP.
- `vibe-status.rb`: generated Homebrew cask.
- `release.json`: bundle, architecture and signing metadata.

The cask generator validates archive paths, bundle identity and version, minimum
macOS version, supported architectures, and nested code signatures. It computes
the checksum from the same archive snapshot it validates. The tap updater checks
that checksum against the public release before committing and rejects version
downgrades or replacing an existing version with different content.

Failed-build diagnostics remain available as GitHub Actions artifacts. Unsigned
local preview archives remain separate and are not accepted as release casks.

## Local packaging

On a Mac with full Xcode:

```sh
bash scripts/build_release.sh 0.1.0 2
python3 scripts/generate_homebrew_cask.py 0.1.0 \
  dist/releases/0.1.0/VibeStatus-0.1.0.zip \
  --output dist/releases/0.1.0/vibe-status.rb
```

Output is under `dist/releases/X.Y.Z/`. Existing version directories are never
overwritten. Failed-build intermediates remain in a printed staging directory
beneath `dist/`. The default build requires no signing certificate.

To compile and package a local preview without even local ad-hoc signing:

```sh
bash scripts/build_release.sh --unsigned 0.1.0 2
```

This produces `dist/unsigned/0.1.0/VibeStatus-0.1.0-unsigned.zip` for local
validation only.

## Verify installation

On a Mac with Homebrew:

```sh
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
brew install --cask jchy20/vibe-status/vibe-status
open -a VibeStatus
```

Check the first-launch approval and the app's SSH setup on supported hardware.
Building both architectures alone is not a runtime test on an Intel Mac.
`brew audit --cask --signing` is expected to reject this unnotarized release;
Developer ID signing is not an acceptance requirement for our personal tap.

## Recover a tap update

If release publication succeeded but the cask commit failed, fix repository
write access and run the updater without rebuilding the ZIP:

```sh
mkdir -p dist/tap-recovery/0.1.0
gh release download v0.1.0 --repo jchy20/vibe-status \
  --pattern vibe-status.rb --dir dist/tap-recovery/0.1.0
python3 scripts/update_homebrew_tap.py 0.1.0 \
  dist/tap-recovery/0.1.0/vibe-status.rb
```

This uses your authenticated GitHub CLI login and is a no-op if the cask already
matches. If a failed run left an unpublished draft release, inspect that draft
before removing it and retrying. Publish a new version to change an already
released ZIP.

## Optional Developer ID releases later

The packaging script also supports `--notarized` for a future paid Developer ID
setup. Configure a valid `DEVELOPER_ID_APPLICATION` identity and a
`NOTARYTOOL_PROFILE` in Keychain, then use:

```sh
bash scripts/build_release.sh --notarized 0.2.0 3
python3 scripts/generate_homebrew_cask.py --notarized 0.2.0 \
  dist/releases/0.2.0/VibeStatus-0.2.0.zip \
  --output dist/releases/0.2.0/vibe-status.rb
```

Set `NOTARYTOOL_KEYCHAIN` as well if the profile is in a custom keychain. This
opt-in path signs with Developer ID, submits to Apple, staples the ticket and
checks Gatekeeper. The default GitHub workflow uses the free route; a future
switch also needs corresponding release notes and CI credential setup.
When publishing or recovering a notarized cask, also pass `--notarized` to
`scripts/update_homebrew_tap.py` so it accepts the notarized cask template.
