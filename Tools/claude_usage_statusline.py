#!/usr/bin/env python3
"""Capture Claude Code quota data while preserving an existing status line."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, Optional


def usage_path() -> Path:
    override = os.environ.get("VIBE_STATUS_CLAUDE_USAGE_FILE")
    if override:
        return Path(override).expanduser()
    xdg_state = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg_state).expanduser() if xdg_state else Path.home() / ".local/state"
    return base / "vibe-status/claude-usage.json"


def delegate_path() -> Path:
    return Path.home() / ".local/lib/vibe-status/claude_statusline_previous.json"


def number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def usage_window(value: Any) -> Optional[Dict[str, float]]:
    if not isinstance(value, dict):
        return None
    percentage = number(value.get("used_percentage"))
    resets_at = number(value.get("resets_at"))
    if percentage is None or resets_at is None or resets_at <= 0:
        return None
    return {
        "used_percentage": min(100.0, max(0.0, percentage)),
        "resets_at": resets_at,
    }


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def capture_usage(value: Any) -> None:
    if not isinstance(value, dict):
        return
    rate_limits = value.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return
    five_hour = usage_window(rate_limits.get("five_hour"))
    seven_day = usage_window(rate_limits.get("seven_day"))
    if five_hour is None and seven_day is None:
        return
    write_json(
        usage_path(),
        {
            "schema_version": 1,
            "five_hour": five_hour,
            "seven_day": seven_day,
            "updated_at": time.time(),
        },
    )


def run_delegate(raw_input: str) -> int:
    try:
        value = json.loads(delegate_path().read_text(encoding="utf-8"))
        command = value.get("command") if isinstance(value, dict) else None
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        command = None
    if not isinstance(command, str) or not command.strip():
        return 0

    result = subprocess.run(
        command,
        shell=True,
        input=raw_input,
        text=True,
        capture_output=True,
        check=False,
    )
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode


def main() -> int:
    raw_input = sys.stdin.read()
    try:
        capture_usage(json.loads(raw_input))
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        pass
    return run_delegate(raw_input)


if __name__ == "__main__":
    raise SystemExit(main())
