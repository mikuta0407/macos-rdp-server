#import "GestureSynth.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

/* CGEvent fields WindowServer uses for gestures (CGSEventField). */
enum {
    kFieldType = 55,            /* the CGS event type, as CGEventGetType */
    kFieldGestureFlavor = 41,
    kFieldHIDType = 110,        /* IOHIDEventType of the gesture */
    kFieldZoom = 113,
    kFieldRotation = 114,
    kFieldSwipeDirection = 115,
    kFieldScrollGestureX = 116,
    kFieldScrollGestureY = 119,
    kFieldDockMotionBits = 119,
    kFieldDockMotion = 123,     /* gs_dock_axis */
    kFieldDockProgress = 124,
    kFieldDockVelocityX = 129,
    kFieldDockVelocityY = 130,
    kFieldPhase = 132,
    kFieldDockPhase = 134,
    kFieldDockProgressBits = 135,
    kFieldDockInverted = 136,
    kFieldDockMotionBits2 = 139,
    kFieldDockMotion2 = 165,
};

/* IOHIDEventType */
enum {
    kHIDRotation = 5,
    kHIDScroll = 6,
    kHIDZoom = 8,
    kHIDNavigationSwipe = 16,
    kHIDZoomToggle = 22,
    kHIDDockSwipe = 23,
};

enum { kTypeGesture = 29, kTypeDockControl = 30 };

static CGEventRef gs_gesture(int64_t hidType) {
    CGEventRef ev = CGEventCreate(NULL);   /* at the pointer */
    if (!ev) return NULL;
    CGEventSetIntegerValueField(ev, kFieldType, kTypeGesture);
    CGEventSetIntegerValueField(ev, kFieldHIDType, hidType);
    return ev;
}

static void gs_post(CGEventRef ev) {
    if (!ev) return;
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

void gs_post_magnify(double magnification, uint32_t phase) {
    CGEventRef ev = gs_gesture(kHIDZoom);
    if (!ev) return;
    CGEventSetIntegerValueField(ev, kFieldPhase, phase);
    CGEventSetDoubleValueField(ev, kFieldZoom, magnification);
    gs_post(ev);
}

void gs_post_rotate(double degrees, uint32_t phase) {
    CGEventRef ev = gs_gesture(kHIDRotation);
    if (!ev) return;
    CGEventSetIntegerValueField(ev, kFieldPhase, phase);
    CGEventSetDoubleValueField(ev, kFieldRotation, degrees);
    gs_post(ev);
}

void gs_post_scroll_gesture(double dx, double dy, uint32_t phase) {
    CGEventRef ev = gs_gesture(kHIDScroll);
    if (!ev) return;
    /* A real trackpad's zero deltas here are negative zeros. */
    CGEventSetDoubleValueField(ev, kFieldScrollGestureX, dx != 0 ? dx : -0.0);
    CGEventSetDoubleValueField(ev, kFieldScrollGestureY, dy != 0 ? dy : -0.0);
    CGEventSetIntegerValueField(ev, kFieldPhase, phase);
    gs_post(ev);
}

void gs_post_smart_zoom(void) {
    gs_post(gs_gesture(kHIDZoomToggle));
}

void gs_post_navigation_swipe(gs_swipe_direction direction) {
    const uint32_t phases[] = { GS_PHASE_BEGAN, GS_PHASE_ENDED };
    for (size_t i = 0; i < 2; i++) {
        CGEventRef ev = gs_gesture(kHIDNavigationSwipe);
        if (!ev) return;
        CGEventSetIntegerValueField(ev, kFieldPhase, phases[i]);
        CGEventSetIntegerValueField(ev, kFieldSwipeDirection, direction);
        gs_post(ev);
    }
}

/* A 32-bit integer carried as the bits of a float in a double field: how
 * WindowServer stores the dock swipe's motion in fields 119 and 139. */
static double gs_int_as_float_bits(uint32_t v) {
    float f;
    memcpy(&f, &v, sizeof f);
    return f;
}

/* ---- The IOHIDEvent a real trackpad's swipe carries ------------------------
 * macOS 27 reads a dock swipe from the IOHIDEvent inside the CGEvent rather
 * than from its fields. IOKit and SkyLight export what it takes to build one
 * and attach it; they are looked up at run time, so a release without them
 * only loses this path. */

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef IOHIDEventRef (*gs_hid_create_fn)(CFAllocatorRef, uint32_t type, uint64_t timestamp, uint32_t options);
typedef void (*gs_hid_set_int_fn)(IOHIDEventRef, uint32_t field, CFIndex value);
typedef void (*gs_hid_set_float_fn)(IOHIDEventRef, uint32_t field, double value);
typedef void (*gs_hid_append_fn)(IOHIDEventRef, IOHIDEventRef child, uint32_t options);
typedef void (*gs_cg_set_hid_fn)(CGEventRef, IOHIDEventRef);
typedef IOHIDEventRef (*gs_cg_copy_hid_fn)(CGEventRef);

static struct {
    gs_hid_create_fn create;
    gs_hid_set_int_fn setInt;
    gs_hid_set_float_fn setFloat;
    gs_hid_append_fn append;
    gs_cg_set_hid_fn attach;
    gs_cg_copy_hid_fn copy;
} gHID;

static BOOL gs_hid_available(void) {
    static dispatch_once_t once;
    static BOOL available;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        gHID.create = (gs_hid_create_fn)dlsym(RTLD_DEFAULT, "IOHIDEventCreate");
        gHID.setInt = (gs_hid_set_int_fn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        gHID.setFloat = (gs_hid_set_float_fn)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        gHID.append = (gs_hid_append_fn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        gHID.attach = (gs_cg_set_hid_fn)dlsym(RTLD_DEFAULT, "SLEventSetIOHIDEvent");
        gHID.copy = (gs_cg_copy_hid_fn)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
        available = gHID.create && gHID.setInt && gHID.setFloat && gHID.append && gHID.attach;
    });
    return available;
}

enum {
    kHIDTypeVelocity = 9,
    kHIDPhaseShift = 24,
    kHIDFlavorDockPrimary = 3,
};
#define GS_HID_FIELD(type, index) ((uint32_t)(type) << 16 | (index))

/* Attaches the dock swipe as an IOHIDEvent; NO if this macOS cannot. */
static BOOL gs_attach_dock_hid(CGEventRef ev, gs_dock_axis axis, double progress,
                               uint32_t phase, double velocity) {
    if (!gs_hid_available()) return NO;
    IOHIDEventRef hid = gHID.create(kCFAllocatorDefault, kHIDDockSwipe, 0, phase << kHIDPhaseShift);
    if (!hid) return NO;
    gHID.setInt(hid, GS_HID_FIELD(kHIDDockSwipe, 1), axis);                    /* motion */
    gHID.setInt(hid, GS_HID_FIELD(kHIDDockSwipe, 5), kHIDFlavorDockPrimary);   /* flavor */
    gHID.setFloat(hid, GS_HID_FIELD(kHIDDockSwipe, 2), progress);              /* progress */
    if (phase & (GS_PHASE_ENDED | GS_PHASE_CANCELLED)) {
        IOHIDEventRef v = gHID.create(kCFAllocatorDefault, kHIDTypeVelocity, 0, 0);
        if (v) {
            gHID.setFloat(v, GS_HID_FIELD(kHIDTypeVelocity, 0), velocity);
            gHID.setFloat(v, GS_HID_FIELD(kHIDTypeVelocity, 1), velocity);
            gHID.append(hid, v, 0);
            CFRelease(v);
        }
    }
    gHID.attach(ev, hid);
    BOOL attached = YES;
    if (gHID.copy) {
        IOHIDEventRef back = gHID.copy(ev);
        attached = back != NULL;
        if (back) CFRelease(back);
    }
    CFRelease(hid);
    return attached;
}

/* Which form the Dock reads: the fields up to macOS 26, the IOHIDEvent from
 * macOS 27. RDP_DOCK_SWIPE=fields|hid overrides, for a release that moves. */
static BOOL gs_dock_uses_hid(void) {
    const char *env = getenv("RDP_DOCK_SWIPE");
    if (env && !strcmp(env, "fields")) return NO;
    if (env && !strcmp(env, "hid")) return YES;
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:
               (NSOperatingSystemVersion){ 27, 0, 0 }];
}

void gs_post_dock_swipe(gs_dock_axis axis, double progress, uint32_t phase, double velocity) {
    /* An exit speed of the Dock's own scale: about a hundred times the
     * progress of the last event of a swipe, events ~16 ms apart. */
    double exitSpeed = velocity * 1.6;
    if (gs_dock_uses_hid()) {
        CGEventRef ev = CGEventCreate(NULL);
        if (!ev) return;
        CGEventSetType(ev, kTypeDockControl);
        if (gs_attach_dock_hid(ev, axis, progress, phase, exitSpeed)) {
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
            return;
        }
        CFRelease(ev);
        /* No IOHIDEvent on this release: the fields are all there is. */
    }
    CGEventRef dock = CGEventCreate(NULL);
    CGEventRef gesture = CGEventCreate(NULL);
    if (!dock || !gesture) {
        if (dock) CFRelease(dock);
        if (gesture) CFRelease(gesture);
        return;
    }
    CGEventSetDoubleValueField(dock, kFieldType, kTypeDockControl);
    CGEventSetDoubleValueField(dock, kFieldHIDType, kHIDDockSwipe);
    CGEventSetDoubleValueField(dock, kFieldPhase, phase);
    CGEventSetDoubleValueField(dock, kFieldDockPhase, phase);
    CGEventSetDoubleValueField(dock, kFieldDockProgress, progress);
    /* The same value again, as the bits of a 32-bit float. */
    float f = (float)progress;
    uint32_t bits;
    memcpy(&bits, &f, sizeof bits);
    CGEventSetIntegerValueField(dock, kFieldDockProgressBits, (int64_t)bits);
    CGEventSetDoubleValueField(dock, kFieldGestureFlavor, 33231);
    CGEventSetDoubleValueField(dock, kFieldDockMotionBits, gs_int_as_float_bits(axis));
    CGEventSetDoubleValueField(dock, kFieldDockMotionBits2, gs_int_as_float_bits(axis));
    CGEventSetDoubleValueField(dock, kFieldDockMotion, axis);
    CGEventSetDoubleValueField(dock, kFieldDockMotion2, axis);
    CGEventSetIntegerValueField(dock, kFieldDockInverted, 0);
    if (phase & (GS_PHASE_ENDED | GS_PHASE_CANCELLED)) {
        CGEventSetDoubleValueField(dock, kFieldDockVelocityX, exitSpeed);
        CGEventSetDoubleValueField(dock, kFieldDockVelocityY, exitSpeed);
    }
    /* The Dock reads the swipe from the type-30 event; the gesture event
     * after it is what a real trackpad sends alongside. */
    CGEventSetDoubleValueField(gesture, kFieldType, kTypeGesture);
    CGEventSetDoubleValueField(gesture, kFieldGestureFlavor, 33231);
    CGEventPost(kCGSessionEventTap, dock);
    CGEventPost(kCGSessionEventTap, gesture);
    CFRelease(dock);
    CFRelease(gesture);
}

/* ---- Probe ---------------------------------------------------------------- */

static void gs_sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }

/* A whole dock swipe to `total`, in `steps` changes 16 ms (GS_STEP_MS) apart. */
static void gs_probe_dock(gs_dock_axis axis, double total, int steps, double velocity) {
    int stepMs = getenv("GS_STEP_MS") ? atoi(getenv("GS_STEP_MS")) : 16;
    gs_post_dock_swipe(axis, total / steps, GS_PHASE_BEGAN, 0);
    for (int i = 2; i <= steps; i++) {
        gs_sleep_ms(stepMs);
        gs_post_dock_swipe(axis, total * i / steps, GS_PHASE_CHANGED, 0);
    }
    gs_sleep_ms(16);
    gs_post_dock_swipe(axis, total, GS_PHASE_ENDED, velocity);
}

static CGEventRef gs_listen_cb(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ud) {
    (void)proxy; (void)ud;
    if (type == 29 || type == 30) {
        printf("ts=%llu type=%d f55=%lld f110=%lld f123=%g f124=%g f132=%lld f134=%lld f41=%g f119=%g\n", (unsigned long long)CGEventGetTimestamp(ev), type,
               CGEventGetIntegerValueField(ev, 55), CGEventGetIntegerValueField(ev, 110),
               CGEventGetDoubleValueField(ev, 123), CGEventGetDoubleValueField(ev, 124),
               CGEventGetIntegerValueField(ev, 132), CGEventGetIntegerValueField(ev, 134),
               CGEventGetDoubleValueField(ev, 41), CGEventGetDoubleValueField(ev, 119));
        fflush(stdout);
    }
    return ev;
}

/* listen <seconds>: prints the gesture events passing the session. */
static int gs_listen(double seconds) {
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionListenOnly,
                                         (1ull << 29) | (1ull << 30), gs_listen_cb, NULL);
    if (!tap) { printf("no tap\n"); return 1; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    printf("listening\n"); fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    return 0;
}

int gs_probe_main(int argc, char **argv) {
    if (argc > 0 && !strcmp(argv[0], "listen")) return gs_listen(argc > 1 ? atof(argv[1]) : 10);
    if (argc < 1) {
        fprintf(stderr, "gesture-probe: dock-h|dock-v <progress> [steps] [velocity] | "
                        "magnify <total> | rotate <degrees> | smart-zoom | nav <left|right>\n");
        return 2;
    }
    const char *what = argv[0];
    double value = argc > 1 ? atof(argv[1]) : 0;
    int steps = argc > 2 ? atoi(argv[2]) : 20;
    double velocity = argc > 3 ? atof(argv[3]) : 0;
    if (!strcmp(what, "dock-h") || !strcmp(what, "dock-v")) {
        gs_probe_dock(what[5] == 'h' ? GS_DOCK_HORIZONTAL : GS_DOCK_VERTICAL, value, steps, velocity);
    } else if (!strcmp(what, "magnify") || !strcmp(what, "rotate")) {
        BOOL zoom = what[0] == 'm';
        void (*post)(double, uint32_t) = zoom ? gs_post_magnify : gs_post_rotate;
        post(0, GS_PHASE_BEGAN);
        for (int i = 0; i < steps; i++) {
            gs_sleep_ms(16);
            post(value / steps, GS_PHASE_CHANGED);
        }
        gs_sleep_ms(16);
        post(0, GS_PHASE_ENDED);
    } else if (!strcmp(what, "click") && argc > 2) {
        /* For dismissing dialogs while probing: this binary has Accessibility. */
        CGPoint at = CGPointMake(atof(argv[1]), atof(argv[2]));
        CGEventType types[] = { kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp };
        for (int i = 0; i < 3; i++) {
            CGEventRef ev = CGEventCreateMouseEvent(NULL, types[i], at, kCGMouseButtonLeft);
            gs_post(ev);
            gs_sleep_ms(60);
        }
    } else if (!strcmp(what, "key") && argc > 1) {
        /* key <kVK> [flags]: one key press with the given CGEventFlags. */
        CGKeyCode vk = (CGKeyCode)atoi(argv[1]);
        CGEventFlags flags = argc > 2 ? (CGEventFlags)strtoull(argv[2], NULL, 0) : 0;
        for (int down = 1; down >= 0; down--) {
            CGEventRef ev = CGEventCreateKeyboardEvent(NULL, vk, down);
            if (ev) CGEventSetFlags(ev, flags);
            gs_post(ev);
            gs_sleep_ms(30);
        }
    } else if (!strcmp(what, "smart-zoom")) {
        gs_post_smart_zoom();
    } else if (!strcmp(what, "nav")) {
        gs_post_navigation_swipe(argc > 1 && !strcmp(argv[1], "right") ? GS_SWIPE_RIGHT : GS_SWIPE_LEFT);
    } else {
        fprintf(stderr, "gesture-probe: unknown gesture %s\n", what);
        return 2;
    }
    gs_sleep_ms(50);
    printf("posted %s\n", what);
    return 0;
}
