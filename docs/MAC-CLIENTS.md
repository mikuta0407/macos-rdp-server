# Mac clients: the MACRDPX extensions

Between two Macs, plain RDP loses things on the way: keys become PC scan codes
(⌘ turns into the Windows key, Fn and the left/right distinction of modifiers
disappear), a trackpad's smooth scrolling becomes 120-unit wheel notches, and
the client has no say in how much bandwidth the stream may use.

macos-rdp-server therefore offers one extra **static virtual channel,
`MACRDPX`**. A client that knows it joins the channel and says HELLO; both
ends then use whatever features they both support. A client that does not
know the channel never joins it and gets exactly the RDP it always got. The
protocol and its codec live in [macrdpx](https://github.com/mikuta0407/macrdpx),
included here as the `external/macrdpx` git submodule and shared with the
mRemote client.

## What a Mac client gets

| Feature | Plain RDP | With MACRDPX |
|---|---|---|
| Keys | Scan codes, mapped back to Mac keys by guesswork about the client's layout | The Mac's virtual key codes with its exact modifier flags (⌘, ⌥, ⌃, ⇧ left/right, Fn, Caps Lock), auto-repeat marked as such |
| Keyboard type | Guessed from the client's Windows layout | The client's own (`LMGetKbdType`), so ANSI/ISO/JIS keys type what they are labelled |
| Pointer | Fast-path pointer events, click count guessed by the server | On the same channel as the keys (a modifier and a click can't overtake each other), with the client's click count |
| Scrolling | Wheel notches, at least one line per event | Pixel deltas with gesture and momentum phases: trackpad scrolling feels native |
| Stream | Server defaults (`RDP_MAX_FPS`, `RDP_BITRATE_KBPS`) | The client chooses frame rate and bit rate, and may change them mid-session (e.g. Wi-Fi → cellular); the server reports what it applied |
| Input source | — | The server reports its keyboard input source (ASCII or a Japanese/Chinese/Korean input mode) |
| Cursor | System arrow (shapes off by default) | Real cursor shapes, 32-bit with alpha, at the display's pixel scale |

Display control (MS-RDPEDISP) and HiDPI are **not** extensions: every client
that resizes its window gets a resized desktop, and every client at 150 %
scale or more gets a HiDPI virtual display.

## How a session goes

1. The client lists `MACRDPX` among its static channels. The server opens it
   in PostConnect (`protocol/RDPMacrdpx.c`).
2. The client sends HELLO with its capabilities; the server answers with its
   own. Both use the intersection (`mrx_negotiate`).
3. The client sends KEYBOARD_INFO and STREAM_CONFIG; the server answers
   STREAM_STATUS and starts reporting INPUT_SOURCE.
4. From then on the client sends keys, pointer and scrolling only on the
   channel. `RDPSession` hands them to `InputInjector`'s `injectMac*` methods,
   which post CGEvents with the client's own flags, bypassing every scan-code
   translation.

`RDP_MACRDPX=0` disables the channel. With `RDP_LOG_LEVEL=debug` every message
is logged (`rx key`, `tx stream-status`, ...).

## Clients

- **mRemote** (iPadOS/iOS and Mac Catalyst): choose *接続先: macOS
  (macos-rdp-server)* in the connection. On the Mac app, AppKit's keys and
  trackpad scrolling go through unchanged; on an iPad, keys go as the Mac key in
  the same position. The session menu shows the stream and lets the quality be
  changed.
