# qemu-kvm 導入・VM 操作の参照情報

[手順書](../setup.md) / [検証記録](../verification/setup.md) / [仕様書](../SPEC.md)

## 手順の背景と実装の説明

### 導入する (1 度だけ) — 手順 1: 変数について

`REPO` は clone 先を指すだけで、`kvm.sh` に渡す変数ではない。`kvm.sh` は自分のあるディレクトリに `cd` してから動き、`data/` もそこ (`KVM_DATA_DIR=$PWD/data`) に作る。VM のディスクや定義はその `data/` に置かれる。

- ホームディレクトリ配下 (`user_home_t`) に置く前提で、seed コンテナと両コンテナはラベル分離なし (`--security-opt label=disable` / `--privileged`) で動かし、`data/` を relabel しない。配置先はユーザーのホームディレクトリ配下にする
- 最後の行は、clone 前 (ディレクトリが無い) には何もしない。新しいシェルで貼り直したときに、以降の `./kvm.sh` が相対パスで動くようにするため。変数のブロックに置く読み戻し以外のコマンドは、この `cd` だけにしている
- `ISO` はホスト側のパス。`ISO=~/Downloads/...` のように `~` で始めれば代入時に展開される (引用符で囲むと展開されない)。[VM 作成の手順 1](../setup.md#vm-を作る-vm-ごとに-1-度) でコピーし、VM 作成の手順 3 では `basename` だけをコンテナ内のパスに付ける
- `ISO` は絶対パス (`~` 始まりを含む) で入れる。相対パスで入れると、この手順の最後の行やこの節の手順 4 の `cd` の後で見つからなくなる
- `VM_NAME` は libvirt のドメイン名で、ディスク `/var/lib/libvirt/images/<VM名>.qcow2`、定義 `data/etc-libvirt/qemu/<VM名>.xml`、UEFI 変数 `data/var-libvirt/qemu/nvram/<VM名>_VARS.fd` の名前になる。削除 (`undefine`) もこの名前で行う
- `VM_MEMORY` は MiB、`VM_DISK` は GiB (`virt-install` の単位)。既定値は旧 README の例 (`alma10` / 4096 / 2 / 20)
- ディスクのバス (SATA の SSD) と NIC のモデル (e1000e) は変数にしていない。VM 作成の手順 3 のコマンドに直接書いてある
- `VM_NETWORK` は VM 作成の手順 3 の `--network network=` に渡す libvirt ネットワークの名前。`default` は NAT (`virbr0`、192.168.122.0/24)、`bridged` は[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)で `KVM_BRIDGE` を付けて登録したホストのブリッジ
- 変数はそのシェルの中だけで有効。以降の手順は、リポジトリ直下 (この節の手順 4 か、貼り直したこの手順の最後の行で移る) で貼る

### 導入する (1 度だけ) — 手順 2: podman と git

`kvm.sh` は `sudo podman` 固定で、rootless podman は使わない。git はこの節の手順 4 の clone と[更新](../setup.md#更新)の `git pull` にだけ使う。

- ホストの libvirt とは無関係なので、ホストに qemu・libvirt を入れてはいけないわけではない。ただし入れて動かしていると `virbr0` が衝突する ([注意点](#注意点))
- ホスト要件は [SPEC.md 2.2](../SPEC.md#22-ホスト要件)、実行ユーザーの要件は [2.3](../SPEC.md#23-実行ユーザーの要件)

### 導入する (1 度だけ) — 手順 4: clone

- clone 元は公開リポジトリの HTTPS の URL で、認証は要らない
- `data/` は git 管理外 (`.gitignore`) で、この節の手順 8 の `up` が初めて作る。clone した直後には無い
- `REPO` にファイルの入った別のディレクトリがあると、`git clone` は `already exists and is not an empty directory` で止まる。`REPO` を変えてこの節の手順 1 から貼り直す

### 導入する (1 度だけ) — 手順 5: ホストの確認

- **ホスト種別の判定は無い**: 画面の有無だけを見る。`KVM_HOST` が `headless` でなく、`DISPLAY` か `WAYLAND_DISPLAY` が設定されていれば `kvm-gui` を起動する (`have_display`。[SPEC.md 2.1](../SPEC.md#21-ディスプレイの判定-have_display))。最後の行はこれと同じ条件で、`KVM_HOST` だけは見ない
- **物理 GNOME**: `kvm.sh up` は実行ユーザーのセッション環境 (`DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY`) を `kvm-gui` に持ち込む。SSH 越しや `sudo -i` のシェルでは `WAYLAND_DISPLAY` などが無く、`kvm-gui` は起動されない (`>> no display found`)
- **SELinux**: Enforcing のままでよい (`kvm` は `--privileged`、`kvm-gui` は `label=disable` でラベル分離が無効)
- **ディスプレイ無し**: `up` は `kvm` だけを起動し、GUI イメージはビルドしない。`up gui` と `viewer` は `!! no display found …` で終了する (それぞれ exit 1 / exit 2)。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` で行い、ゲストにはシリアルコンソールやネットワーク経由でアクセスする ([VM 作成の手順 4](../setup.md#vm-を作る-vm-ごとに-1-度) の補足)
- **画面のあるホストで画面を使わない**: `KVM_HOST=headless` を `up` の前に付ける ([環境変数](#環境変数))。そのときはこの節の手順 7 を飛ばす
- **SSH のシェルの `XDG_RUNTIME_DIR`**: SSH でログインしても設定されるので、`env | grep` に出ることがある。画面の有無は `DISPLAY` / `WAYLAND_DISPLAY` で決まる
- **起動前に確認されるホスト資源** (`check_host_network`): `KVM_BRIDGE` がブリッジでなければ停止、ホストに `virbr0` があれば警告 ([SPEC.md 2.4](../SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

### 導入する (1 度だけ) — 手順 6: ビルド

`Containerfile` は AlmaLinux 10 minimal ベース (`microdnf`) のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、両コンテナ共通の unit マスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui`。

- `./kvm.sh build [kvm|gui]` は `podman build --target <role> -t localhost/kvm-container/<role>:latest` で、余分な引数は `podman build` に渡る。引数なしの `./kvm.sh build` は両方を作る
- この節の手順 6・7 に分けたのは、画面の無いホストで GUI イメージを作らないため。判定はこの節の手順 5 の最後の行と同じ
- どちらのイメージも systemd (`/sbin/init`) で常駐する。イメージ名は固定 ([SPEC.md 3.4](../SPEC.md#34-イメージ仕様-containerfile))
- `up` は足りないイメージを自動でビルドするので、この節の手順 6・7 を飛ばしてもよい。分けてあるのは、ビルドの失敗と起動の失敗を切り分けるため
- ビルドが失敗したら `./kvm.sh build kvm 2>&1 | tee build.log` のように出力を残す (`build.log` は `.gitignore` 済み)

### 導入する (1 度だけ) — 手順 8: 起動する

`./kvm.sh up` の流れ ([SPEC.md 5.1](../SPEC.md#51-起動シーケンス-kvmsh-up)): `/dev/kvm` の確認 (無ければ `modprobe`、0666 に) → root でないことの確認とホストユーザーの名前・uid/gid の取得 → イメージが無ければビルド → `data/` の初期化 → `check_host_network` → `/run/kvm-container/libvirt` を空にする → `kvm` を `podman run` → `>> waiting for libvirt...` (最大 30 秒) → `bridged` ネットワークの同期 → `>> ready.` → ディスプレイがあれば `kvm-gui` を起動。`kvm` が動いていれば `>> kvm is already running` で素通りする。

**`kvm-gui` に渡すもの**

`kvm.sh up` は実行ユーザーのセッション環境をそのまま `kvm-gui` に持ち込む (`kvm` には渡さない)。詳細は [SPEC.md 4.4](../SPEC.md#44-マウント仕様と表示の仕組み) と [6 章](../SPEC.md#6-設計上の不変条件)。

- `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`) をコンテナの **`/run/host-xdg-runtime` に読み取り専用**でマウントし、Wayland ソケットと GNOME の Xwayland 認証ファイルは、その中を指す**絶対パス**で **`WAYLAND_DISPLAY` / `XAUTHORITY`** に渡す (unix ソケットへの接続は読み取り専用でも可)。シンボリックリンクの先が runtime dir の外にある場合は、そのソケットファイルだけを同じパスに読み取り専用でマウントする
- **ホストの runtime dir をコンテナの `/run/user/<uid>` に同じパスでマウントしてはいけない。** コンテナの logind がそのディレクトリを自分のものとして管理し、ユーザーのセッションや `systemd --user` の開始時にホストの session bus や `systemd --user` のソケットを作り直し、`user-runtime-dir@.service` の停止処理で中身をすべて削除してしまう (ホストの Wayland ソケットや session bus が消える)
- **コンテナ内の `/run/user/<uid>` は、コンテナの logind が GUI ユーザー用に作るディレクトリ** (`kvm` では tmpfs、非特権の `kvm-gui` では tmpfs をマウントできないので `/run` 直下のディレクトリ)。`gui-user-setup` がこのユーザーを linger にしているので起動時から存在する (session bus 付き)。GUI アプリはこれを使う
- **`/tmp/.X11-unix` は読み取り専用でマウント** (X11 フォールバック用)。読み取り専用にするのは、コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐため (同じ理由で **`tmpfiles.d/x11.conf` をマスク**)
- **どちらのコンテナでも GUI ユーザーはホストユーザーの写し**: 起動時に `gui-user.service` が `kvm.sh up` を実行したホストユーザーの名前・uid/gid で作る (イメージには一般ユーザーを焼き込んでいない)。ホストの runtime dir は 0700 なので、その中のソケットに届くには uid の一致が必要。**パスワードは設定しない** (コンテナにログインするものは無く、ユーザーはロックされたまま。ホストのパスワードやハッシュはコンテナに渡さない)。値は `podman run -e` で渡し、コンテナ内では PID 1 の environ から読む
- **`/dev/dri` が無いホストではソフトウェア描画** (`LIBGL_ALWAYS_SOFTWARE=1`)。`/dev/dri` があれば `--device` で `kvm-gui` に渡し、`gui` が `renderD*` を 0666 にする
- 渡した引数のハッシュをラベル `kvm.gui-session` に記録し、次の `up` でラベルと、コンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめる (再ログインで `/run/user/<uid>` が作り直されても、`kvm-gui` には古い runtime dir がマウントに残って中身だけ消えるため)。違えば `kvm-gui` だけ作り直す ([再ログインしたとき](../setup.md#再ログインしたとき-繰り返し))

**`data/` の初期化**

| ホスト | コンテナ | 内容 |
| --- | --- | --- |
| `data/var-libvirt` | `/var/lib/libvirt` (kvm) | ディスクイメージ、ISO |
| `data/etc-libvirt` | `/etc/libvirt` (kvm) | VM 定義、ネットワーク定義、qemu.conf |
| `data/home` | `/home/<ホストユーザー名>` (両方) | virt-viewer の設定等 (1 つのホームを両方で使う) |

- ディレクトリが空のときだけ、`kvm.sh up` が `kvm` イメージの一時コンテナ (`--rm --network none --security-opt label=disable`) で初期内容を `cp -a` する (`>> seeding …`)。seed 元は `/var/lib/libvirt` / `/etc/libvirt` / `/etc/skel`。`label=disable` が要るのは、`data/` がユーザーのホーム配下 (`user_home_t`) にあるため
- `sudo podman` で動かすため、ファイルは root や qemu 所有になる。ホストから編集する場合は `sudo` を使う
- コンテナは SELinux のラベル分離なしで動く (`kvm` は `--privileged`、`kvm-gui` は `--security-opt label=disable`) ので、SELinux が Enforcing のホストでも `:Z` などのラベル付けは不要
- `./kvm.sh clean` は確認のうえ `data/` ごと削除する。`down` では残る
- `/run/kvm-container` (libvirt のソケット共有用) は永続化されず、`up` で作り直し `down` で消す。`start_kvm` は `libvirt/` の中身だけを空にする (ディレクトリごと消すと、起動中の `kvm-gui` が古い inode を見続ける)

詳細は [SPEC.md 4.6](../SPEC.md#46-永続化データ-data-と共有-run-dir)。

### 導入する (1 度だけ) — 手順 9: 動作確認

- `systemctl is-system-running` が両コンテナで `running` (`degraded` ではない) ことは、Containerfile の unit マスク群 (`iscsid.socket` / `NetworkManager-wait-online.service` など) が効いているかの実質的な回帰テスト
- `/run/libvirt/virtqemud-sock` が `srw-rw---- root libvirt` なのは `virtd-socket.conf` の drop-in が効いている証拠。`kvm-gui` から一般ユーザーで `virsh` が通ることが、コンテナをまたぐ libvirt 接続の回帰テスト ([選択した方針](#選択した方針))
- `./kvm.sh logs` は `kvm` の `kvm-libvirt-conf` / `virtqemud` / `gui-user` の journal、`./kvm.sh logs gui` は `kvm-gui` の `/var/log/gui.log` と `gui-user` の journal を出す
- 変更後の回帰確認は付録の確認手順 ([物理 GNOME](../setup.md#物理-almalinux-10--gnome-で確認する) / [ディスプレイ無し](../setup.md#ディスプレイの無いホストで確認する) / [VM のライフサイクル](../setup.md#vm-のライフサイクルを確認する)) を手で流す。期待結果は [SPEC.md 9 章](../SPEC.md#9-検証手順)

### VM を作る (VM ごとに 1 度) — 手順 1: ISO の置き場所

- `data/` は `sudo podman` で動くコンテナのバインドマウントなので root や qemu 所有になる。ホストから置く・消すには `sudo` が要る ([SPEC.md 4.6 節](../SPEC.md#46-永続化データ-data-と共有-run-dir))
- `data/var-libvirt` → `kvm` の `/var/lib/libvirt`、`data/etc-libvirt` → `/etc/libvirt`。ISO もディスクも VM 定義もホストの `data/` に残り、`./kvm.sh down` では消えない (`clean` だけが消す)
- SELinux が Enforcing でも `:Z` などのラベル付けは要らない (`kvm` は `--privileged`)

### VM を作る (VM ごとに 1 度) — 手順 3: virt-install のオプション

- `--osinfo` に OS 名を渡す場合の候補は `./kvm.sh virt-install --osinfo list` で確認できる
- `--graphics vnc`・`--noautoconsole`・`--machine q35` と、`bus=sata`・`target.rotation_rate=1`・`model=e1000e` は固定 (理由は後半の補足の[選択した方針](#選択した方針))
- `bus=sata` のディスクのターゲット名は `sda` になる。`--cdrom` の CD-ROM は virt-install が後ろに足すので `sdb` (どちらも SATA で、並び順に `sd*` が振られる)
- `--machine q35` は、ISO から OS を検出できなかったときのため
- 付けないと、検出できなかったときの virt-install は i440fx (`pc-i440fx-…`。RHEL 10 で非推奨) を選び、CD-ROM が IDE の `hda` になる
- `target.rotation_rate=1` は定義の `<target dev='sda' bus='sata' rotation_rate='1'/>` になり、ゲストからはディスクが SSD (非回転) に見える
- `rotation_rate` を付けられるのは SATA / SCSI / IDE のディスクだけ (libvirt 7.3 以降。virtio には無い)
- `model=e1000e` の NIC は Intel 82574L のエミュレーション
- `bus` と `model` を付けないと、virt-install は `--osinfo` で検出した OS から選ぶ。AlmaLinux のような virtio に対応した OS なら `vda` と `virtio` になる
- 新しいディスクはスパースに作られ、virt-install が `discard='unmap'` を付ける (既定)。ゲストの TRIM がホストの qcow2 に届く想定
- SATA (AHCI) と e1000e は、x86_64 の qemu-kvm にはあるが、aarch64 の qemu-kvm には無い
- `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。本書は導入の手順 1 の `VM_NETWORK` で明示し、ホストによってつなぎ先が変わらないようにした。ネットワークの仕様は [SPEC.md 4.5 節](../SPEC.md#45-ネットワークとポート)
- `virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない。キックスタートは `OEMDRV` ラベルの ISO にして渡す ([付録](../setup.md#vm-のライフサイクルを確認する)、[SPEC.md 8 章](../SPEC.md#8-既知の制限事項))
- `--cdrom` の VM は、インストーラの再起動で一度 `shut off` になり、以後はディスクから起動する。インストール後の CD-ROM は空 (`domblklist` の `sdb` が `-`) になる
- Windows と検出した ISO だけは、virt-install が CD-ROM に入れたままにする (インストールが何段階かに分かれるため)。`domblklist` の `sdb` に ISO が残る

### VM を作る (VM ごとに 1 度) — 手順 4: viewer

- `viewer` は先に `up` を実行する。コンテナが止まっていても、再ログインで表示先が変わっていても (`kvm-gui` だけ作り直される)、そのまま使える。VM は動いたまま ([再ログインしたとき](../setup.md#再ログインしたとき-繰り返し))
- VM 名を省くと一覧から選ぶダイアログが出る
- ディスプレイの無いホスト (`DISPLAY` / `WAYLAND_DISPLAY` が無い、または `KVM_HOST=headless`) では `!! no display found ...` で終了コード 2 になる。シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で、抜けるのは `Ctrl+]`。ISO のインストーラがシリアルに出るかは ISO 次第
- `viewer` は virt-viewer のウィンドウが閉じるまで戻らない。VM が `shut off` になるとウィンドウは自動で閉じる ([SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル))

### VM を作る (VM ごとに 1 度) — 手順 5: 動作確認

- `domblklist` は削除の前にも使う。ディスクのターゲット名 (`sda` など) と CD-ROM (`sdb`) の中身が分かる
- ターゲット名はバスで決まる。SATA はディスクも CD-ROM も `sd*` で、virtio のディスクは `vd*` (virtio で作った VM はディスクが `vda`、CD-ROM が `sda`)
- `grep` は定義の `<target>` の行を拾う。CD-ROM の行は `<target dev='sdb' bus='sata'/>` で、`rotation_rate` はディスクにだけ付く
- `domiflist` の `Interface` は、VM が止まっている間は `-` (動いている間は `vnet0` など)
- ディスクファイルは `data/var-libvirt/images/<VM名>.qcow2`。`sudo ls -l` で所有者が root / qemu になっているのは仕様 (この節の手順 1 の補足)

### VM を使う (繰り返し) — 手順 6: 停止の仕組み (libvirt-guests)

- `virsh shutdown` は ACPI の電源ボタンに相当し、ゲスト OS がシャットダウンを行う。`destroy` は電源断
- `./kvm.sh down` (と `clean`) では、コンテナ内の `libvirt-guests.service` (`container/kvm/libvirt-guests`: `ON_SHUTDOWN=shutdown` / `ON_BOOT=ignore` / `SHUTDOWN_TIMEOUT=120`) が動いている VM を一斉に ACPI でシャットダウンする。これが無いとコンテナの systemd が qemu の scope をすぐ止め、VM は電源断と同じ状態になる
- `down` の `podman rm -t` は 180 秒 (`kvm.sh` の `KVM_STOP_TIMEOUT`) で、VM の待ちは 120 秒。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は scope の停止で電源を切られる ([SPEC.md 5.2 節](../SPEC.md#52-停止シーケンス-kvmsh-down))
- `ON_BOOT=ignore` なので、`down` の時点で動いていた VM は次の `up` で起動しない。起動するのは `virsh autostart` を設定した VM だけ (`data/etc-libvirt/qemu/autostart/` の symlink)

### VM をホストのブリッジにつなぐ (任意) — 手順 1: 変数について

- `REPO` と `VM_NAME` は[導入の手順 1](../setup.md#導入する-1-度だけ) の変数を使う (この節では設定しない)
- `NIC_CON` (接続名) と `NIC` (デバイス名) は別物で、同じとは限らない (`Wired connection 1` のような名前のことがある)。`nmcli connection down` は接続名を取るので、`nmcli -g NAME,DEVICE connection show --active` の出力からデバイス名で引いている
- `NIC_CON` はこの手順を貼った時点の値を保持する。この節の手順 4 で NIC の接続を切り替えたあとにシェルを開き直してこの手順を貼ると、NIC に付いている接続は `bridge-slave-<NIC>` なので `NIC_CON` はその名前になる。ロールバックで元の接続名が要るので、この手順の読み戻しの出力を控えておく

### VM をホストのブリッジにつなぐ (任意) — 手順 3: nmcli でブリッジを作る

- 1 行目で `type bridge` の接続 `${BRIDGE}` を作り (ifname と con-name を同じにする。`ipv4.method auto` はブリッジが DHCP で IP を受ける設定)、2 行目で NIC を収容する `type bridge-slave` の接続を作る (接続名は指定していないので NetworkManager の既定 `bridge-slave-<NIC>` になる)
- 無線 NIC はここでは使えない ([無線 NIC は L2 ブリッジできない](#無線-nic-は-l2-ブリッジできない))

### VM をホストのブリッジにつなぐ (任意) — 手順 4: 接続の切り替え

- NIC の元の接続を落とし、ブリッジを上げる。これで NIC は bridge-slave としてブリッジに付き、IP はブリッジ側に来る。その NIC 越しの ssh はここで切れる (`&&` の 2 つ目が走らずに終わることがあるので、コンソールから貼る)

### VM をホストのブリッジにつなぐ (任意) — 手順 5: ブリッジの判定

- `ls -d /sys/class/net/<ブリッジ名>/bridge` は、`kvm.sh` の `check_host_network` が `KVM_BRIDGE` をブリッジと判定する条件そのもの ([SPEC.md 2.4](../SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

### VM をホストのブリッジにつなぐ (任意) — 手順 6: `down kvm`

- `down kvm` は動いている VM を `libvirt-guests` が ACPI でシャットダウンしてから止める (120 秒で電源断、`podman rm -t` は 180 秒。[SPEC.md 5.2](../SPEC.md#52-停止シーケンス-kvmsh-down))。`down` の時点で動いていた VM は次の `up` で起動しない (`virsh autostart` の VM を除く。[VM 作成の手順 6](../setup.md#vm-を作る-vm-ごとに-1-度))。`down kvm` の間 `kvm-gui` は残るが libvirt に届かない状態になり、次の `up` で `kvm` が起動して共有の `/run/libvirt` が空にされると復帰する。`down` (両方) でもよい

### VM をホストのブリッジにつなぐ (任意) — 手順 7: `bridged` の登録と `KVM_BRIDGE` の付け忘れ

- `bridged` の登録は `sync_bridged_network` ([SPEC.md 5.6](../SPEC.md#56-ブリッジ同期-sync_bridged_network)) が行う。これは `start_kvm` が `podman run` で `kvm` を新しく起動し、libvirt の readiness を確認した直後にしか走らない。`kvm` がすでに動いていると `start_kvm` は `>> kvm is already running` で先に戻るので (`kvm.sh` の `start_kvm` 冒頭)、`KVM_BRIDGE=` を付けて `up` しても何も起きない。そのためこの節の手順 6 の `down kvm` と手順 7 の `KVM_BRIDGE=… up` に分けてある
- 起動前に `check_host_network` が `/sys/class/net/<ブリッジ名>/bridge` の有無を確かめ、無ければ `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/setup.md)` で exit 1 する ([SPEC.md 2.4](../SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))。この節の手順 3・4 を飛ばしたときに出る
- `sync_bridged_network` は毎回 define し直す (active なら `net-destroy` してから define → autostart → start)。`KVM_BRIDGE` の値を変えるとその値に追従する。`KVM_BRIDGE` が無いと `bridged` を `net-destroy` / `net-undefine` する。定義は `data/etc-libvirt` (`/etc/libvirt/qemu/networks/`) に永続化されるが、この削除で消える
- `viewer` は内部で `up` を呼ぶ (`kvm` が止まっていれば起動する) ので、`kvm` が止まった状態で `KVM_BRIDGE=` 無しに `viewer` を実行すると `bridged` が削除される。`kvm` を起動し得る経路 (`up`、`up kvm`、`viewer`) には毎回 `KVM_BRIDGE=` を付ける。`up gui` は `kvm` に触らないので影響しない

### VM をホストのブリッジにつなぐ (任意) — 手順 8: 動作確認

- `net-list` で `bridged` が active なこと。`KVM_BRIDGE` 周りを変えたときの確認点は [SPEC.md 9.4](../SPEC.md#94-その他の確認点-変更内容に応じて) (`KVM_BRIDGE` 無しで `up` すると消えることも含む)
- `net-dumpxml bridged` は `kvm.sh` が define した XML (`<name>bridged</name>`、`<forward mode="bridge"/>`、`<bridge name="<ブリッジ名>"/>`) を返す想定。出力にはこれに libvirt が足す `<uuid>` などが加わる

### VM をホストのブリッジにつなぐ (任意) — 手順 9: VM の接続

- `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。この節の手順 4 のあとはホストの既定経路がブリッジ上にあるので、`--network` を省いた VM もそのブリッジに直接つながり得る (この経路は `bridged` を経由しない)。[VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) は `VM_NETWORK` で `--network` を明示する ([SPEC.md 8 章](../SPEC.md#8-既知の制限事項))
- `bridged` の VM は tap がブリッジのポートになり、VM 自身の MAC で LAN に出る。仮想スイッチが MAC アドレスの詐称を許さない環境では、この形は通信できない
- 既存の VM の付け替えは、`kvm` イメージにエディタが無いので `virsh edit` がそのままでは使えない

## 使い方の基本

| サブコマンド | 用途 | 使う手順 |
|---|---|---|
| `./kvm.sh build [kvm\|gui]` | 2 つのイメージをビルド (`localhost/kvm-container/kvm`、`localhost/kvm-container/gui`)。`build kvm` / `build gui` で片方だけ | [導入の手順 6〜7](../setup.md#導入する-1-度だけ) |
| `./kvm.sh up [kvm\|gui]` | `kvm` を起動し、ディスプレイがあれば `kvm-gui` も起動 (kvm モジュールのロードと `/dev/kvm` の権限調整も行う)。`up gui` は `kvm-gui` だけ (再ログイン後など。`up` は `kvm-gui` が別のセッション用なら作り直す) | [導入の手順 8](../setup.md#導入する-1-度だけ) / [VM 利用の手順 1](../setup.md#vm-を使う-繰り返し) / [再ログインの手順 1](../setup.md#再ログインしたとき-繰り返し) |
| `KVM_BRIDGE=br0 ./kvm.sh up` | VM をホストのブリッジ `br0` に接続できるようにして起動 | [ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)の手順 7 |
| `./kvm.sh virt-install ...` | VM を作る (`kvm` コンテナ内の virt-install) | [VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) |
| `./kvm.sh virsh ...` | virsh (`kvm` コンテナ)。`list` / `start` / `shutdown` / `destroy` / `undefine` など | [VM 作成の手順 5〜6](../setup.md#vm-を作る-vm-ごとに-1-度) / [VM 利用の手順 2〜5](../setup.md#vm-を使う-繰り返し) / [VM を削除する](../setup.md#vm-を削除する) |
| `./kvm.sh viewer [VM名]` | VM の画面を virt-viewer で表示 (VM 名を省くと一覧から選ぶダイアログ) | [VM 作成の手順 4](../setup.md#vm-を作る-vm-ごとに-1-度) / [VM 利用の手順 3](../setup.md#vm-を使う-繰り返し) |
| `./kvm.sh shell [kvm\|gui]` | コンテナ内 root シェル (既定 `kvm`) | [導入の手順 9](../setup.md#導入する-1-度だけ) |
| `./kvm.sh logs [kvm\|gui]` | libvirt の journal と GUI アプリのログ | [導入の手順 9](../setup.md#導入する-1-度だけ) |
| `./kvm.sh down [kvm\|gui]` | コンテナ停止・削除 (VM のディスク / 定義はホストの `data/` に残る)。引数なしで両方 | [VM 利用の手順 6](../setup.md#vm-を使う-繰り返し) / [ロールバック](../setup.md#ロールバック)の手順 5 |
| `./kvm.sh clean` | コンテナと `data/` のデータをすべて削除 (確認あり) | [ロールバック](../setup.md#ロールバック)の手順 6 |

- `up` は足りないイメージを自動でビルドする。`viewer` は先に `up` を実行するので、コンテナが止まっていても、再ログインで表示先が変わっていても、そのまま使える
- `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `TZ`) は、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける。一覧は[環境変数](#環境変数)
- `./kvm.sh` を引数なしで実行すると、`kvm.sh` 冒頭のヘッダコメント (サブコマンドと環境変数の一覧) が出る

---


## 全体の参照情報


### 対応対象と進め方

- **目的**: qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナに収め、qemu も libvirt も入れていない軽量なホストで VM を動かし、その画面をホストのデスクトップに表示する
  - VM の作成・操作はコマンドライン (`./kvm.sh virt-install` / `./kvm.sh virsh`。`kvm` コンテナ内の `virt-install` / `virsh --connect qemu:///system` の省略形)、画面の表示は `./kvm.sh viewer` (`kvm-gui` の virt-viewer。ブラウザや Web コンソールは使わない)
  - VM のディスクは SATA の SSD、NIC は e1000e にする (VM 作成の手順 3。x86_64 のホスト向け)
  - `kvm-gui` は `kvm` の libvirt に共有 unix ソケット経由で接続する。デスクトップの再ログイン後は `kvm-gui` だけを作り直せるので、VM を止めずに済む
  - ディスプレイの無いホストでは `kvm` だけを使う (GUI イメージのビルドも不要)
  - 任意で、VM にホストと同じセグメントの IP (LAN の DHCP) を割り当てることもできる
- **進め方**: ホストに入れるのは podman と git だけ。clone した `kvm.sh` が `sudo podman` でビルド・起動・停止をすべて行う
  - 導入の手順 1 で ISO のパスと VM 名を決め、以降のコマンドはそのまま貼る
  - 読者が書き換えるのは `ISO` だけ (ブリッジの節では `NIC` も)。clone 先・VM 名・メモリ・vCPU・ディスク・ネットワークは既定のままでもよい
対応ホスト:

| ホスト | 画面表示 |
| --- | --- |
| 物理マシン / VM の AlmaLinux 10 + GNOME | GNOME (Wayland) デスクトップに表示 |
| ディスプレイの無いホスト (SSH のみ) | 画面表示なし。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[導入の手順 1](../setup.md#導入する-1-度だけ) (ブリッジの節ではその節の手順 1 も) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 設定する手順 | 意味 | 例 |
> |---|---|---|---|
> | `${ISO}` | 導入の手順 1 | ダウンロードした ISO のホスト側パス。VM 作成の手順 1 で `data/var-libvirt/images/` にコピーし、VM 作成の手順 3 では `basename` だけを使う | `~/Downloads/AlmaLinux-10-latest-x86_64-dvd.iso` |
> | `${REPO}` | 導入の手順 1 | このリポジトリを clone する場所。`data/` はこの中にできる。ユーザーのホームディレクトリ配下にする | `~/kvm-container` |
> | `${VM_NAME}` | 導入の手順 1 | VM 名。ディスク (`<VM名>.qcow2`)、定義 (`data/etc-libvirt/qemu/<VM名>.xml`)、UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`) の名前になる | `alma10` |
> | `${VM_MEMORY}` / `${VM_VCPUS}` / `${VM_DISK}` | 導入の手順 1 | `virt-install` の `--memory` (MiB) / `--vcpus` / `--disk size=` (GiB) | `4096` / `2` / `20` |
> | `${VM_NETWORK}` | 導入の手順 1 | VM をつなぐ libvirt ネットワーク (`virt-install --network network=`)。`default` は NAT、`bridged` はブリッジの節で登録したホストのブリッジ | `default` / `bridged` |
> | `${NIC}` | ブリッジの節の手順 1 | ブリッジに収容する物理 NIC の名前。`ip -br link` で確認する | `enp1s0` |
> | `${BRIDGE}` | ブリッジの節の手順 1 | 作るブリッジの名前。`nmcli` の接続名にも同じ名前を使い、`KVM_BRIDGE` に渡す | `br0` |
> | `${NIC_CON}` | ブリッジの節の手順 1 | NIC に今付いている NetworkManager の接続名。NIC 名と同じとは限らない (`nmcli -g NAME,DEVICE connection show --active` から自動で入る) | `enp1s0` / `Wired connection 1` |
>
> - `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `TZ`) は導入の手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける ([環境変数](#環境変数))
> - 出力例・表の中の値は `<VM名>` / `<uid>` / `<ホストユーザー名>` / `<ブリッジ名>` / `<NIC>` のプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない
> - パスワード・鍵・トークンは扱わない。コンテナにはホストのパスワードもハッシュも渡していない (GUI ユーザーはロックされたまま)。ゲスト OS のパスワードと sudoers の内容もこの文書に載せない


### 実施前の状態

| 項目 | 状態 |
|---|---|
| ホスト OS | AlmaLinux 10 (物理 / VM)。qemu・libvirt・virt-viewer は未導入のままでよい (要らない) |
| podman / git | 未導入、または導入済み (podman は root で使う) |
| ホストの `sudo` | 一般ユーザーがパスワード無しで `sudo` を実行できる (`podman` / `dnf` / `cp` / `nmcli` など本書が使うすべて)。sudoers は読者が設定する (本書では扱わない) |
| 仮想化支援 | KVM が使える CPU (SVM / VT-x が有効。VM の中で動かすならネストした仮想化) |
| 画面 | GNOME (Wayland) のセッション。無ければ `kvm` だけを使う |
| `/dev/kvm` | 無くてよい。`up` が `kvm_amd` / `kvm_intel` をロードして 0666 にする |
| ホスト上の libvirt | 動いていないこと (`virbr0` / 192.168.122.0/24 が衝突する) |
| リポジトリ | まだ clone していなくてよい (導入の手順 4 で clone する)。clone 済みならユーザーのホームディレクトリ配下にあること。`data/` はまだ無い |
| ISO | ホストにダウンロード済み (`data/` の外) |
| VM | 無い (あっても構わない。導入の手順 1 の `VM_NAME` が重ならないようにする) |
| ホストの NIC (ブリッジの節) | 物理 NIC に NetworkManager の接続が 1 つ付き、LAN の DHCP から IP を持っている。ブリッジは無い |
| libvirt ネットワーク (ブリッジの節) | `default` (NAT、`virbr0`、192.168.122.0/24) だけ。`bridged` は未定義 |

### 選択した方針

| コンテナ | 中身 | 権限 |
| --- | --- | --- |
| `kvm` | libvirt + qemu-kvm + virt-install (サーバ側。VM が動いている間は常駐) | `--privileged --network host` |
| `kvm-gui` | virt-viewer (デスクトップ側。ディスプレイのあるホストだけ) | 非特権 (`--network host`, SELinux ラベル分離なし) |

- **コマンドライン + virt-viewer**: VM の作成・操作は `kvm` コンテナ内の `virt-install` / `virsh` をパススルーし、画面は `kvm-gui` の virt-viewer で出す
  - `./kvm.sh virt-install` は `sudo podman exec -it kvm virt-install --connect qemu:///system`、`./kvm.sh virsh` は `sudo podman exec -it kvm virsh -c qemu:///system` の省略形 ([SPEC.md 4.1 節](../SPEC.md#41-cli-kvmsh-サブコマンド-ロール-))。ホストに virt-install / virsh を入れない
  - ブラウザや Web コンソール (cockpit) は廃止した (PR #25)
  - RHEL 10 系の qemu-kvm には SPICE が無いので、グラフィックスは VNC (下の `--graphics vnc`)
- **`kvm` は `--privileged --network host`**: KVM、libvirt の `default` ネットワーク (NAT / dnsmasq)、ホストのブリッジへの接続のため
  - `kvm-gui` は非特権だが `--security-opt label=disable`。SELinux Enforcing のホストで、特権コンテナが作った unix ソケットへ接続し、ホストの runtime dir を読むため
- **コンテナをまたぐ libvirt 接続**: `/run/libvirt` はホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナにバインドマウントしたもの。詳細は [SPEC.md 3.5](../SPEC.md#35-コンテナ間の-libvirt-接続) と [6 章](../SPEC.md#6-設計上の不変条件)
  - 別コンテナからの接続では、デーモンが `SO_PEERCRED` で得る pid が 0 になる (pid 名前空間が違う)。そのため libvirt 既定の polkit 認証は使えない
  - 代わりに `auth_unix_rw = "none"` にし、ソケットの権限 (`root:libvirt 0660`) でアクセスを制限する
  - モジュラーデーモンは systemd のソケット活性化なので、権限は `/etc/libvirt/*.conf` の `unix_sock_*` ではなく `virt*d.socket` の drop-in (`container/kvm/virtd-socket.conf`) で決まる
  - `libvirt` グループの gid は両イメージで同じ値に固定し (Containerfile の `LIBVIRT_GID`)、`kvm-gui` 側のユーザーがこのグループでソケットに届くようにする
  - `/etc/libvirt` はホストの `data/etc-libvirt` で、空のときしかイメージから初期化されない。そのため `auth_unix_rw` と qemu.conf の設定 (`security_driver = "none"`、`namespaces = []`) は、`kvm` の起動時に `kvm-libvirt-conf.service` が毎回冪等に書き込む (既存の `data/` もそのまま使える)
- **`sudo podman`**: `kvm.sh` は root の podman を `sudo` で呼ぶ (`PODMAN="sudo podman"` 固定)
  - `--privileged`、`--network host`、`/dev/kvm` の受け渡し、ホストの `/run` 配下のディレクトリ共有のため
  - 利用者は `sudo` を付けずに `./kvm.sh` を実行する
  - 手順書は `sudo` がパスワードを聞かない前提で書き、手順を分けるのは完了待ちや対話入力があるときだけにする (前提は[実施前の状態](#実施前の状態))
- **`data/` はバインドマウント**: リポジトリ内の `data/` (git 管理外) 配下のディレクトリをコンテナにバインドマウントする
  - バインドマウントは named volume と違い、初回にイメージ側の内容をコピーしない
  - そのため空のときだけ、`kvm.sh up` が `kvm` イメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動する ([導入の手順 8 の補足](../setup.md#導入する-1-度だけ))
- **分岐はブロックの中で判定する**: 導入で画面の有無によって変わるのは、GUI イメージのビルド (導入の手順 7) と `kvm-gui` の確認 (導入の手順 9) だけ。どちらもブロックの中で判定し、どちらのホストでも同じブロックを上から貼れるようにした
  - VM の画面を出す VM 作成の手順 4 と VM 利用の手順 3 は、ディスプレイの無いホストでは `!! no display found ...` で終わる
- **実施手順はシナリオで見出しを分ける**: 1 度だけ行う導入と VM の作成、繰り返し行う VM の利用と再ログイン後の作り直しを、`## 実施手順` の下の見出しに分けた
  - 手順の番号は見出しごとに 1 から数え、ほかの見出しの手順は「導入の手順 1」「VM 利用の手順 2」のように呼ぶ
  - 繰り返すシナリオは、導入の手順 1 の変数を貼り直せば、その見出しの手順 1 から始められる
- **画面は端末から開く**: アクティビティ (アプリ一覧) からの起動は廃止した。端末の無い `sudo -n` を前提にしたうえ、画面を端末から開く方式に統一したため
  - `KVM_SOFTWARE_GL` (ソフトウェア描画の強制) と `KVM_CLEAN_YES` (`clean` の確認の省略) も廃止した。`/dev/dri` が無いホストでは、今までどおり自動でソフトウェア描画になる
  - ホストの音声 (PulseAudio / PipeWire) のソケットは `kvm-gui` に渡さない。VNC の VM 画面を出す virt-viewer では使わないため
- **`--graphics vnc`**: RHEL 10 系の qemu-kvm には SPICE が無いため。VNC は `kvm` がホストの loopback で listen し、`kvm-gui` の virt-viewer が libvirt 経由で接続する
- **`--noautoconsole`**: `kvm` コンテナに virt-viewer が無いため。画面は `./kvm.sh viewer` で開く
- **`--osinfo detect=on,require=off`**: ISO から OS を検出し、検出できなくても中断しない。OS 名を渡すなら `--osinfo list` の候補から選ぶ
- **`--network` は明示する**: 省くと virt-install がホストの既定経路からつなぎ先を選び、ブリッジのあるホストでは `default` にならない。導入の手順 1 の `VM_NETWORK` (既定 `default`) で決め、[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)を通したホストでは `bridged` を選べるようにした
- **ディスクは SATA の SSD、NIC は e1000e**: VM 作成の手順 3 で `--machine q35`、`--disk` に `bus=sata,target.rotation_rate=1`、`--network` に `model=e1000e` を付けて固定する
  - ゲストには、準仮想化の virtio ではなく実機と同じ種類の装置 (AHCI の SATA、Intel 82574L の NIC) に見える。virtio のドライバが無い OS でも扱える (性能は一般に virtio より低い)
  - 付けないと、virt-install は `--osinfo` の検出結果でマシン (q35 / i440fx)・ディスク・NIC を選ぶ。明示して、ISO によらず同じ構成にする
  - ターゲット名はディスクが `sda`、`--cdrom` の CD-ROM が `sdb`。削除 (`--storage sda`) と CD-ROM の取り出し (`change-media … sdb`) はこの名前で指定する
  - x86_64 のホスト向け。aarch64 の qemu-kvm には SATA (AHCI) と e1000e が入っていない ([VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) の補足)
- **ISO は `data/var-libvirt/images/` に置く**: ホストの `data/var-libvirt` が `kvm` コンテナの `/var/lib/libvirt` なので、コンテナ内では `/var/lib/libvirt/images/` に見える。VM 作成の手順 3 の `--cdrom` に渡すのはコンテナ内のパス
- **削除は `undefine --nvram --storage sda`**: `--remove-all-storage` は CD-ROM に入ったままの ISO も消すので、消すディスクを `--storage` で指定する。`--nvram` は UEFI の VM に必須で、BIOS の VM に付けても害は無い

### 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `headless` にすると、表示用環境変数があっても `kvm-gui` を起動しない (他の値は `auto` と同じ) |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_BRIDGE` | 未設定 | ホストの既存ブリッジ名 (例 `br0`)。libvirt ネットワーク `bridged` として登録し、VM をホストと同じセグメントに接続できる。手順は[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意) |

いずれも `KVM_HOST=headless ./kvm.sh up` のようにコマンドの前に付ける。`kvm.sh` がどこで読むかは [SPEC.md 4.2](../SPEC.md#42-環境変数-ホスト側の入力)。

### ブリッジにつなぐときの補足

[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)全体にかかわる方針・状態・注意点。

#### ブリッジの方針

- **ブリッジはホスト側で作り、`kvm.sh` は名前を受け取るだけ**: `kvm.sh` はホストのネットワーク設定を変更しない ([SPEC.md 1.2](../SPEC.md#12-スコープ外))
  - コンテナ内の NetworkManager はマスクしてあり (入るとホストの NIC を管理し始める)、ブリッジを作る場所はホストしかない
- **`--network host` の上に `<forward mode="bridge"/>`**: `kvm` コンテナがホストのネットワーク名前空間を共有するので、libvirt はホストのブリッジに VM の tap を直接つなげる
  - `KVM_BRIDGE` のブリッジを libvirt ネットワーク `bridged` として登録し、VM 側は `--network network=bridged` で選ぶ (導入の手順 1 の `VM_NETWORK=bridged`)
  - 定義は `data/etc-libvirt` に永続化され、`KVM_BRIDGE` を付けずに `up` すると削除される ([SPEC.md 4.5](../SPEC.md#45-ネットワークとポート))
- **IP はブリッジ側に持たせる**: 物理 NIC をブリッジのポートにし、`ipv4.method auto` でブリッジが DHCP を受ける。VM はホストと同じ LAN の DHCP から IP を受け取る
- **`default` (NAT) はそのまま残る**: `bridged` は追加であり、`default` を置き換えない。ブリッジを作れないホスト (無線 NIC しか無いなど) は `default` を使う

#### ブリッジを作った後の状態

想定される状態:

- ホスト: `nmcli connection show` に `<ブリッジ名>` (bridge) と `bridge-slave-<NIC>` (ethernet) があり、NIC の元の接続は inactive
  - `ip -br addr` で LAN の IP はブリッジに付き、NIC は IP を持たない。`/sys/class/net/<ブリッジ名>/bridge` がある
- libvirt (`./kvm.sh virsh net-list --all`): `default` と `bridged` がともに active / autostart。`bridged` の定義は `data/etc-libvirt/qemu/networks/bridged.xml` に永続化される
- `kvm.sh`: `KVM_BRIDGE=<ブリッジ名>` を付けた `up` / `viewer` で `>> libvirt network "bridged" -> host bridge <ブリッジ名> ...` が出る。付けないと `>> KVM_BRIDGE is not set: removing the libvirt network "bridged"` で消える
- VM: `--network network=bridged` で作った VM は LAN の DHCP から IP を取り、ホストの隣接テーブルには VM 自身の MAC が載る

#### 毎回 `KVM_BRIDGE=` を付ける

- `bridged` は `kvm` の起動時に `KVM_BRIDGE` の有無で同期される
  - `KVM_BRIDGE=` を付けずに `kvm` を起動する経路 (`up`、`up kvm`、`viewer`) を 1 度でも通ると `bridged` は削除される
  - [VM 利用の手順 1](../setup.md#vm-を使う-繰り返し) と[更新](../setup.md#更新)の手順 2 の `up` もこの経路に当たる
- ブリッジがホストに無い (ブリッジの節の手順 3 の前、再起動でブリッジが上がっていない、名前の打ち間違い) と、`up` は `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/setup.md)` と本書を指して exit 1 する。ホスト側のブリッジを直してから `up` し直す

#### ホストのネットワーク名前空間の共有

`kvm` / `kvm-gui` はともに `--network host` で、libvirt が作るものはすべてホスト上に現れる。全体は[注意点](#注意点)。ブリッジに関わるのは次の 2 点:

- ホストに `virbr0` が残っていると (ホスト自身の libvirt、またはコンテナの異常終了の残骸) `up` が警告し、`default` の起動が失敗する。残骸なら `sudo ip link del virbr0` で消す
  - `bridged` はこれとは別で、ホストのブリッジを `kvm.sh` が消すことは無い
  - `kvm-net-teardown.service` は active な libvirt ネットワークを `net-destroy` し、`ip link del` のフォールバックは `virbr*` だけに掛ける。`<forward mode="bridge"/>` の `net-destroy` はホストのブリッジに触らない
- コンテナ内の NetworkManager はマスクしてある (入るとホストの NIC やブリッジを管理し始める)。ブリッジの操作は必ずホストの `nmcli` で行う

#### 無線 NIC は L2 ブリッジできない

Wi-Fi の NIC は (4 アドレス形式などの例外を除き) 自分以外の MAC のフレームを送れないので、ブリッジのポートにしても VM は LAN に出られない。

- 有線 NIC のあるホストで行う。無線しか無いホストは `default` (NAT) を使う

### VM を削除するときの注意

- UEFI の VM (`<os firmware='efi'>`) は `--nvram` が無いと `Cannot undefine domain with NVRAM/varstore` で失敗する。BIOS の VM に付けても害は無い
- `--remove-all-storage` は CD-ROM に入ったままの ISO も削除する
  - 複数の VM で共有している ISO を消さないように、`--storage sda` のように消すディスクを指定する
  - または先に `./kvm.sh virsh change-media <VM名> sdb --eject --config` で取り出す (`--cdrom` でインストールした VM は、Windows 以外はインストール後に取り出されているが、後から入れた場合は残る)
- `undefine --nvram --storage sda` で消えるのは定義 (`data/etc-libvirt/qemu/<VM名>.xml`)・UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`)・`sda` のディスクだけで、ISO は残る ([SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル))
- ターゲット名は作ったときのバスで決まる。VM 作成の手順 3 の VM はディスクが `sda`・CD-ROM が `sdb`、virtio で作った VM はディスクが `vda`・CD-ROM が `sda`
  - virtio の VM に `--storage sda` を付けると、CD-ROM に入ったままの ISO が消え、qcow2 は残る
  - CD-ROM が空なら `Volume 'sda' was not found in domain's definition.` で止まり、何も消えない
  - そのため、[VM を削除する](../setup.md#vm-を削除する)の手順 1 で `vda` が出たら、`sda` を `vda` に、`sdb` を `sda` に読み替える

### 完了時点の状態

想定される状態 (出力例は本書用の整形で、実測の写しではない):

- `sudo podman ps` に `kvm` (イメージ `localhost/kvm-container/kvm:latest`) と、ディスプレイのあるホストでは `kvm-gui` (`localhost/kvm-container/gui:latest`) が `Up` で並ぶ。ディスプレイの無いホストは `kvm` だけ
- `sudo ls "${REPO}/data"` は `etc-libvirt  home  var-libvirt` (root 所有)。`ls /run/kvm-container/libvirt` に libvirt のソケットが並ぶ
- 両コンテナで `systemctl is-system-running` が `running`
  - `kvm` では `virtqemud` など libvirt のモジュラーデーモンがソケット活性化で待ち受け、`libvirt-guests.service` が有効
  - GUI ユーザー (ホストユーザーの写し) がロックされた状態で存在し、`/run/user/<uid>` と session bus がある
- ホスト上に libvirt の `virbr0` (192.168.122.0/24)、dnsmasq、nftables のルールができる (`--network host`)
- 導入の手順 9 の時点では `./kvm.sh virsh list --all` は空 (VM は[VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度)で作る)
- コンテナ実行仕様の表は [SPEC.md 1.1](../SPEC.md#11-目的) と [3.3](../SPEC.md#33-コンテナ実行仕様-podman-run)、共有物とマウントの表は [4.4](../SPEC.md#44-マウント仕様と表示の仕組み)、ファイル一覧は [付録 A](../SPEC.md#付録-a-ファイル一覧とコンテナ内配置)

VM 作成の手順 6 まで終えた直後 (VM は停止、自動起動あり):

```
$ ./kvm.sh virsh list --all
 Id   Name     State
-------------------------
 -    <VM名>   shut off
$ ./kvm.sh virsh domblklist <VM名>
 Target   Source
------------------------------------------------
 sda      /var/lib/libvirt/images/<VM名>.qcow2
 sdb      -
$ ./kvm.sh virsh dominfo <VM名> | grep -i autostart
Autostart:      enable
$ sudo ls data/var-libvirt/images data/var-libvirt/qemu/nvram data/etc-libvirt/qemu data/etc-libvirt/qemu/autostart
data/var-libvirt/images:
<ISO ファイル名>  <VM名>.qcow2
data/var-libvirt/qemu/nvram:
<VM名>_VARS.fd
data/etc-libvirt/qemu:
<VM名>.xml  autostart  networks
data/etc-libvirt/qemu/autostart:
<VM名>.xml
```

- この出力例は `virsh` の表示形式から組み立てたもので、そのまま取った実測ではない。列の幅などは異なり得る
- `./kvm.sh up` で `kvm` が起動すると `<VM名>` は `running (booted)` になる
- NIC は `domiflist` の `Model` が `e1000e`、ディスクは定義で `bus='sata'`・`rotation_rate='1'` ([VM 作成の手順 5](../setup.md#vm-を作る-vm-ごとに-1-度))
- 「VM を削除する」まで行うと `<VM名>.qcow2` / `<VM名>.xml` / `<VM名>_VARS.fd` が消え、ISO だけが残る

### 注意点

- **`kvm.sh` は一般ユーザーで実行する**。root で実行すると止まる (コンテナ内のユーザーをホストユーザーに合わせるため)
- **再ログイン後は `up`**: GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えた場合は `./kvm.sh up` を実行する。`kvm-gui` だけが作り直され、VM は動いたまま (`viewer` も同じことをしてから起動する。[再ログインしたとき](../setup.md#再ログインしたとき-繰り返し))
- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu なので、`down` で VM を止めてからホストを止める ([VM 利用の手順 6](../setup.md#vm-を使う-繰り返し))
  - `down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない
  - `down` (と `clean`) は動いている VM を先に ACPI でシャットダウンする (`libvirt-guests.service`)。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は電源を切られる
  - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には `virsh autostart` を設定する ([VM 作成の手順 6](../setup.md#vm-を作る-vm-ごとに-1-度))
- **ACPI に応じない VM**: OS の無い VM や ACPI の電源ボタンを無視する OS は、`virsh shutdown` では止まらず、`down` でも 120 秒待ったあと電源断と同じ状態で止まる。`destroy` で止める
- **`data/` は root 所有**: ホストから読み書きするには `sudo` がいる。SELinux Enforcing でも `:Z` は不要。`data/` を消すのは `clean` だけ (`down` では残る)
- **ホストのネットワーク名前空間を共有する** (`--network host`、両コンテナ):
  - ホスト自身で libvirt を動かしていると `virbr0` / 192.168.122.0/24 が衝突する。`up` 時にホストに `virbr0` があると警告する (警告だけで `up` は止まらない。コンテナの異常終了で残った場合は `down` してから `sudo ip link del virbr0` で削除し、`up` し直す)
  - `kvm-gui` も `--network host` (virt-viewer が VM の VNC に届くため)。listen するものは無いので、ホストと衝突するポートやソケットは無い。`kvm` 側も VM の VNC (loopback) 以外にホストで listen するものは無い
  - libvirt の `default` ネットワークの `virbr0`・dnsmasq・nftables ルールはホスト上に作られ、`net.ipv4.ip_forward=1` もホストに効く
  - コンテナ内の `iscsid.socket` / `iscsiuio.socket` (abstract unix ソケットがホストの `iscsid` と衝突して degraded になる) と NetworkManager (入るとホストの NIC を管理し始める) はマスクしている ([SPEC.md 4.5](../SPEC.md#45-ネットワークとポート) / [6 章](../SPEC.md#6-設計上の不変条件))
- **壊しやすい不変条件** (いずれも実際の不具合を踏んだ結果。理由を理解せずに変えない。[SPEC.md 6 章](../SPEC.md#6-設計上の不変条件)):
  - ホストの `XDG_RUNTIME_DIR` は `/run/host-xdg-runtime` に読み取り専用でマウントし、`/run/user/<uid>` には絶対にマウントしない
  - コンテナ内の `/run/user/<uid>` は logind が作る (GUI ユーザーを linger にして起動時から存在させる)
  - `/tmp/.X11-unix` は読み取り専用マウント、`tmpfiles.d/x11.conf` はマスク
  - コンテナをまたぐ libvirt 接続は `auth_unix_rw = "none"` + ソケット権限 `root:libvirt 0660`、`libvirt` の gid は両イメージで固定、設定は `kvm-libvirt-conf.service` が起動ごとに書く
  - `/run/kvm-container/libvirt` は `kvm` の起動前に中身だけ空にし、`down` で消す
  - `kvm-gui` は非特権 + `--security-opt label=disable`。`/dev/dri` は `--device` で渡す
  - 再ログイン後は `kvm-gui` だけ作り直す (`kvm.gui-session` ラベル + ソケットの実在で判定)
  - `--network host` の帰結として `iscsid.socket` / `iscsiuio.socket` / `NetworkManager*.service` をマスクし、停止時に `kvm-net-teardown.service` が `virbr0` を消す
  - `kvm` の停止では `libvirt-guests.service` が VM を先にシャットダウンし、`down` の待ち時間 (`KVM_STOP_TIMEOUT=180`) は `SHUTDOWN_TIMEOUT=120` より長くする
  - GUI ユーザーはホストユーザーの写しでパスワード無し。`data/` は空のときだけ seed
- **コンテナ名は `kvm` と `kvm-gui` に固定** (スクリプト内の変数名は `KVM_CONTAINER` / `GUI_CONTAINER`。`NAME` は他の用途と紛れるため避けている)。イメージ名も `localhost/kvm-container/{kvm,gui}` に固定
- **`viewer` は `up` を経由する**: `kvm` が止まっていれば起動し、表示先が変わっていれば `kvm-gui` を作り直してから virt-viewer を開く
- **削除時の共有 ISO**: `--remove-all-storage` は使わない。`domblklist` で確認して `--storage sda` ([VM を削除するときの注意](#vm-を削除するときの注意))
- **VM を作るのは x86_64 のホスト**: VM 作成の手順 3 の SATA (AHCI) と e1000e は、aarch64 の qemu-kvm に無い ([VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) の補足)
- **SPICE は無い**: グラフィックスは VNC。`--graphics spice` は使えない
- **`--network` を省いた場合**: ホストの既定経路がブリッジ上にあると `default` (NAT) にならない。本書の VM 作成の手順 3 は `VM_NETWORK` で明示しているので、この挙動に当たるのは `--network` を省いて自分で `virt-install` したときだけ
- **ゲストの画面はホストのデスクトップにしか出ない**: SSH だけのホストでは `virsh console` かネットワーク経由

### 参照

- [SPEC.md](../SPEC.md) — [1.1 目的](../SPEC.md#11-目的) / [1.2 スコープ外](../SPEC.md#12-スコープ外) / [2.1 ディスプレイの判定](../SPEC.md#21-ディスプレイの判定-have_display) / [2.2 ホスト要件](../SPEC.md#22-ホスト要件) / [2.3 実行ユーザーの要件](../SPEC.md#23-実行ユーザーの要件) / [2.4 起動前に確認されるホスト資源](../SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [3.2 3 層構造とファイル](../SPEC.md#32-3-層構造とファイル) / [3.3 コンテナ実行仕様](../SPEC.md#33-コンテナ実行仕様-podman-run) / [3.5 コンテナ間の libvirt 接続](../SPEC.md#35-コンテナ間の-libvirt-接続) / [4.1 CLI](../SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) / [4.2 環境変数](../SPEC.md#42-環境変数-ホスト側の入力) / [4.4 マウント仕様と表示の仕組み](../SPEC.md#44-マウント仕様と表示の仕組み) / [4.5 ネットワークとポート](../SPEC.md#45-ネットワークとポート) / [4.6 永続化データ](../SPEC.md#46-永続化データ-data-と共有-run-dir) / [5.1 起動シーケンス](../SPEC.md#51-起動シーケンス-kvmsh-up) / [5.2 停止シーケンス](../SPEC.md#52-停止シーケンス-kvmsh-down) / [5.3 GUI 起動シーケンス](../SPEC.md#53-gui-起動シーケンス-containerguiguikvm-gui-内) / [5.6 ブリッジ同期](../SPEC.md#56-ブリッジ同期-sync_bridged_network) / [6 設計上の不変条件](../SPEC.md#6-設計上の不変条件) / [7 セキュリティ考慮事項](../SPEC.md#7-セキュリティ考慮事項) / [8 既知の制限事項](../SPEC.md#8-既知の制限事項) / [9 検証手順](../SPEC.md#9-検証手順) (9.1 静的検査、9.2 物理 GNOME、9.3 ディスプレイ無し、9.4 その他の確認点、9.5 VM のライフサイクル) / [付録 A ファイル一覧](../SPEC.md#付録-a-ファイル一覧とコンテナ内配置)
- [CLAUDE.md](../../CLAUDE.md) — 変更時の注意点 (壊しやすい不変条件の理由、静的検査の対象ファイル)
- `./kvm.sh` (引数なし) — サブコマンドと環境変数の一覧 (`kvm.sh` 冒頭のヘッダコメント)
- `man virt-install` (`--cdrom` / `--location` / `--osinfo` / `--machine` / `--disk` / `--network`)、`man virsh` (`shutdown` / `destroy` / `autostart` / `undefine` / `change-media` / `domblklist` / `dumpxml` / `net-list` / `net-dumpxml` / `net-undefine` / `domiflist`)
- [libvirt: Domain XML format](https://libvirt.org/formatdomain.html) — ディスクの `<target>` の `bus` / `rotation_rate`、NIC の `<model>`
- `man nmcli` / `man nm-settings-nmcli` (`bridge`、`bridge-slave`、`ipv4.method`)

---
