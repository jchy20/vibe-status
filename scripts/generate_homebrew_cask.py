#!/usr/bin/env python3
"""Generate a cask from the final, signed and stapled universal release ZIP.

Run on macOS after release packaging has produced the final artifact. Native
Apple tools verify the packaged app; there is deliberately no verification bypass.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


REPOSITORY_URL = "https://github.com/jchy20/vibe-status"
BUNDLE_ID = "com.jamescai.VibeStatus"
APP_NAME = "VibeStatus.app"
VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


class ReleaseValidationError(ValueError):
    """The input cannot safely be advertised as an installable release."""


def validate_version(version: str) -> None:
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseValidationError("version must be a stable version such as 0.1.0 (without a v prefix)")


def inspect_archive(archive_path: Path, version: str) -> None:
    """Check archive paths and bundle metadata before invoking native extraction."""
    with zipfile.ZipFile(archive_path) as archive:
        members = archive.infolist()
        names = set()
        for member in members:
            path = PurePosixPath(member.filename)
            if (
                not path.parts
                or path.is_absolute()
                or ".." in path.parts
                or "\\" in member.filename
                or path.parts[0] not in {APP_NAME, "__MACOSX"}
                or member.filename in names
            ):
                raise ReleaseValidationError(f"unsafe or unexpected archive path: {member.filename!r}")
            names.add(member.filename)
            if stat.S_ISLNK(member.external_attr >> 16):
                target = archive.read(member).decode("utf-8")
                if (
                    not target
                    or target.startswith("/")
                    or ".." in PurePosixPath(target).parts
                    or "\\" in target
                    or "\x00" in target
                ):
                    raise ReleaseValidationError(f"unsafe archive symlink: {member.filename!r}")
                # Standard framework links use child paths such as
                # Versions/Current. Disallow parent paths even when they appear
                # safe lexically: chained symlinks can change their destination.

        required = {
            f"{APP_NAME}/Contents/Info.plist",
            f"{APP_NAME}/Contents/MacOS/VibeStatus",
            f"{APP_NAME}/Contents/_CodeSignature/CodeResources",
        }
        if not required.issubset(names):
            raise ReleaseValidationError("ZIP must contain VibeStatus.app with its executable and code signature")
        metadata = plistlib.loads(archive.read(f"{APP_NAME}/Contents/Info.plist"))
        if not isinstance(metadata, dict):
            raise ReleaseValidationError("app Info.plist must contain a dictionary")
        if metadata.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ReleaseValidationError(f"app bundle identifier must be {BUNDLE_ID}")
        if metadata.get("CFBundleShortVersionString") != version:
            raise ReleaseValidationError("app version does not match the requested release version")
        if metadata.get("CFBundleExecutable") != "VibeStatus":
            raise ReleaseValidationError("app executable must be VibeStatus")
        if metadata.get("LSMinimumSystemVersion") not in {"14", "14.0", "14.0.0"}:
            raise ReleaseValidationError("app minimum macOS version must match the cask's macOS 14 requirement")


def run_checked(command: list[str]) -> str:
    result = subprocess.run(command, check=False, text=True, capture_output=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise ReleaseValidationError(f"{Path(command[0]).name} verification failed: {detail}")
    return result.stdout + result.stderr


def verify_packaged_app(archive_path: Path, destination: Path) -> None:
    if sys.platform != "darwin":
        raise ReleaseValidationError("cask generation must run on macOS to verify signing and notarization")
    run_checked(["/usr/bin/ditto", "-x", "-k", str(archive_path), str(destination)])
    app = destination / APP_NAME
    run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)])
    for architecture in ("arm64", "x86_64"):
        signature = run_checked([
            "/usr/bin/codesign", "--display", "--verbose=4", "--arch", architecture, str(app)
        ])
        if not re.search(r"^Authority=Developer ID Application:", signature, re.MULTILINE):
            raise ReleaseValidationError(f"{architecture} app must have a Developer ID Application signature")
        if not re.search(r"^CodeDirectory .*flags=.*\bruntime\b", signature, re.MULTILINE):
            raise ReleaseValidationError(f"{architecture} app signature must enable the hardened runtime")
        timestamp = re.search(r"^Timestamp=(.+)$", signature, re.MULTILINE)
        if not timestamp or timestamp.group(1).strip().lower() in {"none", "not set"}:
            raise ReleaseValidationError(f"{architecture} app signature must have a secure timestamp")
    run_checked(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    architectures = run_checked(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/VibeStatus")])
    if set(architectures.split()) != {"arm64", "x86_64"}:
        raise ReleaseValidationError("app must contain both arm64 and x86_64 architectures")


def generate_cask(version: str, archive_path: Path) -> str:
    validate_version(version)
    expected_name = f"VibeStatus-{version}.zip"
    if archive_path.name != expected_name:
        raise ReleaseValidationError(f"release ZIP must be named {expected_name}; preview builds cannot be published")
    if not archive_path.is_file():
        raise ReleaseValidationError(f"release ZIP does not exist: {archive_path}")

    with tempfile.TemporaryDirectory(prefix="vibe-status-cask-") as directory:
        temporary = Path(directory)
        # Verify and hash the same snapshot, even if the source is replaced while
        # this command runs. ditto preserves the packaged signature and ticket.
        snapshot = temporary / expected_name
        shutil.copyfile(archive_path, snapshot)
        inspect_archive(snapshot, version)
        verify_packaged_app(snapshot, temporary / "unpacked")
        digest = hashlib.sha256()
        with snapshot.open("rb") as release_file:
            for chunk in iter(lambda: release_file.read(1024 * 1024), b""):
                digest.update(chunk)

    return render_cask(version, digest.hexdigest())


def render_cask(version: str, sha256: str) -> str:
    """Render the canonical cask; callers must verify the release artifact first."""
    validate_version(version)
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ReleaseValidationError("release checksum must be a lowercase SHA-256 hex digest")
    return f'''cask "vibe-status" do
  version "{version}"
  sha256 "{sha256}"

  url "{REPOSITORY_URL}/releases/download/v#{{version}}/VibeStatus-#{{version}}.zip"
  name "Vibe Status"
  desc "Menu bar status for Codex and Claude Code tasks on remote hosts"
  homepage "{REPOSITORY_URL}"

  depends_on macos: ">= :sonoma"

  app "VibeStatus.app"

  zap trash: "~/Library/Preferences/{BUNDLE_ID}.plist"
end
'''


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="stable release version without a v prefix, e.g. 0.1.0")
    parser.add_argument("archive", type=Path, help="final signed and stapled VibeStatus-VERSION.zip")
    parser.add_argument("--output", type=Path, help="write the cask to this path (default: stdout)")
    args = parser.parse_args(argv)
    try:
        cask = generate_cask(args.version, args.archive)
        if args.output:
            if args.output.resolve() == args.archive.resolve():
                raise ReleaseValidationError("output path must not overwrite the release ZIP")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(cask, encoding="utf-8")
        else:
            sys.stdout.write(cask)
    except (ReleaseValidationError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException, UnicodeError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
