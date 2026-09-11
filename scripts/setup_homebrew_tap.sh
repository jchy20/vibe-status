#!/bin/bash
set -euo pipefail

# Run once with a personal GitHub CLI login that can create repositories.
root=$(cd "$(dirname "$0")/.." && pwd)
tap=jchy20/homebrew-tap
command -v gh >/dev/null || { echo "Install GitHub CLI and run gh auth login first." >&2; exit 1; }
gh auth status >/dev/null

if ! gh repo view "$tap" --json name >/dev/null 2>&1; then
  gh repo create "$tap" --public --description "Homebrew casks for Vibe Status" \
    --homepage https://github.com/jchy20/vibe-status
fi

# Seed an empty tap only. Existing README content belongs to its maintainer.
if ! gh api "repos/$tap/contents/README.md" --silent >/dev/null 2>&1; then
  payload=$(mktemp)
  trap 'rm -f "$payload"' EXIT
  python3 - "$root/distribution/homebrew/README.md" > "$payload" <<'PY'
import base64, json, pathlib, sys
print(json.dumps({
    "message": "Initialize Vibe Status Homebrew tap",
    "content": base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode(),
}))
PY
  gh api --method PUT "repos/$tap/contents/README.md" --input "$payload" --silent
fi
echo "Tap ready: https://github.com/$tap"
echo "The first signed release will add Casks/vibe-status.rb."
