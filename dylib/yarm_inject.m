// libyarm.dylib entry point.
//
// Loaded into every host process via DYLD_INSERT_LIBRARIES (set on the user's
// launchd session by the yarm LaunchAgent). On +load we evaluate a gating
// chain that decides whether to do anything in this host:
//
//   1. Bundle type must be APPL (CFBundlePackageType). CLI tools idle.
//   2. Config mode == "third-party" => bail if we're a platform binary
//      (CS_PLATFORM_BINARY via csops). Apple's own apps stay untouched.
//   3. Bundle ID must not appear in exclude.txt.
//   4. Crash-recovery: read ~/.config/yarm/state/<bundleID>.state. If the
//      previous constructor entered but didn't reach the "stable" mark before
//      the host died, count it as a crash. Once consecutive_crashes hits
//      safety.crash_threshold, the dylib short-circuits on every subsequent
//      load until the user runs `yarm targets reset <bundleID>`.
//      include.txt overrides this — bundle IDs listed there are always tried.
//
// If everything passes, we install swizzles, subscribe to the reload
// notification, kick off a "stable" timer, and register an NSApplication
// termination observer that records the clean exit. The next constructor sees
// stable_ts > constructor_ts and resets the crash counter.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <notify.h>
#import <pthread.h>
#import <sys/syscall.h>
#import <sys/stat.h>
#import <stdatomic.h>
#import <time.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import "yarm_log.h"

YARM_LOG_DECL

// ---- forward decls implemented elsewhere -----------------------------------

void yarm_install_swizzles(void);
void yarm_apply_to_all_windows(void);
void yarm_invalidate_window_cache(void);

// ---- platform binary check via csops --------------------------------------

#define CS_OPS_STATUS         0
#define CS_PLATFORM_BINARY    0x04000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static BOOL yarm_is_platform_binary(void) {
    uint32_t flags = 0;
    if (csops(0, CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & CS_PLATFORM_BINARY) != 0;
}

// ---- shared state ----------------------------------------------------------

static _Atomic double g_radius = 12.0;
static double g_stable_threshold_seconds = 5.0;
static uint32_t g_crash_threshold = 2;
static NSString *g_bundle_id = nil;
static NSString *g_state_path = nil;
static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;

// Runtime watchdog state. Hot paths (swizzles + interposers) consult
// `g_yarm_runtime_disabled` on every call; when set they pass through to the
// original AppKit / SkyLight behavior without our overlay. Set by the
// background watchdog timer when either of two conditions trips:
//   * RSS grew by more than g_watchdog_rss_growth_mb since process start
//   * yarm_apply_to_window was called more than g_watchdog_rate_limit times
//     in a 60-second window (would-be hot loop after the cache fix)
static _Atomic bool g_yarm_runtime_disabled = false;
static _Atomic uint64_t g_apply_counter = 0;
static uint64_t g_baseline_rss = 0;
static uint64_t g_watchdog_rss_growth_mb = 1024;   // 1 GB default
static uint64_t g_watchdog_rate_limit    = 60000;  // 1000/sec sustained for 60s
static dispatch_source_t g_watchdog_timer = NULL;

double yarm_current_radius(void) { return g_radius; }

bool yarm_runtime_disabled(void) {
    return atomic_load_explicit(&g_yarm_runtime_disabled, memory_order_relaxed);
}

void yarm_apply_counter_tick(void) {
    atomic_fetch_add_explicit(&g_apply_counter, 1, memory_order_relaxed);
}

// ---- path helpers ----------------------------------------------------------

static NSString *yarm_config_dir(void) {
    NSString *home = NSHomeDirectory();
    return home ? [home stringByAppendingPathComponent:@".config/yarm"] : nil;
}

static NSString *yarm_config_path(void)  { return [yarm_config_dir() stringByAppendingPathComponent:@"config.toml"]; }
static NSString *yarm_exclude_path(void) { return [yarm_config_dir() stringByAppendingPathComponent:@"exclude.txt"]; }
static NSString *yarm_include_path(void) { return [yarm_config_dir() stringByAppendingPathComponent:@"include.txt"]; }

static NSString *yarm_state_path_for(NSString *bundleId) {
    NSString *dir = [yarm_config_dir() stringByAppendingPathComponent:@"state"];
    if (!dir || !bundleId) return nil;
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.state", bundleId]];
}

// ---- minimal TOML reader (one key per line; section header tracked) -------

static NSDictionary *yarm_parse_config(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *path = yarm_config_path();
    if (!path) return out;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return out;
    NSString *section = @"";
    for (NSString *raw in [contents componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            section = [line substringWithRange:NSMakeRange(1, line.length - 2)];
            continue;
        }
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        // Strip surrounding quotes.
        if ([val hasPrefix:@"\""] && [val hasSuffix:@"\""] && val.length >= 2) {
            val = [val substringWithRange:NSMakeRange(1, val.length - 2)];
        }
        NSString *fqkey = section.length ? [NSString stringWithFormat:@"%@.%@", section, key] : key;
        out[fqkey] = val;
    }
    return out;
}

// ---- list file reader ------------------------------------------------------

static NSSet *yarm_read_list(NSString *path) {
    NSMutableSet *s = [NSMutableSet set];
    if (!path) return s;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return s;
    for (NSString *raw in [contents componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange hash = [line rangeOfString:@"#"];
        if (hash.location != NSNotFound) {
            line = [[line substringToIndex:hash.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length == 0) continue;
        }
        [s addObject:line];
    }
    return s;
}

// ---- state file (k=v lines, atomic write via temp + rename) ---------------

typedef struct {
    uint64_t constructor_ts;
    uint64_t stable_ts;
    uint64_t clean_exit_ts;
    uint32_t consecutive_crashes;
    BOOL     auto_disabled;     // crash-recovery (constructor-detected) gate
    BOOL     watchdog_disabled; // runtime-watchdog gate; set when RSS/rate trip
} yarm_state;

static uint64_t yarm_now_unix(void) {
    return (uint64_t)time(NULL);
}

static yarm_state yarm_read_state(NSString *path) {
    yarm_state s = {0};
    if (!path) return s;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return s;
    for (NSString *raw in [contents componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [line substringToIndex:eq.location];
        NSString *v = [line substringFromIndex:eq.location + 1];
        if      ([k isEqualToString:@"constructor_ts"])      s.constructor_ts = (uint64_t)v.longLongValue;
        else if ([k isEqualToString:@"stable_ts"])           s.stable_ts = (uint64_t)v.longLongValue;
        else if ([k isEqualToString:@"clean_exit_ts"])       s.clean_exit_ts = (uint64_t)v.longLongValue;
        else if ([k isEqualToString:@"consecutive_crashes"]) s.consecutive_crashes = (uint32_t)v.intValue;
        else if ([k isEqualToString:@"auto_disabled"])       s.auto_disabled = [v isEqualToString:@"true"] || [v isEqualToString:@"1"];
        else if ([k isEqualToString:@"watchdog_disabled"])   s.watchdog_disabled = [v isEqualToString:@"true"] || [v isEqualToString:@"1"];
    }
    return s;
}

static void yarm_write_state(NSString *path, yarm_state s) {
    if (!path) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *body = [NSString stringWithFormat:
        @"constructor_ts=%llu\nstable_ts=%llu\nclean_exit_ts=%llu\n"
        @"consecutive_crashes=%u\nauto_disabled=%s\nwatchdog_disabled=%s\n",
        s.constructor_ts, s.stable_ts, s.clean_exit_ts, s.consecutive_crashes,
        s.auto_disabled ? "true" : "false",
        s.watchdog_disabled ? "true" : "false"];
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    NSError *err = nil;
    if (![body writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:&err]) {
        YARM_ERR("state write failed: %{public}@", err);
        return;
    }
    // atomic swap
    rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
}

// ---- core gating -----------------------------------------------------------

typedef enum {
    YARM_DECISION_PROCEED,
    YARM_DECISION_SKIP_NOT_APP,
    YARM_DECISION_SKIP_PLATFORM,
    YARM_DECISION_SKIP_EXCLUDED,
    YARM_DECISION_SKIP_CRASH_LIMIT,
    YARM_DECISION_SKIP_WATCHDOG,
} yarm_decision;

static yarm_decision yarm_evaluate_gates(NSString **out_bundle_id, yarm_state *out_state) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *type = b.infoDictionary[@"CFBundlePackageType"];
    if (![type isEqualToString:@"APPL"]) return YARM_DECISION_SKIP_NOT_APP;

    NSString *bundleId = b.bundleIdentifier ?: @"";
    *out_bundle_id = bundleId;

    NSDictionary *cfg = yarm_parse_config();
    NSString *mode = cfg[@"injection.mode"] ?: @"third-party";
    NSString *threshold_str = cfg[@"safety.crash_threshold"];
    if (threshold_str) g_crash_threshold = (uint32_t)threshold_str.intValue;
    NSString *stable_str = cfg[@"safety.stable_threshold_seconds"];
    if (stable_str) g_stable_threshold_seconds = stable_str.doubleValue;

    NSSet *excludes = yarm_read_list(yarm_exclude_path());
    NSSet *includes = yarm_read_list(yarm_include_path());

    BOOL is_included = bundleId.length > 0 && [includes containsObject:bundleId];

    // Mode + platform check
    if (!is_included && [mode isEqualToString:@"third-party"] && yarm_is_platform_binary()) {
        return YARM_DECISION_SKIP_PLATFORM;
    }
    // Exclude list (include overrides)
    if (!is_included && bundleId.length > 0 && [excludes containsObject:bundleId]) {
        return YARM_DECISION_SKIP_EXCLUDED;
    }

    // Crash recovery
    NSString *state_path = yarm_state_path_for(bundleId);
    yarm_state st = yarm_read_state(state_path);

    // Detect a previous crash: constructor was entered but neither stable nor
    // clean_exit advanced past it.
    if (st.constructor_ts > st.stable_ts && st.constructor_ts > st.clean_exit_ts) {
        st.consecutive_crashes += 1;
        YARM_INFO("yarm: previous launch of %{public}@ crashed before reaching stable; crashes=%u",
                  bundleId, st.consecutive_crashes);
    }

    if (!is_included && st.consecutive_crashes >= g_crash_threshold) {
        st.auto_disabled = YES;
        yarm_write_state(state_path, st);
        return YARM_DECISION_SKIP_CRASH_LIMIT;
    }
    // Watchdog-set lockout from a prior session. include.txt overrides.
    if (!is_included && st.watchdog_disabled) {
        yarm_write_state(state_path, st);
        return YARM_DECISION_SKIP_WATCHDOG;
    }
    st.auto_disabled = NO;
    st.constructor_ts = yarm_now_unix();
    yarm_write_state(state_path, st);

    *out_state = st;
    return YARM_DECISION_PROCEED;
}

// ---- radius load (still respects YARM_RADIUS env override) ----------------

static void yarm_reload_radius(void) {
    BOOL fromEnv = NO;
    const char *env = getenv("YARM_RADIUS");
    if (env && *env) {
        double v = strtod(env, NULL);
        if (v > 0 && v <= 128) { g_radius = v; fromEnv = YES; }
    }
    if (!fromEnv) {
        NSDictionary *cfg = yarm_parse_config();
        NSString *r = cfg[@"radius"];
        if (r) {
            double v = r.doubleValue;
            if (v > 0 && v <= 128) g_radius = v;
        }
    }
    YARM_INFO("radius -> %{public}.2f (pid=%d, bundle=%{public}@)",
              (double)g_radius, getpid(), g_bundle_id ?: @"?");
    // Drop the per-window cache so the next swizzle hit reapplies the new
    // radius even for windows the cache says "already done".
    yarm_invalidate_window_cache();
    yarm_apply_to_all_windows();
}

// ---- Darwin notification subscriber ---------------------------------------

static int g_notify_token = -1;
static void yarm_subscribe_notifications(void) {
    notify_register_dispatch("com.maxbridgland.yarm.reload",
                             &g_notify_token,
                             dispatch_get_main_queue(),
                             ^(int t) { (void)t; yarm_reload_radius(); });
}

// ---- stable timer + clean-exit observer -----------------------------------

static void yarm_schedule_stable_mark(void) {
    NSString *path = g_state_path;
    if (!path) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(g_stable_threshold_seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        yarm_state s = yarm_read_state(path);
        s.stable_ts = yarm_now_unix();
        s.consecutive_crashes = 0;
        s.auto_disabled = NO;
        yarm_write_state(path, s);
        YARM_DEBUG("marked stable for %{public}@", g_bundle_id);
    });
}

// ---- watchdog --------------------------------------------------------------

static uint64_t yarm_current_rss(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

static void yarm_trip_watchdog(const char *reason, uint64_t value) {
    if (atomic_exchange_explicit(&g_yarm_runtime_disabled, true,
                                 memory_order_relaxed)) {
        return; // already disabled
    }
    YARM_ERR("yarm watchdog tripped (%{public}s value=%llu); disabling further "
             "work for %{public}@. Run `yarm targets reset %{public}@` to clear.",
             reason, value, g_bundle_id ?: @"?", g_bundle_id ?: @"?");
    NSString *path = g_state_path;
    if (path) {
        yarm_state s = yarm_read_state(path);
        s.watchdog_disabled = YES;
        yarm_write_state(path, s);
    }
    if (g_watchdog_timer) {
        dispatch_source_cancel(g_watchdog_timer);
    }
}

static void yarm_start_watchdog(void) {
    g_baseline_rss = yarm_current_rss();

    // Read tunables from config (already parsed once; cheap to re-parse).
    NSDictionary *cfg = yarm_parse_config();
    NSString *rss_str  = cfg[@"safety.watchdog_rss_growth_mb"];
    NSString *rate_str = cfg[@"safety.watchdog_rate_limit_per_minute"];
    if (rss_str)  g_watchdog_rss_growth_mb = (uint64_t)rss_str.longLongValue;
    if (rate_str) g_watchdog_rate_limit    = (uint64_t)rate_str.longLongValue;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    g_watchdog_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!g_watchdog_timer) return;
    // Sample every 10s, 1s leeway. First fire after 30s so we don't trip on
    // startup transients.
    dispatch_source_set_timer(g_watchdog_timer,
        dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC,
        NSEC_PER_SEC);

    __block uint64_t prev_apply = 0;
    __block uint64_t window_start = (uint64_t)time(NULL);
    __block uint64_t window_baseline_apply = 0;

    dispatch_source_set_event_handler(g_watchdog_timer, ^{
        uint64_t rss = yarm_current_rss();
        if (rss > 0 && g_baseline_rss > 0) {
            uint64_t growth_bytes = (rss > g_baseline_rss) ? (rss - g_baseline_rss) : 0;
            uint64_t growth_mb = growth_bytes / (1024 * 1024);
            if (growth_mb > g_watchdog_rss_growth_mb) {
                yarm_trip_watchdog("rss-growth-mb", growth_mb);
                return;
            }
        }
        uint64_t now = (uint64_t)time(NULL);
        uint64_t apply = atomic_load_explicit(&g_apply_counter, memory_order_relaxed);
        (void)prev_apply;
        if (now - window_start >= 60) {
            uint64_t delta = apply - window_baseline_apply;
            if (delta > g_watchdog_rate_limit) {
                yarm_trip_watchdog("apply-rate-per-minute", delta);
                return;
            }
            window_start = now;
            window_baseline_apply = apply;
        }
        prev_apply = apply;
    });
    dispatch_resume(g_watchdog_timer);
}

static void yarm_register_clean_exit_observer(void) {
    NSString *path = g_state_path;
    if (!path) return;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification * _Nonnull n) {
        (void)n;
        yarm_state s = yarm_read_state(path);
        s.clean_exit_ts = yarm_now_unix();
        yarm_write_state(path, s);
    }];
}

// ---- init entry -----------------------------------------------------------

static void yarm_init_once(void) {
    NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
    if ([exe isEqualToString:@"yarm"]) return;

    NSString *bundle_id = nil;
    yarm_state st = {0};
    yarm_decision d = yarm_evaluate_gates(&bundle_id, &st);
    g_bundle_id = [bundle_id copy];

    switch (d) {
        case YARM_DECISION_SKIP_NOT_APP:
            YARM_DEBUG("yarm: %{public}@ not an .app bundle, idling", exe);
            return;
        case YARM_DECISION_SKIP_PLATFORM:
            YARM_DEBUG("yarm: %{public}@ (%{public}@) is a platform binary; skipping (mode=third-party)",
                       exe, bundle_id);
            return;
        case YARM_DECISION_SKIP_EXCLUDED:
            YARM_INFO("yarm: %{public}@ is in exclude.txt, skipping", bundle_id);
            return;
        case YARM_DECISION_SKIP_CRASH_LIMIT:
            YARM_INFO("yarm: %{public}@ auto-disabled (crash threshold reached). "
                      "Run `yarm targets reset %{public}@` to re-enable.",
                      bundle_id, bundle_id);
            return;
        case YARM_DECISION_SKIP_WATCHDOG:
            YARM_INFO("yarm: %{public}@ disabled by watchdog from previous run "
                      "(RSS/rate limit). Run `yarm targets reset %{public}@` to re-enable.",
                      bundle_id, bundle_id);
            return;
        case YARM_DECISION_PROCEED:
            break;
    }

    g_state_path = [yarm_state_path_for(bundle_id) copy];

    YARM_INFO("yarm dylib loaded into %{public}@ (bundle=%{public}@, pid=%d)",
              exe, bundle_id, getpid());

    yarm_install_swizzles();
    yarm_reload_radius();
    yarm_subscribe_notifications();
    yarm_schedule_stable_mark();
    yarm_register_clean_exit_observer();
    yarm_start_watchdog();
}

__attribute__((constructor))
static void yarm_init(void) {
    pthread_once(&g_init_once, yarm_init_once);
}
