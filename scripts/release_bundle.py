#!/usr/bin/env python3
"""Sign nested release code inside out and verify the packaged universal app."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
CODE_BUNDLES = {".app", ".framework", ".xpc", ".appex", ".plugin", ".bundle"}


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def signing_identity(requested):
    identities = re.findall(
        r'\d+\) ([0-9A-Fa-f]{40}) "(Developer ID Application: [^"]+)"',
        run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"),
    )
    matches = [sha for sha, name in identities if requested == name or requested.upper() == sha.upper()]
    if len(matches) != 1:
        raise ValueError(
            "DEVELOPER_ID_APPLICATION must match exactly one valid Developer ID Application "
            "certificate and private key in the keychain (full certificate name or SHA-1)."
        )
    print(matches[0])


def bundle_info(bundle):
    for relative in ("Contents/Info.plist", "Resources/Info.plist", "Info.plist"):
        candidate = bundle / relative
        if candidate.is_file():
            with candidate.open("rb") as stream:
                return plistlib.load(stream)
    return {}


def code_paths(app):
    binaries = []
    bundles = [app]
    # Do not follow framework version symlinks: sign their real code once.
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    binaries.append(path)
        elif path.is_dir() and path.suffix in CODE_BUNDLES:
            if bundle_info(path).get("CFBundleExecutable"):
                bundles.append(path)
    if not binaries:
        raise ValueError("The app contains no Mach-O executables.")
    return sorted(binaries), sorted(bundles, key=lambda p: (-len(p.parts), str(p)))


def sign(app, identity):
    binaries, bundles = code_paths(app)
    # First sign every Mach-O image, including loose helpers and dylibs. Next seal
    # nested code bundles deepest first, ending with the outer app. Signing the
    # containing bundle also gives its main executable the bundle identifier.
    # Never use codesign --deep for signing.
    for path in binaries + bundles:
        print(f"Signing {path.relative_to(app.parent)}", flush=True)
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", identity,
            "--options", "runtime", "--timestamp", str(path),
        ], check=True)


def minimum_macos(path, architecture):
    build_info = run("/usr/bin/xcrun", "vtool", "-arch", architecture, "-show-build", str(path))
    versions = []
    # Xcode's Swift compatibility libraries may also contain Mac Catalyst load
    # commands and use the older macOS minimum-version command on Intel.
    for block in re.split(r"(?m)^Load command \d+\n", build_info):
        if re.search(r"^\s*cmd LC_VERSION_MIN_MACOSX$", block, re.MULTILINE):
            match = re.search(r"^\s*version\s+([\d.]+)$", block, re.MULTILINE)
        elif re.search(r"^\s*platform MACOS$", block, re.MULTILINE):
            match = re.search(r"^\s*minos\s+([\d.]+)$", block, re.MULTILINE)
        else:
            continue
        if match:
            versions.append(match.group(1))
    if len(versions) != 1:
        raise ValueError(f"{path} ({architecture}): cannot determine the macOS deployment target.")
    return versions[0]


def version_tuple(version):
    components = tuple(int(component) for component in version.split("."))
    return components + (0,) * (3 - len(components))


def inspect(app, version, build_number, signed):
    info = bundle_info(app)
    for key, expected in (
        ("CFBundleIdentifier", "com.jamescai.VibeStatus"),
        ("CFBundleShortVersionString", version),
        ("CFBundleVersion", build_number),
        ("LSMinimumSystemVersion", "14.0"),
    ):
        if info.get(key) != expected:
            raise ValueError(f"{key}: expected {expected!r}, got {info.get(key)!r}")
    binaries, bundles = code_paths(app)
    executable = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
    if executable not in binaries:
        raise ValueError("The app's main executable is missing.")
    binary_records = []
    teams = set()
    for path in binaries:
        architectures = run("/usr/bin/lipo", "-archs", str(path)).split()
        if not {"arm64", "x86_64"}.issubset(architectures):
            raise ValueError(f"{path}: missing arm64 or x86_64, got {architectures}")
        minimum_versions = {arch: minimum_macos(path, arch) for arch in architectures}
        for architecture, minimum in minimum_versions.items():
            if version_tuple(minimum) > (14, 0, 0):
                raise ValueError(f"{path} ({architecture}) requires macOS {minimum}, newer than 14.0.")
            if path == executable and version_tuple(minimum) != (14, 0, 0):
                raise ValueError(f"The app's {architecture} slice must target macOS 14.0.")
        if signed:
            run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(path))
            for architecture in architectures:
                signature = run("/usr/bin/codesign", "--display", "--verbose=4", "--arch", architecture, str(path))
                for required in ("runtime)", "Authority=Developer ID Application:", "Timestamp="):
                    if required not in signature:
                        raise ValueError(f"{path} ({architecture}): missing {required} in signature.")
                team = re.search(r"^TeamIdentifier=(\S+)$", signature, re.MULTILINE)
                if not team or team.group(1) == "not set":
                    raise ValueError(f"{path}: signature has no team identifier.")
                teams.add(team.group(1))
        binary_records.append({
            "path": str(path.relative_to(app)),
            "architectures": architectures,
            "minimum_macos_by_architecture": minimum_versions,
        })
    if signed:
        if len(teams) != 1:
            raise ValueError(f"Nested code has different signing teams: {sorted(teams)}")
        for bundle in bundles:
            run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(bundle))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
    print(json.dumps({
        "version": version,
        "build_number": build_number,
        "bundle_identifier": info["CFBundleIdentifier"],
        "minimum_macos": "14.0",
        "developer_id_signed": signed,
        "signing_team": next(iter(teams), None),
        "binaries": binary_records,
    }, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("requested")
    sign_parser = subparsers.add_parser("sign")
    sign_parser.add_argument("app", type=Path)
    sign_parser.add_argument("identity")
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("app", type=Path)
    inspect_parser.add_argument("version")
    inspect_parser.add_argument("build_number")
    inspect_parser.add_argument("--signed", action="store_true")
    args = parser.parse_args()
    if args.command == "identity":
        signing_identity(args.requested)
    elif args.command == "sign":
        sign(args.app.resolve(), args.identity)
    else:
        inspect(args.app.resolve(), args.version, args.build_number, args.signed)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        sys.exit(1)
