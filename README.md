# yarm

**Y**et **A**nother **R**adius **M**anager — uniform window corner radius across apps on macOS Tahoe.

> ⚠️ **Read this before installing.**
> yarm uses `DYLD_INSERT_LIBRARIES` to load an unsigned dylib into every GUI app launched from your session. That means:
> - **SIP must be disabled.** Reversing this later requires a Recovery-mode boot.
> - The dylib runs *inside* every third-party app you open. A bug here is a bug in every app — including memory leaks, crashes on launch, and weird UI behavior. Earlier prerelease versions caused 30GB+ RSS spikes in Electron apps under heavy load; the current build adds a per-window cache and a runtime watchdog (`safety.watchdog_*` keys in `config.toml`) that self-disables the dylib when its footprint or call rate gets out of hand. Recovery from a broken state is `launchctl unsetenv DYLD_INSERT_LIBRARIES` — please keep that command handy.
> - "System-wide" mode (covering Safari, Mail, App Store apps, etc.) needs AMFI weakened via `nvram boot-args` and won't fully work on Cryptex-resident apps. **The default `third-party` mode is the only one I'd run on a machine I depend on.**
> - This is a personal project published for people who want to fiddle with macOS internals. Use it on a machine where you're comfortable booting to Recovery, not your sole work machine.

Tahoe's compositor applies different corner radii per app class (the "system corner radius" path), which makes desktop chrome look inconsistent. yarm forces every window to one radius by interposing the private SkyLight transaction setters and swizzling AppKit's window-show codepaths from inside an injected dylib. JankyBorders' `border_radius` is kept in sync automatically.

## Requirements

- macOS **Tahoe** (26.x) on **Apple Silicon** (`arm64`)
- **SIP disabled** (`csrutil disable` from Recovery / 1TR)
- Xcode Command Line Tools and a Rust toolchain (`rustup`)
- Optional: [`yabai`](https://github.com/koekeishiya/yabai), [JankyBorders](https://github.com/FelixKratz/JankyBorders)

## Install

Via Homebrew tap (recommended once a tagged release exists):

```sh
brew tap M4cs/yarm
brew install yarm
yarm install && yarm start
```

Or from source:

```sh
git clone https://github.com/M4cs/yarm.git
cd yarm
./install.sh
```

`install.sh` builds the universal `arm64 + arm64e` dylib, installs to `/opt/homebrew/{lib,bin}`, writes the LaunchAgent, and runs `launchctl setenv DYLD_INSERT_LIBRARIES`. After install, new app launches inherit the dylib; quit + reopen anything already running.

## Two modes: third-party vs system-wide

yarm has two injection modes. The default is **third-party** because it's the only one Tahoe lets you run without things crashing.

### `mode = "third-party"` (default, safe)

- AMFI is in its **default state** (enforcing). Tahoe's kernel auto-strips `DYLD_INSERT_LIBRARIES` from platform binaries (Apple's own apps, Cryptex-resident apps) — they don't try to load our dylib, and they don't crash.
- The dylib only touches third-party apps that ship with the `com.apple.security.cs.disable-library-validation` entitlement: Zen, VS Code, Discord, Cursor, Arc, iTerm, Ghostty, Spotify, JankyBorders, and most other Electron / non-App-Store distributions.
- Inside the dylib, an extra belt-and-braces check (`csops(CS_OPS_STATUS) & CS_PLATFORM_BINARY`) idles on any platform binary that did slip through.

```sh
yarm targets mode third-party
```

### `mode = "all"` (opt-in, partial)

- Requires `yarm amfi-arm` + reboot, which sets `amfi_get_out_of_my_way=0x1` in nvram boot-args.
- After reboot, AMFI no longer strips `DYLD_INSERT_LIBRARIES` from platform binaries. The dylib gets a chance to load into Apple's own apps.
- **However**: Cryptex-resident apps (Safari, Mail, App Store apps, Finder…) still enforce **library validation** at the kernel codesign layer, which `amfi_get_out_of_my_way` does **not** bypass. dyld will `SIGKILL` those processes on launch with "code signature invalid" because our dylib doesn't have a matching TeamID.
- yarm's exclude list + crash-recovery (below) is what makes this mode usable: the dylib auto-disables itself for any app that crashes twice in a row, and you can pre-emptively exclude known offenders with `yarm targets exclude com.apple.Safari`.
- Truly system-wide Apple-app coverage requires `csrutil authenticated-root disable` + remounting the cryptex read-write + modifying or re-signing the cryptex binaries. That's beyond what yarm scripts; see "Going further" below.

```sh
yarm amfi-arm
# reboot
yarm targets mode all
```

To revert:

```sh
yarm amfi-disarm
yarm targets mode third-party
# reboot
```

## Compatibility matrix

What gets injected under each SIP / AMFI combination. The combination "SIP on, AMFI armed" is impossible — `nvram boot-args` writes are blocked by SIP, so you can't set `amfi_get_out_of_my_way=1` without first running `csrutil disable`.

App categories used in the table:

- **3P, no HR** — third-party app without hardened runtime. Older indie apps, some unsigned tools.
- **3P, HR + LV-disable** — hardened runtime *with* `com.apple.security.cs.disable-library-validation`. Most Electron apps and developer tools: VS Code, Discord, Cursor, Arc, iTerm, Ghostty, Spotify, Zen.
- **3P, HR strict** — hardened runtime *without* the LV-disable entitlement. Many App Store third-party apps.
- **Apple, non-cryptex** — Apple-signed platform binaries that live on the data volume (some utilities, some bundled apps).
- **Apple, cryptex** — Apple apps shipped inside the system cryptex: Safari, Mail, Finder, App Store, most of system UI. These enforce library validation at the kernel codesign layer, which `amfi_get_out_of_my_way` does **not** bypass.

| State                                              | yarm mode      | 3P, no HR | 3P, HR + LV-disable | 3P, HR strict | Apple, non-cryptex | Apple, cryptex |
|----------------------------------------------------|----------------|:---------:|:-------------------:|:-------------:|:------------------:|:--------------:|
| SIP on, AMFI enforcing *(default)*                 | `third-party`  | ✅        | ✅                  | ❌            | ❌                 | ❌             |
| SIP off, AMFI enforcing                            | `third-party`  | ✅        | ✅                  | ❌            | ❌                 | ❌             |
| SIP off, AMFI armed (`amfi_get_out_of_my_way=1`)   | `all`          | ✅        | ✅                  | ✅            | ✅                 | ❌             |
| SIP off, AMFI armed + cryptex re-signed *(manual)* | `all` + fork   | ✅        | ✅                  | ✅            | ✅                 | ✅             |

Notes:

- **SIP off alone changes nothing for injection coverage.** It only unlocks the ability to set the AMFI boot-arg and to modify SIP-protected files. If you're staying in `third-party` mode, leaving SIP enabled is functionally identical and strictly safer.
- **`amfi_get_out_of_my_way=1` requires SIP off**, but SIP-off does not imply AMFI-armed. They are independent toggles with SIP gating the second.
- **Cryptex coverage is not scripted by yarm.** It needs `csrutil authenticated-root disable` plus a re-signed cryptex; see [Going further](#going-further).
- The "yarm mode" column shows what `[injection].mode` you'd set in `config.toml`. `mode = "all"` on a machine that doesn't have AMFI armed is just a slower `third-party` — the kernel still strips `DYLD_INSERT_LIBRARIES` from platform binaries.

## Use

```sh
yarm set 8         # radius in points. live to running + new apps via Darwin notification.
yarm get           # current radius
yarm reload        # re-push current config to running apps (no relaunch needed)
yarm status        # install + launchd + DYLD state
yarm doctor        # SIP / AMFI / dylib / agent diagnostic
```

## Lifecycle

```sh
yarm install       # write the LaunchAgent plist (no activation yet)
yarm start         # bootstrap into gui/<uid> + launchctl setenv
yarm stop          # unset env + bootout. plist stays on disk.
yarm restart       # stop + start
yarm uninstall     # remove the plist
./install.sh --uninstall   # also remove the dylib + cli
```

`stop` does **not** eject the dylib from processes that already loaded it — dyld doesn't support unloading. It only prevents future processes from inheriting the env var. Quit + reopen an app to fully drop the dylib.

## Targeting and crash recovery

Per-bundle injection control + automatic safety net for apps that misbehave with the dylib loaded.

```sh
yarm targets show                              # current config + lists + crash tallies
yarm targets mode third-party                  # safe default
yarm targets mode all                          # opt-in, see warning above
yarm targets exclude com.apple.Safari          # never inject this bundle
yarm targets unexclude com.apple.Safari        # undo
yarm targets include com.foo.bar               # force-inject even if auto-disabled
yarm targets uninclude com.foo.bar
yarm targets reset com.foo.bar                 # clear crash tally → re-enable
yarm targets reset-all
```

**Crash recovery, how it works.** On every dylib load the constructor records a `constructor_ts` in `~/.config/yarm/state/<bundleID>.state`. Five seconds (configurable) after the host reaches its run loop, the dylib marks `stable_ts`. On `NSApplicationWillTerminate` it marks `clean_exit_ts`. On the next load the constructor sees `constructor_ts > stable_ts && constructor_ts > clean_exit_ts` and concludes the previous launch crashed before becoming stable — `consecutive_crashes++`. Once that counter hits `safety.crash_threshold` (default 2), the dylib short-circuits on every subsequent load until you run `yarm targets reset <bundleID>` or add the bundle to `include.txt`.

**Limit:** crash recovery only works if our constructor runs. For Cryptex apps under `mode = "all"`, dyld kills the host *before* our code executes, so there's nothing to record. Add such bundles to `exclude.txt` to stop the crash spam.

## Configuration

`~/.config/yarm/config.toml`:

```toml
radius = 12.0

[injection]
mode = "third-party"  # "third-party" | "all"

[safety]
crash_threshold = 2
stable_threshold_seconds = 5
```

`~/.config/yarm/exclude.txt` and `~/.config/yarm/include.txt`: one bundle ID per line, `#` comments OK.

`~/.config/yarm/state/<bundleID>.state`: written by the dylib, inspected by `yarm targets show`.

## Troubleshooting

`yarm doctor` first. Then:

- **Radius didn't change after `yarm set`** — already-running app? `yarm reload` only affects processes that have the dylib loaded. `yarm restart` and quit + reopen the app.
- **Specific app not affected** — `codesign -dv --entitlements - "/Applications/<App>.app/Contents/MacOS/<bin>"`. If it has the hardened runtime but no `com.apple.security.cs.disable-library-validation` entitlement, the kernel stripped the env var. `mode = "all"` + AMFI bypass is required (with the cryptex caveat).
- **An app is auto-disabled** — `yarm targets show` lists which. `yarm targets reset <bundleID>` clears the tally.
- **An app crashes on every launch** — `yarm targets exclude <bundleID>`. If you're not sure which bundle, `log stream --predicate 'subsystem == "com.maxbridgland.yarm"' --info --debug` and watch for `yarm dylib loaded into <name> (bundle=<id>, ...)` right before the crash.
- **Crash spam from a system daemon after stop** — `yarm stop` only unsets the env var; daemons that already loaded the dylib keep it mapped in memory and will keep crashing until they're killed. `killall <daemon>` for individual ones, or log out / reboot to flush everything.
- **Nothing seems to work** — `launchctl getenv DYLD_INSERT_LIBRARIES`. Empty means the LaunchAgent didn't apply; `yarm start` again.

## Going further

`mode = "all"` reaches some Apple apps but not the cryptex-resident ones — they cs-kill on dylib load. Fully covering those requires one of:

1. **Re-signing the cryptex.** `csrutil authenticated-root disable` from 1TR, remount the Preboot volume read-write, modify Safari et al. or our dylib so signatures align, reseal the snapshot. Invasive, breaks OTA updates, and Apple actively makes this harder every release.
2. **Out-of-process injection.** Use `task_for_pid` (with the right AMFI flags) + a mach helper that maps the dylib and creates a thread inside the target. Sidesteps dyld's library-validation entirely. This is what Frida does. Not currently part of yarm.
3. **Sign the dylib with a real Developer ID** matching the host TeamID. Impossible for Apple's own apps; possible for a Developer-ID-signed third-party app you control.

None of these are scripted by yarm. If you want this path, the codebase is small enough to fork and extend — see `dylib/yarm_inject.m` for the injection entry, `dylib/yarm_interpose.c` for the SkyLight surface.

## How it works

Three layers, all in [`dylib/`](./dylib/):

1. **C `__interpose` against SkyLight** ([`yarm_interpose.c`](./dylib/yarm_interpose.c)). When AppKit calls `SLSTransactionSetWindowCornerRadius` (or its `System` / `Clear` siblings) we substitute the configured value before the transaction reaches WindowServer. Signatures and opcodes from disassembling SkyLight on Tahoe 26.5.
2. **Objective-C swizzle on `NSWindow`** ([`yarm_swizzle.m`](./dylib/yarm_swizzle.m)). After every `makeKeyAndOrderFront:` / `orderFront:` / `becomeKeyWindow` / `setContentView:` we force the content layer's and theme frame's `cornerRadius` + `cornerCurve = continuous`, and call private `_setCornerRadius:` on `NSWindow`.
3. **Proactive `SLSTransaction`** ([`yarm_swizzle.m`](./dylib/yarm_swizzle.m)). After each window-show event the swizzle opens its own `SLSTransactionCreate` → `SetWindowCornerRadius` → `SetWindowSystemCornerRadius` → `SLSTransactionCommit` cycle, covering windows that never go through AppKit's compositor path.

[`yarm_inject.m`](./dylib/yarm_inject.m) is the entry point: it walks the gating chain (bundle is `.app`? mode allows platform binaries? bundle in exclude.txt? crash threshold reached?) and short-circuits before any of the above runs when appropriate. The CLI ([`cli/`](./cli/)) is a thin Rust wrapper over launchctl / nvram / file IO.
