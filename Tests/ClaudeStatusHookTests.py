from __future__ import annotations

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


hook = load_module(
    "claude_status_hook",
    REPOSITORY / "Tools/claude_status_hook.py",
)
configure = load_module(
    "configure_claude_status",
    REPOSITORY / "scripts/configure_claude_status.py",
)


class ClaudeStatusHookTests(unittest.TestCase):
    def test_lifecycle_transitions_and_removes_state_on_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(
                os.environ,
                {"VIBE_STATUS_CLAUDE_STATE_DIR": directory},
                clear=False,
            ):
                base = {
                    "session_id": "session-1",
                    "cwd": "/work/repository",
                }
                hook.handle(
                    {
                        **base,
                        "hook_event_name": "UserPromptSubmit",
                        "prompt": "\nImplement the parser\nwith tests",
                    }
                )
                record_path = Path(directory) / "session-1.json"
                record = json.loads(record_path.read_text(encoding="utf-8"))
                self.assertEqual(record["status"], "working")
                self.assertEqual(record["name"], "Implement the parser")

                hook.handle(
                    {
                        **base,
                        "hook_event_name": "Notification",
                        "notification_type": "permission_prompt",
                    }
                )
                record = json.loads(record_path.read_text(encoding="utf-8"))
                self.assertEqual(record["status"], "needsAttention")
                self.assertEqual(record["name"], "Implement the parser")

                hook.handle({**base, "hook_event_name": "Stop"})
                record = json.loads(record_path.read_text(encoding="utf-8"))
                self.assertEqual(record["status"], "ready")

                hook.handle({**base, "hook_event_name": "SessionEnd"})
                self.assertFalse(record_path.exists())

    def test_unknown_notification_does_not_create_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(
                os.environ,
                {"VIBE_STATUS_CLAUDE_STATE_DIR": directory},
                clear=False,
            ):
                hook.handle(
                    {
                        "session_id": "session-1",
                        "hook_event_name": "Notification",
                        "notification_type": "auth_success",
                    }
                )
                self.assertEqual(list(Path(directory).glob("*.json")), [])

    def test_background_agent_completion_clears_attention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(
                os.environ,
                {"VIBE_STATUS_CLAUDE_STATE_DIR": directory},
                clear=False,
            ):
                base = {
                    "session_id": "session-1",
                    "cwd": "/work/repository",
                    "hook_event_name": "Notification",
                }
                hook.handle({**base, "notification_type": "agent_needs_input"})
                record_path = Path(directory) / "session-1.json"
                record = json.loads(record_path.read_text(encoding="utf-8"))
                self.assertEqual(record["status"], "needsAttention")

                hook.handle({**base, "notification_type": "agent_completed"})
                record = json.loads(record_path.read_text(encoding="utf-8"))
                self.assertEqual(record["status"], "ready")

        notification_matcher = next(
            matcher
            for event_name, matcher in configure.EVENTS
            if event_name == "Notification"
        )
        self.assertIn("agent_completed", notification_matcher)

    def test_installer_preserves_unrelated_hooks(self) -> None:
        installed_hook = Path("/home/test/.local/lib/vibe-status/claude_status_hook.py")
        settings = {
            "theme": "dark",
            "hooks": {
                "Stop": [
                    {
                        "hooks": [
                            {"type": "command", "command": "notify-send done"},
                            {
                                "type": "command",
                                "command": f"python3 {installed_hook}",
                            },
                        ]
                    }
                ]
            },
        }

        configure.remove_existing_entries(settings, installed_hook)
        configure.add_entries(settings, installed_hook, Path("/usr/bin/python3"))

        self.assertEqual(settings["theme"], "dark")
        stop_commands = [
            handler["command"]
            for group in settings["hooks"]["Stop"]
            for handler in group["hooks"]
        ]
        self.assertIn("notify-send done", stop_commands)
        self.assertEqual(
            sum(str(installed_hook) in command for command in stop_commands),
            1,
        )

    def test_installer_and_uninstaller_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            settings_path = home / ".claude/settings.json"
            settings_path.parent.mkdir()
            settings_path.write_text('{"theme":"dark"}\n', encoding="utf-8")
            hook_source = home / "source-hook.py"
            hook_source.write_text("#!/usr/bin/env python3\n", encoding="utf-8")

            with mock.patch.object(Path, "home", return_value=home):
                with redirect_stdout(io.StringIO()):
                    with mock.patch.object(
                        sys,
                        "argv",
                        [
                            "configure_claude_status.py",
                            "--hook-source",
                            str(hook_source),
                        ],
                    ):
                        self.assertEqual(configure.main(), 0)

                installed_hook = (
                    home / ".local/lib/vibe-status/claude_status_hook.py"
                )
                self.assertTrue(installed_hook.is_file())
                self.assertTrue(installed_hook.stat().st_mode & stat.S_IXUSR)
                settings = json.loads(settings_path.read_text(encoding="utf-8"))
                self.assertEqual(settings["theme"], "dark")
                self.assertEqual(
                    sum(
                        1
                        for groups in settings["hooks"].values()
                        for group in groups
                        for handler in group["hooks"]
                        if str(installed_hook) in handler["command"]
                    ),
                    len(configure.EVENTS),
                )

                with redirect_stdout(io.StringIO()):
                    with mock.patch.object(
                        sys,
                        "argv",
                        ["configure_claude_status.py", "--uninstall"],
                    ):
                        self.assertEqual(configure.main(), 0)

            self.assertFalse(installed_hook.exists())
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(settings, {"theme": "dark"})
            self.assertEqual(
                len(
                    list(
                        settings_path.parent.glob(
                            "settings.json.vibe-status-backup-*"
                        )
                    )
                ),
                2,
            )


if __name__ == "__main__":
    unittest.main()
