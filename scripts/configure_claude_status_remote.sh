#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 [--uninstall] <ssh-alias>" >&2
  exit 2
}

mode=install
if [ "${1:-}" = "--uninstall" ]; then
  mode=uninstall
  shift
fi
[ "$#" -eq 1 ] || usage
alias_name="$1"

case "$alias_name" in
  "" | -* | *[!A-Za-z0-9._-]*)
    echo "Expected a literal SSH config alias." >&2
    exit 2
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_dir=$(dirname -- "$script_dir")
remote_dir=$(ssh -o BatchMode=yes -- "$alias_name" \
  'mktemp -d /tmp/vibe-status-claude.XXXXXX')

case "$remote_dir" in
  /tmp/vibe-status-claude.*) ;;
  *)
    echo "Remote host returned an unexpected temporary path." >&2
    exit 1
    ;;
esac
case "$remote_dir" in
  *[!A-Za-z0-9._/-]* | /tmp/vibe-status-claude.)
    echo "Remote host returned an unsafe temporary path." >&2
    exit 1
    ;;
esac

cleanup() {
  case "$remote_dir" in
    /tmp/vibe-status-claude.*)
      ssh -o BatchMode=yes -- "$alias_name" \
        "rm -f '$remote_dir/claude_status_hook.py' '$remote_dir/configure_claude_status.py'; rmdir '$remote_dir'" \
        >/dev/null 2>&1 || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

scp -q -- \
  "$repository_dir/Tools/claude_status_hook.py" \
  "$repository_dir/scripts/configure_claude_status.py" \
  "$alias_name:$remote_dir/"

if [ "$mode" = uninstall ]; then
  ssh -o BatchMode=yes -- "$alias_name" \
    "python3 '$remote_dir/configure_claude_status.py' --uninstall"
else
  ssh -o BatchMode=yes -- "$alias_name" \
    "python3 '$remote_dir/configure_claude_status.py' --hook-source '$remote_dir/claude_status_hook.py'"
fi
