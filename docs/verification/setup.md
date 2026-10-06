# qemu-kvm 導入・VM 操作の検証記録

[手順書](../setup.md) に記載していた検証結果を移動した記録。各記録の実施時点・対象版・未確認事項を保持し、この文書の移動による再検証は行っていない。

### 対象と検証環境

- **状態**:
  - **現行版の新規 VM 検証 (2026-10-06)**: `5cf5712` から clone し、AlmaLinux 10.2 / x86_64 / SELinux Enforcing の VM で依存の確認と `kvm` / `gui` イメージのビルドを完了した。起動はネストした仮想化が提供されないため `modprobe kvm_amd` で停止した。VM 内でのコンテナ起動・VM のライフサイクルを検証済みとは扱わない ([今回の付録](#付録-新規-almalinux-10-vm-での導入検証-2026-10-06))
  - **導入** (導入の手順 1〜9、再ログインしたとき、更新、ロールバックの手順 5〜7): 物理 AlmaLinux 10.2 + GNOME (Wayland、SELinux Enforcing、AMD x86_64) で通しの動作確認済み
    - PR #15 `ae650c0`: `up`、`running`、AVC 0、`/dev/dri` 0666、Wayland 直結、`down` → `up`、`clean`
    - PR #26 `ba2fee2`: `kvm` 再ビルド、両コンテナ `running`、VM のライフサイクル一式
    - `0cab212`: 導入の手順 6・7 → 導入の手順 8 → 導入の手順 9 →「表示先が変わったとき」(現「再ログインしたとき」) の `up gui` → 付録の確認行 (`auth_unix_rw` / `getent shadow` / `/dev/dri` / `ausearch`) → `KVM_HOST=headless` での `up gui` / `viewer` の拒否 (exit 1 / 2) → `down` (`virbr0` と `/run/kvm-container` が残らない) → `clean`。clone 先は `~/kvm-container` 以外 (git の worktree)、`viewer` と VM は未実施
  - **ディスプレイの無いホストは PR #28 で通した**
    - AlmaLinux 10.2 / Raspberry Pi 5 / aarch64、SELinux Enforcing、グラフィカルセッション外のシェル
    - `build` → `KVM_HOST=headless` での `up` → 付録の確認一式 → `down` → `clean`
    - **ただしそのホストでは VM を作っていない** (`virt-install` / `virsh console` は未実施)
  - README の例を変数形に書き換えたもので、その形では再実行していない行 (導入):
    - 導入の手順 6 の `cd "${REPO:?…}" && ./kvm.sh build kvm`、再ログインの手順 1 の `cd "${REPO:?…}" && ./kvm.sh up gui`、付録の `./kvm.sh viewer "${VM_NAME:?…}"`
  - 新しく足した行で、本実行していないもの (導入):
    - 導入の手順 2 の `sudo dnf install` (導入の手順 3 の `rpm -q podman git` は実行した)、導入の手順 4 の `git clone` (既に clone 済みのホストなので判定で飛ばした)
    - 「更新」の各手順、ロールバックの手順 7 の `rmi --ignore` とリポジトリの削除
  - **VM** (VM 作成の手順 1〜6、VM 利用の手順 2・4・5、VM を削除する): 物理 AlmaLinux 10.2 + GNOME、SELinux Enforcing で、作成 → 起動 → `viewer` → `reboot` → `shutdown` → `suspend` / `resume` → `destroy` → 稼働中の `down kvm` → `autostart` → `undefine --nvram --storage vda` の一式を通した (PR #26。[付録](../setup.md#vm-のライフサイクルを確認する))
    - **ただしそのときの作成は `--location` + キックスタート形で、`--network` も省いていた。** VM 作成の手順 3 の `--cdrom` 形は README の例を変数形に書き換え、`--network "network=${VM_NETWORK}"` を足したもので、その形では再実行していない
    - **記録の VM はディスクが virtio で、NIC は `--network` を省いた virt-install の既定だった**。記録のディスクは `vda`
    - VM 作成の手順 3 の `--machine q35`・`bus=sata,target.rotation_rate=1`・`model=e1000e` は、物理ホストでは本実行していない
    - それに合わせて `sda` / `sdb` に付け替えた行 (VM 作成の手順 5、[VM を削除する](../setup.md#vm-を削除する)の手順 1・2・5、補足) も本実行していない
    - VM 作成の手順 3 の引数は、AlmaLinux 10 のコンテナ (virt-install 5.1.0、libvirt 11.10.0、qemu-kvm 10.1.0) で `virt-install --print-xml` と `virsh define` まで確かめた
    - KVM の無いコンテナなので `--virt-type qemu` を足し、ISO は空のファイルにした。OS を `--osinfo almalinux10` で渡した形と、検出できない形の両方で同じ名前になった。VM は起動していない
    - そのコンテナでは、ディスク `sda` (`bus='sata' rotation_rate='1'`)・CD-ROM `sdb`・NIC `e1000e` になり、VM 作成の手順 5 の `grep` / `domblklist` / `domiflist` もそのとおりに出た
    - 同じコンテナで、virtio の VM に `undefine --storage sda` を付けると CD-ROM に入ったままの ISO が消え、SATA の VM では `sda` の qcow2 だけが消えることも確かめた
    - VM 作成の手順 1・2・4〜6、VM 利用の手順 2・4・5 と「VM を削除する」の各行も README の例を変数形に書き換えたもので、その形では再実行していない
    - 新しく足した行で、本実行していないもの: 導入の手順 1 の `VM_NETWORK`、VM 作成の手順 5 の `sudo ls -l`・`dumpxml` の `grep`・`domiflist`、VM 利用の手順 2・5 の `domstate`、[VM を削除する](../setup.md#vm-を削除する)の手順 2〜4 (`change-media --eject --config`・`shutdown`・`domstate`) と手順 6 (ISO の `sudo rm`) (`--remove-all-storage` が ISO を消すことは `lctest` で確認した)
    - ディスプレイの無いホストでの VM の作成・操作 (`virt-install` / `virsh console`) は未検証。そこで確認したのは `up` 〜 `down` だけ
    - PR #28 のディスプレイ無しのホストは aarch64 で、VM 作成の手順 3 の SATA と e1000e はその qemu-kvm に無い ([VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) の補足)
  - **ブリッジの節**: **通しで実行していない。** `KVM_BRIDGE` の機構 (`bridged` の登録・削除と、`bridged` につないだ VM の疎通) を現行構成で確認した記録は無い
    - 記述は `kvm.sh` の実装 (`check_host_network` / `sync_bridged_network`。[SPEC.md 2.4](../SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [5.6](../SPEC.md#56-ブリッジ同期-sync_bridged_network)) から書いたもの
    - **ブリッジの節の手順 3・4 の nmcli も物理ホストで本実行していない** (物理 AlmaLinux 10.2 + GNOME での通しの確認 PR #15 `ae650c0` は NIC が無線のみで `KVM_BRIDGE` を試していない)
    - README の例を変数形に書き換えたもので、その形では再実行していない行: ブリッジの節の手順 1 の `NIC_CON` の式 (`awk -F: -v d="${NIC}" '$2==d{print $1}'`)、同じ節の手順 3・4 の nmcli 行と手順 7 の `KVM_BRIDGE="${BRIDGE}" ./kvm.sh up`
    - 新規の確認行で本実行していないもの: ブリッジの節の手順 1 の読み戻し、同じ節の手順 2 と手順 5 の `ip -br addr show`、手順 5 の `ls -d`、手順 6 の `./kvm.sh down kvm`、手順 8 の `net-dumpxml`、手順 9 の `domiflist`、ロールバックの手順 1〜4 (ブリッジの節の手順 8 の `net-list` は README にあった行)
    - ブリッジの節の手順 3 とロールバックの手順 4 の nmcli は、`sudo` がパスワードを聞かない前提に合わせて 1 ブロック 2 行の形にした (この形でも本実行していない)
  - **4 本の手順書を 1 本にまとめたときに変えた行** (どれも本実行していない):
    - 導入の手順 1 の 2 つのブロック (旧 setup.md と旧 vm.md の手順 1 を 1 つにした形)。旧 vm.md の `cd "${REPO:?…}" && ls -l "${ISO:?…}"` は消し、`ls -l` を VM 作成の手順 1 の先頭に移した
    - ブリッジの節の手順 1 (旧 bridge.md の `REPO=` と `cd "${REPO:?…}" && ls -l kvm.sh` を消し、`ip -br addr show` を同じ節の手順 2 に移した)
    - 中断メッセージ (`${VAR:?…}`) の手順の番号だけを直した行: ブリッジの節の手順 2〜4・7・9、ロールバックの手順 4、付録の `./kvm.sh viewer`
    - `kvm.sh` のヘッダとメッセージの参照先 (`docs/bridge.md` → `docs/setup.md`)。`bash -n` と `shellcheck` だけで確かめた
  - **実施手順をシナリオに分けたときに変えた行** (どれも本実行していない):
    - 旧手順 1〜9 は導入、旧手順 10〜14 は VM 作成の手順 1〜5、旧手順 15・16 は VM 利用の手順 2・4 にした
    - 旧手順 17 は分け、`autostart` を VM 作成の手順 6、`domstate` を VM 利用の手順 5 に移した。旧「表示先が変わったとき」は再ログインの手順 1・2 にした
    - 新しく足した行: VM 利用の手順 1 の `cd "${REPO:?…}" && ./kvm.sh up`、手順 3 の `./kvm.sh viewer "${VM_NAME:?…}"`、手順 6 の `./kvm.sh down`
    - 変えた行: VM 利用の手順 2 の `start` に `${VM_NAME:?…}` を足した。中断メッセージ (`${VAR:?…}`) の「手順 1」は「導入の手順 1」にした
    - 更新の手順 3 (旧版のランチャーを消す `rm -f`) は新しく足した
  - **アクティビティからの起動・`KVM_SOFTWARE_GL`・`KVM_CLEAN_YES`・音声ソケットの受け渡しを削除した変更** (本実行していない):
    - `kvm.sh` / `container/gui/gui` は `bash -n` と `shellcheck` で確かめた
    - `gui_args` だけを取り出し、runtime dir の中と外の Wayland ソケットで `GUI_ARGS` を確かめた (podman は動かしていない)
    - `tar` を抜いた `gui` イメージのビルドと、`kvm-gui` の起動は確かめていない

| 項目 | 物理 AlmaLinux 10 + GNOME | ディスプレイ無し |
|---|---|---|
| ホスト | AlmaLinux 10.2 + GNOME (Wayland)、SELinux Enforcing、AMD x86_64 | AlmaLinux 10.2 (Raspberry Pi 5、aarch64)、SELinux Enforcing、podman 5.8.2、グラフィカルセッション外のシェル (`DISPLAY` / `WAYLAND_DISPLAY` 未設定) |
| 確認した版 | PR #15 (1 コンテナ構成、cockpit の頃)、PR #26 (現行の 2 コンテナ構成)、`0cab212` (導入の手順 6〜9 と `down` / `clean`) | PR #28 (現行の 2 コンテナ構成) |
| 画面表示 | GNOME (Wayland) デスクトップ | 無し (`>> no display found: GUI disabled ...`) |
| VM の作成・操作 | ライフサイクル一式 (PR #26。[付録](../setup.md#vm-のライフサイクルを確認する)、期待結果は [SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル)) | 未実施 (`virsh list` が通るところまで。`viewer` が使えないことは [SPEC.md 8 章](../SPEC.md#8-既知の制限事項)) |
| VM の作成形 | `--location` + キックスタート (`OEMDRV` ISO)、`--network` 省略、ディスクは virtio (`vda`)。VM 作成の手順 3 の `--cdrom` 形は未再実行、SATA の SSD / e1000e はコンテナで XML まで確認 | — |
| ゲスト OS | AlmaLinux 10.2 (boot ISO `AlmaLinux-10.2-x86_64-boot.iso`) | — |
| ブリッジの節 (`KVM_BRIDGE`) | 未検証 (NIC が無線のみ) | 未検証 |


## 手順本文にあった検証記録

### 導入する (1 度だけ) — 手順 1: 変数について

`REPO` は clone 先を指すだけで、`kvm.sh` に渡す変数ではない。`kvm.sh` は自分のあるディレクトリに `cd` してから動き、`data/` もそこ (`KVM_DATA_DIR=$PWD/data`) に作る。VM のディスクや定義はその `data/` に置かれる。

- ホームディレクトリ配下 (`user_home_t`) に置く前提で、seed コンテナと両コンテナはラベル分離なし (`--security-opt label=disable` / `--privileged`) で動かし、`data/` を relabel しない。他の場所に置いた場合は検証していない
- 最後の行は、clone 前 (ディレクトリが無い) には何もしない。新しいシェルで貼り直したときに、以降の `./kvm.sh` が相対パスで動くようにするため。変数のブロックに置く読み戻し以外のコマンドは、この `cd` だけにしている
- `ISO` はホスト側のパス。`ISO=~/Downloads/...` のように `~` で始めれば代入時に展開される (引用符で囲むと展開されない)。[VM 作成の手順 1](../setup.md#vm-を作る-vm-ごとに-1-度) でコピーし、VM 作成の手順 3 では `basename` だけをコンテナ内のパスに付ける
- `ISO` は絶対パス (`~` 始まりを含む) で入れる。相対パスで入れると、この手順の最後の行やこの節の手順 4 の `cd` の後で見つからなくなる
- `VM_NAME` は libvirt のドメイン名で、ディスク `/var/lib/libvirt/images/<VM名>.qcow2`、定義 `data/etc-libvirt/qemu/<VM名>.xml`、UEFI 変数 `data/var-libvirt/qemu/nvram/<VM名>_VARS.fd` の名前になる。削除 (`undefine`) もこの名前で行う
- `VM_MEMORY` は MiB、`VM_DISK` は GiB (`virt-install` の単位)。既定値は旧 README の例 (`alma10` / 4096 / 2 / 20)
- ディスクのバス (SATA の SSD) と NIC のモデル (e1000e) は変数にしていない。VM 作成の手順 3 のコマンドに直接書いてある
- `VM_NETWORK` は VM 作成の手順 3 の `--network network=` に渡す libvirt ネットワークの名前。`default` は NAT (`virbr0`、192.168.122.0/24)、`bridged` は[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)で `KVM_BRIDGE` を付けて登録したホストのブリッジ
- 変数はそのシェルの中だけで有効。以降の手順は、リポジトリ直下 (この節の手順 4 か、貼り直したこの手順の最後の行で移る) で貼る

### 導入する (1 度だけ) — 手順 8: 起動する

`./kvm.sh up` の流れ ([SPEC.md 5.1](../SPEC.md#51-起動シーケンス-kvmsh-up)): `/dev/kvm` の確認 (無ければ `modprobe`、0666 に) → root でないことの確認とホストユーザーの名前・uid/gid の取得 → イメージが無ければビルド → `data/` の初期化 → `check_host_network` → `/run/kvm-container/libvirt` を空にする → `kvm` を `podman run` → `>> waiting for libvirt...` (最大 30 秒) → `bridged` ネットワークの同期 → `>> ready.` → ディスプレイがあれば `kvm-gui` を起動。`kvm` が動いていれば `>> kvm is already running` で素通りする。

**`kvm-gui` に渡すもの**

`kvm.sh up` は実行ユーザーのセッション環境をそのまま `kvm-gui` に持ち込む (`kvm` には渡さない)。詳細は [SPEC.md 4.4](../SPEC.md#44-マウント仕様と表示の仕組み) と [6 章](../SPEC.md#6-設計上の不変条件)。

- `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`) をコンテナの **`/run/host-xdg-runtime` に読み取り専用**でマウントし、Wayland ソケットと GNOME の Xwayland 認証ファイルは、その中を指す**絶対パス**で **`WAYLAND_DISPLAY` / `XAUTHORITY`** に渡す (unix ソケットへの接続は読み取り専用でも可)。シンボリックリンクの先が runtime dir の外にある場合は、そのソケットファイルだけを同じパスに読み取り専用でマウントする
- **ホストの runtime dir をコンテナの `/run/user/<uid>` に同じパスでマウントしてはいけない。** コンテナの logind がそのディレクトリを自分のものとして管理し、ユーザーのセッションや `systemd --user` の開始時にホストの session bus や `systemd --user` のソケットを作り直し、`user-runtime-dir@.service` の停止処理で中身をすべて削除してしまう (ホストの Wayland ソケットや session bus が消える。cockpit を載せていた頃に、そのログイン / ログアウトで実際に起きた不具合。PR #10)
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

### VM を作る (VM ごとに 1 度) — 手順 3: virt-install のオプション

- `--osinfo` に OS 名を渡す場合の候補は `./kvm.sh virt-install --osinfo list` で確認できる
- `--graphics vnc`・`--noautoconsole`・`--machine q35` と、`bus=sata`・`target.rotation_rate=1`・`model=e1000e` は固定 (理由は後半の補足の[選択した方針](../reference/setup.md#選択した方針))
- `bus=sata` のディスクのターゲット名は `sda` になる。`--cdrom` の CD-ROM は virt-install が後ろに足すので `sdb` (どちらも SATA で、並び順に `sd*` が振られる)
- `--machine q35` は、ISO から OS を検出できなかったときのため
- 付けないと、検出できなかったときの virt-install は i440fx (`pc-i440fx-…`。RHEL 10 で非推奨) を選び、CD-ROM が IDE の `hda` になる (AlmaLinux 10 のコンテナの `--print-xml` で確認)
- `target.rotation_rate=1` は定義の `<target dev='sda' bus='sata' rotation_rate='1'/>` になり、ゲストからはディスクが SSD (非回転) に見える
- `rotation_rate` を付けられるのは SATA / SCSI / IDE のディスクだけ (libvirt 7.3 以降。virtio には無い)
- `model=e1000e` の NIC は Intel 82574L のエミュレーション
- `bus` と `model` を付けないと、virt-install は `--osinfo` で検出した OS から選ぶ。AlmaLinux のような virtio に対応した OS なら `vda` と `virtio` になる
- 新しいディスクはスパースに作られ、virt-install が `discard='unmap'` を付ける (既定)。ゲストの TRIM がホストの qcow2 に届く想定で、確かめていない
- SATA (AHCI) と e1000e は、x86_64 の qemu-kvm にはあるが、aarch64 の qemu-kvm には無い。CentOS Stream 10 の qemu-kvm のビルド設定で見たもので、AlmaLinux の aarch64 では確かめていない
- `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。本書は導入の手順 1 の `VM_NETWORK` で明示し、ホストによってつなぎ先が変わらないようにした。ネットワークの仕様は [SPEC.md 4.5 節](../SPEC.md#45-ネットワークとポート)
- `default` につないだ VM がネットワークに出られること (インストーラがリポジトリに届き、起動後に `domifaddr --source agent` で IP が取れること) は PR #26 のライフサイクル確認で見ている ([付録](../setup.md#vm-のライフサイクルを確認する))。そのときは `--network` を省いた形で、そのホストでは `default` につながった
- `virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない。キックスタートは `OEMDRV` ラベルの ISO にして渡す ([付録](../setup.md#vm-のライフサイクルを確認する)、[SPEC.md 8 章](../SPEC.md#8-既知の制限事項))
- `--cdrom` の VM は、インストーラの再起動で一度 `shut off` になり、以後はディスクから起動する。インストール後の CD-ROM は空 (`domblklist` の `sdb` が `-`) になる (旧 README の記述と virt-install の仕様による。実測は `--location` + キックスタート形で、`--cdrom` 形は再実行していない)
- Windows と検出した ISO だけは、virt-install が CD-ROM に入れたままにする (インストールが何段階かに分かれるため。`--osinfo win11` の `--print-xml` で確認)。`domblklist` の `sdb` に ISO が残る

### VM を作る (VM ごとに 1 度) — 手順 4: viewer

- `viewer` は先に `up` を実行する。コンテナが止まっていても、再ログインで表示先が変わっていても (`kvm-gui` だけ作り直される)、そのまま使える。VM は動いたまま ([再ログインしたとき](../setup.md#再ログインしたとき-繰り返し))
- VM 名を省くと一覧から選ぶダイアログが出る
- ディスプレイの無いホスト (`DISPLAY` / `WAYLAND_DISPLAY` が無い、または `KVM_HOST=headless`) では `!! no display found ...` で終了コード 2 になる。シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で、抜けるのは `Ctrl+]`。ISO のインストーラがシリアルに出るかは ISO 次第 (未検証)
- `viewer` は virt-viewer のウィンドウが閉じるまで戻らない。VM が `shut off` になるとウィンドウは自動で閉じる (`shutdown` で確認。[SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル))

### VM を使う (繰り返し) — 手順 6: 停止の仕組み (libvirt-guests)

- `virsh shutdown` は ACPI の電源ボタンに相当し、ゲスト OS がシャットダウンを行う。`destroy` は電源断
- `./kvm.sh down` (と `clean`) では、コンテナ内の `libvirt-guests.service` (`container/kvm/libvirt-guests`: `ON_SHUTDOWN=shutdown` / `ON_BOOT=ignore` / `SHUTDOWN_TIMEOUT=120`) が動いている VM を一斉に ACPI でシャットダウンする。これが無いとコンテナの systemd が qemu の scope をすぐ止め、VM は電源断と同じ状態になる (次の起動でルートの XFS のジャーナル復旧が走るのを PR #26 で確認)
- `down` の `podman rm -t` は 180 秒 (`kvm.sh` の `KVM_STOP_TIMEOUT`) で、VM の待ちは 120 秒。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は scope の停止で電源を切られる。ACPI に応じない VM では `down` が 122 秒で終わることを確認している ([SPEC.md 5.2 節](../SPEC.md#52-停止シーケンス-kvmsh-down))
- `ON_BOOT=ignore` なので、`down` の時点で動いていた VM は次の `up` で起動しない。起動するのは `virsh autostart` を設定した VM だけ (`data/etc-libvirt/qemu/autostart/` の symlink)

### VM をホストのブリッジにつなぐ (任意) — 手順 1: 変数について

- `REPO` と `VM_NAME` は[導入の手順 1](../setup.md#導入する-1-度だけ) の変数を使う (この節では設定しない)
- `NIC_CON` (接続名) と `NIC` (デバイス名) は別物で、同じとは限らない (`Wired connection 1` のような名前のことがある)。`nmcli connection down` は接続名を取るので、`nmcli -g NAME,DEVICE connection show --active` の出力からデバイス名で引いている。README にあった `awk -F: '$2=="enp1s0"{print $1}'` を `-v d="${NIC}"` で変数化した形で、その形では再実行していない
- `NIC_CON` はこの手順を貼った時点の値を保持する。この節の手順 4 で NIC の接続を切り替えたあとにシェルを開き直してこの手順を貼ると、NIC に付いている接続は `bridge-slave-<NIC>` なので `NIC_CON` はその名前になる。ロールバックで元の接続名が要るので、この手順の読み戻しの出力を控えておく

### VM をホストのブリッジにつなぐ (任意) — 手順 8: 動作確認

- `net-list` で `bridged` が active なこと。`KVM_BRIDGE` 周りを変えたときの確認点は [SPEC.md 9.4](../SPEC.md#94-その他の確認点-変更内容に応じて) (`KVM_BRIDGE` 無しで `up` すると消えることも含む)
- `net-dumpxml bridged` は `kvm.sh` が define した XML (`<name>bridged</name>`、`<forward mode="bridge"/>`、`<bridge name="<ブリッジ名>"/>`) を返す想定。新規の確認行で本実行していないので、出力にはこれに libvirt が足す `<uuid>` などが加わる

### VM をホストのブリッジにつなぐ (任意) — 手順 9: VM の接続

- `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。この節の手順 4 のあとはホストの既定経路がブリッジ上にあるので、`--network` を省いた VM もそのブリッジに直接つながり得る (この経路は `bridged` を経由しない)。[VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) は `VM_NETWORK` で `--network` を明示する ([SPEC.md 8 章](../SPEC.md#8-既知の制限事項))
- `bridged` の VM は tap がブリッジのポートになり、VM 自身の MAC で LAN に出る。仮想スイッチが MAC アドレスの詐称を許さない環境では、この形は通信できない
- 既存の VM の付け替えは、`kvm` イメージにエディタが無いので `virsh edit` がそのままでは使えない。`virsh dumpxml` → 編集 → `virsh define` の手順も未検証
- `domiflist` の確認は新規の行で、本実行していない

### VM を作る (VM ごとに 1 度) — 手順 4 の記載

- インストーラが最後に再起動すると VM は `shut off` になり、ウィンドウも閉じる (`--location` + キックスタートでの実測。`--cdrom` 形では再実行していない)

### VM を作る (VM ごとに 1 度) — 手順 4 の記載 (2)

- **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする (この手順の補足。未検証)

### VM をホストのブリッジにつなぐ (任意) — 手順 0 の記載

- この節の手順 3・4 の nmcli は物理ホストで本実行していない (検証に使った物理ホストは NIC が無線のみ)

### VM をホストのブリッジにつなぐ (任意) — 手順 5 の記載

ip -br addr show "${BRIDGE}"                  # UP で、LAN の DHCP から IP が付く (NIC と同じ IP になるかは未確認)

### VM をホストのブリッジにつなぐ (任意) — 手順 5 の記載 (2)

- `ip -br addr show` でブリッジが `UP` で、LAN の DHCP から IP が付く (NIC と同じ IP になるかは未確認)

### VM を削除する — 手順 2 の記載

- 本実行していない

### VM を削除する — 手順 6 の記載

- 本実行していない

### 更新 — 手順 0 の記載

- この節の手順は、この形では本実行していない (以前は `git pull` → `./kvm.sh down` → `./kvm.sh build` → `./kvm.sh up` と書いていたが、その流れも本実行していない)

### 更新 — 手順 3 の記載

- 本実行していない

### ロールバック — 手順 0 の記載

- この節の手順 1〜4 と手順 7 は本実行していない

### ロールバック — 手順 0 の記載 (2)

- `bridged` の VM が残ったまま `KVM_BRIDGE` 無しで `up` したときの挙動は未確認 ([付録](#付録-ブリッジの節-実行記録なし))

### ロールバック — 手順 7 の記載

- 本実行していない

### ロールバック — 手順 7 の記載 (2)

- clone したリポジトリも要らなければ、`clean` の後に `cd ~ && rm -rf "${REPO}"` で消す (本実行していない)

## 補足にあった検証記録

- **画面は端末から開く**: アクティビティ (アプリ一覧) からの起動は廃止した。端末の無い `sudo -n` を前提にしたうえ、現行のエントリを本実行できていなかったため
想定 (物理ホストでは本実行していない):
- VM: `--network network=bridged` で作った VM は LAN の DHCP から IP を取り、ホストの隣接テーブルには VM 自身の MAC が載る (いずれも未検証)
  - `bridged` につないだ VM がそのとき定義されたままだとどうなるか (起動時に `bridged` が見つからず失敗する想定) は未検証
- 物理 AlmaLinux 10 + GNOME での通しの確認 (PR #15) で `KVM_BRIDGE` を試せなかったのはこのため (NIC が無線のみ)
  - SPEC.md 9.5 節の記録 (`lctest`) は virtio の VM なので、そこでは `vda` を指定している
  - そのため、[VM を削除する](../setup.md#vm-を削除する)の手順 1 で `vda` が出たら、`sda` を `vda` に、`sdb` を `sda` に読み替える (どちらも AlmaLinux 10 のコンテナで確かめた)
- **ゲストの画面はホストのデスクトップにしか出ない**: SSH だけのホストでは `virsh console` かネットワーク経由 (未検証)

### 付録: 物理 AlmaLinux 10 + GNOME での確認手順

変更後の回帰確認。**先に [VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) で VM を 1 つ作り、導入の手順 1 の `VM_NAME` を設定したシェルで貼る。** 期待結果と検証している項目の表は [SPEC.md 9.2](../SPEC.md#92-物理-almalinux-10--gnome)。記録は PR #15 `ae650c0` (1 コンテナ構成) と PR #26 `ba2fee2` (現行)。以下のブロックは README にあった確認手順を記録どおりに分けたもので、`cd "${REPO:?…}"` の行と `viewer` の変数形は本実行していない。

```bash
cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}"
getenforce                                            # Enforcing のままで可
env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'      # GNOME 端末で値が入っていること
./kvm.sh up                                            # >> ready. VMs: ... が出ること
for c in kvm kvm-gui; do sudo podman exec $c systemctl is-system-running; done   # どちらも running (degraded ではない)
sudo podman exec kvm ls -l /run/libvirt/virtqemud-sock  # srw-rw---- root libvirt
sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list   # 一般ユーザーが kvm-gui から kvm の libvirt に接続できること
sudo sh -c "grep -h '^auth_unix_rw' data/etc-libvirt/virt*d.conf"   # すべて "none" (kvm-libvirt-conf.service)
sudo podman exec kvm getent shadow $USER               # 第 2 フィールドが ! (ロック) であること
sudo podman exec kvm-gui ls -la /dev/dri              # renderD* が 0666
sudo ausearch -m avc -ts recent                        # SELinux 拒否が無いこと
```

VM が無ければ、ここで [VM 作成の手順 3](../setup.md#vm-を作る-vm-ごとに-1-度) の `./kvm.sh virt-install ...` で VM を作る。次のブロックは GNOME デスクトップにウィンドウが出ること、VM のコンソールが見えることを確かめる (ウィンドウを閉じてから次へ)。

```bash
./kvm.sh viewer "${VM_NAME:?導入の手順 1 の VM_NAME を設定してから貼る}"
```

VM 名なしでは一覧から選ぶダイアログが出ること。ダイアログを閉じてから次へ。

```bash
./kvm.sh viewer
```

GNOME からログアウト → 再ログイン → 端末で (導入の手順 1 の変数を貼り直してから):

```bash
./kvm.sh up                                            # kvm-gui だけが作り直され、./kvm.sh virsh list の VM が動いたままであること
```

最後に止めて、ホストに何も残らないことを確かめる。

```bash
./kvm.sh down; ip link show virbr0; ls /run/kvm-container   # どちらも残っていないこと
```

### 付録: ディスプレイの無いホストでの確認手順

グラフィカルセッションの外のシェル (SSH など) から流す。期待結果は [SPEC.md 9.3](../SPEC.md#93-ディスプレイ無し-headless)。
PR #28 で AlmaLinux 10.2 (Raspberry Pi 5、aarch64、SELinux Enforcing、podman 5.8.2) に通した記録なので、そのまま貼れる形で書いてある。
`KVM_HOST=headless` を付けているが、このシェルには `DISPLAY` / `WAYLAND_DISPLAY` が無いので、付けなくても同じ経路を通る (最後のブロックで確認する)。

```bash
cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}"
KVM_HOST=headless ./kvm.sh up      # >> ready. のあとに >> no display found: GUI disabled ... が出ること
```

`up gui` と `viewer` は画面が無いので拒否される (終了コードはそれぞれ 1 と 2)。

```bash
KVM_HOST=headless ./kvm.sh up gui; echo "exit=$?"    # !! no display found ... the GUI container is not needed / exit=1
KVM_HOST=headless ./kvm.sh viewer; echo "exit=$?"    # !! no display found ... manage the VMs with ./kvm.sh virsh / exit=2
```

```bash
sudo podman exec kvm systemctl is-system-running     # running (degraded ではないこと)
sudo podman ps                                       # kvm だけで、kvm-gui が居ないこと
sudo podman exec kvm ls -l /run/libvirt/virtqemud-sock          # srw-rw---- root libvirt
sudo sh -c 'grep -h "^auth_unix_rw" data/etc-libvirt/virt*d.conf'   # すべて "none"
sudo podman exec kvm getent shadow "$USER"           # 第 2 フィールドが ! (GUI ユーザーはロックされている)
./kvm.sh virsh list --all                            # 一覧が出ること (VM が無ければヘッダだけ)
ip -br addr show virbr0                              # 192.168.122.1/24
sudo ausearch -m avc -ts recent                      # 拒否が無いこと (<no matches>)
```

`KVM_HOST` を付けない場合も同じ経路を通り、`down` でホストに何も残らないことを確かめる。

```bash
./kvm.sh down; ./kvm.sh up                           # 同じ >> no display found ... が出て >> ready. まで進むこと
./kvm.sh down; ip link show virbr0; ls /run/kvm-container   # どちらも残っていないこと
```

#### 未確認事項

- ディスプレイの無いホストでの VM の作成・操作 (`virt-install` → `virsh console`)。PR #28 で通したのは `up` 〜 `down` まで
- aarch64 のホストで、VM 作成の手順 3 が SATA / e1000e のところで止まること (qemu-kvm のビルド設定からの想定)
- x86_64 のディスプレイ無しホストでの通し (PR #28 の記録は aarch64 の Raspberry Pi 5。`/dev/kvm` が無いときの `modprobe kvm_amd` / `kvm_intel` は x86 前提で、aarch64 では通らない)
- ロールバックの手順 7 の `sudo podman rmi --ignore …` とリポジトリの削除、更新の手順 3 (旧版のランチャーの削除) と `git pull --ff-only` からの通常更新
- 導入の手順 2 の `sudo dnf install`、導入の手順 4 の `git clone` (他の新規の行と「表示先が変わったとき」(現「再ログインしたとき」) の `./kvm.sh up gui` → `./kvm.sh virsh list` は `0cab212` で実行した)
- `~/kvm-container` に clone したホストでの通し (`0cab212` の実行は git の worktree を clone 先にしたもの)

### 付録: VM のライフサイクルの確認手順

OS の入った使い捨ての VM `lctest` で、作成から削除までを確認する (手順の詳細と期待結果は [SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル))。変更後の回帰確認に手で流す。PR #26 で物理 AlmaLinux 10.2 + GNOME (SELinux Enforcing) で通した記録なので、VM 名 `lctest` と boot ISO `AlmaLinux-10.2-x86_64-boot.iso` は変数にせずそのまま書いてある。
キックスタートは `data/` 以外の場所で書き、`OEMDRV` ラベルの ISO にして渡す (`virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない)。
`ks.cfg` には `poweroff` と、`%packages` に `qemu-guest-agent` を入れておく。

- boot ISO は先に [VM 作成の手順 1](../setup.md#vm-を作る-vm-ごとに-1-度) で `data/var-libvirt/images/` に置く (導入の手順 1 の `ISO` にその boot ISO のパスを入れる)
- `ks.cfg` はカレントディレクトリ (最初のブロックの `cd` の後なのでリポジトリ直下) に置いてあるものとして `podman cp` している。別の場所に書いたならパスを読み替える。リポジトリ直下に置いた `ks.cfg` は `.gitignore` に無く `git status` に untracked として出るので、終わったら消す (誤ってコミットしない)
- 検証記録なので、待ち時間のある行が同じブロックに並んでいる。1 行ずつ結果を見ながら貼る (`virt-install` の後は `domstate` が `shut off` になるまで数分待ってから `start` 以降を貼る)

```bash
cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}"
./kvm.sh up
sudo podman exec kvm mkdir -p /tmp/ksdir && sudo podman cp ks.cfg kvm:/tmp/ksdir/ks.cfg
sudo podman exec kvm xorriso -as mkisofs -V OEMDRV -o /var/lib/libvirt/images/lctest-ks.iso /tmp/ksdir
./kvm.sh virt-install --name lctest --memory 3072 --vcpus 2 --disk size=10 \
  --location /var/lib/libvirt/images/AlmaLinux-10.2-x86_64-boot.iso --osinfo almalinux10 \
  --disk path=/var/lib/libvirt/images/lctest-ks.iso,device=cdrom \
  --extra-args "inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0,115200" \
  --serial pty,log.file=/var/log/libvirt/qemu/lctest-serial.log --graphics vnc --noautoconsole
./kvm.sh virsh domstate lctest                         # インストールが終わると shut off (poweroff)
./kvm.sh virsh start lctest
./kvm.sh virsh qemu-agent-command lctest '{"execute":"guest-ping"}'   # 応答すれば OS が起動している
./kvm.sh virsh domifaddr lctest --source agent          # IP が取れていること
```

**ウィンドウが開く** (単独で貼る)。`viewer` はウィンドウが閉じるまで戻らないので、**次のブロックは virt-viewer を開いたまま、別の端末 (リポジトリ直下に `cd` したもの) で貼る**:

```bash
./kvm.sh viewer lctest                                  # ログインプロンプトが見えること
```

```bash
./kvm.sh virsh reboot lctest                            # 再起動して guest agent が戻ること
./kvm.sh virsh shutdown lctest                          # 数秒で shut off (shutdown)。viewer のウィンドウは閉じる
```

**次のブロックは `./kvm.sh virsh domstate lctest` で `shut off` を確認してから貼る。**

```bash
./kvm.sh virsh start lctest; ./kvm.sh virsh suspend lctest; ./kvm.sh virsh resume lctest   # paused (user) → running (unpaused)
./kvm.sh virsh destroy lctest                           # shut off (destroyed)
./kvm.sh virsh start lctest; ./kvm.sh down kvm          # ">> shutting down the running VMs" が出て、数秒で終わること
./kvm.sh up kvm; ./kvm.sh virsh start lctest            # シリアルログに "XFS (...): Starting recovery" が出ないこと
./kvm.sh virsh autostart lctest; ./kvm.sh down kvm; ./kvm.sh up kvm   # lctest が running (booted) になること
./kvm.sh virsh autostart lctest --disable
./kvm.sh down kvm; ./kvm.sh up kvm                      # 定義が残り、lctest は shut off のまま (down 時に動いていても起動しない)
./kvm.sh virsh undefine lctest --nvram --storage vda    # 定義とディスクだけが消え、ISO が残ること
sudo ls data/var-libvirt/images data/etc-libvirt/qemu
```

PR #26 の記録: キックスタートで入れた VM で上の一式を通し、稼働中の `down kvm` は 2.4 秒で終わり次の起動は `Ending clean mount` だった。ACPI に応じない VM (`--pxe --disk none`) では `down` が 122 秒で終わり、qemu・`vnet*`・`virbr0`・`/run/kvm-container` が残らないこと、`down` 時に動いていた autostart 無しの VM が次の `up` で起動しないことを確認した。シリアルログ (`/var/log/libvirt/qemu/lctest-serial.log`) は `kvm` のコンテナ内にあり、`down` で消える。

#### 未確認事項

- VM 作成の手順 3 の `--cdrom` 形での通し (作成からインストール完了まで)。検証記録は `--location` + キックスタート形だけ
- VM 作成の手順 3 の `--network "network=${VM_NETWORK}"` (`default` / `bridged` のどちらも。検証記録は `--network` を省いた形だけ)
- VM 作成の手順 3 の `--machine q35`・SATA の SSD・e1000e での作成とインストール。コンテナで確かめたのは XML の生成と `define` まで
- SATA の SSD / e1000e の VM で、ゲストがディスクを非回転 (SSD) として扱い、e1000e で通信できること
- VM 作成の手順 5 の `dumpxml` の `grep` と `domiflist`、「VM を削除する」の `sda` / `sdb` の行 (手順 1・2・5) を物理ホストで流すこと
- スパースのディスクに付く `discard='unmap'` で、ゲストの TRIM がホストの qcow2 に届くこと
- 「VM を削除する」の手順 2〜4 (`change-media --eject --config`、`shutdown`、`domstate`) と手順 6 (ISO の `sudo rm`)
- ディスプレイ無しのホストでの `./kvm.sh virsh console` (ISO のインストーラがシリアルに出るかも含む)
- 導入の手順 1 (旧 setup.md と旧 vm.md の手順 1 をまとめた形) と VM 作成の手順 1 の `ls -l`、VM 作成の手順 5・6 と VM 利用の手順 2・4・5 の変数形の行と、`sudo ls -l` / `domstate` の新規行
- VM 利用の手順 1・3・6 (実施手順をシナリオに分けたときに足した行)
- 「完了時点の状態」の出力例 (表示形式から組み立てたもので、そのまま取った実測ではない)

### 付録: ブリッジの節 (実行記録なし)

[ブリッジの節](../setup.md#vm-をホストのブリッジにつなぐ-任意)は通しで実行した記録が無い (状態は[対象と検証環境](#対象と検証環境))。NetworkManager は物理ホストの AlmaLinux 10 の既定 (`nmcli`) で、版は記録していない。

#### 未確認事項

- ブリッジの節の手順 3・4 の nmcli 手順 (物理ホスト、有線 NIC) の本実行。ブリッジが DHCP で NIC と同じ IP を引き継ぐか、ブリッジを上げたあとの ssh の復帰
- ブリッジの節の手順 1 の `NIC_CON` の式 (`awk -v d="${NIC}"` 形) と、同じ節の手順 1〜7 の変数形・新規の行
- ブリッジの節の手順 8 の `net-dumpxml bridged` の実際の出力
- 物理ホストのブリッジに `--network network=bridged` (導入の手順 1 の `VM_NETWORK=bridged`) でつないだ VM が LAN の DHCP から IP を取ること、ブリッジの節の手順 9 の `domiflist` の出力
- `KVM_BRIDGE` を付けた `up` で `bridged` が登録されること、`KVM_BRIDGE` 無しの `up` で削除されること (実行記録なし)
- `bridged` につないだ VM が定義されたまま `KVM_BRIDGE` 無しで `up` したときの挙動 (`bridged` の削除が失敗するか、VM の起動が失敗するか)
- ロールバックの手順 4 の nmcli (`connection delete` と元の接続の `up`。1 ブロック 2 行の形) と、ロールバックの手順 2 の `KVM_BRIDGE` 無しの `up` で `bridged` が消えるところ (README には書かれていたが本書の形では再実行していない)
- 更新の手順 2 を `KVM_BRIDGE=` 付きの `up` にしたとき、`bridged` が残ること
- `export KVM_BRIDGE=br0` にしたときの `viewer` / `up` の挙動

- シェルの `export KVM_BRIDGE=br0` にすれば毎回付けなくて済むが、本書はそれを検証していない (`kvm.sh` は `KVM_BRIDGE=${KVM_BRIDGE:-}` で環境から読むだけなので動く想定)
- 既存 VM の `bridged` → `default` の付け替え手順

---

### 付録: 新規 AlmaLinux 10 VM での導入検証 (2026-10-06)

**対象**: `5cf5712` の手順と実装。公式 ISO の Workstation クリーンインストールのスナップショットから、新規の `alma10-current-20261006-containers` を作った。AlmaLinux 10.2 / x86_64 / kernel `6.12.0-211.61.1.el10_2.x86_64` / SELinux Enforcing。外側は Windows 11 / VirtualBox 7.2.20 / Hyper-V NEM。

- 導入の依存の確認、公開リポジトリの clone、実行ユーザー・SELinux・画面無しの分岐を通した。Podman 5.8.2 / Git 2.52.0。
- 導入の手順 6 の `kvm` イメージをビルドできた。画面の無いシェルなので手順 7 は本文の条件で飛ばしたが、追加で `./kvm.sh build gui` を実行し、現行の `gui` イメージもビルドできた。
- 導入の手順 8 の `./kvm.sh up` は `>> loading kvm module` の後、`modprobe: ERROR: could not insert 'kvm_amd': Operation not supported`、終了 1 で止まった。CPU の SVM / VT-x が見えず、`/dev/kvm` は無い。外側がネストした仮想化を提供しないことによる前提不足で、イメージのビルド失敗ではない。
- この結果から、手順冒頭に CPU の仮想化支援と VM 内でのネストした仮想化の前提を明記し、手順 8 のエラー説明に実際の `modprobe` の停止も加えた。
- ISO の取り込み、導入の手順 9、コンテナの実起動と `running` の確認、VM の作成・操作・削除、GUI 接続、ブリッジ、更新・全ロールバックは、この VM では実行していない。以前の物理ホストの記録を、この VM の結果とは扱わない。
