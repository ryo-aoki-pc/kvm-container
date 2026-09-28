# qemu-kvm コンテナ 導入と VM の作成・操作手順 (AlmaLinux 10 / podman、物理 GNOME / ディスプレイ無し)

## 実施手順

> [!IMPORTANT]
> - **すべて対象ホストの一般ユーザーのシェルで実行する**。root や `sudo -i` のシェルでは、`kvm.sh` が `!! run kvm.sh as a regular user, not root` で止まる
> - **画面を使うなら、GNOME にログインした端末から実行する**。SSH のシェルからでは `kvm-gui` が起動しない
> - **ホストの `sudo` は、パスワードを聞かれずに実行できるようにしておく**。本書は、どのブロックでも `sudo` が止まらない前提で書いてある。sudoers の設定は読者が行う (書き方は扱わない。権限上の意味は [SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項))
> - **VM を作るなら、インストールに使う ISO を先にホストにダウンロードしておく** ([導入の手順 1](#導入する-1-度だけ) でそのパスを入れる)
> - **VM を作るのは x86_64 のホスト**。[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) で使う SATA と e1000e は、aarch64 の qemu-kvm には無い (VM 作成の手順 3 の補足)
> - **[導入の手順 2](#導入する-1-度だけ) には `[y/N]` の確認がある**。答えて、インストールが終わってから導入の手順 3 を貼る
> - **[VM 作成の手順 4](#vm-を作る-vm-ごとに-1-度) と [VM 利用の手順 3](#vm-を使う-繰り返し) は、ホストのデスクトップにウィンドウが開く**。GNOME にログインした端末から行い、ウィンドウを閉じてから次の手順を貼る。ディスプレイの無いホストでは画面は出ない (VM 作成の手順 4 の注意)
> - **[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 4 と[ロールバック](#ロールバック)の手順 4 は、GNOME の端末 (コンソール) から単独で貼る**。NIC の接続を切り替えるので、その NIC 越しの ssh は切れる

| シナリオ | 頻度 | 内容 |
|---|---|---|
| [導入する](#導入する-1-度だけ) | 1 度だけ | podman と git を入れ、clone してイメージをビルドし、コンテナを起動する |
| [VM を作る](#vm-を作る-vm-ごとに-1-度) | VM ごとに 1 度 | ISO を置き、`virt-install` で VM を作ってインストールする |
| [VM を使う](#vm-を使う-繰り返し) | 繰り返し | コンテナと VM を起動し、画面を見て、止める |
| [再ログインしたとき](#再ログインしたとき-繰り返し) | 繰り返し | GNOME に再ログインした後、`kvm-gui` だけを作り直す |
| [VM をホストのブリッジにつなぐ (任意)](#vm-をホストのブリッジにつなぐ-任意) | 任意、1 度だけ | 導入の後、VM を作る前に行う |
| [VM を削除する](#vm-を削除する) | VM ごとに 1 度 | VM の定義・UEFI 変数・ディスクを消す |
| [更新](#更新) | 更新のたび | リポジトリを最新にし、イメージを作り直す |
| [ロールバック](#ロールバック) | 戻すとき | 任意の節を戻し、コンテナ・`data/`・イメージを消す |

- 初めてなら、導入する → VM を作る → VM を使う の順に、上から順にコードブロックを貼る。以後は、必要なシナリオだけを貼る
- 手順の番号はシナリオ (見出し) ごとに 1 から数える。ほかのシナリオの手順は「導入の手順 1」「VM 作成の手順 3」「VM 利用の手順 2」「再ログインの手順 1」のように呼ぶ
- どのシナリオも、導入の手順 1 で変数を設定したシェルで貼る。新しいシェルでは、導入の手順 1 の 2 つのブロックを貼り直してから始める
- 画面の有無による違いはブロックの中で判定するので、どちらのホストでも同じブロックを貼る
- 各手順の末尾の「補足」(折り畳み) と後半の[補足](#補足)は、実行するだけなら読まなくてよい。折り畳みの中のブロックも貼らなくてよい
- VM をホストのブリッジにつなぐなら、導入の手順 1 の `VM_NETWORK` を `bridged` にし、導入の後に[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 1〜8 を行ってから VM を作る
- サブコマンドの一覧は[使い方の基本](#使い方の基本)。実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [SPEC.md](SPEC.md)

### 導入する (1 度だけ)

- podman と git だけのホストにこのリポジトリを clone し、イメージをビルドしてコンテナを起動する
- ホストごとに 1 度だけ行う。2 回目からは[VM を使う](#vm-を使う-繰り返し)から始める (新しいシェルでは、この節の手順 1 だけを貼り直す)

1. 変数を設定する (`ISO` は必ず値を入れる)。

   ```bash
   ISO=   # ← ダウンロードした ISO のホスト側パス (例: ~/Downloads/AlmaLinux-10-latest-x86_64-dvd.iso)。<ISO>
   ```

   ```bash
   REPO=~/kvm-container   # clone 先。ユーザーのホームディレクトリ配下にする。<REPO>
   VM_NAME=alma10         # VM 名。ディスクは /var/lib/libvirt/images/${VM_NAME}.qcow2 になる。<VM_NAME>
   VM_MEMORY=4096         # メモリ (MiB)。<VM_MEMORY>
   VM_VCPUS=2             # vCPU 数。<VM_VCPUS>
   VM_DISK=20             # ディスクの大きさ (GiB)。<VM_DISK>
   VM_NETWORK=default     # VM をつなぐ libvirt ネットワーク。ブリッジの節を通したホストで LAN に直接つなぐなら bridged。<VM_NETWORK>
   for v in ISO REPO VM_NAME VM_MEMORY VM_VCPUS VM_DISK VM_NETWORK; do
     printf '%-10s = %s\n' "$v" "${!v}"
   done
   [ ! -d "${REPO}" ] || cd "${REPO}"
   ```

   - `ISO` には、ホストにダウンロードしておいた ISO のパスを入れる
   - `ISO` を使うのは [VM 作成の手順 1](#vm-を作る-vm-ごとに-1-度) から。空のままだと、そこで止まる
   - `REPO` から `VM_NETWORK` までは、既定のままでよければそのまま貼る (値は旧 README の例と同じ)
   - clone 先を `~/kvm-container` 以外にするときだけ `REPO` を変える
   - 値を読み戻して確かめる
   - clone 済みなら、最後の行でリポジトリ直下に移る
   - **新しいシェルを開いたら** (SSH を張り直したあとも)、この手順の 2 つのブロックを貼り直してから、続きのシナリオへ進む

   <details>
   <summary>補足: 変数について</summary>

   `REPO` は clone 先を指すだけで、`kvm.sh` に渡す変数ではない。`kvm.sh` は自分のあるディレクトリに `cd` してから動き、`data/` もそこ (`KVM_DATA_DIR=$PWD/data`) に作る。VM のディスクや定義はその `data/` に置かれる。

   - ホームディレクトリ配下 (`user_home_t`) に置く前提で、seed コンテナと両コンテナはラベル分離なし (`--security-opt label=disable` / `--privileged`) で動かし、`data/` を relabel しない。他の場所に置いた場合は検証していない
   - 最後の行は、clone 前 (ディレクトリが無い) には何もしない。新しいシェルで貼り直したときに、以降の `./kvm.sh` が相対パスで動くようにするため。変数のブロックに置く読み戻し以外のコマンドは、この `cd` だけにしている
   - `ISO` はホスト側のパス。`ISO=~/Downloads/...` のように `~` で始めれば代入時に展開される (引用符で囲むと展開されない)。[VM 作成の手順 1](#vm-を作る-vm-ごとに-1-度) でコピーし、VM 作成の手順 3 では `basename` だけをコンテナ内のパスに付ける
   - `ISO` は絶対パス (`~` 始まりを含む) で入れる。相対パスで入れると、この手順の最後の行やこの節の手順 4 の `cd` の後で見つからなくなる
   - `VM_NAME` は libvirt のドメイン名で、ディスク `/var/lib/libvirt/images/<VM名>.qcow2`、定義 `data/etc-libvirt/qemu/<VM名>.xml`、UEFI 変数 `data/var-libvirt/qemu/nvram/<VM名>_VARS.fd` の名前になる。削除 (`undefine`) もこの名前で行う
   - `VM_MEMORY` は MiB、`VM_DISK` は GiB (`virt-install` の単位)。既定値は旧 README の例 (`alma10` / 4096 / 2 / 20)
   - ディスクのバス (SATA の SSD) と NIC のモデル (e1000e) は変数にしていない。VM 作成の手順 3 のコマンドに直接書いてある
   - `VM_NETWORK` は VM 作成の手順 3 の `--network network=` に渡す libvirt ネットワークの名前。`default` は NAT (`virbr0`、192.168.122.0/24)、`bridged` は[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)で `KVM_BRIDGE` を付けて登録したホストのブリッジ
   - 変数はそのシェルの中だけで有効。以降の手順は、リポジトリ直下 (この節の手順 4 か、貼り直したこの手順の最後の行で移る) で貼る

   </details>

1. podman と git を入れる。

   ```bash
   sudo dnf install podman git
   ```

   - ホストに入れるのは podman と git だけ (podman は root で使う)
   - qemu・libvirt・virt-viewer はホストに入れない
   - **次の手順は、`[y/N]` に答えてインストールが終わってから貼る** (続けて貼ると答えとして食われる)

   <details>
   <summary>補足: podman と git</summary>

   `kvm.sh` は `sudo podman` 固定で、rootless podman は使わない。git はこの節の手順 4 の clone と[更新](#更新)の `git pull` にだけ使う。

   - ホストの libvirt とは無関係なので、ホストに qemu・libvirt を入れてはいけないわけではない。ただし入れて動かしていると `virbr0` が衝突する ([注意点](#注意点))
   - ホスト要件は [SPEC.md 2.2](SPEC.md#22-ホスト要件)、実行ユーザーの要件は [2.3](SPEC.md#23-実行ユーザーの要件)

   </details>

1. podman と git が入ったか確かめる。

   ```bash
   rpm -q podman git
   ```

   - 2 行とも `podman-…` / `git-…` の版が出ればよい

1. リポジトリを clone する。

   ```bash
   [ -e "${REPO:?導入の手順 1 の REPO が空のまま。導入の手順 1 を貼り直す}/kvm.sh" ] || git clone https://github.com/ryo-aoki-pc/kvm-container.git "${REPO}"
   cd "${REPO}" && ls -l kvm.sh
   ```

   - `kvm.sh` の行 (実行権限付き) が出ればよい
   - すでに clone してあれば、`git clone` は飛ばされる
   - 以降の手順は、このディレクトリ (リポジトリ直下) で貼る

   <details>
   <summary>補足: clone</summary>

   - clone 元は公開リポジトリの HTTPS の URL で、認証は要らない
   - `data/` は git 管理外 (`.gitignore`) で、この節の手順 8 の `up` が初めて作る。clone した直後には無い
   - `REPO` にファイルの入った別のディレクトリがあると、`git clone` は `already exists and is not an empty directory` で止まる。`REPO` を変えてこの節の手順 1 から貼り直す

   </details>

1. ホストの SELinux と画面の有無を確かめる。

   ```bash
   getenforce
   env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'
   if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then echo '画面あり: kvm と kvm-gui を使う'; else echo '画面なし: kvm だけを使う'; fi
   ```

   - `getenforce` は `Enforcing` のままでよい
   - GNOME の端末なら `WAYLAND_DISPLAY` / `DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` の行が並び、`画面あり` と出る
   - ディスプレイの無いホスト (SSH のみ) では `画面なし` と出る。これで正常で、以降の手順は `kvm` だけを扱う
   - **注意**: GNOME のホストで `画面なし` と出たら、SSH か `sudo -i` のシェルで貼っている。GNOME の端末を開き、この節の手順 1 から貼り直す
   - ファームウェアで SVM (AMD) / VT-x (Intel) を有効にしておく

   <details>
   <summary>補足: ホストの確認</summary>

   - **ホスト種別の判定は無い**: 画面の有無だけを見る。`KVM_HOST` が `headless` でなく、`DISPLAY` か `WAYLAND_DISPLAY` が設定されていれば `kvm-gui` を起動する (`have_display`。[SPEC.md 2.1](SPEC.md#21-ディスプレイの判定-have_display))。最後の行はこれと同じ条件で、`KVM_HOST` だけは見ない
   - **物理 GNOME**: `kvm.sh up` は実行ユーザーのセッション環境 (`DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY`) を `kvm-gui` に持ち込む。SSH 越しや `sudo -i` のシェルでは `WAYLAND_DISPLAY` などが無く、`kvm-gui` は起動されない (`>> no display found`)
   - **SELinux**: Enforcing のままでよい (`kvm` は `--privileged`、`kvm-gui` は `label=disable` でラベル分離が無効)
   - **ディスプレイ無し**: `up` は `kvm` だけを起動し、GUI イメージはビルドしない。`up gui` と `viewer` は `!! no display found …` で終了する (それぞれ exit 1 / exit 2)。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` で行い、ゲストにはシリアルコンソールやネットワーク経由でアクセスする ([VM 作成の手順 4](#vm-を作る-vm-ごとに-1-度) の補足)
   - **画面のあるホストで画面を使わない**: `KVM_HOST=headless` を `up` の前に付ける ([環境変数](#環境変数))。そのときはこの節の手順 7 を飛ばす
   - **SSH のシェルの `XDG_RUNTIME_DIR`**: SSH でログインしても設定されるので、`env | grep` に出ることがある。画面の有無は `DISPLAY` / `WAYLAND_DISPLAY` で決まる
   - **起動前に確認されるホスト資源** (`check_host_network`): `KVM_BRIDGE` がブリッジでなければ停止、ホストに `virbr0` があれば警告 ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

   </details>

1. `kvm` のイメージをビルドする。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh build kvm
   ```

   - 時間がかかる (AlmaLinux 10 minimal のイメージ取得と `microdnf` でのパッケージ導入)
   - ビルドの最後に `Successfully tagged localhost/kvm-container/kvm:latest` が出ればよい
   - **次の手順は、ビルドが終わってから貼る**

   <details>
   <summary>補足: ビルド</summary>

   `Containerfile` は AlmaLinux 10 minimal ベース (`microdnf`) のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、両コンテナ共通の unit マスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui`。

   - `./kvm.sh build [kvm|gui]` は `podman build --target <role> -t localhost/kvm-container/<role>:latest` で、余分な引数は `podman build` に渡る。引数なしの `./kvm.sh build` は両方を作る
   - この節の手順 6・7 に分けたのは、画面の無いホストで GUI イメージを作らないため。判定はこの節の手順 5 の最後の行と同じ
   - どちらのイメージも systemd (`/sbin/init`) で常駐する。イメージ名は固定 ([SPEC.md 3.4](SPEC.md#34-イメージ仕様-containerfile))
   - `up` は足りないイメージを自動でビルドするので、この節の手順 6・7 を飛ばしてもよい。分けてあるのは、ビルドの失敗と起動の失敗を切り分けるため
   - ビルドが失敗したら `./kvm.sh build kvm 2>&1 | tee build.log` のように出力を残す (`build.log` は `.gitignore` 済み)

   </details>

1. GUI のイメージをビルドする (画面の無いホストでは何もしない)。

   ```bash
   [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || ./kvm.sh build gui
   ```

   - 画面のあるホストでは GUI のイメージも作る
   - ビルドの最後に `Successfully tagged localhost/kvm-container/gui:latest` が出ればよい
   - **次の手順は、ビルドが終わってから貼る**

1. コンテナを起動する。

   ```bash
   ./kvm.sh up
   ```

   - 初回は `>> seeding …/data/var-libvirt from image …` のように `data/` の初期化が 3 回出る
   - `>> ready. VMs: …` が出れば `kvm` は起動している
   - 画面のあるホストでは、続けて `>> kvm-gui started. VM screen: ./kvm.sh viewer [VM]` が出る
   - 画面の無いホストでは `>> no display found: GUI disabled (manage the VMs with ./kvm.sh virsh / virt-install)` が出る。これで正常
   - `!! /dev/kvm not found …` で止まったら、ファームウェアの SVM (AMD) / VT-x (Intel) を見直す
   - `!! virbr0 already exists on the host …` は警告だけで、`kvm` は起動してしまう
   - 前回のコンテナの残骸なら `./kvm.sh down` → `sudo ip link del virbr0` → `./kvm.sh up` の順にやり直す ([注意点](#注意点))
   - **次の手順は、`>> ready.` が出てから貼る**

   <details>
   <summary>補足: 起動する</summary>

   `./kvm.sh up` の流れ ([SPEC.md 5.1](SPEC.md#51-起動シーケンス-kvmsh-up)): `/dev/kvm` の確認 (無ければ `modprobe`、0666 に) → root でないことの確認とホストユーザーの名前・uid/gid の取得 → イメージが無ければビルド → `data/` の初期化 → `check_host_network` → `/run/kvm-container/libvirt` を空にする → `kvm` を `podman run` → `>> waiting for libvirt...` (最大 30 秒) → `bridged` ネットワークの同期 → `>> ready.` → ディスプレイがあれば `kvm-gui` を起動。`kvm` が動いていれば `>> kvm is already running` で素通りする。

   **`kvm-gui` に渡すもの**

   `kvm.sh up` は実行ユーザーのセッション環境をそのまま `kvm-gui` に持ち込む (`kvm` には渡さない)。詳細は [SPEC.md 4.4](SPEC.md#44-マウント仕様と表示の仕組み) と [6 章](SPEC.md#6-設計上の不変条件)。

   - `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`) をコンテナの **`/run/host-xdg-runtime` に読み取り専用**でマウントし、Wayland ソケットと GNOME の Xwayland 認証ファイルは、その中を指す**絶対パス**で **`WAYLAND_DISPLAY` / `XAUTHORITY`** に渡す (unix ソケットへの接続は読み取り専用でも可)。シンボリックリンクの先が runtime dir の外にある場合は、そのソケットファイルだけを同じパスに読み取り専用でマウントする
   - **ホストの runtime dir をコンテナの `/run/user/<uid>` に同じパスでマウントしてはいけない。** コンテナの logind がそのディレクトリを自分のものとして管理し、ユーザーのセッションや `systemd --user` の開始時にホストの session bus や `systemd --user` のソケットを作り直し、`user-runtime-dir@.service` の停止処理で中身をすべて削除してしまう (ホストの Wayland ソケットや session bus が消える。cockpit を載せていた頃に、そのログイン / ログアウトで実際に起きた不具合。PR #10)
   - **コンテナ内の `/run/user/<uid>` は、コンテナの logind が GUI ユーザー用に作るディレクトリ** (`kvm` では tmpfs、非特権の `kvm-gui` では tmpfs をマウントできないので `/run` 直下のディレクトリ)。`gui-user-setup` がこのユーザーを linger にしているので起動時から存在する (session bus 付き)。GUI アプリはこれを使う
   - **`/tmp/.X11-unix` は読み取り専用でマウント** (X11 フォールバック用)。読み取り専用にするのは、コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐため (同じ理由で **`tmpfiles.d/x11.conf` をマスク**)
   - **どちらのコンテナでも GUI ユーザーはホストユーザーの写し**: 起動時に `gui-user.service` が `kvm.sh up` を実行したホストユーザーの名前・uid/gid で作る (イメージには一般ユーザーを焼き込んでいない)。ホストの runtime dir は 0700 なので、その中のソケットに届くには uid の一致が必要。**パスワードは設定しない** (コンテナにログインするものは無く、ユーザーはロックされたまま。ホストのパスワードやハッシュはコンテナに渡さない)。値は `podman run -e` で渡し、コンテナ内では PID 1 の environ から読む
   - **`/dev/dri` が無いホストではソフトウェア描画** (`LIBGL_ALWAYS_SOFTWARE=1`)。`/dev/dri` があれば `--device` で `kvm-gui` に渡し、`gui` が `renderD*` を 0666 にする
   - 渡した引数のハッシュをラベル `kvm.gui-session` に記録し、次の `up` でラベルと、コンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめる (再ログインで `/run/user/<uid>` が作り直されても、`kvm-gui` には古い runtime dir がマウントに残って中身だけ消えるため)。違えば `kvm-gui` だけ作り直す ([再ログインしたとき](#再ログインしたとき-繰り返し))

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

   詳細は [SPEC.md 4.6](SPEC.md#46-永続化データ-data-と共有-run-dir)。

   </details>

1. 両コンテナと、コンテナをまたぐ libvirt の接続を確かめる。

   ```bash
   sudo podman exec kvm systemctl is-system-running         # running (degraded ではない)
   sudo podman exec kvm ls -l /run/libvirt/virtqemud-sock   # srw-rw---- root libvirt
   ./kvm.sh virsh list --all                                # 空の一覧 (ヘッダだけ) で可
   if sudo podman container exists kvm-gui; then
     sudo podman exec kvm-gui systemctl is-system-running                          # running
     sudo podman exec kvm-gui runuser -u "$USER" -- virsh -c qemu:///system list   # 一般ユーザーが kvm-gui から kvm の libvirt に接続できること
   else
     echo 'kvm-gui が無い (画面なし): skip'
   fi
   ```

   - `kvm` の `systemctl is-system-running` が `running` (`degraded` ではない)
   - `virtqemud-sock` が `srw-rw---- root libvirt`
   - `virsh list --all` は空の一覧 (ヘッダだけ) で可
   - 画面のあるホストでは `kvm-gui` も確かめる。画面の無いホストでは `skip` と出るだけ
   - `degraded` なら `./kvm.sh shell` (`kvm-gui` は `./kvm.sh shell gui`) で `systemctl --failed` を見る
   - ログは `./kvm.sh logs` (`kvm-gui` は `./kvm.sh logs gui`)
   - この後は[VM を作る](#vm-を作る-vm-ごとに-1-度)に進む

   <details>
   <summary>補足: 動作確認</summary>

   - `systemctl is-system-running` が両コンテナで `running` (`degraded` ではない) ことは、Containerfile の unit マスク群 (`iscsid.socket` / `NetworkManager-wait-online.service` など) が効いているかの実質的な回帰テスト
   - `/run/libvirt/virtqemud-sock` が `srw-rw---- root libvirt` なのは `virtd-socket.conf` の drop-in が効いている証拠。`kvm-gui` から一般ユーザーで `virsh` が通ることが、コンテナをまたぐ libvirt 接続の回帰テスト ([選択した方針](#選択した方針))
   - `./kvm.sh logs` は `kvm` の `kvm-libvirt-conf` / `virtqemud` / `gui-user` の journal、`./kvm.sh logs gui` は `kvm-gui` の `/var/log/gui.log` と `gui-user` の journal を出す
   - 変更後の回帰確認は付録の確認手順 ([物理 GNOME](#付録-物理-almalinux-10--gnome-での確認手順) / [ディスプレイ無し](#付録-ディスプレイの無いホストでの確認手順) / [VM のライフサイクル](#付録-vm-のライフサイクルの確認手順)) を手で流す。期待結果は [SPEC.md 9 章](SPEC.md#9-検証手順)

   </details>

### VM を作る (VM ごとに 1 度)

- ISO を `data/` に置き、`virt-install` で VM (ディスクは SATA の SSD、NIC は e1000e) を作って、virt-viewer の画面でインストールする
- x86_64 のホストで行う。この節の手順 3 で使う SATA と e1000e は、aarch64 の qemu-kvm には無い
- [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェル (リポジトリ直下) で貼る。コンテナが止まっていれば、先に [VM 利用の手順 1](#vm-を使う-繰り返し) で起動する
- 2 台目からは、導入の手順 1 の `VM_NAME` (ISO を変えるなら `ISO` も) を変えて貼り直してから、この節の手順 1 から貼る
- VM をホストのブリッジにつなぐなら、先に[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 1〜8 を行う

1. ISO があるか確かめ、`data/` にコピーする。

   ```bash
   ls -l "${ISO:?導入の手順 1 の ISO が空のまま。値を入れて貼り直す}"
   sudo cp "${ISO:?導入の手順 1 の ISO が空のまま。値を入れて貼り直す}" data/var-libvirt/images/
   ```

   - `ls -l` が `No such file or directory` なら、導入の手順 1 の `ISO` を直して貼り直してから、この手順を貼り直す
   - ISO の大きさによっては時間がかかる
   - **次の手順は、`cp` が終わってから貼る**

   <details>
   <summary>補足: ISO の置き場所</summary>

   - `data/` は `sudo podman` で動くコンテナのバインドマウントなので root や qemu 所有になる。ホストから置く・消すには `sudo` が要る ([SPEC.md 4.6 節](SPEC.md#46-永続化データ-data-と共有-run-dir))
   - `data/var-libvirt` → `kvm` の `/var/lib/libvirt`、`data/etc-libvirt` → `/etc/libvirt`。ISO もディスクも VM 定義もホストの `data/` に残り、`./kvm.sh down` では消えない (`clean` だけが消す)
   - SELinux が Enforcing でも `:Z` などのラベル付けは要らない (`kvm` は `--privileged`)

   </details>

1. ISO が置けたか確かめる。

   ```bash
   sudo ls -l data/var-libvirt/images/   # ISO が root 所有で置かれている
   ```

   - ISO が root 所有で置かれていればよい

1. ディスクを SATA の SSD、NIC を e1000e にして VM を作る。

   ```bash
   ./kvm.sh virt-install --name "${VM_NAME:?導入の手順 1 の VM_NAME が空のまま。値を入れて貼り直す}" --memory "${VM_MEMORY}" --vcpus "${VM_VCPUS}" \
     --machine q35 --disk "size=${VM_DISK},bus=sata,target.rotation_rate=1" \
     --cdrom "/var/lib/libvirt/images/$(basename "${ISO:?導入の手順 1 の ISO が空のまま。値を入れて貼り直す}")" --osinfo detect=on,require=off \
     --network "network=${VM_NETWORK:?導入の手順 1 の VM_NETWORK が空のまま。導入の手順 1 を貼り直す},model=e1000e" --graphics vnc --noautoconsole
   ```

   - `virt-install` はすぐ戻り、VM はインストーラが起動した状態 (`running`) になる
   - ディスクは `/var/lib/libvirt/images/${VM_NAME}.qcow2` (ホストの `data/var-libvirt/images/`) に作られる
   - ディスクは SATA の SSD (`sda`)、NIC は `e1000e` になる (確かめるのはこの節の手順 5)
   - `VM_NETWORK=bridged` でネットワークが見つからないと言われたら、[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 6・7 (`KVM_BRIDGE` を付けた `up`) を先に行う
   - **注意**: aarch64 のホストでは通らない想定。qemu-kvm に SATA と e1000e が無い (この手順の補足)

   <details>
   <summary>補足: virt-install のオプション</summary>

   - `--osinfo` に OS 名を渡す場合の候補は `./kvm.sh virt-install --osinfo list` で確認できる
   - `--graphics vnc`・`--noautoconsole`・`--machine q35` と、`bus=sata`・`target.rotation_rate=1`・`model=e1000e` は固定 (理由は後半の補足の[選択した方針](#選択した方針))
   - `bus=sata` のディスクのターゲット名は `sda` になる。`--cdrom` の CD-ROM は virt-install が後ろに足すので `sdb` (どちらも SATA で、並び順に `sd*` が振られる)
   - `--machine q35` は、ISO から OS を検出できなかったときのため
   - 付けないと、検出できなかったときの virt-install は i440fx (`pc-i440fx-…`。RHEL 10 で非推奨) を選び、CD-ROM が IDE の `hda` になる (AlmaLinux 10 のコンテナの `--print-xml` で確認)
   - `target.rotation_rate=1` は定義の `<target dev='sda' bus='sata' rotation_rate='1'/>` になり、ゲストからはディスクが SSD (非回転) に見える
   - `rotation_rate` を付けられるのは SATA / SCSI / IDE のディスクだけ (libvirt 7.3 以降。virtio には無い)
   - `model=e1000e` の NIC は Intel 82574L のエミュレーション
   - `bus` と `model` を付けないと、virt-install は `--osinfo` で検出した OS から選ぶ。AlmaLinux のような virtio に対応した OS なら `vda` と `virtio` になる
   - 新しいディスクはスパースに作られ、virt-install が `discard='unmap'` を付ける (既定)。ゲストの TRIM がホストの qcow2 に届く想定で、確かめていない
   - SATA (AHCI) と e1000e は、x86_64 の qemu-kvm にはあるが、aarch64 の qemu-kvm には無い。CentOS Stream 10 の qemu-kvm のビルド設定で見たもので、AlmaLinux の aarch64 では確かめていない
   - `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。本書は導入の手順 1 の `VM_NETWORK` で明示し、ホストによってつなぎ先が変わらないようにした。ネットワークの仕様は [SPEC.md 4.5 節](SPEC.md#45-ネットワークとポート)
   - `default` につないだ VM がネットワークに出られること (インストーラがリポジトリに届き、起動後に `domifaddr --source agent` で IP が取れること) は PR #26 のライフサイクル確認で見ている ([付録](#付録-vm-のライフサイクルの確認手順))。そのときは `--network` を省いた形で、そのホストでは `default` につながった
   - `virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない。キックスタートは `OEMDRV` ラベルの ISO にして渡す ([付録](#付録-vm-のライフサイクルの確認手順)、[SPEC.md 8 章](SPEC.md#8-既知の制限事項))
   - `--cdrom` の VM は、インストーラの再起動で一度 `shut off` になり、以後はディスクから起動する。インストール後の CD-ROM は空 (`domblklist` の `sdb` が `-`) になる (旧 README の記述と virt-install の仕様による。実測は `--location` + キックスタート形で、`--cdrom` 形は再実行していない)
   - Windows と検出した ISO だけは、virt-install が CD-ROM に入れたままにする (インストールが何段階かに分かれるため。`--osinfo win11` の `--print-xml` で確認)。`domblklist` の `sdb` に ISO が残る

   </details>

1. virt-viewer で画面を開き、インストールする。

   ```bash
   ./kvm.sh viewer "${VM_NAME}"
   ```

   - ホストのデスクトップに virt-viewer のウィンドウが開き、インストーラの画面が出る。ウィンドウの中でインストールを進める
   - インストーラが最後に再起動すると VM は `shut off` になり、ウィンドウも閉じる (`--location` + キックスタートでの実測。`--cdrom` 形では再実行していない)
   - **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする (この手順の補足。未検証)
   - **次の手順は、VM が `shut off` になるか、ウィンドウを閉じてから貼る** (`viewer` はウィンドウが閉じるまで戻らない)

   <details>
   <summary>補足: viewer</summary>

   - `viewer` は先に `up` を実行する。コンテナが止まっていても、再ログインで表示先が変わっていても (`kvm-gui` だけ作り直される)、そのまま使える。VM は動いたまま ([再ログインしたとき](#再ログインしたとき-繰り返し))
   - VM 名を省くと一覧から選ぶダイアログが出る
   - ディスプレイの無いホスト (`DISPLAY` / `WAYLAND_DISPLAY` が無い、または `KVM_HOST=headless`) では `!! no display found ...` で終了コード 2 になる。シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で、抜けるのは `Ctrl+]`。ISO のインストーラがシリアルに出るかは ISO 次第 (未検証)
   - `viewer` は virt-viewer のウィンドウが閉じるまで戻らない。VM が `shut off` になるとウィンドウは自動で閉じる (`shutdown` で確認。[SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))

   </details>

1. VM ができ、ディスクが SATA の SSD、NIC が e1000e か確かめる。

   ```bash
   ./kvm.sh virsh list --all                       # VM_NAME の行がある (インストール完了後は shut off)
   ./kvm.sh virsh domblklist "${VM_NAME}"          # sda = /var/lib/libvirt/images/${VM_NAME}.qcow2。sdb はインストール中は ISO、終了後は空 (-)
   ./kvm.sh virsh dumpxml "${VM_NAME}" | grep "bus='sata'"   # sda の行に rotation_rate='1' (SATA の SSD)
   ./kvm.sh virsh domiflist "${VM_NAME}"           # Model が e1000e
   sudo ls -l "${REPO}/data/var-libvirt/images/"   # ${VM_NAME}.qcow2 と ISO がある (root / qemu 所有)
   ```

   - `VM_NAME` の行があり、インストール完了後は `shut off`
   - `domblklist` の `sda` が `/var/lib/libvirt/images/${VM_NAME}.qcow2`。`sdb` はインストール中は ISO、終了後は空 (`-`)
   - `grep` の出力に `<target dev='sda' bus='sata' rotation_rate='1'/>` がある
   - `domiflist` の `Model` が `e1000e`
   - `data/var-libvirt/images/` に `${VM_NAME}.qcow2` と ISO がある (root / qemu 所有)

   <details>
   <summary>補足: 動作確認</summary>

   - `domblklist` は削除の前にも使う。ディスクのターゲット名 (`sda` など) と CD-ROM (`sdb`) の中身が分かる
   - ターゲット名はバスで決まる。SATA はディスクも CD-ROM も `sd*` で、virtio のディスクは `vd*` (virtio で作った VM はディスクが `vda`、CD-ROM が `sda`)
   - `grep` は定義の `<target>` の行を拾う。CD-ROM の行は `<target dev='sdb' bus='sata'/>` で、`rotation_rate` はディスクにだけ付く
   - `domiflist` の `Interface` は、VM が止まっている間は `-` (動いている間は `vnet0` など)
   - ディスクファイルは `data/var-libvirt/images/<VM名>.qcow2`。`sudo ls -l` で所有者が root / qemu になっているのは仕様 (この節の手順 1 の補足)

   </details>

1. VM が `up` で自動起動するように設定する。

   ```bash
   ./kvm.sh virsh autostart "${VM_NAME}"           # up で自動起動する (解除は --disable)
   ```

   - 以後、`kvm` を起動するたびに (`./kvm.sh up`)、この VM も起動する
   - 自動起動させない VM では、`--disable` を付けて貼り直す
   - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には、この手順の `autostart` を設定する
   - この後の起動・画面・停止は[VM を使う](#vm-を使う-繰り返し)

### VM を使う (繰り返し)

- コンテナと VM を起動し、画面を見て、止めるまでの流れ。ホストの起動後やログインのたびに、要る手順だけを貼る
- [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェルで貼る。新しいシェルでは、導入の手順 1 の 2 つのブロックを貼り直してから始める
- ブリッジの節を通したホストでは、この節の手順 1 の `./kvm.sh up` を `KVM_BRIDGE=br0 ./kvm.sh up` に変えて貼る ([毎回 `KVM_BRIDGE=` を付ける](#毎回-kvm_bridge-を付ける))

1. コンテナを起動する (動いていれば何もしない)。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh up
   ```

   - `>> ready. VMs: …` が出れば `kvm` は起動している。動いていれば `>> kvm is already running`
   - 画面のあるホストでは、続けて `>> kvm-gui started. …` か `>> kvm-gui is already running` が出る
   - 再ログインの後なら `>> the host session has changed: recreating kvm-gui …` が出て、`kvm-gui` だけが作り直される
   - [VM 作成の手順 6](#vm-を作る-vm-ごとに-1-度) で自動起動を設定した VM は、`kvm` の起動と一緒に起動する
   - **次の手順は、`>> ready.` か `>> kvm is already running` が出てから貼る**

1. VM を起動する。

   ```bash
   ./kvm.sh virsh start "${VM_NAME:?導入の手順 1 の VM_NAME が空のまま。値を入れて貼り直す}"
   ./kvm.sh virsh domstate "${VM_NAME}"            # running
   ```

   - `domstate` が `running` になる
   - 自動起動などで動いていれば、`start` はエラーになる。`domstate` が `running` ならそのまま先へ進む

1. VM の画面を開く。

   ```bash
   ./kvm.sh viewer "${VM_NAME:?導入の手順 1 の VM_NAME が空のまま。値を入れて貼り直す}"
   ```

   - ホストのデスクトップに virt-viewer のウィンドウが開き、VM の画面が出る
   - VM が `shut off` になると、ウィンドウは自動で閉じる
   - **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする ([VM 作成の手順 4](#vm-を作る-vm-ごとに-1-度) の補足)
   - **次の手順は、ウィンドウを閉じてから貼る** (`viewer` はウィンドウが閉じるまで戻らない)

1. VM を ACPI で停止する。

   ```bash
   ./kvm.sh virsh shutdown "${VM_NAME}"            # ACPI で停止 (destroy は強制停止)
   ```

   - `shutdown` は非同期で、コマンドはすぐ戻る
   - **注意**: 起動途中の OS は ACPI に応じないことがある。OS が起動してログイン画面になってから貼る
   - **次の手順は、数十秒待ってから貼る**

1. VM が止まったか確かめる。

   ```bash
   ./kvm.sh virsh domstate "${VM_NAME}"            # shut off
   ```

   - `domstate` が `shut off` になる。`running` のままなら、少し待ってからもう一度貼る

1. ホストを再起動・シャットダウンする前だけ、コンテナを止める。

   ```bash
   ./kvm.sh down
   ```

   - 動いている VM は先に ACPI でシャットダウンされる (`>> shutting down the running VMs (up to 120 s)...`。120 秒で電源断)
   - `data/` (VM のディスク・定義) は残る
   - ホストの停止に任せると、VM が正常にシャットダウンできるとは限らない ([注意点](#注意点))
   - ホストの起動後は、この節の手順 1 から貼る。起動するのは、自動起動を設定した VM だけ

   <details>
   <summary>補足: 停止の仕組み (libvirt-guests)</summary>

   - `virsh shutdown` は ACPI の電源ボタンに相当し、ゲスト OS がシャットダウンを行う。`destroy` は電源断
   - `./kvm.sh down` (と `clean`) では、コンテナ内の `libvirt-guests.service` (`container/kvm/libvirt-guests`: `ON_SHUTDOWN=shutdown` / `ON_BOOT=ignore` / `SHUTDOWN_TIMEOUT=120`) が動いている VM を一斉に ACPI でシャットダウンする。これが無いとコンテナの systemd が qemu の scope をすぐ止め、VM は電源断と同じ状態になる (次の起動でルートの XFS のジャーナル復旧が走るのを PR #26 で確認)
   - `down` の `podman rm -t` は 180 秒 (`kvm.sh` の `KVM_STOP_TIMEOUT`) で、VM の待ちは 120 秒。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は scope の停止で電源を切られる。ACPI に応じない VM では `down` が 122 秒で終わることを確認している ([SPEC.md 5.2 節](SPEC.md#52-停止シーケンス-kvmsh-down))
   - `ON_BOOT=ignore` なので、`down` の時点で動いていた VM は次の `up` で起動しない。起動するのは `virsh autostart` を設定した VM だけ (`data/etc-libvirt/qemu/autostart/` の symlink)

   </details>

### 再ログインしたとき (繰り返し)

- GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えたりしたときに行う
- `kvm-gui` だけが作り直され、`kvm` と VM は動いたまま
- [VM 利用の手順 1](#vm-を使う-繰り返し) の `up` と `viewer` も同じことをしてから動くので、それらを使うならこの節は飛ばしてよい
- 仕組み: 再ログインで `/run/user/<uid>` は作り直されるが、`kvm-gui` は古い runtime dir をマウントしたまま中身だけ消える。`up` は渡した引数 (ラベル `kvm.gui-session`) とコンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめて作り直す

1. GNOME の端末を開き、[導入の手順 1](#導入する-1-度だけ) を貼ってから `kvm-gui` を作り直す。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh up gui
   ```

   - `>> the host session has changed: recreating kvm-gui (the kvm container and its VMs keep running)` が出る
   - 何も変わっていなければ `>> kvm-gui is already running`
   - 引数なしの `./kvm.sh up` でも同じ (`kvm` は `>> kvm is already running` で素通りする)
   - **次の手順は、`up` が終わってから貼る**

1. VM が動いたままか確かめる。

   ```bash
   ./kvm.sh virsh list   # VM が動いたまま
   ```

   - VM が動いたままならよい

---

## VM をホストのブリッジにつなぐ (任意)

- VM にホストと同じセグメントの IP (LAN の DHCP) を割り当てる。ホストにブリッジを作り、`KVM_BRIDGE` でそれを libvirt ネットワーク `bridged` として登録する
- [導入](#導入する-1-度だけ)の後、[VM を作る](#vm-を作る-vm-ごとに-1-度)の前に行う。[導入の手順 1](#導入する-1-度だけ) の `VM_NETWORK` は `bridged` にしておく
- この節の手順 9 だけは、[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) で VM を作った後に貼る
- すでに VM を作ったなら、導入の手順 1 の `VM_NAME` も別の名前にして貼り直す (作った VM の `default` からの付け替えは扱わない)
- **物理マシン / VM の AlmaLinux 10 + GNOME (NetworkManager) で、GNOME にログインした端末 (コンソール) から行う**。この節の手順 4 は NIC の接続をブリッジに切り替えるので、その NIC 越しの ssh は切れる
- ブリッジ自体はホスト側で作る (`kvm.sh` はホストのネットワーク設定を変更しない)。無線 NIC しか無いホストでは使えない ([無線 NIC は L2 ブリッジできない](#無線-nic-は-l2-ブリッジできない))
- **この節は通しで実行していない** ([付録](#付録-ブリッジの節-実行記録なし))。記述は `kvm.sh` の実装 (`check_host_network` / `sync_bridged_network`) から書いた
- この節の手順 3・4 の nmcli は物理ホストで本実行していない (検証に使った物理ホストは NIC が無線のみ)
- 元に戻すのは[ロールバック](#ロールバック)の手順 1〜4。この節の補足は[ブリッジにつなぐときの補足](#ブリッジにつなぐときの補足)

1. 変数を設定する (`NIC` は必ず値を入れる)。

   ```bash
   NIC=   # ← ブリッジに収容する物理 NIC (ip -br link で確認。例: enp1s0)。<NIC>
   ```

   ```bash
   BRIDGE=br0             # 作るブリッジの名前。libvirt ネットワーク bridged の実体になる。<BRIDGE>
   NIC_CON=$(nmcli -g NAME,DEVICE connection show --active | awk -F: -v d="${NIC}" '$2==d{print $1}')   # NIC の現在の接続名 (自動)。<NIC_CON>
   for v in NIC BRIDGE NIC_CON; do
     printf '%-8s = %s\n' "$v" "${!v}"
   done
   ```

   - `NIC` には、ブリッジに収容する物理 NIC の名前を入れる (`ip -br link` で確認する)
   - `BRIDGE` は、既定のままでよければそのまま貼る
   - `NIC_CON` は `NIC` から自動で入る
   - 値を読み戻して確かめる
   - `NIC_CON` が空なら、ここで止める。`NIC` の名前が違うか、その NIC に active な接続が無い (`nmcli connection show --active` で確かめる)
   - **`NIC_CON` の値を控えておく**。[ロールバック](#ロールバック)の手順 4 で NIC の元の接続を上げるのに使う
   - 新しいシェルを開いたら (SSH を張り直したあとも)、[導入の手順 1](#導入する-1-度だけ) と、この手順の 2 つのブロックを貼り直してから先へ進む。**この節の手順 4 の後に貼り直すと `NIC_CON` の値が変わる** (この手順の補足)

   <details>
   <summary>補足: 変数について</summary>

   - `REPO` と `VM_NAME` は[導入の手順 1](#導入する-1-度だけ) の変数を使う (この節では設定しない)
   - `NIC_CON` (接続名) と `NIC` (デバイス名) は別物で、同じとは限らない (`Wired connection 1` のような名前のことがある)。`nmcli connection down` は接続名を取るので、`nmcli -g NAME,DEVICE connection show --active` の出力からデバイス名で引いている。README にあった `awk -F: '$2=="enp1s0"{print $1}'` を `-v d="${NIC}"` で変数化した形で、その形では再実行していない
   - `NIC_CON` はこの手順を貼った時点の値を保持する。この節の手順 4 で NIC の接続を切り替えたあとにシェルを開き直してこの手順を貼ると、NIC に付いている接続は `bridge-slave-<NIC>` なので `NIC_CON` はその名前になる。ロールバックで元の接続名が要るので、この手順の読み戻しの出力を控えておく

   </details>

1. NIC が UP で、IP を持っているか確かめる。

   ```bash
   ip -br addr show "${NIC:?この節の手順 1 の NIC が空のまま。値を入れて貼り直す}"
   ```

   - NIC が `UP` で IP を持っていればよい (この IP がブリッジ側に移る)

1. ブリッジの接続と、NIC を収容する接続を作る。

   ```bash
   sudo nmcli connection add type bridge ifname "${BRIDGE:?この節の手順 1 の BRIDGE が空のまま。この節の手順 1 を貼り直す}" con-name "${BRIDGE}" ipv4.method auto
   sudo nmcli connection add type bridge-slave ifname "${NIC:?この節の手順 1 の NIC が空のまま。値を入れて貼り直す}" master "${BRIDGE}"
   ```

   - 物理 NIC をブリッジに収容し、IP はブリッジ側に持たせる
   - **次の手順は、コンソール (GNOME の端末) から単独で貼る** (NIC の接続を切り替えるので、その NIC 越しの ssh は切れる)

   <details>
   <summary>補足: nmcli でブリッジを作る</summary>

   - 1 行目で `type bridge` の接続 `${BRIDGE}` を作り (ifname と con-name を同じにする。`ipv4.method auto` はブリッジが DHCP で IP を受ける設定)、2 行目で NIC を収容する `type bridge-slave` の接続を作る (接続名は指定していないので NetworkManager の既定 `bridge-slave-<NIC>` になる)
   - 無線 NIC はここでは使えない ([無線 NIC は L2 ブリッジできない](#無線-nic-は-l2-ブリッジできない))

   </details>

1. コンソールから単独で、NIC の接続を落としてブリッジを上げる。

   ```bash
   sudo nmcli connection down "${NIC_CON:?この節の手順 1 の NIC_CON が空のまま。この節の手順 1 を貼り直す}" && sudo nmcli connection up "${BRIDGE}"
   ```

   - **注意**: この NIC 越しに ssh でつないでいるとセッションが切れ、2 つ目のコマンドが走らないことがある。コンソール (GNOME の端末) から、このブロックだけを単独で貼る
   - **次の手順は、ブリッジが上がって IP が付いてから貼る** (数秒かかる)

   <details>
   <summary>補足: 接続の切り替え</summary>

   - NIC の元の接続を落とし、ブリッジを上げる。これで NIC は bridge-slave としてブリッジに付き、IP はブリッジ側に来る。その NIC 越しの ssh はここで切れる (`&&` の 2 つ目が走らずに終わることがあるので、コンソールから貼る)

   </details>

1. ブリッジが上がり、`kvm.sh` がブリッジと判定できるか確かめる。

   ```bash
   ip -br addr show "${BRIDGE}"                  # UP で、LAN の DHCP から IP が付く (NIC と同じ IP になるかは未確認)
   ls -d "/sys/class/net/${BRIDGE}/bridge"       # kvm.sh がブリッジと判定する条件 (このディレクトリがあること)
   ```

   - `ip -br addr show` でブリッジが `UP` で、LAN の DHCP から IP が付く (NIC と同じ IP になるかは未確認)
   - `ls -d` が `No such file or directory` なら、この節の手順 7 の `up` は `!! KVM_BRIDGE=... is not a bridge on this host` で止まる
   - そのときはブリッジの名前と状態を見直してから先へ進む

   <details>
   <summary>補足: ブリッジの判定</summary>

   - `ls -d /sys/class/net/<ブリッジ名>/bridge` は、`kvm.sh` の `check_host_network` が `KVM_BRIDGE` をブリッジと判定する条件そのもの ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

   </details>

1. ブリッジを登録するため、先に `kvm` を止める。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。導入の手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
   ```

   - 動いている VM は ACPI でシャットダウンされる (最大 120 秒待つ)
   - `kvm` が動いたままだと、この節の手順 7 の `up` は `>> kvm is already running` で戻り、`bridged` は登録されない (この節の手順 7 の補足)
   - **次の手順は、`down` が終わってから貼る**

   <details>
   <summary>補足: <code>down kvm</code></summary>

   - `down kvm` は動いている VM を `libvirt-guests` が ACPI でシャットダウンしてから止める (120 秒で電源断、`podman rm -t` は 180 秒。[SPEC.md 5.2](SPEC.md#52-停止シーケンス-kvmsh-down))。`down` の時点で動いていた VM は次の `up` で起動しない (`virsh autostart` の VM を除く。[VM 作成の手順 6](#vm-を作る-vm-ごとに-1-度))。`down kvm` の間 `kvm-gui` は残るが libvirt に届かない状態になり、次の `up` で `kvm` が起動して共有の `/run/libvirt` が空にされると復帰する。`down` (両方) でもよい

   </details>

1. `KVM_BRIDGE` を付けて `kvm` を起動し、ブリッジを `bridged` として登録する。

   ```bash
   KVM_BRIDGE="${BRIDGE:?この節の手順 1 の BRIDGE が空のまま。この節の手順 1 を貼り直す}" ./kvm.sh up
   ```

   - `>> waiting for libvirt...` のあとに、`>> libvirt network "bridged" -> host bridge <ブリッジ名> (use it with …)` と出る
   - 最後に `>> ready. VMs: ...` で戻る
   - **注意**: 以後、`kvm` を起動するすべての経路に毎回 `KVM_BRIDGE=` を付ける
   - 付けずに `kvm` を起動すると `bridged` は削除される (`>> KVM_BRIDGE is not set: removing the libvirt network "bridged"`)
   - `./kvm.sh viewer` も内部で `up` を呼ぶので、`KVM_BRIDGE=br0 ./kvm.sh viewer` にする
   - [VM 利用の手順 1](#vm-を使う-繰り返し) の `up` も同じで、`KVM_BRIDGE=br0` を付けて貼る
   - `./kvm.sh up gui` (再ログイン後の `kvm-gui` の作り直し) は `bridged` に影響しない。`kvm` が動いている限り `bridged` はそのまま
   - **次の手順は、`>> ready.` が出てから貼る**

   <details>
   <summary>補足: <code>bridged</code> の登録と <code>KVM_BRIDGE</code> の付け忘れ</summary>

   - `bridged` の登録は `sync_bridged_network` ([SPEC.md 5.6](SPEC.md#56-ブリッジ同期-sync_bridged_network)) が行う。これは `start_kvm` が `podman run` で `kvm` を新しく起動し、libvirt の readiness を確認した直後にしか走らない。`kvm` がすでに動いていると `start_kvm` は `>> kvm is already running` で先に戻るので (`kvm.sh` の `start_kvm` 冒頭)、`KVM_BRIDGE=` を付けて `up` しても何も起きない。そのためこの節の手順 6 の `down kvm` と手順 7 の `KVM_BRIDGE=… up` に分けてある
   - 起動前に `check_host_network` が `/sys/class/net/<ブリッジ名>/bridge` の有無を確かめ、無ければ `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/setup.md)` で exit 1 する ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))。この節の手順 3・4 を飛ばしたときに出る
   - `sync_bridged_network` は毎回 define し直す (active なら `net-destroy` してから define → autostart → start)。`KVM_BRIDGE` の値を変えるとその値に追従する。`KVM_BRIDGE` が無いと `bridged` を `net-destroy` / `net-undefine` する。定義は `data/etc-libvirt` (`/etc/libvirt/qemu/networks/`) に永続化されるが、この削除で消える
   - `viewer` は内部で `up` を呼ぶ (`kvm` が止まっていれば起動する) ので、`kvm` が止まった状態で `KVM_BRIDGE=` 無しに `viewer` を実行すると `bridged` が削除される。`kvm` を起動し得る経路 (`up`、`up kvm`、`viewer`) には毎回 `KVM_BRIDGE=` を付ける。`up gui` は `kvm` に触らないので影響しない

   </details>

1. `bridged` が登録されたか確かめる。

   ```bash
   ./kvm.sh virsh net-list                # bridged が active (default と並ぶ)
   ./kvm.sh virsh net-dumpxml bridged     # forward mode が bridge、bridge name が BRIDGE の値
   ```

   - `net-list` で `bridged` が active (`default` と並ぶ)
   - `net-list` に `bridged` が無ければ、`kvm` を止めずに `up` したか、`KVM_BRIDGE=` を付け忘れている。この節の手順 6・7 をやり直す
   - この後は[VM を作る](#vm-を作る-vm-ごとに-1-度)に進む
   - [導入の手順 1](#導入する-1-度だけ) の `VM_NETWORK` を `bridged` にして貼ると、[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の `virt-install` が `--network network=bridged` で VM を作る
   - VM は LAN の DHCP から IP を取る (ホストと同じセグメント)

   <details>
   <summary>補足: 動作確認</summary>

   - `net-list` で `bridged` が active なこと。`KVM_BRIDGE` 周りを変えたときの確認点は [SPEC.md 9.4](SPEC.md#94-その他の確認点-変更内容に応じて) (`KVM_BRIDGE` 無しで `up` すると消えることも含む)
   - `net-dumpxml bridged` は `kvm.sh` が define した XML (`<name>bridged</name>`、`<forward mode="bridge"/>`、`<bridge name="<ブリッジ名>"/>`) を返す想定。新規の確認行で本実行していないので、出力にはこれに libvirt が足す `<uuid>` などが加わる

   </details>

1. [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の後に、VM が `bridged` につながっていることを確かめる。

   ```bash
   ./kvm.sh virsh domiflist "${VM_NAME:?導入の手順 1 の VM_NAME を設定してから貼る}"   # Type が network、Source が bridged
   ```

   - [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェル (リポジトリ直下) で貼る
   - `Type` が `network`、`Source` が `bridged` ならよい
   - 既存の VM の付け替え (定義の `<source network='default'/>` を `bridged` にする) は本書では扱わない (この手順の補足)

   <details>
   <summary>補足: VM の接続</summary>

   - `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。この節の手順 4 のあとはホストの既定経路がブリッジ上にあるので、`--network` を省いた VM もそのブリッジに直接つながり得る (この経路は `bridged` を経由しない)。[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) は `VM_NETWORK` で `--network` を明示する ([SPEC.md 8 章](SPEC.md#8-既知の制限事項))
   - `bridged` の VM は tap がブリッジのポートになり、VM 自身の MAC で LAN に出る。仮想スイッチが MAC アドレスの詐称を許さない環境では、この形は通信できない
   - 既存の VM の付け替えは、`kvm` イメージにエディタが無いので `virsh edit` がそのままでは使えない。`virsh dumpxml` → 編集 → `virsh define` の手順も未検証
   - `domiflist` の確認は新規の行で、本実行していない

   </details>

---

## 使い方の基本

| サブコマンド | 用途 | 使う手順 |
|---|---|---|
| `./kvm.sh build [kvm\|gui]` | 2 つのイメージをビルド (`localhost/kvm-container/kvm`、`localhost/kvm-container/gui`)。`build kvm` / `build gui` で片方だけ | [導入の手順 6〜7](#導入する-1-度だけ) |
| `./kvm.sh up [kvm\|gui]` | `kvm` を起動し、ディスプレイがあれば `kvm-gui` も起動 (kvm モジュールのロードと `/dev/kvm` の権限調整も行う)。`up gui` は `kvm-gui` だけ (再ログイン後など。`up` は `kvm-gui` が別のセッション用なら作り直す) | [導入の手順 8](#導入する-1-度だけ) / [VM 利用の手順 1](#vm-を使う-繰り返し) / [再ログインの手順 1](#再ログインしたとき-繰り返し) |
| `KVM_BRIDGE=br0 ./kvm.sh up` | VM をホストのブリッジ `br0` に接続できるようにして起動 | [ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 7 |
| `./kvm.sh virt-install ...` | VM を作る (`kvm` コンテナ内の virt-install) | [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) |
| `./kvm.sh virsh ...` | virsh (`kvm` コンテナ)。`list` / `start` / `shutdown` / `destroy` / `undefine` など | [VM 作成の手順 5〜6](#vm-を作る-vm-ごとに-1-度) / [VM 利用の手順 2〜5](#vm-を使う-繰り返し) / [VM を削除する](#vm-を削除する) |
| `./kvm.sh viewer [VM名]` | VM の画面を virt-viewer で表示 (VM 名を省くと一覧から選ぶダイアログ) | [VM 作成の手順 4](#vm-を作る-vm-ごとに-1-度) / [VM 利用の手順 3](#vm-を使う-繰り返し) |
| `./kvm.sh shell [kvm\|gui]` | コンテナ内 root シェル (既定 `kvm`) | [導入の手順 9](#導入する-1-度だけ) |
| `./kvm.sh logs [kvm\|gui]` | libvirt の journal と GUI アプリのログ | [導入の手順 9](#導入する-1-度だけ) |
| `./kvm.sh down [kvm\|gui]` | コンテナ停止・削除 (VM のディスク / 定義はホストの `data/` に残る)。引数なしで両方 | [VM 利用の手順 6](#vm-を使う-繰り返し) / [ロールバック](#ロールバック)の手順 5 |
| `./kvm.sh clean` | コンテナと `data/` のデータをすべて削除 (確認あり) | [ロールバック](#ロールバック)の手順 6 |

- `up` は足りないイメージを自動でビルドする。`viewer` は先に `up` を実行するので、コンテナが止まっていても、再ログインで表示先が変わっていても、そのまま使える
- `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `TZ`) は、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける。一覧は補足の[環境変数](#環境変数)
- `./kvm.sh` を引数なしで実行すると、`kvm.sh` 冒頭のヘッダコメント (サブコマンドと環境変数の一覧) が出る

---

## VM を削除する

- [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェル (リポジトリ直下) で貼る。コンテナが止まっていれば、先に [VM 利用の手順 1](#vm-を使う-繰り返し) で起動する
- コンテナごと止める・`data/` ごと消すのは[ロールバック](#ロールバック)の手順 5〜7 (`down` は `data/` を残し、`clean` だけが消す)
- 削除の注意は補足の[VM を削除するときの注意](#vm-を削除するときの注意)

> [!CAUTION]
> **この節の手順 5 で、VM の定義・UEFI 変数・ディスク (`sda`) が消え、取り戻せない。** ISO は残る。

1. 削除するディスクと、CD-ROM の中身を確かめる。

   ```bash
   ./kvm.sh virsh domblklist "${VM_NAME:?導入の手順 1 の VM_NAME が空のまま。値を入れて貼り直す}"   # sda = 消すディスク。sdb に ISO が入ったままなら次の手順で取り出す
   ```

   - `sda` が消すディスク
   - `sdb` が `-` なら、この節の手順 2 は飛ばす (`--cdrom` でインストールした VM は、Windows 以外はインストール後に取り出されている)
   - `vda` が出たら virtio で作った VM。この節の `sda` を `vda` に、`sdb` を `sda` に読み替えて貼る ([VM を削除するときの注意](#vm-を削除するときの注意))

1. `sdb` に他の VM と共有している ISO が入ったままのときだけ、取り出す。

   ```bash
   ./kvm.sh virsh change-media "${VM_NAME}" sdb --eject --config   # CD-ROM から ISO を取り出す (定義にも反映)
   ```

   - 本実行していない

1. VM を ACPI で止める。

   ```bash
   ./kvm.sh virsh shutdown "${VM_NAME}"
   ```

   - 急ぐなら `shutdown` を `destroy` (強制停止) に変えて貼る
   - 止まっている VM では `domain is not running` のエラーになるが、そのまま先へ進んでよい
   - **次の手順は、数十秒待ってから貼る**

1. VM が止まったか確かめる。

   ```bash
   ./kvm.sh virsh domstate "${VM_NAME}"   # shut off。running のままなら少し待ってもう一度貼る
   ```

   - `running` のままなら、少し待ってからもう一度貼る
   - **次の手順は、`shut off` になったのを確かめてから貼る**

1. VM の定義・UEFI 変数・ディスクを消す (取り戻せない)。

   ```bash
   ./kvm.sh virsh undefine "${VM_NAME}" --nvram --storage sda   # 定義・UEFI 変数・ディスクを削除 (ISO は残る)
   sudo ls "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}/data/var-libvirt/images" "${REPO}/data/etc-libvirt/qemu"   # qcow2 と xml が消え、ISO は残っている
   ```

   - `sudo ls` で、qcow2 と xml が消え、ISO が残っていることを確かめる

1. ISO も消すときだけ、他の VM が使っていないことを `domblklist` で確かめてから消す。

   ```bash
   sudo rm "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}/data/var-libvirt/images/$(basename "${ISO:?導入の手順 1 の ISO が空のまま。値を入れて貼り直す}")"
   ```

   - 本実行していない

---

## 更新

- リポジトリを最新にし、イメージを作り直してコンテナを起動し直す。`data/` (VM のディスク・定義) はそのまま使える
- ブリッジの節を通したホストでは、この節の手順 2 の最後の `./kvm.sh up` を `KVM_BRIDGE=br0 ./kvm.sh up` に変えて貼る (`br0` はブリッジの節の手順 1 の `BRIDGE`)。付けないと `bridged` が消える ([毎回 `KVM_BRIDGE=` を付ける](#毎回-kvm_bridge-を付ける))
- この節の手順は、この形では本実行していない (以前は `git pull` → `./kvm.sh down` → `./kvm.sh build` → `./kvm.sh up` と書いていたが、その流れも本実行していない)

1. リポジトリを最新にし、コンテナを止める。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。導入の手順 1 を貼り直す}" && git pull --ff-only
   ./kvm.sh down
   ```

   - 動いている VM は ACPI でシャットダウンされる (最大 120 秒)
   - **次の手順は、`down` が終わってから貼る**

1. イメージを作り直して起動する。

   ```bash
   ./kvm.sh build kvm && { [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || ./kvm.sh build gui; } && ./kvm.sh up
   ```

   - 画面の無いホストでは `gui` を作らない
   - `>> ready.` が出れば終わり。確認は[導入の手順 9](#導入する-1-度だけ)
   - **次の手順は、`>> ready.` が出てから貼る**

1. 旧版で `install-desktop` を実行したときだけ、残ったランチャーを消す。

   ```bash
   rm -f "${XDG_DATA_HOME:-$HOME/.local/share}"/applications/kvm-{virt-viewer,virt-manager,firefox}.desktop \
     "${XDG_DATA_HOME:-$HOME/.local/share}"/icons/hicolor/*/apps/{virt-viewer,virt-manager,firefox}.*
   ```

   - アクティビティからの起動 (`install-desktop` / `launch`) は廃止した。残ったランチャーは、押しても VM の画面が開かない
   - sudo は要らない
   - 本実行していない

---

## ロールバック

- 上から順に、通した節の分だけ実行する
- ブリッジの節を通したときは、先に `bridged` につないだ VM を止め、`default` に付け替える (本書では扱わない) か[VM を削除する](#vm-を削除する)で消す
- ブリッジの節を通したときは、この節の手順 4 を GNOME の端末 (コンソール) から単独で貼る。ブリッジを消すと、その NIC 越しの ssh は切れる
- この節の手順 1〜4 と手順 7 は本実行していない
- `bridged` の VM が残ったまま `KVM_BRIDGE` 無しで `up` したときの挙動は未確認 ([付録](#付録-ブリッジの節-実行記録なし))

> [!CAUTION]
> **この節の手順 6 で `data/` ごと、VM のディスク・定義が消え、取り戻せない。**

1. ブリッジの節を通したときだけ、`bridged` を外すため、まず `kvm` を止める。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。導入の手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
   ```

   - **次の手順は、`down` が終わってから貼る**

1. ブリッジの節を通したときだけ、`KVM_BRIDGE` を付けずに `kvm` を起動し直し、`bridged` を削除する。

   ```bash
   ./kvm.sh up                  # KVM_BRIDGE 無し: bridged を削除する (>> KVM_BRIDGE is not set: removing ...)
   ```

   - **次の手順は、`>> ready.` が出てから貼る**

1. ブリッジの節を通したときだけ、`bridged` が消えたか確かめる。

   ```bash
   ./kvm.sh virsh net-list      # bridged が消えている (default だけ)
   ```

   - `bridged` が消え、`default` だけならよい
   - `NIC_CON` はブリッジの節の手順 1 で控えた元の接続名
   - 新しいシェルなら、[導入の手順 1](#導入する-1-度だけ) とブリッジの節の手順 1 を貼り直してから、`NIC_CON=` に控えた名前を入れ直す (ブリッジの節の手順 1 を貼り直すと、`NIC_CON` は `bridge-slave-…` の名前になる)
   - bridge-slave の接続名は NetworkManager の既定 (`bridge-slave-<NIC>`)。違っていれば `nmcli connection show` で確かめる
   - **次の手順は、`NIC_CON` に元の接続名が入っているのを確かめてから、コンソールで単独で貼る** (ブリッジを消すと、その NIC 越しの ssh は切れる)

1. ブリッジの節を通したときだけ、コンソールから単独で、ブリッジを消して NIC の元の接続を上げる。

   ```bash
   sudo nmcli connection delete "${BRIDGE:?ブリッジの節の手順 1 の BRIDGE が空のまま。ブリッジの節の手順 1 を貼り直す}" "bridge-slave-${NIC:?ブリッジの節の手順 1 の NIC が空のまま。値を入れて貼り直す}"
   sudo nmcli connection up "${NIC_CON:?ブリッジの節の手順 1 で控えた元の接続名を NIC_CON に入れてから貼る}"
   ```

   - ブリッジを消してから NIC に IP が戻るまでは通信できないので、2 行を続けて実行する
   - `ip -br addr show "${NIC}"` で、NIC に LAN の IP が戻っていることを確かめる

1. コンテナを止めて消す。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh down
   ```

   - 動いている VM は先に ACPI でシャットダウンされる (`>> shutting down the running VMs (up to 120 s)...`。120 秒で電源断)
   - `data/` (VM のディスク・定義) は残り、`/run/kvm-container` は消える
   - VM を止めるだけならここまでで、この節の手順 6・7 は飛ばす
   - **次の手順は、`down` が終わってから貼る**

1. `data/` ごと消すときだけ、`clean` で VM のディスク・定義も消す (取り戻せない)。

   ```bash
   ./kvm.sh clean
   ```

   - `This deletes the VM disks and definitions as well. Continue? [y/N]` に `y` と答える
   - `clean` は内部で `down` を呼ぶので、この節の手順 5 を飛ばしてもよい
   - **次の手順は、`[y/N]` に答えてから貼る** (続けて貼ると答えとして食われる)

1. イメージも消すときだけ、`kvm` と `gui` のイメージを消す。

   ```bash
   sudo podman rmi --ignore localhost/kvm-container/kvm:latest localhost/kvm-container/gui:latest
   ```

   - 本実行していない
   - 画面の無いホストには `gui` のイメージが無いが、`--ignore` で無視される
   - ホストに入れた podman と git はそのまま残す
   - clone したリポジトリも要らなければ、`clean` の後に `cd ~ && rm -rf "${REPO}"` で消す (本実行していない)

---

## 補足

### 対象と検証環境

- **目的**: qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナに収め、qemu も libvirt も入れていない軽量なホストで VM を動かし、その画面をホストのデスクトップに表示する
  - VM の作成・操作はコマンドライン (`./kvm.sh virt-install` / `./kvm.sh virsh`。`kvm` コンテナ内の `virt-install` / `virsh --connect qemu:///system` の省略形)、画面の表示は `./kvm.sh viewer` (`kvm-gui` の virt-viewer。ブラウザや Web コンソールは使わない)
  - VM のディスクは SATA の SSD、NIC は e1000e にする (VM 作成の手順 3。x86_64 のホスト向け)
  - `kvm-gui` は `kvm` の libvirt に共有 unix ソケット経由で接続する。デスクトップの再ログイン後は `kvm-gui` だけを作り直せるので、VM を止めずに済む
  - ディスプレイの無いホストでは `kvm` だけを使う (GUI イメージのビルドも不要)
  - 任意で、VM にホストと同じセグメントの IP (LAN の DHCP) を割り当てることもできる
- **進め方**: ホストに入れるのは podman と git だけ。clone した `kvm.sh` が `sudo podman` でビルド・起動・停止をすべて行う
  - 導入の手順 1 で ISO のパスと VM 名を決め、以降のコマンドはそのまま貼る
  - 読者が書き換えるのは `ISO` だけ (ブリッジの節では `NIC` も)。clone 先・VM 名・メモリ・vCPU・ディスク・ネットワークは既定のままでもよい
- **状態**:
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
  - **VM** (VM 作成の手順 1〜6、VM 利用の手順 2・4・5、VM を削除する): 物理 AlmaLinux 10.2 + GNOME、SELinux Enforcing で、作成 → 起動 → `viewer` → `reboot` → `shutdown` → `suspend` / `resume` → `destroy` → 稼働中の `down kvm` → `autostart` → `undefine --nvram --storage vda` の一式を通した (PR #26。[付録](#付録-vm-のライフサイクルの確認手順))
    - **ただしそのときの作成は `--location` + キックスタート形で、`--network` も省いていた。** VM 作成の手順 3 の `--cdrom` 形は README の例を変数形に書き換え、`--network "network=${VM_NETWORK}"` を足したもので、その形では再実行していない
    - **記録の VM はディスクが virtio で、NIC は `--network` を省いた virt-install の既定だった**。記録のディスクは `vda`
    - VM 作成の手順 3 の `--machine q35`・`bus=sata,target.rotation_rate=1`・`model=e1000e` は、物理ホストでは本実行していない
    - それに合わせて `sda` / `sdb` に付け替えた行 (VM 作成の手順 5、[VM を削除する](#vm-を削除する)の手順 1・2・5、補足) も本実行していない
    - VM 作成の手順 3 の引数は、AlmaLinux 10 のコンテナ (virt-install 5.1.0、libvirt 11.10.0、qemu-kvm 10.1.0) で `virt-install --print-xml` と `virsh define` まで確かめた
    - KVM の無いコンテナなので `--virt-type qemu` を足し、ISO は空のファイルにした。OS を `--osinfo almalinux10` で渡した形と、検出できない形の両方で同じ名前になった。VM は起動していない
    - そのコンテナでは、ディスク `sda` (`bus='sata' rotation_rate='1'`)・CD-ROM `sdb`・NIC `e1000e` になり、VM 作成の手順 5 の `grep` / `domblklist` / `domiflist` もそのとおりに出た
    - 同じコンテナで、virtio の VM に `undefine --storage sda` を付けると CD-ROM に入ったままの ISO が消え、SATA の VM では `sda` の qcow2 だけが消えることも確かめた
    - VM 作成の手順 1・2・4〜6、VM 利用の手順 2・4・5 と「VM を削除する」の各行も README の例を変数形に書き換えたもので、その形では再実行していない
    - 新しく足した行で、本実行していないもの: 導入の手順 1 の `VM_NETWORK`、VM 作成の手順 5 の `sudo ls -l`・`dumpxml` の `grep`・`domiflist`、VM 利用の手順 2・5 の `domstate`、[VM を削除する](#vm-を削除する)の手順 2〜4 (`change-media --eject --config`・`shutdown`・`domstate`) と手順 6 (ISO の `sudo rm`) (`--remove-all-storage` が ISO を消すことは `lctest` で確認した)
    - ディスプレイの無いホストでの VM の作成・操作 (`virt-install` / `virsh console`) は未検証。そこで確認したのは `up` 〜 `down` だけ
    - PR #28 のディスプレイ無しのホストは aarch64 で、VM 作成の手順 3 の SATA と e1000e はその qemu-kvm に無い ([VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の補足)
  - **ブリッジの節**: **通しで実行していない。** `KVM_BRIDGE` の機構 (`bridged` の登録・削除と、`bridged` につないだ VM の疎通) を現行構成で確認した記録は無い
    - 記述は `kvm.sh` の実装 (`check_host_network` / `sync_bridged_network`。[SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [5.6](SPEC.md#56-ブリッジ同期-sync_bridged_network)) から書いたもの
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
| VM の作成・操作 | ライフサイクル一式 (PR #26。[付録](#付録-vm-のライフサイクルの確認手順)、期待結果は [SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル)) | 未実施 (`virsh list` が通るところまで。`viewer` が使えないことは [SPEC.md 8 章](SPEC.md#8-既知の制限事項)) |
| VM の作成形 | `--location` + キックスタート (`OEMDRV` ISO)、`--network` 省略、ディスクは virtio (`vda`)。VM 作成の手順 3 の `--cdrom` 形は未再実行、SATA の SSD / e1000e はコンテナで XML まで確認 | — |
| ゲスト OS | AlmaLinux 10.2 (boot ISO `AlmaLinux-10.2-x86_64-boot.iso`) | — |
| ブリッジの節 (`KVM_BRIDGE`) | 未検証 (NIC が無線のみ) | 未検証 |

対応ホスト:

| ホスト | 画面表示 |
| --- | --- |
| 物理マシン / VM の AlmaLinux 10 + GNOME | GNOME (Wayland) デスクトップに表示 |
| ディスプレイの無いホスト (SSH のみ) | 画面表示なし。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[導入の手順 1](#導入する-1-度だけ) (ブリッジの節ではその節の手順 1 も) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
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

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

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
  - `./kvm.sh virt-install` は `sudo podman exec -it kvm virt-install --connect qemu:///system`、`./kvm.sh virsh` は `sudo podman exec -it kvm virsh -c qemu:///system` の省略形 ([SPEC.md 4.1 節](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-))。ホストに virt-install / virsh を入れない
  - ブラウザや Web コンソール (cockpit) は廃止した (PR #25)
  - RHEL 10 系の qemu-kvm には SPICE が無いので、グラフィックスは VNC (下の `--graphics vnc`)
- **`kvm` は `--privileged --network host`**: KVM、libvirt の `default` ネットワーク (NAT / dnsmasq)、ホストのブリッジへの接続のため
  - `kvm-gui` は非特権だが `--security-opt label=disable`。SELinux Enforcing のホストで、特権コンテナが作った unix ソケットへ接続し、ホストの runtime dir を読むため
- **コンテナをまたぐ libvirt 接続**: `/run/libvirt` はホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナにバインドマウントしたもの。詳細は [SPEC.md 3.5](SPEC.md#35-コンテナ間の-libvirt-接続) と [6 章](SPEC.md#6-設計上の不変条件)
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
  - そのため空のときだけ、`kvm.sh up` が `kvm` イメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動する ([導入の手順 8 の補足](#導入する-1-度だけ))
- **分岐はブロックの中で判定する**: 導入で画面の有無によって変わるのは、GUI イメージのビルド (導入の手順 7) と `kvm-gui` の確認 (導入の手順 9) だけ。どちらもブロックの中で判定し、どちらのホストでも同じブロックを上から貼れるようにした
  - VM の画面を出す VM 作成の手順 4 と VM 利用の手順 3 は、ディスプレイの無いホストでは `!! no display found ...` で終わる
- **実施手順はシナリオで見出しを分ける**: 1 度だけ行う導入と VM の作成、繰り返し行う VM の利用と再ログイン後の作り直しを、`## 実施手順` の下の見出しに分けた
  - 手順の番号は見出しごとに 1 から数え、ほかの見出しの手順は「導入の手順 1」「VM 利用の手順 2」のように呼ぶ
  - 繰り返すシナリオは、導入の手順 1 の変数を貼り直せば、その見出しの手順 1 から始められる
- **画面は端末から開く**: アクティビティ (アプリ一覧) からの起動は廃止した。端末の無い `sudo -n` を前提にしたうえ、現行のエントリを本実行できていなかったため
  - `KVM_SOFTWARE_GL` (ソフトウェア描画の強制) と `KVM_CLEAN_YES` (`clean` の確認の省略) も廃止した。`/dev/dri` が無いホストでは、今までどおり自動でソフトウェア描画になる
  - ホストの音声 (PulseAudio / PipeWire) のソケットは `kvm-gui` に渡さない。VNC の VM 画面を出す virt-viewer では使わないため
- **`--graphics vnc`**: RHEL 10 系の qemu-kvm には SPICE が無いため。VNC は `kvm` がホストの loopback で listen し、`kvm-gui` の virt-viewer が libvirt 経由で接続する
- **`--noautoconsole`**: `kvm` コンテナに virt-viewer が無いため。画面は `./kvm.sh viewer` で開く
- **`--osinfo detect=on,require=off`**: ISO から OS を検出し、検出できなくても中断しない。OS 名を渡すなら `--osinfo list` の候補から選ぶ
- **`--network` は明示する**: 省くと virt-install がホストの既定経路からつなぎ先を選び、ブリッジのあるホストでは `default` にならない。導入の手順 1 の `VM_NETWORK` (既定 `default`) で決め、[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)を通したホストでは `bridged` を選べるようにした
- **ディスクは SATA の SSD、NIC は e1000e**: VM 作成の手順 3 で `--machine q35`、`--disk` に `bus=sata,target.rotation_rate=1`、`--network` に `model=e1000e` を付けて固定する
  - ゲストには、準仮想化の virtio ではなく実機と同じ種類の装置 (AHCI の SATA、Intel 82574L の NIC) に見える。virtio のドライバが無い OS でも扱える (性能は一般に virtio より低い)
  - 付けないと、virt-install は `--osinfo` の検出結果でマシン (q35 / i440fx)・ディスク・NIC を選ぶ。明示して、ISO によらず同じ構成にする
  - ターゲット名はディスクが `sda`、`--cdrom` の CD-ROM が `sdb`。削除 (`--storage sda`) と CD-ROM の取り出し (`change-media … sdb`) はこの名前で指定する
  - x86_64 のホスト向け。aarch64 の qemu-kvm には SATA (AHCI) と e1000e が入っていない ([VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の補足)
- **ISO は `data/var-libvirt/images/` に置く**: ホストの `data/var-libvirt` が `kvm` コンテナの `/var/lib/libvirt` なので、コンテナ内では `/var/lib/libvirt/images/` に見える。VM 作成の手順 3 の `--cdrom` に渡すのはコンテナ内のパス
- **削除は `undefine --nvram --storage sda`**: `--remove-all-storage` は CD-ROM に入ったままの ISO も消すので、消すディスクを `--storage` で指定する。`--nvram` は UEFI の VM に必須で、BIOS の VM に付けても害は無い

### 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `headless` にすると、表示用環境変数があっても `kvm-gui` を起動しない (他の値は `auto` と同じ) |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_BRIDGE` | 未設定 | ホストの既存ブリッジ名 (例 `br0`)。libvirt ネットワーク `bridged` として登録し、VM をホストと同じセグメントに接続できる。手順は[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意) |

いずれも `KVM_HOST=headless ./kvm.sh up` のようにコマンドの前に付ける。`kvm.sh` がどこで読むかは [SPEC.md 4.2](SPEC.md#42-環境変数-ホスト側の入力)。

### ブリッジにつなぐときの補足

[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)全体にかかわる方針・状態・注意点。

#### ブリッジの方針

- **ブリッジはホスト側で作り、`kvm.sh` は名前を受け取るだけ**: `kvm.sh` はホストのネットワーク設定を変更しない ([SPEC.md 1.2](SPEC.md#12-スコープ外))
  - コンテナ内の NetworkManager はマスクしてあり (入るとホストの NIC を管理し始める)、ブリッジを作る場所はホストしかない
- **`--network host` の上に `<forward mode="bridge"/>`**: `kvm` コンテナがホストのネットワーク名前空間を共有するので、libvirt はホストのブリッジに VM の tap を直接つなげる
  - `KVM_BRIDGE` のブリッジを libvirt ネットワーク `bridged` として登録し、VM 側は `--network network=bridged` で選ぶ (導入の手順 1 の `VM_NETWORK=bridged`)
  - 定義は `data/etc-libvirt` に永続化され、`KVM_BRIDGE` を付けずに `up` すると削除される ([SPEC.md 4.5](SPEC.md#45-ネットワークとポート))
- **IP はブリッジ側に持たせる**: 物理 NIC をブリッジのポートにし、`ipv4.method auto` でブリッジが DHCP を受ける。VM はホストと同じ LAN の DHCP から IP を受け取る
- **`default` (NAT) はそのまま残る**: `bridged` は追加であり、`default` を置き換えない。ブリッジを作れないホスト (無線 NIC しか無いなど) は `default` を使う

#### ブリッジを作った後の状態

想定 (物理ホストでは本実行していない):

- ホスト: `nmcli connection show` に `<ブリッジ名>` (bridge) と `bridge-slave-<NIC>` (ethernet) があり、NIC の元の接続は inactive
  - `ip -br addr` で LAN の IP はブリッジに付き、NIC は IP を持たない。`/sys/class/net/<ブリッジ名>/bridge` がある
- libvirt (`./kvm.sh virsh net-list --all`): `default` と `bridged` がともに active / autostart。`bridged` の定義は `data/etc-libvirt/qemu/networks/bridged.xml` に永続化される
- `kvm.sh`: `KVM_BRIDGE=<ブリッジ名>` を付けた `up` / `viewer` で `>> libvirt network "bridged" -> host bridge <ブリッジ名> ...` が出る。付けないと `>> KVM_BRIDGE is not set: removing the libvirt network "bridged"` で消える
- VM: `--network network=bridged` で作った VM は LAN の DHCP から IP を取り、ホストの隣接テーブルには VM 自身の MAC が載る (いずれも未検証)

#### 毎回 `KVM_BRIDGE=` を付ける

- `bridged` は `kvm` の起動時に `KVM_BRIDGE` の有無で同期される
  - `KVM_BRIDGE=` を付けずに `kvm` を起動する経路 (`up`、`up kvm`、`viewer`) を 1 度でも通ると `bridged` は削除される
  - [VM 利用の手順 1](#vm-を使う-繰り返し) と[更新](#更新)の手順 2 の `up` もこの経路に当たる
  - `bridged` につないだ VM がそのとき定義されたままだとどうなるか (起動時に `bridged` が見つからず失敗する想定) は未検証
- ブリッジがホストに無い (ブリッジの節の手順 3 の前、再起動でブリッジが上がっていない、名前の打ち間違い) と、`up` は `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/setup.md)` と本書を指して exit 1 する。ホスト側のブリッジを直してから `up` し直す
- シェルの `export KVM_BRIDGE=br0` にすれば毎回付けなくて済むが、本書はそれを検証していない (`kvm.sh` は `KVM_BRIDGE=${KVM_BRIDGE:-}` で環境から読むだけなので動く想定)

#### ホストのネットワーク名前空間の共有

`kvm` / `kvm-gui` はともに `--network host` で、libvirt が作るものはすべてホスト上に現れる。全体は[注意点](#注意点)。ブリッジに関わるのは次の 2 点:

- ホストに `virbr0` が残っていると (ホスト自身の libvirt、またはコンテナの異常終了の残骸) `up` が警告し、`default` の起動が失敗する。残骸なら `sudo ip link del virbr0` で消す
  - `bridged` はこれとは別で、ホストのブリッジを `kvm.sh` が消すことは無い
  - `kvm-net-teardown.service` は active な libvirt ネットワークを `net-destroy` し、`ip link del` のフォールバックは `virbr*` だけに掛ける。`<forward mode="bridge"/>` の `net-destroy` はホストのブリッジに触らない
- コンテナ内の NetworkManager はマスクしてある (入るとホストの NIC やブリッジを管理し始める)。ブリッジの操作は必ずホストの `nmcli` で行う

#### 無線 NIC は L2 ブリッジできない

Wi-Fi の NIC は (4 アドレス形式などの例外を除き) 自分以外の MAC のフレームを送れないので、ブリッジのポートにしても VM は LAN に出られない。

- 物理 AlmaLinux 10 + GNOME での通しの確認 (PR #15) で `KVM_BRIDGE` を試せなかったのはこのため (NIC が無線のみ)
- 有線 NIC のあるホストで行う。無線しか無いホストは `default` (NAT) を使う

### VM を削除するときの注意

- UEFI の VM (`<os firmware='efi'>`) は `--nvram` が無いと `Cannot undefine domain with NVRAM/varstore` で失敗する。BIOS の VM に付けても害は無い
- `--remove-all-storage` は CD-ROM に入ったままの ISO も削除する
  - 複数の VM で共有している ISO を消さないように、`--storage sda` のように消すディスクを指定する
  - または先に `./kvm.sh virsh change-media <VM名> sdb --eject --config` で取り出す (`--cdrom` でインストールした VM は、Windows 以外はインストール後に取り出されているが、後から入れた場合は残る)
- `undefine --nvram --storage sda` で消えるのは定義 (`data/etc-libvirt/qemu/<VM名>.xml`)・UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`)・`sda` のディスクだけで、ISO は残る ([SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))
  - SPEC.md 9.5 節の記録 (`lctest`) は virtio の VM なので、そこでは `vda` を指定している
- ターゲット名は作ったときのバスで決まる。VM 作成の手順 3 の VM はディスクが `sda`・CD-ROM が `sdb`、virtio で作った VM はディスクが `vda`・CD-ROM が `sda`
  - virtio の VM に `--storage sda` を付けると、CD-ROM に入ったままの ISO が消え、qcow2 は残る
  - CD-ROM が空なら `Volume 'sda' was not found in domain's definition.` で止まり、何も消えない
  - そのため、[VM を削除する](#vm-を削除する)の手順 1 で `vda` が出たら、`sda` を `vda` に、`sdb` を `sda` に読み替える (どちらも AlmaLinux 10 のコンテナで確かめた)

### 完了時点の状態

想定される状態 (出力例は本書用の整形で、実測の写しではない):

- `sudo podman ps` に `kvm` (イメージ `localhost/kvm-container/kvm:latest`) と、ディスプレイのあるホストでは `kvm-gui` (`localhost/kvm-container/gui:latest`) が `Up` で並ぶ。ディスプレイの無いホストは `kvm` だけ
- `sudo ls "${REPO}/data"` は `etc-libvirt  home  var-libvirt` (root 所有)。`ls /run/kvm-container/libvirt` に libvirt のソケットが並ぶ
- 両コンテナで `systemctl is-system-running` が `running`
  - `kvm` では `virtqemud` など libvirt のモジュラーデーモンがソケット活性化で待ち受け、`libvirt-guests.service` が有効
  - GUI ユーザー (ホストユーザーの写し) がロックされた状態で存在し、`/run/user/<uid>` と session bus がある
- ホスト上に libvirt の `virbr0` (192.168.122.0/24)、dnsmasq、nftables のルールができる (`--network host`)
- 導入の手順 9 の時点では `./kvm.sh virsh list --all` は空 (VM は[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度)で作る)
- コンテナ実行仕様の表は [SPEC.md 1.1](SPEC.md#11-目的) と [3.3](SPEC.md#33-コンテナ実行仕様-podman-run)、共有物とマウントの表は [4.4](SPEC.md#44-マウント仕様と表示の仕組み)、ファイル一覧は [付録 A](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)

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
- NIC は `domiflist` の `Model` が `e1000e`、ディスクは定義で `bus='sata'`・`rotation_rate='1'` ([VM 作成の手順 5](#vm-を作る-vm-ごとに-1-度))
- 「VM を削除する」まで行うと `<VM名>.qcow2` / `<VM名>.xml` / `<VM名>_VARS.fd` が消え、ISO だけが残る

### 注意点

- **`kvm.sh` は一般ユーザーで実行する**。root で実行すると止まる (コンテナ内のユーザーをホストユーザーに合わせるため)
- **再ログイン後は `up`**: GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えた場合は `./kvm.sh up` を実行する。`kvm-gui` だけが作り直され、VM は動いたまま (`viewer` も同じことをしてから起動する。[再ログインしたとき](#再ログインしたとき-繰り返し))
- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu なので、`down` で VM を止めてからホストを止める ([VM 利用の手順 6](#vm-を使う-繰り返し))
  - `down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない
  - `down` (と `clean`) は動いている VM を先に ACPI でシャットダウンする (`libvirt-guests.service`)。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は電源を切られる
  - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には `virsh autostart` を設定する ([VM 作成の手順 6](#vm-を作る-vm-ごとに-1-度))
- **ACPI に応じない VM**: OS の無い VM や ACPI の電源ボタンを無視する OS は、`virsh shutdown` では止まらず、`down` でも 120 秒待ったあと電源断と同じ状態で止まる。`destroy` で止める
- **`data/` は root 所有**: ホストから読み書きするには `sudo` がいる。SELinux Enforcing でも `:Z` は不要。`data/` を消すのは `clean` だけ (`down` では残る)
- **ホストのネットワーク名前空間を共有する** (`--network host`、両コンテナ):
  - ホスト自身で libvirt を動かしていると `virbr0` / 192.168.122.0/24 が衝突する。`up` 時にホストに `virbr0` があると警告する (警告だけで `up` は止まらない。コンテナの異常終了で残った場合は `down` してから `sudo ip link del virbr0` で削除し、`up` し直す)
  - `kvm-gui` も `--network host` (virt-viewer が VM の VNC に届くため)。listen するものは無いので、ホストと衝突するポートやソケットは無い。`kvm` 側も VM の VNC (loopback) 以外にホストで listen するものは無い
  - libvirt の `default` ネットワークの `virbr0`・dnsmasq・nftables ルールはホスト上に作られ、`net.ipv4.ip_forward=1` もホストに効く
  - コンテナ内の `iscsid.socket` / `iscsiuio.socket` (abstract unix ソケットがホストの `iscsid` と衝突して degraded になる) と NetworkManager (入るとホストの NIC を管理し始める) はマスクしている ([SPEC.md 4.5](SPEC.md#45-ネットワークとポート) / [6 章](SPEC.md#6-設計上の不変条件))
- **壊しやすい不変条件** (いずれも実際の不具合を踏んだ結果。理由を理解せずに変えない。[SPEC.md 6 章](SPEC.md#6-設計上の不変条件)):
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
- **VM を作るのは x86_64 のホスト**: VM 作成の手順 3 の SATA (AHCI) と e1000e は、aarch64 の qemu-kvm に無い ([VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の補足)
- **SPICE は無い**: グラフィックスは VNC。`--graphics spice` は使えない
- **`--network` を省いた場合**: ホストの既定経路がブリッジ上にあると `default` (NAT) にならない。本書の VM 作成の手順 3 は `VM_NETWORK` で明示しているので、この挙動に当たるのは `--network` を省いて自分で `virt-install` したときだけ
- **ゲストの画面はホストのデスクトップにしか出ない**: SSH だけのホストでは `virsh console` かネットワーク経由 (未検証)

### 参照

- [SPEC.md](SPEC.md) — [1.1 目的](SPEC.md#11-目的) / [1.2 スコープ外](SPEC.md#12-スコープ外) / [2.1 ディスプレイの判定](SPEC.md#21-ディスプレイの判定-have_display) / [2.2 ホスト要件](SPEC.md#22-ホスト要件) / [2.3 実行ユーザーの要件](SPEC.md#23-実行ユーザーの要件) / [2.4 起動前に確認されるホスト資源](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [3.2 3 層構造とファイル](SPEC.md#32-3-層構造とファイル) / [3.3 コンテナ実行仕様](SPEC.md#33-コンテナ実行仕様-podman-run) / [3.5 コンテナ間の libvirt 接続](SPEC.md#35-コンテナ間の-libvirt-接続) / [4.1 CLI](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) / [4.2 環境変数](SPEC.md#42-環境変数-ホスト側の入力) / [4.4 マウント仕様と表示の仕組み](SPEC.md#44-マウント仕様と表示の仕組み) / [4.5 ネットワークとポート](SPEC.md#45-ネットワークとポート) / [4.6 永続化データ](SPEC.md#46-永続化データ-data-と共有-run-dir) / [5.1 起動シーケンス](SPEC.md#51-起動シーケンス-kvmsh-up) / [5.2 停止シーケンス](SPEC.md#52-停止シーケンス-kvmsh-down) / [5.3 GUI 起動シーケンス](SPEC.md#53-gui-起動シーケンス-containerguiguikvm-gui-内) / [5.6 ブリッジ同期](SPEC.md#56-ブリッジ同期-sync_bridged_network) / [6 設計上の不変条件](SPEC.md#6-設計上の不変条件) / [7 セキュリティ考慮事項](SPEC.md#7-セキュリティ考慮事項) / [8 既知の制限事項](SPEC.md#8-既知の制限事項) / [9 検証手順](SPEC.md#9-検証手順) (9.1 静的検査、9.2 物理 GNOME、9.3 ディスプレイ無し、9.4 その他の確認点、9.5 VM のライフサイクル) / [付録 A ファイル一覧](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)
- [CLAUDE.md](../CLAUDE.md) — 変更時の注意点 (壊しやすい不変条件の理由、静的検査の対象ファイル)
- `./kvm.sh` (引数なし) — サブコマンドと環境変数の一覧 (`kvm.sh` 冒頭のヘッダコメント)
- `man virt-install` (`--cdrom` / `--location` / `--osinfo` / `--machine` / `--disk` / `--network`)、`man virsh` (`shutdown` / `destroy` / `autostart` / `undefine` / `change-media` / `domblklist` / `dumpxml` / `net-list` / `net-dumpxml` / `net-undefine` / `domiflist`)
- [libvirt: Domain XML format](https://libvirt.org/formatdomain.html) — ディスクの `<target>` の `bus` / `rotation_rate`、NIC の `<model>`
- `man nmcli` / `man nm-settings-nmcli` (`bridge`、`bridge-slave`、`ipv4.method`)

---

### 付録: 物理 AlmaLinux 10 + GNOME での確認手順

変更後の回帰確認。**先に [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) で VM を 1 つ作り、導入の手順 1 の `VM_NAME` を設定したシェルで貼る。** 期待結果と検証している項目の表は [SPEC.md 9.2](SPEC.md#92-物理-almalinux-10--gnome)。記録は PR #15 `ae650c0` (1 コンテナ構成) と PR #26 `ba2fee2` (現行)。以下のブロックは README にあった確認手順を記録どおりに分けたもので、`cd "${REPO:?…}"` の行と `viewer` の変数形は本実行していない。

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

VM が無ければ、ここで [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の `./kvm.sh virt-install ...` で VM を作る。次のブロックは GNOME デスクトップにウィンドウが出ること、VM のコンソールが見えることを確かめる (ウィンドウを閉じてから次へ)。

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

グラフィカルセッションの外のシェル (SSH など) から流す。期待結果は [SPEC.md 9.3](SPEC.md#93-ディスプレイ無し-headless)。
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

OS の入った使い捨ての VM `lctest` で、作成から削除までを確認する (手順の詳細と期待結果は [SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))。変更後の回帰確認に手で流す。PR #26 で物理 AlmaLinux 10.2 + GNOME (SELinux Enforcing) で通した記録なので、VM 名 `lctest` と boot ISO `AlmaLinux-10.2-x86_64-boot.iso` は変数にせずそのまま書いてある。
キックスタートは `data/` 以外の場所で書き、`OEMDRV` ラベルの ISO にして渡す (`virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない)。
`ks.cfg` には `poweroff` と、`%packages` に `qemu-guest-agent` を入れておく。

- boot ISO は先に [VM 作成の手順 1](#vm-を作る-vm-ごとに-1-度) で `data/var-libvirt/images/` に置く (導入の手順 1 の `ISO` にその boot ISO のパスを入れる)
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

[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)は通しで実行した記録が無い (状態は[対象と検証環境](#対象と検証環境))。NetworkManager は物理ホストの AlmaLinux 10 の既定 (`nmcli`) で、版は記録していない。

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
- 既存 VM の `bridged` → `default` の付け替え手順
