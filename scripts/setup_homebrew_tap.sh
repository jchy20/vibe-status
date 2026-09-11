#!/bin/bash
set -euo pipefail

# The public source repository also hosts Casks/vibe-status.rb.
# No extra GitHub repository, account login, or publishing token is needed.
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh" >&2; exit 1; }
brew tap jchy20/vibe-status https://github.com/jchy20/vibe-status
echo "Install Vibe Status with: brew install --cask jchy20/vibe-status/vibe-status"
