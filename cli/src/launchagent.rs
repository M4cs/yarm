// LaunchAgent lifecycle.
//
// The agent itself is a one-shot at login that runs `launchctl setenv
// DYLD_INSERT_LIBRARIES <dylib>` on the user's gui session. With the env var
// set on the launchd session, every process subsequently spawned via launchd
// (Dock, Finder, every .app launched from the GUI, every `open`-invoked tool)
// inherits it, and dyld pulls libyarm.dylib in.
//
// We split lifecycle four ways:
//   * install   -- write the plist into ~/Library/LaunchAgents (file only)
//   * start     -- bootstrap the plist into gui/<uid> + setenv right now
//   * stop      -- unsetenv + bootout (leaves plist on disk so `start` is fast)
//   * uninstall -- stop + delete the plist
//
// Install assumes the dylib already lives at the path returned by
// `dylib_path()`; the top-level installer script puts it in /opt/homebrew/lib.
// None of the commands need sudo on Apple Silicon (brew owns /opt/homebrew).

use anyhow::{Context, Result};
use std::path::PathBuf;
use std::process::Command;

pub const LABEL: &str = "com.maxbridgland.yarm.agent";

/// Resolved at runtime so dev builds and brew installs both work.
/// Priority: $YARM_DYLIB env override -> brew prefix (arm64 or x86) -> /usr/local.
pub fn dylib_path() -> PathBuf {
    if let Ok(p) = std::env::var("YARM_DYLIB") {
        return PathBuf::from(p);
    }
    for candidate in ["/opt/homebrew/lib/libyarm.dylib", "/usr/local/lib/libyarm.dylib"] {
        if std::path::Path::new(candidate).exists() {
            return PathBuf::from(candidate);
        }
    }
    PathBuf::from("/opt/homebrew/lib/libyarm.dylib")
}

fn agent_plist_path() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("$HOME not set")?;
    Ok(PathBuf::from(home).join("Library/LaunchAgents").join(format!("{LABEL}.plist")))
}

fn gui_domain() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

fn plist_contents(dylib: &PathBuf) -> String {
    let d = dylib.display();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>DYLD_INSERT_LIBRARIES</string>
        <string>{d}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
"#
    )
}

/// Write the LaunchAgent plist. Does not register it with launchd; call
/// `start()` for that. Idempotent — overwrites any existing plist with the
/// currently-resolved dylib path (covers brew upgrades that move the file).
pub fn install() -> Result<()> {
    let dylib = dylib_path();
    anyhow::ensure!(
        dylib.exists(),
        "dylib not found at {}. Build it (`make dylib`), set YARM_DYLIB, or install via brew.",
        dylib.display()
    );
    let path = agent_plist_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, plist_contents(&dylib))?;
    Ok(())
}

/// Register the plist into gui/<uid> and assert the env var on the live
/// session. Safe to call when already running; we bootout-then-bootstrap so
/// the plist is re-read (covers dylib-path changes between `install` calls).
pub fn start() -> Result<()> {
    let path = agent_plist_path()?;
    anyhow::ensure!(
        path.exists(),
        "LaunchAgent plist missing at {}; run `yarm install` first.",
        path.display()
    );
    let domain = gui_domain();
    // Bootout is best-effort: a failure here just means it wasn't loaded.
    // Silenced so first-time `start` doesn't print a scary "Input/output error".
    let _ = Command::new("launchctl")
        .args(["bootout", &domain, path.to_str().unwrap()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    let st = Command::new("launchctl")
        .args(["bootstrap", &domain, path.to_str().unwrap()])
        .status()
        .context("launchctl bootstrap")?;
    anyhow::ensure!(st.success(), "launchctl bootstrap failed");

    // Push the env var to the current session so we don't need a logout.
    let dylib = dylib_path();
    let st = Command::new("launchctl")
        .args(["setenv", "DYLD_INSERT_LIBRARIES", dylib.to_str().unwrap()])
        .status()
        .context("launchctl setenv")?;
    anyhow::ensure!(st.success(), "launchctl setenv failed");
    Ok(())
}

/// Unset the env var and remove the plist from launchd. Leaves the plist on
/// disk so `start` works again without re-running `install`.
pub fn stop() -> Result<()> {
    let _ = Command::new("launchctl")
        .args(["unsetenv", "DYLD_INSERT_LIBRARIES"])
        .status();
    let path = agent_plist_path()?;
    if path.exists() {
        let _ = Command::new("launchctl")
            .args(["bootout", &gui_domain(), path.to_str().unwrap()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    Ok(())
}

/// Parse the dylib path out of the installed plist (so `status` reflects
/// what's actually wired into launchd, not what we'd resolve from $PATH right
/// now). Returns None if the plist doesn't exist or doesn't match.
pub fn installed_dylib_path() -> Option<PathBuf> {
    let plist = agent_plist_path().ok()?;
    let contents = std::fs::read_to_string(&plist).ok()?;
    // The plist has a fixed ProgramArguments order; the dylib path is the
    // <string> right after "DYLD_INSERT_LIBRARIES".
    let marker = "DYLD_INSERT_LIBRARIES";
    let after = contents.split_once(marker)?.1;
    let open = after.find("<string>")? + "<string>".len();
    let close = after[open..].find("</string>")?;
    Some(PathBuf::from(after[open..open + close].trim()))
}

pub fn restart() -> Result<()> {
    stop()?;
    start()
}

/// Stop + delete the plist. Does not touch the dylib / cli binaries
/// themselves — that's `install.sh --uninstall` or `make uninstall`.
pub fn uninstall() -> Result<()> {
    stop().ok();
    let path = agent_plist_path()?;
    if path.exists() {
        std::fs::remove_file(&path).ok();
    }
    Ok(())
}

pub fn is_installed() -> Result<bool> {
    Ok(agent_plist_path()?.exists())
}

pub fn dyld_env_set() -> Result<bool> {
    let out = Command::new("launchctl")
        .args(["getenv", "DYLD_INSERT_LIBRARIES"])
        .output()?;
    Ok(out.status.success() && !out.stdout.is_empty() && out.stdout != b"\n")
}

pub fn is_loaded_in_launchd() -> bool {
    // `launchctl print gui/<uid>/<label>` returns 0 if the agent is loaded.
    Command::new("launchctl")
        .args(["print", &format!("{}/{}", gui_domain(), LABEL)])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
