# qemu-kvm コンテナ (AlmaLinux 10)

qemu-kvm / libvirt / cockpit / firefox / virt-viewer / virt-manager を 1 つの systemd コンテナに同梱し、
ブラウザや qemu-kvm を入れていない軽量なホストでも仮想マシンを動かして、その画面をホストのデスクトップに表示します。

対応ホスト:

| ホスト | 画面表示 |
| --- | --- |
| Windows 11 + WSL2 (AlmaLinux 10 など任意のディストリ) | WSLg 経由で Windows デスクトップに表示 |
| 物理マシン / VM の AlmaLinux 10 + GNOME | GNOME (Wayland) デスクトップに表示 |
| ディスプレイの無いホスト (SSH のみ) | cockpit の Web コンソール (noVNC) をブラウザで利用 |

## 前提

共通: podman (root で利用、`sudo` 可)。ホストにブラウザ・qemu・cockpit は不要です。

```bash
sudo dnf install podman
```

リポジトリはユーザーのホームディレクトリ配下にクローンして使います (例: `git clone ... ~/kvm-container`)。
VM のディスクや定義はその中の `data/` に置かれます。

### Windows + WSL2

- Windows 11 (ネストした仮想化は既定で有効。無効なら `%USERPROFILE%\.wslconfig` に `[wsl2]` / `nestedVirtualization=true` を書いて `wsl --shutdown`)
- WSL 2.5.1 以降 (cgroup v2 が既定)。`wsl --version` で確認
- `modprobe` が無ければ `sudo dnf install kmod`。KVM モジュールは `kvm.sh up` が自動ロードします
- `/etc/wsl.conf` の `systemd=true` は不要 (root の podman は cgroupfs で動きます)

### 物理マシンの AlmaLinux 10 + GNOME

- ファームウェアで SVM (AMD) / VT-x (Intel) を有効にしておく
- SELinux は Enforcing のままで構いません (`--privileged` のためラベル分離は無効)
- **GNOME にログインした状態のターミナルから** `kvm.sh` を実行してください。
  `DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` を元にコンテナへ表示先を渡します (仕組みは後述)

### ディスプレイの無いホスト

```bash
COCKPIT_BIND=0.0.0.0 ./kvm.sh up
sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload
```

別 PC のブラウザで `https://<ホスト名>:9090` を開き、`kvm.sh up` を実行したホストユーザーの名前とパスワードでログインします。
「仮想マシン」ページ (cockpit-machines) で VM の作成とコンソール表示ができます。

## 使い方

```bash
./kvm.sh build          # イメージをビルド (localhost/qemu-kvm-cockpit:latest)
./kvm.sh up             # コンテナ起動 (kvm モジュールのロードと /dev/kvm の権限調整も行う)
./kvm.sh firefox        # コンテナ内 firefox で cockpit をホスト画面に表示 (ホストのユーザー名・パスワードでログイン)
./kvm.sh virt-manager   # virt-manager をホスト画面に表示
./kvm.sh viewer <VM名>  # 任意の VM を virt-viewer で表示
./kvm.sh virsh list     # virsh
./kvm.sh shell          # コンテナ内 root シェル
./kvm.sh down           # コンテナ停止・削除 (VM のディスク/定義はホストの data/ に残る)
./kvm.sh clean          # コンテナと data/ のデータをすべて削除 (確認あり)
./kvm.sh install-desktop    # アクティビティ (アプリ一覧) から virt-manager / Firefox を起動できるようにする (後述)
./kvm.sh uninstall-desktop  # 上記の解除
```

cockpit はホストのブラウザからも `https://localhost:9090` で開けます (自己署名証明書)。
ログインは `kvm.sh up` を実行したホストユーザーの名前とパスワードです (コンテナ内のユーザーをホストユーザーに合わせています。後述)。

環境変数:

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `wsl` / `generic` / `headless` で判定を上書き |
| `COCKPIT_BIND` / `COCKPIT_PORT` | `127.0.0.1` / `9090` | cockpit の公開アドレスとポート |
| `KVM_SOFTWARE_GL` | 未設定 | `1` でソフトウェア描画を強制 |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_CLEAN_YES` | 未設定 | `1` で `clean` の確認を省略 |

## 構成

| ファイル | 役割 |
| --- | --- |
| `Containerfile` | AlmaLinux 10 ベース。EPEL から virt-manager を追加。systemd (`/sbin/init`) で常駐 |
| `kvm.sh` | ホスト側の操作スクリプト (`sudo podman` を使用) |
| `container/gui` | ホストユーザーと同じ名前のユーザーとして GUI アプリを起動 (Wayland 優先、X11 フォールバック)。コンテナ側の `/run/user/<uid>` と session bus を使う |
| `container/gui-user-setup` + `gui-user.service` | 起動時にコンテナ内の GUI/cockpit ユーザーをホストユーザーの名前・uid/gid・パスワードに合わせ、linger を有効にする |
| `container/kvm-perms.service` | `/dev/kvm` `/dev/net/tun` `/dev/dri/renderD*` の権限調整と ip_forward 有効化 |
| `container/cockpit.conf` | cockpit-ws の設定 |
| `desktop/kvm-virt-manager.desktop` `desktop/kvm-firefox.desktop` | アクティビティ用ランチャーのテンプレート。`kvm.sh install-desktop` が `@KVM_SH@` を埋めて `~/.local/share/applications/` に配置 |

### 表示の仕組み

`kvm.sh up` は実行ユーザーのセッション環境をそのままコンテナに持ち込みます。

- `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`。WSLg では `/run/user/<uid>` の中に `/mnt/wslg/runtime-dir` へのシンボリックリンクがあります)
  をコンテナの `/run/host-xdg-runtime` に**読み取り専用**でマウントし、Wayland ソケット・GNOME の Xwayland 認証ファイル・PipeWire/Pulse の
  ソケットは、その中を指す**絶対パス**で `WAYLAND_DISPLAY` / `XAUTHORITY` / `PULSE_SERVER` に渡します (unix ソケットへの接続は読み取り専用でも可)。
  シンボリックリンクの先が runtime dir の外にある場合 (WSLg の `/mnt/wslg/...`) は、そのソケットファイルだけを同じパスに読み取り専用でマウントします
- ホストの runtime dir をコンテナの `/run/user/<uid>` に**同じパスでマウントしてはいけません**。コンテナの logind がそのディレクトリを
  自分のものとして管理し、cockpit ログイン時にホストの session bus や `systemd --user` のソケットを作り直し、ログアウト時には
  `user-runtime-dir@.service` の停止処理で中身をすべて削除してしまいます (ホストの Wayland ソケットや session bus が消えます)
- コンテナ内の `/run/user/<uid>` は、コンテナの logind が GUI ユーザー用に作る tmpfs です。`gui-user-setup` がこのユーザーを linger に
  しているので起動時から存在し (session bus 付き)、cockpit からログアウトしても消えません。GUI アプリと cockpit-bridge はこれを使います
- `/tmp/.X11-unix` を **読み取り専用**でマウント (X11 フォールバック用)。読み取り専用にするのは、
  コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐためです (同じ理由で `tmpfiles.d/x11.conf` をマスク)
- コンテナ内の GUI/cockpit ユーザーは、起動時に `gui-user.service` が `kvm.sh up` を実行したホストユーザーの
  名前・uid/gid・パスワードハッシュに合わせます (イメージ内のテンプレートユーザー `admin` をリネーム)。
  ホストの runtime dir は 0700 なので、その中のソケットに届くには uid の一致が必要で、cockpit はコンテナ内の `/etc/shadow` で認証するため
  パスワードハッシュもコピーします。ハッシュは `podman run --env-file` で渡します (コマンドラインには出ません)。
  ホストでパスワードを変えたら `./kvm.sh down` → `./kvm.sh up` で反映されます
- WSL、または `/dev/dri` が無いホストではソフトウェア描画 (`LIBGL_ALWAYS_SOFTWARE=1`) を使います

### 永続化 (ホストディレクトリのバインドマウント)

リポジトリ内の `data/` (git 管理外) 配下のディレクトリをコンテナにバインドマウントします。

| ホスト | コンテナ | 内容 |
| --- | --- | --- |
| `data/var-libvirt` | `/var/lib/libvirt` | ディスクイメージ、ISO |
| `data/etc-libvirt` | `/etc/libvirt` | VM 定義、ネットワーク定義、qemu.conf |
| `data/home` | `/home/<ホストユーザー名>` | firefox プロファイル等 |

- ディレクトリが空のときは `kvm.sh up` がイメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動します
  (バインドマウントは named volume と違い、初回にイメージ側の内容をコピーしないため)
- `sudo podman` で動かすため、ファイルは root や qemu 所有になります。ホストから編集する場合は `sudo` を使ってください
- コンテナは `--privileged` (SELinux ラベル分離なし) なので、SELinux が Enforcing のホストでも `:Z` などのラベル付けは不要です
- `./kvm.sh clean` は確認のうえ `data/` ごと削除します

## アクティビティ (アプリ一覧) から起動する

GNOME のアクティビティで「仮想マシンマネージャー」「Firefox」を検索し、クリックで起動できるようにします
(ホストに virt-manager を直接入れたときと同じ使い勝手。デスクトップにアイコンは置きません)。

```bash
./kvm.sh build                  # 先にイメージを作っておく
./kvm.sh install-desktop        # デスクトップにログインした端末で、sudo は付けずに実行
./kvm.sh up                     # コンテナは起動しておく
```

`install-desktop` が配置するもの:

| 場所 | 内容 |
| --- | --- |
| `~/.local/share/applications/kvm-virt-manager.desktop` `kvm-firefox.desktop` | ランチャー。`Exec` は `<このリポジトリ>/kvm.sh launch <app>` (絶対パス) |
| `~/.local/share/icons/hicolor/<size>/apps/{virt-manager,firefox}.png` | イメージ内のアイコンをコピー |

- アクティビティから起動したプロセスには端末が無く sudo のパスワードを入力できないため、`kvm.sh launch` は `sudo -n podman exec kvm gui <app>` を実行します。
  実行ユーザーがパスワード無しで `sudo podman` を実行できるように、sudoers を事前に設定しておいてください
- Firefox のエントリは `./kvm.sh firefox` と同じく cockpit (`https://localhost:9090`) を開きます
- コンテナが起動していないときは、通知で `./kvm.sh up` を案内します
- 起動直後は、コンテナ内の `gui` が systemd の起動完了 (ユーザーの同期、virtqemud) を待ってからアプリを起動します
- リポジトリを移動したら `./kvm.sh install-desktop` を再実行してください (`.desktop` は絶対パスです。`TryExec` により古いパスのエントリは自動で非表示になります)
- 起動しない場合は `./kvm.sh logs` (コンテナ内 `/var/log/gui.log`) と `journalctl --user -b` を確認してください。失敗の理由はデスクトップ通知にも出ます
- WSLg は `~/.local/share/applications` の `.desktop` を Windows のスタートメニューに反映しますが、未検証です
- 解除は `./kvm.sh uninstall-desktop` (`.desktop` とアイコンを削除)

## 注意

- コンテナは `--privileged` で起動します (libvirt の default ネットワーク (NAT/dnsmasq) と KVM のため)。
- GNOME からログアウト/再ログインすると `/run/user/<uid>` が作り直されるため、`./kvm.sh down` → `./kvm.sh up` してください。
  ホスト側の `DISPLAY` 等を変えた場合も同様です。
- RHEL 10 系の qemu-kvm には SPICE がないため、グラフィックスは VNC を使っています。
- ホストユーザーにパスワードが設定されていない (ロックされている) と cockpit にログインできません。`passwd` で設定してから
  `./kvm.sh down` → `./kvm.sh up` してください (`up` 時に警告が出ます)。`kvm.sh` は root ではなく一般ユーザーで実行してください。
- コンテナ名は `kvm` 固定です (スクリプト内の変数名は `CONTAINER`。`NAME` は WSL がホスト名に使うため避けています)。

### 物理 AlmaLinux 10 GNOME での確認手順

```bash
getenforce                                            # Enforcing のままで可
env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'      # GNOME 端末で値が入っていること
./kvm.sh up && ./kvm.sh firefox
sudo podman exec kvm ls -la /dev/dri                  # renderD* が 0666
sudo ausearch -m avc -ts recent                        # SELinux 拒否が無いこと
```

### Windows + WSL2 での確認手順

```bash
./kvm.sh up && ./kvm.sh firefox                       # WSLg 経由で Windows デスクトップに Firefox (cockpit) が出ること
sudo podman exec kvm ss -xp | grep wayland            # /mnt/wslg/runtime-dir/wayland-0 に接続していること (X11 フォールバックではない)
sudo podman exec kvm findmnt /run/user/$UID           # コンテナ専用の tmpfs であること (ホストの runtime dir ではない)
ls -A /run/user/$UID && systemctl --user is-system-running   # cockpit にログイン→ログアウトした後も、ホスト側の一覧が変わらず running のままであること
```
