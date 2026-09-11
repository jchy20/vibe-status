from __future__ import annotations

import base64
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


REPOSITORY = Path(__file__).resolve().parents[2]


def load_script(name):
    specification = importlib.util.spec_from_file_location(name, REPOSITORY / "scripts" / f"{name}.py")
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    with mock.patch.object(sys, "path", [str(REPOSITORY / "scripts"), *sys.path]):
        specification.loader.exec_module(module)
    return module


generator = load_script("generate_homebrew_cask")
updater = load_script("update_homebrew_tap")


class HomebrewTapUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        archive = directory / "VibeStatus-0.2.0.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("VibeStatus.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.jamescai.VibeStatus",
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleExecutable": "VibeStatus",
                "LSMinimumSystemVersion": "14.0",
            }))
            output.writestr("VibeStatus.app/Contents/MacOS/VibeStatus", b"fixture executable")
            output.writestr("VibeStatus.app/Contents/_CodeSignature/CodeResources", b"fixture signature")
        with mock.patch.object(generator, "verify_packaged_app"):
            self.content = generator.generate_cask("0.2.0", archive)
        self.cask = directory / "vibe-status.rb"
        self.cask.write_text(self.content)
        self.download_bytes = archive.read_bytes()
        self.release = {"draft": False, "prerelease": False}
        self.source = {"private": False, "default_branch": "main"}
        self.tree = {"truncated": False, "tree": []}
        self.previous = None
        self.calls = []
        self.writes = []
        self.api_error = None

    def gh(self, *args, payload=None):
        self.calls.append(args)
        if self.api_error:
            raise self.api_error
        endpoint = args[-1]
        if "PUT" in args:
            self.assertEqual(endpoint, "repos/jchy20/vibe-status/contents/Casks/vibe-status.rb")
            self.writes.append(payload)
            return {}
        if endpoint == "repos/jchy20/vibe-status":
            return self.source
        if endpoint == "repos/jchy20/vibe-status/releases/tags/v0.2.0":
            return self.release
        if endpoint == "repos/jchy20/vibe-status/git/trees/main?recursive=1":
            return self.tree
        if endpoint == "repos/jchy20/vibe-status/git/blobs/previous-blob":
            return {"content": base64.b64encode(self.previous.encode()).decode()}
        self.fail(f"Unexpected GitHub API call: {args!r}")

    def download(self, command, **kwargs):
        self.assertEqual(command[:3], ["gh", "release", "download"])
        self.assertNotIn("shell", kwargs)
        target = Path(command[command.index("--dir") + 1])
        filename = command[command.index("--pattern") + 1]
        (target / filename).write_bytes(self.download_bytes)
        return subprocess.CompletedProcess(command, 0)

    def run_updater(self, version="0.2.0", *, notarized=False):
        arguments = ["update_homebrew_tap.py", version, str(self.cask)]
        if notarized:
            arguments.append("--notarized")
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(updater, "gh", side_effect=self.gh),
            mock.patch.object(updater.subprocess, "run", side_effect=self.download),
            redirect_stdout(io.StringIO()),
            redirect_stderr(io.StringIO()),
        ):
            return updater.main()

    def existing_cask(self, content):
        self.previous = content
        self.tree["tree"] = [{"path": "Casks/vibe-status.rb", "sha": "previous-blob", "type": "blob"}]

    def test_first_release_publishes_exact_generated_cask(self) -> None:
        self.run_updater()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(base64.b64decode(self.writes[0]["content"]).decode(), self.content)
        self.assertEqual(self.writes[0]["branch"], "main")
        self.assertNotIn("sha", self.writes[0])

    def test_upgrade_includes_previous_blob_for_conflict_detection(self) -> None:
        self.existing_cask(self.content.replace('version "0.2.0"', 'version "0.1.0"'))
        self.run_updater()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0]["sha"], "previous-blob")

    def test_identical_release_is_idempotent(self) -> None:
        self.existing_cask(self.content)
        self.run_updater()
        self.assertEqual(self.writes, [])

    def test_downgrade_or_replacement_of_same_version_is_rejected(self) -> None:
        for previous in (
            self.content.replace('version "0.2.0"', 'version "0.3.0"'),
            self.content + "\n# different existing content\n",
        ):
            with self.subTest(previous=previous):
                self.existing_cask(previous)
                with self.assertRaises(SystemExit):
                    self.run_updater()
                self.assertEqual(self.writes, [])

    def test_draft_and_prerelease_cannot_be_published_to_stable_cask(self) -> None:
        for release in ({"draft": True, "prerelease": False}, {"draft": False, "prerelease": True}):
            with self.subTest(release=release):
                self.release = release
                with self.assertRaises(SystemExit):
                    self.run_updater()
                self.assertEqual(self.writes, [])

    def test_downloaded_archive_must_match_generated_checksum(self) -> None:
        self.download_bytes = b"a different release artifact"
        with self.assertRaises(SystemExit):
            self.run_updater()
        self.assertEqual(self.writes, [])

    def test_private_source_repository_is_rejected(self) -> None:
        self.source["private"] = True
        with self.assertRaises(SystemExit):
            self.run_updater()
        self.assertEqual(self.writes, [])

    def test_caveat_cannot_be_removed_from_default_free_release(self) -> None:
        digest = generator.hashlib.sha256(self.download_bytes).hexdigest()
        self.cask.write_text(generator.render_cask("0.2.0", digest, notarized=True))
        with self.assertRaises(SystemExit):
            self.run_updater()
        self.assertEqual(self.calls, [])
        self.run_updater(notarized=True)
        self.assertEqual(len(self.writes), 1)

    def test_additional_ruby_code_or_conflicting_stanzas_are_rejected(self) -> None:
        for extra in ('\nsystem("unexpected")\n', '\n  version "99.0.0"\n', '\n  app "Other.app"\n'):
            with self.subTest(extra=extra):
                self.cask.write_text(self.content + extra)
                with self.assertRaises(SystemExit):
                    self.run_updater()
                self.assertEqual(self.calls, [])

    def test_truncated_tree_is_not_treated_as_missing_cask(self) -> None:
        self.tree["truncated"] = True
        with self.assertRaises(SystemExit):
            self.run_updater()
        self.assertEqual(self.writes, [])

    def test_api_failure_is_not_treated_as_missing_cask(self) -> None:
        self.api_error = subprocess.CalledProcessError(1, ["gh", "api"], stderr="HTTP 403")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_updater()
        self.assertEqual(self.writes, [])

    def test_invalid_version_and_release_mapping_fail_before_github_calls(self) -> None:
        with self.assertRaises(SystemExit):
            self.run_updater('0.2.0"; system("unexpected")')
        self.assertEqual(self.calls, [])
        for original, replacement in (
            ('version "0.2.0"', 'version "0.3.0"'),
            ("https://github.com/jchy20/vibe-status", "https://example.com/untrusted"),
            ("sha256", "invalid_checksum"),
        ):
            with self.subTest(replacement=replacement):
                self.cask.write_text(self.content.replace(original, replacement))
                with self.assertRaises(SystemExit):
                    self.run_updater()
                self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
