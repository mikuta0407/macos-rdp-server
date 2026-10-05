#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/* RDP keyboard flags (MS-RDPBCGR 2.2.8.1.1.3.1.1.1) */
#define RDP_KBD_RELEASE   0x8000   /* KBDFLAGS_RELEASE */
#define RDP_KBD_EXTENDED  0x0100   /* KBDFLAGS_EXTENDED */
#define RDP_KBD_EXTENDED1 0x0200   /* KBDFLAGS_EXTENDED1 (Pause: E1 1D 45) */

/* RDP synchronize-event toggle flags (MS-RDPBCGR 2.2.8.1.1.3.1.1.5) */
#define RDP_SYNC_SCROLL_LOCK 0x01
#define RDP_SYNC_NUM_LOCK    0x02
#define RDP_SYNC_CAPS_LOCK   0x04
#define RDP_SYNC_KANA_LOCK   0x08

/* RDP pointer flags (MS-RDPBCGR 2.2.8.1.1.3.1.1.3). Button press vs release is
 * the DOWN bit — NOT separate values; identity is the BUTTONn bit. */
#define RDP_PTR_MOVE              0x0800
#define RDP_PTR_DOWN              0x8000
#define RDP_PTR_BUTTON1           0x1000   /* left   */
#define RDP_PTR_BUTTON2           0x2000   /* right  */
#define RDP_PTR_BUTTON3           0x4000   /* middle */
#define RDP_PTR_WHEEL             0x0200
#define RDP_PTR_HWHEEL            0x0400
#define RDP_PTR_WHEEL_NEGATIVE    0x0100
#define RDP_PTR_WHEEL_ROTATION    0x01FF

/* macOS keyboard types (CGEventSourceKeyboardType). The Mac keyboard layout
 * (uchr) picks a different key → character table per physical layout family,
 * chosen from this value: e.g. keycode 33 types '[' as ANSI but '@' as JIS. */
#define RDP_MAC_KBTYPE_ANSI 40
#define RDP_MAC_KBTYPE_ISO  41
#define RDP_MAC_KBTYPE_JIS  42

@interface InputInjector : NSObject

/* sourceWidth/Height are the RDP desktop dimensions the client sends pointer
 * coordinates in (the negotiated/captured size). They are scaled to the Mac
 * display's actual point bounds so clicks land correctly when the remote
 * resolution differs from the Mac's (e.g. a Retina display). */
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                      sourceWidth:(uint32_t)sourceWidth
                     sourceHeight:(uint32_t)sourceHeight;

/* Choose the Mac keyboard type (ANSI / ISO / JIS) from what the client reported
 * in its core data (MS-RDPBCGR TS_UD_CS_CORE keyboardLayout / keyboardType).
 * RDP_KEYBOARD_TYPE=auto|jis|ansi|iso|<number> overrides the detection. */
- (void)configureForClientKeyboardLayout:(uint32_t)layout
                                    type:(uint32_t)type
                                 subType:(uint32_t)subType;

- (void)injectKeyEvent:(uint16_t)flags scanCode:(uint16_t)code;
/* TS_UNICODE_KEYBOARD_EVENT: one UTF-16 code unit (surrogates arrive separately). */
- (void)injectUnicodeEvent:(uint16_t)flags codeUnit:(uint16_t)unit;
/* TS_SYNC_EVENT: releases every key we still hold (the client sends this on
 * focus-in, after it may have missed key-ups) and adopts its Caps Lock state. */
- (void)synchronizeWithFlags:(uint32_t)toggleFlags;
/* Release every held key/modifier — call on session teardown. */
- (void)releaseAllKeys;

- (void)injectMouseEvent:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y;
/* Wheel rotation is encoded entirely within flags; decoded internally. */
- (void)injectMouseWheelEvent:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y;

@end

NS_ASSUME_NONNULL_END
