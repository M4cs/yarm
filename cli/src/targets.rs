// Per-bundle injection targeting + crash-recovery state inspection.
//
// Three pieces of state live under ~/.config/yarm/:
//
//   config.toml      — mode + safety thresholds
//   exclude.txt      — bundle IDs to ALWAYS skip
//   include.txt      — bundle IDs to ALWAYS attempt (overrides crash-disable)
//   state/<id>.state — per-bundle crash tally written by the dylib
//
// The dylib reads all four at constructor time and decides whether to
// short-circuit. This module is the CLI side: edit the lists, inspect the
// state tallies, clear them when the user wants to re-enable a bundle that
// auto-disabled itself.

use crate::config::{read_list, write_list, Config};
use anyhow::Result;
use std::path::PathBuf;

#[derive(Debug)]
struct BundleState {
    bundle_id: String,
    constructor_ts: u64,
    stable_ts: u64,
    clean_exit_ts: u64,
    consecutive_crashes: u32,
    auto_disabled: bool,
    watchdog_disabled: bool,
}

fn parse_state_file(path: &PathBuf) -> Option<BundleState> {
    let contents = std::fs::read_to_string(path).ok()?;
    let bundle_id = path.file_stem()?.to_string_lossy().to_string();
    let mut s = BundleState {
        bundle_id,
        constructor_ts: 0,
        stable_ts: 0,
        clean_exit_ts: 0,
        consecutive_crashes: 0,
        auto_disabled: false,
        watchdog_disabled: false,
    };
    for line in contents.lines() {
        let (k, v) = line.split_once('=')?;
        match k.trim() {
            "constructor_ts" => s.constructor_ts = v.trim().parse().unwrap_or(0),
            "stable_ts" => s.stable_ts = v.trim().parse().unwrap_or(0),
            "clean_exit_ts" => s.clean_exit_ts = v.trim().parse().unwrap_or(0),
            "consecutive_crashes" => s.consecutive_crashes = v.trim().parse().unwrap_or(0),
            "auto_disabled" => s.auto_disabled = matches!(v.trim(), "true" | "1"),
            "watchdog_disabled" => s.watchdog_disabled = matches!(v.trim(), "true" | "1"),
            _ => {}
        }
    }
    Some(s)
}

fn all_states() -> Vec<BundleState> {
    let Ok(dir) = Config::state_dir() else { return Vec::new() };
    let Ok(rd) = std::fs::read_dir(&dir) else { return Vec::new() };
    rd.filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|x| x == "state"))
        .filter_map(|e| parse_state_file(&e.path()))
        .collect()
}

pub fn show() -> Result<()> {
    let cfg = Config::load_or_default()?;
    let excludes = read_list(&Config::exclude_path()?);
    let includes = read_list(&Config::include_path()?);
    let states = all_states();

    println!("config:");
    println!("  mode:                {}", cfg.injection.mode);
    println!("  crash_threshold:     {}", cfg.safety.crash_threshold);
    println!("  stable_threshold_s:  {}", cfg.safety.stable_threshold_seconds);
    println!("  radius:              {}", cfg.radius);
    println!();

    println!("exclude.txt ({}):", excludes.len());
    if excludes.is_empty() { println!("  (none)"); }
    for id in &excludes { println!("  {id}"); }
    println!();

    println!("include.txt ({}):", includes.len());
    if includes.is_empty() { println!("  (none)"); }
    for id in &includes { println!("  {id}"); }
    println!();

    println!("per-bundle state ({}):", states.len());
    if states.is_empty() {
        println!("  (no state recorded yet — run apps with yarm active to populate)");
        return Ok(());
    }
    println!("  {:<44}  {:>7}  {:<13}  {:<14}",
        "bundle id", "crashes", "crash-disabled", "watchdog-tripped");
    for s in &states {
        println!("  {:<44}  {:>7}  {:<13}  {:<14}",
            s.bundle_id, s.consecutive_crashes,
            if s.auto_disabled { "yes" } else { "no" },
            if s.watchdog_disabled { "yes" } else { "no" });
    }
    Ok(())
}

pub fn set_mode(mode: &str) -> Result<()> {
    anyhow::ensure!(
        matches!(mode, "third-party" | "all"),
        "mode must be 'third-party' or 'all', got '{mode}'"
    );
    let mut cfg = Config::load_or_default()?;
    cfg.injection.mode = mode.to_string();
    cfg.save()?;
    println!("mode set to '{mode}'");
    if mode == "all" {
        println!();
        println!("warning: 'all' mode injects into every host launchd reaches. Apple platform binaries");
        println!("require AMFI off (`yarm amfi-arm` + reboot), and even then Cryptex apps (Safari, Mail, etc.)");
        println!("will SIGKILL on launch because library-validation can't be bypassed without 1TR-level");
        println!("cs disabling. Add them to exclude.txt to avoid crash spam.");
    }
    Ok(())
}

fn add_to_list(path: PathBuf, id: &str) -> Result<()> {
    let mut list = read_list(&path);
    if list.iter().any(|x| x == id) {
        println!("{id} already present in {}", path.display());
        return Ok(());
    }
    list.push(id.to_string());
    write_list(&path, &list)?;
    println!("added {id} to {}", path.display());
    Ok(())
}

fn remove_from_list(path: PathBuf, id: &str) -> Result<()> {
    let mut list = read_list(&path);
    let len_before = list.len();
    list.retain(|x| x != id);
    if list.len() == len_before {
        println!("{id} was not in {}", path.display());
        return Ok(());
    }
    write_list(&path, &list)?;
    println!("removed {id} from {}", path.display());
    Ok(())
}

pub fn exclude(id: &str) -> Result<()> {
    add_to_list(Config::exclude_path()?, id)
}
pub fn unexclude(id: &str) -> Result<()> {
    remove_from_list(Config::exclude_path()?, id)
}
pub fn include(id: &str) -> Result<()> {
    add_to_list(Config::include_path()?, id)
}
pub fn uninclude(id: &str) -> Result<()> {
    remove_from_list(Config::include_path()?, id)
}

pub fn reset(id: &str) -> Result<()> {
    let path = Config::state_dir()?.join(format!("{id}.state"));
    if path.exists() {
        std::fs::remove_file(&path)?;
        println!("cleared state for {id}");
    } else {
        println!("no state file for {id} (already clean)");
    }
    Ok(())
}

pub fn reset_all() -> Result<()> {
    let dir = Config::state_dir()?;
    let Ok(rd) = std::fs::read_dir(&dir) else {
        println!("no state directory at {}", dir.display());
        return Ok(());
    };
    let mut n = 0;
    for entry in rd.filter_map(|e| e.ok()) {
        if entry.path().extension().is_some_and(|x| x == "state") {
            std::fs::remove_file(entry.path()).ok();
            n += 1;
        }
    }
    println!("cleared {n} state file(s)");
    Ok(())
}
