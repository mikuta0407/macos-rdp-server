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
- **launchd との統合**: ユーザー単位の LaunchAgent として、ログイン時に起動し、クラッシュしても再起動します
- **TLS 暗号化**: インストール時に自己署名証明書を作ります。クライアントは初回接続時に信頼します
- **クライアントのウィンドウに追従**: ディスプレイ制御（MS-RDPEDISP）で、仮想ディスプレイ、ストリーム、GFX サーフェスのサイズをその場で変えます。スケールが 150 % 以上のクライアント（Mac の Retina は 200 %）には **HiDPI** の仮想ディスプレイを用意するので、文字がクライアントの密度で描かれます。メインディスプレイを表示している場合は、サイズを変えたクライアントにディスプレイ自身の縦横比でストリームを送り、そうしたクライアントには Retina のピクセル数で送ります
- **Mac 同士の拡張（MACRDPX）**: `MACRDPX` チャネルに参加した Mac のクライアントは、キーを正確な修飾キーつきの Mac のキーとして送れます（⌘ は ⌘ のまま、Fn、左右の区別も保たれます）。ほかに、実際のクリック回数つきのポインタ、慣性つきのピクセル単位のトラックパッドスクロール、トラックパッドのジェスチャ（ピンチ、回転、スマートズーム、Dock のスワイプ）を送れ、セッション中にフレームレートとビットレートも選べます。詳しくは [docs/MAC-CLIENTS.md](docs/MAC-CLIENTS.md)（英語）を見てください。それ以外のクライアントには、これまでどおり通常の RDP で応答します

## 動作環境

- macOS 14 Sonoma 以降
- Homebrew（Homebrew でインストールする場合と、ソースからビルドする場合。ビルド済みのバイナリは実行時の依存がありません）
- Xcode Command Line Tools（ソースからビルドする場合のみ）

## インストール

画面を使いたいユーザーで実行します（そのユーザーがログインしていれば、SSH からでも構いません）。

```bash
brew install mikuta0407/apps/macos-rdp-server
macos-rdp-install-user
```

`macos-rdp-install-user` は、daemon を `~/.macos-rdp/bin/` にコピーして固定の自己署名証明書で署名し、
RDP 用の TLS 証明書を作り、ポート 3389 で待ち受けるユーザー単位の LaunchAgent（`com.macosrdp.agent`）を
読み込みます。sudo は不要です。

設定は、実行するときに環境変数で渡します。例:

```bash
RDP_KEYBOARD_TYPE=jis RDP_PORT=3390 macos-rdp-install-user
```

そのあと、下の 2 つの許可を一度だけ与えて接続してください。

> [!IMPORTANT]
> **daemon はログイン済みの GUI セッションの中で動く必要があります。** 画面のキャプチャには、そのセッションの
> WindowServer への接続が要るためです。そのため LaunchAgent になっていて、ログインした時点で起動します。
> 誰もログインしていない間は待ち受けません。画面やキーボードをつながない Mac で使う場合は
> [ヘッドレス運用](#ヘッドレス運用) を見てください。

## プライバシーの許可

| 許可 | 必要な理由 |
|---|---|
| 画面収録（*画面収録とシステムオーディオ録音*） | 画面とシステム音声の取得 |
| アクセシビリティ | キーボードとマウスの入力 |

どちらも `~/.macos-rdp/bin/macos-rdp-daemon` に対して許可します（Homebrew が入れた方ではありません）。
許可は Mac 本体で行う必要があります。画面収録の許可がないと RDP の画面は真っ黒なので、RDP 越しには
許可できません。モニターをつなぐか、macOS の画面共有で一度つないでください。

1. RDP クライアントから一度接続します（画面はまだ真っ黒です）。Mac 側に、`macos-rdp-daemon` がコンピュータを
   制御すること・画面を収録することの確認が出るので、**システム設定を開く** を選びます。
2. **システム設定 → プライバシーとセキュリティ → アクセシビリティ** で `macos-rdp-daemon` をオンにします。
   **画面収録とシステムオーディオ録音** でも同じようにオンにします。
3. つなぎ直すと、画面が映り、キーボードとマウスが使えます。

一覧に `macos-rdp-daemon` がない場合は追加します。**＋** を押し、**⌘⇧G** で `~/.macos-rdp/bin/` と
入力して移動し（隠しフォルダですが、パスを入力すれば開けます）、`macos-rdp-daemon` を選んでオンにします。

許可は更新しても外れません。`macos-rdp-install-user` が新しいビルドを毎回同じ証明書で署名し直し、macOS は
許可をその署名に結びつけるためです。なお、macOS は約 30 日ごとに、画面の収録を続けてよいかをもう一度確認してきます。

## 起動・停止・更新

```bash
launchctl print gui/$(id -u)/com.macosrdp.agent | grep -E 'state|pid'  # 状態
launchctl kickstart -k gui/$(id -u)/com.macosrdp.agent                # 再起動
launchctl bootout gui/$(id -u)/com.macosrdp.agent                     # 停止（次のログインでまた起動）
tail -f ~/Library/Logs/macos-rdp-agent.error.log                      # ログ
```

そのユーザーで、**sudo を付けずに**実行してください。LaunchAgent はユーザーの GUI ドメインにあります。

- **設定を変える**: 新しい値を付けて `macos-rdp-install-user` をもう一度実行します。LaunchAgent を書き直して
  読み込み直します。書き込まれるのは渡した変数だけなので、既定以外の値は毎回すべて渡してください。
- **更新**: `brew upgrade macos-rdp-server` のあと、`macos-rdp-install-user` をもう一度実行します。
- **アンインストール**:

  ```bash
  launchctl bootout gui/$(id -u)/com.macosrdp.agent
  rm ~/Library/LaunchAgents/com.macosrdp.agent.plist
  security delete-keychain ~/.macos-rdp/signing/macos-rdp.keychain-db
  rm -rf ~/.macos-rdp
  brew uninstall macos-rdp-server
  ```

| 項目 | 場所 |
|---|---|
| daemon（署名済みのコピー） | `~/.macos-rdp/bin/macos-rdp-daemon` |
| RDP 用 TLS 証明書 | `~/.macos-rdp/server.crt`、`server.key` |
| 署名用キーチェーン | `~/.macos-rdp/signing/macos-rdp.keychain-db` |
| LaunchAgent | `~/Library/LaunchAgents/com.macosrdp.agent.plist` |
| ログ | `~/Library/Logs/macos-rdp-agent.error.log`（daemon のログ）、`macos-rdp-agent.log` |

## ヘッドレス運用

画面やキーボードをつながない Mac で使うには、再起動のたびにログインした状態になっている必要があるので、
自動ログインを有効にします。

1. **FileVault を切る**: FileVault が有効な間、macOS は自動ログインを無効にします。
   （再起動がすべて計画的なら FileVault を残すこともできます。`sudo fdesetup authrestart` で再起動すると、
   一度だけそのままログインした状態で起動します。ただし停電のあとは FileVault のロック解除画面で止まります。）
2. **自動ログインを有効にする**: システム設定 → ユーザとグループ → *自動ログイン*。
3. **停電のあと自動で起動する**: `sudo pmset -a autorestart 1`。
4. **インストールして許可を与える**: 上の手順どおりです。最初の許可だけは、モニターか画面共有で行います。

daemon は動いている間 Mac をスリープさせず、ディスプレイのない Mac には仮想ディスプレイを用意するので、
画面のためにほかに必要なことはありません。

この構成で手放すもの: Mac に物理的に触れられる人は、モニターがなくても USB キーボードだけで、ログイン済みの
セッションを操作できます。FileVault を切ると、ディスクはパスワードで暗号化されなくなります。ネットワーク越しの
守りは RDP のパスワードだけになるので、ポート 3389 はインターネットに直接公開せず、LAN か VPN の内側で
使ってください。また、クライアント側の証明書の確認は有効にしておき、証明書が変わったら気づけるようにしてください。

## 接続

| クライアント | 手順 |
|---|---|
| Windows のリモートデスクトップ | スタート → `mstsc` → Mac の IP を入力 |
| macOS のリモートデスクトップ | App Store → Microsoft Remote Desktop → PC を追加 |
| FreeRDP（CLI） | `xfreerdp /v:your-mac-ip /u:$(whoami) /cert:ignore` |
| Remmina | 新しい接続 → プロトコル RDP → IP を入力 |
| mRemote（iPad、iPhone、Mac） | 接続先を追加し、MACRDPX を使うため接続先を Mac に設定 |

初回接続時にクライアントが証明書を信頼するか尋ねてくるので、受け入れてください。次回からは聞かれません。

## 設定

設定は `macos-rdp-install-user` に渡す環境変数です（[起動・停止・更新](#起動停止更新) を参照）。

| 変数 | 既定値 | 説明 |
|---|---|---|
| `RDP_PORT` | `3389` | 待ち受ける TCP ポート |
| `RDP_LOG_LEVEL` | `info` | `error`、`info`、`verbose`、`debug`（後述） |
| `RDP_KEYBOARD_TYPE` | auto | `jis`、`ansi`、`iso`、`auto`。[docs/JAPANESE-SETUP.md](docs/JAPANESE-SETUP.md) を参照 |
| `RDP_MAX_FPS` | `30` | フレームレートの上限（1〜120）。MACRDPX クライアントはセッションごとに変えられます |
| `RDP_BITRATE_KBPS` | `8000` | H.264 の目標ビットレート。同じく MACRDPX クライアントはセッションごとに変えられます |
| `RDP_DISPLAY_MODE` | `main` | `main` は Mac のメインディスプレイを表示。`virtual` はセッションごとにクライアントに合わせたサイズの専用ディスプレイを用意 |
| `RDP_HIDPI` | auto | `auto`: クライアントのスケールが 150 % 以上なら HiDPI の仮想ディスプレイ。`0`: 使わない。`1`: 常に使う |
| `RDP_DISP` | on | `0` でディスプレイ制御を無効化（デスクトップは接続時のサイズのまま） |
| `RDP_MACRDPX` | on | `0` で Mac 同士の拡張チャネルを無効化 |
| `RDP_CURSOR_SHAPES` | auto | `1` で実際のカーソル形状をすべてのクライアントに送る。`0` で送らない。MACRDPX クライアントには既定で送ります |
| `RDP_UPDATE_ENABLED` | `0` | `1` で daemon が自分を最新のリリースに置き換える。Homebrew で入れた場合は無効のままにしてください |

`RDP_ZENKAKU_TOGGLE`、`RDP_SWAP_CTRL_CMD`、`RDP_AUDIO_LOCAL`、`RDP_AUDIO_INPUT`、`RDP_RDPDR_ENABLED`、
`RDP_SHARED_MODE`、`RDP_PRIVACY_BLANK`、`RDP_ALLOW_IDLE_SLEEP` も渡せます。内容は
[docs/TESTING.md](docs/TESTING.md)（英語）にあります。

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

| レベル | 記録する内容 | 使う場面 |
|---|---|---|
| `error` | セッションや daemon が止まる致命的な失敗 | 本番運用、静かに動かしたいマシン |
| `info` | 接続の流れ（接続、有効化、切断） | 既定 |
| `verbose` | サブシステムの出来事（チャネルのオープン、ディスプレイの作成、エンコーダーや音声の開始） | 接続や機能の問題を調べるとき |
| `debug` | フレームやイベントごとの詳細（すべてのキー入力、エンコードしたフレームのサイズ、更新領域） | プロトコルを深く調べるとき |

> **注意:** `debug` はキャプチャしたフレームと入力イベントをすべて記録します。60fps なら 1 分あたり約 3,600 行になります。短時間の採取にだけ使ってください。

```bash
RDP_LOG_LEVEL=verbose macos-rdp-install-user                     # レベルを変える
tail -f ~/Library/Logs/macos-rdp-agent.error.log                 # ログを追う
tail -f ~/Library/Logs/macos-rdp-agent.error.log | grep '\[ERROR\]'
log stream --predicate 'process == "macos-rdp-daemon"' --level debug   # 統合ログ
```

## ソースからビルド

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

# 4. ユーザー単位の LaunchAgent としてインストール（sudo 不要）
scripts/install-user.sh build/macos-rdp-daemon
```

`scripts/install-user.sh` は `macos-rdp-install-user` が実行しているものと同じで、同じ設定を受け付けます。
日本語環境と JIS キーボードについては [docs/JAPANESE-SETUP.md](docs/JAPANESE-SETUP.md) を見てください。

> **リリースのバイナリのビルド方法**: リリース（`v*` のタグ）ごとに、CI がソースを固定した FreeRDP と OpenSSL の
> fork から、静的リンクで 1 回で、universal バイナリとしてビルドします。ビルド時にも実行時にも、パッケージ
> マネージャーから取ってくるものはありません。[`.github/workflows/release.yml`](.github/workflows/release.yml) を見てください。

## ほかのインストール方法（システムの LaunchDaemon）

上流から引き継いだ方法です。daemon を**システムの LaunchDaemon** として入れますが、WindowServer に接続できないので
**画面が真っ黒**になります。Homebrew でのインストールを使ってください。ここで入れたバイナリを使う場合は、
LaunchDaemon の代わりに `scripts/install-user.sh /usr/local/sbin/macos-rdp-daemon` を実行してください。

```bash
# 1 行インストーラー: universal バイナリを /usr/local/sbin に、TLS 証明書を /etc/macos-rdp/ に置き、
# ポート 3389 で LaunchDaemon を登録
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/remote-install.sh | sudo bash

# バイナリだけを入れる場合と、そのチェックサムの確認
sudo curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/macos-rdp-daemon \
  -o /usr/local/sbin/macos-rdp-daemon && sudo chmod +x /usr/local/sbin/macos-rdp-daemon
cd /usr/local/sbin && curl -fsSL https://github.com/mikuta0407/macos-rdp-server/releases/latest/download/SHA256SUMS | shasum -c --ignore-missing

# 権限のヘルパー（SIP が無効なら TCC データベースに直接書き込みます）
curl -fsSL https://raw.githubusercontent.com/mikuta0407/macos-rdp-server/master/scripts/grant-permissions.sh | sudo bash

# 操作
sudo launchctl kickstart -k system/com.macosrdp.daemon     # 再起動
tail -f /var/log/macos-rdp-daemon.error.log                # ログ
sudo bash scripts/uninstall.sh                             # アンインストール
```

設定は `/Library/LaunchDaemons/com.macosrdp.daemon.plist` にあります（`ProgramArguments` の `--port`、
`EnvironmentVariables` の各変数）。

## 構成

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

任意の DriverKit HID 拡張（Apple Developer アカウントが必要）:
キーボードとマウスを HID の段階で入力するので、ログイン画面でも動く
```

## Apple Developer アカウントなしで使う

daemon はコード署名なしで完全に動きます。Developer アカウントが必要なのは、任意の DriverKit HID 拡張だけです。[署名なしでの実行](docs/no-signing.md)（英語）を見てください。

## ライセンス

MIT
