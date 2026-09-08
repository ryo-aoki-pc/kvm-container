# qemu-kvm コンテナ 仕様書

本書は、このリポジトリ (qemu-kvm / libvirt / cockpit / firefox / virt-manager を 2 つの systemd コンテナに収め、
軽量なホストで VM を動かしてその画面をホストのデスクトップに表示する仕組み) の **現状の実装 (as-built) を仕様として記述したもの**です。

| 項目 | 内容 |
| --- | --- |
| 対象コミット | `8197907` (main、PR 18「コンテナをサーバ (kvm) とデスクトップクライアント (kvm-gui) の 2 つに分割する」まで) |
| 対象読者 | 利用者 (CLI・環境変数・ポート・データの扱いを知りたい人) と保守者 (起動/停止の順序、各 unit の役割、変えてはいけない構成を知りたい人) |
| 出典 | `kvm.sh` `host/wsl.sh` `Containerfile` `container/{common,kvm,gui}/*` `desktop/*` `.gitignore`、README.md、CLAUDE.md、git の変更履歴。本書はこれらに書かれている事実のみを記述し、実装に無い振る舞いは書かない |
| 他文書との分担 | README.md = 導入手順と使い方、CLAUDE.md = 変更時の注意点、本書 = 振る舞いの定義。手順は README を参照し、本書では繰り返さない |
| 記法 | 実行時メッセージとコード内コメントは英語なので原文のまま引用する。`>> ` は進捗、`!! ` は警告/エラー (stderr)。図中の `UID` はホストユーザーの uid、`USER` はホストユーザー名、`PORT` は `COCKPIT_PORT` を表す |

目次

1. [概要](#1-概要)
2. [対応環境・前提条件](#2-対応環境前提条件)
3. [システム構成](#3-システム構成)
4. [外部インターフェース仕様](#4-外部インターフェース仕様)
5. [内部仕様 (処理シーケンス)](#5-内部仕様-処理シーケンス)
6. [設計上の不変条件](#6-設計上の不変条件)
7. [セキュリティ考慮事項](#7-セキュリティ考慮事項)
8. [既知の制限事項](#8-既知の制限事項)
9. [検証手順](#9-検証手順)
- [付録 A. ファイル一覧とコンテナ内配置](#付録-a-ファイル一覧とコンテナ内配置)
- [付録 B. 主要な変更履歴](#付録-b-主要な変更履歴)

## 1. 概要

### 1.1 目的

ブラウザも qemu も cockpit も入っていない軽量なホストに **podman だけ**を入れ、VM の実行に必要なものをコンテナに閉じ込める。
役割・権限・寿命の境界で 2 つのコンテナに分かれている。

| コンテナ | 役割 | 権限 | 寿命 |
| --- | --- | --- | --- |
| `kvm` | サーバ: libvirt + qemu-kvm + virt-install + cockpit (machines / storaged) | `--privileged --network host` | VM が動いている間は常駐 |
| `kvm-gui` | デスクトップクライアント: firefox / virt-manager / virt-viewer / virsh をホストの画面に表示 | 非特権 (`--security-opt label=disable`、`--network host`) | ディスプレイのあるホストだけ。ホストの再ログイン後はこれだけ作り直す |

`kvm-gui` は両コンテナが共有する `/run/libvirt` の unix ソケット経由で `kvm` の libvirt に接続する。ディスプレイの無いホストでは
`kvm` だけを使い、cockpit の Web コンソール (noVNC) で VM を扱う (GUI イメージのビルドも不要)。

```mermaid
flowchart LR
  subgraph hosts ["ホスト (podman だけ入れる)"]
    wsl["Windows 11 + WSL2"]
    gnome["物理 / VM の AlmaLinux 10 + GNOME"]
    headless["ディスプレイ無し (SSH のみ)"]
  end
  sh["kvm.sh (sudo podman)"]
  subgraph kvm ["コンテナ kvm (--privileged --network host)"]
    qemu["libvirt + qemu-kvm + virt-install"]
    cockpit["cockpit + cockpit-machines"]
  end
  subgraph gui ["コンテナ kvm-gui (非特権、ディスプレイのあるホストだけ)"]
    apps["firefox / virt-manager / virt-viewer / virsh"]
  end
  wsl --> sh
  gnome --> sh
  headless --> sh
  sh -->|"up (常に)"| kvm
  sh -->|"up (ディスプレイがあるとき)"| gui
  apps -->|"/run/libvirt の共有ソケット"| qemu
  apps -->|"https://localhost:9091"| cockpit
  apps -->|"Wayland / X11 ソケット (ro マウント)"| wslg["WSLg → Windows デスクトップ"]
  apps -->|"Wayland / X11 ソケット (ro マウント)"| gd["GNOME Wayland デスクトップ"]
  cockpit -->|"https://ホスト:9091"| browser["ブラウザ (別 PC など、noVNC)"]
```

図 1: 利用形態。3 種のホストはいずれも `kvm.sh` 経由で同じ `kvm` コンテナを動かし、ディスプレイがあるときだけ `kvm-gui` を足す。
画面の出口 (WSLg / GNOME / ブラウザ) だけがホスト種別で変わる。

### 1.2 スコープ外

| 項目 | 理由 (出典) |
| --- | --- |
| WSL2 でのブリッジ接続 (`KVM_BRIDGE`) | Hyper-V 仮想スイッチが WSL の vNIC 以外の MAC からのフレームを破棄する (README「Windows + WSL2 では使えません」、PR 14 の検証) |
| SPICE | RHEL 10 系の qemu-kvm に SPICE が無い。VM のグラフィックスは VNC (README「注意」) |
| cockpit の「ネットワーク」ページ | コンテナ内の NetworkManager をマスクしている (3.4 節) |
| cockpit を `kvm-gui` 側に置くこと | RHEL 系の cockpit-machines は qemu-kvm / libvirt-daemon-driver-* / libvirt-dbus を hard Requires しており、分けてもハイパーバイザ一式が付いてくる (PR 18) |
| ホストのネットワーク設定の変更 | ブリッジは利用者がホスト側で作る。`kvm.sh` はホストの NIC やブリッジを作らない |
| 自動テスト | テストスイートは無い。検証は README 末尾の確認手順を手で流す (9 章) |

### 1.3 用語

| 用語 | 意味 |
| --- | --- |
| ホスト | `kvm.sh` を実行するマシン (WSL2 ディストリ、物理/VM の AlmaLinux 10、または headless) |
| ロール | `kvm` (サーバ) と `gui` (デスクトップクライアント)。`kvm.sh` のサブコマンド `build` / `up` / `down` / `shell` / `logs` が第 1 引数として受け取る |
| コンテナ | ロール `kvm` のコンテナ名は `kvm`、ロール `gui` は `kvm-gui` (`kvm.sh` の変数 `KVM_CONTAINER` / `GUI_CONTAINER`) |
| イメージ | `localhost/kvm-container/kvm:latest` と `localhost/kvm-container/gui:latest` (`KVM_IMAGE` / `GUI_IMAGE`)。1 つの Containerfile の `--target kvm` / `--target gui` |
| ホストユーザー | `kvm.sh` を実行した一般ユーザー。`id -un` / `id -u` / `id -g` の値が `HOST_USER` / `HOST_UID` / `HOST_GID` になる |
| GUI ユーザー (= cockpit ユーザー) | 両コンテナ内でホストユーザーと同じ名前・uid/gid を持つユーザー。`kvm` ではパスワードハッシュも同じ (cockpit のログインアカウント)、`kvm-gui` ではロック |
| ホスト runtime dir | ホストの `$XDG_RUNTIME_DIR` (GNOME: `/run/user/UID`、WSLg: `/mnt/wslg/runtime-dir` への symlink を含む)。`kvm-gui` の `/run/host-xdg-runtime` に読み取り専用でマウントされる |
| コンテナ runtime dir | コンテナ内の `/run/user/UID`。コンテナの logind が GUI ユーザー用に作る (`kvm` では tmpfs、非特権の `kvm-gui` では `/run` 直下の通常のディレクトリ)。ホストとは無関係 |
| 共有 run dir | ホストの `/run/kvm-container/libvirt` (`KVM_RUN_DIR`)。両コンテナの `/run/libvirt` にバインドマウントされ、libvirt のソケットを共有する。`up` で空にし `down` で消す |
| セッション ID | `GUI_ARGS` (ホストのセッションをコンテナに渡す `podman run` 引数) の SHA-256 先頭 16 桁。`kvm-gui` のラベル `kvm.gui-session` に記録し、再ログインの検出に使う |
| ホスト種別 | `wsl` / `generic` / `headless`。`KVM_HOST` で上書きできる (2.1 節) |
| `data/` | リポジトリ直下の永続化ディレクトリ (git 管理外、root 所有)。VM のディスク・定義・GUI ユーザーのホームを保持する |

## 2. 対応環境・前提条件

### 2.1 ホスト種別と判定

```mermaid
flowchart TD
  start["KVM_HOST の値 (既定 auto)"] -->|"wsl"| W["WSL2 モード: host/wsl.sh のフック上書きを有効化"]
  start -->|"generic / headless"| G["汎用モード: 判定しない、フックは既定実装"]
  start -->|"auto"| chk{"WSL_DISTRO_NAME が設定済み、または<br/>/proc/sys/kernel/osrelease に microsoft を含む"}
  chk -->|"はい"| W
  chk -->|"いいえ"| G
  W --> hd{"have_display: KVM_HOST が headless でなく、<br/>DISPLAY か WAYLAND_DISPLAY が設定されている"}
  G --> hd
  hd -->|"いいえ"| H["kvm だけ<br/>up: >> no display found: GUI disabled, use cockpit in a browser<br/>up gui: !! no display found ... で exit 1<br/>firefox / virt-manager / viewer: !! no display found ... で exit 2"]
  hd -->|"はい"| D["kvm + kvm-gui (ホストのセッションを kvm-gui へ渡す。4.4 節)"]
```

図 2: ホスト種別の判定 (`host/wsl.sh` の `is_wsl`) と、GUI コンテナを使うかの判定 (`kvm.sh` の `have_display`)。
WSL 判定はフックの上書きだけを決め、GUI の有無は `KVM_HOST=headless` と表示用環境変数の有無で独立に決まる。

| ホスト種別 | 画面表示 | フックの上書き (`host/wsl.sh`) |
| --- | --- | --- |
| `wsl` (Windows 11 + WSL2) | WSLg 経由で Windows デスクトップ | `host_kvm_missing_hint`: `.wslconfig` の `nestedVirtualization=true` を案内。`host_default_runtime_dir`: `XDG_RUNTIME_DIR` 未設定時に `/mnt/wslg/runtime-dir` を使う。`host_force_software_gl`: 常に真 (WSL には `/dev/dri` が無い) |
| `generic` (物理/VM の AlmaLinux 10 + GNOME) | GNOME (Wayland) デスクトップ | 無し。`host_kvm_missing_hint` はファームウェアの SVM/VT-x を案内、`host_default_runtime_dir` は空、`host_force_software_gl` は `/dev/dri` が無いか `KVM_SOFTWARE_GL=1` のとき真 |
| `headless` (ディスプレイ無し) | cockpit の Web コンソール (noVNC) | 無し。`have_display` が偽になり `kvm-gui` を起動しない |

### 2.2 ホスト要件

| 要件 | 内容 | 確認・処理箇所 |
| --- | --- | --- |
| podman | root で利用 (`sudo podman`)。`kvm.sh` のすべての podman 操作は `PODMAN="sudo podman"` 経由 | `kvm.sh` |
| KVM | CPU 仮想化 (AMD SVM / Intel VT-x)。WSL2 は Windows 側のネストした仮想化。`/dev/kvm` が無ければ `modprobe kvm_amd` (`/proc/cpuinfo` に `AuthenticAMD`) または `kvm_intel` を試み、それでも無ければ `host_kvm_missing_hint` を出して exit 1 | `ensure_kvm` (`start_kvm` から) |
| `modprobe` | `/dev/kvm` が無いときに必要。無ければ `!! modprobe not found: sudo dnf install kmod` で exit 1 | `ensure_kvm` |
| WSL | 2.5.1 以降 (cgroup v2 が既定)。`/etc/wsl.conf` の `systemd=true` は不要 (root の podman は cgroupfs で動く) | README |
| デスクトップセッション (GUI を使う場合) | GNOME にログインした端末から実行する。`XDG_RUNTIME_DIR` (WSL では未設定でも可) が実在しなければ `!! XDG_RUNTIME_DIR (...) does not exist. Run this from a terminal inside a desktop session` で exit 1 | `gui_args` |
| GPU (任意) | `/dev/dri` があれば `--device /dev/dri` で `kvm-gui` に渡す。無ければソフトウェア描画 | `gui_args` |
| SELinux | Enforcing のままで可。`kvm` は `--privileged`、`kvm-gui` と seed 用コンテナは `--security-opt label=disable` で、いずれもラベル分離無し | `start_kvm` / `start_gui` / `prepare_data_dir` |
| ホストの `/run` | `/run/kvm-container/libvirt` を作れること (tmpfs 上、`sudo`) | `start_kvm` / `start_gui` |
| リポジトリの位置 | ユーザーのホーム配下にクローンする。`data/` はその中に作られる (`KVM_DATA_DIR=$PWD/data`) | `kvm.sh` |

### 2.3 実行ユーザーの要件

| 要件 | 振る舞い |
| --- | --- |
| root で実行しない | `host_user_args` が uid 0 を検出すると `!! run kvm.sh as a regular user, not root (the container user mirrors the invoking user)` で exit 1。`install-desktop` / `uninstall-desktop` も root を拒否する |
| `sudo` が使える | `podman`、`getent shadow`、`modprobe`、`chmod /dev/kvm`、`data/` と `/run/kvm-container` の操作に使う |
| パスワードが設定されている | `sudo getent shadow` のハッシュが空、`!` 始まり、`*` 始まりのいずれかなら `!! USER has no usable password on the host; cockpit login will not work until one is set (passwd), then ./kvm.sh down kvm && ./kvm.sh up` を出すが起動は続行する (cockpit にログインできないだけ) |
| `launch` (Activities から起動) を使う場合 | パスワード無しで `sudo podman` を実行できる sudoers 設定が必要 (`sudo -n` で実行するため。4.7 節) |

### 2.4 起動前に確認されるホスト資源 (`check_host_network`、`kvm` の起動時)

| 確認 | 条件 | 結果 |
| --- | --- | --- |
| ブリッジの存在 | `KVM_BRIDGE` が設定され、`/sys/class/net/$KVM_BRIDGE/bridge` が無い | `!! KVM_BRIDGE=... is not a bridge on this host. Create it first (see README: ブリッジ)` で exit 1 |
| `virbr0` の残存 | `/sys/class/net/virbr0` がある | 警告のみ (`!! virbr0 already exists on the host ...` と `sudo ip link del virbr0` の案内)。起動は続くが `default` ネットワークの起動は失敗する |
| cockpit ポートの空き | `ss` があり、`ss -H -ltn "sport = :$COCKPIT_PORT"` が何か返す | `!! port PORT is already in use on the host, so the container's cockpit cannot start.` と `COCKPIT_PORT=9092 ./kvm.sh up` の案内で exit 1 |

## 3. システム構成

### 3.1 全体構成

```mermaid
flowchart LR
  subgraph host ["ホスト"]
    direction TB
    kvmsh["kvm.sh + host/wsl.sh"]
    desktop["kvm-*.desktop (Activities)"]
    session["デスクトップセッション<br/>XDG_RUNTIME_DIR / Wayland / X11 / Pulse のソケット、/dev/dri"]
    data["data/<br/>var-libvirt / etc-libvirt / home"]
    rundir["/run/kvm-container/libvirt (tmpfs)<br/>libvirt のソケット共有"]
    hostnet["ホストのネットワーク名前空間<br/>NIC / br0 / virbr0 / cockpit の listen / VNC"]
  end
  subgraph kvm ["コンテナ kvm (--privileged --systemd=always --network host)"]
    direction TB
    kpid1["systemd (PID 1)<br/>environ にホストから渡された値"]
    kgen["generator: cockpit-listen"]
    kperms["kvm-perms.service"]
    kconf["kvm-libvirt-conf.service"]
    kuser["gui-user.service (ハッシュあり)"]
    klogind["systemd-logind → user@UID.service<br/>/run/user/UID (tmpfs)"]
    virt["virtqemud / virtnetworkd / ... (socket 起動、0660 root:libvirt)"]
    cw["cockpit-ws / cockpit-bridge / libvirt-dbus"]
    kpid1 --> kgen
    kpid1 --> kperms
    kpid1 --> kconf
    kpid1 --> kuser
    kpid1 --> klogind
    kpid1 --> virt
    kpid1 --> cw
  end
  subgraph gui ["コンテナ kvm-gui (非特権、--security-opt label=disable、--systemd=always --network host)"]
    direction TB
    gpid1["systemd (PID 1)<br/>environ にホストから渡された値、ラベル kvm.gui-session"]
    guser["gui-user.service (ハッシュ無し)"]
    glogind["systemd-logind → user@UID.service<br/>/run/user/UID (通常のディレクトリ)"]
    gapp["gui → firefox / virt-manager / virt-viewer / virsh"]
    gpid1 --> guser
    gpid1 --> glogind
    gpid1 --> gapp
  end
  desktop -->|"launch (sudo -n podman exec kvm-gui)"| kvmsh
  kvmsh -->|"podman run -e / --env-file"| kpid1
  kvmsh -->|"podman run -e / --label"| gpid1
  kvmsh -->|"podman run -v (rw)"| data
  data --- virt
  data -.-|"var-libvirt は ro、home は rw"| gapp
  rundir --- virt
  rundir --- gapp
  session -->|"-v ro、--device /dev/dri"| gapp
  gapp -.->|"connect"| session
  cw -.-|"listen"| hostnet
  virt -.-|"virbr0 / tap / nftables / VNC"| hostnet
  gapp -.->|"cockpit / VNC へ"| hostnet
```

図 3: 全体構成。ホスト → コンテナの値は `podman run` の `-e` / `--env-file` / `--label` で渡り (4.3 節)、表示用ソケットは
`kvm-gui` への読み取り専用マウントを通して connect する (4.4 節)。2 つのコンテナは `/run/libvirt` (ホストの `/run/kvm-container/libvirt`)、
`data/var-libvirt`、`data/home` を共有する (3.5 節)。ネットワーク名前空間は両方ともホストと共有なので、libvirt のブリッジも
cockpit の listen も VM の VNC もホスト上に現れ、`kvm-gui` の firefox / virt-viewer は `localhost` でそれらに届く (4.5 節)。

### 3.2 3 層構造とファイル

```mermaid
flowchart TB
  subgraph L1 ["層 1: ホスト側 (sudo podman を呼ぶだけ)"]
    kvmsh["kvm.sh"] --- wsl["host/wsl.sh (無条件に source、WSL2 のときだけフックを上書き)"]
    tmpl["desktop/kvm-virt-manager.desktop / kvm-firefox.desktop (テンプレート)"]
  end
  subgraph L2 ["層 2: イメージ (Containerfile、1 ファイルのマルチステージ)"]
    base["base: 10-minimal + shadow-utils / systemd / dbus-daemon / hostname / locale<br/>libvirt グループを gid 985 で固定、両イメージ共通の unit マスク"]
    common["common: gui-user.service / gui-user-setup (GUI ユーザーを起動時に作成)<br/>systemd-logind の unmask"]
    kvmimg["kvm (--target kvm → localhost/kvm-container/kvm)<br/>libvirt / qemu-kvm / virt-install / cockpit、sudoers、libvirtdbus を libvirt グループへ"]
    guiimg["gui (--target gui → localhost/kvm-container/gui)<br/>EPEL、firefox / virt-viewer / virt-manager / libvirt-client、フォント、video / render グループ"]
    base --> common
    common --> kvmimg
    common --> guiimg
  end
  subgraph L3 ["層 3: コンテナ内 (container/、ロールごとのディレクトリ)"]
    c1["common/gui-user-setup → /usr/local/bin/gui-user-setup<br/>common/gui-user.service → /etc/systemd/system/"]
    k1["kvm/kvm-perms.service、kvm-net-teardown.service、kvm-libvirt-conf.service → /etc/systemd/system/<br/>kvm/libvirt-conf → /usr/local/bin/libvirt-conf<br/>kvm/virtd-socket.conf → /usr/local/share/kvm-container/ → virt*d.socket.d/kvm-container.conf<br/>kvm/cockpit.conf → /etc/cockpit/cockpit.conf<br/>kvm/cockpit-listen-generator → /usr/lib/systemd/system-generators/cockpit-listen"]
    g1["gui/gui → /usr/local/bin/gui<br/>(加えて tmpfiles.d/x11.conf → /dev/null)"]
  end
  kvmsh -->|"build kvm / gui"| L2
  common -->|"COPY"| c1
  kvmimg -->|"COPY + chmod +x"| k1
  guiimg -->|"COPY + chmod +x"| g1
  kvmsh -->|"up: podman run / exec"| L3
  kvmsh -->|"install-desktop: @KVM_SH@ を絶対パスに置換"| tmpl
```

図 4: 3 層構造とマルチステージビルド。`base` と `common` は両イメージに入り、`kvm` / `gui` がそれぞれのターゲットになる。
どの層を触るかで影響範囲が変わる (ホスト側はコンテナを作り直さなくてよい、イメージと `container/` は該当ロールの `build` が必要)。

| ファイル | 層 | 入るイメージ | 役割 | 実行タイミング |
| --- | --- | --- | --- | --- |
| `kvm.sh` | ホスト | | 操作スクリプト。ホストのセッション環境とユーザー情報を `podman run` の引数に変換する | 利用者が実行 |
| `host/wsl.sh` | ホスト | | WSL2 判定と `host_*` フックの上書き | `kvm.sh` が起動直後に source |
| `desktop/kvm-*.desktop` | ホスト | | Activities 用ランチャーのテンプレート | `install-desktop` が `~/.local/share/applications/` に配置 |
| `Containerfile` | イメージ | | AlmaLinux 10 minimal + `microdnf`。`base` → `common` → `kvm` / `gui` | `build` |
| `container/common/gui-user-setup` + `gui-user.service` | コンテナ | 両方 | GUI/cockpit ユーザーをホストユーザーとして作り、linger を有効化 | 起動時 (sysinit、logind より前) |
| `container/kvm/kvm-perms.service` | コンテナ | kvm | `/dev/kvm` `/dev/net/tun` の権限と `ip_forward` | 起動時 (sysinit、virtqemud より前) |
| `container/kvm/kvm-libvirt-conf.service` + `libvirt-conf` | コンテナ | kvm | `/etc/libvirt` (= `data/etc-libvirt`) に `auth_unix_rw` と qemu.conf の設定を冪等に適用 | 起動時 (sysinit、virt*d の .socket より前) |
| `container/kvm/virtd-socket.conf` | コンテナ | kvm | `virt{qemu,network,storage,nodedev,secret}d.socket` の drop-in (`SocketMode=0660` `SocketGroup=libvirt`) | ビルド時に配置、socket 起動時に効く |
| `container/kvm/cockpit-listen-generator` | コンテナ | kvm | `COCKPIT_LISTEN` を `cockpit.socket` の `ListenStream` に反映 | 起動時 (systemd generator、unit 読み込み前) |
| `container/kvm/cockpit.conf` | コンテナ | kvm | cockpit-ws の設定 | cockpit-ws 起動時に読まれる |
| `container/kvm/kvm-net-teardown.service` | コンテナ | kvm | 停止時に libvirt ネットワークを `net-destroy` | 停止時 (`ExecStop`) |
| `container/gui/gui` | コンテナ | gui | GUI ユーザーとしてアプリをホストの画面に起動 | `kvm.sh firefox` / `virt-manager` / `viewer` / `launch` から `podman exec` |

### 3.3 コンテナ実行仕様 (`podman run`)

`start_kvm` が発行する `kvm` の `podman run` 引数 (順序も同じ):

| 引数 | 値 | 目的 |
| --- | --- | --- |
| `-d --name kvm --hostname kvm` | 固定 | コンテナ名・ホスト名 |
| `--privileged` | 固定 | KVM、libvirt、logind、ラベル分離無しのバインドマウント |
| `--systemd=always` | 固定 | `/sbin/init` を PID 1 として動かす |
| `--network host` | 固定 | VM をホストのブリッジに接続できるようにする。帰結は 4.5 節 |
| `--device /dev/kvm --device /dev/net/tun` | 固定 | VM の実行と tap デバイス |
| `-e COCKPIT_LISTEN=<COCKPIT_BIND>:<COCKPIT_PORT>` | 既定 `127.0.0.1:9091` | cockpit の listen アドレス (generator が読む) |
| `-v data/var-libvirt:/var/lib/libvirt` `-v data/etc-libvirt:/etc/libvirt` `-v data/home:/home/<HOST_USER>` | rw | 永続化 (4.6 節) |
| `-v /run/kvm-container/libvirt:/run/libvirt` | rw | libvirt ソケットの共有 (3.5 節) |
| `HOST_ARGS` | `-e HOST_USER= -e HOST_UID= -e HOST_GID=` | ホストユーザーの写し (4.3 節) |
| `HASH_ARGS` | `--env-file <mktemp>` (ハッシュが使えるときだけ) | パスワードハッシュ。`kvm` にだけ渡す |
| `-e TZ=${TZ:-Asia/Tokyo}` | 既定 `Asia/Tokyo` | コンテナのタイムゾーン |
| `--shm-size 2g` | 固定 | 共有メモリ |
| イメージ | `localhost/kvm-container/kvm:latest` | |

`start_gui` が発行する `kvm-gui` の `podman run` 引数:

| 引数 | 値 | 目的 |
| --- | --- | --- |
| `-d --name kvm-gui --hostname kvm-gui` | 固定 | コンテナ名・ホスト名 |
| `--systemd=always` | 固定 | `/sbin/init` を PID 1 として動かす。**`--privileged` は付けない** |
| `--network host` | 固定 | firefox が `localhost` の cockpit に、virt-viewer / virt-manager が VM の VNC (ホストの loopback) に届くため。listen するものは無い |
| `--security-opt label=disable` | 固定 | SELinux Enforcing のホストで、特権コンテナが作った unix ソケットへ connect し、ホストの runtime dir を読むため |
| `--label kvm.gui-session=<セッション ID>` | `GUI_ARGS` の SHA-256 先頭 16 桁 | 再ログインの検出 (5.1 節) |
| `-e COCKPIT_LISTEN=<COCKPIT_BIND>:<COCKPIT_PORT>` | 同上 | `gui` が firefox に渡す cockpit の URL のポート |
| `-v data/var-libvirt:/var/lib/libvirt:ro` | ro | virt-manager の「ローカルを参照」用 |
| `-v data/home:/home/<HOST_USER>` | rw | firefox プロファイル等 (`kvm` と同じホーム) |
| `-v /run/kvm-container/libvirt:/run/libvirt` | rw | libvirt ソケットの共有 |
| `HOST_ARGS` | `-e HOST_USER= -e HOST_UID= -e HOST_GID=` | ホストユーザーの写し (ハッシュは渡さない) |
| `GUI_ARGS` | ro マウント、`-e WAYLAND_DISPLAY/DISPLAY/XAUTHORITY/PULSE_SERVER/HOST_RUNTIME_DIR/LIBGL_ALWAYS_SOFTWARE`、`--device /dev/dri` | ホストのセッション (4.4 節) |
| `-e TZ=${TZ:-Asia/Tokyo}` `--shm-size 2g` | 同上 | |
| イメージ | `localhost/kvm-container/gui:latest` | |

### 3.4 イメージ仕様 (`Containerfile`)

| ステージ | `FROM` | 内容 |
| --- | --- | --- |
| `base` | `quay.io/almalinuxorg/10-minimal:10` | `LANG=ja_JP.UTF-8` `LC_ALL=ja_JP.UTF-8` `container=podman`。`shadow-utils` (minimal には無い) を先に入れ、`ARG LIBVIRT_GID=985` で `groupadd -r -g 985 libvirt` (パッケージが gid を割り当てる前に固定。985 はシステム範囲で、ホストユーザーの gid とは衝突しない)。続けて `systemd` (minimal には無い) `dbus-daemon` (dbus-broker の代わり) `hostname` `glibc-langpack-ja` `glibc-langpack-en`。両イメージ共通の unit マスク (図 6)。`STOPSIGNAL SIGRTMIN+3`、`CMD ["/sbin/init"]` |
| `common` | `base` | `gui-user.service` / `gui-user-setup` を配置して enable (一般ユーザーはイメージに焼き込まず、起動時に作る)。`systemd-logind.service` を unmask |
| `kvm` | `common` | `passwd` `iputils` `procps-ng` `libvirt` `libvirt-daemon-kvm` `virt-install` `cockpit` `cockpit-machines` `cockpit-storaged`。`/etc/sudoers.d/wheel-nopasswd` (0440): `%wheel ALL=(ALL) NOPASSWD: ALL`。`usermod -aG libvirt libvirtdbus`。`container/kvm/*` を配置し、`virtd-socket.conf` を 5 つの `.socket.d/kvm-container.conf` に `install`。unit を enable (図 6)。`EXPOSE 9091` |
| `gui` | `common` | `epel-release` → `firefox` `virt-viewer` `libvirt-client` `util-linux-core` (runuser / setsid) `dejavu-sans-fonts` `google-noto-sans-cjk-vf-fonts` `tar`。`virt-manager` は `epel-release` が有効にする CRB リポジトリから (無ければ `virt-manager is not available, skipping`)。`video` / `render` グループが無ければ作る (GUI ユーザーの追加は起動時に `gui-user-setup` が行う)。`gui` を配置。`/etc/tmpfiles.d/x11.conf` → `/dev/null` |

パッケージ方針は「依存で入らないものだけを、それが来るステージに列挙する」。`microdnf --setopt=install_weak_deps=0` (`False/True` は不可)。

```mermaid
flowchart LR
  subgraph base ["base (両イメージ)"]
    b1["systemd / dbus-daemon / hostname / glibc-langpack-ja, -en"]
  end
  subgraph common ["common (両イメージ)"]
    c1["shadow-utils (useradd / usermod / groupmod)"]
  end
  subgraph kvm ["kvm"]
    k1["libvirt / libvirt-daemon-kvm"]
    k2["cockpit / cockpit-machines / cockpit-storaged"]
    k3["virt-install (cockpit-machines の依存だが podman exec kvm virt-install 用に明示)"]
    k4["passwd (cockpit のパスワード画面) / iputils / procps-ng (sysctl)"]
  end
  subgraph gui ["gui"]
    g1["firefox"]
    g2["virt-viewer / libvirt-client (virsh)"]
    g3["virt-manager (EPEL、失敗許容)"]
    g4["util-linux-core (runuser / setsid) / dejavu-sans-fonts / google-noto-sans-cjk-vf-fonts / tar"]
  end
  subgraph deps ["依存で入る主なもの (明示しない)"]
    qemu["qemu-kvm / qemu-img / edk2-ovmf / swtpm / util-linux"]
    ckw["cockpit-ws / cockpit-bridge / cockpit-system"]
    dbus["libvirt-dbus / libvirt-client (kvm 側)"]
    pol["polkit / sudo / iproute / curl / xz"]
    iscsi["iscsi-initiator-utils (iscsid.socket はマスク)"]
    mesa["mesa-* (gui 側)"]
  end
  k1 --> qemu
  k1 --> iscsi
  k2 --> ckw
  k2 --> dbus
  k2 --> iscsi
  kvm --> pol
  g1 --> mesa
```

図 5: ステージごとの明示パッケージと、依存で入る主なもの (Containerfile のコメントから)。`procps-ng` は弱い依存でしか引かれないため
`kvm-perms.service` の `sysctl` 用に、`util-linux-core` は systemd の弱い依存でしかないため `gui` の `runuser` / `setsid` 用に明示している。

```mermaid
flowchart LR
  subgraph base ["base 段 (両イメージ): systemctl mask"]
    m1["systemd-udevd.service / -kernel.socket / -control.socket<br/>systemd-resolved.service"]
    m2["NetworkManager-wait-online.service<br/>podman の eth0 が online にならず 60 秒後に degraded"]
    m3["NetworkManager.service<br/>--network host でホストの NIC を管理し始める"]
    m4["iscsid.socket / iscsiuio.socket<br/>abstract unix ソケットがホストの iscsid と衝突"]
    m5["systemd-remount-fs.service の wants を削除"]
  end
  subgraph common ["common 段 (両イメージ)"]
    e0["enable: gui-user.service"]
    u1["unmask: systemd-logind.service<br/>ベースイメージがマスク済み。cockpit のログイン (pam_systemd) と<br/>/run/user/UID の session bus に必要"]
  end
  subgraph kvm ["kvm 段: systemctl enable"]
    e1["kvm-perms.service / kvm-libvirt-conf.service / kvm-net-teardown.service"]
    e2["virtqemud / virtnetworkd / virtstoraged / virtnodedevd / virtsecretd / virtlogd の .socket<br/>(virtlogd 以外は drop-in で SocketMode=0660 SocketGroup=libvirt)"]
    e3["cockpit.socket (generator が ListenStream を書き換える)"]
  end
  subgraph gui ["gui 段"]
    x1["tmpfiles.d/x11.conf → /dev/null<br/>ro マウントしたホストの /tmp/.X11-unix を systemd-tmpfiles に触らせない"]
  end
```

図 6: コンテナ内 systemd unit の状態 (ステージ別)。マスクは `base` にまとめてあるので、そのステージに入らない unit
(`gui` イメージの NetworkManager や iscsid など) に対しても無害に効く。

### 3.5 コンテナ間の libvirt 接続

```mermaid
flowchart LR
  subgraph gui ["kvm-gui (kvm とは別の pid 名前空間)"]
    app["virt-manager / virt-viewer / virsh<br/>GUI ユーザー: libvirt グループ (gid 985) の一員"]
  end
  subgraph shared ["ホストの /run/kvm-container/libvirt = 両コンテナの /run/libvirt"]
    sock["virtqemud-sock など<br/>srw-rw---- root:libvirt<br/>(virtd-socket.conf: SocketMode=0660 SocketGroup=libvirt)"]
  end
  subgraph kvm ["kvm"]
    daemon["virtqemud / virtnetworkd / virtstoraged / virtnodedevd / virtsecretd<br/>(systemd の socket 起動)"]
    conf["kvm-libvirt-conf.service → libvirt-conf<br/>virt*d.conf に auth_unix_rw = none を毎起動・冪等に書く"]
    dbus["libvirt-dbus (ユーザー libvirtdbus、libvirt グループ)<br/>← cockpit-machines"]
  end
  app -->|"connect: グループ権限で許可"| sock
  dbus -->|"connect"| sock
  sock --> daemon
  conf -.->|"/etc/libvirt/virt*d.conf、qemu.conf"| daemon
  why["別コンテナからの接続は SO_PEERCRED の pid が 0 に見える<br/>→ libvirt 既定の polkit 認証はクライアントを識別できない<br/>→ 認証は none、代わりにソケットの所有グループで制限"]
  why -.- daemon
```

図 7: `kvm-gui` から `kvm` の libvirt に届く仕組み。認証をソケットの権限に置き換え、そのために `libvirt` グループの gid を両イメージで揃えている。

| 要素 | 仕様 | 理由 |
| --- | --- | --- |
| 共有ディレクトリ | ホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナの `/run/libvirt` に rw でバインドマウント。`start_kvm` が起動前に **中身だけ** 空にし (`find -mindepth 1 -delete`)、`down` (引数なし) が `/run/kvm-container` ごと削除する | コンテナ自身の `/run` と同様に起動時は空である必要がある (前回のソケット・pid・VM 状態が残るとデーモンが混乱する)。ディレクトリ自体を消さないのは、起動中の `kvm-gui` がマウントしている inode を保つため |
| 認証方式 | `virtqemud` `virtnetworkd` `virtstoraged` `virtnodedevd` `virtsecretd` の `.conf` に `auth_unix_rw = "none"` (`libvirt-conf` が該当ファイルがあるものだけ設定) | 別 pid 名前空間からの接続では `SO_PEERCRED` の pid が 0 になり polkit が成立しない |
| ソケット権限 | `virtd-socket.conf` (drop-in `virt*d.socket.d/kvm-container.conf`): `SocketMode=0660` `SocketGroup=libvirt`。`virtlogd.socket` は対象外 | socket 起動では `/etc/libvirt/*.conf` の `unix_sock_group` / `unix_sock_rw_perms` ではなく `.socket` unit の設定が権限を決める |
| グループ | `libvirt` の gid は `base` 段で 985 に固定 (`LIBVIRT_GID`)。GUI ユーザーは `gui-user-setup` が両イメージで `libvirt` に入れる。`kvm` の `libvirtdbus` も所属 | `kvm-gui` 側のユーザーがソケットに届くには gid の一致が必要。cockpit-machines は libvirt-dbus 経由で接続する |
| qemu.conf | `libvirt-conf` が `security_driver = "none"`、`namespaces = []` を設定 | コンテナ内の qemu にゲストの SELinux ラベル付けと VM ごとのマウント名前空間は使えない |
| 適用方法 | `libvirt-conf` の `set_key`: `^#?key = ` の行があれば置換、無ければ末尾に追記。それ以外の行は触らない | `/etc/libvirt` は `data/etc-libvirt` で空のときしか seed されないため、ビルド時に書いても既存の `data/` には届かない。起動ごとの冪等適用なら旧 `data/` もそのまま使える |
| 診断 | `sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` が通ればコンテナをまたぐ接続は正常 (CLAUDE.md の回帰テスト) | |

## 4. 外部インターフェース仕様

### 4.1 CLI (`kvm.sh <サブコマンド> [ロール] ...`)

`kvm.sh` は `set -euo pipefail` で動き、最初に自分のディレクトリへ `cd` する (すべての相対パスはリポジトリ直下基準)。
`build` / `up` / `down` / `shell` / `logs` は第 1 引数が `kvm` または `gui` ならロールとして取り込む (`role_arg`)。
引数無し、または未知のサブコマンドでは `usage` (ヘッダコメントの 2 行目から最初の非コメント行の手前まで) を表示する。

| サブコマンド | 引数 | 前提 | 動作 | 終了 |
| --- | --- | --- | --- | --- |
| `build [kvm\|gui] [podman build 引数]` | ロール省略で両方 | | ロールごとに `podman build --target <role> -t localhost/kvm-container/<role>:latest -f Containerfile "$@" .` (`>> building ... (Containerfile target <role>)`) | podman の終了コード |
| `up [kvm\|gui]` | 追加引数があれば usage で 1 | 2 章の要件 | 省略: `start_kvm` → `have_display` なら `start_gui`、無ければ `>> no display found: GUI disabled, use cockpit in a browser`。`kvm`: `start_kvm` のみ。`gui`: `have_display` でなければ `!! no display found (DISPLAY / WAYLAND_DISPLAY unset, or KVM_HOST=headless): the GUI container is not needed` で 1、あれば `start_gui` のみ (5.1 節) | `kvm` の readiness が 30 秒で確認できなければ `!! could not confirm startup. Check systemctl --failed via ./kvm.sh shell` で 1 |
| `down [kvm\|gui]` | 追加引数があれば usage で 1 | | 省略: `kvm-gui` → `kvm` の順に `podman rm -f -i -t 10`、さらに `sudo rm -rf /run/kvm-container`。`kvm` / `gui`: そのコンテナだけ (共有 run dir は残す)。`data/` は残る (5.2 節) | podman の終了コード |
| `clean` | 無し | | `kvm.sh down` (両方) → `data/` が無ければ `>> ... does not exist` で 0 → 削除対象と `du -sh` を表示 → `KVM_CLEAN_YES=1` でなければ `This deletes the VM disks and definitions as well. Continue? [y/N]` を尋ね、`y`/`Y` 以外は `>> aborted` で 1 → `sudo rm -rf data/` | 上記 |
| `firefox` / `virt-manager` | 追加引数 (アプリへ渡す) | ディスプレイ | `have_display` でなければ `!! no display found: use cockpit in a browser (https://BIND:PORT)` で 2。`kvm.sh up` (足りないものを起動し、再ログイン後は `kvm-gui` を作り直す) → `podman exec kvm-gui gui <cmd> "$@"` | `gui` の終了コード |
| `viewer <VM名>` | VM 名 (virt-viewer の引数) | 同上 | 同上。`viewer` を `virt-viewer` に読み替えて `gui virt-viewer <VM名>` | 同上 |
| `virsh ...` | virsh の引数 | `kvm` 起動中 | `podman exec -it kvm virsh -c qemu:///system "$@"` | virsh の終了コード |
| `shell [kvm\|gui]` | ロール省略で `kvm` | 起動中 | `podman exec -it <container> bash` | bash の終了コード |
| `logs [kvm\|gui]` | ロール省略で両方 | | `kvm`: 起動中なら `journalctl --no-pager -n 30 -u kvm-libvirt-conf -u virtqemud -u cockpit.socket -u gui-user`、でなければ `>> kvm is not running`。`gui`: 起動中なら `/var/log/gui.log` 末尾 50 行 + `journalctl -n 30 -u gui-user`、でなければ `>> kvm-gui is not running` | |
| `launch <app>` | `firefox` または `virt-manager` | `.desktop` から呼ばれる。podman の NOPASSWD sudo | `sudo -n podman exec kvm-gui gui <app>` を実行し、失敗をデスクトップ通知にする (4.7 節)。他の引数は usage を出して 1 | 成功 0 / 失敗 1 |
| `install-desktop` | 無し | root 以外、デスクトップにログインしたユーザー | `gui` イメージが無ければ `build gui`。アイコン抽出と `.desktop` 配置 (4.7 節) | 0 |
| `uninstall-desktop` | 無し | root 以外 | `.desktop` とアイコンを削除 | 0 |

### 4.2 環境変数 (ホスト側の入力)

`kvm.sh` が利用者から受け取る変数:

| 変数 | 既定 | 意味 | 読む場所 |
| --- | --- | --- | --- |
| `KVM_HOST` | `auto` | ホスト種別の上書き (`wsl` / `generic` / `headless`)。`headless` は `have_display` を偽にする | `host/wsl.sh` `is_wsl`、`have_display` |
| `COCKPIT_BIND` | `127.0.0.1` | cockpit の bind アドレス。`0.0.0.0` / `::` で他 PC から到達可 | `COCKPIT_LISTEN` の組み立て (両コンテナ)、ready メッセージ |
| `COCKPIT_PORT` | `9091` | cockpit のポート。9090 でないのはホスト自身の cockpit と衝突するため | 同上、`check_host_network` |
| `KVM_BRIDGE` | 未設定 | ホストの既存ブリッジ名。libvirt ネットワーク `bridged` として登録する。未設定なら `bridged` を削除 | `check_host_network`、`sync_bridged_network` |
| `KVM_SOFTWARE_GL` | 未設定 | `1` でソフトウェア描画を強制 (`LIBGL_ALWAYS_SOFTWARE=1`) | `host_force_software_gl` |
| `TZ` | `Asia/Tokyo` | 両コンテナのタイムゾーン | `podman run -e TZ` |
| `KVM_CLEAN_YES` | 未設定 | `1` で `clean` の確認を省略 | `clean` |

セッションから読む変数 (`have_display` が真のとき、`gui_args`):

| 変数 | 用途 |
| --- | --- |
| `XDG_RUNTIME_DIR` | ホスト runtime dir。未設定なら `host_default_runtime_dir` (WSL: `/mnt/wslg/runtime-dir`、それ以外: 空 → エラー) |
| `WAYLAND_DISPLAY` | Wayland ソケット。相対名は runtime dir 基準。ソケットでなければ警告して Wayland を無効化 |
| `DISPLAY` | X11。設定されていれば `/tmp/.X11-unix` (realpath) を ro マウントする |
| `XAUTHORITY` | 設定されていて読めれば、コンテナ内パスに変換して渡す |
| `PULSE_SERVER` | 未設定なら `$XDG_RUNTIME_DIR/pulse/native` がソケットのときに `unix:` 形式で補う。`unix:` 以外はそのまま渡す。ソケットでなければ `audio disabled` |
| `XDG_DATA_HOME` / `HOME` | `install-desktop` の配置先 (`${XDG_DATA_HOME:-$HOME/.local/share}`) |
| `WSL_DISTRO_NAME` | WSL2 判定 |

### 4.3 ホスト → コンテナの値の受け渡し

コンテナ内のスクリプトは、`podman run` で渡された値を **PID 1 (systemd) の環境** から `tr` で NUL を改行に変換して
`/proc/1/environ` を読むことで取得する。`podman exec` で起動するプロセス (`gui`) には同じ値が環境変数として継承される。

```mermaid
flowchart LR
  subgraph src ["kvm.sh (ホスト)"]
    id["id -un / -u / -g"] --> ha["HOST_ARGS: -e HOST_USER, HOST_UID, HOST_GID"]
    shadow["sudo getent shadow USER"] --> envf["mktemp に HOST_PASSWORD_HASH= を書く<br/>(EXIT trap で削除)"] --> hash["HASH_ARGS: --env-file"]
    cb["COCKPIT_BIND + COCKPIT_PORT"] --> cl["-e COCKPIT_LISTEN=bind:port"]
    sess["WAYLAND_DISPLAY / DISPLAY / XAUTHORITY / PULSE_SERVER、/dev/dri"] --> map["map_rt_path / add_ro_mount"] --> ga["GUI_ARGS: -e (コンテナ内の絶対パス)、-v ...:ro、--device /dev/dri<br/>-e HOST_RUNTIME_DIR、LIBGL_ALWAYS_SOFTWARE"]
    ga --> label["sha256 の先頭 16 桁 → --label kvm.gui-session"]
    tz["TZ"] --> tzarg["-e TZ"]
  end
  kenv["kvm: PID 1 の environ"]
  genv["kvm-gui: PID 1 の environ"]
  ha --> kenv
  ha --> genv
  hash --> kenv
  cl --> kenv
  cl --> genv
  ga --> genv
  tzarg --> kenv
  tzarg --> genv
  kenv -->|"HOST_USER / HOST_UID / HOST_GID / HOST_PASSWORD_HASH"| kgus["gui-user-setup (kvm): ユーザー作成 + ハッシュ設定"]
  kenv -->|"COCKPIT_LISTEN"| gen["generator: cockpit-listen"]
  genv -->|"HOST_USER / HOST_UID / HOST_GID (ハッシュ無し)"| ggus["gui-user-setup (kvm-gui): ユーザー作成 + ロック"]
  genv -->|"HOST_USER、COCKPIT_LISTEN のポート"| gui["gui"]
  genv -->|"WAYLAND_DISPLAY / DISPLAY / XAUTHORITY / PULSE_SERVER / LIBGL_ALWAYS_SOFTWARE<br/>(podman exec が環境変数として継承)"| gui
  gui -->|"unset HOST_PASSWORD_HASH HOST_USER HOST_UID HOST_GID"| app["runuser → GUI アプリ"]
```

図 8: 値の流れ。ユーザー情報 (`HOST_ARGS`) と `COCKPIT_LISTEN` は両コンテナに、パスワードハッシュ (`HASH_ARGS`) は `kvm` にだけ、
セッション情報 (`GUI_ARGS`) は `kvm-gui` にだけ渡る。`host_user_args` は一度組み立てたら再実行しない (`up` で両コンテナを起動しても
`getent shadow` は 1 回)。

| 変数 | 渡し方 | 渡す先 | 値 | 読む側 |
| --- | --- | --- | --- | --- |
| `HOST_USER` `HOST_UID` `HOST_GID` | `-e` | 両方 | `id -un` / `id -u` / `id -g` | `gui-user-setup` (全部)、`gui` (`HOST_USER`) |
| `HOST_PASSWORD_HASH` | `--env-file` (mktemp、EXIT trap で削除) | `kvm` のみ | `sudo getent shadow` の第 2 フィールド。使えないハッシュのときは渡さない | `gui-user-setup` (kvm) |
| `COCKPIT_LISTEN` | `-e` | 両方 | `<COCKPIT_BIND>:<COCKPIT_PORT>` | `cockpit-listen-generator` (kvm)、`gui` (firefox の URL 用にポート部分) |
| `HOST_RUNTIME_DIR` | `-e` | `kvm-gui` | `/run/host-xdg-runtime` | `gui` (Xauthority の探索) |
| `WAYLAND_DISPLAY` `DISPLAY` `XAUTHORITY` `PULSE_SERVER` | `-e` (存在するものだけ) | `kvm-gui` | コンテナ内から見た絶対パス (`PULSE_SERVER` は `unix:` 付き、`DISPLAY` はホストの値そのまま) | `gui` → GUI アプリ。`gui_session_matches` も参照する |
| `LIBGL_ALWAYS_SOFTWARE` | `-e` (条件付き) | `kvm-gui` | `1` (`host_force_software_gl` が真のとき) | `gui` → GUI アプリ |
| `kvm.gui-session` | `--label` | `kvm-gui` | `GUI_ARGS` の各要素を改行区切りで `sha256sum` した先頭 16 桁 | `gui_session_matches` (`podman inspect`) |
| `TZ` | `-e` | 両方 | `${TZ:-Asia/Tokyo}` | コンテナ全体 |

新しい値を渡すときもこの流儀 (`-e` で渡し、PID 1 の environ から読む) に合わせる。

### 4.4 マウント仕様と表示の仕組み

```mermaid
flowchart LR
  subgraph h ["ホスト"]
    d1["data/var-libvirt"]
    d2["data/etc-libvirt"]
    d3["data/home"]
    rl["/run/kvm-container/libvirt<br/>(tmpfs。up で空にし、down で削除)"]
    rt["$XDG_RUNTIME_DIR<br/>GNOME: /run/user/UID、WSLg: /mnt/wslg/runtime-dir"]
    wlout["runtime dir の外にあるソケット<br/>(WSLg: /run/user/UID/wayland-0 → /mnt/wslg/runtime-dir/wayland-0)"]
    x11["/tmp/.X11-unix (readlink -f 後)"]
    xauth["XAUTHORITY (runtime dir の外にあるとき)"]
    dri["/dev/dri (あれば)"]
  end
  subgraph k ["kvm"]
    k1["/var/lib/libvirt (rw)"]
    k2["/etc/libvirt (rw)"]
    k3["/home/USER (rw)"]
    k4["/run/libvirt (rw)"]
    ku["/run/user/UID (logind の tmpfs、ホストとは無関係)"]
  end
  subgraph g ["kvm-gui"]
    g1["/var/lib/libvirt (ro)"]
    g3["/home/USER (rw)"]
    g4["/run/libvirt (rw)"]
    crt["/run/host-xdg-runtime (ro)"]
    cwl["ホストと同じパス (ro、ソケットファイル単位)"]
    cx11["/tmp/.X11-unix (ro)"]
    cxa["ホストと同じパス (ro)"]
    cdri["/dev/dri (--device)"]
    gu["/run/user/UID (logind。非特権なので通常のディレクトリ)"]
  end
  d1 -->|"-v rw"| k1
  d1 -->|"-v ro"| g1
  d2 -->|"-v rw"| k2
  d3 -->|"-v rw"| k3
  d3 -->|"-v rw"| g3
  rl -->|"-v rw"| k4
  rl -->|"-v rw"| g4
  rt -->|"-v ro"| crt
  wlout -->|"add_ro_mount"| cwl
  x11 -->|"-v ro"| cx11
  xauth -->|"-v ro"| cxa
  dri -->|"--device"| cdri
  rt -.->|"✗ 禁止: ここには絶対にマウントしない"| gu
```

図 9: ホストのパスとコンテナ内パスの対応。ホストのセッション資源は `kvm-gui` にだけ、読み取り専用で入る。ホストの runtime dir は
別パスにマウントし、コンテナの `/run/user/UID` はコンテナの logind のものにする。この 2 つを混ぜないことが最重要の不変条件 (6 章)。

| ホスト | コンテナ | モード | 条件 | 目的 |
| --- | --- | --- | --- | --- |
| `data/var-libvirt` | `kvm` `/var/lib/libvirt` | rw | 常に | ディスクイメージ、ISO |
| `data/var-libvirt` | `kvm-gui` `/var/lib/libvirt` | ro | GUI 有効 | virt-manager の「ローカルを参照」用 |
| `data/etc-libvirt` | `kvm` `/etc/libvirt` | rw | 常に | VM 定義、ネットワーク定義、libvirt の設定 (`kvm-gui` には無い) |
| `data/home` | 両方 `/home/<HOST_USER>` | rw | 常に | firefox プロファイル等。1 つのホームを両方で使う |
| `/run/kvm-container/libvirt` | 両方 `/run/libvirt` | rw | 常に | libvirt のソケット共有 (3.5 節) |
| `$XDG_RUNTIME_DIR` | `kvm-gui` `/run/host-xdg-runtime` | ro | GUI 有効 | Wayland / Xwayland 認証 / Pulse のソケットに届くため。unix ソケットは ro でも connect できる |
| `readlink -f /tmp/.X11-unix` | `kvm-gui` `/tmp/.X11-unix` | ro | `DISPLAY` 設定時 | X11 フォールバック。ro にするのは systemd-tmpfiles にホストの X ソケットを消させないため |
| runtime dir 外のソケット (Wayland / Pulse) | `kvm-gui` 同じパス | ro | `map_rt_path` が失敗したとき | ソケットファイルだけをマウントする。親ディレクトリ (`/tmp` や `$HOME`) はマウントしない (コンテナ側のディレクトリを隠すため) |
| runtime dir 外の `XAUTHORITY` | `kvm-gui` 同じパス | ro | 同上 | `add_ro_mount` を通さず直接 `-v` (重複チェック無し) |
| `/dev/dri` | `kvm-gui` `/dev/dri` | `--device` | ホストに `/dev/dri` がある | GPU の render node。非特権なので明示的に渡す。`gui` が `renderD*` を 0666 にする |

```mermaid
flowchart TD
  in["入力 p (例: wayland-0、/run/user/1000/pulse/native、XAUTHORITY)"] --> rel{"絶対パスか"}
  rel -->|"いいえ"| pre["HOST_RT/p を前置する"] --> rl
  rel -->|"はい"| rl["readlink -f で実体パスに解決 (失敗時は p のまま)"]
  rl --> under{"実体が HOST_RT の配下か"}
  under -->|"はい"| ok["/run/host-xdg-runtime/相対部分 を出力して return 0"]
  under -->|"いいえ"| ng["実体パスをそのまま出力して return 1"]
  ng --> which{"呼び出し元"}
  which -->|"WAYLAND_DISPLAY / PULSE_SERVER"| aro["add_ro_mount path"]
  which -->|"XAUTHORITY"| direct["-v path:path:ro を直接追加"]
  aro --> dup{"RO_MOUNTS に同じパス、または親がある"}
  dup -->|"はい"| skip["追加しない"]
  dup -->|"いいえ"| add["RO_MOUNTS に記録し -v path:path:ro を追加"]
```

図 10: `map_rt_path` の変換規則と、runtime dir 外だったときの処理。WSLg の `/run/user/UID/wayland-0` は
`/mnt/wslg/runtime-dir/wayland-0` への symlink なので後者の経路を通る。

`gui_args` の出力 (`kvm-gui` の環境変数として `gui` に届く値):

| 条件 | 環境変数 / 引数 | 値 |
| --- | --- | --- |
| GUI 有効 | `HOST_RUNTIME_DIR` | `/run/host-xdg-runtime` |
| `WAYLAND_DISPLAY` がソケット | `WAYLAND_DISPLAY` | 絶対パス (libwayland 1.15 以降が受け付ける)。ソケットでなければ `!! WAYLAND_DISPLAY=... is not a socket (...); Wayland disabled, X11 is used if DISPLAY is set` |
| `DISPLAY` 設定、`/tmp/.X11-unix` がディレクトリ | `DISPLAY` | ホストの値そのまま |
| 上に加えて `XAUTHORITY` が読める | `XAUTHORITY` | 変換後のパス |
| Pulse ソケットあり | `PULSE_SERVER` | `unix:<変換後のパス>`。`unix:` 以外の値は無変換 |
| `/dev/dri` がある | `--device /dev/dri` | |
| `host_force_software_gl` が真 | `LIBGL_ALWAYS_SOFTWARE` | `1` |

### 4.5 ネットワークとポート

```mermaid
flowchart LR
  subgraph ns ["ホストのネットワーク名前空間 (kvm と kvm-gui が共有: --network host)"]
    nic["物理 NIC (例 enp1s0)"]
    br0["br0 (利用者が nmcli 等で作成、IP を持つ)"]
    virbr0["virbr0 192.168.122.1/24<br/>libvirt default (NAT) + dnsmasq + nftables (kvm が作る)"]
    hcock["ホスト自身の cockpit-ws :9090 (AlmaLinux 10 では有効なことが多い)"]
    ccock["kvm の cockpit-ws<br/>COCKPIT_BIND:COCKPIT_PORT (既定 127.0.0.1:9091)"]
    vnc["qemu の VNC (ホストの loopback で listen)"]
    ipf["net.ipv4.ip_forward=1 (kvm-perms.service が設定)"]
    gapps["kvm-gui の firefox / virt-viewer / virt-manager (listen するものは無い)"]
  end
  subgraph vms ["VM (qemu-kvm、tap デバイス)"]
    vmA["network=default の VM"]
    vmB["network=bridged の VM"]
  end
  lan["LAN / DHCP"] --- nic
  nic --- br0
  vmA --- virbr0
  vmB --- br0
  virbr0 -->|"NAT (nftables)"| nic
  gapps -->|"https://localhost:PORT"| ccock
  gapps -->|"VNC"| vnc
  browser["別 PC のブラウザ (COCKPIT_BIND=0.0.0.0 のとき)"] -->|"https"| ccock
```

図 11: ネットワーク。コンテナ専用の名前空間は無く、libvirt が作るもの (virbr0、dnsmasq、nftables) も cockpit の listen も VM の VNC も
ホスト上に現れる。`kvm-gui` も同じ名前空間なので firefox は `localhost` の cockpit に、virt-viewer は VNC に届く。

| 項目 | 仕様 |
| --- | --- |
| cockpit の listen | `COCKPIT_LISTEN` から generator が `cockpit.socket` の `ListenStream=` を書き換える。bare な IPv6 リテラル (`::`) は `[::]` に整形する。既定 (未指定時) は `127.0.0.1:9091` |
| ポート 9091 の理由 | AlmaLinux 10 のホストは自前の `cockpit.socket` が 9090 を使っていることが多く、`--network host` では衝突する。`check_host_network` が使用中のポートを検出して中止する |
| 外部公開 | `COCKPIT_BIND=0.0.0.0` (または `::`) のとき ready メッセージが `https://$(uname -n):PORT` と `sudo firewall-cmd --add-port=PORT/tcp --permanent && sudo firewall-cmd --reload` を案内する (firewalld の `cockpit` サービスは 9090 固定なので使えない) |
| `default` ネットワーク | libvirt 標準の NAT (`virbr0`、192.168.122.0/24)。ホストで libvirt が動いていると衝突する (`virbr0` 検出で警告) |
| `bridged` ネットワーク | `KVM_BRIDGE` 指定時に `sync_bridged_network` が define/autostart/start する (5.7 節)。定義は `data/etc-libvirt` に永続化され、`KVM_BRIDGE` 無しで `up` すると削除される |
| ip_forward | `kvm-perms.service` が `net.ipv4.ip_forward=1` をホストの名前空間に設定する |
| `kvm-gui` | `--network host` だが listen するものは無く、ホストと衝突するポートやソケットは無い |
| 停止時 | `kvm-net-teardown.service` が全ネットワークを `net-destroy` し、残った `virbr*` を `ip link del` する (5.2 節) |

### 4.6 永続化データ (`data/`) と共有 run dir

```mermaid
flowchart TD
  s["start_kvm"] --> pd["prepare_data_dir x3 (var-libvirt / etc-libvirt / home)"]
  pd --> mk["sudo mkdir -p dir"] --> empty{"dir は空か (sudo ls -A)"}
  empty -->|"いいえ"| keep["そのまま使う (既存の VM 定義・ディスク・home を維持)"]
  empty -->|"はい"| seed[">> seeding dir from image src<br/>podman run --rm --network none --security-opt label=disable -v dir:/mnt/seed KVM_IMAGE cp -a src/. /mnt/seed/"]
  keep --> rd
  seed --> rd["sudo mkdir -p /run/kvm-container/libvirt && find -mindepth 1 -delete<br/>(中身だけ消す: 起動中の kvm-gui が見ている inode を保つ)"]
  rd --> run["podman run kvm (-v data/*、-v /run/kvm-container/libvirt:/run/libvirt)"]
  run --> conf["kvm-libvirt-conf.service: /etc/libvirt に auth_unix_rw と qemu.conf の設定を冪等適用"]
  down["kvm.sh down (引数なし)"] --> rm["sudo rm -rf /run/kvm-container (data/ は残す)"]
```

図 12: `data/` の初期化と共有 run dir の寿命。バインドマウントは named volume と違い初回にイメージ側の内容をコピーしないので、
空のときだけ `kvm` イメージの一時コンテナで `cp -a` する。seed 元は `/var/lib/libvirt` `/etc/libvirt` `/etc/skel` (ホームの雛形)。

| 項目 | 仕様 |
| --- | --- |
| 場所 | `<リポジトリ>/data/` (`KVM_DATA_DIR=$PWD/data`)。`.gitignore` で `data/` `*.iso` `*.qcow2` `build.log` を除外 |
| 所有者 | `sudo podman` で動くため root や qemu 所有。ホストから読み書きするには `sudo` が必要 |
| SELinux | どちらのコンテナもラベル分離無し (`kvm` は `--privileged`、`kvm-gui` は `label=disable`) なので `:Z` 等は不要。seed コンテナは `container_t` のままだと `user_home_t` の `data/` に書けないため `--security-opt label=disable` を付ける |
| `data/home` | 両コンテナの `/home/<HOST_USER>` にマウントされ、それぞれの `gui-user-setup` が `chown -R HOST_UID:HOST_GID` する |
| `data/etc-libvirt` | seed は空のときだけ。libvirt の認証設定と qemu.conf は `kvm-libvirt-conf.service` が起動ごとに上書きする (3.5 節) |
| `/run/kvm-container` | 永続化しない。`start_kvm` が `libvirt/` の中身を空にし、`start_gui` も `mkdir -p` する。`down` (引数なし) で削除 |
| 削除 | `data/` は `clean` のみ (`down` では残る)。パスワード変更の反映は `down kvm` → `up` |

### 4.7 デスクトップ統合 (Activities からの起動)

```mermaid
sequenceDiagram
  participant S as GNOME Shell (Activities)
  participant D as kvm-firefox.desktop / kvm-virt-manager.desktop
  participant K as kvm.sh launch app
  participant P as sudo -n podman exec kvm-gui
  participant G as gui (kvm-gui 内)
  participant N as 通知 (notify-send、無ければ zenity、無ければ stderr のみ)
  S->>D: 起動 (TryExec で kvm.sh の存在を確認、無ければ非表示)
  D->>K: Exec = kvm.sh (絶対パス) launch firefox または virt-manager
  K->>P: gui app (stderr を err に取り込む)
  alt sudo がパスワードを要求 (err に password を含む)
    P-->>K: 失敗
    K->>N: could not start app ... configure passwordless sudo for podman (launch runs sudo -n without a terminal)
  else それ以外の失敗 (kvm-gui 未起動など)
    P-->>K: 失敗
    K->>N: could not start app ... check that the GUI container is running (./kvm.sh up)
  else 成功
    P->>G: podman exec kvm-gui gui app
    G->>G: systemd の起動完了と user@UID.service を待つ (5.3 節)
    G-->>S: アプリのウィンドウ (setsid で切り離し、出力は /var/log/gui.log)
  end
```

図 13: `.desktop` からの起動経路。端末が無く sudo のパスワードを入力できないため `sudo -n` を使い、失敗理由はデスクトップ通知で伝える。
`launch` は `kvm.sh firefox` と違って `up` を経由しないので、コンテナが止まっていれば通知で `./kvm.sh up` を案内する。

| 項目 | 仕様 |
| --- | --- |
| 配置先 | `${XDG_DATA_HOME:-$HOME/.local/share}/applications/kvm-virt-manager.desktop`、`kvm-firefox.desktop`。アイコンは同 `icons/hicolor/<size>/apps/{virt-manager,firefox}.*` |
| テンプレート置換 | `desktop/kvm-<app>.desktop` の `@KVM_SH@` を `<リポジトリ>/kvm.sh` (絶対パス) に置換 (`sed`)。リポジトリを移動したら再実行が必要 |
| `.desktop` の主要キー | `TryExec=@KVM_SH@` (無ければエントリ非表示)、`Exec="@KVM_SH@" launch <app>`、`Icon=firefox` / `virt-manager`、`StartupWMClass=firefox` / `virt-manager`、`Terminal=false`、`Name[ja]` / `Comment[ja]` / `Keywords` の日本語 |
| アイコン抽出 | `gui` イメージの一時コンテナ (`--rm --network none`) で `/usr/share/icons/hicolor` から `apps/virt-manager.*` と `apps/firefox.*` だけを `tar` で取り出す。失敗しても続行 (汎用アイコンになる旨を表示) |
| virt-manager 不在 | `gui` イメージに `/usr/bin/virt-manager` が無ければ `>> virt-manager is not in the image; skipping kvm-virt-manager.desktop` |
| 後処理 | `update-desktop-database -q` (あれば)。配置先と Activities での検索語を表示 |
| `launch` の前提 | 実行ユーザーが `sudo -n podman` を実行できること。`launch` は `firefox` / `virt-manager` 以外を拒否する |
| 通知 | `notify-send -a kvm.sh -i dialog-error "kvm-container" "<本文>"` → 無ければ `zenity --error --title=kvm-container --text=<本文>` → どちらも無ければ stderr のみ |
| 解除 | `uninstall-desktop` が `.desktop` 2 つと `icons/hicolor/*/apps/{virt-manager,firefox}.*` を削除 |

### 4.8 ログとメッセージの規約

| 出力元 | 形式 | 出力先 |
| --- | --- | --- |
| `kvm.sh` の進捗 | `>> ...` | stdout |
| `kvm.sh` の警告・エラー | `!! ...` (続きの行は 3 スペースのインデント) | stderr |
| `gui-user-setup` (両コンテナ) | `gui-user: ...` (エラーは `gui-user: ERROR ...`) | journal (`gui-user.service`) |
| `libvirt-conf` (kvm) | 出力無し (失敗は unit の失敗として journal に残る) | journal (`kvm-libvirt-conf.service`) |
| `gui` 自身の警告 (kvm-gui) | `gui: ...`、headless は `!! GUI unavailable ...` | `podman exec` の stderr (`launch` 経由ではデスクトップ通知に含まれる) |
| GUI アプリの stdout/stderr | アプリの出力そのまま | `kvm-gui` 内 `/var/log/gui.log` (追記) |
| `kvm.sh logs` | `kvm`: `journalctl -n 30 -u kvm-libvirt-conf -u virtqemud -u cockpit.socket -u gui-user`。`gui`: `gui.log` 末尾 50 行 + `journalctl -n 30 -u gui-user` | stdout |

## 5. 内部仕様 (処理シーケンス)

### 5.1 起動シーケンス (`kvm.sh up`)

```mermaid
sequenceDiagram
  actor U as 利用者
  participant K as kvm.sh up
  participant P as podman (sudo)
  participant S as kvm: systemd (PID 1)
  participant G as kvm-gui: systemd (PID 1)
  U->>K: ./kvm.sh up
  Note over K: start_kvm
  K->>P: kvm が起動中なら already running でスキップ
  K->>K: ensure_kvm (modprobe、chmod 666 /dev/kvm)、host_user_args (root 拒否、ハッシュを env-file へ)
  K->>P: kvm イメージが無ければ build --target kvm
  K->>P: prepare_data_dir x3 (空なら seed)
  K->>K: check_host_network (KVM_BRIDGE、virbr0、COCKPIT_PORT)
  K->>P: podman rm -f -i kvm、/run/kvm-container/libvirt の中身を削除
  K->>P: podman run kvm (--privileged --network host、HOST_ARGS + HASH_ARGS)
  P->>S: /sbin/init
  S->>S: generator cockpit-listen → sysinit: kvm-perms、gui-user (リネーム + ハッシュ + linger)、kvm-libvirt-conf (auth_unix_rw = none)
  S->>S: logind → user@UID、virt*d の .socket (0660 root:libvirt)、cockpit.socket、kvm-net-teardown
  loop 最大 30 回、1 秒間隔
    K->>P: exec kvm: systemctl is-active -q cockpit.socket かつ virsh list が成功するか
  end
  K->>P: sync_bridged_network (KVM_BRIDGE に応じて bridged を define / undefine)
  K-->>U: ready. cockpit: https://... (log in with your host user: USER)
  Note over K: have_display なら start_gui (図 15)、無ければ no display found で終了
  K->>K: gui_args → session = sha256(GUI_ARGS) の先頭 16 桁
  K->>P: kvm-gui が起動中で gui_session_matches なら already running でスキップ
  K->>P: gui イメージが無ければ build --target gui、podman rm -f -i kvm-gui
  K->>P: podman run kvm-gui (非特権、label=disable、--label kvm.gui-session、HOST_ARGS + GUI_ARGS)
  P->>G: /sbin/init
  G->>G: sysinit: gui-user (リネーム、ハッシュ無しでロック、linger) → logind → user@UID
  K-->>U: kvm-gui started. host display: ./kvm.sh firefox / ./kvm.sh virt-manager
```

図 14: 起動シーケンス。`kvm` の起動と readiness 確認が終わってから `kvm-gui` を起動する。`kvm-gui` 側には readiness 待ちが無く、
代わりに `gui` がアプリ起動前に systemd の起動完了を待つ (5.3 節)。`up kvm` / `up gui` はそれぞれ片方だけを行う。

```mermaid
flowchart TD
  s["start_gui (have_display 確認済み)"] --> ga["gui_args: GUI_ARGS を組み立てる"] --> h["session = GUI_ARGS の各要素を改行区切りで sha256sum した先頭 16 桁"]
  h --> r{"kvm-gui が起動中か"}
  r -->|"いいえ"| c
  r -->|"はい"| l{"ラベル kvm.gui-session が session と一致するか (podman inspect)"}
  l -->|"いいえ"| c2
  l -->|"はい"| e{"コンテナ内で WAYLAND_DISPLAY のソケットと XAUTHORITY がまだ存在するか<br/>(再ログインで古い runtime dir がマウントに残り、中身だけ消える場合の検出)"}
  e -->|"はい"| ok[">> kvm-gui is already running (何もしない)"]
  e -->|"いいえ"| c2[">> the host session has changed: recreating kvm-gui<br/>(the kvm container and its VMs keep running)"]
  c2 --> c["host_user_args、gui イメージが無ければ build gui、podman rm -f -i kvm-gui<br/>sudo mkdir -p /run/kvm-container/libvirt、data/var-libvirt、data/home"]
  c --> run["podman run kvm-gui ... --label kvm.gui-session=session"]
  run --> msg[">> kvm-gui started. host display: ./kvm.sh firefox | ./kvm.sh virt-manager"]
```

図 15: `start_gui` とセッション一致判定 (`gui_session_matches`)。ラベルの一致だけでは足りない (再ログイン後もソケットのパスが
同じことが多い) ので、コンテナ内からソケットの実在も確かめる。`kvm` と VM には手を触れない。

```mermaid
flowchart LR
  subgraph kvm ["kvm"]
    gen["generator: cockpit-listen<br/>(unit 読み込み前に実行)"] --> ksys
    subgraph ksys ["sysinit.target (DefaultDependencies=no の oneshot)"]
      perms["kvm-perms.service"]
      kuser["gui-user.service<br/>After=local-fs.target"]
      kconf["kvm-libvirt-conf.service<br/>After=local-fs.target"]
    end
    perms -->|"Before="| vq["virtqemud.socket / virtqemud.service / libvirtd.service"]
    kuser -->|"Before="| klogind["systemd-logind.service"]
    kuser -->|"Before="| cs["cockpit.socket"]
    kuser -->|"Before="| vq
    kconf -->|"Before="| allsock["virtqemud / virtnetworkd / virtstoraged / virtnodedevd / virtsecretd / virtlogd の .socket"]
    klogind -->|"linger を読む"| kuserat["user@UID.service → /run/user/UID (tmpfs) + session bus"]
    subgraph kmu ["multi-user.target"]
      td["kvm-net-teardown.service<br/>After=virtnetworkd / virtqemud の .service と .socket<br/>Wants=virtnetworkd.socket"]
    end
    vq --> td
    allsock --> td
  end
  subgraph gui ["kvm-gui"]
    guser["gui-user.service (sysinit)"] -->|"Before="| glogind["systemd-logind.service"]
    glogind -->|"linger を読む"| guserat["user@UID.service → /run/user/UID (非特権: 通常のディレクトリ) + session bus"]
  end
```

図 16: コンテナ内 unit の順序関係 (`Before=` / `After=` / `WantedBy=` から)。`gui-user.service` が logind より前なのは、
logind が `/var/lib/systemd/linger` を起動時にしか読まないため。`kvm-libvirt-conf` が全 `.socket` より前なのは、デーモンが設定を読む前に
`/etc/libvirt` を整えるため。`kvm-net-teardown` が virt*d の後なのは停止時に先に止まるため。`gui-user.service` の `Before=cockpit.socket virtqemud.socket`
は `kvm-gui` には該当 unit が無いので無視される。

起動後のメッセージ:

| 条件 | 出力 |
| --- | --- |
| `kvm` 起動、`COCKPIT_BIND` が `0.0.0.0` または `::` | `>> ready. cockpit: https://$(uname -n):PORT  (log in with your host user: USER)` と firewalld の `--add-port` 案内 |
| `kvm` 起動、それ以外 | `>> ready. cockpit: https://COCKPIT_BIND:PORT  (log in with your host user: USER)` |
| `kvm-gui` を (再) 作成 | `>> kvm-gui started. host display: ./kvm.sh firefox \| ./kvm.sh virt-manager` |
| `kvm-gui` が現セッション用に起動中 | `>> kvm-gui is already running` |
| ディスプレイ無し (`up` 引数なし) | `>> no display found: GUI disabled, use cockpit in a browser` |

### 5.2 停止シーケンス (`kvm.sh down`)

```mermaid
sequenceDiagram
  actor U as 利用者
  participant K as kvm.sh down
  participant P as podman
  participant G as kvm-gui
  participant S as kvm: systemd (PID 1)
  participant T as kvm-net-teardown (ExecStop)
  participant V as virtnetworkd / virtqemud
  participant H as ホスト
  U->>K: ./kvm.sh down (引数なし = 両方)
  K->>P: podman rm -f -i -t 10 kvm-gui
  P->>G: SIGRTMIN+3 → 停止・削除 (GUI アプリも終了)
  K->>P: podman rm -f -i -t 10 kvm
  P->>S: SIGRTMIN+3 (STOPSIGNAL)
  S->>T: stop (After= の逆順なので virt*d より先に止まる)
  T->>V: virsh net-list --name で得た各ネットワークを net-destroy
  V->>H: virbr0 / dnsmasq / nftables ルールを削除
  T->>H: それでも残った /sys/class/net/virbr* を ip link del (フォールバック)
  Note over T: TimeoutStopSec=15
  S->>V: virt*d、cockpit などを停止
  P-->>K: コンテナ削除 (10 秒以内に止まらなければ SIGKILL)
  K->>H: sudo rm -rf /run/kvm-container
  Note over H: data/ (VM 定義・ディスク・home) は残る。down kvm / down gui は片方だけ止め、/run/kvm-container は残す
```

図 17: 停止シーケンス。`virbr0` はホストの名前空間にあるため、コンテナが消えても自動では消えない。libvirt のデーモンが
生きているうちに `net-destroy` し、idle-exit していて socket activation が拒否される場合に備えて `ip link del` も行う。
`kvm-gui` を先に止めるのは、`kvm` の libvirt に接続しているクライアントを先に閉じるため。

### 5.3 GUI 起動シーケンス (`container/gui/gui`、`kvm-gui` 内)

```mermaid
flowchart TD
  a["podman exec kvm-gui gui app args"] --> b["GUI_USER = 環境変数 GUI_USER → PID 1 の HOST_USER (どちらも空なら !! HOST_USER is not set で exit 1)<br/>id で uid / gid を取得"]
  b --> c{"DISPLAY と WAYLAND_DISPLAY が両方とも空か"}
  c -->|"はい"| c1["!! GUI unavailable: the container was started without a display (headless)<br/>exit 2"]
  c -->|"いいえ"| d["環境設定: XDG_RUNTIME_DIR=/run/user/UID、MOZ_ENABLE_WAYLAND=1、<br/>GDK_BACKEND=wayland,x11、GSETTINGS_BACKEND=keyfile、LANG (既定 ja_JP.UTF-8)、LIBGL_ALWAYS_SOFTWARE (渡されたときのみ)"]
  d --> e{"WAYLAND_DISPLAY が絶対パスで、そのソケットが無いか"}
  e -->|"はい"| e1["gui: Wayland socket ... not found (./kvm.sh up recreates this container after a host re-login); trying X11<br/>unset WAYLAND_DISPLAY"] --> f
  e -->|"いいえ"| f{"XAUTHORITY が未設定か"}
  f -->|"はい"| f1["探索順: /run/host-xdg-runtime/.mutter-Xwaylandauth.* (新しい順)<br/>→ /run/host-xdg-runtime/Xauthority → /home/USER/.Xauthority"] --> g
  f -->|"いいえ"| g{"コマンド"}
  g -->|"firefox (引数なし)"| g1["firefox --new-instance https://localhost:PORT<br/>PORT は PID 1 の COCKPIT_LISTEN の末尾 (無ければ 9091)"]
  g -->|"virt-viewer VM"| g2["virt-viewer --connect qemu:///system --attach --wait VM"]
  g -->|"その他"| g3["そのまま実行"]
  g1 --> h
  g2 --> h
  g3 --> h["timeout 60 systemctl is-system-running --wait (gui-user の uid 合わせを待つ)<br/>timeout 30 systemctl start user@UID.service (失敗は無視)"]
  h --> i{"/run/user/UID があるか"}
  i -->|"いいえ"| i1["gui: user@UID.service did not provide ... creating it<br/>install -d -m 700 (session bus 無し)"] --> j
  i -->|"はい"| j{"/run/user/UID/bus があるか"}
  j -->|"はい"| j1["DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/UID/bus"] --> k
  j -->|"いいえ"| k["chmod 0666 /dev/dri/renderD* (失敗は無視)"]
  k --> u["unset HOST_PASSWORD_HASH HOST_USER HOST_UID HOST_GID"]
  u --> l["exec setsid -f runuser -u USER -- cmd<br/>stdout / stderr は /var/log/gui.log に追記"]
```

図 18: `gui` の処理。GUI アプリは **コンテナの** `/run/user/UID` と session bus を使い (virt-manager の単一インスタンス化に必要)、
ホストの runtime dir はソケットへの connect にだけ使う。libvirt へは `/run/libvirt` の共有ソケットで届く (`qemu:///system`)。
`runuser` は `--login` 無しなので環境がそのまま渡り、そのためにホストユーザーの情報を先に `unset` する
(`kvm-gui` にハッシュは渡っていないが、同じコードで消す)。

### 5.4 ユーザー作成 (`container/common/gui-user-setup`、両コンテナ)

```mermaid
flowchart TD
  s["gui-user.service (sysinit、logind より前)"] --> r["PID 1 の environ から HOST_USER / HOST_UID / HOST_GID / HOST_PASSWORD_HASH を読む"]
  r --> a{"HOST_USER と HOST_UID があるか"}
  a -->|"いいえ"| a1["no GUI user is created と表示して exit 0<br/>(kvm.sh 以外から起動された場合)"]
  a -->|"はい"| b["HOST_GID 省略時は HOST_UID"]
  b --> c{"HOST_GID のグループが既にあるか"}
  c -->|"ある"| e
  c -->|"無い、同名グループがある"| c1["groupmod -g HOST_GID HOST_USER"] --> e
  c -->|"無い"| c2["groupadd -g HOST_GID HOST_USER"] --> e
  e{"HOST_USER が既に存在するか"}
  e -->|"いいえ (通常の起動)"| f{"HOST_UID が使用中か"}
  f -->|"はい"| f1["gui-user: ERROR uid ... is already used<br/>exit 1"]
  f -->|"いいえ"| f2["useradd -m -u HOST_UID -g HOST_GID HOST_USER<br/>(/home/USER はバインドマウント済みなので skel はコピーされない)"] --> h
  e -->|"はい (コンテナを作り直さない再起動)"| g["gid が異なれば usermod -g、uid が異なれば usermod -u<br/>(uid が使用中なら ERROR + exit 1)"] --> h
  h["そのイメージにあるグループへ追加: usermod -aG wheel / libvirt / video / render"] --> i{"HOST_PASSWORD_HASH があるか"}
  i -->|"はい (kvm)"| i1["usermod -p HASH"] --> k
  i -->|"いいえ (kvm-gui、またはホストにパスワード無し)"| i2["usermod -L (ロック: cockpit ログイン不可)"] --> k
  k["linger: /var/lib/systemd/linger/USER を作成"] --> l["/home/USER があれば chown -R HOST_UID:HOST_GID"]
```

図 19: GUI ユーザーの作成。両コンテナで同じスクリプトが動き、`kvm` だけがハッシュを受け取る。イメージには一般ユーザーが
入っていないので、通常の起動では毎回ここで新規作成する (`kvm.sh up` は毎回 `podman rm` してイメージから作る)。
uid/gid の再調整は `podman restart` のようにコンテナを作り直さずに再起動した場合の経路。
主グループの gid を変えても `libvirt` グループ (gid 985) への所属は変わらない。
linger は `loginctl enable-linger` と同じ効果を logind 起動前に得るため、ファイルを直接作る。

### 5.5 各 unit と設定の仕様

| unit / ファイル | イメージ | 種別 | 依存関係 | 内容 |
| --- | --- | --- | --- | --- |
| `gui-user.service` | 両方 | oneshot, RemainAfterExit | `DefaultDependencies=no`、`After=local-fs.target`、`Before=systemd-logind.service cockpit.socket virtqemud.socket`、`WantedBy=sysinit.target` | `ExecStart=/usr/local/bin/gui-user-setup` (5.4 節) |
| `kvm-perms.service` | kvm | oneshot, RemainAfterExit | `DefaultDependencies=no`、`Before=virtqemud.socket virtqemud.service libvirtd.service`、`WantedBy=sysinit.target` | `chmod 0666 /dev/kvm /dev/net/tun`、`chown root:kvm /dev/kvm`、`sysctl -qw net.ipv4.ip_forward=1`。すべて失敗を無視 (`\|\| true`)。`/dev/dri` は扱わない (`kvm-gui` の `gui` が行う) |
| `kvm-libvirt-conf.service` | kvm | oneshot, RemainAfterExit | `DefaultDependencies=no`、`After=local-fs.target`、`Before=` 6 つの `virt*d.socket`、`WantedBy=sysinit.target` | `ExecStart=/usr/local/bin/libvirt-conf` (3.5 節) |
| `virtd-socket.conf` | kvm | drop-in (`virt{qemu,network,storage,nodedev,secret}d.socket.d/kvm-container.conf`) | | `[Socket]` `SocketMode=0660` `SocketGroup=libvirt` |
| `kvm-net-teardown.service` | kvm | oneshot, RemainAfterExit | `After=virtnetworkd.service virtqemud.service virtnetworkd.socket virtqemud.socket`、`Wants=virtnetworkd.socket`、`WantedBy=multi-user.target`、`TimeoutStopSec=15` | `ExecStart=/bin/true`、`ExecStop` で全ネットワークの `net-destroy` と `virbr*` の `ip link del` (5.2 節) |
| `cockpit-listen` (generator) | kvm | systemd generator (`/usr/lib/systemd/system-generators/`) | unit 読み込み前 | 第 1 引数 (normal ディレクトリ) に `cockpit.socket.d/listen.conf` を生成: `ListenStream=` (リセット) と `ListenStream=<bind>:<port>`。`COCKPIT_LISTEN` が無ければ `127.0.0.1:9091` |
| `cockpit.conf` | kvm | cockpit-ws 設定 | | `[WebService]` `AllowUnencrypted = true`、`ProtocolHeader = X-Forwarded-Proto` (Origin は Host ヘッダで検査されるので localhost でも他 PC でも動く) |
| `systemd-logind.service` | 両方 | (unmask) | | cockpit ログインで pam_systemd がセッションを作り、`/run/user/UID/bus` を使う。無いと cockpit-bridge が落ちてログイン直後にログアウトされる。`kvm-gui` では GUI ユーザーの `user@UID` を起動するために必要 |
| `tmpfiles.d/x11.conf` | gui | マスク (`/dev/null` への symlink) | | ro マウントしたホストの `/tmp/.X11-unix` を systemd-tmpfiles に触らせない |

### 5.6 ホスト種別フック (`host_*`)

`kvm.sh` はホスト依存の振る舞いを 3 つのフック関数として汎用実装付きで定義し、その直後に `host/wsl.sh` を無条件に source する。
`host/wsl.sh` は WSL2 のときだけ同名関数を再定義する。`kvm.sh` 本体には WSL 固有の分岐や文字列を書かない。

| フック | 引数 / 戻り値 | 汎用実装 (`kvm.sh`) | WSL2 実装 (`host/wsl.sh`) | 呼び出し元 |
| --- | --- | --- | --- | --- |
| `host_kvm_missing_hint` | 無し / stderr にメッセージ | `!! /dev/kvm not found. Enable SVM (AMD) / VT-x (Intel) in the firmware and check sudo modprobe kvm_amd or kvm_intel` | `!! /dev/kvm not found. Set [wsl2] nestedVirtualization=true in %USERPROFILE%\.wslconfig on the Windows side and run wsl --shutdown` | `ensure_kvm` (modprobe 後も `/dev/kvm` が無いとき) |
| `host_default_runtime_dir` | 無し / stdout にパス | 何も出力しない | `/mnt/wslg/runtime-dir` | `gui_args` (`XDG_RUNTIME_DIR` 未設定時) |
| `host_force_software_gl` | 無し / 終了コード (0 = 強制) | `[ ! -d /dev/dri ] \|\| [ "$KVM_SOFTWARE_GL" = 1 ]` | 常に 0 (WSL に `/dev/dri` は無い) | `gui_args` (`LIBGL_ALWAYS_SOFTWARE=1` を付けるか) |

新しいホスト依存の挙動はこの形式で追加する (汎用実装を `kvm.sh` に、上書きを `host/wsl.sh` に)。

### 5.7 ブリッジ同期 (`sync_bridged_network`)

```mermaid
flowchart TD
  s["sync_bridged_network (kvm の readiness 確認後、start_kvm のたびに実行)"] --> a{"KVM_BRIDGE が設定されているか"}
  a -->|"いいえ"| b{"bridged が定義済みか (net-list --all --name)"}
  b -->|"はい"| b1[">> KVM_BRIDGE is not set: removing the libvirt network bridged<br/>net-destroy bridged (失敗は無視) → net-undefine bridged"]
  b -->|"いいえ"| b2["何もしない (default のみ)"]
  a -->|"はい"| c{"bridged が active か (net-list --name)"}
  c -->|"はい"| c1["net-destroy bridged"] --> d
  c -->|"いいえ"| d["net-define (stdin の XML: name=bridged, forward mode=bridge, bridge name=KVM_BRIDGE)"]
  d --> e["net-autostart bridged → net-start bridged"]
  e --> f[">> libvirt network bridged -> host bridge KVM_BRIDGE ...<br/>定義は data/etc-libvirt に永続化"]
```

図 20: `bridged` ネットワークの同期 (`kvm` コンテナ内の virsh で実行)。ブリッジ自体の存在は起動前に `check_host_network` が確認済み。
毎回 define し直すので、`KVM_BRIDGE` の値を変えるとその値に追従する。`up gui` では実行されない。

## 6. 設計上の不変条件

以下はいずれも実際の不具合を踏んだ結果その形になっている (付録 B の PR 番号)。理由を理解せずに変えないこと。

```mermaid
flowchart LR
  subgraph bad ["やってはいけない構成"]
    b1["ホストの runtime dir を /run/user/UID にマウントする"]
    b2["/tmp/.X11-unix を rw でマウントする、または tmpfiles.d/x11.conf を有効にする"]
    b3["iscsid.socket / iscsiuio.socket を有効にする"]
    b4["NetworkManager.service を有効にする"]
    b5["NetworkManager-wait-online.service を有効にする"]
    b6["cockpit を 9090 で listen する"]
    b7["kvm-net-teardown.service 無しで停止する"]
    b8["seed コンテナや kvm-gui を label=disable 無しで動かす"]
    b9["systemd-logind をマスクしたままにする"]
    b10["kvm-gui から libvirt 既定の polkit 認証 (ソケット 0666) のまま接続する"]
    b11["libvirt グループの gid をパッケージ任せにする"]
    b12["/etc/libvirt の設定を Containerfile の sed で行う"]
    b13["/run/kvm-container/libvirt を空にせずに kvm を起動する、またはディレクトリごと消す"]
    b14["kvm-gui のセッション判定を省いて再利用する"]
  end
  subgraph result ["起きること"]
    r1["cockpit ログインで logind がホストの bus / systemd --user を作り直し、ログアウト時に user-runtime-dir@ がホストの Wayland ソケットごと削除 (PR 10)"]
    r2["コンテナの systemd-tmpfiles がホストの X ソケットを削除 (PR 10)"]
    r3["abstract unix ソケットがホストの iscsid と衝突し、起動が常に degraded (PR 15)"]
    r4["ホストの NIC・ブリッジを管理し始める (PR 14)"]
    r5["podman の eth0 が online にならず 60 秒待って degraded (PR 11)"]
    r6["AlmaLinux 10 ホスト自身の cockpit.socket と衝突して起動できない (PR 15)"]
    r7["virbr0 がホストに残り、次回 default の起動が File exists で失敗 (PR 14)"]
    r8["SELinux Enforcing で data/ (user_home_t) への書き込みや、spc_t のソケットへの connectto、runtime dir (user_tmp_t) の読み取りが拒否される (PR 15、PR 18)"]
    r9["cockpit-bridge が session bus に届かず、ログイン直後にログアウトされる (PR 2)"]
    r10["別 pid 名前空間からの接続は SO_PEERCRED の pid が 0 で、polkit がクライアントを識別できず認証失敗 (PR 18)"]
    r11["両イメージで gid が食い違い、kvm-gui のユーザーが 0660 のソケットに届かない (PR 18)"]
    r12["data/etc-libvirt は空のときしか seed されないので、既存の data/ に設定が届かない (PR 18)"]
    r13["前回のソケット・pid・VM 状態が残ってデーモンが混乱する。ディレクトリを消すと起動中の kvm-gui が古い inode を見続ける (PR 18)"]
    r14["再ログイン後に古い (消えた) Wayland ソケットへ繋ぎ続け、画面に出ない (PR 18)"]
  end
  b1 --> r1
  b2 --> r2
  b3 --> r3
  b4 --> r4
  b5 --> r5
  b6 --> r6
  b7 --> r7
  b8 --> r8
  b9 --> r9
  b10 --> r10
  b11 --> r11
  b12 --> r12
  b13 --> r13
  b14 --> r14
```

図 21: 禁止構成とその帰結。左の構成にすると右の不具合が再発する。

| 規則 | 実装箇所 | 補足 |
| --- | --- | --- |
| ホストの `XDG_RUNTIME_DIR` は `kvm-gui` の `/run/host-xdg-runtime` に **読み取り専用** でマウントし、`/run/user/UID` には絶対にマウントしない | `kvm.sh` `gui_args` / `HOST_RUNTIME_DIR` | ソケットは `map_rt_path` でコンテナ内の絶対パスに変換して環境変数で渡す。runtime dir 外の symlink 先はそのファイルだけを同じパスに ro マウント |
| コンテナ内の `/run/user/UID` は logind が作る。GUI ユーザーを linger にして起動時から存在させる | `gui-user-setup` `enable_linger`、`gui-user.service` の `Before=systemd-logind.service` | `kvm` では tmpfs。非特権の `kvm-gui` では tmpfs のマウントに失敗して systemd がディレクトリ作成にフォールバックする (想定内)。cockpit ログアウトでも消えない |
| `/tmp/.X11-unix` は読み取り専用マウント、`tmpfiles.d/x11.conf` はマスク (`gui` イメージ) | `kvm.sh` `gui_args`、`Containerfile` | コンテナの systemd-tmpfiles にホストの X ソケットを消させない |
| コンテナをまたぐ libvirt 接続は `auth_unix_rw = "none"` + ソケット権限 `root:libvirt 0660` で制御し、`libvirt` の gid は `base` 段で固定する | `container/kvm/libvirt-conf`、`virtd-socket.conf`、`Containerfile` `LIBVIRT_GID` | 3.5 節。socket 起動では `.socket` unit の設定が権限を決める。`kvm-libvirt-conf.service` が起動ごとに冪等に書く (Containerfile で sed しない) |
| `/run/libvirt` はホストの `/run/kvm-container/libvirt` を両コンテナにバインドマウントしたもの。`start_kvm` が中身だけ空にし、`down` (引数なし) で消す | `kvm.sh` `start_kvm` / `down` | ディレクトリ自体は消さない (起動中の `kvm-gui` のマウントを壊さない) |
| `kvm-gui` は `--privileged` ではないが `--security-opt label=disable` | `kvm.sh` `start_gui` | SELinux Enforcing のホストで特権コンテナ (spc_t) のソケットへ connect し、ホストの runtime dir (user_tmp_t) を読むため。`/dev/dri` は `--device` で渡し、`gui` が `renderD*` を 0666 にする |
| 再ログイン後は `kvm-gui` だけ作り直す | `kvm.sh` `start_gui` / `gui_session_matches` | `GUI_ARGS` のハッシュをラベル `kvm.gui-session` に記録し、ラベルとコンテナ内のソケット実在の両方で判定する。`firefox` / `virt-manager` / `viewer` は必ず `up` を経由する |
| `--network host` の帰結を守る (両コンテナ): 既定ポート 9091、`iscsid.socket` / `iscsiuio.socket` / `NetworkManager.service` / `NetworkManager-wait-online.service` のマスク、停止時の `kvm-net-teardown` | `kvm.sh` `COCKPIT_PORT` / `check_host_network`、`Containerfile` `base`、`kvm-net-teardown.service` | `podman -p` は使えないので generator で `ListenStream` を書き換える |
| GUI/cockpit ユーザーはホストユーザーの写し (名前・uid/gid、`kvm` ではパスワードハッシュも)。`kvm.sh` は root で実行させない | `host_user_args`、`gui-user-setup` | ホストの runtime dir は 0700 なので uid 一致が必要。cockpit は `kvm` の `/etc/shadow` で認証する。ハッシュは `kvm` にだけ渡す |
| `data/` は空のときだけ `kvm` イメージから seed し、seed コンテナは `--security-opt label=disable` | `prepare_data_dir` | バインドマウントはイメージの内容をコピーしないため。`data/var-libvirt` は `kvm-gui` に ro で見せる |
| `systemd-logind` はマスク解除する (`common` 段) | `Containerfile` | ベースイメージはマスク済み。cockpit の pam_systemd と両コンテナの session bus に必要 |
| ホスト → コンテナの値は PID 1 の environ 経由。パスワードハッシュだけは `--env-file` で `kvm` にだけ、`gui` は `runuser` 前に `unset` | `kvm.sh`、`gui-user-setup` `env_of_pid1`、`gui` | 新しい値もこの流儀で渡す |
| コンテナ名は `kvm` / `kvm-gui`、イメージ名は `localhost/kvm-container/{kvm,gui}` に固定 (変数名 `KVM_CONTAINER` / `GUI_CONTAINER` / `KVM_IMAGE` / `GUI_IMAGE`)。`NAME` は使わない | `kvm.sh` | `NAME` は WSL がホスト名に使う |
| ホスト依存の挙動は `host_*` フックで足す。`kvm.sh` 本体に WSL 分岐を書かない | `kvm.sh`、`host/wsl.sh` | 5.6 節 |

## 7. セキュリティ考慮事項

| 項目 | 現状の扱い | 影響 |
| --- | --- | --- |
| `kvm` の権限 | `--privileged`、root の podman、`--network host`。SELinux のラベル分離は無効 | コンテナ内 root はホスト root と同等。信頼できるイメージ (このリポジトリの `build`) のみ使う前提 |
| `kvm-gui` の権限 | 非特権 (`--privileged` 無し、capability の追加無し)、`--security-opt label=disable`、`--network host`、`--device /dev/dri` | ブラウザなど攻撃面の広いアプリを特権コンテナから切り離す。SELinux のラベル分離は無いので、ホスト側からは通常の非特権コンテナ相当 |
| libvirt へのアクセス制御 | polkit ではなくソケットの所有グループ (`root:libvirt 0660`) と `auth_unix_rw = "none"`。両コンテナの GUI ユーザーと `kvm` の `libvirtdbus` が `libvirt` グループ | `libvirt` グループ (gid 985) に入れるプロセスは誰でも `qemu:///system` を完全に操作できる。gid 985 を持つホスト側のプロセスも `/run/kvm-container/libvirt` 経由で届く |
| ホストユーザーのパスワードハッシュ | `sudo getent shadow` で取得 → `mktemp` のファイルに書く (既定 0600) → `podman run --env-file` で `kvm` にだけ渡す (コマンドラインには出ない) → `kvm.sh` 終了時に EXIT trap で削除。`kvm-gui` には渡さない | ハッシュは `kvm` 内 root (PID 1 の environ、`/etc/shadow`) から読める。`kvm-gui` とその中の GUI アプリには存在しない |
| cockpit の TLS | 自己署名証明書 (cockpit-ws の既定)。`AllowUnencrypted = true`、`ProtocolHeader = X-Forwarded-Proto` | ブラウザで警告が出る。既定 bind は `127.0.0.1` なのでホスト外からは届かない |
| `COCKPIT_BIND=0.0.0.0` / `::` | ホストの全アドレスで listen。認証はホストユーザーの名前・パスワード (`kvm` の `/etc/shadow`) | ホストユーザーの資格情報が LAN から試行可能になる。firewalld の開放は利用者が行う |
| `kvm` 内の sudo | `%wheel ALL=(ALL) NOPASSWD: ALL` (`kvm` イメージのみ)。GUI ユーザーは `wheel` に属する | cockpit の「管理者アクセス」に使う。`kvm` 内では GUI ユーザー = root 相当。`kvm-gui` に sudoers は無い |
| ホスト側の sudo | `launch` (Activities 起動) だけが `sudo -n podman` を要求する。通常の `kvm.sh` は対話的な `sudo` | podman の NOPASSWD sudo はホスト root 相当の権限付与になる。設定は利用者の判断 |
| libvirt / qemu | `security_driver = "none"`、`namespaces = []`。`/dev/kvm` `/dev/net/tun` は 0666、`kvm-gui` の `/dev/dri/renderD*` も 0666 | VM 間の SELinux / namespace 隔離は無い |
| ホストのセッション資源 | `kvm-gui` にのみ、runtime dir と `/tmp/.X11-unix` と Xauthority を読み取り専用で渡す | GUI アプリはホストのコンポジタに接続できる (画面・入力にアクセス可能) が、ホストのソケットを消したり作り直したりはできない |
| `data/` | root / qemu 所有。`clean` で削除 (確認あり、`KVM_CLEAN_YES=1` で省略)。`kvm-gui` からは `var-libvirt` が ro、`home` が rw | VM ディスクと定義はホストのファイルシステムに平文で置かれる。firefox のプロファイルは `kvm` 側 (`home` rw) からも読める |

## 8. 既知の制限事項

| 制限 | 内容 |
| --- | --- |
| WSL2 でブリッジ不可 | Hyper-V 仮想スイッチが WSL の vNIC 以外の MAC からのフレームを破棄する。WSL2 では `default` (NAT) を使う |
| SPICE 非対応 | RHEL 10 系の qemu-kvm に SPICE が無く、VM のグラフィックスは VNC |
| cockpit の「ネットワーク」ページ | コンテナ内の NetworkManager がマスクされているため使えない |
| cockpit は `kvm` 側 | cockpit-machines の hard Requires により分離できない。`kvm-gui` の firefox は `localhost` の cockpit を開くだけ |
| ホストの再ログイン | GNOME からログアウト/再ログインすると `/run/user/UID` が作り直され、`kvm-gui` に渡した Wayland ソケットのパスが無効になる。`./kvm.sh up` (または `firefox` / `virt-manager` / `viewer`) が `kvm-gui` だけを作り直す。`kvm` と VM は動いたまま |
| パスワード変更の反映 | ホストでパスワードを変えても起動中の `kvm` には反映されない。`down kvm` → `up` |
| headless での GUI | `kvm.sh firefox` 等は `have_display` の判定で exit 2、`up gui` は exit 1。cockpit をブラウザで使う |
| `kvm-gui` の `/run/user/UID` | 非特権なので tmpfs にならず `/run` 直下の通常のディレクトリ (systemd のフォールバック、想定内) |
| virt-manager | EPEL に無い環境では `gui` イメージに入らず、`install-desktop` は `.desktop` をスキップする |
| WSLg のスタートメニュー | `~/.local/share/applications` の `.desktop` は Windows のスタートメニューに反映されるはずだが未検証 |
| 1 コンテナ構成からの移行 | 旧構成の `kvm` コンテナは `/run/libvirt` を共有していないので、`./kvm.sh down` で消してから `./kvm.sh build && ./kvm.sh up` する。旧イメージ `localhost/qemu-kvm-cockpit` は `sudo podman rmi` で消せる。`data/` はそのまま使える (`kvm-libvirt-conf.service` が設定を更新する) |
| 起動確認のタイムアウト | `kvm` の readiness は 30 秒固定。遅いホストでは `could not confirm startup` になり得る (コンテナ自体は起動を続ける)。`kvm-gui` には readiness 待ちが無い |

```mermaid
stateDiagram-v2
  [*] --> NoImage
  NoImage : イメージ無し
  Kvm : kvm だけ起動中 (ディスプレイ無し、または down gui 後)
  Both : kvm + kvm-gui 起動中 (GUI 可)
  Stale : kvm 起動中、kvm-gui は古いセッション用
  Down : コンテナ無し (data/ は残る)
  NoData : コンテナ無し、data/ 無し (イメージは残る)
  NoImage --> Kvm : kvm.sh up (build と seed を自動実行、ディスプレイ無し)
  NoImage --> Both : kvm.sh up (ディスプレイあり)
  NoData --> Kvm : kvm.sh up (seed)
  Down --> Kvm : kvm.sh up (ディスプレイ無し) / up kvm
  Down --> Both : kvm.sh up (ディスプレイあり) / firefox / virt-manager / viewer
  Kvm --> Both : kvm.sh up / up gui / firefox / virt-manager / viewer
  Both --> Kvm : kvm.sh down gui
  Both --> Stale : ホストで再ログイン、DISPLAY 等の変更
  Stale --> Both : kvm.sh up / firefox / virt-manager / viewer (kvm-gui だけ作り直す)
  Both --> Down : kvm.sh down
  Kvm --> Down : kvm.sh down
  Stale --> Down : kvm.sh down
  Both --> NoData : kvm.sh clean (確認あり)
  Down --> NoData : kvm.sh clean (確認あり)
```

図 22: コンテナと `data/` のライフサイクル。`down` は `data/` を残し、`clean` だけが消す。イメージは `clean` でも残る。
`down kvm` だけを行うと `kvm-gui` は libvirt に届かない状態で残る (次の `up` で `kvm` が再起動し、共有 run dir が空にされるので復帰する)。

## 9. 検証手順

自動テストは無い。変更後は静的検査と、README 末尾の確認手順を手で流す。

### 9.1 静的検査

```bash
files="kvm.sh host/wsl.sh container/gui/gui container/common/gui-user-setup container/kvm/libvirt-conf container/kvm/cockpit-listen-generator"
bash -n $files
shellcheck $files          # 指摘ゼロを保つ (-S style でもゼロ)
# shellcheck がホストに無ければ gui イメージの使い捨てコンテナで実行できる:
sudo podman run --rm --security-opt label=disable -v "$PWD:/src:ro" localhost/kvm-container/gui \
  sh -c 'microdnf -y install ShellCheck >/dev/null && cd /src && shellcheck '"$files"
```

### 9.2 物理 AlmaLinux 10 + GNOME

| コマンド | 期待結果 | 検証していること |
| --- | --- | --- |
| `getenforce` | `Enforcing` のままで可 | SELinux を緩めずに動く (seed と `kvm-gui` の `label=disable`、`kvm` の `--privileged`) |
| `env \| grep -E 'DISPLAY\|WAYLAND\|XDG_RUNTIME\|XAUTH'` | 値が入っている | `gui_args` が表示先を取得できる |
| `ss -ltn \| grep 9091` | 何も出ない | `check_host_network` を通る (出るなら `COCKPIT_PORT` を変える) |
| `./kvm.sh up && ./kvm.sh firefox` | cockpit が firefox で開く (自己署名証明書の警告) | 起動シーケンス全体 (両コンテナ) と Wayland 表示 |
| `for c in kvm kvm-gui; do sudo podman exec $c systemctl is-system-running; done` | どちらも `running` (`degraded` ではない) | Containerfile の unit マスク群が効いている **(実質的な回帰テスト)** |
| `sudo podman exec kvm ls -l /run/libvirt/virtqemud-sock` | `srw-rw---- root libvirt` | `virtd-socket.conf` の drop-in |
| `sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` | VM 一覧が出る | コンテナをまたぐ libvirt 接続 **(回帰テスト)** |
| `sudo grep -h '^auth_unix_rw' data/etc-libvirt/virt*d.conf` | すべて `"none"` | `kvm-libvirt-conf.service` |
| `sudo podman exec kvm-gui ls -la /dev/dri` | `renderD*` が 0666 | `--device /dev/dri` と `gui` の chmod |
| `sudo ausearch -m avc -ts recent` | 拒否が無い | SELinux 上の問題が無い |
| `./kvm.sh virt-manager && ./kvm.sh viewer <VM名>` | GNOME にウィンドウが出て VM のコンソールが見える | session bus、Wayland 接続、共有ソケット経由の VNC |
| GNOME 再ログイン後に `./kvm.sh up` | `kvm-gui` だけが作り直され、`./kvm.sh virsh list` の VM が動いたまま | `gui_session_matches` (図 15) |
| `./kvm.sh down; ip link show virbr0; ls /run/kvm-container` | どちらも残っていない | `kvm-net-teardown` と共有 run dir の削除 |

### 9.3 Windows + WSL2

| コマンド | 期待結果 | 検証していること |
| --- | --- | --- |
| `./kvm.sh up && ./kvm.sh firefox` | WSLg 経由で Windows に Firefox (cockpit) が出る | WSL 判定、`/mnt/wslg/runtime-dir` の扱い |
| `for c in kvm kvm-gui; do sudo podman exec $c systemctl is-system-running; done` | どちらも `running` | unit マスク群 |
| `sudo podman exec kvm-gui ss -xp \| grep wayland` | `/mnt/wslg/runtime-dir/wayland-0` に接続している | X11 フォールバックではなく Wayland (図 10 の経路) |
| `sudo podman exec kvm-gui findmnt /run/user/$UID` | ホストの runtime dir ではなく、コンテナ内 `/run` の下 (非特権なので tmpfs ではない) | ホストの runtime dir を `/run/user/UID` にマウントしていない (図 9) |
| `ls -A /run/user/$UID && systemctl --user is-system-running` | cockpit ログイン → ログアウト後も一覧が変わらず `running` | ホストのセッションが無傷 (図 21 の r1 が再発していない) |

### 9.4 その他の確認点 (変更内容に応じて)

| 変更箇所 | 確認 |
| --- | --- |
| `KVM_BRIDGE` 周り | `./kvm.sh virsh net-list` で `bridged` が active。`KVM_BRIDGE` 無しで `up` すると消える |
| `down` | ホストに `virbr0` と dnsmasq と `/run/kvm-container` が残らない。`down` → `up` で VM 定義とディスクが復元される |
| `COCKPIT_PORT` | 使用中のポートを指定すると `up` が中止する。`firefox` が開く URL が新しいポートに追従する |
| `install-desktop` / `launch` | Activities から起動できる。`kvm-gui` 未起動時と sudo 失敗時に通知が出る |
| パスワード | ホストユーザーのパスワードで cockpit にログインできる。コンテナには他に一般ユーザーが居ない。`podman run` のコマンドラインにハッシュが出ない。`kvm-gui` 内の `/etc/shadow` でユーザーがロックされている |
| ロール引数 | `up kvm` は `kvm-gui` を起動しない。ディスプレイ無しで `up gui` は exit 1。`build gui` は `gui` イメージだけを作る |

## 付録 A. ファイル一覧とコンテナ内配置

| リポジトリ内 | イメージ | コンテナ内 (Containerfile の COPY) | モード | 備考 |
| --- | --- | --- | --- | --- |
| `kvm.sh` | | (ホスト側) | 実行可能 | |
| `host/wsl.sh` | | (ホスト側、source) | | |
| `desktop/kvm-firefox.desktop` `desktop/kvm-virt-manager.desktop` | | (ホスト側、`install-desktop` が `~/.local/share/applications/` へ) | | `@KVM_SH@` を置換 |
| `Containerfile` | | | | マルチステージ: `base` → `common` → `kvm` / `gui` |
| `container/common/gui-user-setup` | 両方 | `/usr/local/bin/gui-user-setup` | `chmod +x` | |
| `container/common/gui-user.service` | 両方 | `/etc/systemd/system/gui-user.service` | | `systemctl enable` |
| `container/kvm/kvm-perms.service` | kvm | `/etc/systemd/system/kvm-perms.service` | | `systemctl enable` |
| `container/kvm/kvm-net-teardown.service` | kvm | `/etc/systemd/system/kvm-net-teardown.service` | | `systemctl enable` |
| `container/kvm/kvm-libvirt-conf.service` | kvm | `/etc/systemd/system/kvm-libvirt-conf.service` | | `systemctl enable` |
| `container/kvm/libvirt-conf` | kvm | `/usr/local/bin/libvirt-conf` | `chmod +x` | |
| `container/kvm/virtd-socket.conf` | kvm | `/usr/local/share/kvm-container/virtd-socket.conf` → `/etc/systemd/system/virt{qemu,network,storage,nodedev,secret}d.socket.d/kvm-container.conf` | 0644 (`install -D`) | |
| `container/kvm/cockpit-listen-generator` | kvm | `/usr/lib/systemd/system-generators/cockpit-listen` | `chmod +x` | |
| `container/kvm/cockpit.conf` | kvm | `/etc/cockpit/cockpit.conf` | | |
| `container/gui/gui` | gui | `/usr/local/bin/gui` | `chmod +x` | |
| `.gitignore` | | | | `*.iso` `*.qcow2` `build.log` `data/` |
| `data/` (git 管理外) | | `kvm`: `/var/lib/libvirt` `/etc/libvirt` `/home/<HOST_USER>`、`kvm-gui`: `/var/lib/libvirt` (ro) `/home/<HOST_USER>` | バインドマウント | `up` が作成・seed |
| `/run/kvm-container/libvirt` (ホスト、非永続) | | 両方 `/run/libvirt` | バインドマウント | `up` が空にし `down` で削除 |

## 付録 B. 主要な変更履歴

不変条件がどの不具合から生まれたかの索引。詳細はコミットメッセージを参照。

| PR | 要旨 | 本書の関連節 |
| --- | --- | --- |
| 2 | `systemd-logind` のマスク解除。cockpit ログイン直後の自動ログアウトを修正 | 3.4、6 |
| 3 | 永続化を named volume からホストディレクトリのバインドマウントに変更 (seed 処理) | 4.6 |
| 5 | `install-desktop` / `launch` の追加 | 4.7 |
| 8 | Quadlet / sudoers 配置の廃止、コンテナ名・イメージ名・データディレクトリを固定値に | 1.3、3.3 |
| 9 | cockpit にホストのユーザー名・パスワードでログインできるように (ホストユーザーの写しを作る、ハッシュの env-file 渡し) | 4.3、5.4、7 |
| 10 | ホストの runtime dir を読み取り専用の別パスにマウント。cockpit ログアウトでホストの `/run/user/UID` が消える問題を修正。GUI ユーザーの linger | 4.4、5.3、6 |
| 11 | `NetworkManager-wait-online.service` をマスク。起動完了が 1 分遅れて degraded になるのを防ぐ | 3.4 |
| 12 | WSL2 専用処理を `host/wsl.sh` に分離 (`host_*` フック) | 2.1、5.6 |
| 13 | ベースイメージを AlmaLinux 10 minimal に変更、明示パッケージを最小化 | 3.4 |
| 14 | `--network host` と `KVM_BRIDGE` (libvirt ネットワーク `bridged`)、`cockpit-listen-generator`、`kvm-net-teardown.service`、NetworkManager のマスク | 4.5、5.2、5.7 |
| 15 | 物理 AlmaLinux 10 対応: seed の `label=disable`、`iscsid.socket` のマスク、cockpit 既定ポート 9091、ポート使用中の検出、firefox の URL をポートに追従 | 2.4、3.4、4.5 |
| 16 | CLAUDE.md の追加 | |
| 18 | コンテナをサーバ `kvm` とデスクトップクライアント `kvm-gui` に分割。マルチステージ Containerfile、`container/{common,kvm,gui}/`、共有 `/run/libvirt` とソケット権限による認証 (`auth_unix_rw = "none"`、`libvirt` の gid 固定)、`kvm-libvirt-conf.service`、`kvm.sh` のロール引数、セッション判定による `kvm-gui` だけの作り直し、ハッシュは `kvm` にだけ渡す | 1.1、3.2〜3.5、4.1、4.3、4.4、5.1、5.2、6 |
| 20 | イメージのテンプレートユーザー `admin` を廃止し、`gui-user-setup` が起動時に GUI ユーザーを作成する。`data/home` の seed 元は `/etc/skel` | 3.4、4.6、5.3、5.4 |
