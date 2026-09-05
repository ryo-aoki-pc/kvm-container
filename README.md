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
./kvm.sh install-service    # root の Quadlet (kvm-container.service) として登録 (後述)
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
| `quadlet/kvm-container.container` | Quadlet のテンプレート。`kvm.sh install-service` がプレースホルダを埋めて `/etc/containers/systemd/` に配置 |
| `quadlet/user-runtime-dir.conf` | GUI ありのときにテンプレートの `[Unit]` に差し込む `Wants=` / `After=user-runtime-dir@<uid>.service` |

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

コンテナを root の Quadlet (`/etc/containers/systemd/kvm-container.container` → `kvm-container.service`) として登録し、
`sudo systemctl start / stop / status kvm-container` で扱えるようにします。
ブート時の自動起動ではなく、GNOME にログインしたあと手動で起動する使い方を想定しています。

```bash
./kvm.sh build                  # 先にイメージを作っておく
./kvm.sh install-service        # GNOME にログインした端末で、sudo は付けずに実行 (途中でパスワードを聞かれます)
sudo systemctl start kvm-container
sudo systemctl status kvm-container
sudo systemctl stop kvm-container     # コンテナを停止・削除 (データは data/ に残る)
journalctl -u kvm-container           # 起動ログ
```

- `install-service` はテンプレート `quadlet/kvm-container.container` のプレースホルダを、今のシェルの環境変数
  (`COCKPIT_BIND` `COCKPIT_PORT` `KVM_DATA_DIR` `TZ` `KVM_SOFTWARE_GL` など) とセッション環境で埋めて配置します。
  設定を変えるときは環境変数を付けて再実行します
  (例: `COCKPIT_BIND=0.0.0.0 ./kvm.sh install-service` → `sudo systemctl restart kvm-container`)
- `[Service] ExecStartPre=kvm.sh prepare` で、kvm モジュールのロード、`/dev/kvm` の権限調整、`data/` のシード、
  イメージが無ければ build を root で行います。sudoers の設定は不要です
- サービスで起動したコンテナでも `./kvm.sh firefox` / `demo` / `viewer` / `virsh` はそのまま使えます (コンテナは同じものです)。
  起動・停止は `systemctl` で行ってください (登録中は `./kvm.sh up` は案内だけ出して終了します)
- ブート時に自動起動したい場合は `.container` 末尾のコメントを外して `[Install] WantedBy=multi-user.target` を有効にします
- 解除は `./kvm.sh uninstall-service` (サービスを停止し `.container` を削除)
- WSL2 で使うには `/etc/wsl.conf` に `[boot]` / `systemd=true` が必要です。WSLg の `XDG_RUNTIME_DIR` (`/mnt/wslg/runtime-dir`)
  は常設の固定パスなのでそのまま埋め込みますが、サービス経由でのホスト画面表示は未検証です

### root の Quadlet でセッション環境 (GUI) を扱う仕組み

root のシステムサービスにはログインユーザーのセッション環境はありませんが、GNOME (Wayland) では
「ユーザーとデスクトップが決まればセッション環境はほぼ固定値」なので、登録時に値を埋めておけば動きます。

| 項目 | 値 | 備考 |
| --- | --- | --- |
| `XDG_RUNTIME_DIR` | `/run/user/<uid>` | tmpfs をバインドマウントしておけば、後から作られる Wayland / Pulse のソケットもコンテナから見える |
| `WAYLAND_DISPLAY` | `wayland-0` | GNOME は固定 |
| `DISPLAY` | `:0` | X11 はフォールバック用 |
| `PULSE_SERVER` | `unix:/run/user/<uid>/pulse/native` | 固定 |
| `HOST_UID` / `HOST_GID` | 実行ユーザーの uid/gid | 固定 |
| `XAUTHORITY` | `.mutter-Xwaylandauth.XXXXXX` | セッションごとに名前が変わるので埋めない。コンテナ内の `gui` が起動時に `$XDG_RUNTIME_DIR` から探す |

- `/run/user/<uid>` はログイン時に logind が作る tmpfs なので、`.container` に `Wants=` / `After=user-runtime-dir@<uid>.service` を付け、
  先に tmpfs ができてからコンテナを起動します (`Requires=` にはしません。ログアウトで VM ごと止まるのを避けるため)
- GNOME からログアウト/再ログインすると tmpfs が作り直されるため、対話起動と同様に `sudo systemctl restart kvm-container` が必要です
- セッション環境が無い端末 (SSH など) や `KVM_HOST=headless` で `install-service` すると、GUI 無し (cockpit のみ) の `.container` になります

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
