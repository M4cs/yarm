use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub radius: f64,
    pub injection: Injection,
    pub safety: Safety,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Injection {
    /// "third-party" = skip platform binaries (Tahoe-safe default).
    /// "all"         = attempt every host the DYLD env reaches.
    pub mode: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Safety {
    /// After this many consecutive crashes (constructor entered but app never
    /// reached the stable threshold), the dylib auto-disables itself for that
    /// bundleID on the next launch.
    pub crash_threshold: u32,
    /// Seconds a host must run after dylib load before we consider its
    /// startup "stable" and reset the crash counter.
    pub stable_threshold_seconds: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self { radius: 12.0, injection: Injection::default(), safety: Safety::default() }
    }
}

impl Default for Injection {
    fn default() -> Self {
        Self { mode: "third-party".into() }
    }
}

impl Default for Safety {
    fn default() -> Self {
        Self { crash_threshold: 2, stable_threshold_seconds: 5 }
    }
}

impl Config {
    /// We use `~/.config/yarm/` (XDG-style) on macOS, matching what the dylib
    /// reads. The directories crate's macOS default (`~/Library/Application
    /// Support/...`) would put us out of sync.
    pub fn dir() -> Result<PathBuf> {
        let home = std::env::var("HOME").context("$HOME not set")?;
        Ok(PathBuf::from(home).join(".config/yarm"))
    }

    pub fn path() -> Result<PathBuf> {
        Ok(Self::dir()?.join("config.toml"))
    }

    pub fn exclude_path() -> Result<PathBuf> {
        Ok(Self::dir()?.join("exclude.txt"))
    }

    pub fn include_path() -> Result<PathBuf> {
        Ok(Self::dir()?.join("include.txt"))
    }

    pub fn state_dir() -> Result<PathBuf> {
        Ok(Self::dir()?.join("state"))
    }

    pub fn load_or_default() -> Result<Self> {
        let p = Self::path()?;
        if !p.exists() {
            return Ok(Self::default());
        }
        let s = std::fs::read_to_string(&p).with_context(|| format!("reading {}", p.display()))?;
        Ok(toml::from_str(&s)?)
    }

    pub fn save(&self) -> Result<()> {
        let p = Self::path()?;
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&p, toml::to_string_pretty(self)?)?;
        Ok(())
    }
}

/// One bundle ID per line, comments starting with `#` ignored, blanks ignored.
pub fn read_list(path: &std::path::Path) -> Vec<String> {
    let Ok(s) = std::fs::read_to_string(path) else { return Vec::new() };
    s.lines()
        .map(|l| l.split('#').next().unwrap_or("").trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

pub fn write_list(path: &std::path::Path, ids: &[String]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body: String = ids
        .iter()
        .map(|s| format!("{s}\n"))
        .collect();
    std::fs::write(path, body)?;
    Ok(())
}
