cask "vibe-status" do
  version "0.1.0"
  sha256 "523ad9461bcd9fafbf6ebdc25a2044b515d867ba1efc7a11451f023215e19d0a"

  url "https://github.com/jchy20/vibe-status/releases/download/v#{version}/VibeStatus-#{version}.zip"
  name "Vibe Status"
  desc "Menu bar status for Codex and Claude Code tasks on remote hosts"
  homepage "https://github.com/jchy20/vibe-status"

  depends_on macos: ">= :sonoma"

  app "VibeStatus.app"

  zap trash: "~/Library/Preferences/com.jamescai.VibeStatus.plist"

  caveats <<~EOS
    This release is not notarized by Apple.
    After opening Vibe Status, if macOS blocks it, approve this app in:
      System Settings > Privacy & Security > Open Anyway
  EOS
end
