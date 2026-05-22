// System-level injection enablement: SIP status, AMFI boot-arg toggling,
// codesign + LaunchAgent diagnostics.
//
// macOS Tahoe on Apple Silicon refuses to load an unsigned (or non-Apple)
// dylib into hardened, library-validated binaries (Safari, Mail, App Store
// apps, etc.) even with SIP off. The kernel-side check is gated by AMFI; the
// escape hatch is `amfi_get_out_of_my_way=0x1` in nvram boot-args.
//
// On Apple Silicon, writing boot-args requires the system's security policy
// to be at "Reduced Security" (settable only from 1TR / Recovery). With SIP
// already disabled the policy is usually permissive enough, but if `sudo
// nvram` rejects the write we surface the Recovery steps verbatim.

use anyhow::{Context, Result};
use std::process::Command;

const AMFI_FLAG: &str = "amfi_get_out_of_my_way=0x1";

/// Parsed `nvram boot-args` output. Empty string when the variable is unset.
fn read_boot_args() -> String {
    let out = Command::new("nvram").arg("boot-args").output();
    let Ok(out) = out else { return String::new() };
    if !out.status.success() {
        return String::new();
    }
    let s = String::from_utf8_lossy(&out.stdout);
    // Format: `boot-args\t<value>\n`
    s.splitn(2, '\t').nth(1).unwrap_or("").trim().to_string()
}

fn write_boot_args(value: &str) -> Result<()> {
    let kv = format!("boot-args={value}");
    let st = Command::new("sudo")
        .args(["nvram", kv.as_str()])
        .status()
        .context("invoking sudo nvram")?;
    if !st.success() {
        anyhow::bail!(
            "sudo nvram refused to write boot-args.\n\n\
             On Apple Silicon this means the system's security policy is too \
             strict to allow custom boot-args even with SIP disabled. To fix:\n\
             \n\
             1. Shut down. Hold the power button until \"Loading startup \
                options\" appears.\n\
             2. Choose Options → Continue → pick your admin user → Utilities \
                → Terminal.\n\
             3. Run `csrutil disable` (if not already), then \
                `bputil -nkc -nas`, accepting prompts.\n\
             4. Reboot, then re-run `yarm amfi-arm`.\n"
        );
    }
    Ok(())
}

fn sip_disabled() -> bool {
    Command::new("csrutil")
        .arg("status")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("disabled"))
        .unwrap_or(false)
}

fn amfi_armed(boot_args: &str) -> bool {
    boot_args
        .split_whitespace()
        .any(|tok| tok.starts_with("amfi_get_out_of_my_way="))
}

/// Strip any existing `amfi_get_out_of_my_way=*` tokens, return the rest.
fn boot_args_without_amfi(boot_args: &str) -> String {
    boot_args
        .split_whitespace()
        .filter(|tok| !tok.starts_with("amfi_get_out_of_my_way="))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn amfi_arm() -> Result<()> {
    let current = read_boot_args();
    if amfi_armed(&current) {
        println!("amfi_get_out_of_my_way already present in boot-args:");
        println!("  {current}");
        println!("(reboot still required if you set this in the current session)");
        return Ok(());
    }
    let cleaned = boot_args_without_amfi(&current);
    let new = if cleaned.is_empty() {
        AMFI_FLAG.to_string()
    } else {
        format!("{cleaned} {AMFI_FLAG}")
    };
    write_boot_args(&new)?;
    println!("set boot-args = {new}");
    println!();
    println!("REBOOT for AMFI to drop library validation. Until then,");
    println!("Apple-signed hardened apps will still reject the dylib.");
    Ok(())
}

pub fn amfi_disarm() -> Result<()> {
    let current = read_boot_args();
    if !amfi_armed(&current) {
        println!("amfi_get_out_of_my_way is not present in boot-args.");
        return Ok(());
    }
    let cleaned = boot_args_without_amfi(&current);
    if cleaned.is_empty() {
        // Clear the variable entirely.
        let st = Command::new("sudo")
            .args(["nvram", "-d", "boot-args"])
            .status()?;
        anyhow::ensure!(st.success(), "sudo nvram -d boot-args failed");
    } else {
        write_boot_args(&cleaned)?;
    }
    println!("removed AMFI flag. REBOOT for library validation to re-engage.");
    Ok(())
}

pub fn doctor() -> Result<()> {
    let sip = sip_disabled();
    let ba = read_boot_args();
    let amfi = amfi_armed(&ba);
    let dylib = crate::launchagent::dylib_path();
    let dylib_exists = dylib.exists();
    let dylib_sig = if dylib_exists {
        Command::new("codesign")
            .args(["-dv", "--verbose=2"])
            .arg(&dylib)
            .output()
            .ok()
            .and_then(|o| {
                // codesign writes details to stderr
                let s = String::from_utf8_lossy(&o.stderr).to_string();
                if s.contains("adhoc") {
                    Some("adhoc")
                } else if s.contains("Authority") {
                    Some("signed")
                } else if s.is_empty() {
                    None
                } else {
                    Some("unsigned/unknown")
                }
            })
            .unwrap_or("unknown")
    } else {
        "missing"
    };
    let agent = crate::launchagent::is_installed().unwrap_or(false);
    let dyld = crate::launchagent::dyld_env_set().unwrap_or(false);

    let mark = |ok: bool| if ok { "ok  " } else { "FAIL" };

    println!("  [{}] SIP disabled               {}", mark(sip),
        if sip { "(csrutil reports disabled)" } else { "csrutil reports enabled — yarm will not inject" });
    println!("  [{}] AMFI library-validation    {}", mark(amfi),
        if amfi { "boot-args contains amfi_get_out_of_my_way" }
        else { "not disabled — `yarm amfi-arm` then reboot for Apple-signed apps" });
    println!("  [{}] Dylib at {:<30} {}", mark(dylib_exists), dylib.display(), dylib_sig);
    println!("  [{}] LaunchAgent registered     {}", mark(agent),
        if agent { "~/Library/LaunchAgents/com.maxbridgland.yarm.agent.plist" } else { "run `yarm install`" });
    println!("  [{}] DYLD_INSERT_LIBRARIES set  {}", mark(dyld),
        if dyld { "in launchd gui session" } else { "run `yarm install` or relog" });

    if !sip {
        println!();
        println!("note: SIP is enabled; yarm cannot proceed. Boot to 1TR and run `csrutil disable`.");
    } else if !amfi {
        println!();
        println!("note: with AMFI library validation still on, yarm will only inject into");
        println!("      ad-hoc-signed binaries (third-party tools, dev builds). Apple's own");
        println!("      apps will silently reject the dylib. `yarm amfi-arm` to flip it.");
    }
    Ok(())
}

/// Optional active-injection probe: spawn /bin/echo with the dylib inserted
/// and confirm dyld actually loaded it. Smoke-test for "is the env var
/// plumbing alive in this shell."
pub fn probe() -> Result<()> {
    let dylib = crate::launchagent::dylib_path();
    anyhow::ensure!(dylib.exists(), "dylib not found at {}", dylib.display());
    let out = Command::new("/bin/echo")
        .env("DYLD_INSERT_LIBRARIES", &dylib)
        .env("YARM_RADIUS", "12")
        .arg("probe")
        .output()?;
    // The dylib logs to os_log; surface what we can show inline.
    let stderr = String::from_utf8_lossy(&out.stderr);
    if stderr.is_empty() {
        println!("/bin/echo ran (no stderr). Check log:");
        println!("  log show --last 30s --predicate 'subsystem == \"com.maxbridgland.yarm\"' --info");
    } else {
        print!("{stderr}");
    }
    Ok(())
}
