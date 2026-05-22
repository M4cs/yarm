# Canonical formula for the M4cs/homebrew-yarm tap.
#
# This file is the source of truth. The copy at
# https://github.com/M4cs/homebrew-yarm/blob/main/Formula/yarm.rb is kept in
# sync on every release. On a new tag:
#
#   1. `git tag vX.Y.Z && git push --tags` in this repo.
#   2. .github/workflows/release.yml prints a stable `url` / `sha256` /
#      `version` stanza.
#   3. Paste it into the `stable` block below AND into the tap's copy.
#   4. Commit + push both repos.
#
# Install (after a tagged release):
#   brew tap M4cs/yarm
#   brew install yarm
#   yarm install && yarm start
#
# Install (pre-release, builds from main):
#   brew tap M4cs/yarm
#   brew install --HEAD yarm

class Yarm < Formula
  desc "Uniform window corner radius for macOS Tahoe"
  homepage "https://github.com/M4cs/yarm"
  license "MIT"

  # No stable release yet. Uncomment + fill from CI output after the first
  # `git tag v0.1.0 && git push --tags`.
  #
  # url "https://github.com/M4cs/yarm/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 "<computed by .github/workflows/release.yml>"
  # version "0.1.0"

  head "https://github.com/M4cs/yarm.git", branch: "main"

  depends_on "rust" => :build
  depends_on :macos => :sequoia # placeholder; bump to :tahoe once Brew has the symbol
  depends_on arch: :arm64

  def install
    system "make", "PREFIX=#{prefix}", "install"
  end

  def caveats
    <<~EOS
      To activate yarm:

          yarm install        # registers the LaunchAgent
          yarm start          # arms DYLD_INSERT_LIBRARIES on the live session

      Quit and reopen the apps you want affected so they inherit the dylib.

      yarm requires SIP disabled and macOS Tahoe (26.x) on Apple Silicon.
      See https://github.com/M4cs/yarm#readme for the safety notes
      (AMFI / library-validation caveats, the runtime watchdog, the
      crash-recovery behavior, etc.).
    EOS
  end

  test do
    system "#{bin}/yarm", "--version"
  end
end
