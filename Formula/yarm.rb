# yarm — uniform window corner radius for macOS Tahoe.
#
# This is the tap formula for the M4cs/homebrew-yarm tap. The canonical
# source lives at https://github.com/M4cs/yarm/blob/main/Formula/yarm.rb;
# this file is kept in sync on every release.
#
# Install:
#   brew tap M4cs/yarm
#   brew install yarm           # once v0.1.0 is tagged; until then:
#   brew install --HEAD yarm    # builds from main
#   yarm install && yarm start
#
# Update on a new tag:
#   1. CI in M4cs/yarm prints an updated url/sha256/version stanza after a
#      tag push. Paste those three lines into the `stable` block below.
#   2. Commit + push this repo.
#   3. Users get the update on `brew upgrade yarm`.

class Yarm < Formula
  desc "Uniform window corner radius for macOS Tahoe"
  homepage "https://github.com/M4cs/yarm"
  license "MIT"

  # No stable release yet — uncomment + fill from CI output after the first
  # `git tag v0.1.0 && git push --tags` in the main repo.
  #
  url "https://github.com/M4cs/yarm/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e3f2c84cdba9c38ceda53fb5888147b421068066a447b47b668ef268a30ba975"
  version "0.1.0"


  head "https://github.com/M4cs/yarm.git", branch: "main"

  depends_on "rust" => :build
  depends_on :macos => :sequoia # placeholder; bump to :tahoe once Brew has the symbol
  depends_on arch: :arm64

  def install
    # Brew's superenv strips `-arch arm64e` by default — without this opt-in,
    # the resulting libyarm.dylib is arm64-only and cannot inject into Apple's
    # platform binaries (which are arm64e on Apple Silicon).
    ENV.permit_arch_flags
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
