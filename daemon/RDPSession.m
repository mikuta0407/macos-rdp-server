#import "daemon/RDPSession.h"
#import "daemon/DisplayControl.h"
#import "daemon/Authenticator.h"
#import "protocol/RDPPeer.h"
#import "display/VirtualDisplay.h"
#import "display/ScreenCapture.h"
#import "display/FrameEncoder.h"
#import "display/CursorCapture.h"
#import "input/InputInjector.h"
#import "input/ClipboardSync.h"
#import "audio/AudioCapture.h"
#import "audio/AudioRedirect.h"
#import <os/lock.h>
#import <unistd.h>
#include <freerdp/freerdp.h>
#define RDP_LOG_COMPONENT "session"
#include "logging/RDPLog.h"

static const uint32_t kDefaultWidth   = 1920;
static const uint32_t kDefaultHeight  = 1080;
static const uint32_t kDefaultBitrate = 8000;
static const uint32_t kDefaultMaxFps  = 30;

/* What this server offers a MACRDPX client (external/macrdpx). */
static const mrx_caps kServerMrxCaps = MRX_CAP_MAC_KEYS | MRX_CAP_POINTER |
    MRX_CAP_PRECISE_SCROLL | MRX_CAP_STREAM_CONFIG | MRX_CAP_INPUT_SOURCE |
    MRX_CAP_CURSOR_ALPHA;

static uint32_t env_u32(const char *name, uint32_t dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    long n = strtol(v, NULL, 10);
    return n > 0 ? (uint32_t)n : dflt;
}

static uint32_t clamp_u32(uint32_t v, uint32_t lo, uint32_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Hand-off point between the audio capture thread and the peer. Audio starts
 * asynchronously (see setupDisplayAndMediaForWidth:), so the capture callback can
 * outlive the peer; teardown detaches the peer here before destroying it. */
@interface RDPAudioSink : NSObject {
@public
    os_unfair_lock lock;
    freerdp_peer *peer;
}
@end
@implementation RDPAudioSink
@end

@interface RDPSession ()
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) RDPSessionState sessionState;
@property (nonatomic, strong) NSString *address;
@property (nonatomic, assign) freerdp_peer *peer;
@property (nonatomic, strong) VirtualDisplay  *display;
@property (nonatomic, strong) DisplayControl  *displayControl;
@property (nonatomic, strong) ScreenCapture   *capture;
@property (nonatomic, strong) FrameEncoder    *encoder;
@property (nonatomic, strong) InputInjector   *injector;
@property (nonatomic, strong) ClipboardSync   *clipboard;
@property (nonatomic, strong) AudioCapture    *audio;
@property (nonatomic, strong) RDPAudioSink    *audioSink;
/* Audio start/stop run here, off the session queue: the first start can block
 * in AudioDeviceStart until the "record system audio" consent prompt is
 * answered — and on a headless Mac that prompt can only be answered through
 * this very session, so it must not stall the peer loop. */
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) CursorCapture   *cursor;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
/* Signaled exactly once when teardown completes; lets the takeover path wait
 * for this session's display to be released without touching the main queue. */
@property (nonatomic, strong) dispatch_semaphore_t teardownSem;
/* Set once this session has authenticated + become the active session, so we
 * skip re-authenticating / re-activating on a subsequent Activate (mstsc may
 * re-activate on a resize). Guarded by the serial session queue. */
@property (nonatomic, assign) BOOL activated;
/* MACRDPX: features agreed with the client (0 = a standard RDP client), the
 * keyboard type it reported before the injector existed, and the stream rate
 * in effect. mrxSink lets the main thread (input-source changes) send safely. */
@property (nonatomic, assign) mrx_caps mrxCaps;
@property (nonatomic, assign) uint32_t mrxKeyboardType;
@property (nonatomic, assign) uint32_t maxFps;
@property (nonatomic, assign) uint32_t bitrateKbps;
@property (nonatomic, assign) uint32_t streamWidth;
@property (nonatomic, assign) uint32_t streamHeight;
@property (nonatomic, strong) RDPAudioSink *mrxSink;
@end

@implementation RDPSession

- (instancetype)initWithFileDescriptor:(int)fd clientAddress:(NSString *)address {
    if ((self = [super init])) {
        _fd             = fd;
        _address        = [address copy];
        _sessionState   = RDPSessionStateConnecting;
        _sessionQueue   = dispatch_queue_create("com.macosrdp.session",
                                                DISPATCH_QUEUE_SERIAL);
        _teardownSem    = dispatch_semaphore_create(0);
        _audioQueue     = dispatch_queue_create("com.macosrdp.session.audio",
                                                DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (int)clientFd             { return _fd; }
- (RDPSessionState)state    { return _sessionState; }
- (NSString *)clientAddress { return _address; }

- (void)start {
    rdp_info("starting session for %s", _address.UTF8String);
    dispatch_async(_sessionQueue, ^{ [self setupAndRun]; });
}

- (void)setupAndRun {
    rdp_verbose("creating RDP peer for fd=%d", _fd);
    RDPPeerCallbacks cb = {
        .onKeyboard  = rdp_on_keyboard,
        .onUnicode   = rdp_on_unicode,
        .onSync      = rdp_on_sync,
        .onMouse     = rdp_on_mouse,
        .onMouseEx   = rdp_on_mouse_ex,
        .onClipboard = rdp_on_clipboard,
        .onReady     = rdp_on_ready,
        .onKeyframeRequest = rdp_on_keyframe_request,
        .onMacrdpx   = rdp_on_macrdpx,
        .userdata    = (__bridge void *)self,
    };

    _maxFps      = clamp_u32(env_u32("RDP_MAX_FPS", kDefaultMaxFps), 1, 120);
    _bitrateKbps = clamp_u32(env_u32("RDP_BITRATE_KBPS", kDefaultBitrate), 250, 200000);

    _peer = rdp_peer_create(_fd, &cb);
    if (!_peer) {
        rdp_error("rdp_peer_create failed for %s", _address.UTF8String);
        [self endWithError:[NSError errorWithDomain:@"RDPError" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"peer_create failed"}]];
        return;
    }

    _sessionState = RDPSessionStateNegotiating;
    rdp_verbose("RDP negotiation started with %s", _address.UTF8String);

    /* Negotiation watchdog: if the client doesn't complete RDP activation within
     * kNegotiationTimeoutSecs, drop the connection. Without this, a half-open or
     * stalled TLS handshake holds the peer for FreeRDP's full 2-minute read timeout,
     * making every reconnect attempt appear dead to the user. */
    static const NSTimeInterval kNegotiationTimeoutSecs = 20.0;
    NSDate *negoDeadline = [NSDate dateWithTimeIntervalSinceNow:kNegotiationTimeoutSecs];

    uint32_t lastAudioRate = 0;
    while (_sessionState != RDPSessionStateDisconnecting &&
           _sessionState != RDPSessionStateDisconnected) {
        if (!rdp_peer_run_once(_peer)) {
            rdp_verbose("peer loop ended for %s", _address.UTF8String);
            break;
        }
        /* Abort if still negotiating past the deadline. */
        if (_sessionState == RDPSessionStateNegotiating &&
            [[NSDate date] compare:negoDeadline] == NSOrderedDescending) {
            rdp_info("negotiation timeout (%gs) for %s — dropping stale connection",
                     kNegotiationTimeoutSecs, _address.UTF8String);
            break;
        }
        /* rdpsnd format negotiation completes asynchronously (Activated callback)
         * AFTER audio capture starts. The client plays our PCM at the rate IT
         * selected — rdpsnd does not resample — so the tap must be resampled to
         * that exact rate or the audio is pitch-shifted. Poll the negotiated rate
         * and push it to AudioCapture once known/changed. Cheap; the setter
         * no-ops when unchanged. */
        if (_audio) {
            uint32_t rate = rdp_peer_get_audio_rate(_peer);
            if (rate && rate != lastAudioRate) {
                _audio.outputSampleRate = rate;
                rdp_info("audio playback rate negotiated: %u Hz — "
                         "tap resampled to match (no pitch shift)", (unsigned)rate);
                lastAudioRate = rate;
            }
        }
    }

    [self teardown];
}

static void rdp_on_ready(void *ud, uint32_t w, uint32_t h, uint32_t depth) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_info("client activated: %ux%u @%ubpp", w, h, depth);
    /* Called from peer_activate INSIDE the peer loop, which already runs on the
     * serial sessionQueue. dispatch_async back onto that same queue would starve
     * this behind the blocking loop — it would only run after the loop exits and
     * teardown has freed _peer (use-after-free crash), and media would never be
     * set up during a live session. Run it inline: the peer is alive here. */
    [self setupDisplayAndMediaForWidth:w height:h];
}

static void rdp_on_keyboard(void *ud, uint16_t flags, uint16_t code) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_debug("key flags=0x%04x code=0x%02x", flags, code);
    [self.injector injectKeyEvent:flags scanCode:code];
}

static void rdp_on_unicode(void *ud, uint16_t flags, uint16_t code) {
    RDPSession *self = (__bridge RDPSession *)ud;
    [self.injector injectUnicodeEvent:flags codeUnit:code];
}

static void rdp_on_sync(void *ud, uint32_t toggleFlags) {
    RDPSession *self = (__bridge RDPSession *)ud;
    [self.injector synchronizeWithFlags:toggleFlags];
}

static void rdp_on_mouse(void *ud, uint16_t flags, uint16_t x, uint16_t y) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_debug("mouse flags=0x%04x x=%u y=%u", flags, x, y);
    if (flags & (RDP_PTR_WHEEL | RDP_PTR_HWHEEL))
        [self.injector injectMouseWheelEvent:flags x:x y:y];
    else
        [self.injector injectMouseEvent:flags x:x y:y];
}

static void rdp_on_mouse_ex(void *ud, uint16_t flags, uint16_t x, uint16_t y) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_debug("mouse_ex flags=0x%04x x=%u y=%u", flags, x, y);
    [self.injector injectMouseEvent:flags x:x y:y];
}

static void rdp_on_clipboard(void *ud, const uint8_t *data, size_t len,
                              uint32_t format) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_verbose("clipboard from client: format=0x%08x len=%zu", format, len);
    [self.clipboard receiveFromClient:data length:len format:format];
}

/* ── MACRDPX (Mac client extensions) ─────────────────────────────────────── */

- (void)sendMrxStreamStatus {
    if (!(_mrxCaps & MRX_CAP_STREAM_CONFIG) || !_peer || !_streamWidth) return;
    mrx_message m = { .type = MRX_MSG_STREAM_STATUS };
    m.u.stream_status.max_fps       = (uint16_t)_maxFps;
    m.u.stream_status.scale_percent = 100;
    m.u.stream_status.bitrate_kbps  = _bitrateKbps;
    m.u.stream_status.width         = _streamWidth;
    m.u.stream_status.height        = _streamHeight;
    rdp_peer_send_macrdpx(_peer, &m);
}

- (void)applyStreamFps:(uint32_t)fps kbps:(uint32_t)kbps {
    if (fps)  _maxFps      = clamp_u32(fps, 1, 120);
    if (kbps) _bitrateKbps = clamp_u32(kbps, 250, 200000);
    _capture.maxFps = _maxFps;
    [_encoder setTargetBitrateKbps:_bitrateKbps];
    rdp_info("stream: %u fps, %u kbps (client request %u fps / %u kbps)",
             _maxFps, _bitrateKbps, fps, kbps);
    [self sendMrxStreamStatus];
}

/* Starts after activation, once the peer and injector exist. */
- (void)startMrxFeatures {
    if (!_mrxCaps || !_injector) return;
    if (_mrxKeyboardType) [_injector setMacKeyboardType:_mrxKeyboardType];
    [self sendMrxStreamStatus];
    if (_mrxCaps & MRX_CAP_CURSOR_ALPHA) [self startCursorShapesIfWanted];
    if (_mrxCaps & MRX_CAP_INPUT_SOURCE) {
        RDPAudioSink *sink = [RDPAudioSink new];
        sink->lock = OS_UNFAIR_LOCK_INIT;
        sink->peer = _peer;
        _mrxSink = sink;
        dispatch_async(dispatch_get_main_queue(), ^{
            [InputInjector setInputSourceObserver:^(BOOL ascii, NSString *sid) {
                const char *u = sid.UTF8String ?: "";
                size_t n = strlen(u);
                mrx_message m = { .type = MRX_MSG_INPUT_SOURCE };
                m.u.input_source.ascii_capable = ascii ? 1 : 0;
                m.u.input_source.id = u;
                m.u.input_source.id_length = (uint8_t)(n > MRX_MAX_NAME_BYTES ? MRX_MAX_NAME_BYTES : n);
                os_unfair_lock_lock(&sink->lock);
                if (sink->peer) rdp_peer_send_macrdpx(sink->peer, &m);
                os_unfair_lock_unlock(&sink->lock);
            }];
        });
    }
}

- (void)handleMrxMessage:(const mrx_message *)m {
    switch (m->type) {
    case MRX_MSG_HELLO: {
        if (m->u.hello.role != MRX_ROLE_CLIENT) return;
        _mrxCaps = mrx_negotiate(m->u.hello.caps, kServerMrxCaps);
        rdp_info("MACRDPX client \"%.*s\" v%u caps=0x%x -> using 0x%x",
                 (int)m->u.hello.name_length, m->u.hello.name ?: "", m->u.hello.version,
                 m->u.hello.caps, _mrxCaps);
        char name[128];
        snprintf(name, sizeof name, "macos-rdp-server; macOS %s",
                 NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String ?: "?");
        mrx_message r = { .type = MRX_MSG_HELLO };
        r.u.hello.version = MRX_PROTOCOL_VERSION;
        r.u.hello.role = MRX_ROLE_SERVER;
        r.u.hello.caps = kServerMrxCaps;
        r.u.hello.name = name;
        r.u.hello.name_length = (uint8_t)strlen(name);
        rdp_peer_send_macrdpx(_peer, &r);
        [self startMrxFeatures];   /* no-op until activation */
        return;
    }
    case MRX_MSG_KEYBOARD_INFO:
        _mrxKeyboardType = m->u.keyboard_info.keyboard_type;
        if (_injector) [_injector setMacKeyboardType:_mrxKeyboardType];
        return;
    case MRX_MSG_STREAM_CONFIG:
        if (!(_mrxCaps & MRX_CAP_STREAM_CONFIG)) return;
        [self applyStreamFps:m->u.stream_config.max_fps kbps:m->u.stream_config.bitrate_kbps];
        return;
    default:
        break;
    }
    /* Input: only once agreed, and only while there is somewhere to put it. */
    if (!_injector) return;
    switch (m->type) {
    case MRX_MSG_KEY:
        if (_mrxCaps & MRX_CAP_MAC_KEYS) [_injector injectMacKey:&m->u.key];
        break;
    case MRX_MSG_MODIFIERS:
        if (_mrxCaps & MRX_CAP_MAC_KEYS) [_injector syncMacModifiers:m->u.modifiers.modifier_flags];
        break;
    case MRX_MSG_POINTER:
        if (_mrxCaps & MRX_CAP_POINTER) [_injector injectMacPointer:&m->u.pointer];
        break;
    case MRX_MSG_SCROLL:
        if (_mrxCaps & MRX_CAP_PRECISE_SCROLL) [_injector injectMacScroll:&m->u.scroll];
        break;
    default:
        rdp_verbose("MACRDPX %s ignored on the server", mrx_message_type_name(m->type));
        break;
    }
}

static void rdp_on_macrdpx(void *ud, const mrx_message *m) {
    RDPSession *self = (__bridge RDPSession *)ud;
    [self handleMrxMessage:m];
}

static void rdp_on_keyframe_request(void *ud) {
    RDPSession *self = (__bridge RDPSession *)ud;
    rdp_debug("keyframe requested by peer");
    [self.encoder forceKeyframe];
}

- (void)setupDisplayAndMediaForWidth:(uint32_t)w height:(uint32_t)h {
    /* mstsc can re-activate (e.g. on a client-side resize). We only authenticate
     * and bring the display up once — re-entry after we're active is a no-op. */
    if (_activated || _sessionState == RDPSessionStateActive) {
        rdp_verbose("re-activation ignored (session already active) for %s",
                    _address.UTF8String);
        return;
    }

    /* ── Authenticate BEFORE creating any virtual display ─────────────────────
     * Credentials arrived in the RDP logon (peer_activate captured them). Validate
     * against the local macOS account. Fail-closed: bad/missing creds → tear the
     * connection down. This runs inline on the serial session queue (inside the
     * peer loop), so a synchronous check is safe. NEVER log the password. */
    const char *cuser = NULL, *cpass = NULL, *cdomain = NULL;
    rdp_peer_get_credentials(_peer, &cuser, &cpass, &cdomain);
    NSString *user   = cuser   ? [NSString stringWithUTF8String:cuser]   : nil;
    NSString *pass   = cpass   ? [NSString stringWithUTF8String:cpass]   : nil;
    NSString *domain = cdomain ? [NSString stringWithUTF8String:cdomain] : nil;

    if (![Authenticator validateUsername:user password:pass domain:domain]) {
        rdp_error("authentication FAILED for %s (user='%s') — rejecting connection",
                  _address.UTF8String, user.length ? user.UTF8String : "(none)");
        _sessionState = RDPSessionStateDisconnecting;
        return;  /* peer loop sees Disconnecting and exits → teardown, no display */
    }
    rdp_info("authentication OK for %s (user='%s')",
             _address.UTF8String, user.length ? user.UTF8String : "(none)");

    /* ── Become the single active session (takeover) ──────────────────────────
     * Ask the server to make us active. It signals any currently-active session
     * to disconnect and BLOCKS here until that old session has released its
     * virtual display, so we never have two virtual displays / two main displays
     * fighting. If it returns NO we were superseded (or the server is stopping)
     * and must abort. */
    if ([self.delegate respondsToSelector:@selector(sessionDidAuthenticateAndRequestActivation:)]) {
        if (![self.delegate sessionDidAuthenticateAndRequestActivation:self]) {
            rdp_info("activation refused for %s — aborting session", _address.UTF8String);
            _sessionState = RDPSessionStateDisconnecting;
            return;
        }
    }
    _activated = YES;

    uint32_t width  = w  ?: kDefaultWidth;
    uint32_t height = h ?: kDefaultHeight;

    rdp_info("setting up display %ux%u for %s", width, height, _address.UTF8String);

    _display = [[VirtualDisplay alloc] initWithWidth:width height:height];
    if (![_display create]) {
        rdp_verbose("VirtualDisplay unavailable, falling back to main display");
        _display = nil;
    } else {
        rdp_verbose("VirtualDisplay created: displayID=%u", _display.displayID);
    }

    CGDirectDisplayID displayID = _display ? _display.displayID : CGMainDisplayID();

    /* Wake the Mac + keep it awake for the whole session (replaces caffeinate),
     * and privacy-dim the BUILT-IN panel (brightness -> 0) so a bystander can't
     * watch the remote session. Pass the virtual display id so we never dim the
     * screen the remote actually captures. RDP_SHARED_MODE=1 skips dimming. */
    _displayControl = [[DisplayControl alloc] initWithVirtualDisplayID:displayID];
    [_displayControl start];

    _streamWidth = width;
    _streamHeight = height;
    _encoder = [[FrameEncoder alloc] initWithWidth:width height:height
                                           bitrate:_bitrateKbps];
    __weak typeof(self) weak = self;
    _encoder.outputHandler = ^(const uint8_t *data, size_t len, BOOL keyFrame,
                               uint16_t dx, uint16_t dy, uint16_t dw, uint16_t dh) {
        rdp_debug("encoded frame: len=%zu keyFrame=%d dirty=(%u,%u,%ux%u)",
                  len, keyFrame, dx, dy, dw, dh);
        rdp_peer_send_h264_frame(weak.peer, data, len, width, height,
                                 keyFrame ? true : false, dx, dy, dw, dh);
    };
    [_encoder start];
    rdp_verbose("H.264 encoder started at %u kbps", _bitrateKbps);

    _capture = [[ScreenCapture alloc] initWithDisplayID:displayID];
    _capture.maxFps = _maxFps;
    _capture.frameHandler = ^(IOSurfaceRef surface, uint32_t fw, uint32_t fh,
                               CGRect dirty) {
        (void)fw; (void)fh;
        /* Clamp the dirty origin/size to UINT16 surface-pixel coordinates. */
        uint16_t dx = (uint16_t)MAX(0.0, dirty.origin.x);
        uint16_t dy = (uint16_t)MAX(0.0, dirty.origin.y);
        uint16_t dw = (uint16_t)MIN((double)width,  dirty.size.width);
        uint16_t dh = (uint16_t)MIN((double)height, dirty.size.height);
        rdp_debug("captured frame: dirty=(%u,%u,%ux%u)", dx, dy, dw, dh);
        [weak.encoder encodeFrame:surface dirtyX:dx dirtyY:dy dirtyW:dw dirtyH:dh];
    };
    if ([_capture startWithWidth:width height:height])
        rdp_verbose("screen capture started on displayID=%u", displayID);
    else
        rdp_error("screen capture FAILED on displayID=%u — desktop will be black "
                  "until Screen Recording is granted", displayID);

    _injector  = [[InputInjector alloc] initWithDisplayID:displayID
                                              sourceWidth:width
                                             sourceHeight:height];
    {
        rdpSettings *s = _peer->context->settings;
        [_injector configureForClientKeyboardLayout:freerdp_settings_get_uint32(s, FreeRDP_KeyboardLayout)
                                               type:freerdp_settings_get_uint32(s, FreeRDP_KeyboardType)
                                            subType:freerdp_settings_get_uint32(s, FreeRDP_KeyboardSubType)];
    }
    _clipboard = [[ClipboardSync alloc] init];
    _clipboard.sendToClientBlock = ^(const uint8_t *data, size_t len, uint32_t fmt) {
        rdp_verbose("sending clipboard to client: format=0x%08x len=%zu", fmt, len);
        rdp_peer_send_clipboard(weak.peer, data, len, fmt);
    };
    [_clipboard start];

    /* Only start audio capture if the client actually declared audio support.
       Saves a CoreAudio IO proc registration for clients that don't want audio. */
    BOOL clientWantsAudio = freerdp_settings_get_bool(
        _peer->context->settings, FreeRDP_AudioPlayback);
    if (clientWantsAudio) {
        RDPAudioSink *sink = [RDPAudioSink new];
        sink->lock = OS_UNFAIR_LOCK_INIT;
        sink->peer = _peer;
        _audioSink = sink;
        _audio = [[AudioCapture alloc] init];
        _audio.captureBlock = ^(const int16_t *samples, uint32_t frameCount) {
            /* No per-buffer logging here: buffers arrive ~100x/sec and flooded the
             * log. AudioCapture itself logs a throttled frame total. */
            os_unfair_lock_lock(&sink->lock);
            if (sink->peer) rdp_peer_send_audio(sink->peer, samples, frameCount);
            os_unfair_lock_unlock(&sink->lock);
        };
        AudioCapture *audio = _audio;
        dispatch_async(_audioQueue, ^{
            NSError *audioErr = nil;
            if (![audio startWithError:&audioErr])
                rdp_verbose("audio capture unavailable: %s",
                            audioErr.localizedDescription.UTF8String);
            else
                rdp_verbose("audio capture started");
        });
    } else {
        rdp_verbose("client did not request audio — capture skipped");
    }

    _sessionState = RDPSessionStateActive;
    rdp_info("session active for %s", _address.UTF8String);

    /* Advertise a client-side system cursor first so the very first pointer the
     * client gets is valid (and the cursor is smooth, decoupled from the video
     * frame rate) before the real shapes start streaming. */
    rdp_peer_send_default_cursor(_peer);

    /* Stream the REAL Mac cursor shapes (I-beam, resize, hand, …) as RDP
     * color-pointer PDUs. OPT-IN via RDP_CURSOR_SHAPES=1 (default OFF): the
     * current 32bpp color-pointer renders INVISIBLE on mstsc (shapes are captured
     * and sent at correct sizes, but the client draws nothing — a 32bpp-alpha
     * color-pointer quirk under investigation). Default keeps the client-side
     * SYSPTR_DEFAULT arrow above, which is always visible. Re-enable once the
     * pointer encoding is fixed (likely switch to 24bpp XOR + 1bpp AND mask). */
    [self startCursorShapesIfWanted];

    /* A MACRDPX HELLO that arrived before activation takes effect now. */
    [self startMrxFeatures];
}

- (void)startCursorShapesIfWanted {
    if (_cursor || !_peer) return;
    __weak typeof(self) weak = self;
    const char *curShapes = getenv("RDP_CURSOR_SHAPES");
    /* A MACRDPX client draws alpha pointers properly, so it gets real shapes. */
    BOOL wantShapes = (curShapes && strcmp(curShapes, "1") == 0) ||
                      (_mrxCaps & MRX_CAP_CURSOR_ALPHA);
    if (curShapes && strcmp(curShapes, "0") == 0) wantShapes = NO;
    if (wantShapes) {
        _cursor = [[CursorCapture alloc] init];
        _cursor.handler = ^(const uint8_t *bgra, uint32_t cw, uint32_t ch,
                            uint16_t hotX, uint16_t hotY) {
            rdp_peer_send_cursor_shape(weak.peer, bgra, cw, ch, hotX, hotY);
        };
        [_cursor start];
        rdp_info("cursor-shape streaming ON (%s)",
                 (_mrxCaps & MRX_CAP_CURSOR_ALPHA) ? "MACRDPX client" : "RDP_CURSOR_SHAPES=1");
    } else if (!_mrxCaps) {
        rdp_info("cursor-shape streaming OFF (default) — client draws the system "
                 "arrow; set RDP_CURSOR_SHAPES=1 to stream real Mac cursor shapes");
    }
}

- (void)disconnect {
    rdp_info("disconnecting %s", _address.UTF8String);
    /* The peer loop polls this state every <=50ms and exits when it sees
     * Disconnecting, after which teardown runs on the session queue. */
    _sessionState = RDPSessionStateDisconnecting;
}

- (BOOL)waitForTeardown:(NSTimeInterval)timeout {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(timeout * NSEC_PER_SEC));
    long rc = dispatch_semaphore_wait(_teardownSem, deadline);
    if (rc != 0)
        rdp_error("timed out after %.0fs waiting for %s to release its display",
                  timeout, _address.UTF8String);
    return rc == 0;
}

- (void)teardown {
    rdp_verbose("tearing down session for %s", _address.UTF8String);
    /* Don't leave modifiers stuck down on the Mac if the client vanished mid-chord. */
    [_injector releaseAllKeys];
    [_cursor stop];
    [_capture stop];
    [_encoder stop];
    if (_mrxSink) {
        os_unfair_lock_lock(&_mrxSink->lock);
        _mrxSink->peer = NULL;
        os_unfair_lock_unlock(&_mrxSink->lock);
        dispatch_async(dispatch_get_main_queue(), ^{ [InputInjector setInputSourceObserver:nil]; });
    }
    if (_audioSink) {
        os_unfair_lock_lock(&_audioSink->lock);
        _audioSink->peer = NULL;           /* no more sends into the dying peer */
        os_unfair_lock_unlock(&_audioSink->lock);
    }
    if (_audio) {
        /* Queued behind a start that may still be waiting on consent. */
        AudioCapture *audio = _audio;
        dispatch_async(_audioQueue, ^{ [audio stop]; });
    }
    [_clipboard stop];
    [_displayControl stop];
    [_display destroy];

    if (_peer) { rdp_peer_destroy(_peer); _peer = NULL; }
    if (_fd >= 0) { close(_fd); _fd = -1; }

    _sessionState = RDPSessionStateDisconnected;
    rdp_info("session torn down for %s", _address.UTF8String);

    /* Signal anyone waiting on takeover that our display is now released. Done
     * here (on the session queue, after destroy) rather than via the main-queue
     * delegate hop below, so the semaphore is the reliable cross-thread
     * completion signal. */
    dispatch_semaphore_signal(_teardownSem);

    [self endWithError:nil];
}

- (void)endWithError:(NSError *)error {
    /* Notify on a background queue, NOT the main queue: the main run loop is
     * kept for signal handling and input-source notifications (daemon/main.m). */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self.delegate sessionDidEnd:self error:error];
    });
}

@end
