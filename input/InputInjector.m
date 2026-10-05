#import "input/InputInjector.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <dlfcn.h>
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
 * exactly as for a real keyboard; see -configureForClientKeyboardLayout:.
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
    {0x56, kVK_ISO_Section},         /* ISO 102nd key (left of Z); swapped for ISO */
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

/* Extended scan codes of the consumer (media) keys → NX_KEYTYPE_*. macOS does
 * not handle these as key codes; they are NSSystemDefined aux-control events. */
typedef struct { uint8_t scan; int nxKey; } MediaMapping;
static const MediaMapping kMediaMappings[] = {
    {0x20, NX_KEYTYPE_MUTE},
    {0x2E, NX_KEYTYPE_SOUND_DOWN},
    {0x30, NX_KEYTYPE_SOUND_UP},
    {0x22, NX_KEYTYPE_PLAY},
    {0x19, NX_KEYTYPE_NEXT},
    {0x10, NX_KEYTYPE_PREVIOUS},
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

static int media_key_for_ext_scan(uint8_t scan) {
    for (size_t i = 0; i < sizeof(kMediaMappings) / sizeof(kMediaMappings[0]); i++)
        if (kMediaMappings[i].scan == scan) return kMediaMappings[i].nxKey;
    return -1;
}

/* ── Modifiers ───────────────────────────────────────────────────────────
 * Injected events carry exactly the flags we set, so modifier state is tracked
 * here and stamped on every key AND mouse event (⌘-click, ⇧-select, ⌥-drag).
 * Device-dependent bits (NX_DEVICE*) let apps tell left from right. */

typedef struct { uint16_t vk; CGEventFlags flag; CGEventFlags device; } ModifierInfo;
static const ModifierInfo kModifiers[] = {
    {kVK_Shift,        kCGEventFlagMaskShift,     NX_DEVICELSHIFTKEYMASK},
    {kVK_RightShift,   kCGEventFlagMaskShift,     NX_DEVICERSHIFTKEYMASK},
    {kVK_Control,      kCGEventFlagMaskControl,   NX_DEVICELCTLKEYMASK},
    {kVK_RightControl, kCGEventFlagMaskControl,   NX_DEVICERCTLKEYMASK},
    {kVK_Option,       kCGEventFlagMaskAlternate, NX_DEVICELALTKEYMASK},
    {kVK_RightOption,  kCGEventFlagMaskAlternate, NX_DEVICERALTKEYMASK},
    {kVK_Command,      kCGEventFlagMaskCommand,   NX_DEVICELCMDKEYMASK},
    {kVK_RightCommand, kCGEventFlagMaskCommand,   NX_DEVICERCMDKEYMASK},
};

static const ModifierInfo *modifier_info(uint16_t vk) {
    for (size_t i = 0; i < sizeof(kModifiers) / sizeof(kModifiers[0]); i++)
        if (kModifiers[i].vk == vk) return &kModifiers[i];
    return NULL;
}

/* Extra flags a real Apple keyboard sets on these keys. Some apps (Terminal,
 * editors with keypad bindings) look at NumericPad / SecondaryFn. */
static CGEventFlags extra_flags_for_vk(uint16_t vk) {
    switch (vk) {
    case kVK_UpArrow: case kVK_DownArrow: case kVK_LeftArrow: case kVK_RightArrow:
        return kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
    case kVK_Home: case kVK_End: case kVK_PageUp: case kVK_PageDown:
    case kVK_ForwardDelete: case kVK_Help:
    case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5: case kVK_F6:
    case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10: case kVK_F11: case kVK_F12:
    case kVK_F13: case kVK_F14: case kVK_F15: case kVK_F16: case kVK_F17:
    case kVK_F18: case kVK_F19: case kVK_F20:
        return kCGEventFlagMaskSecondaryFn;
    case kVK_ANSI_Keypad0: case kVK_ANSI_Keypad1: case kVK_ANSI_Keypad2:
    case kVK_ANSI_Keypad3: case kVK_ANSI_Keypad4: case kVK_ANSI_Keypad5:
    case kVK_ANSI_Keypad6: case kVK_ANSI_Keypad7: case kVK_ANSI_Keypad8:
    case kVK_ANSI_Keypad9: case kVK_ANSI_KeypadDecimal: case kVK_ANSI_KeypadMultiply:
    case kVK_ANSI_KeypadPlus: case kVK_ANSI_KeypadClear: case kVK_ANSI_KeypadDivide:
    case kVK_ANSI_KeypadEnter: case kVK_ANSI_KeypadMinus: case kVK_ANSI_KeypadEquals:
        return kCGEventFlagMaskNumericPad;
    default:
        return 0;
    }
}

/* ── Keyboard type selection ─────────────────────────────────────────────── */

static uint32_t keyboard_type_for_client(uint32_t layout, uint32_t type) {
    uint16_t lang = (uint16_t)(layout & 0xFFFF);
    if (type == 7 || lang == 0x0411) return RDP_MAC_KBTYPE_JIS;        /* Japanese */
    if (layout == 0) return 0;                                           /* unknown */
    switch (lang) {
    case 0x0409:                         /* English (US), incl. Dvorak variants */
    case 0x0412:                         /* Korean */
    case 0x0404: case 0x0804:            /* Chinese (Traditional / Simplified) */
    case 0x0C04: case 0x1004: case 0x1404:
        return RDP_MAC_KBTYPE_ANSI;
    default:
        return RDP_MAC_KBTYPE_ISO;       /* European layouts have the 102nd key */
    }
}

/* Physical layout family of a Mac keyboard type. HIToolbox exports
 * KBGetLayoutType() (the call the system itself uses to pick the uchr table)
 * but the SDK no longer declares it, so resolve it at runtime and fall back to
 * the three canonical types if it is ever missing. */
typedef enum { KB_FAMILY_ANSI, KB_FAMILY_ISO, KB_FAMILY_JIS } KeyboardFamily;

static KeyboardFamily keyboard_family(uint32_t kbType) {
    typedef OSType (*KBGetLayoutTypeFn)(SInt16);
    static KBGetLayoutTypeFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (KBGetLayoutTypeFn)dlsym(RTLD_DEFAULT, "KBGetLayoutType"); });
    if (fn) {
        OSType t = fn((SInt16)kbType);
        if (t == 'JIS ') return KB_FAMILY_JIS;
        if (t == 'ISO ') return KB_FAMILY_ISO;
        return KB_FAMILY_ANSI;
    }
    if (kbType == RDP_MAC_KBTYPE_JIS) return KB_FAMILY_JIS;
    if (kbType == RDP_MAC_KBTYPE_ISO) return KB_FAMILY_ISO;
    return KB_FAMILY_ANSI;
}

static const char *keyboard_type_name(uint32_t t) {
    if (t == 0) return "system default";
    switch (keyboard_family(t)) {
    case KB_FAMILY_JIS: return "JIS";
    case KB_FAMILY_ISO: return "ISO";
    default:            return "ANSI";
    }
}

static BOOL env_flag(const char *name, BOOL dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    return strcmp(v, "0") != 0 && strcasecmp(v, "false") != 0 && strcasecmp(v, "no") != 0;
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

@implementation InputInjector {
    CGEventSourceRef _source;
    uint32_t _keyboardType;        /* 0 = leave the system default */
    BOOL _isoSwap;                 /* swap Grave/Section like macOS does for ISO */
    BOOL _swapCtrlCmd;
    BOOL _capsLock;
    BOOL _pausePending;            /* swallow the 0x45 that follows E1 1D */
    BOOL _keyDown[128];            /* Mac keycodes currently held */
    uint16_t _pendingHighSurrogate;
}

- (instancetype)initWithDisplayID:(CGDirectDisplayID)did
                      sourceWidth:(uint32_t)sourceWidth
                     sourceHeight:(uint32_t)sourceHeight {
    if ((self = [super init])) {
        build_tables();
        _displayID = did;
        _srcW = sourceWidth;
        _srcH = sourceHeight;
        /* Private state: our events carry only the flags we set, independent of
         * whatever the local HID keyboard (if any) is doing. */
        _source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        _swapCtrlCmd = env_flag("RDP_SWAP_CTRL_CMD", NO);
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

- (void)dealloc {
    [self releaseAllKeys];
    if (_source) CFRelease(_source);
}

- (void)configureForClientKeyboardLayout:(uint32_t)layout
                                    type:(uint32_t)type
                                 subType:(uint32_t)subType {
    uint32_t kbType = keyboard_type_for_client(layout, type);
    const char *env = getenv("RDP_KEYBOARD_TYPE");
    const char *how = "detected";
    if (env && *env && strcasecmp(env, "auto") != 0) {
        how = "RDP_KEYBOARD_TYPE";
        if      (strcasecmp(env, "jis")  == 0) kbType = RDP_MAC_KBTYPE_JIS;
        else if (strcasecmp(env, "ansi") == 0) kbType = RDP_MAC_KBTYPE_ANSI;
        else if (strcasecmp(env, "iso")  == 0) kbType = RDP_MAC_KBTYPE_ISO;
        else if (atoi(env) > 0)                kbType = (uint32_t)atoi(env);
        else { rdp_error("RDP_KEYBOARD_TYPE='%s' not understood — using detection", env);
               how = "detected"; }
    }
    _keyboardType = kbType;
    if (kbType && _source) CGEventSourceSetKeyboardType(_source, kbType);

    KeyboardFamily family = kbType ? keyboard_family(kbType) : KB_FAMILY_ANSI;
    _isoSwap = kbType && family == KB_FAMILY_ISO;

    rdp_info("client keyboard: layout=0x%08x type=%u subtype=%u → Mac keyboard type %u "
             "(%s, %s)%s", layout, type, subType, kbType, keyboard_type_name(kbType), how,
             _swapCtrlCmd ? ", Ctrl<->Cmd swapped" : "");
}

/* Current modifier flags, derived from the keys we hold. */
- (CGEventFlags)modifierFlags {
    CGEventFlags flags = 0;
    for (size_t i = 0; i < sizeof(kModifiers) / sizeof(kModifiers[0]); i++)
        if (_keyDown[kModifiers[i].vk]) flags |= kModifiers[i].flag | kModifiers[i].device;
    if (_capsLock) flags |= kCGEventFlagMaskAlphaShift;
    return flags;
}

- (void)postKey:(uint16_t)vk down:(BOOL)down {
    const ModifierInfo *mod = modifier_info(vk);
    BOOL wasDown = _keyDown[vk];

    if (vk == kVK_CapsLock) {
        /* Caps Lock is a toggle: flip on press, ignore release and auto-repeat. */
        if (!down || wasDown) { _keyDown[vk] = down; return; }
        _keyDown[vk] = YES;
        _capsLock = !_capsLock;
    } else if (mod) {
        if (down == wasDown) return;     /* clients auto-repeat held modifiers */
        _keyDown[vk] = down;
    } else {
        _keyDown[vk] = down;
    }

    CGEventRef ev = CGEventCreateKeyboardEvent(_source, (CGKeyCode)vk, down);
    if (!ev) return;
    CGEventFlags flags = [self modifierFlags] | kCGEventFlagMaskNonCoalesced;
    if (mod || vk == kVK_CapsLock) {
        CGEventSetType(ev, kCGEventFlagsChanged);
    } else {
        flags |= extra_flags_for_vk(vk);
        if (down && wasDown) CGEventSetIntegerValueField(ev, kCGKeyboardEventAutorepeat, 1);
    }
    CGEventSetFlags(ev, flags);
    /* Post to the session event stream so it reaches the frontmost app. */
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

- (void)postMediaKey:(int)nxKey down:(BOOL)down {
    /* NX_SYSDEFINED aux-control-button event, as the media keys of an Apple
     * keyboard generate (data1 = key << 16 | (keyDown ? 0xA : 0xB) << 8). */
    NSInteger state = down ? 0xA : 0xB;
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                    location:NSZeroPoint
                               modifierFlags:(NSEventModifierFlags)(state << 8)
                                   timestamp:0
                                windowNumber:0
                                     context:nil
                                     subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                       data1:((NSInteger)nxKey << 16) | (state << 8)
                                       data2:-1];
    CGEventRef ev = e.CGEvent;
    if (ev) CGEventPost(kCGHIDEventTap, ev);
}

- (void)injectKeyEvent:(uint16_t)flags scanCode:(uint16_t)code16 {
    BOOL isRelease  = (flags & RDP_KBD_RELEASE) != 0;
    BOOL isExtended = (flags & RDP_KBD_EXTENDED) != 0;
    uint8_t code = (uint8_t)code16;

    /* Pause/Break arrives as E1 1D 45: KBDFLAGS_EXTENDED1 + 0x1D, then a plain
     * 0x45 that must not be mistaken for Num Lock. */
    if (flags & RDP_KBD_EXTENDED1) {
        if (code == 0x1D) {
            _pausePending = YES;
            rdp_debug("key scan=E1 1D (Pause) %s -> vk=%u", isRelease ? "up" : "down", kVK_F15);
            [self postKey:kVK_F15 down:!isRelease];
        } else {
            rdp_verbose("unmapped scan code E1 %02x (flags=0x%04x) — ignored", code, flags);
        }
        return;
    }
    if (_pausePending && !isExtended && code == 0x45) {
        _pausePending = NO;
        return;
    }
    _pausePending = NO;

    if (isExtended) {
        int nx = media_key_for_ext_scan(code);
        if (nx >= 0) {
            rdp_debug("key scan=E0 %02x %s -> media key %d", code, isRelease ? "up" : "down", nx);
            [self postMediaKey:nx down:!isRelease];
            return;
        }
    }

    uint16_t vk = isExtended ? gExtScanToVK[code] : gScanToVK[code];
    if (vk == kVKNone) {
        rdp_verbose("unmapped scan code %s%02x %s (flags=0x%04x) — ignored",
                    isExtended ? "E0 " : "", code, isRelease ? "up" : "down", flags);
        return;
    }
    if (_isoSwap) {
        /* On ISO keyboards macOS reports the top-left key as Section and the
         * 102nd key as Grave; mirror that so the ISO layouts type correctly. */
        if (vk == kVK_ANSI_Grave)       vk = kVK_ISO_Section;
        else if (vk == kVK_ISO_Section) vk = kVK_ANSI_Grave;
    }
    if (_swapCtrlCmd) {
        if      (vk == kVK_Control)      vk = kVK_Command;
        else if (vk == kVK_Command)      vk = kVK_Control;
        else if (vk == kVK_RightControl) vk = kVK_RightCommand;
        else if (vk == kVK_RightCommand) vk = kVK_RightControl;
    }
    rdp_debug("key scan=%s%02x %s -> vk=%u", isExtended ? "E0 " : "", code,
              isRelease ? "up" : "down", vk);
    [self postKey:vk down:!isRelease];
}

- (void)injectUnicodeEvent:(uint16_t)flags codeUnit:(uint16_t)unit {
    if (flags & RDP_KBD_RELEASE) return;   /* the press already typed it */

    UniChar chars[2];
    UniCharCount n = 0;
    if (CFStringIsSurrogateHighCharacter(unit)) { _pendingHighSurrogate = unit; return; }
    if (CFStringIsSurrogateLowCharacter(unit)) {
        if (!_pendingHighSurrogate) return;
        chars[n++] = _pendingHighSurrogate;
    }
    _pendingHighSurrogate = 0;
    chars[n++] = unit;
    rdp_debug("unicode U+%04X%s", unit, n == 2 ? " (surrogate pair)" : "");

    for (int down = 1; down >= 0; down--) {
        CGEventRef ev = CGEventCreateKeyboardEvent(_source, 0, (bool)down);
        if (!ev) return;
        CGEventKeyboardSetUnicodeString(ev, n, chars);
        CGEventSetFlags(ev, kCGEventFlagMaskNonCoalesced);
        CGEventPost(kCGSessionEventTap, ev);
        CFRelease(ev);
    }
}

- (void)synchronizeWithFlags:(uint32_t)toggleFlags {
    [self releaseAllKeys];
    BOOL caps = (toggleFlags & RDP_SYNC_CAPS_LOCK) != 0;
    rdp_debug("keyboard sync: flags=0x%02x (caps=%d)", toggleFlags, caps);
    if (caps != _capsLock) {
        _capsLock = caps;
        CGEventRef ev = CGEventCreateKeyboardEvent(_source, kVK_CapsLock, true);
        if (ev) {
            CGEventSetType(ev, kCGEventFlagsChanged);
            CGEventSetFlags(ev, [self modifierFlags] | kCGEventFlagMaskNonCoalesced);
            CGEventPost(kCGSessionEventTap, ev);
            CFRelease(ev);
        }
    }
}

- (void)releaseAllKeys {
    for (uint16_t vk = 0; vk < 128; vk++) {
        if (!_keyDown[vk]) continue;
        if (vk == kVK_CapsLock) { _keyDown[vk] = NO; continue; }
        rdp_debug("releasing held key vk=%u", vk);
        [self postKey:vk down:NO];
    }
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
    CGEventSetFlags(event, [self modifierFlags]);
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
    CGEventSetFlags(event, [self modifierFlags]);   /* ⌃-scroll zoom, ⇧-scroll etc. */
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

@end
