from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


REPOSITORY = Path(__file__).resolve().parents[2]
SPECIFICATION = importlib.util.spec_from_file_location(
    "generate_homebrew_cask", REPOSITORY / "scripts/generate_homebrew_cask.py"
)
assert SPECIFICATION and SPECIFICATION.loader
cask = importlib.util.module_from_spec(SPECIFICATION)
with mock.patch.object(sys, "path", [str(REPOSITORY / "scripts"), *sys.path]):
    SPECIFICATION.loader.exec_module(cask)


class HomebrewCaskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def make_archive(self, version="0.1.0", *, filename=None, metadata=None, signed=True, extra=None):
        archive_path = self.directory / (filename or f"VibeStatus-{version}.zip")
        info = {
            "CFBundleIdentifier": "com.jamescai.VibeStatus",
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "VibeStatus",
            "LSMinimumSystemVersion": "14.0",
        }
        info.update(metadata or {})
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("VibeStatus.app/Contents/Info.plist", plistlib.dumps(info))
            archive.writestr("VibeStatus.app/Contents/MacOS/VibeStatus", b"fixture executable")
            if signed:
                archive.writestr("VibeStatus.app/Contents/_CodeSignature/CodeResources", b"fixture signature")
            for name, data in (extra or {}).items():
                archive.writestr(name, data)
        return archive_path

    def test_checksum_and_download_url_refer_to_the_exact_release(self) -> None:
        archive = self.make_archive()
        with mock.patch.object(cask, "verify_packaged_app") as verification:
            result = cask.generate_cask("0.1.0", archive)
        verification.assert_called_once()
        self.assertIn(f'sha256 "{hashlib.sha256(archive.read_bytes()).hexdigest()}"', result)
        self.assertIn('version "0.1.0"', result)
        self.assertIn(
            'url "https://github.com/jchy20/vibe-status/releases/download/v#{version}/VibeStatus-#{version}.zip"',
            result,
        )
        self.assertIn('depends_on macos: :sonoma', result)
        self.assertIn('app "VibeStatus.app"', result)
        self.assertNotIn("auto_updates", result)
        self.assertNotIn("depends_on arch:", result)
        self.assertIn('zap trash: "~/Library/Preferences/com.jamescai.VibeStatus.plist"', result)
        self.assertIn("This release is not notarized by Apple.", result)
        self.assertIn("After opening Vibe Status", result)
        self.assertIn("System Settings > Privacy & Security > Open Anyway", result)
        self.assertNotIn("quarantine", result)

    def test_checksum_changes_when_archive_content_changes(self) -> None:
        archive = self.make_archive()
        with mock.patch.object(cask, "verify_packaged_app"):
            before = cask.generate_cask("0.1.0", archive)
            self.make_archive(extra={"VibeStatus.app/Contents/Resources/new.txt": b"new payload"})
            after = cask.generate_cask("0.1.0", archive)
        self.assertNotEqual(before, after)

    def test_version_rejects_injection_and_nonrelease_values_before_native_tools(self) -> None:
        versions = (
            '0.1.0"; system("touch /tmp/unwanted"); #',
            "0.1.0\n",
            "$(touch /tmp/unwanted)",
            "`touch /tmp/unwanted`",
            "../../0.1.0",
            "v0.1.0",
            "01.2.3",
            "0.1.0-preview",
            "latest",
        )
        for version in versions:
            with self.subTest(version=version), mock.patch.object(cask, "verify_packaged_app") as verification:
                with self.assertRaises(cask.ReleaseValidationError):
                    cask.generate_cask(version, Path("irrelevant.zip"))
                verification.assert_not_called()

    def test_preview_and_mismatched_filenames_are_rejected(self) -> None:
        for filename in ("VibeStatus-0.1.0-unsigned.zip", "VibeStatus-0.2.0.zip", "VibeStatus.zip"):
            with self.subTest(filename=filename):
                archive = self.make_archive(filename=filename)
                with self.assertRaises(cask.ReleaseValidationError):
                    cask.generate_cask("0.1.0", archive)

    def test_bundle_metadata_must_match_install_contract(self) -> None:
        for metadata in (
            {"CFBundleShortVersionString": "0.2.0"},
            {"CFBundleIdentifier": "com.other.app"},
            {"CFBundleExecutable": "OtherApp"},
            {"LSMinimumSystemVersion": "15.0"},
        ):
            with self.subTest(metadata=metadata):
                archive = self.make_archive(metadata=metadata)
                with self.assertRaises(cask.ReleaseValidationError):
                    cask.generate_cask("0.1.0", archive)

    def test_unsigned_bundle_is_rejected_even_with_release_filename(self) -> None:
        archive = self.make_archive(signed=False)
        with self.assertRaises(cask.ReleaseValidationError):
            cask.generate_cask("0.1.0", archive)

    def test_archive_paths_cannot_escape_or_install_another_app(self) -> None:
        for path in (
            "../outside",
            "/tmp/outside",
            "VibeStatus.app/../../outside",
            "VibeStatus.app/Contents/../../../outside",
            "VibeStatus.app\\..\\outside",
            "Another.app/Contents/Info.plist",
        ):
            with self.subTest(path=path):
                archive = self.make_archive(extra={path: b"unexpected"})
                with self.assertRaises(cask.ReleaseValidationError):
                    cask.generate_cask("0.1.0", archive)

    def test_escaping_symlink_is_rejected(self) -> None:
        for target in ("../../outside", "/tmp/outside"):
            with self.subTest(target=target):
                archive = self.make_archive()
                with zipfile.ZipFile(archive, "a") as output:
                    symlink = zipfile.ZipInfo("VibeStatus.app/escape")
                    symlink.create_system = 3
                    symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
                    output.writestr(symlink, target)
                with self.assertRaises(cask.ReleaseValidationError):
                    cask.inspect_archive(archive, "0.1.0")

    def test_framework_symlink_is_allowed(self) -> None:
        archive = self.make_archive()
        with zipfile.ZipFile(archive, "a") as output:
            symlink = zipfile.ZipInfo("VibeStatus.app/Contents/Frameworks/Core.framework/Versions/Current")
            symlink.create_system = 3
            symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(symlink, "A")
        cask.inspect_archive(archive, "0.1.0")

    def test_output_file_and_stdout_are_the_same_cask(self) -> None:
        archive = self.make_archive()
        output = self.directory / "tap" / "Casks" / "vibe-status.rb"
        stdout = io.StringIO()
        with mock.patch.object(cask, "verify_packaged_app"), redirect_stdout(stdout):
            self.assertEqual(cask.main(["0.1.0", str(archive)]), 0)
            self.assertEqual(cask.main(["0.1.0", str(archive), "--output", str(output)]), 0)
        self.assertEqual(output.read_text(), stdout.getvalue())

    def test_failed_validation_preserves_existing_cask(self) -> None:
        archive = self.make_archive(signed=False)
        output = self.directory / "vibe-status.rb"
        output.write_text("previous working cask\n")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cask.main(["0.1.0", str(archive), "--output", str(output)])
        self.assertEqual(output.read_text(), "previous working cask\n")

    def test_output_cannot_overwrite_release_archive(self) -> None:
        archive = self.make_archive()
        original = archive.read_bytes()
        with mock.patch.object(cask, "verify_packaged_app"), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                cask.main(["0.1.0", str(archive), "--output", str(archive)])
        self.assertEqual(archive.read_bytes(), original)

    def make_native_app(self):
        app = self.directory / "VibeStatus.app"
        binary_paths = (
            app / "Contents/MacOS/VibeStatus",
            app / "Contents/Frameworks/Helper.framework/Versions/A/Helper",
            app / "Contents/Frameworks/libSupport.dylib",
        )
        for path in binary_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\xca\xfe\xba\xbe" + b"fixture Mach-O")
        framework = app / "Contents/Frameworks/Helper.framework"
        metadata = framework / "Resources/Info.plist"
        metadata.parent.mkdir(parents=True)
        metadata.write_bytes(plistlib.dumps({"CFBundleExecutable": "Helper"}))
        return binary_paths, (framework, app)

    def test_ad_hoc_release_checks_all_nested_code_without_notarization(self) -> None:
        binaries, bundles = self.make_native_app()
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            self.assertNotIn("shell", kwargs)
            stdout = "x86_64 arm64" if "-archs" in command else "Signature=adhoc\n"
            return subprocess.CompletedProcess(command, 0, stdout, "")

        with (
            mock.patch.object(cask.sys, "platform", "darwin"),
            mock.patch.object(cask.subprocess, "run", side_effect=run),
            mock.patch.object(cask, "minimum_macos", return_value="14.0"),
        ):
            cask.verify_packaged_app(Path("release.zip"), self.directory)
        self.assertFalse(any("stapler" in command for command in commands))
        for path in (*binaries, *bundles):
            self.assertTrue(any("--verify" in command and command[-1] == str(path) for command in commands))
            for architecture in ("arm64", "x86_64"):
                self.assertTrue(any("--display" in command and architecture in command and command[-1] == str(path)
                                    for command in commands))

    def test_ad_hoc_release_rejects_nested_invalid_signature_architecture_or_macos_requirement(self) -> None:
        self.make_native_app()
        for failure in ("signature", "signature_x86_64", "architecture", "minimum_os"):
            with self.subTest(failure=failure):
                def run(command, **kwargs):
                    nested = command[-1].endswith("libSupport.dylib")
                    status, stdout = 0, ""
                    if "--verify" in command and nested and failure == "signature":
                        status = 1
                    if "--display" in command:
                        stdout = "Signature=adhoc\n"
                        if nested and "x86_64" in command and failure == "signature_x86_64":
                            stdout = "Signature=invalid\n"
                    if "-archs" in command:
                        stdout = "arm64" if nested and failure == "architecture" else "x86_64 arm64"
                    return subprocess.CompletedProcess(command, status, stdout, "")

                def minimum(path, architecture):
                    return "15.0" if path.name == "libSupport.dylib" and failure == "minimum_os" else "14.0"

                with (
                    mock.patch.object(cask.sys, "platform", "darwin"),
                    mock.patch.object(cask.subprocess, "run", side_effect=run),
                    mock.patch.object(cask, "minimum_macos", side_effect=minimum),
                    self.assertRaises(cask.ReleaseValidationError),
                ):
                    cask.verify_packaged_app(Path("release.zip"), self.directory)

    def test_notarized_flag_requires_stricter_verification_and_omits_manual_approval_caveat(self) -> None:
        archive = self.make_archive()
        stdout = io.StringIO()
        with mock.patch.object(cask, "verify_packaged_app") as verify, redirect_stdout(stdout):
            cask.main(["0.1.0", str(archive), "--notarized"])
        self.assertTrue(verify.call_args.kwargs["notarized"])
        self.assertNotIn("not notarized", stdout.getvalue())

    def test_native_verification_rejects_local_signing_missing_runtime_or_ticket_and_single_arch(self) -> None:
        self.make_native_app()
        good_signature = "Authority=Developer ID Application: Example (TEAM123)\nCodeDirectory v=20500 size=900 flags=0x10000(runtime) hashes=10+7\nTimestamp=Sep 11, 2026 at 00:00:00\n"
        cases = (
            {"signature": "Signature=adhoc\nCodeDirectory v=20500 flags=0x10000(runtime)\n"},
            {"signature": "Authority=Developer ID Application: Example (TEAM123)\nCodeDirectory v=20500 flags=0x0(none)\n"},
            {"stapler_status": 65},
            {"codesign_status": 1},
            {"architectures": "arm64\n"},
            {"signature": good_signature.replace("Timestamp=Sep 11, 2026 at 00:00:00\n", "")},
            {"signatures": {"x86_64": "Signature=adhoc\n"}},
        )

        def runner_for(options):
            def run(command, **kwargs):
                self.assertIsInstance(command, list)
                self.assertNotIn("shell", kwargs)
                status, stdout = 0, ""
                if "--verify" in command:
                    self.assertIn("--all-architectures", command)
                    status = options.get("codesign_status", 0)
                elif "--display" in command:
                    architecture = command[command.index("--arch") + 1]
                    stdout = options.get("signatures", {}).get(architecture, options.get("signature", good_signature))
                elif "stapler" in command:
                    status = options.get("stapler_status", 0)
                elif "-archs" in command:
                    stdout = options.get("architectures", "x86_64 arm64\n")
                return subprocess.CompletedProcess(command, status, stdout, "")
            return run

        with (mock.patch.object(cask.sys, "platform", "darwin"),
              mock.patch.object(cask, "minimum_macos", return_value="14.0")):
            for options in cases:
                with self.subTest(options=options), mock.patch.object(cask.subprocess, "run", side_effect=runner_for(options)):
                    with self.assertRaises(cask.ReleaseValidationError):
                        cask.verify_packaged_app(Path("release.zip"), self.directory, notarized=True)
            with mock.patch.object(cask.subprocess, "run", side_effect=runner_for({})):
                cask.verify_packaged_app(Path("release.zip"), self.directory, notarized=True)

    def test_platform_without_apple_verification_tools_is_rejected(self) -> None:
        with mock.patch.object(cask.sys, "platform", "linux"):
            with self.assertRaises(cask.ReleaseValidationError):
                cask.verify_packaged_app(Path("release.zip"), self.directory)


if __name__ == "__main__":
    unittest.main()
