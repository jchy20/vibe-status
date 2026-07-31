#!/usr/bin/env python3
"""Install or remove Vibe Status hooks in Claude Code user settings."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
from typing import Any, Dict, List, Optional, Tuple


EVENTS: Tuple[Tuple[str, Optional[str]], ...] = (
    ("SessionStart", None),
    ("UserPromptSubmit", None),
    ("PermissionRequest", None),
    ("PermissionDenied", None),
    ("PostToolUse", None),
    ("PostToolUseFailure", None),
    (
        "Notification",
        "permission_prompt|idle_prompt|elicitation_dialog|"
        "elicitation_complete|elicitation_response|agent_needs_input|"
        "agent_completed",
    ),
    ("Stop", None),
    ("StopFailure", None),
    ("SessionEnd", None),
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument(
        "--hook-source",
        type=Path,
        help="Path to claude_status_hook.py when installing.",
    )
    return parser.parse_args()


def load_settings(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as error:
        raise SystemExit(f"Cannot update invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"Cannot update {path}: the top-level JSON value is not an object.")
    return value


def is_vibe_status_hook(value: Any, installed_hook: Path) -> bool:
    if not isinstance(value, dict):
        return False
    command = value.get("command")
    return isinstance(command, str) and str(installed_hook) in command


def remove_existing_entries(
    settings: Dict[str, Any],
    installed_hook: Path,
) -> None:
    hooks = settings.get("hooks")
    if hooks is None:
        return
    if not isinstance(hooks, dict):
        raise SystemExit("Cannot update Claude settings: 'hooks' is not an object.")

    for event_name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        retained_groups: List[Any] = []
        for group in groups:
            if not isinstance(group, dict):
                retained_groups.append(group)
                continue
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                retained_groups.append(group)
                continue
            retained_handlers = [
                handler
                for handler in handlers
                if not is_vibe_status_hook(handler, installed_hook)
            ]
            if retained_handlers:
                updated_group = dict(group)
                updated_group["hooks"] = retained_handlers
                retained_groups.append(updated_group)
        if retained_groups:
            hooks[event_name] = retained_groups
        else:
            hooks.pop(event_name, None)

    if not hooks:
        settings.pop("hooks", None)


def add_entries(
    settings: Dict[str, Any],
    installed_hook: Path,
    python_path: Path,
) -> None:
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit("Cannot update Claude settings: 'hooks' is not an object.")
    command = f"{shlex.quote(str(python_path))} {shlex.quote(str(installed_hook))}"

    for event_name, matcher in EVENTS:
        group: Dict[str, Any] = {
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 5,
                }
            ]
        }
        if matcher is not None:
            group["matcher"] = matcher
        groups = hooks.setdefault(event_name, [])
        if not isinstance(groups, list):
            raise SystemExit(
                f"Cannot update Claude settings: hooks.{event_name} is not an array."
            )
        groups.append(group)


def backup(path: Path) -> Optional[Path]:
    if not path.exists():
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_path = path.with_name(f"{path.name}.vibe-status-backup-{stamp}")
    shutil.copy2(path, backup_path)
    return backup_path


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    arguments = parse_arguments()
    settings_path = Path.home() / ".claude/settings.json"
    installed_hook = Path.home() / ".local/lib/vibe-status/claude_status_hook.py"
    settings_existed = settings_path.exists()
    settings = load_settings(settings_path)
    remove_existing_entries(settings, installed_hook)

    if arguments.uninstall:
        backup_path = backup(settings_path)
        if settings_existed:
            write_json(settings_path, settings)
        try:
            installed_hook.unlink()
        except FileNotFoundError:
            pass
        print("Removed Vibe Status Claude Code hooks.")
        if backup_path:
            print(f"Backup: {backup_path}")
        return 0

    if arguments.hook_source is None or not arguments.hook_source.is_file():
        raise SystemExit("--hook-source must point to claude_status_hook.py")
    installed_hook.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copy2(arguments.hook_source, installed_hook)
    os.chmod(installed_hook, 0o700)

    python_path = Path(sys.executable).resolve()
    add_entries(settings, installed_hook, python_path)
    backup_path = backup(settings_path)
    write_json(settings_path, settings)
    print(f"Installed Claude Code status hook: {installed_hook}")
    print(f"Updated Claude settings: {settings_path}")
    if backup_path:
        print(f"Backup: {backup_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
