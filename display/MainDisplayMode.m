#import "display/MainDisplayMode.h"
#include <math.h>
#define RDP_LOG_COMPONENT "display"
#include "logging/RDPLog.h"

/* Set once a change has failed. WindowServer can take ten seconds to give up
 * (it waits on every app to answer a ping first), so a Mac that refuses is
 * not asked again on each connect and resize. */
static _Atomic BOOL sRefused = NO;

@implementation MainDisplayMode {
    CGDirectDisplayID _displayID;
    CGDisplayModeRef _original;   /* the mode before the first change, or NULL */
}

+ (BOOL)isEnabled {
    const char *env = getenv("RDP_MATCH_RESOLUTION");
    return !(env && strcmp(env, "0") == 0) && !sRefused;
}

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID {
    if ((self = [super init])) _displayID = displayID;
    return self;
}

- (void)dealloc {
    if (_original) CGDisplayModeRelease(_original);
}

static BOOL isHiDPI(CGDisplayModeRef mode) {
    return CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode);
}

/* Lower is better: how far the mode is from the size asked for, then whether
 * it has the density asked for, then the refresh rate in use now. */
static double score(CGDisplayModeRef mode, double w, double h, BOOL hiDPI, double refresh) {
    double mw = (double)CGDisplayModeGetWidth(mode), mh = (double)CGDisplayModeGetHeight(mode);
    double s = fabs(log(mw / w)) + fabs(log(mh / h));
    if (isHiDPI(mode) != hiDPI) s += 0.001;
    if (refresh > 0 && fabs(CGDisplayModeGetRefreshRate(mode) - refresh) > 0.5) s += 0.0001;
    return s;
}

- (BOOL)matchPointWidth:(double)w height:(double)h hiDPI:(BOOL)hiDPI {
    if (w < 1 || h < 1 || sRefused) return NO;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(_displayID);
    if (!current) return NO;
    double refresh = CGDisplayModeGetRefreshRate(current);

    CFDictionaryRef options = (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_displayID, options);
    CGDisplayModeRef best = NULL;
    double bestScore = INFINITY;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        double s = score(mode, w, h, hiDPI, refresh);
        if (s < bestScore) { bestScore = s; best = mode; }
    }
    BOOL changed = NO;
    /* The mode in use scores as well as the best: nothing to change. */
    if (best && score(current, w, h, hiDPI, refresh) > bestScore) {
        CGDisplayConfigRef config = NULL;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(config, _displayID, best, NULL);
            CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
            if (err == kCGErrorSuccess) {
                if (!_original) _original = CGDisplayModeRetain(current);
                changed = YES;
                rdp_info("main display: %zux%zu%s for a client asking for %.0fx%.0f%s",
                         CGDisplayModeGetWidth(best), CGDisplayModeGetHeight(best),
                         isHiDPI(best) ? " HiDPI" : "", w, h, hiDPI ? " HiDPI" : "");
            } else {
                sRefused = YES;
                rdp_error("main display: changing the resolution failed (%d); leaving it as it is "
                          "until the daemon restarts", err);
            }
        }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(current);
    return changed;
}

- (void)restore {
    if (!_original) return;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
        CGConfigureDisplayWithDisplayMode(config, _displayID, _original, NULL);
        CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
        if (err == kCGErrorSuccess)
            rdp_info("main display: back to %zux%zu", CGDisplayModeGetWidth(_original),
                     CGDisplayModeGetHeight(_original));
        else
            rdp_error("main display: restoring the resolution failed (%d)", err);
    }
    CGDisplayModeRelease(_original);
    _original = NULL;
}

@end
