# Canonical formula for the M4cs/homebrew-yarm tap.
#
# This file is the *source of truth* — on release, the CI workflow
# (.github/workflows/release.yml) prints an updated `url` + `sha256` + `version`
# stanza which gets pasted into the tap repo. The copy in this repo is for
# auditing only; brew reads from M4cs/homebrew-yarm.
#
# Usage:
#   brew tap M4cs/yarm
#   brew install yarm
#   yarm install && yarm start
#
# Notes:
#   - Requires SIP disabled. We do NOT detect at install time; runtime
#     injection just won't take effect until you `csrutil disable`.
#   - macOS Tahoe (26.x) on Apple Silicon only. The build targets Tahoe's
#     SkyLight surface (private SLSTransaction* setters) and the dylib is
#     unsigned, so older OS / Intel / hardened-library-validation
#     constraints all bite.

class Yarm < Formula
  desc "Uniform window corner radius for macOS Tahoe"
  homepage "https://github.com/M4cs/yarm"
  url "https://github.com/M4cs/yarm/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
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
      yarm requires SIP disabled. See the README for the AMFI / library-
      validation caveats on Apple-signed apps and the watchdog notes.
    EOS
  end

  test do
    system "#{bin}/yarm", "--version"
  end
end
