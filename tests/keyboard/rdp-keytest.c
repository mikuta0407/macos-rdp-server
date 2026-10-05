/*
 * rdp-keytest — minimal RDP client that connects, types a scripted sequence of
 * scan codes / Unicode characters, then disconnects. Used to exercise the
 * server's keyboard path (scan code → Mac key code, keyboard type, JIS keys)
 * deterministically, without a human at a real client.
 *
 * Build:  tests/keyboard/build.sh
 * Usage:  rdp-keytest [options] <token>...
 *   -h host     server (default 127.0.0.1)    -P port   (default 3389)
 *   -u user     -p password
 *   -l layout   client keyboard layout, e.g. 0x411 (JP) / 0x409 (US)  (default 0x411)
 *   -t type     client keyboard type, 7 = Japanese, 4 = IBM enhanced  (default 7)
 *   -d ms       delay between tokens (default 80)
 * Tokens:
 *   1e          tap scan code 0x1E          e0:48     tap extended scan code
 *   +2a / -2a   press / release only        +e0:1d    (extended press)
 *   pause       Pause/Break (E1 1D 45)      sync:N    TS_SYNC_EVENT with flags N
 *   u:TEXT      type TEXT as Unicode events sleep:MS  wait
 *   click:X,Y   left click at X,Y           dclick:X,Y double click
 */
#include <freerdp/freerdp.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static freerdp *g_inst;

/* Service the connection for `ms` milliseconds so server PDUs are consumed. */
static BOOL pump(DWORD ms) {
    UINT64 end = GetTickCount64() + ms;
    for (;;) {
        HANDLE h[MAXIMUM_WAIT_OBJECTS];
        DWORD n = freerdp_get_event_handles(g_inst->context, h, ARRAYSIZE(h));
        if (n == 0) return FALSE;
        UINT64 now = GetTickCount64();
        if (now >= end) return TRUE;
        WaitForMultipleObjects(n, h, FALSE, (DWORD)(end - now));
        if (!freerdp_check_event_handles(g_inst->context)) return FALSE;
        if (freerdp_shall_disconnect_context(g_inst->context)) return FALSE;
    }
}

static void send_key(BOOL down, UINT8 code, BOOL ext) {
    UINT16 flags = (down ? 0 : KBD_FLAGS_RELEASE) | (ext ? KBD_FLAGS_EXTENDED : 0);
    if (!freerdp_input_send_keyboard_event(g_inst->context->input, flags, code))
        fprintf(stderr, "send failed\n");
}

static void send_utf8(const char *s) {
    /* Minimal UTF-8 → UTF-16 for the test strings we use. */
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        uint32_t cp; int len;
        if (*p < 0x80)      { cp = *p; len = 1; }
        else if (*p < 0xE0) { cp = *p & 0x1F; len = 2; }
        else if (*p < 0xF0) { cp = *p & 0x0F; len = 3; }
        else                { cp = *p & 0x07; len = 4; }
        for (int i = 1; i < len; i++) cp = (cp << 6) | (p[i] & 0x3F);
        p += len;
        UINT16 units[2]; int n = 0;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            units[n++] = (UINT16)(0xD800 + (cp >> 10));
            units[n++] = (UINT16)(0xDC00 + (cp & 0x3FF));
        } else units[n++] = (UINT16)cp;
        for (int i = 0; i < n; i++) {
            freerdp_input_send_unicode_keyboard_event(g_inst->context->input, 0, units[i]);
            freerdp_input_send_unicode_keyboard_event(g_inst->context->input,
                                                      KBD_FLAGS_RELEASE, units[i]);
        }
        pump(20);
    }
}

static void run_token(const char *tok) {
    if (strncmp(tok, "sleep:", 6) == 0) { pump((DWORD)atoi(tok + 6)); return; }
    if (strncmp(tok, "u:", 2) == 0)     { send_utf8(tok + 2); return; }
    if (strncmp(tok, "sync:", 5) == 0) {
        freerdp_input_send_synchronize_event(g_inst->context->input,
                                             (UINT32)strtoul(tok + 5, NULL, 0));
        return;
    }
    if (strncmp(tok, "click:", 6) == 0 || strncmp(tok, "dclick:", 7) == 0) {
        int clicks = tok[0] == 'd' ? 2 : 1;
        unsigned x = 0, y = 0;
        sscanf(strchr(tok, ':') + 1, "%u,%u", &x, &y);
        rdpInput *in = g_inst->context->input;
        freerdp_input_send_mouse_event(in, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
        for (int i = 0; i < clicks; i++) {
            pump(30);
            freerdp_input_send_mouse_event(in, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1, (UINT16)x, (UINT16)y);
            pump(30);
            freerdp_input_send_mouse_event(in, PTR_FLAGS_BUTTON1, (UINT16)x, (UINT16)y);
        }
        return;
    }
    if (strcmp(tok, "pause") == 0) {
        freerdp_input_send_keyboard_pause_event(g_inst->context->input);
        return;
    }
    int mode = 0;                         /* 0 tap, 1 press, 2 release */
    if (*tok == '+') { mode = 1; tok++; } else if (*tok == '-') { mode = 2; tok++; }
    BOOL ext = FALSE;
    if (strncmp(tok, "e0:", 3) == 0) { ext = TRUE; tok += 3; }
    UINT8 code = (UINT8)strtoul(tok, NULL, 16);
    if (mode != 2) send_key(TRUE, code, ext);
    if (mode == 0) pump(30);
    if (mode != 1) send_key(FALSE, code, ext);
}

int main(int argc, char **argv) {
    const char *host = "127.0.0.1", *user = NULL, *pass = NULL;
    UINT32 port = 3389, layout = 0x411, type = 7, delay = 80;
    int opt;
    while ((opt = getopt(argc, argv, "h:P:u:p:l:t:d:")) != -1) {
        switch (opt) {
        case 'h': host = optarg; break;
        case 'P': port = (UINT32)strtoul(optarg, NULL, 0); break;
        case 'u': user = optarg; break;
        case 'p': pass = optarg; break;
        case 'l': layout = (UINT32)strtoul(optarg, NULL, 0); break;
        case 't': type = (UINT32)strtoul(optarg, NULL, 0); break;
        case 'd': delay = (UINT32)strtoul(optarg, NULL, 0); break;
        default:  fprintf(stderr, "see header comment for usage\n"); return 2;
        }
    }

    g_inst = freerdp_new();
    if (!g_inst || !freerdp_context_new(g_inst)) { fprintf(stderr, "context failed\n"); return 1; }
    rdpSettings *s = g_inst->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, port);
    if (user) freerdp_settings_set_string(s, FreeRDP_Username, user);
    if (pass) freerdp_settings_set_string(s, FreeRDP_Password, pass);
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1280);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 800);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, layout);
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardType, type);
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardSubType, type == 7 ? 2 : 0);
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardFunctionKey, 12);

    if (!freerdp_connect(g_inst)) {
        fprintf(stderr, "connect failed: 0x%08x\n", freerdp_get_last_error(g_inst->context));
        return 1;
    }
    fprintf(stderr, "connected; settling...\n");
    if (!pump(2500)) { fprintf(stderr, "connection dropped while settling\n"); return 1; }

    for (int i = optind; i < argc; i++) {
        run_token(argv[i]);
        if (!pump(delay)) { fprintf(stderr, "connection dropped at token %s\n", argv[i]); return 1; }
    }
    pump(500);
    freerdp_disconnect(g_inst);
    freerdp_context_free(g_inst);
    freerdp_free(g_inst);
    fprintf(stderr, "done\n");
    return 0;
}
