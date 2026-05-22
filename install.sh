#!/usr/bin/env bash
#
# yarm one-shot installer.
#
#   ./install.sh             build + install + start
#   ./install.sh --uninstall stop + remove binaries + remove agent
#   ./install.sh --reinstall same as: --uninstall && fresh install
#
# Assumes: macOS Tahoe (26.x) on Apple Silicon, SIP disabled, Xcode CLT + Rust
# toolchain installed (`xcode-select --install`, `rustup`). Refuses to run on
# anything else — these are hard requirements, not lints.

set -euo pipefail

# ---- platform sanity ------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
    echo "yarm: macOS only" >&2
    exit 1
fi

OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [[ "$OS_MAJOR" -lt 26 ]]; then
    echo "yarm: needs macOS Tahoe (26.x). You have $(sw_vers -productVersion)." >&2
    exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
    echo "yarm: Apple Silicon only (arm64). You're on $ARCH." >&2
    exit 1
fi

if ! csrutil status 2>/dev/null | grep -q "disabled"; then
    echo "yarm: SIP is enabled. Boot to Recovery, run 'csrutil disable', reboot, then retry." >&2
    exit 1
fi

# ---- where things go ------------------------------------------------------

# Apple Silicon brew lives at /opt/homebrew; we co-locate with it.
PREFIX="${PREFIX:-/opt/homebrew}"
LIB_DIR="$PREFIX/lib"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/yarm"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB_SRC="$REPO_DIR/dylib/libyarm.dylib"
CLI_SRC="$REPO_DIR/target/release/yarm"
PLIST_SRC="$REPO_DIR/agent/com.maxbridgland.yarm.plist"

# ---- subcommands ----------------------------------------------------------

action_uninstall() {
    echo "==> stopping any running yarm"
    if [[ -x "$BIN_DIR/yarm" ]]; then
        "$BIN_DIR/yarm" stop 2>/dev/null || true
        "$BIN_DIR/yarm" uninstall 2>/dev/null || true
    fi
    echo "==> removing binaries"
    rm -f "$LIB_DIR/libyarm.dylib" "$BIN_DIR/yarm"
    rm -rf "$SHARE_DIR"
    echo "done. config at ~/.config/yarm/ is untouched."
}

action_install() {
    echo "==> building dylib"
    make -C "$REPO_DIR/dylib"

    echo "==> building cli (cargo build --release)"
    ( cd "$REPO_DIR" && cargo build --release )

    if [[ ! -f "$DYLIB_SRC" ]] || [[ ! -x "$CLI_SRC" ]]; then
        echo "build artifacts missing; aborting" >&2
        exit 1
    fi

    echo "==> installing to $PREFIX"
    install -d "$LIB_DIR" "$BIN_DIR" "$SHARE_DIR"
    install -m 0755 "$DYLIB_SRC" "$LIB_DIR/libyarm.dylib"
    install -m 0755 "$CLI_SRC"   "$BIN_DIR/yarm"
    install -m 0644 "$PLIST_SRC" "$SHARE_DIR/com.maxbridgland.yarm.plist"

    echo "==> registering LaunchAgent + activating"
    "$BIN_DIR/yarm" install
    "$BIN_DIR/yarm" start

    echo
    "$BIN_DIR/yarm" status
    echo
    echo "next steps:"
    echo "  yarm set 8                    # pick a radius"
    echo "  quit + reopen the apps you want to affect"
    echo "  yarm doctor                   # if anything looks off"
}

case "${1:-install}" in
    install)
        action_install ;;
    --uninstall|uninstall)
        action_uninstall ;;
    --reinstall|reinstall)
        action_uninstall
        action_install ;;
    *)
        echo "usage: $0 [install|--uninstall|--reinstall]" >&2
        exit 1 ;;
esac
