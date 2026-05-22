// Objective-C swizzles that force a uniform window corner radius.
//
// The hot path here is `yarm_apply_to_window`, which is reached from four
// swizzled NSWindow methods on every show / order / focus / contentView event.
// In a quiet app that's a handful of calls per session. In a busy Electron
// app (VS Code, Cursor) during a workload like `pnpm install` — with rapid
// notifications, popups, tooltips, and tasks-panel updates — those four
// methods can fire thousands of times per second.
//
// Without dedup, every call did:
//   * forced `wantsLayer = YES` on the contentView (rebuilds the layer tree
//     for a complex view hierarchy)
//   * called the private `-[NSWindow _setCornerRadius:]` (allocates an
//     internal corner-mask resource)
//   * opened a new `SLSTransactionCreate` and committed it (IPC + a
//     client-side buffer that SkyLight retains until WS acks)
//
// All idempotent in effect, all expensive in aggregate. A user reported 30GB+
// of RSS growth in Electron renderers under that load. The fix is the
// `yarm_window_needs_update` gate: per-window cache of last-applied radius,
// short-circuit early if unchanged. The cache is invalidated globally when
// the radius config reloads, so live `yarm set` still propagates.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <math.h>
#import "yarm_log.h"

YARM_LOG_DECL

extern double yarm_current_radius(void);
extern bool   yarm_runtime_disabled(void);
extern void   yarm_apply_counter_tick(void);

// ---- per-window radius cache (the dedupe) ---------------------------------

static os_unfair_lock g_window_cache_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber*, NSNumber*> *g_window_cache;

static BOOL yarm_window_needs_update(uint32_t wid, double r) {
    BOOL needs = NO;
    os_unfair_lock_lock(&g_window_cache_lock);
    if (!g_window_cache) g_window_cache = [NSMutableDictionary dictionaryWithCapacity:64];
    NSNumber *prev = g_window_cache[@(wid)];
    if (!prev || fabs(prev.doubleValue - r) > 0.01) {
        g_window_cache[@(wid)] = @(r);
        needs = YES;
        // Bound the cache so dead window IDs don't pile up forever in a
        // long-running process. 512 is well above any realistic NSWindow
        // count for a single app, even an Electron one. When we hit the cap
        // we flush completely — the next swizzle hits will re-populate the
        // entries that still matter.
        if (g_window_cache.count > 512) {
            [g_window_cache removeAllObjects];
        }
    }
    os_unfair_lock_unlock(&g_window_cache_lock);
    return needs;
}

// Called by yarm_inject.m when the radius config changes; otherwise the
// cache would suppress reapplication.
void yarm_invalidate_window_cache(void) {
    os_unfair_lock_lock(&g_window_cache_lock);
    [g_window_cache removeAllObjects];
    os_unfair_lock_unlock(&g_window_cache_lock);
}

// ---- proactive SkyLight path -----------------------------------------------

typedef struct _SLSTransaction *SLSTransactionRef;
typedef int CGSConnectionID;

static CGSConnectionID (*p_SLSMainConnectionID)(void);
static SLSTransactionRef (*p_SLSTransactionCreate)(CGSConnectionID);
static int (*p_SLSTransactionCommit)(SLSTransactionRef, int);
static void (*p_SLSTransactionSetWindowCornerRadius)(SLSTransactionRef, uint32_t, double);
static void (*p_SLSTransactionSetWindowSystemCornerRadius)(SLSTransactionRef, uint32_t, double);

static void yarm_resolve_sls_symbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p_SLSMainConnectionID                       = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        p_SLSTransactionCreate                      = dlsym(RTLD_DEFAULT, "SLSTransactionCreate");
        p_SLSTransactionCommit                      = dlsym(RTLD_DEFAULT, "SLSTransactionCommit");
        p_SLSTransactionSetWindowCornerRadius       = dlsym(RTLD_DEFAULT, "SLSTransactionSetWindowCornerRadius");
        p_SLSTransactionSetWindowSystemCornerRadius = dlsym(RTLD_DEFAULT, "SLSTransactionSetWindowSystemCornerRadius");
    });
}

static void yarm_force_radius_for_window(uint32_t wid) {
    yarm_resolve_sls_symbols();
    if (!p_SLSMainConnectionID || !p_SLSTransactionCreate ||
        !p_SLSTransactionCommit || !p_SLSTransactionSetWindowCornerRadius) {
        return;
    }
    CGSConnectionID cid = p_SLSMainConnectionID();
    SLSTransactionRef txn = p_SLSTransactionCreate(cid);
    if (!txn) return;
    double r = yarm_current_radius();
    p_SLSTransactionSetWindowCornerRadius(txn, wid, r);
    if (p_SLSTransactionSetWindowSystemCornerRadius) {
        p_SLSTransactionSetWindowSystemCornerRadius(txn, wid, r);
    }
    p_SLSTransactionCommit(txn, 0);
    CFRelease((CFTypeRef)txn);
}

// ---- helpers ---------------------------------------------------------------

static void yarm_apply_to_window(NSWindow *win) {
    // The watchdog flips this flag when our footprint or call rate gets out
    // of hand. Hot-path early-out: do nothing, let AppKit's normal radius
    // path run uninterrupted.
    if (yarm_runtime_disabled()) return;
    yarm_apply_counter_tick();

    if (!win) return;
    NSInteger wnum = win.windowNumber;
    if (wnum <= 0) return;  // window not yet assigned a CGSWindowID

    CGFloat r = (CGFloat)yarm_current_radius();
    // Single source of truth for "do we have work to do?" — gates all the
    // expensive work below. Without this, every swizzle hit ran the full
    // sequence even when the radius was already correct.
    if (!yarm_window_needs_update((uint32_t)wnum, r)) return;

    NSView *content = win.contentView;
    if (content) {
        if (!content.wantsLayer) content.wantsLayer = YES;
        CALayer *cl = content.layer;
        if (cl && cl.cornerRadius != r) {
            cl.cornerRadius = r;
            cl.masksToBounds = YES;
            if ([cl respondsToSelector:@selector(setCornerCurve:)]) {
                cl.cornerCurve = kCACornerCurveContinuous;
            }
        }
    }
    // Walk up to the themeFrame (the view AppKit installs as the window's
    // *actual* root; contentView is its child).
    NSView *root = content ? content.superview : nil;
    if (root && root.layer) {
        if (!root.wantsLayer) root.wantsLayer = YES;
        if (root.layer.cornerRadius != r) {
            root.layer.cornerRadius = r;
            root.layer.masksToBounds = YES;
            if ([root.layer respondsToSelector:@selector(setCornerCurve:)]) {
                root.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
    }
    // Best-effort call into NSWindow private API if it exists in this build.
    SEL setCornerRadius = NSSelectorFromString(@"_setCornerRadius:");
    if ([win respondsToSelector:setCornerRadius]) {
        void (*fn)(id, SEL, CGFloat) = (void *)objc_msgSend;
        fn(win, setCornerRadius, r);
    }
    // Proactive SkyLight transaction. Guarded above by the cache.
    yarm_force_radius_for_window((uint32_t)wnum);
}

void yarm_apply_to_all_windows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!NSApp) return;
        for (NSWindow *w in NSApp.windows) {
            yarm_apply_to_window(w);
        }
    });
}

// ---- swizzle primitive -----------------------------------------------------

static void yarm_swizzle(Class cls, SEL orig, SEL repl) {
    if (!cls) return;
    Method o = class_getInstanceMethod(cls, orig);
    Method n = class_getInstanceMethod(cls, repl);
    if (!o || !n) return;
    if (class_addMethod(cls, orig,
                        method_getImplementation(n),
                        method_getTypeEncoding(n))) {
        class_replaceMethod(cls, repl,
                            method_getImplementation(o),
                            method_getTypeEncoding(o));
    } else {
        method_exchangeImplementations(o, n);
    }
}

// ---- NSWindow category with replacement IMPLs ------------------------------

@interface NSWindow (YarmHooks)
@end

@implementation NSWindow (YarmHooks)

- (void)yarm_makeKeyAndOrderFront:(id)sender {
    [self yarm_makeKeyAndOrderFront:sender];
    yarm_apply_to_window(self);
}
- (void)yarm_orderFront:(id)sender {
    [self yarm_orderFront:sender];
    yarm_apply_to_window(self);
}
- (void)yarm_becomeKeyWindow {
    [self yarm_becomeKeyWindow];
    yarm_apply_to_window(self);
}
- (void)yarm_setContentView:(NSView *)view {
    [self yarm_setContentView:view];
    yarm_apply_to_window(self);
}

@end

// ---- entry from yarm_inject.m ---------------------------------------------

void yarm_install_swizzles(void) {
    if (getenv("YARM_NO_SWIZZLE")) {
        YARM_INFO("YARM_NO_SWIZZLE set; skipping NSWindow swizzles");
        return;
    }
    Class W = NSClassFromString(@"NSWindow");
    if (!W) return;
    yarm_swizzle(W, @selector(makeKeyAndOrderFront:), @selector(yarm_makeKeyAndOrderFront:));
    yarm_swizzle(W, @selector(orderFront:),           @selector(yarm_orderFront:));
    yarm_swizzle(W, @selector(becomeKeyWindow),       @selector(yarm_becomeKeyWindow));
    yarm_swizzle(W, @selector(setContentView:),       @selector(yarm_setContentView:));
    YARM_INFO("NSWindow swizzles installed");
}
