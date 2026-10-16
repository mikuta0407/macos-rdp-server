# macos-rdp-server

English | [日本語](README.ja.md)

A lightweight RDP server daemon for macOS Tahoe and later. This is a fork of [grioghar/macos-rdp-server](https://github.com/grioghar/macos-rdp-server) with Japanese/JIS keyboard support and the Mac-to-Mac extensions (MACRDPX). Connect to your Mac from any standard RDP client — Windows Remote Desktop, FreeRDP, Remmina — with the same smoothness you'd expect from a Windows environment.

## Features

- **H.264 hardware encoding** via VideoToolbox — low latency, low CPU
- **Your own screen, or a screen of its own** — by default the session shows and controls the Mac's main display, as Screen Sharing does; `RDP_DISPLAY_MODE=virtual` gives each session a dedicated CGVirtualDisplay instead, leaving your physical screen undisturbed (a Mac with no display lit always gets one)
- **Full keyboard & mouse injection** via CGEventPost with a complete RDP scan-code table — JIS/ISO/ANSI aware, IME keys, Unicode input
- **Bidirectional clipboard** — text and images sync between client and host
- **System audio redirection** — hear your Mac's audio through the RDP client
- **Structured logging** — four levels (ERROR / INFO / VERBOSE / DEBUG), set via flag or env var
- **DriverKit HID extension** *(optional, requires Apple Developer account)* — injects input at the HID stack level, works at the login window and in secure input fields
- **launchd integration** — a per-user LaunchAgent that starts when you log in and restarts on crash
- **TLS encryption** — self-signed certificate generated on install; clients trust on first connect
- **Follows the client's window** — display control (MS-RDPEDISP) resizes the virtual display, the stream and the GFX surface live; a client at 150 % scale or more (a Mac's Retina 200 %) gets a **HiDPI** virtual display, so text is rendered at the client's density. On the main display, the Mac switches to the display mode closest to the client's size (in points, HiDPI for a Retina client) and goes back to its own when the session ends; the stream takes the display's shape, at Retina pixels for such a client
- **Mac-to-Mac extensions (MACRDPX)** — a Mac client that joins the `MACRDPX` channel sends keys as Mac keys with exact modifiers (⌘ stays ⌘, Fn, left/right), the pointer with real click counts, pixel-precise trackpad scrolling with momentum, trackpad gestures (pinch, rotate, smart zoom, Dock swipes), and can choose the frame rate and bit rate mid-session. See [docs/MAC-CLIENTS.md](docs/MAC-CLIENTS.md). Every other client is plain RDP, unchanged

## Requirements

- macOS 14 Sonoma or later
- Homebrew (for the Homebrew install, or when building from source; the pre-built binary has no runtime dependencies)
- Xcode Command Line Tools (source builds only)

## Install

Run these as the user whose desktop you want to reach (over SSH is fine, as
long as that user is logged in):

```bash
brew install mikuta0407/apps/macos-rdp-server
macos-rdp-install-user
```

`macos-rdp-install-user` copies the daemon to `~/.macos-rdp/bin/`, signs it
with a stable self-signed certificate, creates the RDP TLS certificate, and
loads a per-user LaunchAgent (`com.macosrdp.agent`) that listens on port 3389.
No sudo.

Settings go in the environment when you run it, for example:

```bash
RDP_KEYBOARD_TYPE=jis RDP_PORT=3390 macos-rdp-install-user
```

Then grant the two permissions below once, and connect.

> [!IMPORTANT]
> **The daemon must run inside a logged-in GUI session.** Screen capture needs the
> session's WindowServer connection, which is why it is a LaunchAgent and starts when
> you log in. Nothing listens before a user logs in — for a Mac without a screen or a
> keyboard, see [Headless operation](#headless-operation).

## Privacy permissions

| Permission | Required for |
|---|---|
| Screen Recording (*Screen & System Audio Recording*) | Capturing the screen, and the system audio |
| Accessibility | Injecting keyboard and mouse input |

Both are granted to `~/.macos-rdp/bin/macos-rdp-daemon`, not to the copy Homebrew
installed. Granting has to be done on the Mac itself: without Screen Recording the RDP
screen is black, so it cannot be done over RDP. Use a monitor, or connect once with
macOS Screen Sharing.

1. Connect once from an RDP client (the screen is still black). macOS asks on the Mac
   whether `macos-rdp-daemon` may control the computer and record the screen; choose
   **Open System Settings**.
2. In **System Settings → Privacy & Security → Accessibility**, turn on
   `macos-rdp-daemon`. Do the same under **Screen & System Audio Recording**.
3. Reconnect. The desktop appears and the keyboard and mouse work.

If `macos-rdp-daemon` is not in a list, add it: click **+**, press **⌘⇧G**, type
`~/.macos-rdp/bin/` (a hidden folder, but typing the path opens it), select
`macos-rdp-daemon`, and turn it on.

The grant survives updates: `macos-rdp-install-user` re-signs every new build with
the same certificate, and macOS pins the grant to that signature. About every 30 days
macOS asks again whether the daemon may keep recording the screen.

## Managing the agent

```bash
launchctl print gui/$(id -u)/com.macosrdp.agent | grep -E 'state|pid'  # status
launchctl kickstart -k gui/$(id -u)/com.macosrdp.agent                # restart
launchctl bootout gui/$(id -u)/com.macosrdp.agent                     # stop (starts again at next login)
tail -f ~/Library/Logs/macos-rdp-agent.error.log                      # log
```

Run these as the user, **without sudo**: the agent lives in the user's GUI domain.

- **Change a setting**: run `macos-rdp-install-user` again with the new values. It
  rewrites the LaunchAgent and reloads it. Only the variables you pass are written,
  so pass every non-default one each time.
- **Update**: `brew upgrade macos-rdp-server`, then `macos-rdp-install-user` again.
- **Uninstall**:

  ```bash
  launchctl bootout gui/$(id -u)/com.macosrdp.agent
  rm ~/Library/LaunchAgents/com.macosrdp.agent.plist
  security delete-keychain ~/.macos-rdp/signing/macos-rdp.keychain-db
  rm -rf ~/.macos-rdp
  brew uninstall macos-rdp-server
  ```

| What | Where |
|---|---|
| Daemon (signed copy) | `~/.macos-rdp/bin/macos-rdp-daemon` |
| RDP TLS certificate | `~/.macos-rdp/server.crt`, `server.key` |
| Signing keychain | `~/.macos-rdp/signing/macos-rdp.keychain-db` |
| LaunchAgent | `~/Library/LaunchAgents/com.macosrdp.agent.plist` |
| Logs | `~/Library/Logs/macos-rdp-agent.error.log` (the daemon's log), `macos-rdp-agent.log` |

## Headless operation

To use a Mac with no screen or keyboard attached, it has to be logged in after every
restart, so turn on automatic login:

1. **Turn off FileVault** — macOS disables automatic login while FileVault is on.
   (Keeping FileVault is possible if every restart is planned:
   `sudo fdesetup authrestart` restarts once straight into the logged-in session. A
   power cut still stops at the FileVault unlock screen.)
2. **Turn on automatic login**: System Settings → Users & Groups → *Automatically log
   in as*.
3. **Start again after a power cut**: `sudo pmset -a autorestart 1`.
4. **Install and grant the permissions** as above, with a monitor or Screen Sharing for
   the one-time grant.

The daemon keeps the Mac from sleeping while it runs, and a Mac with no display gets a
virtual one, so nothing else is needed for the screen.

What this setup gives up: anyone with physical access to the Mac — a monitor or just a
USB keyboard — gets the logged-in session, and without FileVault the disk is not
encrypted with your password. Over the network, the RDP password is the only lock:
keep port 3389 on your LAN or behind a VPN rather than open to the internet, and keep
the client's certificate check on, so a changed certificate is noticed.

## Connect

| Client | Steps |
|---|---|
| Windows Remote Desktop | Start → `mstsc` → enter your Mac's IP |
| macOS Remote Desktop | App Store → Microsoft Remote Desktop → Add PC |
| FreeRDP (CLI) | `xfreerdp /v:your-mac-ip /u:$(whoami) /cert:ignore` |
| Remmina | New connection → protocol RDP → enter IP |
| mRemote (iPad, iPhone, Mac) | Add a connection, and mark it as a Mac for the MACRDPX extensions |

On first connect your client will show a certificate trust prompt — accept it. Subsequent connections skip this.

## Configuration

Settings are environment variables passed to `macos-rdp-install-user` (see
[Managing the agent](#managing-the-agent)).

| Variable | Default | Description |
|---|---|---|
| `RDP_PORT` | `3389` | TCP port to listen on |
| `RDP_LOG_LEVEL` | `info` | `error`, `info`, `verbose` or `debug` (see below) |
| `RDP_KEYBOARD_TYPE` | auto | `jis`, `ansi`, `iso` or `auto`; see [docs/JAPANESE-SETUP.md](docs/JAPANESE-SETUP.md) |
| `RDP_MAX_FPS` | `30` | Frame-rate cap (1–120); a MACRDPX client may change it per session |
| `RDP_BITRATE_KBPS` | `8000` | H.264 target bit rate; likewise per session for MACRDPX clients |
| `RDP_DISPLAY_MODE` | `main` | `main` shows the Mac's main display; `virtual` gives each session a display of its own, sized to the client |
| `RDP_MATCH_RESOLUTION` | `1` | On the main display: `1` switches the Mac's resolution to the mode closest to the client's; `0` leaves it as it is |
| `RDP_HIDPI` | auto | `auto`: HiDPI virtual display at a client scale ≥ 150 %; `0` never; `1` always |
| `RDP_DISP` | on | `0` disables display control (the desktop keeps its connect-time size) |
| `RDP_MACRDPX` | on | `0` disables the Mac-to-Mac extensions channel |
| `RDP_CURSOR_SHAPES` | auto | `1` streams real cursor shapes to every client; `0` never. MACRDPX clients get them by default |
| `RDP_UPDATE_ENABLED` | `0` | `1` lets the daemon replace itself with the latest release. Leave it off with Homebrew |

`RDP_ZENKAKU_TOGGLE`, `RDP_SWAP_CTRL_CMD`, `RDP_AUDIO_LOCAL`, `RDP_AUDIO_INPUT`,
`RDP_RDPDR_ENABLED`, `RDP_SHARED_MODE`, `RDP_PRIVACY_BLANK` and `RDP_ALLOW_IDLE_SLEEP`
are passed through as well; [docs/TESTING.md](docs/TESTING.md) describes them.

## Logging

The daemon uses a four-level structured logger. Each log line includes a timestamp, level tag, and subsystem component:

```
[14:23:01.042] [INFO ] [server] listening for RDP connections on port 3389
[14:23:04.187] [INFO ] [main  ] client connected from ::ffff:192.168.1.5
[14:23:04.201] [INFO ] [peer  ] peer activated: 1920x1080 @32bpp
[14:23:04.203] [INFO ] [session] setting up display 1920x1080 for ::ffff:192.168.1.5
[14:23:04.251] [INFO ] [display] virtual display created: displayID=3 1920x1080
[14:23:04.260] [INFO ] [encoder] H.264 encoder ready: 1920x1080 @ 8000 kbps
[14:23:04.261] [INFO ] [capture] capture started on displayID=3
[14:23:04.265] [INFO ] [audio  ] audio capture started on device 48
[14:23:04.266] [INFO ] [session] session active for ::ffff:192.168.1.5
```

| Level | What it logs | Use when |
|---|---|---|
| `error` | Hard failures that stop a session or the daemon | Production; quiet machines |
| `info` | Connection lifecycle — connect, activate, disconnect | Default |
| `verbose` | Subsystem events — channel opens, display creation, encoder start, audio start | Diagnosing connection or feature issues |
| `debug` | Per-frame and per-event detail — every keypress, every encoded frame size, every dirty rect | Deep protocol troubleshooting |

> **Warning:** `debug` logs every captured frame and input event. At 60fps this is ~3,600 lines/minute. Use it for short captures only.

```bash
RDP_LOG_LEVEL=verbose macos-rdp-install-user                     # change the level
tail -f ~/Library/Logs/macos-rdp-agent.error.log                 # follow the log
tail -f ~/Library/Logs/macos-rdp-agent.error.log | grep '\[ERROR\]'
log stream --predicate 'process == "macos-rdp-daemon"' --level debug   # unified logging
```

## Build from source

```bash
# 1. Install dependencies
brew install freerdp cmake openssl pkgconf

# 2. Clone (with the macrdpx submodule)
git clone --recurse-submodules https://github.com/mikuta0407/macos-rdp-server.git
cd macos-rdp-server
# an existing checkout: git submodule update --init

# 3. Build
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$(brew --prefix freerdp);$(brew --prefix openssl)"
cmake --build build

# 4. Install as a per-user LaunchAgent (no sudo)
scripts/install-user.sh build/macos-rdp-daemon
```

`scripts/install-user.sh` is what `macos-rdp-install-user` runs; it takes the same
settings. Japanese / JIS keyboard notes: [docs/JAPANESE-SETUP.md](docs/JAPANESE-SETUP.md).

> **How the release binary is built.** Each release (a `v*` tag) is built by CI from
> source-pinned forks of FreeRDP and OpenSSL, statically linked, in a single pass, as a
> universal binary. Nothing is pulled from a package manager at build or run time. See
> [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Other install methods (system LaunchDaemon)

These are kept from upstream. They install the daemon as a **system LaunchDaemon**,
which has no WindowServer connection and **renders a black screen**. Prefer the
Homebrew install; with a binary from here, run
`scripts/install-user.sh /usr/local/sbin/macos-rdp-daemon` instead of the daemon.

```bash
# One-line installer: the universal binary to /usr/local/sbin, a TLS certificate in
# /etc/macos-rdp/, and the LaunchDaemon on port 3389
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/remote-install.sh | sudo bash

# Or just the binary, and its checksum
sudo curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/macos-rdp-daemon \
  -o /usr/local/sbin/macos-rdp-daemon && sudo chmod +x /usr/local/sbin/macos-rdp-daemon
cd /usr/local/sbin && curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/SHA256SUMS | shasum -c --ignore-missing

# Permission helper (with SIP disabled it writes the TCC database directly)
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/grant-permissions.sh | sudo bash

# Managing it
sudo launchctl kickstart -k system/com.macosrdp.daemon     # restart
tail -f /var/log/macos-rdp-daemon.error.log                # log
sudo bash scripts/uninstall.sh                             # uninstall
```

Its settings live in `/Library/LaunchDaemons/com.macosrdp.daemon.plist`
(`--port` in `ProgramArguments`, variables under `EnvironmentVariables`).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│        macos-rdp-daemon (LaunchAgent, user session)      │
│                                                          │
│  TCP :3389 ──► RDPServer ──► RDPSession (per client)    │
│                                   │                      │
│              ┌────────────────────┼──────────────────┐   │
│              │                   │                   │   │
│         RDPPeer              VirtualDisplay    AudioCapture
│      (libfreerdp 3)        (CGVirtualDisplay) (CoreAudio HAL)
│              │                   │                   │   │
│         GFX Pipeline       ScreenCapture       AudioRedirect
│       (H.264 AVC420)      (ScreenCaptureKit)   (RDPSND ch.)
│              │                   │                        │
│         InputInjector       FrameEncoder                  │
│        (CGEventPost)      (VideoToolbox)                  │
│              │                                            │
│         ClipboardSync      RDPLog                         │
│        (NSPasteboard)   (ERROR/INFO/VERBOSE/DEBUG)        │
│              │                                            │
│         MACRDPX channel ── external/macrdpx (submodule)   │
│        (Mac keys, pointer, scroll, stream config)         │
└─────────────────────────────────────────────────────────┘

Optional DriverKit HID extension (requires Apple Developer account):
injects keyboard/mouse at the HID level — works at login window
```

## Without an Apple Developer account

The daemon runs fully without code signing. You only need a Developer account for the optional DriverKit HID extension. See [Running without signing](docs/no-signing.md).

## License

MIT
