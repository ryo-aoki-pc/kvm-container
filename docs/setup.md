# qemu-kvm コンテナ 導入手順 (AlmaLinux 10 / podman、物理 GNOME / ディスプレイ無し)

## 実施手順

> [!IMPORTANT]
> - **すべて対象ホストの一般ユーザーのシェルで実行する**。root や `sudo -i` のシェルでは、`kvm.sh` が `!! run kvm.sh as a regular user, not root` で止まる
> - **画面を使うなら、GNOME にログインした端末から実行する**。SSH のシェルからでは `kvm-gui` が起動しない
> - **手順 2 と、手順 5 の最初のブロックでは sudo のパスワードを聞かれる** (手順 2 は `[y/N]` も)。そのブロックだけ続けて貼らない
> - **`./kvm.sh` は内部で `sudo podman` を呼ぶ**。sudo のタイムスタンプが切れていれば、ほかのブロックでも聞かれる。新しい端末や長い待ちの後は、先に `sudo -v` を単独で貼っておく ([注意点](#注意点))

- 手順 1 で変数を設定したシェルで、上から順にコードブロックを貼る。画面の有無による違いはブロックの中で判定するので、どちらのホストでも同じブロックを貼る
- 各手順の末尾の「補足」(折り畳み) と後半の[補足](#補足)は、実行するだけなら読まなくてよい。折り畳みの中のブロックも貼らなくてよい
- 実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [SPEC.md](SPEC.md)
- 手順の後: [VM の作成と操作](vm.md)、[アクティビティから起動する](desktop.md)、[ブリッジ](bridge.md) の各手順書が使える
- 日常の操作は[使い方の基本](#使い方の基本)、再ログイン後は[表示先が変わったとき](#表示先が変わったとき-再ログイン後)、旧版からは[更新](#更新)、戻すときは[ロールバック](#ロールバック)

1. **変数を設定する**

   - **編集するものは無い**。clone 先を `~/kvm-container` 以外にするときだけ `REPO` を変える
   - **新しいシェルを開いたら** (SSH を張り直したあとも)、先にこのブロックを貼り直す。clone 済みなら、最後の行でリポジトリ直下に移る

   ```bash
   REPO=~/kvm-container                                        # clone 先。ユーザーのホームディレクトリ配下にする。<REPO>
   REPO_URL=https://github.com/ryo-aoki-pc/kvm-container.git   # このリポジトリ。固定。<REPO_URL>
   printf '%-8s = %s\n' REPO "${REPO}" REPO_URL "${REPO_URL}"
   [ ! -d "${REPO}" ] || cd "${REPO}"
   ```

   <details>
   <summary>補足: 変数について</summary>

   `REPO` は clone 先を指すだけで、`kvm.sh` に渡す変数ではない。`kvm.sh` は自分のあるディレクトリに `cd` してから動き、`data/` もそこ (`KVM_DATA_DIR=$PWD/data`) に作る。VM のディスクや定義はその `data/` に置かれる。

   - ホームディレクトリ配下 (`user_home_t`) に置く前提で、seed コンテナと両コンテナはラベル分離なし (`--security-opt label=disable` / `--privileged`) で動かし、`data/` を relabel しない。他の場所に置いた場合は検証していない
   - `install-desktop` はランチャーに `kvm.sh` の絶対パスを書くので、リポジトリを移動したら再実行する ([desktop.md](desktop.md))
   - `REPO_URL` は公開リポジトリの HTTPS の URL で、clone に認証は要らない。手順 3 で使う
   - 最後の行は、clone 前 (ディレクトリが無い) には何もしない。新しいシェルで貼り直したときに、以降の `./kvm.sh` が相対パスで動くようにするため

   </details>

1. **podman と git を入れる**

   ホストに入れるのは podman と git だけ (podman は root で使う)。qemu・libvirt・virt-viewer はホストに入れない。

   ```bash
   sudo dnf install podman git
   ```

   sudo のパスワードと `[y/N]` の確認がある。**次のブロックはインストールが終わってから貼る。**

   ```bash
   rpm -q podman git
   ```

   - 2 行とも `podman-…` / `git-…` の版が出ればよい

   <details>
   <summary>補足: podman と git</summary>

   `kvm.sh` は `sudo podman` 固定で、rootless podman は使わない。git は手順 3 の clone と[更新](#更新)の `git pull` にだけ使う。

   - ホストの libvirt とは無関係なので、ホストに qemu・libvirt を入れてはいけないわけではない。ただし入れて動かしていると `virbr0` が衝突する ([注意点](#注意点))
   - ホスト要件は [SPEC.md 2.2](SPEC.md#22-ホスト要件)、実行ユーザーの要件は [2.3](SPEC.md#23-実行ユーザーの要件)

   </details>

1. **リポジトリを clone する**

   ```bash
   [ -e "${REPO:?手順 1 の REPO が空のまま。手順 1 を貼り直す}/kvm.sh" ] || git clone "${REPO_URL:?手順 1 の REPO_URL が空のまま。手順 1 を貼り直す}" "${REPO}"
   cd "${REPO}" && ls -l kvm.sh
   ```

   - `kvm.sh` の行 (実行権限付き) が出ればよい
   - すでに clone してあれば、`git clone` は飛ばされる
   - 以降のブロックは、このディレクトリ (リポジトリ直下) で貼る

   <details>
   <summary>補足: clone</summary>

   - `data/` は git 管理外 (`.gitignore`) で、手順 6 の `up` が初めて作る。clone した直後には無い
   - `REPO` にファイルの入った別のディレクトリがあると、`git clone` は `already exists and is not an empty directory` で止まる。`REPO` を変えて手順 1 から貼り直す

   </details>

1. **ホストを確認する**

   ```bash
   getenforce
   env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'
   if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then echo '画面あり: kvm と kvm-gui を使う'; else echo '画面なし: kvm だけを使う'; fi
   ```

   - `getenforce` は `Enforcing` のままでよい
   - GNOME の端末なら `WAYLAND_DISPLAY` / `DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` の行が並び、`画面あり` と出る
   - ディスプレイの無いホスト (SSH のみ) では `画面なし` と出る。これで正常で、以降のブロックは `kvm` だけを扱う
   - **注意**: GNOME のホストで `画面なし` と出たら、SSH か `sudo -i` のシェルで貼っている。GNOME の端末を開き、手順 1 から貼り直す
   - ファームウェアで SVM (AMD) / VT-x (Intel) を有効にしておく

   <details>
   <summary>補足: ホストの確認</summary>

   - **ホスト種別の判定は無い**: 画面の有無だけを見る。`KVM_HOST` が `headless` でなく、`DISPLAY` か `WAYLAND_DISPLAY` が設定されていれば `kvm-gui` を起動する (`have_display`。[SPEC.md 2.1](SPEC.md#21-ディスプレイの判定-have_display))。最後の行はこれと同じ条件で、`KVM_HOST` だけは見ない
   - **物理 GNOME**: `kvm.sh up` は実行ユーザーのセッション環境 (`DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY`) を `kvm-gui` に持ち込む。SSH 越しや `sudo -i` のシェルでは `WAYLAND_DISPLAY` などが無く、`kvm-gui` は起動されない (`>> no display found`)
   - **SELinux**: Enforcing のままでよい (`kvm` は `--privileged`、`kvm-gui` は `label=disable` でラベル分離が無効)
   - **ディスプレイ無し**: `up` は `kvm` だけを起動し、GUI イメージはビルドしない。`up gui` と `viewer` は `!! no display found …` で終了する (それぞれ exit 1 / exit 2)。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` で行い、ゲストにはシリアルコンソールやネットワーク経由でアクセスする ([VM の作成と操作](vm.md) の手順 4)
   - **画面のあるホストで画面を使わない**: `KVM_HOST=headless` を `up` の前に付ける ([環境変数](#環境変数))。そのときは手順 5 の 2 つ目のブロックを貼らない
   - **SSH のシェルの `XDG_RUNTIME_DIR`**: SSH でログインしても設定されるので、`env | grep` に出ることがある。画面の有無は `DISPLAY` / `WAYLAND_DISPLAY` で決まる
   - **起動前に確認されるホスト資源** (`check_host_network`): `KVM_BRIDGE` がブリッジでなければ停止、ホストに `virbr0` があれば警告 ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

   </details>

1. **イメージをビルドする**

   `kvm` のイメージを作る。最初の `sudo podman` なので、sudo のパスワードを聞かれることがある。

   ```bash
   cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh build kvm
   ```

   - 時間がかかる (AlmaLinux 10 minimal のイメージ取得と `microdnf` でのパッケージ導入)
   - **次のブロックはビルドが終わってから貼る**

   画面のあるホストでは GUI のイメージも作る。画面の無いホストでは何もしない。

   ```bash
   [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || ./kvm.sh build gui
   ```

   - ビルドの最後に `Successfully tagged localhost/kvm-container/kvm:latest` (`gui` のときは `…/gui:latest`) が出ればよい

   <details>
   <summary>補足: ビルド</summary>

   `Containerfile` は AlmaLinux 10 minimal ベース (`microdnf`) のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、両コンテナ共通の unit マスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui`。

   - `./kvm.sh build [kvm|gui]` は `podman build --target <role> -t localhost/kvm-container/<role>:latest` で、余分な引数は `podman build` に渡る。引数なしの `./kvm.sh build` は両方を作る
   - 2 つのブロックに分けたのは、画面の無いホストで GUI イメージを作らないため。判定は手順 4 の最後の行と同じ
   - どちらのイメージも systemd (`/sbin/init`) で常駐する。イメージ名は固定 ([SPEC.md 3.4](SPEC.md#34-イメージ仕様-containerfile))
   - `up` は足りないイメージを自動でビルドするので、この手順を飛ばしてもよい。分けてあるのは、ビルドの失敗と起動の失敗を切り分けるため
   - ビルドが失敗したら `./kvm.sh build kvm 2>&1 | tee build.log` のように出力を残す (`build.log` は `.gitignore` 済み)

   </details>

1. **起動する**

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
   - **次のブロックは `>> ready.` が出てから貼る**

   <details>
   <summary>補足: 起動する</summary>

   `./kvm.sh up` の流れ ([SPEC.md 5.1](SPEC.md#51-起動シーケンス-kvmsh-up)): `/dev/kvm` の確認 (無ければ `modprobe`、0666 に) → root でないことの確認とホストユーザーの名前・uid/gid の取得 → イメージが無ければビルド → `data/` の初期化 → `check_host_network` → `/run/kvm-container/libvirt` を空にする → `kvm` を `podman run` → `>> waiting for libvirt...` (最大 30 秒) → `bridged` ネットワークの同期 → `>> ready.` → ディスプレイがあれば `kvm-gui` を起動。`kvm` が動いていれば `>> kvm is already running` で素通りする。

   **`kvm-gui` に渡すもの**

   `kvm.sh up` は実行ユーザーのセッション環境をそのまま `kvm-gui` に持ち込む (`kvm` には渡さない)。詳細は [SPEC.md 4.4](SPEC.md#44-マウント仕様と表示の仕組み) と [6 章](SPEC.md#6-設計上の不変条件)。

   - `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`) をコンテナの **`/run/host-xdg-runtime` に読み取り専用**でマウントし、Wayland ソケット・GNOME の Xwayland 認証ファイル・PipeWire/Pulse のソケットは、その中を指す**絶対パス**で **`WAYLAND_DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`** に渡す (unix ソケットへの接続は読み取り専用でも可)。シンボリックリンクの先が runtime dir の外にある場合は、そのソケットファイルだけを同じパスに読み取り専用でマウントする
   - **ホストの runtime dir をコンテナの `/run/user/<uid>` に同じパスでマウントしてはいけない。** コンテナの logind がそのディレクトリを自分のものとして管理し、ユーザーのセッションや `systemd --user` の開始時にホストの session bus や `systemd --user` のソケットを作り直し、`user-runtime-dir@.service` の停止処理で中身をすべて削除してしまう (ホストの Wayland ソケットや session bus が消える。cockpit を載せていた頃に、そのログイン / ログアウトで実際に起きた不具合。PR #10)
   - **コンテナ内の `/run/user/<uid>` は、コンテナの logind が GUI ユーザー用に作るディレクトリ** (`kvm` では tmpfs、非特権の `kvm-gui` では tmpfs をマウントできないので `/run` 直下のディレクトリ)。`gui-user-setup` がこのユーザーを linger にしているので起動時から存在する (session bus 付き)。GUI アプリはこれを使う
   - **`/tmp/.X11-unix` は読み取り専用でマウント** (X11 フォールバック用)。読み取り専用にするのは、コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐため (同じ理由で **`tmpfiles.d/x11.conf` をマスク**)
   - **どちらのコンテナでも GUI ユーザーはホストユーザーの写し**: 起動時に `gui-user.service` が `kvm.sh up` を実行したホストユーザーの名前・uid/gid で作る (イメージには一般ユーザーを焼き込んでいない)。ホストの runtime dir は 0700 なので、その中のソケットに届くには uid の一致が必要。**パスワードは設定しない** (コンテナにログインするものは無く、ユーザーはロックされたまま。ホストのパスワードやハッシュはコンテナに渡さない)。値は `podman run -e` で渡し、コンテナ内では PID 1 の environ から読む
   - **`/dev/dri` が無いホストではソフトウェア描画** (`LIBGL_ALWAYS_SOFTWARE=1`)。`/dev/dri` があれば `--device` で `kvm-gui` に渡し、`gui` が `renderD*` を 0666 にする。`KVM_SOFTWARE_GL=1` で強制できる
   - 渡した引数のハッシュをラベル `kvm.gui-session` に記録し、次の `up` でラベルと、コンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめる (再ログインで `/run/user/<uid>` が作り直されても、`kvm-gui` には古い runtime dir がマウントに残って中身だけ消えるため)。違えば `kvm-gui` だけ作り直す ([表示先が変わったとき](#表示先が変わったとき-再ログイン後))

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

1. **動作確認する**

   ```bash
   sudo podman exec kvm systemctl is-system-running         # running (degraded ではない)
   sudo podman exec kvm ls -l /run/libvirt/virtqemud-sock   # srw-rw---- root libvirt
   ./kvm.sh virsh list --all                                # 空の一覧 (ヘッダだけ) で可
   ```

   画面のあるホストでは `kvm-gui` も確かめる。画面の無いホストでは `skip` と出るだけ。

   ```bash
   if sudo podman container exists kvm-gui; then
     sudo podman exec kvm-gui systemctl is-system-running                          # running
     sudo podman exec kvm-gui runuser -u "$USER" -- virsh -c qemu:///system list   # 一般ユーザーが kvm-gui から kvm の libvirt に接続できること
   else
     echo 'kvm-gui が無い (画面なし): skip'
   fi
   ```

   - `degraded` なら `./kvm.sh shell` (`kvm-gui` は `./kvm.sh shell gui`) で `systemctl --failed` を見る
   - ログは `./kvm.sh logs` (`kvm-gui` は `./kvm.sh logs gui`)

   <details>
   <summary>補足: 動作確認</summary>

   - `systemctl is-system-running` が両コンテナで `running` (`degraded` ではない) ことは、Containerfile の unit マスク群 (`iscsid.socket` / `NetworkManager-wait-online.service` など) が効いているかの実質的な回帰テスト
   - `/run/libvirt/virtqemud-sock` が `srw-rw---- root libvirt` なのは `virtd-socket.conf` の drop-in が効いている証拠。`kvm-gui` から一般ユーザーで `virsh` が通ることが、コンテナをまたぐ libvirt 接続の回帰テスト ([選択した方針](#選択した方針))
   - `./kvm.sh logs` は `kvm` の `kvm-libvirt-conf` / `virtqemud` / `gui-user` の journal、`./kvm.sh logs gui` は `kvm-gui` の `/var/log/gui.log` と `gui-user` の journal を出す
   - 変更後の回帰確認は付録の確認手順 ([物理 GNOME](#付録-物理-almalinux-10--gnome-での確認手順) / [ディスプレイ無し](#付録-ディスプレイの無いホストでの確認手順)) を手で流す。期待結果は [SPEC.md 9 章](SPEC.md#9-検証手順)

   </details>

---

## 使い方の基本

| サブコマンド | 用途 | 使う手順書 |
|---|---|---|
| `./kvm.sh build [kvm\|gui]` | 2 つのイメージをビルド (`localhost/kvm-container/kvm`、`localhost/kvm-container/gui`)。`build kvm` / `build gui` で片方だけ | 本書 [手順 5](#実施手順) |
| `./kvm.sh up [kvm\|gui]` | `kvm` を起動し、ディスプレイがあれば `kvm-gui` も起動 (kvm モジュールのロードと `/dev/kvm` の権限調整も行う)。`up gui` は `kvm-gui` だけ (再ログイン後など。`up` は `kvm-gui` が別のセッション用なら作り直す) | 本書 [手順 6](#実施手順) / [表示先が変わったとき](#表示先が変わったとき-再ログイン後) |
| `KVM_BRIDGE=br0 ./kvm.sh up` | VM をホストのブリッジ `br0` に接続できるようにして起動 | [bridge.md](bridge.md) |
| `./kvm.sh virt-install ...` | VM を作る (`kvm` コンテナ内の virt-install) | [vm.md](vm.md) |
| `./kvm.sh virsh ...` | virsh (`kvm` コンテナ)。`list` / `start` / `shutdown` / `destroy` / `undefine` など | [vm.md](vm.md) |
| `./kvm.sh viewer [VM名]` | VM の画面を virt-viewer で表示 (VM 名を省くと一覧から選ぶダイアログ) | [vm.md](vm.md) |
| `./kvm.sh shell [kvm\|gui]` | コンテナ内 root シェル (既定 `kvm`) | 本書 [手順 7](#実施手順) |
| `./kvm.sh logs [kvm\|gui]` | libvirt の journal と GUI アプリのログ | 本書 [手順 7](#実施手順) |
| `./kvm.sh down [kvm\|gui]` | コンテナ停止・削除 (VM のディスク / 定義はホストの `data/` に残る)。引数なしで両方 | 本書 [ロールバック](#ロールバック) |
| `./kvm.sh clean` | コンテナと `data/` のデータをすべて削除 (確認あり) | 本書 [ロールバック](#ロールバック) |
| `./kvm.sh install-desktop` | アクティビティ (アプリ一覧) から Virt Viewer を起動できるようにする | [desktop.md](desktop.md) |
| `./kvm.sh uninstall-desktop` | 上記の解除 | [desktop.md](desktop.md) |

- `up` は足りないイメージを自動でビルドする。`viewer` は先に `up` を実行するので、コンテナが止まっていても、再ログインで表示先が変わっていても、そのまま使える
- `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `KVM_SOFTWARE_GL` / `TZ` / `KVM_CLEAN_YES`) は、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける。一覧は補足の[環境変数](#環境変数)
- `./kvm.sh` を引数なしで実行すると、`kvm.sh` 冒頭のヘッダコメント (サブコマンドと環境変数の一覧) が出る

## 表示先が変わったとき (再ログイン後)

GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えたりした場合は `up` を実行する。

- `kvm-gui` だけが作り直され、`kvm` と VM は動いたまま
- `viewer` も同じことをしてから起動するので、`viewer` を使うだけならこの節は飛ばしてよい
- 仕組み: 再ログインで `/run/user/<uid>` は作り直されるが、`kvm-gui` は古い runtime dir をマウントしたまま中身だけ消える。`up` は渡した引数 (ラベル `kvm.gui-session`) とコンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめて作り直す

GNOME の端末を開き、[手順 1](#実施手順) のブロックを貼ってから貼る。新しい端末なので、sudo のパスワードを聞かれる。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh up gui
```

- `>> the host session has changed: recreating kvm-gui (the kvm container and its VMs keep running)` が出る
- 何も変わっていなければ `>> kvm-gui is already running`
- 引数なしの `./kvm.sh up` でも同じ (`kvm` は `>> kvm is already running` で素通りする)
- **次のブロックは `up` が終わってから貼る**

```bash
./kvm.sh virsh list   # VM が動いたまま
```

## 更新

> [!WARNING]
> **`down` が VM をシャットダウンしない版 (PR #26 より前) から更新するときは、先に VM を止めておく。** 止めないと、下の `down` で VM が電源断と同じ状態で止まる。
>
> - `./kvm.sh virsh list` で動いている VM を確かめ、[vm.md 手順 6](vm.md#実施手順) の `./kvm.sh virsh shutdown` で止める

旧版から更新するときは、ほかに次のことが起きる。どれも `data/` はそのまま使える。

- **cockpit / firefox を使っていた版から**: `COCKPIT_BIND` / `COCKPIT_PORT` は使われなくなり、ホストの 9091 番で listen するものは無くなる。Firefox のランチャーを入れていた場合は、更新の後に `./kvm.sh install-desktop` (または `uninstall-desktop`) が古い `kvm-firefox.desktop` を消す ([desktop.md](desktop.md))
- **1 コンテナ構成の頃から**: 下の `down` で古い `kvm` コンテナも消える。古いコンテナは `/run/libvirt` を共有していないので、動いたままだと `kvm-gui` から libvirt に届かない。libvirt の設定は `kvm-libvirt-conf.service` が更新する

リポジトリを最新にする。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。手順 1 を貼り直す}" && git pull --ff-only
```

コンテナを止める。動いている VM は ACPI でシャットダウンされる (最大 120 秒)。

```bash
./kvm.sh down
```

**次のブロックは `down` が終わってから貼る。** イメージを作り直して起動する (画面の無いホストでは `gui` を作らない)。

```bash
./kvm.sh build kvm && { [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || ./kvm.sh build gui; } && ./kvm.sh up
```

- `>> ready.` が出れば終わり。確認は[手順 7](#実施手順)
- 1 コンテナ構成の頃のイメージは、次のブロックで消せる (任意)

```bash
sudo podman rmi localhost/qemu-kvm-cockpit
```

- この節のブロックは、この形では本実行していない (以前は `git pull` → `./kvm.sh down` → `./kvm.sh build` → `./kvm.sh up` と書いていたが、その流れも本実行していない)

## ロールバック

コンテナを止めて消す。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh down
```

- 動いている VM は先に ACPI でシャットダウンされる (`>> shutting down the running VMs (up to 120 s)...`。120 秒で電源断)
- `data/` (VM のディスク・定義) は残り、`/run/kvm-container` は消える
- VM を止めるだけならここまで

> [!CAUTION]
> **次のブロックで `data/` ごと、VM のディスク・定義が消え、取り戻せない。**

```bash
./kvm.sh clean
```

- `This deletes the VM disks and definitions as well. Continue? [y/N]` に `y` と答える (`KVM_CLEAN_YES=1 ./kvm.sh clean` で省略できる)
- `clean` は内部で `down` を呼ぶので、上の `down` を飛ばしてもよい
- **次のブロックは、答えてから貼る**

イメージも消す (本実行していない)。画面の無いホストには `gui` のイメージが無いが、`--ignore` で無視される。

```bash
sudo podman rmi --ignore localhost/kvm-container/kvm:latest localhost/kvm-container/gui:latest
```

- ホストに入れた podman と git はそのまま残す
- clone したリポジトリも要らなければ、`clean` の後に `cd ~ && rm -rf "${REPO}"` で消す (本実行していない)

---

## 補足

### 対象と検証環境

- **目的**: qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナに収め、qemu も libvirt も入れていない軽量なホストで VM を動かし、その画面をホストのデスクトップに表示する
  - VM の作成・操作はコマンドライン (`virt-install` / `virsh`)、画面の表示は virt-viewer (ブラウザや Web コンソールは使わない)
  - `kvm-gui` は `kvm` の libvirt に共有 unix ソケット経由で接続する。デスクトップの再ログイン後は `kvm-gui` だけを作り直せるので、VM を止めずに済む
  - ディスプレイの無いホストでは `kvm` だけを使う (GUI イメージのビルドも不要)
- **進め方**: ホストに入れるのは podman と git だけ。clone した `kvm.sh` が `sudo podman` でビルド・起動・停止をすべて行う。読者が書き換える値は無い (clone 先を変えるときだけ手順 1 の `REPO`)
- **状態**:
  - 物理 AlmaLinux 10.2 + GNOME (Wayland、SELinux Enforcing、AMD x86_64) で通しの動作確認済み
    - PR #15 `ae650c0`: `up`、`running`、AVC 0、`/dev/dri` 0666、Wayland 直結、`down` → `up`、`clean`
    - PR #26 `ba2fee2`: `kvm` 再ビルド、両コンテナ `running`、VM のライフサイクル一式
    - `0cab212` (現行版): 手順 5 の 2 ブロック → 手順 6 → 手順 7 の 2 ブロック →「表示先が変わったとき」の `up gui` → 付録の確認行 (`auth_unix_rw` / `getent shadow` / `/dev/dri` / `ausearch`) → `KVM_HOST=headless` での `up gui` / `viewer` の拒否 (exit 1 / 2) → `down` (`virbr0` と `/run/kvm-container` が残らない) → `clean`。clone 先は `~/kvm-container` 以外 (git の worktree)、`viewer` と VM は未実施
  - **ディスプレイの無いホストは PR #28 で通した**
    - AlmaLinux 10.2 / Raspberry Pi 5 / aarch64、SELinux Enforcing、グラフィカルセッション外のシェル
    - `build` → `KVM_HOST=headless` での `up` → 下の付録の確認一式 → `down` → `clean`
    - **ただしそのホストでは VM を作っていない** (`virt-install` / `virsh console` は未実施)
  - README の例を変数形に書き換えたもので、その形では再実行していない行:
    - 手順 5 の `cd "${REPO:?…}" && ./kvm.sh build kvm`、「表示先が変わったとき」の `cd "${REPO:?…}" && ./kvm.sh up gui`、付録の `./kvm.sh viewer "${VM_NAME:?…}"`
  - 新しく足した行で、本実行していないもの:
    - 手順 1 の `REPO_URL`、手順 2 の `sudo dnf install` (`rpm -q podman git` は実行した)、手順 3 の `git clone` (既に clone 済みのホストなので判定で飛ばした)
    - 「更新」の各ブロック、ロールバックの `rmi --ignore` とリポジトリの削除

| 項目 | 物理 AlmaLinux 10 + GNOME | ディスプレイ無し |
|---|---|---|
| ホスト | AlmaLinux 10.2 + GNOME (Wayland)、SELinux Enforcing、AMD x86_64 | AlmaLinux 10.2 (Raspberry Pi 5、aarch64)、SELinux Enforcing、podman 5.8.2、グラフィカルセッション外のシェル (`DISPLAY` / `WAYLAND_DISPLAY` 未設定) |
| 確認した版 | PR #15 (1 コンテナ構成、cockpit の頃)、PR #26 (現行の 2 コンテナ構成)、`0cab212` (手順 5〜7 と `down` / `clean`) | PR #28 (現行の 2 コンテナ構成) |
| 画面表示 | GNOME (Wayland) デスクトップ | 無し (`>> no display found: GUI disabled ...`) |
| VM の作成・操作 | ライフサイクル一式 (PR #26。[vm.md](vm.md)) | 未実施 (`virsh list` が通るところまで) |
| `KVM_BRIDGE` | 未検証 (NIC が無線のみ) | 未検証 |

対応ホスト:

| ホスト | 画面表示 |
| --- | --- |
| 物理マシン / VM の AlmaLinux 10 + GNOME | GNOME (Wayland) デスクトップに表示 |
| ディスプレイの無いホスト (SSH のみ) | 画面表示なし。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[手順 1](#実施手順) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 意味 | 例 |
> |---|---|---|
> | `${REPO}` | このリポジトリを clone する場所。`data/` はこの中にできる。ユーザーのホームディレクトリ配下にする | `~/kvm-container` |
> | `${REPO_URL}` | このリポジトリの clone 元。公開リポジトリなので認証は要らない。固定 | `https://github.com/ryo-aoki-pc/kvm-container.git` |
>
> - `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `KVM_SOFTWARE_GL` / `TZ` / `KVM_CLEAN_YES`) は手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける ([環境変数](#環境変数))
> - 出力例・表の中の値は `<VM名>` / `<uid>` / `<ホストユーザー名>` のプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない
> - パスワード・鍵・トークンは扱わない。コンテナにはホストのパスワードもハッシュも渡していない (GUI ユーザーはロックされたまま)

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

### 実施前の状態

| 項目 | 状態 |
|---|---|
| ホスト OS | AlmaLinux 10 (物理 / VM)。qemu・libvirt・virt-viewer は未導入のままでよい |
| podman / git | 未導入、または導入済み (podman は root で使う) |
| 仮想化支援 | KVM が使える CPU (SVM / VT-x が有効。VM の中で動かすならネストした仮想化) |
| 画面 | GNOME (Wayland) のセッション。無ければ `kvm` だけを使う |
| `/dev/kvm` | 無くてよい。`up` が `kvm_amd` / `kvm_intel` をロードして 0666 にする |
| ホスト上の libvirt | 動いていないこと (`virbr0` / 192.168.122.0/24 が衝突する) |
| リポジトリ | まだ clone していなくてよい (手順 3 で clone する)。clone 済みならユーザーのホームディレクトリ配下にあること。`data/` はまだ無い |

### 選択した方針

| コンテナ | 中身 | 権限 |
| --- | --- | --- |
| `kvm` | libvirt + qemu-kvm + virt-install (サーバ側。VM が動いている間は常駐) | `--privileged --network host` |
| `kvm-gui` | virt-viewer (デスクトップ側。ディスプレイのあるホストだけ) | 非特権 (`--network host`, SELinux ラベル分離なし) |

- **コマンドライン + virt-viewer**: VM の作成・操作は `kvm` コンテナ内の `virt-install` / `virsh` をパススルーし、画面は `kvm-gui` の virt-viewer で出す
  - ブラウザや Web コンソール (cockpit) は廃止した (PR #25)
  - RHEL 10 系の qemu-kvm には SPICE が無いので、グラフィックスは VNC ([vm.md](vm.md#選択した方針))
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
- **`data/` はバインドマウント**: リポジトリ内の `data/` (git 管理外) 配下のディレクトリをコンテナにバインドマウントする
  - バインドマウントは named volume と違い、初回にイメージ側の内容をコピーしない
  - そのため空のときだけ、`kvm.sh up` が `kvm` イメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動する ([手順 6 の補足](#実施手順))
- **分岐はブロックの中で判定する**: 画面の有無で変わるのは、GUI イメージのビルド (手順 5) と `kvm-gui` の確認 (手順 7) だけ。どちらもブロックの中で判定し、どちらのホストでも同じブロックを上から貼れるようにした

### 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `headless` にすると、表示用環境変数があっても `kvm-gui` を起動しない (他の値は `auto` と同じ) |
| `KVM_SOFTWARE_GL` | 未設定 | `1` でソフトウェア描画を強制 |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_CLEAN_YES` | 未設定 | `1` で `clean` の確認を省略 |
| `KVM_BRIDGE` | 未設定 | ホストの既存ブリッジ名 (例 `br0`)。libvirt ネットワーク `bridged` として登録し、VM をホストと同じセグメントに接続できる。手順は [bridge.md](bridge.md) |

いずれも `KVM_HOST=headless ./kvm.sh up` のようにコマンドの前に付ける。`kvm.sh` がどこで読むかは [SPEC.md 4.2](SPEC.md#42-環境変数-ホスト側の入力)。

### 完了時点の状態

想定される状態 (出力例は本書用の整形で、実測の写しではない):

- `sudo podman ps` に `kvm` (イメージ `localhost/kvm-container/kvm:latest`) と、ディスプレイのあるホストでは `kvm-gui` (`localhost/kvm-container/gui:latest`) が `Up` で並ぶ。ディスプレイの無いホストは `kvm` だけ
- `sudo ls "${REPO}/data"` は `etc-libvirt  home  var-libvirt` (root 所有)。`ls /run/kvm-container/libvirt` に libvirt のソケットが並ぶ
- 両コンテナで `systemctl is-system-running` が `running`
  - `kvm` では `virtqemud` など libvirt のモジュラーデーモンがソケット活性化で待ち受け、`libvirt-guests.service` が有効
  - GUI ユーザー (ホストユーザーの写し) がロックされた状態で存在し、`/run/user/<uid>` と session bus がある
- ホスト上に libvirt の `virbr0` (192.168.122.0/24)、dnsmasq、nftables のルールができる (`--network host`)
- `./kvm.sh virsh list --all` は空 (VM は [vm.md](vm.md) で作る)

コンテナ実行仕様の表は [SPEC.md 1.1](SPEC.md#11-目的) と [3.3](SPEC.md#33-コンテナ実行仕様-podman-run)、共有物とマウントの表は [4.4](SPEC.md#44-マウント仕様と表示の仕組み)、ファイル一覧は [付録 A](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)。

### 注意点

- **`kvm.sh` は一般ユーザーで実行する**。root で実行すると止まる (コンテナ内のユーザーをホストユーザーに合わせるため)
- **再ログイン後は `up`**: GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えた場合は `./kvm.sh up` を実行する。`kvm-gui` だけが作り直され、VM は動いたまま (`viewer` も同じことをしてから起動する)
- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu なので、`down` で VM を止めてからホストを止める
  - `down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない
  - `down` (と `clean`) は動いている VM を先に ACPI でシャットダウンする (`libvirt-guests.service`)。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は電源を切られる
  - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には `virsh autostart` を設定する ([vm.md](vm.md))
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
- **`viewer` は `up` を経由する**: `kvm` が止まっていれば起動し、表示先が変わっていれば `kvm-gui` を作り直してから virt-viewer を開く。そのため `viewer` でも sudo のパスワードを聞かれることがある
- **複数行のブロックの途中の sudo**: `./kvm.sh` は内部で `sudo podman` を呼ぶ。sudo のタイムスタンプが切れた状態で複数行のブロックを貼ると、途中でパスワードを聞かれ、残りの行がパスワードとして読まれるか捨てられる
  - 新しい端末や長い待ち (ビルド・VM のインストール) の後は、先に `sudo -v` を単独で貼ってパスワードを入れておく
  - 途中で聞かれてしまったら、Ctrl+C で止めてから `sudo -v` を貼り、そのブロックを貼り直す

### 参照

- [SPEC.md](SPEC.md) — [1.1 目的](SPEC.md#11-目的) / [1.2 スコープ外](SPEC.md#12-スコープ外) / [2.1 ディスプレイの判定](SPEC.md#21-ディスプレイの判定-have_display) / [2.2 ホスト要件](SPEC.md#22-ホスト要件) / [2.3 実行ユーザーの要件](SPEC.md#23-実行ユーザーの要件) / [2.4 起動前に確認されるホスト資源](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [3.2 3 層構造とファイル](SPEC.md#32-3-層構造とファイル) / [3.3 コンテナ実行仕様](SPEC.md#33-コンテナ実行仕様-podman-run) / [3.5 コンテナ間の libvirt 接続](SPEC.md#35-コンテナ間の-libvirt-接続) / [4.1 CLI](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) / [4.2 環境変数](SPEC.md#42-環境変数-ホスト側の入力) / [4.4 マウント仕様と表示の仕組み](SPEC.md#44-マウント仕様と表示の仕組み) / [4.6 永続化データ](SPEC.md#46-永続化データ-data-と共有-run-dir) / [5.1 起動シーケンス](SPEC.md#51-起動シーケンス-kvmsh-up) / [5.2 停止シーケンス](SPEC.md#52-停止シーケンス-kvmsh-down) / [6 設計上の不変条件](SPEC.md#6-設計上の不変条件) / [7 セキュリティ考慮事項](SPEC.md#7-セキュリティ考慮事項) / [9 検証手順](SPEC.md#9-検証手順) (9.1 静的検査、9.2 物理 GNOME、9.3 ディスプレイ無し) / [付録 A ファイル一覧](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)
- [CLAUDE.md](../CLAUDE.md) — 変更時の注意点 (壊しやすい不変条件の理由、静的検査の対象ファイル)
- `./kvm.sh` (引数なし) — サブコマンドと環境変数の一覧 (`kvm.sh` 冒頭のヘッダコメント)

---

### 付録: 物理 AlmaLinux 10 + GNOME での確認手順

変更後の回帰確認。**先に [vm.md 手順 3](vm.md#実施手順) で VM を 1 つ作り、vm.md 手順 1 の `VM_NAME` を設定したシェルで貼る。** 期待結果と検証している項目の表は [SPEC.md 9.2](SPEC.md#92-物理-almalinux-10--gnome)。記録は PR #15 `ae650c0` (1 コンテナ構成) と PR #26 `ba2fee2` (現行)。以下のブロックは README にあった確認手順を記録どおりに分けたもので、`cd "${REPO:?…}"` の行と `viewer` の変数形は本実行していない。

`up` で sudo のパスワードを聞かれたら答えてから続ける。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}"
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

VM が無ければ、ここで [vm.md 手順 3](vm.md#実施手順) の `./kvm.sh virt-install ...` で VM を作る。次のブロックは GNOME デスクトップにウィンドウが出ること、VM のコンソールが見えることを確かめる (ウィンドウを閉じてから次へ)。

```bash
./kvm.sh viewer "${VM_NAME:?vm.md 手順 1 の VM_NAME を設定してから貼る}"
```

VM 名なしでは一覧から選ぶダイアログが出ること (`install-desktop` 後はアクティビティの「Virt Viewer」も同じ。現行エントリの本実行記録は無い。[desktop.md](desktop.md))。ダイアログを閉じてから次へ。

```bash
./kvm.sh viewer
```

GNOME からログアウト → 再ログイン → 端末で (手順 1 と vm.md 手順 1 の変数を貼り直してから):

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
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}"
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
- x86_64 のディスプレイ無しホストでの通し (PR #28 の記録は aarch64 の Raspberry Pi 5。`/dev/kvm` が無いときの `modprobe kvm_amd` / `kvm_intel` は x86 前提で、aarch64 では通らない)
- ロールバックの `sudo podman rmi --ignore …` とリポジトリの削除、更新の 3 項目と `git pull --ff-only` からの通常更新
- 手順 1 の `REPO_URL`、手順 2 の `sudo dnf install`、手順 3 の `git clone` (他の新規の行と「表示先が変わったとき」の `./kvm.sh up gui` → `./kvm.sh virsh list` は `0cab212` で実行した)
- `~/kvm-container` に clone したホストでの通し (`0cab212` の実行は git の worktree を clone 先にしたもの)
