#!/bin/bash
# Build a universal macOS release. Unsigned output is only for local validation.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build_release.sh [--notarized | --unsigned] VERSION BUILD_NUMBER

The default release uses ad-hoc code signatures and requires no Apple account.
It is not notarized; macOS may require a manual first-launch approval.
Output: dist/releases/VERSION/VibeStatus-VERSION.zip and .zip.sha256

--notarized opts into Developer ID signing and Apple notarization. It requires
DEVELOPER_ID_APPLICATION (certificate name or SHA-1) and NOTARYTOOL_PROFILE
(an existing notarytool keychain profile).

--unsigned skips packaging signatures for LOCAL VALIDATION ONLY.
Output: dist/unsigned/VERSION/VibeStatus-VERSION-unsigned.zip and .zip.sha256

Optional: DEVELOPER_DIR, RELEASE_DERIVED_DATA_PATH,
RELEASE_SOURCE_PACKAGES_PATH, NOTARYTOOL_KEYCHAIN (file-based keychain path),
NOTARIZATION_TIMEOUT (default: 30m).
An existing output directory is never overwritten.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

signing_mode=adhoc
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--unsigned" ]]; then
  signing_mode=unsigned
  shift
elif [[ "${1:-}" == "--notarized" ]]; then
  signing_mode=notarized
  shift
fi
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
version=$1
build_number=$2
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'VERSION must be X.Y.Z without leading zeroes, such as 0.1.0.'
[[ $build_number =~ ^[1-9][0-9]*$ ]] || die 'BUILD_NUMBER must be a positive integer.'
[[ $(uname -s) == Darwin ]] || die 'A Mac with full Xcode is required.'

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_dir=$(dirname -- "$script_dir")
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v python3 >/dev/null || die 'Python 3 is required.'
xcodebuild -version >/dev/null || die 'Select a full Xcode installation using DEVELOPER_DIR.'
derived_data=${RELEASE_DERIVED_DATA_PATH:-"$repository_dir/DerivedData/Release"}
source_packages=${RELEASE_SOURCE_PACKAGES_PATH:-"$repository_dir/DerivedData/SourcePackages"}

if [[ $signing_mode == unsigned ]]; then
  output_dir="$repository_dir/dist/unsigned/$version"
  archive_name="VibeStatus-$version-unsigned.zip"
else
  output_dir="$repository_dir/dist/releases/$version"
  archive_name="VibeStatus-$version.zip"
fi
[[ ! -e "$output_dir" ]] || die "Output already exists: $output_dir"

# Only the opt-in notarized route needs Apple credentials. Never silently
# downgrade an explicitly requested notarized release if credentials are missing.
hardened_runtime=NO
if [[ $signing_mode == notarized ]]; then
  hardened_runtime=YES
  [[ -n ${DEVELOPER_ID_APPLICATION:-} ]] || die 'Set DEVELOPER_ID_APPLICATION to a valid Developer ID Application signing identity.'
  [[ -n ${NOTARYTOOL_PROFILE:-} ]] || die 'Set NOTARYTOOL_PROFILE to an existing notarytool keychain profile.'
  signing_identity=$(python3 "$script_dir/release_bundle.py" identity "$DEVELOPER_ID_APPLICATION")
  notary_options=(--keychain-profile "$NOTARYTOOL_PROFILE")
  if [[ -n ${NOTARYTOOL_KEYCHAIN:-} ]]; then
    notary_options+=(--keychain "$NOTARYTOOL_KEYCHAIN")
  fi
  xcrun notarytool history "${notary_options[@]}" --output-format json >/dev/null
fi

mkdir -p "$repository_dir/dist" "$(dirname -- "$output_dir")"
staging_dir=$(mktemp -d "$repository_dir/dist/.release-$version.XXXXXX")
on_exit() {
  status=$?
  if [[ $status -ne 0 ]]; then
    printf 'Release failed. Logs and intermediates: %s\n' "$staging_dir" >&2
  fi
}
trap on_exit EXIT

printf 'Building Vibe Status %s (%s) for arm64 and x86_64…\n' "$version" "$build_number"
xcodebuild -quiet \
  -project "$repository_dir/VibeStatus.xcodeproj" \
  -scheme VibeStatus \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  ENABLE_HARDENED_RUNTIME="$hardened_runtime" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$staging_dir/build.log"

app_path="$staging_dir/VibeStatus.app"
ditto "$derived_data/Build/Products/Release/VibeStatus.app" "$app_path"
python3 "$script_dir/release_bundle.py" inspect "$app_path" "$version" "$build_number" \
  > "$staging_dir/release.json"

if [[ $signing_mode == adhoc ]]; then
  python3 "$script_dir/release_bundle.py" sign "$app_path" -
  python3 "$script_dir/release_bundle.py" inspect "$app_path" "$version" "$build_number" --adhoc \
    > "$staging_dir/release.json"
  printf 'Created ad-hoc signatures. This release is not notarized by Apple.\n'
elif [[ $signing_mode == notarized ]]; then
  python3 "$script_dir/release_bundle.py" sign "$app_path" "$signing_identity"
  python3 "$script_dir/release_bundle.py" inspect "$app_path" "$version" "$build_number" --signed \
    > "$staging_dir/release.json"

  # ZIPs cannot themselves receive a stapled ticket. Submit an initial ZIP, staple
  # the accepted app, then produce the final downloadable ZIP from that app.
  submission_zip="$staging_dir/notarization-upload.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
  xcrun notarytool submit "$submission_zip" \
    "${notary_options[@]}" \
    --wait --timeout "${NOTARIZATION_TIMEOUT:-30m}" \
    --output-format json > "$staging_dir/notarization.json"
  notarization_status=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["status"])' "$staging_dir/notarization.json")
  if [[ $notarization_status != Accepted ]]; then
    submission_id=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$staging_dir/notarization.json")
    xcrun notarytool log "$submission_id" "${notary_options[@]}" \
      "$staging_dir/notarization-log.json" || true
    die "Notarization was $notarization_status; inspect notarization-log.json."
  fi
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  codesign --verify --deep --strict --all-architectures "$app_path"
  spctl --assess --type execute --verbose=2 "$app_path"
  python3 "$script_dir/release_bundle.py" inspect "$app_path" "$version" "$build_number" --notarized \
    > "$staging_dir/release.json"
  rm -f -- "$submission_zip"
else
  printf 'UNSIGNED LOCAL VALIDATION BUILD: do not publish this archive.\n' >&2
fi

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/$archive_name"
(
  cd -- "$staging_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
mv -- "$staging_dir" "$output_dir"
trap - EXIT
printf 'Created %s/%s\n' "$output_dir" "$archive_name"
printf 'Checksum: %s/%s.sha256\n' "$output_dir" "$archive_name"
