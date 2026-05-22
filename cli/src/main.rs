mod borders;
mod config;
mod launchagent;
mod notify;
mod system;
mod targets;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "yarm",
    version,
    about = "Yet Another Radius Manager — uniform corner radius on macOS Tahoe"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Set the global window corner radius (points). Applies live to running + new apps.
    Set {
        /// Radius in points, e.g. 12
        radius: f64,
    },
    /// Print the current configured radius.
    Get,
    /// Print install/agent/dylib/borders status.
    Status,
    /// Place the LaunchAgent plist in ~/Library/LaunchAgents (does not activate; call `start`).
    Install,
    /// Activate: register LaunchAgent + set DYLD_INSERT_LIBRARIES in the live launchd session.
    Start,
    /// Deactivate: unset DYLD env + remove LaunchAgent from launchd. Plist stays on disk.
    Stop,
    /// Stop then start. Useful after `yarm set` if you want to forcibly re-prime new processes.
    Restart,
    /// Remove the LaunchAgent plist entirely (use install.sh --uninstall for binaries).
    Uninstall,
    /// Re-apply current config without changing it (post Darwin notification, kick borders).
    Reload,
    /// Print system diagnostics: SIP, AMFI, dylib, agent, DYLD env.
    Doctor,
    /// Disable AMFI library validation so the dylib can inject into Apple-signed apps. Reboot required.
    AmfiArm,
    /// Re-enable AMFI library validation by removing the boot-arg. Reboot required.
    AmfiDisarm,
    /// Quick smoke-test of injection plumbing.
    Probe,
    /// Manage per-bundle injection targeting + crash state.
    #[command(subcommand)]
    Targets(TargetsCmd),
}

#[derive(Subcommand)]
enum TargetsCmd {
    /// Show config, exclude/include lists, and per-bundle crash state.
    Show,
    /// Set injection mode: third-party (safe default) or all (opt-in, risky).
    Mode { mode: String },
    /// Add a bundle ID to the exclude list.
    Exclude { bundle_id: String },
    /// Remove a bundle ID from the exclude list.
    Unexclude { bundle_id: String },
    /// Add a bundle ID to the include list (overrides crash-disable).
    Include { bundle_id: String },
    /// Remove a bundle ID from the include list.
    Uninclude { bundle_id: String },
    /// Clear crash-recovery state for one bundle (re-enable after auto-disable).
    Reset { bundle_id: String },
    /// Clear crash-recovery state for ALL bundles.
    ResetAll,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Set { radius } => {
            anyhow::ensure!(
                (0.0..=64.0).contains(&radius),
                "radius must be between 0 and 64 points"
            );
            let mut cfg = config::Config::load_or_default()?;
            cfg.radius = radius;
            cfg.save().context("saving config")?;
            borders::sync(radius).context("syncing JankyBorders")?;
            notify::post_reload().context("posting reload notification")?;
            println!("radius set to {radius}");
        }
        Cmd::Get => {
            let cfg = config::Config::load_or_default()?;
            println!("{}", cfg.radius);
        }
        Cmd::Status => {
            let cfg = config::Config::load_or_default()?;
            let installed = launchagent::is_installed()?;
            let loaded = launchagent::is_loaded_in_launchd();
            let dyld_set = launchagent::dyld_env_set()?;
            let borders_pid = borders::pid();
            let dylib = launchagent::installed_dylib_path()
                .unwrap_or_else(launchagent::dylib_path);
            println!("radius:           {}", cfg.radius);
            println!("dylib:            {}", dylib.display());
            println!("LaunchAgent:      {}", if installed { "installed" } else { "not installed (run `yarm install`)" });
            println!("launchd state:    {}", if loaded { "loaded" } else { "not loaded (run `yarm start`)" });
            println!("DYLD env set:     {}", if dyld_set { "yes" } else { "no" });
            println!("borders process:  {}", borders_pid.map(|p| p.to_string()).unwrap_or_else(|| "not running".into()));
        }
        Cmd::Install => {
            launchagent::install().context("installing LaunchAgent")?;
            println!("LaunchAgent installed at ~/Library/LaunchAgents/{}.plist", launchagent::LABEL);
            println!("run `yarm start` to activate now (or `yarm restart` after `yarm set`).");
        }
        Cmd::Start => {
            launchagent::start().context("starting LaunchAgent")?;
            let cfg = config::Config::load_or_default()?;
            borders::sync(cfg.radius).ok();
            notify::post_reload().ok();
            println!("started. new apps (and apps relaunched after this) will be injected.");
            println!("apps already running need a quit+reopen to pick up the dylib.");
        }
        Cmd::Stop => {
            launchagent::stop().context("stopping LaunchAgent")?;
            println!("stopped. new processes will no longer be injected.");
            println!("apps already injected keep the dylib loaded until they exit.");
        }
        Cmd::Restart => {
            launchagent::restart().context("restarting LaunchAgent")?;
            println!("restarted.");
        }
        Cmd::Uninstall => {
            launchagent::uninstall().context("uninstalling LaunchAgent")?;
            println!("LaunchAgent removed. Binaries still in place — run install.sh --uninstall to remove those too.");
        }
        Cmd::Reload => {
            let cfg = config::Config::load_or_default()?;
            borders::sync(cfg.radius).ok();
            notify::post_reload()?;
            println!("reload posted at radius {}", cfg.radius);
        }
        Cmd::Doctor => system::doctor()?,
        Cmd::AmfiArm => system::amfi_arm()?,
        Cmd::AmfiDisarm => system::amfi_disarm()?,
        Cmd::Probe => system::probe()?,
        Cmd::Targets(t) => match t {
            TargetsCmd::Show => targets::show()?,
            TargetsCmd::Mode { mode } => targets::set_mode(&mode)?,
            TargetsCmd::Exclude { bundle_id } => targets::exclude(&bundle_id)?,
            TargetsCmd::Unexclude { bundle_id } => targets::unexclude(&bundle_id)?,
            TargetsCmd::Include { bundle_id } => targets::include(&bundle_id)?,
            TargetsCmd::Uninclude { bundle_id } => targets::uninclude(&bundle_id)?,
            TargetsCmd::Reset { bundle_id } => targets::reset(&bundle_id)?,
            TargetsCmd::ResetAll => targets::reset_all()?,
        },
    }
    Ok(())
}
