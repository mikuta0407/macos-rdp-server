## macos-rdp-server VERSION

Lightweight RDP server for macOS, with Japanese/JIS keyboard support and the Mac-to-Mac extensions (MACRDPX). Single universal binary — runs natively on Intel and Apple Silicon.

### Homebrew

    brew install mikuta0407/apps/macos-rdp-server
    macos-rdp-install-user

### One-line install

    curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/remote-install.sh | sudo bash

### Manual binary download

    sudo curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/download/VERSION/macos-rdp-daemon -o /usr/local/sbin/macos-rdp-daemon
    sudo chmod +x /usr/local/sbin/macos-rdp-daemon

### Verify checksum

    cd /usr/local/sbin && curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/download/VERSION/SHA256SUMS | shasum -c --ignore-missing

### Built with

- FreeRDP FREERDP_VER (statically linked, no runtime dependencies)
- macOS 14 SDK, universal binary (arm64 + x86_64)
