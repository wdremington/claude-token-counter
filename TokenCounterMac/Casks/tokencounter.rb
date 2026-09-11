# Homebrew cask for TokenCounter.
#
# This file belongs in a repository named `homebrew-tap` (or `homebrew-<name>`)
# under `Casks/`, not here — it lives in this repo only as the source of truth to
# copy from. Users then install with:
#
#   brew install --cask OWNER/tap/tokencounter
#
# The official homebrew/cask tap enforces a notability floor (roughly 30 forks /
# 30 watchers / 75 stars, checked in CI), so a new project is not eligible there
# yet. An own tap has no such bar and behaves identically for the user.
#
# Before each release: bump `version`, and paste the sha256 that
# `./build.sh --release` prints.
cask "tokencounter" do
  version "1.1.0"
  sha256 "REPLACE_WITH_THE_SHA256_PRINTED_BY_build.sh"

  url "https://github.com/OWNER/TokenCounter/releases/download/v#{version}/TokenCounter-#{version}.dmg"
  name "TokenCounter"
  desc "Menu bar dashboard for Claude Code token usage and cost"
  homepage "https://github.com/OWNER/TokenCounter"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app targets macOS 14. Declaring it means an older system gets a clear
  # message from brew instead of a bundle that silently fails to launch.
  depends_on macos: ">= :sonoma"

  app "TokenCounter.app"

  # `brew uninstall --zap` should leave nothing behind. The stored usage history
  # lives under Application Support and is the one thing a user might miss, so it
  # is removed only by an explicit zap, never by a plain uninstall.
  zap trash: [
    "~/Library/Application Support/TokenCounter",
    "~/Library/Preferences/com.tokencounter.app.plist",
    "~/Library/Caches/com.tokencounter.app",
    "~/Library/Saved Application State/com.tokencounter.app.savedState",
  ]
end
