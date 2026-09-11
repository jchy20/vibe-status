#!/usr/bin/env python3
"""Publish a generated cask after verifying its public GitHub release asset."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from generate_homebrew_cask import render_cask


def gh(*args, payload=None):
    command = ["gh", *args]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("cask", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        parser.error("version must be a stable X.Y.Z version")
    content = args.cask.read_text()
    sha = re.search(r'^  sha256 "([0-9a-f]{64})"$', content, re.MULTILINE)
    if not sha or content != render_cask(args.version, sha.group(1)):
        parser.error("cask does not match the generated Vibe Status release template")

    source = gh("api", "repos/jchy20/vibe-status")
    if source["private"]:
        parser.error("the source release repository must be public for Homebrew downloads")
    release = gh("api", f"repos/jchy20/vibe-status/releases/tags/v{args.version}")
    if release["draft"] or release["prerelease"]:
        parser.error("the stable release must be published before updating Homebrew")
    with tempfile.TemporaryDirectory(prefix="vibe-status-release-") as directory:
        filename = f"VibeStatus-{args.version}.zip"
        subprocess.run(["gh", "release", "download", f"v{args.version}",
                        "--repo", "jchy20/vibe-status", "--pattern", filename,
                        "--dir", directory], check=True)
        digest = hashlib.sha256()
        with (Path(directory) / filename).open("rb") as archive:
            for chunk in iter(lambda: archive.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != sha.group(1):
            parser.error("published ZIP checksum does not match the cask")

    repo = "jchy20/homebrew-tap"
    metadata = gh("api", f"repos/{repo}")
    if metadata["private"]:
        parser.error("the Homebrew tap must be public")
    branch = metadata["default_branch"]
    # Reading the tree distinguishes a missing cask from authentication/API errors.
    tree = gh("api", f"repos/{repo}/git/trees/{branch}?recursive=1")
    if tree.get("truncated"):
        parser.error("tap tree is truncated; cannot safely determine the existing cask")
    entry = next((item for item in tree["tree"] if item["path"] == "Casks/vibe-status.rb"), None)
    if entry:
        current = gh("api", f"repos/{repo}/git/blobs/{entry['sha']}")
        previous = base64.b64decode(current["content"]).decode()
        if previous == content:
            print("Homebrew cask already matches this release.")
            return
        version = re.search(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', previous, re.MULTILINE)
        if version and tuple(map(int, version.group(1).split("."))) >= tuple(map(int, args.version.split("."))):
            parser.error("refusing to downgrade or replace an existing released version")
    payload = {
        "message": f"Update Vibe Status to {args.version}",
        "content": base64.b64encode(content.encode()).decode(),
        "branch": branch,
    }
    if entry:
        payload["sha"] = entry["sha"]
    gh("api", "--method", "PUT", f"repos/{repo}/contents/Casks/vibe-status.rb", payload=payload)
    print("Published: brew install --cask jchy20/tap/vibe-status")


if __name__ == "__main__":
    main()
