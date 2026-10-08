#import "display/VirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
#define RDP_LOG_COMPONENT "display"
#include "logging/RDPLog.h"

@interface VirtualDisplay ()
@property (nonatomic, assign) CGDirectDisplayID did;
@property (nonatomic, assign) uint32_t w;
@property (nonatomic, assign) uint32_t h;
@property (nonatomic, assign) BOOL created;
@property (nonatomic, assign) BOOL hidpi;

#if MACOS_RDP_VIRTUAL_DISPLAY
/* Opaque pointers so the compiler doesn't need CGVirtualDisplay headers here.
 * CGVirtualDisplay and its private VirtualDisplayListener thread keep using the
 * descriptor/mode/settings objects AFTER applySettings: returns, so all of them
 * must be retained for the display's whole lifetime — otherwise they dealloc when
 * createVirtualDisplay returns and the listener thread crashes on freed memory. */
@property (nonatomic, strong) id vdObject;
@property (nonatomic, strong) id vdDescriptor;
@property (nonatomic, strong) id vdMode;
@property (nonatomic, strong) id vdSettings;
#endif
@end

@implementation VirtualDisplay

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
    return [self initWithWidth:width height:height hiDPI:NO];
}

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI {
    if ((self = [super init])) {
        _w = width;
        _h = height;
        _hidpi = hiDPI;
    }
    return self;
}

- (BOOL)hiDPI { return _hidpi; }

- (CGDirectDisplayID)displayID { return _did; }
- (uint32_t)width              { return _w; }
- (uint32_t)height             { return _h; }

- (BOOL)create {
    if (_created) return YES;

#if MACOS_RDP_VIRTUAL_DISPLAY
    [self createVirtualDisplay];
#else
    /* Default: capture the main display. Physical display is undisturbed
       because RDP sessions run in a separate window-server context when
       the daemon is launched as a login item for a specific user. */
    _did = CGMainDisplayID();
    rdp_info("using main display %u (%ux%u) — build with MACOS_RDP_VIRTUAL_DISPLAY=1 "
             "for a dedicated virtual display (requires Apple entitlement)", _did, _w, _h);
#endif

    _created = YES;
    return YES;
}

- (void)destroy {
    if (!_created) return;
#if MACOS_RDP_VIRTUAL_DISPLAY
    /* Release in reverse dependency order: drop the display first (stops its
     * listener thread), then the settings/mode/descriptor it referenced. */
    _vdObject     = nil;
    _vdSettings   = nil;
    _vdMode       = nil;
    _vdDescriptor = nil;
#endif
    _did = 0;
    _created = NO;
    rdp_verbose("display released");
}

- (void)setResolutionWidth:(uint32_t)width height:(uint32_t)height {
    _w = width;
    _h = height;
    rdp_verbose("resolution set to %ux%u (takes effect on next session)", width, height);
}

#if MACOS_RDP_VIRTUAL_DISPLAY
/* The largest desktop a session may resize to, in pixels. CGVirtualDisplay
 * fixes this at creation, so it is generous; it costs nothing until used. */
static const uint32_t kMaxPixelsWide = 7680;
static const uint32_t kMaxPixelsHigh = 4320;

/* A CGVirtualDisplayMode of w x h (POINTS when the settings are hiDPI). */
static id make_mode(uint32_t w, uint32_t h) {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    SEL modeSel = @selector(initWithWidth:height:refreshRate:);
    if (![modeClass instancesRespondToSelector:modeSel]) return nil;
    id m = [modeClass alloc];
    NSMethodSignature *sig = [m methodSignatureForSelector:modeSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = m; inv.selector = modeSel;
    unsigned int mw = w, mh = h; double rr = 60.0;
    [inv setArgument:&mw atIndex:2];
    [inv setArgument:&mh atIndex:3];
    [inv setArgument:&rr atIndex:4];
    [inv invoke];
    return m;
}

/* Applies one mode to the virtual display and switches to it. For HiDPI the
 * mode is given in points and macOS offers it backed by twice the pixels; that
 * backed variant has to be selected explicitly, as the display may come up in
 * the 1x one. */
- (BOOL)applyModeWidth:(uint32_t)w height:(uint32_t)h hiDPI:(BOOL)hiDPI {
    uint32_t pw = hiDPI ? w / 2 : w, ph = hiDPI ? h / 2 : h;
    id mode = make_mode(pw, ph);
    if (!mode) { rdp_error("CGVirtualDisplayMode init failed"); return NO; }
    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    [settings setValue:@[mode] forKey:@"modes"];
    @try { [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"]; } @catch (id e) {}

    BOOL applied = NO;
    SEL applySel = @selector(applySettings:);
    if ([_vdObject respondsToSelector:applySel]) {
        NSMethodSignature *sig2 = [_vdObject methodSignatureForSelector:applySel];
        NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
        inv2.target = _vdObject; inv2.selector = applySel;
        [inv2 setArgument:&settings atIndex:2];
        [inv2 retainArguments];
        [inv2 invoke];
        [inv2 getReturnValue:&applied];
    }
    _vdMode = mode;
    _vdSettings = settings;
    if (!applied) { rdp_error("applySettings %ux%u%s failed", w, h, hiDPI ? " HiDPI" : ""); return NO; }
    if (!_did) {
        @try { _did = (CGDirectDisplayID)[[_vdObject valueForKey:@"displayID"] unsignedIntValue]; }
        @catch (id e) {}
        if (!_did) { rdp_error("virtual display has no displayID after applySettings"); return NO; }
        usleep(400000);   /* let the new display register before asking for its modes */
    }

    /* Select the exact mode: pw x ph points at w x h pixels. */
    BOOL selected = NO;
    for (int attempt = 0; attempt < 10 && !selected; attempt++) {
        NSDictionary *opts = @{ (__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES };
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(_did, (__bridge CFDictionaryRef)opts));
        for (id x in modes) {
            CGDisplayModeRef dm = (__bridge CGDisplayModeRef)x;
            if (CGDisplayModeGetWidth(dm) == pw && CGDisplayModeGetHeight(dm) == ph &&
                CGDisplayModeGetPixelWidth(dm) == w && CGDisplayModeGetPixelHeight(dm) == h) {
                CGDisplayConfigRef cfg = NULL;
                if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
                    CGConfigureDisplayWithDisplayMode(cfg, _did, dm, NULL);
                    selected = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) == kCGErrorSuccess;
                }
                break;
            }
        }
        if (!selected) usleep(100000);   /* the mode list appears asynchronously */
    }
    _w = w; _h = h; _hidpi = hiDPI;
    rdp_info("virtual display %u: %ux%u pixels as %ux%u points%s",
             _did, w, h, pw, ph, selected ? "" : " (mode not selectable - left as macOS chose)");
    return YES;
}

- (BOOL)reconfigureWidth:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI {
    if (!_created || !_vdObject) return NO;
    if (width > kMaxPixelsWide || height > kMaxPixelsHigh) {
        rdp_error("resize to %ux%u exceeds the virtual display's %ux%u maximum", width, height,
                  kMaxPixelsWide, kMaxPixelsHigh);
        return NO;
    }
    if (width == _w && height == _h && hiDPI == _hidpi) return YES;
    return [self applyModeWidth:width height:height hiDPI:hiDPI];
}

- (void)createVirtualDisplay {
    /*
     * Create a CGVirtualDisplay sized exactly to the RDP client (e.g. 3440x1440)
     * so there is no pillarbox/scaling and pointer mapping is 1:1. CGVirtualDisplay
     * is a PRIVATE CoreGraphics API (CGVirtualDisplayDescriptor / *Mode / *Settings),
     * driven here entirely via NSClassFromString + KVC + NSInvocation so a missing
     * class / wrong ABI / thrown exception cleanly falls back to the main display
     * (pillarboxed) instead of crashing the daemon.
     */
    _did = CGMainDisplayID();   /* safe default */
    @try {
        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class dispClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class setClass  = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!descClass || !dispClass || !modeClass || !setClass) {
            rdp_error("CGVirtualDisplay classes unavailable on this macOS — "
                      "using main display (pillarboxed)");
            return;
        }

        id desc = [[descClass alloc] init];
        [desc setValue:@"RDP Virtual Display" forKey:@"name"];
        [desc setValue:@(MAX(_w, kMaxPixelsWide)) forKey:@"maxPixelsWide"];
        [desc setValue:@(MAX(_h, kMaxPixelsHigh)) forKey:@"maxPixelsHigh"];
        /* The panel's physical size decides what macOS treats as its native
         * density: ~220 ppi reads as a Retina panel, ~100 as a standard one. */
        double dpi = _hidpi ? 220.0 : 100.0;
        CGSize mm = CGSizeMake((_w / dpi) * 25.4, (_h / dpi) * 25.4);
        [desc setValue:[NSValue valueWithBytes:&mm objCType:@encode(CGSize)]
                forKey:@"sizeInMillimeters"];
        @try { [desc setValue:@(0x5244500u) forKey:@"productID"]; } @catch (id e) {}
        @try { [desc setValue:@(0x5244500u) forKey:@"vendorID"];  } @catch (id e) {}
        @try { [desc setValue:@(1)          forKey:@"serialNum"]; } @catch (id e) {}
        @try { [desc setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                       forKey:@"queue"]; } @catch (id e) {}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vd = [[dispClass alloc] performSelector:@selector(initWithDescriptor:)
                                         withObject:desc];
#pragma clang diagnostic pop
        if (!vd) { rdp_error("CGVirtualDisplay init failed — main display"); return; }

        _vdObject     = vd;
        _vdDescriptor = desc;
        _did          = 0;
        BOOL applied = [self applyModeWidth:_w height:_h hiDPI:_hidpi];
        CGDirectDisplayID vdid = applied ? _did : 0;
        if (!applied) { _vdObject = nil; _vdDescriptor = nil; _did = CGMainDisplayID(); }

        if (vdid != 0) {
            /* Retain ALL of these for the display's lifetime — CGVirtualDisplay and
             * its listener thread reference the descriptor (and its queue), the mode,
             * and the settings after this function returns. Letting them dealloc here
             * was a use-after-free that crashed the daemon mid-session. */
            rdp_info("virtual display created: displayID=%u %ux%u%s",
                     _did, _w, _h, _hidpi ? " HiDPI" : "");

            /* Make the virtual display the MAIN display so the menu bar, Dock, and
             * newly-opened windows land ON it. Otherwise apps open on the built-in
             * screen, invisible to the RDP session ("windows never pop up"). Give the
             * new display a moment to register, then put it at the global origin
             * (0,0) = main, and move the former main (built-in) to its right. */
            CGDirectDisplayID oldMain = CGMainDisplayID();
            if (oldMain != _did) {
                CGDisplayConfigRef dcfg = NULL;
                if (CGBeginDisplayConfiguration(&dcfg) == kCGErrorSuccess) {
                    CGConfigureDisplayOrigin(dcfg, _did, 0, 0);
                    CGConfigureDisplayOrigin(dcfg, oldMain, (int32_t)CGDisplayBounds(_did).size.width, 0);
                    CGError ce = CGCompleteDisplayConfiguration(dcfg, kCGConfigureForSession);
                    rdp_info("virtual display %u set as main (built-in %u moved aside, rc=%d)",
                             _did, oldMain, ce);
                }
            }
        } else {
            rdp_error("virtual display has no displayID — main display");
        }
    } @catch (NSException *e) {
        rdp_error("virtual display creation threw (%s) — main display",
                  e.reason.UTF8String ?: "?");
        _did = CGMainDisplayID();
    }
}
#endif

@end
