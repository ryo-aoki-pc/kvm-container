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

### Windows + WSL2

- Windows 11 (ネストした仮想化は既定で有効。無効なら `%USERPROFILE%\.wslconfig` に `[wsl2]` / `nestedVirtualization=true` を書いて `wsl --shutdown`)
- WSL 2.5.1 以降 (cgroup v2 が既定)。`wsl --version` で確認
- `modprobe` が無ければ `sudo dnf install kmod`。KVM モジュールは `kvm.sh up` が自動ロードします
- `/etc/wsl.conf` の `systemd=true` は不要 (root の podman は cgroupfs で動きます)。後述の systemd サービス化を使う場合のみ必要

### 物理マシンの AlmaLinux 10 + GNOME

- ファームウェアで SVM (AMD) / VT-x (Intel) を有効にしておく
- SELinux は Enforcing のままで構いません (`--privileged` のためラベル分離は無効)
- **GNOME にログインした状態のターミナルから** `kvm.sh` を実行してください。
  `DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` をそのままコンテナに引き継ぎます

### ディスプレイの無いホスト

```bash
COCKPIT_BIND=0.0.0.0 ./kvm.sh up
sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload
```

別 PC のブラウザで `https://<ホスト名>:9090` を開き、admin / admin でログインします。
「仮想マシン」ページ (cockpit-machines) で VM の作成とコンソール表示ができます。

## 使い方

```bash
./kvm.sh build          # イメージをビルド (localhost/qemu-kvm-cockpit:latest)
./kvm.sh up             # コンテナ起動 (kvm モジュールのロードと /dev/kvm の権限調整も行う)
./kvm.sh firefox        # コンテナ内 firefox で cockpit をホスト画面に表示 (admin / admin)
./kvm.sh demo           # デモ VM (Alpine Linux live ISO) を作成・起動して virt-viewer で表示
./kvm.sh virt-manager   # virt-manager をホスト画面に表示
./kvm.sh viewer <VM名>  # 任意の VM を virt-viewer で表示
./kvm.sh virsh list     # virsh
./kvm.sh shell          # コンテナ内 root シェル
./kvm.sh down           # コンテナ停止・削除 (VM のディスク/定義はホストの data/ に残る)
./kvm.sh clean          # コンテナと data/ のデータをすべて削除 (確認あり)
./kvm.sh install-service    # systemd --user サービス kvm-container として登録 (後述)
./kvm.sh uninstall-service  # サービスの登録解除
```

cockpit はホストのブラウザからも `https://localhost:9090` で開けます (自己署名証明書)。

環境変数:

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `wsl` / `generic` / `headless` で判定を上書き |
| `COCKPIT_BIND` / `COCKPIT_PORT` | `127.0.0.1` / `9090` | cockpit の公開アドレスとポート |
| `KVM_SOFTWARE_GL` | 未設定 | `1` でソフトウェア描画を強制 |
| `HOST_UID` / `HOST_GID` | 実行ユーザー | コンテナ内 GUI ユーザー admin の uid/gid |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_DATA_DIR` | `./data` | 永続化用のホストディレクトリ (下記) |
| `KVM_CLEAN_YES` | 未設定 | `1` で `clean` の確認を省略 |

## 構成

| ファイル | 役割 |
| --- | --- |
| `Containerfile` | AlmaLinux 10 ベース。EPEL から virt-manager を追加。systemd (`/sbin/init`) で常駐 |
| `kvm.sh` | ホスト側の操作スクリプト (`sudo podman` を使用) |
| `container/gui` | admin ユーザーとして GUI アプリを起動 (Wayland 優先、X11 フォールバック) |
| `container/gui-user-setup` + `gui-user.service` | 起動時に admin の uid/gid をホストユーザーに合わせる |
| `container/demo-vm` | Alpine ISO を取得して `virt-install` で VM を作成し virt-viewer を開く |
| `container/kvm-perms.service` | `/dev/kvm` `/dev/net/tun` `/dev/dri/renderD*` の権限調整と ip_forward 有効化 |
| `container/cockpit.conf` | cockpit-ws の設定 |

### 表示の仕組み

`kvm.sh up` は実行ユーザーのセッション環境をそのままコンテナに持ち込みます。

- `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`、WSLg なら `/mnt/wslg/runtime-dir`) を**同じパス**にマウント。
  Wayland ソケット、GNOME の Xwayland 認証ファイル、PipeWire/Pulse のソケットがここにあります
- `/tmp/.X11-unix` を **読み取り専用**でマウント (X11 フォールバック用)。読み取り専用にするのは、
  コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐためです (同じ理由で `tmpfiles.d/x11.conf` をマスク)
- `XAUTHORITY` があれば渡す。`PULSE_SERVER` は WSLg のものを渡すか、`$XDG_RUNTIME_DIR/pulse/native` を使う
- ホストの `/run/user/<uid>` は 0700 なので、コンテナ内の GUI ユーザー `admin` の uid/gid を
  `gui-user.service` が起動時にホストユーザー (`HOST_UID` / `HOST_GID`) に合わせます
- WSL、または `/dev/dri` が無いホストではソフトウェア描画 (`LIBGL_ALWAYS_SOFTWARE=1`) を使います

### 永続化 (ホストディレクトリのバインドマウント)

`KVM_DATA_DIR` (既定: リポジトリ内の `data/`、git 管理外) 配下のディレクトリをコンテナにバインドマウントします。

| ホスト | コンテナ | 内容 |
| --- | --- | --- |
| `data/var-libvirt` | `/var/lib/libvirt` | ディスクイメージ、ISO |
| `data/etc-libvirt` | `/etc/libvirt` | VM 定義、ネットワーク定義、qemu.conf |
| `data/home` | `/home/admin` | firefox プロファイル等 |

- ディレクトリが空のときは `kvm.sh up` がイメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動します
  (バインドマウントは named volume と違い、初回にイメージ側の内容をコピーしないため)
- `sudo podman` で動かすため、ファイルは root や qemu 所有になります。ホストから編集する場合は `sudo` を使ってください
- コンテナは `--privileged` (SELinux ラベル分離なし) なので、SELinux が Enforcing のホストでも `:Z` などのラベル付けは不要です
- `./kvm.sh clean` は確認のうえ `KVM_DATA_DIR` ごと削除します

## systemd サービスとして起動する (GNOME ログイン後)

`kvm.sh up` / `down` を、ログインユーザーの systemd (`systemctl --user`) から扱えるようにします。
ブート時の自動起動ではなく、GNOME にログインしたあと手動で起動する使い方を想定しています。

```bash
./kvm.sh build                  # 先にイメージを作っておく
./kvm.sh install-service        # sudo は付けない (途中でパスワードを聞かれます)
systemctl --user start kvm-container
systemctl --user status kvm-container
systemctl --user stop kvm-container   # コンテナを停止・削除 (データは data/ に残る)
journalctl --user -u kvm-container    # 起動ログ
```

- `install-service` が作るもの
  - `~/.config/systemd/user/kvm-container.service`: `ExecStart=kvm.sh up` / `ExecStop=kvm.sh down` の oneshot ユニット
  - `~/.config/kvm-container.conf`: サービス用の環境変数 (`COCKPIT_BIND` `COCKPIT_PORT` `KVM_DATA_DIR` など)。
    他 PC から cockpit を開くなら `COCKPIT_BIND=0.0.0.0` を書いて `systemctl --user restart kvm-container`
  - `/etc/sudoers.d/kvm-container`: サービス内では端末が無く sudo がパスワードを聞けないため、
    `up` / `down` に必要な `podman` `modprobe` `chmod` `mkdir` `ls` だけをパスワード無しで sudo できるようにします
    (`clean` は従来どおりパスワードを聞きます)
- ユーザーサービスは GNOME セッションの `DISPLAY` / `WAYLAND_DISPLAY` を引き継ぐので、サービスで起動したコンテナでも
  `./kvm.sh firefox` / `demo` / `viewer` によるホスト画面表示がそのまま使えます (コンテナは同じものです)
- `enable` は勧めません。ログイン直後はセッションの環境変数が取り込まれる前で、GUI 無し (headless) で上がることがあります
- 解除は `./kvm.sh uninstall-service` (サービスを停止し、ユニットと sudoers を削除。`~/.config/kvm-container.conf` は残ります)
- WSL2 で使うには `/etc/wsl.conf` に `[boot]` / `systemd=true` が必要です。ただし systemd 有効時の WSLg は
  `XDG_RUNTIME_DIR` が `/run/user/<uid>` になり中身が `/mnt/wslg` へのシンボリックリンクのため、
  サービス経由でのホスト画面表示は未検証です (主な対象は物理 AlmaLinux 10 + GNOME)

### Quadlet を使わない理由

- このコンテナは `--privileged` + `/dev/kvm` + libvirt の NAT ネットワークのため **root の podman** が必須ですが、
  GUI 表示には **ログインユーザーのセッション環境** が必要です。root の Quadlet (`/etc/containers/systemd/`) は
  システムサービスなのでセッション環境を持たず headless になり、ユーザー Quadlet (`~/.config/containers/systemd/`) は
  rootless podman になって動きません。「root で起動しつつユーザーセッションの環境を使う」は `.container` では表現できません
- `up` の前処理 (kvm モジュールのロード、`/dev/kvm` の権限調整、`data/` のシード、未ビルドなら build、libvirt/cockpit の起動待ち)
  は `[Container]` に書けず、結局 `ExecStartPre` でスクリプトを呼ぶことになります
- Wayland/X11 ソケットや `XAUTHORITY` などの GUI 用マウントはセッションごとに値が変わるため、静的な `.container` に書けません。
  `podman run` の引数を kvm.sh と `.container` の二か所で管理することにもなります

## 注意

- コンテナは `--privileged` で起動します (libvirt の default ネットワーク (NAT/dnsmasq) と KVM のため)。
- GNOME からログアウト/再ログインすると `/run/user/<uid>` が作り直されるため、`./kvm.sh down` → `./kvm.sh up` してください。
  ホスト側の `DISPLAY` 等を変えた場合も同様です。
- RHEL 10 系の qemu-kvm には SPICE がないため、グラフィックスは VNC を使っています。
- 環境変数 `NAME` は WSL がホスト名に使っているため、スクリプトのコンテナ名は `CONTAINER` で指定します。

### 物理 AlmaLinux 10 GNOME での確認手順

```bash
getenforce                                            # Enforcing のままで可
env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'      # GNOME 端末で値が入っていること
./kvm.sh up && ./kvm.sh firefox
sudo podman exec kvm ls -la /dev/dri                  # renderD* が 0666
sudo ausearch -m avc -ts recent                        # SELinux 拒否が無いこと
```
