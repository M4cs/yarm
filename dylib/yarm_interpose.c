// dyld __interpose section: rewrites the radius argument WindowServer is told
// to apply, on every transaction setter SkyLight exposes for window corner
// radius on macOS Tahoe.
//
// Symbols were located in SkyLight at runtime (dlsym confirms they're all
// resolvable on 26.5) and signatures decoded from disassembly:
//
//   void SLSTransactionSetWindowCornerRadius(
//       SLSTransactionRef txn, uint32_t wid, double radius);
//   void SLSTransactionSetWindowSystemCornerRadius(
//       SLSTransactionRef txn, uint32_t wid, double radius);   // Tahoe-new
//   void SLSTransactionClearWindowCornerRadius(
//       SLSTransactionRef txn, uint32_t wid);
//   void SLSTransactionClearWindowSystemCornerRadius(
//       SLSTransactionRef txn, uint32_t wid);                  // Tahoe-new
//   void SLSTransactionSetWindowCornerRadiusMaskedCorners(
//       SLSTransactionRef txn, uint32_t wid, uint32_t maskedCorners);
//
// The "System" variants are the new Tahoe path where the OS picks a radius
// per-window-class — that's the per-app variability we're trying to unify.
//
// Policy:
//   * Set / SetSystem  -> forward with our radius (ignore caller's value).
//   * Clear / ClearSystem -> let the clear pass through, then re-Set ours.
//   * MaskedCorners    -> forward unchanged (controls *which* corners are
//                         rounded — keeping caller intent).
//
// All targets are declared weak_import; in processes that don't link SkyLight
// (CLI tools, etc.) the interpose entries simply never bind.

#include <stdint.h>
#include <stdbool.h>

extern double yarm_current_radius(void);
extern bool   yarm_runtime_disabled(void);

typedef struct _SLSTransaction *SLSTransactionRef;

#define DYLD_INTERPOSE(_repl, _orig) \
    __attribute__((used)) static struct { \
        const void *repl; \
        const void *orig; \
    } _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_repl, (const void *)(uintptr_t)&_orig \
    };

// ---- Externs (weak so the dylib loads in non-SkyLight processes too) ------

extern void SLSTransactionSetWindowCornerRadius(
    SLSTransactionRef txn, uint32_t wid, double radius) __attribute__((weak_import));
extern void SLSTransactionSetWindowSystemCornerRadius(
    SLSTransactionRef txn, uint32_t wid, double radius) __attribute__((weak_import));
extern void SLSTransactionClearWindowCornerRadius(
    SLSTransactionRef txn, uint32_t wid) __attribute__((weak_import));
extern void SLSTransactionClearWindowSystemCornerRadius(
    SLSTransactionRef txn, uint32_t wid) __attribute__((weak_import));
extern void SLSTransactionSetWindowCornerRadiusMaskedCorners(
    SLSTransactionRef txn, uint32_t wid, uint32_t maskedCorners) __attribute__((weak_import));

// ---- Interposers ----------------------------------------------------------

// These wrappers fire on AppKit's NATURAL SkyLight calls. Apps doing live
// window updates (drag, resize, focus change in a busy Electron renderer)
// can hit them at hundreds of Hz. No logging here on purpose — the cost of
// even an os_log_debug at that rate is non-trivial when a log subscriber is
// attached, and the original incident report involved 30GB+ RSS growth in
// processes doing exactly that kind of churn.

static void yarm_SLSTransactionSetWindowCornerRadius(
    SLSTransactionRef txn, uint32_t wid, double caller_radius) {
    double r = yarm_runtime_disabled() ? caller_radius : yarm_current_radius();
    if (&SLSTransactionSetWindowCornerRadius)
        SLSTransactionSetWindowCornerRadius(txn, wid, r);
}
DYLD_INTERPOSE(yarm_SLSTransactionSetWindowCornerRadius,
               SLSTransactionSetWindowCornerRadius)

static void yarm_SLSTransactionSetWindowSystemCornerRadius(
    SLSTransactionRef txn, uint32_t wid, double caller_radius) {
    double r = yarm_runtime_disabled() ? caller_radius : yarm_current_radius();
    if (&SLSTransactionSetWindowSystemCornerRadius)
        SLSTransactionSetWindowSystemCornerRadius(txn, wid, r);
}
DYLD_INTERPOSE(yarm_SLSTransactionSetWindowSystemCornerRadius,
               SLSTransactionSetWindowSystemCornerRadius)

static void yarm_SLSTransactionClearWindowCornerRadius(
    SLSTransactionRef txn, uint32_t wid) {
    if (&SLSTransactionClearWindowCornerRadius)
        SLSTransactionClearWindowCornerRadius(txn, wid);
    // When disabled we leave the cleared state alone — caller wanted no
    // rounding, we honor it.
    if (yarm_runtime_disabled()) return;
    if (&SLSTransactionSetWindowCornerRadius)
        SLSTransactionSetWindowCornerRadius(txn, wid, yarm_current_radius());
}
DYLD_INTERPOSE(yarm_SLSTransactionClearWindowCornerRadius,
               SLSTransactionClearWindowCornerRadius)

static void yarm_SLSTransactionClearWindowSystemCornerRadius(
    SLSTransactionRef txn, uint32_t wid) {
    if (&SLSTransactionClearWindowSystemCornerRadius)
        SLSTransactionClearWindowSystemCornerRadius(txn, wid);
    if (yarm_runtime_disabled()) return;
    if (&SLSTransactionSetWindowSystemCornerRadius)
        SLSTransactionSetWindowSystemCornerRadius(txn, wid, yarm_current_radius());
}
DYLD_INTERPOSE(yarm_SLSTransactionClearWindowSystemCornerRadius,
               SLSTransactionClearWindowSystemCornerRadius)
