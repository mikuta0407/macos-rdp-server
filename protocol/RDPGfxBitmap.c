/*
 * GFX surface updates from captured BGRA frames, for clients that do not take
 * H.264 (they set RDPGFX_CAPS_FLAG_AVC_DISABLED on every capset, e.g. Windows
 * App on iPhone). The frame is compared with the last one sent in 64x64 tiles
 * (the RemoteFX tile grid), and only the tiles that changed are encoded:
 *
 *   - RemoteFX Progressive (RDPGFX_CODECID_CAPROGRESSIVE): the dirty tiles go
 *     out as one region per surface command, at full quality ("simple" tiles,
 *     as FreeRDP's shadow server sends them). A frame touching many tiles is
 *     split into several commands so no single PDU grows too large.
 *   - Planar (RDPGFX_CODECID_PLANAR): one surface command per run of dirty
 *     tiles in a tile row, at most kPlanarRunTiles wide.
 *
 * The changed tiles are copied into the encoder's own frame first, and the
 * codecs encode from that copy. Every frame's commands are wrapped in one
 * StartFrame/EndFrame pair. Encoding happens before the transport lock is
 * taken; only the sends hold it.
 */
#define RDP_LOG_COMPONENT "gfx"
#include "logging/RDPLog.h"
#include "protocol/RDPPeer.h"

#include <freerdp/codec/progressive.h>
#include <freerdp/codec/planar.h>
#include <freerdp/codec/region.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/rdpgfx.h>
#include <winpr/sysinfo.h>
#include <stdlib.h>
#include <string.h>

enum {
    kTile = 64,
    /* Progressive: tiles per surface command. 256 tiles is 1M pixels; a
     * full-quality command of that many tiles is typically well under 1 MB. */
    kProgressiveMaxTiles = 256,
    /* Planar: widest run of tiles in one command (256x64 px, 64 KB raw). */
    kPlanarRunTiles = 4,
    /* Frames sent but not yet acknowledged before new ones are held back. The
     * changes are not lost: they are compared against the last frame SENT, so
     * the next frame that goes out carries them. */
    kMaxFramesInFlight = 3,
    /* A client that stops acknowledging (or never does) still gets a frame
     * this often. */
    kAckTimeoutMs = 1000,
    /* With nothing changed, an empty frame keeps the stream alive this often
     * (the AVC path re-sends the screen for the same reason). */
    kIdleFrameMs = 1000,
};

struct RDPGfxBitmapEncoder {
    uint32_t  width, height;
    uint32_t  tilesX, tilesY;
    uint8_t  *prev;          /* last frame sent, width*4 bytes per row */
    uint8_t  *dirty;         /* tilesX*tilesY flags */
    PROGRESSIVE_CONTEXT   *progressive;
    BITMAP_PLANAR_CONTEXT *planar;
    uint64_t  lastSendMs;
    uint64_t  frames, bytes; /* stats */
};

typedef struct {
    RDPGFX_SURFACE_COMMAND cmd;
    BYTE *owned;
} PendingCmd;

typedef struct {
    PendingCmd *items;
    size_t      count, cap;
    size_t      bytes;
} CmdList;

void rdp_gfx_bitmap_encoder_free(RDPGfxBitmapEncoder *e) {
    if (!e) return;
    if (e->progressive) progressive_context_free(e->progressive);
    if (e->planar) freerdp_bitmap_planar_context_free(e->planar);
    free(e->prev);
    free(e->dirty);
    free(e);
}

static RDPGfxBitmapEncoder *encoder_new(RDPGfxCodec codec, uint32_t w, uint32_t h) {
    RDPGfxBitmapEncoder *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->width = w; e->height = h;
    e->tilesX = (w + kTile - 1) / kTile;
    e->tilesY = (h + kTile - 1) / kTile;
    e->prev  = malloc((size_t)w * h * 4);
    e->dirty = malloc((size_t)e->tilesX * e->tilesY);
    if (!e->prev || !e->dirty) goto fail;
    if (codec == RDP_GFX_CODEC_PROGRESSIVE) {
        e->progressive = progressive_context_new(TRUE);
        if (!e->progressive || !progressive_context_reset(e->progressive)) goto fail;
    } else {
        /* The surface is XRGB: no alpha plane. RLE keeps flat UI areas small. */
        e->planar = freerdp_bitmap_planar_context_new(
            PLANAR_FORMAT_HEADER_NA | PLANAR_FORMAT_HEADER_RLE,
            kTile * kPlanarRunTiles, kTile);
        if (!e->planar ||
            !freerdp_bitmap_planar_context_reset(e->planar, kTile * kPlanarRunTiles, kTile))
            goto fail;
        freerdp_planar_topdown_image(e->planar, TRUE);
    }
    return e;
fail:
    rdp_gfx_bitmap_encoder_free(e);
    return NULL;
}

static bool cmds_push(CmdList *l, const RDPGFX_SURFACE_COMMAND *cmd, BYTE *owned) {
    if (l->count == l->cap) {
        size_t cap = l->cap ? l->cap * 2 : 16;
        PendingCmd *n = realloc(l->items, cap * sizeof(*n));
        if (!n) { free(owned); return false; }
        l->items = n; l->cap = cap;
    }
    l->items[l->count].cmd = *cmd;
    l->items[l->count].owned = owned;
    l->count++;
    l->bytes += cmd->length;
    return true;
}

static void cmds_free(CmdList *l) {
    for (size_t i = 0; i < l->count; i++) free(l->items[i].owned);
    free(l->items);
}

/* Marks the tiles that differ from the last frame sent and copies them into
 * it. Returns the number of dirty tiles. */
static uint32_t diff_tiles(RDPGfxBitmapEncoder *e, const uint8_t *bgra, uint32_t stride,
                           bool full) {
    const size_t prevStride = (size_t)e->width * 4;
    uint32_t count = 0;
    for (uint32_t ty = 0; ty < e->tilesY; ty++) {
        const uint32_t y0 = ty * kTile;
        const uint32_t th = MIN((uint32_t)kTile, e->height - y0);
        for (uint32_t tx = 0; tx < e->tilesX; tx++) {
            const uint32_t x0 = tx * kTile;
            const size_t rowBytes = (size_t)MIN((uint32_t)kTile, e->width - x0) * 4;
            bool changed = full;
            for (uint32_t y = 0; !changed && y < th; y++)
                changed = memcmp(bgra + (size_t)(y0 + y) * stride + x0 * 4,
                                 e->prev + (size_t)(y0 + y) * prevStride + x0 * 4,
                                 rowBytes) != 0;
            e->dirty[ty * e->tilesX + tx] = changed;
            if (!changed) continue;
            count++;
            for (uint32_t y = 0; y < th; y++)
                memcpy(e->prev + (size_t)(y0 + y) * prevStride + x0 * 4,
                       bgra + (size_t)(y0 + y) * stride + x0 * 4, rowBytes);
        }
    }
    return count;
}

static bool encode_progressive_batch(RDPGfxBitmapEncoder *e, RDPPeerContext *ctx,
                                     const uint8_t *bgra, uint32_t stride,
                                     REGION16 *region, CmdList *out) {
    BYTE *data = NULL;
    UINT32 len = 0;
    int rc = progressive_compress(e->progressive, bgra, stride * e->height,
                                  PIXEL_FORMAT_BGRX32, e->width, e->height, stride,
                                  region, &data, &len);
    region16_clear(region);
    if (rc < 0) { rdp_error("progressive_compress failed: %d", rc); return false; }
    if (rc == 0 || !len) return true;
    /* The codec reuses its output buffer on the next call: keep a copy. */
    BYTE *copy = malloc(len);
    if (!copy) return false;
    memcpy(copy, data, len);
    RDPGFX_SURFACE_COMMAND cmd = {0};
    cmd.surfaceId = ctx->surfaceId;
    /* One progressive codec context per surface; a resize makes a new surface,
     * and with it a new context on the client. */
    cmd.contextId = ctx->surfaceId;
    cmd.codecId   = RDPGFX_CODECID_CAPROGRESSIVE;
    cmd.format    = PIXEL_FORMAT_BGRX32;
    cmd.right     = e->width;
    cmd.bottom    = e->height;
    cmd.data      = copy;
    cmd.length    = len;
    return cmds_push(out, &cmd, copy);
}

static bool encode_progressive(RDPGfxBitmapEncoder *e, RDPPeerContext *ctx,
                               const uint8_t *bgra, uint32_t stride, CmdList *out) {
    REGION16 region;
    region16_init(&region);
    uint32_t batch = 0;
    bool ok = true;
    for (uint32_t ty = 0; ok && ty < e->tilesY; ty++) {
        for (uint32_t tx = 0; ok && tx < e->tilesX; ) {
            if (!e->dirty[ty * e->tilesX + tx]) { tx++; continue; }
            uint32_t run = 0;
            while (tx + run < e->tilesX && e->dirty[ty * e->tilesX + tx + run] &&
                   batch + run < kProgressiveMaxTiles)
                run++;
            RECTANGLE_16 r = {
                .left   = (UINT16)(tx * kTile),
                .top    = (UINT16)(ty * kTile),
                .right  = (UINT16)MIN((tx + run) * kTile, e->width),
                .bottom = (UINT16)MIN((ty + 1) * kTile, e->height),
            };
            region16_union_rect(&region, &region, &r);
            batch += run;
            tx += run;
            if (batch >= kProgressiveMaxTiles) {
                ok = encode_progressive_batch(e, ctx, bgra, stride, &region, out);
                batch = 0;
            }
        }
    }
    if (ok && batch) ok = encode_progressive_batch(e, ctx, bgra, stride, &region, out);
    region16_uninit(&region);
    return ok;
}

static bool encode_planar(RDPGfxBitmapEncoder *e, RDPPeerContext *ctx,
                          const uint8_t *bgra, uint32_t stride, CmdList *out) {
    for (uint32_t ty = 0; ty < e->tilesY; ty++) {
        for (uint32_t tx = 0; tx < e->tilesX; ) {
            if (!e->dirty[ty * e->tilesX + tx]) { tx++; continue; }
            uint32_t run = 0;
            while (tx + run < e->tilesX && e->dirty[ty * e->tilesX + tx + run] &&
                   run < kPlanarRunTiles)
                run++;
            const uint32_t x = tx * kTile, y = ty * kTile;
            const uint32_t w = MIN((tx + run) * kTile, e->width) - x;
            const uint32_t h = MIN((ty + 1) * kTile, e->height) - y;
            UINT32 len = 0;
            BYTE *data = freerdp_bitmap_compress_planar(
                e->planar, bgra + (size_t)y * stride + (size_t)x * 4,
                PIXEL_FORMAT_BGRX32, w, h, stride, NULL, &len);
            if (!data || !len) { free(data); rdp_error("planar compress failed"); return false; }
            RDPGFX_SURFACE_COMMAND cmd = {0};
            cmd.surfaceId = ctx->surfaceId;
            cmd.codecId   = RDPGFX_CODECID_PLANAR;
            cmd.format    = PIXEL_FORMAT_BGRX32;
            cmd.left = x; cmd.top = y; cmd.right = x + w; cmd.bottom = y + h;
            cmd.data   = data;
            cmd.length = len;
            if (!cmds_push(out, &cmd, data)) return false;
            tx += run;
        }
    }
    return true;
}

bool rdp_peer_send_bgra_frame(freerdp_peer *peer, const uint8_t *bgra,
                              uint32_t stride, uint32_t width, uint32_t height) {
    RDPPeerContext *ctx = (RDPPeerContext *)peer->context;
    const RDPGfxCodec codec = ctx->gfxCodec;
    if (codec != RDP_GFX_CODEC_PROGRESSIVE && codec != RDP_GFX_CODEC_PLANAR) return false;
    if (!ctx->gfxReady || !ctx->gfx) { rdp_debug("gfx not ready"); return false; }
    if (ctx->outputSuppressed) return true;
    if (!bgra || width == 0 || height == 0 || stride < width * 4) return false;

    /* A frame of the old size, still in flight across a resize. */
    rdpSettings *s = peer->context->settings;
    if (width  != freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth) ||
        height != freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight)) {
        rdp_debug("frame %ux%u does not match the surface; dropped", width, height);
        return true;
    }

    RDPGfxBitmapEncoder *e = ctx->bitmapEncoder;
    if (e && (e->width != width || e->height != height ||
              (codec == RDP_GFX_CODEC_PROGRESSIVE) != (e->progressive != NULL))) {
        rdp_gfx_bitmap_encoder_free(e);
        e = ctx->bitmapEncoder = NULL;
    }
    bool full = !ctx->sentKeyframe;
    if (!e) {
        e = ctx->bitmapEncoder = encoder_new(codec, width, height);
        if (!e) { rdp_error("could not create the %ux%u bitmap encoder", width, height); return false; }
        full = true;
    }

    const uint64_t now = GetTickCount64();
    if (!full && !ctx->gfxAcksSuspended) {
        const uint32_t inFlight = ctx->frameId - ctx->gfxLastAckedFrame;
        const uint64_t lastAck = MAX(ctx->gfxLastAckMs, e->lastSendMs);
        if (inFlight > kMaxFramesInFlight && now - lastAck < kAckTimeoutMs) {
            rdp_debug("%u frames unacknowledged; holding back", inFlight);
            return true;
        }
    }

    const uint32_t dirty = diff_tiles(e, bgra, stride, full);
    if (dirty == 0 && now - e->lastSendMs < kIdleFrameMs) return true;

    CmdList cmds = {0};
    bool ok = true;
    if (dirty) {
        /* Encode from the copy, not from the captured surface: the surface
         * may still change under us (the capture heartbeat re-reads the last
         * surface, which the capture pool may already be reusing). Pixels
         * encoded from it could differ from what the copy recorded, and a
         * tile that then stops changing would stay wrong on the client. From
         * the copy, the client always holds exactly what the next diff
         * compares against. */
        const uint32_t prevStride = e->width * 4;
        ok = codec == RDP_GFX_CODEC_PROGRESSIVE
                 ? encode_progressive(e, ctx, e->prev, prevStride, &cmds)
                 : encode_planar(e, ctx, e->prev, prevStride, &cmds);
    }
    if (!ok) {
        cmds_free(&cmds);
        ctx->sentKeyframe = false;   /* resend everything next time */
        return false;
    }

    /* Serialize against ALL other transport writers (run loop, cliprdr, audio). */
    UINT rc = CHANNEL_RC_OK;
    pthread_mutex_lock(&ctx->xportLock);
    if (ctx->gfxReady && !ctx->outputSuppressed &&
        width  == freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth) &&
        height == freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight)) {
        const uint32_t fid = ++ctx->frameId;
        RDPGFX_START_FRAME_PDU start = { .frameId = fid };
        RDPGFX_END_FRAME_PDU   end   = { .frameId = fid };
        /* The surface may have been recreated since encoding (resize). */
        for (size_t i = 0; i < cmds.count; i++) {
            cmds.items[i].cmd.surfaceId = ctx->surfaceId;
            if (cmds.items[i].cmd.codecId == RDPGFX_CODECID_CAPROGRESSIVE)
                cmds.items[i].cmd.contextId = ctx->surfaceId;
        }
        if (cmds.count == 1) {
            rc = ctx->gfx->SurfaceFrameCommand(ctx->gfx, &cmds.items[0].cmd, &start, &end);
        } else {
            rc = ctx->gfx->StartFrame(ctx->gfx, &start);
            for (size_t i = 0; rc == CHANNEL_RC_OK && i < cmds.count; i++)
                rc = ctx->gfx->SurfaceCommand(ctx->gfx, &cmds.items[i].cmd);
            if (rc == CHANNEL_RC_OK) rc = ctx->gfx->EndFrame(ctx->gfx, &end);
        }
        if (full && rc == CHANNEL_RC_OK) { ctx->sentKeyframe = true; ctx->keyframeRequested = false; }
    }
    pthread_mutex_unlock(&ctx->xportLock);

    if (rc != CHANNEL_RC_OK) {
        rdp_error("GFX %s frame send failed: %u", codec == RDP_GFX_CODEC_PROGRESSIVE
                  ? "progressive" : "planar", rc);
        ctx->sentKeyframe = false;
        cmds_free(&cmds);
        return false;
    }
    e->lastSendMs = now;
    e->frames++;
    e->bytes += cmds.bytes;
    rdp_debug("sent %s frame: %u/%u tiles, %zu commands, %zu bytes",
              codec == RDP_GFX_CODEC_PROGRESSIVE ? "progressive" : "planar",
              dirty, e->tilesX * e->tilesY, cmds.count, cmds.bytes);
    if (e->frames % 300 == 0)
        rdp_verbose("bitmap codec: %llu frames, %llu KB sent",
                    (unsigned long long)e->frames, (unsigned long long)(e->bytes / 1024));
    cmds_free(&cmds);
    return true;
}
