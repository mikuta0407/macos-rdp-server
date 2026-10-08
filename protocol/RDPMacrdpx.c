#define RDP_LOG_COMPONENT "macrdpx"
#include "logging/RDPLog.h"
#include "protocol/RDPPeer.h"
#include <winpr/wtsapi.h>
#include <winpr/synch.h>
#include <stdlib.h>
#include <string.h>

/*
 * MACRDPX - the Mac RDP eXtensions static virtual channel (external/macrdpx).
 *
 * A Mac-aware client (mRemote in its macOS mode) lists "MACRDPX" in its
 * channel list; every other client doesn't, WTSVirtualChannelOpen returns
 * NULL, and nothing here runs. The channel carries native Mac keys, pointer
 * and precise scrolling, and the client's stream wishes. Decoding happens
 * here; what each message means is RDPSession's business (callbacks.onMacrdpx).
 *
 * FreeRDP reassembles a static channel's chunks before queueing, so each read
 * is one whole client write, which may hold several messages back to back.
 */

#define MRX_READ_BUF_SIZE (MRX_HEADER_BYTES + MRX_MAX_PAYLOAD_BYTES)

bool rdp_peer_open_macrdpx(freerdp_peer *peer) {
    RDPPeerContext *ctx = (RDPPeerContext *)peer->context;
    const char *env = getenv("RDP_MACRDPX");
    if (env && strcmp(env, "0") == 0) {
        rdp_verbose("disabled (RDP_MACRDPX=0)");
        return false;
    }

    HANDLE ch = WTSVirtualChannelOpen(ctx->vcm, WTS_CURRENT_SESSION, MRX_CHANNEL_NAME);
    if (!ch || ch == INVALID_HANDLE_VALUE) {
        rdp_verbose("client did not join %s - standard RDP only", MRX_CHANNEL_NAME);
        return false;
    }

    void *evPtr = NULL;
    DWORD evLen = 0;
    if (!WTSVirtualChannelQuery(ch, WTSVirtualEventHandle, &evPtr, &evLen) || !evPtr) {
        rdp_error("%s: no event handle - channel unusable", MRX_CHANNEL_NAME);
        WTSFreeMemory(evPtr);
        WTSVirtualChannelClose(ch);
        return false;
    }
    ctx->mrxEvent = *(HANDLE *)evPtr;
    WTSFreeMemory(evPtr);
    ctx->mrxChannel = ch;
    ctx->mrxBroken = false;
    rdp_info("%s channel joined by the client - waiting for its HELLO", MRX_CHANNEL_NAME);
    return true;
}

void rdp_peer_close_macrdpx(RDPPeerContext *ctx) {
    if (ctx->mrxChannel && ctx->mrxChannel != INVALID_HANDLE_VALUE)
        WTSVirtualChannelClose(ctx->mrxChannel);
    ctx->mrxChannel = NULL;
    ctx->mrxEvent = NULL;
}

void rdp_peer_pump_macrdpx(freerdp_peer *peer) {
    RDPPeerContext *ctx = (RDPPeerContext *)peer->context;
    if (!ctx->mrxChannel) return;

    static uint8_t *buf;   /* the run loop is the only reader; one session at a time */
    if (!buf && !(buf = malloc(MRX_READ_BUF_SIZE))) return;

    ULONG got = 0;
    while (WTSVirtualChannelRead(ctx->mrxChannel, 0, (PCHAR)buf, MRX_READ_BUF_SIZE, &got) && got > 0) {
        if (ctx->mrxBroken) { got = 0; continue; }
        size_t off = 0;
        while (off < got) {
            mrx_message msg;
            size_t used = 0;
            mrx_status st = mrx_decode(buf + off, got - off, &msg, &used);
            if (st == MRX_OK) {
                rdp_debug("rx %s", mrx_message_type_name(msg.type));
                if (ctx->callbacks.onMacrdpx)
                    ctx->callbacks.onMacrdpx(ctx->callbacks.userdata, &msg);
                off += used;
            } else if (st == MRX_ERROR_UNKNOWN_TYPE) {
                rdp_verbose("skipping unknown message type 0x%04x", (unsigned)msg.type);
                off += used;
            } else {
                /* A write is never split across reads, so NEED_MORE is a broken
                 * sender too. Stop trusting the stream rather than guess. */
                rdp_error("malformed message (%s) at %zu/%lu - ignoring the channel from now on",
                          mrx_status_name(st), off, (unsigned long)got);
                ctx->mrxBroken = true;
                break;
            }
        }
        got = 0;
    }
}

bool rdp_peer_send_macrdpx(freerdp_peer *peer, const mrx_message *message) {
    if (!peer || !peer->context) return false;
    RDPPeerContext *ctx = (RDPPeerContext *)peer->context;
    if (!ctx->mrxChannel) return false;

    uint8_t buf[MRX_HEADER_BYTES + 2 * MRX_MAX_NAME_BYTES];
    size_t len = 0;
    mrx_status st = mrx_encode(message, buf, sizeof buf, &len);
    if (st != MRX_OK) {
        rdp_error("cannot encode %s: %s", mrx_message_type_name(message->type), mrx_status_name(st));
        return false;
    }
    ULONG written = 0;
    pthread_mutex_lock(&ctx->xportLock);
    BOOL ok = WTSVirtualChannelWrite(ctx->mrxChannel, (PCHAR)buf, (ULONG)len, &written);
    pthread_mutex_unlock(&ctx->xportLock);
    if (!ok) rdp_error("write of %s failed", mrx_message_type_name(message->type));
    else rdp_debug("tx %s", mrx_message_type_name(message->type));
    return ok;
}
