#!/usr/bin/env python3
"""Persist the minimum Claude Code lifecycle state consumed by Vibe Status."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from typing import Any, Dict, Optional


ATTENTION_NOTIFICATIONS = {
    "permission_prompt",
    "elicitation_dialog",
    "agent_needs_input",
}
WORKING_NOTIFICATIONS = {
    "elicitation_complete",
    "elicitation_response",
}
READY_NOTIFICATIONS = {
    "idle_prompt",
    "agent_completed",
}
WORKING_EVENTS = {
    "UserPromptSubmit",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionDenied",
}
READY_EVENTS = {
    "SessionStart",
    "Stop",
}


def state_directory() -> Path:
    override = os.environ.get("VIBE_STATUS_CLAUDE_STATE_DIR")
    if override:
        return Path(override).expanduser()
    xdg_state = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg_state).expanduser() if xdg_state else Path.home() / ".local/state"
    return base / "vibe-status/claude"


def state_path(directory: Path, session_id: str) -> Path:
    if re.fullmatch(r"[A-Za-z0-9._-]{1,160}", session_id):
        filename = session_id
    else:
        filename = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    return directory / f"{filename}.json"


def normalized_name(value: Any, maximum_length: int = 120) -> Optional[str]:
    if not isinstance(value, str):
        return None
    first_line = next((line.strip() for line in value.splitlines() if line.strip()), "")
    if not first_line:
        return None
    return first_line[:maximum_length]


def existing_record(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def status_for(event: Dict[str, Any]) -> Optional[str]:
    event_name = event.get("hook_event_name")
    if event_name == "Notification":
        notification_type = event.get("notification_type")
        if notification_type in ATTENTION_NOTIFICATIONS:
            return "needsAttention"
        if notification_type in READY_NOTIFICATIONS:
            return "ready"
        if notification_type in WORKING_NOTIFICATIONS:
            return "working"
        return None
    if event_name in WORKING_EVENTS:
        return "working"
    if event_name in READY_EVENTS:
        return "ready"
    if event_name in {"PermissionRequest", "StopFailure"}:
        return "needsAttention"
    return None


def write_record(path: Path, record: Dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.stem}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(record, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def handle(event: Dict[str, Any]) -> None:
    session_id = event.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return

    directory = state_directory()
    path = state_path(directory, session_id)
    if event.get("hook_event_name") == "SessionEnd":
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return

    status = status_for(event)
    if status is None:
        return

    existing = existing_record(path)
    prompt_name = normalized_name(event.get("prompt"))
    existing_name = normalized_name(existing.get("name"))
    cwd = event.get("cwd") if isinstance(event.get("cwd"), str) else None
    record = {
        "schema_version": 1,
        "session_id": session_id,
        "name": prompt_name or existing_name,
        "cwd": cwd or existing.get("cwd"),
        "status": status,
        "updated_at": time.time(),
    }
    write_record(path, record)


def main() -> int:
    try:
        event = json.load(sys.stdin)
        if isinstance(event, dict):
            handle(event)
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"vibe-status Claude hook: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
