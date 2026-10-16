# macos-rdp-server

[English](README.md) | 日本語

macOS Tahoe 以降向けの軽量な RDP サーバー daemon です。[grioghar/macos-rdp-server](https://github.com/grioghar/macos-rdp-server) の fork で、日本語 / JIS キーボードへの対応と、Mac 同士の拡張（MACRDPX）を加えています。Windows のリモートデスクトップ、FreeRDP、Remmina など標準の RDP クライアントから、Windows 環境と同じような滑らかさで Mac に接続できます。

## 機能

- **H.264 ハードウェアエンコード**: VideoToolbox を使い、低遅延・低 CPU 負荷
- **自分の画面、または専用の画面**: 既定では画面共有と同じく、Mac のメインディスプレイを表示・操作します。`RDP_DISPLAY_MODE=virtual` にすると、セッションごとに専用の CGVirtualDisplay を作り、手元の物理画面には触れません（点灯しているディスプレイがない Mac では、常に専用の画面になります）
- **キーボードとマウスの完全な入力**: CGEventPost と RDP のスキャンコード表一式で入力します。JIS / ISO / ANSI、IME のキー、Unicode 入力に対応
- **双方向のクリップボード**: テキストと画像をクライアントとホストの間で同期
- **システム音声の転送**: Mac の音を RDP クライアントで聞けます
- **構造化ログ**: 4 段階（ERROR / INFO / VERBOSE / DEBUG）。フラグか環境変数で設定
- **DriverKit HID 拡張** *（任意。Apple Developer アカウントが必要）*: HID スタックの段階で入力するので、ログイン画面やセキュア入力欄でも動きます
- **launchd との統合**: 起動時に自動で立ち上がり、クラッシュしても再起動します
- **TLS 暗号化**: インストール時に自己署名証明書を作ります。クライアントは初回接続時に信頼します
- **クライアントのウィンドウに追従**: ディスプレイ制御（MS-RDPEDISP）で、仮想ディスプレイ、ストリーム、GFX サーフェスのサイズをその場で変えます。スケールが 150 % 以上のクライアント（Mac の Retina は 200 %）には **HiDPI** の仮想ディスプレイを用意するので、文字がクライアントの密度で描かれます。メインディスプレイを表示している場合は、サイズを変えたクライアントにディスプレイ自身の縦横比でストリームを送り、そうしたクライアントには Retina のピクセル数で送ります
- **Mac 同士の拡張（MACRDPX）**: `MACRDPX` チャネルに参加した Mac のクライアントは、キーを正確な修飾キーつきの Mac のキーとして送れます（⌘ は ⌘ のまま、Fn、左右の区別も保たれます）。ほかに、実際のクリック回数つきのポインタ、慣性つきのピクセル単位のトラックパッドスクロール、トラックパッドのジェスチャ（ピンチ、回転、スマートズーム、Dock のスワイプ）を送れ、セッション中にフレームレートとビットレートも選べます。詳しくは [docs/MAC-CLIENTS.md](docs/MAC-CLIENTS.md)（英語）を見てください。それ以外のクライアントには、これまでどおり通常の RDP で応答します

## 動作環境

- macOS 14 Sonoma 以降
- Homebrew（ソースからビルドする場合のみ。ビルド済みのバイナリは実行時の依存がありません）
- Xcode Command Line Tools（ソースからビルドする場合のみ）

## 1 行でインストール

> [!IMPORTANT]
> **画面のキャプチャには、daemon が GUI（Aqua）のログインセッションで動いている必要があります。**
> この節のコマンドで入るシステムの LaunchDaemon は WindowServer に接続できないので、
> **画面が真っ黒**になります。きちんと動き、更新しても画面収録とアクセシビリティの許可が
> 外れない構成にするには、バイナリを手に入れたあと、ユーザー単位のインストーラーを使ってください。
>
> ```bash
> scripts/install-user.sh /usr/local/sbin/macos-rdp-daemon   # バイナリのパスなら何でもよい
> ```
>
> daemon をユーザー単位の LaunchAgent として動かし（Aqua セッション → WindowServer →
> キャプチャできる）、固定の自己署名証明書で署名します。macOS は許可を、ビルドのたびに
> 変わる cdhash ではなく署名に結びつけるので、許可が外れません。sudo は不要です。

```bash
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/remote-install.sh | sudo bash
```

GitHub Releases から、ビルド済みの最新の **Apple Silicon 用**バイナリをダウンロードします。Homebrew もコンパイルも不要で、実行時の依存もありません。リンクしているのは macOS のシステムフレームワークだけです。Intel の Mac では、代わりにソースからビルドします（Homebrew がなければ入れます）。

スクリプトは次のことをします。
1. バイナリを `/usr/local/sbin/macos-rdp-daemon` にダウンロード（Intel ではビルド）
2. `/etc/macos-rdp/` に自己署名の TLS 証明書を作成
3. ポート 3389 で launchd サービスを登録して起動
4. IP アドレスと、必要な 2 つのプライバシー許可の手順を表示

バイナリを直接ダウンロードすることもできます（Apple Silicon）。
```bash
sudo curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/macos-rdp-daemon \
  -o /usr/local/sbin/macos-rdp-daemon && sudo chmod +x /usr/local/sbin/macos-rdp-daemon
```

公開されているチェックサムで検証できます。
```bash
echo "$(curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/macos-rdp-daemon.sha256)  /usr/local/sbin/macos-rdp-daemon" | shasum -a 256 -c
```

インストールしたら、RDP クライアントで Mac の IP アドレスに接続してください。

> **バイナリのビルド方法**: `master` への push のたびに、CI がソースを固定した FreeRDP の fork から
> 静的リンクでビルドし、最新のリリースとして公開します。
> [`.github/workflows/ci.yml`](.github/workflows/ci.yml) を見てください。

## 手動でインストール

```bash
# 1. 依存をインストール
brew install freerdp cmake openssl pkgconf

# 2. clone（macrdpx サブモジュールも一緒に）
git clone --recurse-submodules https://github.com/mikuta0407/macos-rdp-server.git
cd macos-rdp-server
# 既存のチェックアウトなら: git submodule update --init

# 3. ビルド
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$(brew --prefix freerdp);$(brew --prefix openssl)"
cmake --build build

# 4. ユーザー単位の LaunchAgent としてインストール（sudo 不要。上の注意を参照）
scripts/install-user.sh build/macos-rdp-daemon
```

`install-user.sh` は自動更新を既定で無効にします（`RDP_UPDATE_ENABLED=0`）。
有効だと、自分でビルドしたものが上流のリリースに置き換えられてしまうためです。
`RDP_LOG_LEVEL`、`RDP_KEYBOARD_TYPE`、`RDP_SWAP_CTRL_CMD` などの設定は、実行時に
環境変数で渡せます。日本語環境と JIS キーボードについては [docs/JAPANESE-SETUP.md](docs/JAPANESE-SETUP.md) を見てください。

## 接続

| クライアント | 手順 |
|---|---|
| Windows のリモートデスクトップ | スタート → `mstsc` → Mac の IP を入力 |
| macOS のリモートデスクトップ | App Store → Microsoft Remote Desktop → PC を追加 |
| FreeRDP（CLI） | `xfreerdp /v:your-mac-ip /u:$(whoami) /cert:ignore` |
| Remmina | 新しい接続 → プロトコル RDP → IP を入力 |

初回接続時にクライアントが証明書を信頼するか尋ねてくるので、受け入れてください。次回からは聞かれません。

## プライバシーの許可

daemon の機能は、macOS の「プライバシーとセキュリティ」で許可が必要です。

| 許可 | 必要な理由 |
|---|---|
| 画面収録 | `CGDisplayStream` による画面のキャプチャ |
| アクセシビリティ | `CGEventPost` によるキーボードとマウスの入力 |
| マイク | CoreAudio によるシステム音声の取得 |

インストーラーが該当の設定画面を自動で開きます。ヘルパーを（もう一度）実行するには:

```bash
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/grant-permissions.sh | sudo bash
```

ヘルパーがすること:
- **SIP が有効**（既定）: **画面収録**と**アクセシビリティ**の設定画面を開きます。**＋ → ⌘⇧G → `/usr/local/sbin`** と進んで `macos-rdp-daemon` を選び、スイッチをオンにしてください。（一度 RDP クライアントが接続すると、バイナリが自分でリストに載るので、スイッチを入れるだけで済みます。）
- **SIP が無効**: システムの TCC データベースに直接書き込んで両方を許可し、daemon を再起動します。クリックは不要です。

> SIP が有効な間は、どんなツールでも画面収録とアクセシビリティをプログラムから許可することはできません。それこそが TCC の目的です。このヘルパーは、OS が許す範囲で手作業をワンクリックに近づけるものです。完全に無人で許可するには [SIP の無効化](docs/no-signing.md)（英語）が必要です。

両方を有効にしたら、サービスを再起動します。
```bash
sudo launchctl kickstart -k system/com.macosrdp.daemon
```

## 設定

### ポート

`/Library/LaunchDaemons/com.macosrdp.daemon.plist` を編集します。

```bash
sudo launchctl unload /Library/LaunchDaemons/com.macosrdp.daemon.plist
# ProgramArguments に --port <n> を設定
sudo launchctl load -w /Library/LaunchDaemons/com.macosrdp.daemon.plist
```

| フラグ | 既定値 | 説明 |
|---|---|---|
| `--port` | `3389` | 待ち受ける TCP ポート |
| `--log-level` | `info` | ログの詳しさ（後述） |

ストリームとディスプレイの設定（LaunchAgent の環境変数）:

| 変数 | 既定値 | 説明 |
|---|---|---|
| `RDP_MAX_FPS` | `30` | フレームレートの上限（1〜120）。MACRDPX クライアントはセッションごとに変えられます |
| `RDP_BITRATE_KBPS` | `8000` | H.264 の目標ビットレート。同じく MACRDPX クライアントはセッションごとに変えられます |
| `RDP_DISPLAY_MODE` | `main` | `main` は Mac のメインディスプレイを表示。`virtual` はセッションごとにクライアントに合わせたサイズの専用ディスプレイを用意 |
| `RDP_HIDPI` | auto | `auto`: クライアントのスケールが 150 % 以上なら HiDPI の仮想ディスプレイ。`0`: 使わない。`1`: 常に使う |
| `RDP_DISP` | on | `0` でディスプレイ制御を無効化（デスクトップは接続時のサイズのまま） |
| `RDP_MACRDPX` | on | `0` で Mac 同士の拡張チャネルを無効化 |
| `RDP_CURSOR_SHAPES` | auto | `1` で実際のカーソル形状をすべてのクライアントに送る。`0` で送らない。MACRDPX クライアントには既定で送ります |

## ログ

daemon は 4 段階の構造化ロガーを使います。各行にはタイムスタンプ、レベル、サブシステム名が入ります。

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

### ログレベル

| レベル | 記録する内容 | 使う場面 |
|---|---|---|
| `error` | セッションや daemon が止まる致命的な失敗 | 本番運用、静かに動かしたいマシン |
| `info` | 接続の流れ（接続、有効化、切断） | 既定 |
| `verbose` | サブシステムの出来事（チャネルのオープン、ディスプレイの作成、エンコーダーや音声の開始） | 接続や機能の問題を調べるとき |
| `debug` | フレームやイベントごとの詳細（すべてのキー入力、エンコードしたフレームのサイズ、更新領域） | プロトコルを深く調べるとき |

> **注意:** `debug` はキャプチャしたフレームと入力イベントをすべて記録します。60fps なら 1 分あたり約 3,600 行になります。短時間の採取にだけ使ってください。

### ログレベルの設定

**CLI フラグ**（一度だけ、または手動で実行する場合）:
```bash
sudo macos-rdp-daemon --log-level verbose
sudo macos-rdp-daemon --log-level debug
```

**環境変数**（再起動後も有効）:
```bash
# plist を編集せずにその場で:
sudo launchctl setenv RDP_LOG_LEVEL verbose
sudo launchctl kickstart -k system/com.macosrdp.daemon

# または launchd の plist で恒久的に:
# /Library/LaunchDaemons/com.macosrdp.daemon.plist
# → EnvironmentVariables → RDP_LOG_LEVEL
```

### ログを読む

```bash
# daemon のログファイルを直接追う:
tail -f /var/log/macos-rdp-daemon.error.log

# レベルで絞り込む:
tail -f /var/log/macos-rdp-daemon.error.log | grep '\[ERROR\]'

# macOS の統合ログで（os_log の出力も見える）:
log stream --predicate 'process == "macos-rdp-daemon"' --level debug

# 過去のログはコンソール.app で:
# プロセス名 "macos-rdp-daemon" で絞り込む
```

## アンインストール

```bash
sudo bash scripts/uninstall.sh
```

## 構成

```
┌─────────────────────────────────────────────────────────┐
│                  macos-rdp-daemon (root)                 │
│                                                          │
│  TCP :3389 ──► RDPServer ──► RDPSession (per client)    │
│                                   │                      │
│              ┌────────────────────┼──────────────────┐   │
│              │                   │                   │   │
│         RDPPeer              VirtualDisplay    AudioCapture
│      (libfreerdp 3)        (CGVirtualDisplay) (CoreAudio HAL)
│              │                   │                   │   │
│         GFX Pipeline       ScreenCapture       AudioRedirect
│       (H.264 AVC420)     (CGDisplayStream)     (RDPSND ch.)
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

任意の DriverKit HID 拡張（Apple Developer アカウントが必要）:
キーボードとマウスを HID の段階で入力するので、ログイン画面でも動く
```

## Apple Developer アカウントなしで使う

daemon はコード署名なしで完全に動きます。Developer アカウントが必要なのは、任意の DriverKit HID 拡張だけです。[署名なしでの実行](docs/no-signing.md)（英語）を見てください。

## ライセンス

MIT
