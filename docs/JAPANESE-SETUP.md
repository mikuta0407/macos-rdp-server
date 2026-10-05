# 日本語環境・JIS キーボードでの導入と接続

ヘッドレス運用の Mac に macos-rdp-server を入れ、Windows（mstsc）・Linux（Remmina /
FreeRDP）・Windows App（iPad / iPhone / Mac）から JIS キーボードで使うための手順です。

> 表記: ✅ = macOS 26.6 (Tahoe) の VM 上で実際に確認済み / ⚠️ = 未確認（仕様・資料からの推測）

---

## 1. ビルドとインストール（Mac 側・sudo 不要）

```bash
brew install freerdp cmake openssl pkgconf
git clone <このリポジトリ> && cd macos-rdp-server
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$(brew --prefix freerdp):$(brew --prefix openssl)"
cmake --build build
scripts/install-user.sh build/macos-rdp-daemon
```

設定は環境変数で渡します（再実行すれば書き換わります）。例:

```bash
RDP_LOG_LEVEL=verbose RDP_KEYBOARD_TYPE=auto scripts/install-user.sh build/macos-rdp-daemon
```

| 項目 | 場所 |
|---|---|
| 実行ファイル | `~/.macos-rdp/bin/macos-rdp-daemon`（固定の自己署名証明書で署名） |
| RDP 用 TLS 証明書 | `~/.macos-rdp/server.crt` / `server.key` |
| 署名用キーチェーン | `~/.macos-rdp/signing/macos-rdp.keychain-db` |
| LaunchAgent | `~/Library/LaunchAgents/com.macosrdp.agent.plist`（ラベル `com.macosrdp.agent`） |
| ログ | `~/Library/Logs/macos-rdp-agent.error.log`（本体のログはこちら）、`macos-rdp-agent.log` |

操作:

```bash
launchctl print gui/$(id -u)/com.macosrdp.agent | grep -E 'state|pid'   # 状態
launchctl kickstart -k gui/$(id -u)/com.macosrdp.agent                 # 再起動
launchctl bootout gui/$(id -u)/com.macosrdp.agent                      # 停止
tail -f ~/Library/Logs/macos-rdp-agent.error.log                       # ログ
```

**自動アップデートは既定で無効**です（`RDP_UPDATE_ENABLED=0`）。有効にすると上流
（grioghar/macos-rdp-server）のリリースバイナリで置き換えられ、ここでの JIS 対応が消えます。

### プライバシー権限（初回のみ・手動）

最初に RDP 接続したとき、Mac 側に次のダイアログが出ます。すべて許可してください。

1. **画面収録**（プライバシーとセキュリティ → 画面収録とシステムオーディオ録音）
2. **アクセシビリティ**（キー・マウスの注入）
3. **システムオーディオの録音**（音声転送。「許可」を押す）

署名が固定なので、`install-user.sh` で再ビルド版を入れ直しても権限は維持されます ✅。
システムオーディオのダイアログは RDP 画面上にも表示され、そのまま RDP 越しにクリックできます ✅
（以前はこのダイアログ待ちでセッション全体が止まり、ヘッドレスでは詰んでいました）。

---

## 2. 自動ログインと FileVault

LaunchAgent は **GUI ログイン済みのユーザーセッション内でしか動きません**。再起動後に
誰もログインしていなければ RDP は待ち受けません。

確認コマンド（読み取りのみ）:

```bash
fdesetup status                                                   # FileVault
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser  # 自動ログイン
```

- FileVault が有効だと、macOS は自動ログインを無効にします（両立しません）。
- 選択肢:
  - FileVault を切って自動ログインを使う（盗難時のリスクは上がる）。
  - FileVault を維持し、計画的な再起動は `sudo fdesetup authrestart` で行う
    （次回起動時だけディスクのロックが自動解除され、ログイン状態で上がります）。
  - ⚠️ macOS 26 では SSH から FileVault のロック解除ができるようになったとされています
    （リモートログインを有効にしている場合）。停電などの計画外の再起動に備えるなら要検証。

---

## 3. ネットワーク（Tailscale 経由で使う）

デーモンは全インターフェースの TCP 3389 で待ち受けます（`lsof -nP -iTCP:3389 -sTCP:LISTEN` で `*:3389`）。

- ルーターで 3389 をポート転送していなければ、インターネットからは届きません。
- macOS のアプリケーションファイアウォールは「アプリ単位」の許可・拒否しかできず、
  「Tailscale 側だけ許可」はできません。LAN からも塞ぎたい場合は pf を使います（要 sudo）:

```bash
# /etc/pf.anchors/macosrdp  （例: Tailscale の CGNAT 帯とローカルだけ通す）
pass in quick proto tcp from 100.64.0.0/10 to any port 3389
pass in quick proto tcp from 127.0.0.1 to any port 3389
block in quick proto tcp from any to any port 3389
```

`/etc/pf.conf` に `anchor "macosrdp"` と `load anchor "macosrdp" from "/etc/pf.anchors/macosrdp"`
を追記し、`sudo pfctl -f /etc/pf.conf && sudo pfctl -e`。確認は `sudo pfctl -sr`。

- セキュリティ層は **TLS + Mac のアカウント（パスワード）認証**です。NLA（CredSSP）は使いません。
  クライアントの「サーバー認証」警告は自己署名証明書のためで、初回に信頼すれば以後は出ません。

---

## 4. クライアントの設定

接続先は Mac の Tailscale IP（`100.x.y.z`）または MagicDNS 名、ユーザー名は Mac の
ユーザー名（`whoami` の値）、パスワードは Mac のログインパスワードです。

### Windows 11（mstsc）⚠️ 実機未確認

1. `mstsc` →「オプションの表示」
2. 全般: コンピューター = Tailscale IP、ユーザー名 = Mac のユーザー名
3. ローカルリソース:
   - リモートオーディオ →「このコンピューターで再生する」
   - キーボード →「Windows のキーの組み合わせを適用」=「リモートコンピューター上」
     （Win キー = ⌘ として送るため）
4. 接続 → 証明書の警告で「はい」（「今後このメッセージを表示しない」をチェック）

日本語 Windows の mstsc はキーボード種別「日本語 (106/109)」を通知するので、サーバーは自動で
JIS として扱います。キーの対応は §5 を参照してください。

### Linux（Remmina）⚠️ 実機未確認

1. 新規接続 → プロトコル「RDP - Remote Desktop Protocol」
2. 基本: サーバー = Tailscale IP、ユーザー名・パスワード
3. 詳細設定:
   - セキュリティプロトコルネゴシエーション: 「TLS」（または自動）
   - 音声出力モード: 「Local」
4. Remmina の設定 → RDP タブ → キーボードレイアウトを「Japanese (00000411)」
   （OS のキーボード設定が jp106 なら自動検出でも可）
5. Super キー（⌘）を送るには、接続中にキーボードのグラブを有効にする（既定: 右 Ctrl）

### Linux / Mac（FreeRDP コマンドライン）✅ 動作確認済み

```bash
xfreerdp3 /v:100.x.y.z /u:USER /cert:tofu /sec:tls /gfx /sound /kbd:layout:0x411,type:7
# Mac では sdl-freerdp でも同じオプション
```

### Windows App（iPad / iPhone / Mac）⚠️ 未確認

- 「PC を追加」→ PC 名 = Tailscale IP、ユーザーアカウントを追加
- ソフトウェアキーボードの文字は Unicode イベントで届くため、そのまま入力されます
  （Unicode 入力自体は FreeRDP で確認済み ✅）。
- 外付けの JIS キーボードで記号がずれる場合は、Mac 側で `RDP_KEYBOARD_TYPE=jis` を指定して
  `install-user.sh` を再実行してください（クライアントが US 配列を通知している可能性があります）。

---

## 5. JIS キーの対応

| PC（JIS）のキー | スキャンコード | Mac 側 | 備考 |
|---|---|---|---|
| 変換 | 0x79 | かな（kVK_JIS_Kana = 104） | ✅ |
| 無変換 | 0x7B | 英数（kVK_JIS_Eisu = 102） | ✅ |
| カタカナ/ひらがな | 0x70 | かな（104） | ✅ |
| 半角/全角 | 0x29 | 現在の入力モードを見て かな ⇄ 英数 を切り替え | ✅ `RDP_ZENKAKU_TOGGLE=0` で無効 |
| ¥ | 0x7D | kVK_JIS_Yen = 93 | ✅ `¥` / ⇧`\|` |
| ろ（\ _） | 0x73 | kVK_JIS_Underscore = 94 | ✅ `_` |
| @ [ ] : ; ^ - | 0x1A 0x1B 0x2B 0x28 0x27 0x0D 0x0C | 同じ位置の Mac キー | ✅ 刻印どおり（⇧ で `` ` { } * + ~ = ``） |
| 英数 / Caps Lock | 0x3A | Caps Lock | |
| Windows / Alt / Ctrl | | ⌘ / ⌥ / ⌃ | `RDP_SWAP_CTRL_CMD=1` で Ctrl と ⌘ を入れ替え |
| PrintScreen / ScrollLock / Pause | | F13 / F14 / F15 | Apple 拡張キーボードと同じ |
| テンキー / NumLock | | テンキー / Clear | Mac にはテンキーの NumLock がない |
| 音量・ミュート・再生 | | 音量・ミュート・再生 | ✅ |
| 変換表にないキー | | 何も送らない | ✅ verbose ログに `unmapped scan code` |

### 記号が刻印どおりになる仕組み

RDP で届くのは「キーの位置」（スキャンコード）だけです。Mac がどの文字を入力するかは、
キーイベントに付いている **キーボード種別**（ANSI=40 / ISO=41 / JIS=42）と入力ソースで決まります。
同じキーコード 33 でも ANSI なら `[`、JIS なら `@` です（`UCKeyTranslate` で確認）。
合成イベントの既定のキーボード種別は Mac に繋がっている物理キーボードに依存し、ヘッドレス機や
VM では ANSI になることがあります（検証用 VM では 198 = ANSI 系でした）。そこで、クライアントが
通知したレイアウト（0x411 = 日本語）やキーボード種別（7 = 日本語）から JIS/ANSI/ISO を判断し、
注入するイベントに明示的に設定しています。

接続時のログで判定結果を確認できます:

```
[INFO ] [input] client keyboard: layout=0x00000411 type=7 subtype=2 → Mac keyboard type 42 (JIS, detected), Hankaku/Zenkaku toggles Kana/Eisu
```

`¥` キーで `\` を入力したい場合は Mac 側の設定（キーボード → 入力ソース → 日本語 →
「"¥"キーで入力する文字」）を変更してください。これはサーバーではなく IME の設定です。

---

## 6. 実機での確認手順（Windows / Linux から）

Mac 側でデバッグログを有効にします（キー操作がすべて記録されるので、終わったら戻す）:

```bash
RDP_LOG_LEVEL=debug scripts/install-user.sh build/macos-rdp-daemon
tail -f ~/Library/Logs/macos-rdp-agent.error.log | grep -E 'client keyboard|key scan|unmapped|Hankaku'
```

接続して「テキストエディット」を開き、次を確認します。

| # | 操作 | 期待される結果 | ログ |
|---|---|---|---|
| 1 | 接続直後 | デスクトップが表示される | `virtual display created`, `GFX pipeline ready` |
| 2 | Mac で音を鳴らす（`afplay /System/Library/Sounds/Glass.aiff`） | クライアントで聞こえる | `audio playback rate negotiated` |
| 3 | ログの判定行 | `Mac keyboard type 42 (JIS, …)` | `client keyboard:` |
| 4 | `@ [ ] : ; ^ - ¥ _` と、Shift 付き | 刻印どおり | `key scan=1a … -> vk=33` など |
| 5 | 変換 → `ka` → Enter | 「か」 | `scan=79 … vk=104` |
| 6 | 無変換 → `a` | 「a」 | `scan=7b … vk=102` |
| 7 | 半角/全角を 2 回 | かな → 英数 | `Hankaku/Zenkaku -> vk=104 (Kana)` → `(Eisu)` |
| 8 | Win+C / Win+V（または `RDP_SWAP_CTRL_CMD=1` で Ctrl+C / Ctrl+V） | コピー・貼り付け | |
| 9 | ダブルクリック | 単語が選択される | |
| 10 | 変換表にないキー（例: アプリ固有の拡張キー） | 何も入力されない（「a」にならない） | `unmapped scan code` |

確認後は `RDP_LOG_LEVEL=info scripts/install-user.sh build/macos-rdp-daemon` で戻します。

### 自動テスト（Mac 側で完結）

```bash
tests/keyboard/build.sh
open build/tests/KeyLogger.app          # GUI セッションで開いておく
build/tests/rdp-keytest -u USER -p PASS 2d 1a 1b 2b 28 27 0d 7d 73 2d
cat /tmp/keylog-text.txt                # → x@[]:;^¥_x
```

`rdp-keytest` の書式はソース冒頭のコメントを参照してください。

---

## 7. うまくいかないとき

| 症状 | 確認すること |
|---|---|
| 画面が真っ黒 | 画面収録の権限。LaunchDaemon（システム全体）ではなく LaunchAgent で動いているか |
| キー・マウスが効かない | アクセシビリティの権限。ログに `Accessibility not granted` |
| 記号がずれる | ログの `client keyboard:` 行。違っていれば `RDP_KEYBOARD_TYPE=jis` |
| 修飾キーが押しっぱなしになる | クライアントにフォーカスを戻すと同期イベントで解放されます。切断時も解放 |
| 再起動後に繋がらない | GUI ログインしているか（§2） |
| 接続直後に切れる（FreeRDP） | `/sec:tls` を指定。サーバーは NLA を使いません |
