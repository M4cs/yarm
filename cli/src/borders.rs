// JankyBorders integration. Mutates ~/.config/borders/bordersrc so that the
// `border_radius` line matches our global radius, then SIGUSR1's borders to
// reload. SIGUSR1 is the documented reload signal as of JankyBorders 1.x.
//
// We only touch the single `border_radius=` line; other settings are preserved
// verbatim. If the file is missing we leave borders alone — user hasn't
// configured it.

use anyhow::{Context, Result};
use std::io::Write;
use std::path::PathBuf;

fn bordersrc() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".config/borders/bordersrc"))
}

pub fn sync(radius: f64) -> Result<()> {
    let Some(path) = bordersrc() else { return Ok(()) };
    if !path.exists() {
        return Ok(());
    }
    let original = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    let new_line = format!("border_radius={}", radius as i64);

    let mut found = false;
    let mut out = String::with_capacity(original.len() + 32);
    for line in original.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("border_radius=") || trimmed.starts_with("border_radius ") {
            out.push_str(&new_line);
            found = true;
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    if !found {
        out.push_str(&new_line);
        out.push('\n');
    }

    if out != original {
        let tmp = path.with_extension("bordersrc.yarm-tmp");
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(out.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, &path)?;
    }

    if let Some(pid) = pid() {
        unsafe { libc::kill(pid, libc::SIGUSR1) };
    }
    Ok(())
}

pub fn pid() -> Option<i32> {
    let out = std::process::Command::new("pgrep")
        .arg("-x")
        .arg("borders")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.split_whitespace().next()?.parse().ok()
}
