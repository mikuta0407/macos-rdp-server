#import "input/InputInjector.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <syslog.h>
#define RDP_LOG_COMPONENT "input"
#include "logging/RDPLog.h"

/* ── Scan code → macOS virtual key code ──────────────────────────────────
 *
 * RDP sends PC/AT "set 1" scan codes (MS-RDPBCGR 2.2.8.1.1.3.1.1.1), with
 * KBDFLAGS_EXTENDED for the E0-prefixed keys. Each is mapped to the Mac key at
 * the same PHYSICAL position — i.e. the keycode a PC keyboard plugged into a
 * Mac would produce. Which character that key types is then decided by the
 * Mac's input source together with the event's keyboard type (ANSI/ISO/JIS),
 * exactly as for a real keyboard.
 *
 * Values are the kVK_* constants from HIToolbox/Events.h. kVK_ANSI_A is 0, so
 * unmapped entries can't be left zero-initialised (they used to be injected as
 * "A"): the tables are filled with kVKNone first, then from the lists below. */

#define kVKNone 0xFFFF

typedef struct { uint8_t scan; uint16_t vk; } ScanMapping;

static const ScanMapping kScanMappings[] = {
    {0x01, kVK_Escape},
    {0x02, kVK_ANSI_1}, {0x03, kVK_ANSI_2}, {0x04, kVK_ANSI_3}, {0x05, kVK_ANSI_4},
    {0x06, kVK_ANSI_5}, {0x07, kVK_ANSI_6}, {0x08, kVK_ANSI_7}, {0x09, kVK_ANSI_8},
    {0x0A, kVK_ANSI_9}, {0x0B, kVK_ANSI_0},
    {0x0C, kVK_ANSI_Minus},          /* JIS: - =  */
    {0x0D, kVK_ANSI_Equal},          /* JIS: ^ ~  */
    {0x0E, kVK_Delete},              /* Backspace */
    {0x0F, kVK_Tab},
    {0x10, kVK_ANSI_Q}, {0x11, kVK_ANSI_W}, {0x12, kVK_ANSI_E}, {0x13, kVK_ANSI_R},
    {0x14, kVK_ANSI_T}, {0x15, kVK_ANSI_Y}, {0x16, kVK_ANSI_U}, {0x17, kVK_ANSI_I},
    {0x18, kVK_ANSI_O}, {0x19, kVK_ANSI_P},
    {0x1A, kVK_ANSI_LeftBracket},    /* JIS: @ `  */
    {0x1B, kVK_ANSI_RightBracket},   /* JIS: [ {  */
    {0x1C, kVK_Return},
    {0x1D, kVK_Control},
    {0x1E, kVK_ANSI_A}, {0x1F, kVK_ANSI_S}, {0x20, kVK_ANSI_D}, {0x21, kVK_ANSI_F},
    {0x22, kVK_ANSI_G}, {0x23, kVK_ANSI_H}, {0x24, kVK_ANSI_J}, {0x25, kVK_ANSI_K},
    {0x26, kVK_ANSI_L},
    {0x27, kVK_ANSI_Semicolon},      /* JIS: ; +  */
    {0x28, kVK_ANSI_Quote},          /* JIS: : *  */
    {0x29, kVK_ANSI_Grave},          /* JIS: Hankaku/Zenkaku */
    {0x2A, kVK_Shift},
    {0x2B, kVK_ANSI_Backslash},      /* JIS: ] }  */
    {0x2C, kVK_ANSI_Z}, {0x2D, kVK_ANSI_X}, {0x2E, kVK_ANSI_C}, {0x2F, kVK_ANSI_V},
    {0x30, kVK_ANSI_B}, {0x31, kVK_ANSI_N}, {0x32, kVK_ANSI_M},
    {0x33, kVK_ANSI_Comma}, {0x34, kVK_ANSI_Period}, {0x35, kVK_ANSI_Slash},
    {0x36, kVK_RightShift},
    {0x37, kVK_ANSI_KeypadMultiply},
    {0x38, kVK_Option},
    {0x39, kVK_Space},
    {0x3A, kVK_CapsLock},            /* JIS: Eisu / Caps Lock */
    {0x3B, kVK_F1}, {0x3C, kVK_F2}, {0x3D, kVK_F3}, {0x3E, kVK_F4}, {0x3F, kVK_F5},
    {0x40, kVK_F6}, {0x41, kVK_F7}, {0x42, kVK_F8}, {0x43, kVK_F9}, {0x44, kVK_F10},
    /* Num Lock → Clear: the key at that position on Apple keypads (macOS has no
     * Num Lock; the keypad always types digits). */
    {0x45, kVK_ANSI_KeypadClear},
    /* Scroll Lock / Print Screen / Pause → F14 / F13 / F15, the keys at those
     * positions on Apple extended keyboards (and what macOS does for PC ones). */
    {0x46, kVK_F14},
    /* Non-extended 0x47..0x53 are the keypad. The cursor-block keys arrive with
     * KBDFLAGS_EXTENDED and live in the extended table. */
    {0x47, kVK_ANSI_Keypad7}, {0x48, kVK_ANSI_Keypad8}, {0x49, kVK_ANSI_Keypad9},
    {0x4A, kVK_ANSI_KeypadMinus},
    {0x4B, kVK_ANSI_Keypad4}, {0x4C, kVK_ANSI_Keypad5}, {0x4D, kVK_ANSI_Keypad6},
    {0x4E, kVK_ANSI_KeypadPlus},
    {0x4F, kVK_ANSI_Keypad1}, {0x50, kVK_ANSI_Keypad2}, {0x51, kVK_ANSI_Keypad3},
    {0x52, kVK_ANSI_Keypad0}, {0x53, kVK_ANSI_KeypadDecimal},
    {0x54, kVK_F13},                 /* SysRq (Alt+Print Screen) */
    {0x56, kVK_ISO_Section},         /* ISO 102nd key (left of Z) */
    {0x57, kVK_F11}, {0x58, kVK_F12},
    {0x59, kVK_ANSI_KeypadEquals},
    {0x64, kVK_F13}, {0x65, kVK_F14}, {0x66, kVK_F15}, {0x67, kVK_F16},
    {0x68, kVK_F17}, {0x69, kVK_F18}, {0x6A, kVK_F19}, {0x6B, kVK_F20},
    /* JIS-specific keys (FreeRDP scancode.h names in parentheses). */
    {0x70, kVK_JIS_Kana},            /* Katakana/Hiragana (HIRAGANA) */
    {0x73, kVK_JIS_Underscore},      /* Ro: \ _ (ABNT_C1 / JP OEM_102) */
    {0x79, kVK_JIS_Kana},            /* Henkan (CONVERT_JP) */
    {0x7B, kVK_JIS_Eisu},            /* Muhenkan (NONCONVERT_JP) */
    {0x7D, kVK_JIS_Yen},             /* Yen: ¥ | (BACKSLASH_JP) */
};

static const ScanMapping kExtScanMappings[] = {
    {0x1C, kVK_ANSI_KeypadEnter},
    {0x1D, kVK_RightControl},
    {0x35, kVK_ANSI_KeypadDivide},
    {0x36, kVK_RightShift},          /* some clients flag RShift as extended */
    {0x37, kVK_F13},                 /* Print Screen */
    {0x38, kVK_RightOption},         /* Right Alt / AltGr */
    {0x45, kVK_ANSI_KeypadClear},    /* Num Lock sent as extended by some clients */
    {0x46, kVK_F15},                 /* Ctrl+Break */
    {0x47, kVK_Home},
    {0x48, kVK_UpArrow},
    {0x49, kVK_PageUp},
    {0x4B, kVK_LeftArrow},
    {0x4D, kVK_RightArrow},
    {0x4F, kVK_End},
    {0x50, kVK_DownArrow},
    {0x51, kVK_PageDown},
    {0x52, kVK_Help},                /* Insert — Help sits there on Apple keyboards */
    {0x53, kVK_ForwardDelete},
    {0x5B, kVK_Command},             /* Left Windows */
    {0x5C, kVK_RightCommand},        /* Right Windows */
    {0x5D, kVK_ContextualMenu},      /* Application / Menu */
};

static uint16_t gScanToVK[256];
static uint16_t gExtScanToVK[256];

static void build_tables(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < 256; i++) gScanToVK[i] = gExtScanToVK[i] = kVKNone;
        for (size_t i = 0; i < sizeof(kScanMappings) / sizeof(kScanMappings[0]); i++)
            gScanToVK[kScanMappings[i].scan] = kScanMappings[i].vk;
        for (size_t i = 0; i < sizeof(kExtScanMappings) / sizeof(kExtScanMappings[0]); i++)
            gExtScanToVK[kExtScanMappings[i].scan] = kExtScanMappings[i].vk;
    });
}

@interface InputInjector ()
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) uint32_t srcW;   /* RDP desktop width  (pointer coord space) */
@property (nonatomic, assign) uint32_t srcH;   /* RDP desktop height */
/* Button state — needed to emit MouseDragged (not MouseMoved) while a button
 * is held, otherwise drags / text selection / window moves don't work. */
@property (nonatomic, assign) BOOL leftDown;
@property (nonatomic, assign) BOOL rightDown;
@property (nonatomic, assign) BOOL middleDown;
@end

@implementation InputInjector

- (instancetype)initWithDisplayID:(CGDirectDisplayID)did
                      sourceWidth:(uint32_t)sourceWidth
                     sourceHeight:(uint32_t)sourceHeight {
    if ((self = [super init])) {
        build_tables();
        _displayID = did;
        _srcW = sourceWidth;
        _srcH = sourceHeight;
        /* Prompt for Accessibility (required for CGEventPost) and register the
         * binary in the Privacy list. In the GUI session this pops the system
         * dialog the first time; thereafter it just reports the trust state. */
        NSDictionary *opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts))
            rdp_error("Accessibility not granted — input injection will not work "
                      "until enabled (grant the prompt or System Settings > Privacy "
                      "& Security > Accessibility)");
    }
    return self;
}

- (void)injectKeyEvent:(uint16_t)flags scanCode:(uint16_t)code16 {
    BOOL isRelease  = (flags & RDP_KBD_RELEASE) != 0;
    BOOL isExtended = (flags & RDP_KBD_EXTENDED) != 0;
    uint8_t code = (uint8_t)code16;

    uint16_t vk = isExtended ? gExtScanToVK[code] : gScanToVK[code];
    if (vk == kVKNone) {
        rdp_verbose("unmapped scan code %s%02x %s (flags=0x%04x) — ignored",
                    isExtended ? "E0 " : "", code, isRelease ? "up" : "down", flags);
        return;
    }
    rdp_debug("key scan=%s%02x %s -> vk=%u", isExtended ? "E0 " : "", code,
              isRelease ? "up" : "down", vk);

    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)vk, !isRelease);
    if (!event) return;

    /* Post to the session event stream so it reaches the frontmost app. */
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

- (void)injectMouseEvent:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y {
    /* The client sends pointer coords in the RDP desktop space (0..srcW, 0..srcH).
     * The capture preserves the Mac's aspect ratio inside that surface, so the Mac
     * image occupies a CENTERED sub-rectangle with letterbox/pillarbox bars when the
     * client and Mac aspect ratios differ. Map the pointer into that content rect
     * (not the whole surface), then to the Mac display's point bounds — otherwise the
     * bars throw off the cursor position. */
    CGRect bounds = CGDisplayBounds(_displayID);
    double macAspect  = bounds.size.width / bounds.size.height;
    double surfAspect = (_srcH > 0) ? (double)_srcW / (double)_srcH : macAspect;
    double contentW, contentH, offX, offY;
    if (macAspect < surfAspect) {            /* pillarbox: content fits the height */
        contentH = _srcH; contentW = (double)_srcH * macAspect;
        offX = ((double)_srcW - contentW) / 2.0; offY = 0;
    } else {                                  /* letterbox: content fits the width */
        contentW = _srcW; contentH = (double)_srcW / macAspect;
        offX = 0; offY = ((double)_srcH - contentH) / 2.0;
    }
    double fx = (contentW > 0) ? ((double)x - offX) / contentW : 0;  /* 0..1 in content */
    double fy = (contentH > 0) ? ((double)y - offY) / contentH : 0;
    if (fx < 0) fx = 0; else if (fx > 1) fx = 1;
    if (fy < 0) fy = 0; else if (fy > 1) fy = 1;
    CGPoint pos = CGPointMake(bounds.origin.x + fx * bounds.size.width,
                              bounds.origin.y + fy * bounds.size.height);

    BOOL down = (flags & RDP_PTR_DOWN) != 0;
    CGEventType type;
    CGMouseButton button;

    if (flags & RDP_PTR_BUTTON1) {
        button = kCGMouseButtonLeft;
        type = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
        _leftDown = down;
    } else if (flags & RDP_PTR_BUTTON2) {
        button = kCGMouseButtonRight;
        type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
        _rightDown = down;
    } else if (flags & RDP_PTR_BUTTON3) {
        button = kCGMouseButtonCenter;
        type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
        _middleDown = down;
    } else if (flags & RDP_PTR_MOVE) {
        /* A move with a button held is a drag — macOS needs the dragged event
         * type or the gesture (selection, window move) is dropped. */
        if (_leftDown)        { type = kCGEventLeftMouseDragged;  button = kCGMouseButtonLeft; }
        else if (_rightDown)  { type = kCGEventRightMouseDragged; button = kCGMouseButtonRight; }
        else if (_middleDown) { type = kCGEventOtherMouseDragged; button = kCGMouseButtonCenter; }
        else                  { type = kCGEventMouseMoved;        button = kCGMouseButtonLeft; }
    } else {
        return; /* nothing actionable */
    }

    CGEventRef event = CGEventCreateMouseEvent(NULL, type, pos, button);
    if (!event) return;
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

- (void)injectMouseWheelEvent:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y {
    (void)x; (void)y;
    BOOL horizontal = (flags & RDP_PTR_HWHEEL) != 0;

    /* Rotation magnitude is the low 8 bits; PTR_FLAGS_WHEEL_NEGATIVE flips sign.
     * Windows sends multiples of WHEEL_DELTA (120) per notch. */
    int32_t rotation = flags & 0xFF;
    if (flags & RDP_PTR_WHEEL_NEGATIVE) rotation = -rotation;

    int32_t lines = rotation / 120;
    if (lines == 0) lines = (rotation > 0) ? 1 : (rotation < 0 ? -1 : 0);
    if (lines == 0) return;

    /* macOS scroll sign is opposite RDP for vertical (natural direction). */
    CGEventRef event = CGEventCreateScrollWheelEvent(
        NULL, kCGScrollEventUnitLine,
        horizontal ? 2 : 1,
        horizontal ? 0 : lines,
        horizontal ? lines : 0
    );
    if (!event) return;
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

@end
