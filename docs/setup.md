# qemu-kvm コンテナ 導入手順 (AlmaLinux 10 / podman、Windows + WSL2 / 物理 GNOME / ディスプレイ無し)

## 実施手順

**すべて対象ホストの一般ユーザーのシェルで実行する** (root や `sudo -i` のシェルは不可。`kvm.sh` は root で実行すると `!! run kvm.sh as a regular user, not root` で止まる)。画面を使うなら GNOME にログインした端末 (Windows + WSL2 では WSLg の動くディストリの端末) から実行する。手順 2 と手順 4 は sudo のパスワードを聞かれる (手順 2 は `[y/N]` も)。手順 5 も sudo のタイムスタンプが切れていれば聞かれる。手順 1 で変数を設定したシェルで、上から順にコードブロックを貼る (各手順の末尾で折り畳んである「補足」の中のブロックは、手順を進めるためには貼らなくてよい)。理由・実測・落とし穴は、手順ごとのものはその手順の「補足」に、全体に関わるものは後半の[補足](#補足)にまとめてあり、実行するだけなら読まなくてよい。実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [SPEC.md](SPEC.md)。

この手順を通すと、[VM の作成と操作](vm.md)、[アクティビティから起動する](desktop.md)、[ブリッジ](bridge.md) の各手順書が使える。

日常の操作は[使い方の基本](#使い方の基本)、再ログイン後は[表示先が変わったとき](#表示先が変わったとき-再ログイン後)、旧版からは[更新](#更新)、戻すときは[ロールバック](#ロールバック)。

1. **変数を設定する**

   **このブロックは編集必須の変数が無い。** リポジトリはユーザーのホームディレクトリ配下に clone して使う (例: `git clone … ~/kvm-container`)。VM のディスクや定義はその中の `data/` に置かれる。clone 先が `~/kvm-container` ならそのまま貼る。**新しいシェルを開いたら (SSH を張り直したあとも) 先にこのブロックを貼り直す。**

   ```bash
   REPO=~/kvm-container   # このリポジトリを clone した場所。ユーザーのホームディレクトリ配下にする。<REPO>
   ```

   **値を読み戻して確かめる。** `kvm.sh` が表示されなければ、ここで止めて直す。

   ```bash
   ls -l "${REPO}/kvm.sh"
   ```

   <details>
   <summary>補足: 変数について</summary>

   `REPO` は clone 先を指すだけで、`kvm.sh` に渡す変数ではない。`kvm.sh` は自分のあるディレクトリに `cd` してから動き、`data/` もそこ (`KVM_DATA_DIR=$PWD/data`) に作る。ホームディレクトリ配下 (`user_home_t`) に置く前提で、seed コンテナと両コンテナはラベル分離なし (`--security-opt label=disable` / `--privileged`) で動かし、`data/` を relabel しない。他の場所に置いた場合は検証していない。`install-desktop` はランチャーに `kvm.sh` の絶対パスを書くので、リポジトリを移動したら再実行する ([desktop.md](desktop.md))。

   </details>

1. **podman を入れる**

   ホストに入れるのは podman だけ (root で利用、`sudo` 可)。qemu・libvirt・virt-viewer はホストに入れない。

   ```bash
   sudo dnf install podman
   ```

   sudo のパスワードと `[y/N]` の確認がある。**次のブロックはインストールが終わってから貼る。** WSL2 で AlmaLinux 以外のディストリを使うなら、そのディストリのパッケージ管理で podman を入れる。

   ```bash
   rpm -q podman
   ```

   <details>
   <summary>補足: podman</summary>

   `kvm.sh` は `sudo podman` 固定で、rootless podman は使わない。ホストの libvirt とは無関係なので、ホストに qemu・libvirt を入れてはいけないわけではないが、入れて動かしていると `virbr0` が衝突する ([注意点](#注意点))。WSL2 では `/etc/wsl.conf` の `systemd=true` は不要 (root の podman は cgroupfs で動く)。ホスト要件は [SPEC.md 2.2](SPEC.md#22-ホスト要件)、実行ユーザーの要件は [2.3](SPEC.md#23-実行ユーザーの要件)。

   </details>

1. **ホストを準備する (種別ごとに 1 つ選ぶ)**

   **上から順ではなく、自分のホストに当てはまる 1 つだけを行う。**

   **A. Windows 11 + WSL2**

   Windows 側 (PowerShell) で WSL の版を確認する。WSL 2.5.1 以降であること (cgroup v2 が既定)。

   ```
   wsl --version
   ```

   ネストした仮想化は Windows 11 では既定で有効。無効なら `%USERPROFILE%\.wslconfig` に次を書いて `wsl --shutdown` する。

   ```
   [wsl2]
   nestedVirtualization=true
   ```

   ディストリ側では、`modprobe` が無いときだけ `kmod` を入れる (KVM モジュールは `./kvm.sh up` が自動でロードする)。`/etc/wsl.conf` の `systemd=true` は不要 (root の podman は cgroupfs で動く)。

   ```bash
   sudo dnf install kmod   # modprobe が無いときだけ
   ```

   `[y/N]` の確認がある。次のブロック (手順 4) はインストールが終わってから貼る。

   **B. 物理マシン / VM の AlmaLinux 10 + GNOME**

   ファームウェアで SVM (AMD) / VT-x (Intel) を有効にしておく。SELinux は Enforcing のままでよい (`--privileged` のためラベル分離は無効)。**GNOME にログインした状態の端末から** `kvm.sh` を実行する (`DISPLAY` / `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` / `XAUTHORITY` を元に `kvm-gui` へ表示先を渡すため)。

   ```bash
   getenforce                                            # Enforcing のままで可
   env | grep -E 'DISPLAY|WAYLAND|XDG_RUNTIME|XAUTH'      # GNOME 端末で値が入っていること
   ```

   **C. ディスプレイの無いホスト (SSH のみ)**

   何もしない。`./kvm.sh up` は `kvm` コンテナだけを起動し、GUI イメージはビルドしない。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` で行う。画面は表示できないので、ゲストにはシリアルコンソールやネットワーク経由でアクセスする ([VM の作成と操作](vm.md) の手順 4)。

   <details>
   <summary>補足: ホストの準備</summary>

   - **ホスト種別の判定**: `KVM_HOST=auto` (既定) では `host/wsl.sh` の `is_wsl` が `WSL_DISTRO_NAME` か `/proc/sys/kernel/osrelease` の `microsoft` で WSL2 を判定する。`KVM_HOST=wsl` / `generic` / `headless` で上書きできる ([SPEC.md 2.1](SPEC.md#21-ホスト種別と判定))。画面の有無は `KVM_HOST` が `headless` でなく、`DISPLAY` か `WAYLAND_DISPLAY` が設定されているかで決まる (`have_display`)
   - **WSL2**: WSLg は Wayland / PulseAudio のソケットを `/mnt/wslg/runtime-dir` に置き、`/run/user/<uid>` にはそこへのシンボリックリンクがある。`XDG_RUNTIME_DIR` が未設定なら `/mnt/wslg/runtime-dir` を使う。`/dev/dri` が無いので常にソフトウェア描画。`/dev/kvm` が modprobe 後も無いときの案内は `.wslconfig` の `nestedVirtualization=true` になる
   - **物理 GNOME**: `env | grep …` で値が入っていることを確かめるのは、`kvm.sh up` が実行ユーザーのセッション環境を `kvm-gui` に持ち込むため。SSH 越しや `sudo -i` のシェルでは `WAYLAND_DISPLAY` などが無く、`kvm-gui` は起動されない (`>> no display found`)。SELinux は Enforcing のまま (`kvm` は `--privileged`、`kvm-gui` は `label=disable`)
   - **ディスプレイ無し**: `up` は `kvm` だけを起動し、`up gui` と `viewer` は `!! no display found …` で終了する (それぞれ exit 1 / exit 2)。`KVM_HOST=headless` で画面のあるホストでも同じ挙動にできる
   - **起動前に確認されるホスト資源** (`check_host_network`): `KVM_BRIDGE` がブリッジでなければ停止、ホストに `virbr0` があれば警告 ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))

   </details>

1. **イメージをビルドする**

   最初の `sudo podman` なので sudo のパスワードを聞かれる。時間がかかる (AlmaLinux 10 minimal のイメージ取得と `microdnf` でのパッケージ導入)。

   ```bash
   cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh build
   ```

   - ディスプレイの無いホストは `./kvm.sh build kvm` で `kvm` イメージだけを作る (GUI イメージは不要)
   - `up` は足りないイメージを自動でビルドするので、この手順を飛ばして手順 5 に進んでもよい。分けてあるのは、ビルドの失敗と起動の失敗を切り分けるため
   - **次のブロックはビルドが終わってから貼る**

   <details>
   <summary>補足: ビルド</summary>

   `Containerfile` は AlmaLinux 10 minimal ベース (`microdnf`) のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、両コンテナ共通の unit マスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui`。`./kvm.sh build [kvm|gui]` は `podman build --target <role> -t localhost/kvm-container/<role>:latest` で、余分な引数は `podman build` に渡る。どちらのイメージも systemd (`/sbin/init`) で常駐する。イメージ名は固定 ([SPEC.md 3.4](SPEC.md#34-イメージ仕様-containerfile))。ビルドが失敗したら `./kvm.sh build kvm 2>&1 | tee build.log` のように出力を残す (`build.log` は `.gitignore` 済み)。

   </details>

1. **起動する**

   ```bash
   ./kvm.sh up
   ```

   - 初回は `>> seeding …/data/var-libvirt from image …` のように `data/` の初期化が 3 回出る。`>> ready. VMs: …` が出れば `kvm` は起動している。ディスプレイがあれば続けて `>> kvm-gui started. VM screen: ./kvm.sh viewer [VM]` が出る
   - ディスプレイの無いホストでは `>> no display found: GUI disabled (manage the VMs with ./kvm.sh virsh / virt-install)` が出る。これは正常
   - `!! /dev/kvm not found …` で止まったら、手順 3 のネストした仮想化 (WSL2) / SVM・VT-x (物理) を見直す
   - `!! virbr0 already exists on the host …` は、ホスト自身で libvirt が動いているか、前回のコンテナの残骸。警告だけで `up` は止まらず `kvm` は起動してしまうので、残骸なら `./kvm.sh down` でコンテナを消し、`sudo ip link del virbr0` で消してから `up` し直す ([注意点](#注意点))
   - **次のブロックは `>> ready.` が出てから貼る**

   <details>
   <summary>補足: 起動する</summary>

   `./kvm.sh up` の流れ ([SPEC.md 5.1](SPEC.md#51-起動シーケンス-kvmsh-up)): `/dev/kvm` の確認 (無ければ `modprobe`、0666 に) → root でないことの確認とホストユーザーの名前・uid/gid の取得 → イメージが無ければビルド → `data/` の初期化 → `check_host_network` → `/run/kvm-container/libvirt` を空にする → `kvm` を `podman run` → `>> waiting for libvirt...` (最大 30 秒) → `bridged` ネットワークの同期 → `>> ready.` → ディスプレイがあれば `kvm-gui` を起動。`kvm` が動いていれば `>> kvm is already running` で素通りする。

   **`kvm-gui` に渡すもの**

   `kvm.sh up` は実行ユーザーのセッション環境をそのまま `kvm-gui` に持ち込む (`kvm` には渡さない)。詳細は [SPEC.md 4.4](SPEC.md#44-マウント仕様と表示の仕組み) と [6 章](SPEC.md#6-設計上の不変条件)。

   - `$XDG_RUNTIME_DIR` (GNOME なら `/run/user/<uid>`。WSLg では `/run/user/<uid>` の中に `/mnt/wslg/runtime-dir` へのシンボリックリンクがある) をコンテナの **`/run/host-xdg-runtime` に読み取り専用**でマウントし、Wayland ソケット・GNOME の Xwayland 認証ファイル・PipeWire/Pulse のソケットは、その中を指す**絶対パス**で **`WAYLAND_DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`** に渡す (unix ソケットへの接続は読み取り専用でも可)。シンボリックリンクの先が runtime dir の外にある場合 (WSLg の `/mnt/wslg/...`) は、そのソケットファイルだけを同じパスに読み取り専用でマウントする
   - **ホストの runtime dir をコンテナの `/run/user/<uid>` に同じパスでマウントしてはいけない。** コンテナの logind がそのディレクトリを自分のものとして管理し、ユーザーのセッションや `systemd --user` の開始時にホストの session bus や `systemd --user` のソケットを作り直し、`user-runtime-dir@.service` の停止処理で中身をすべて削除してしまう (ホストの Wayland ソケットや session bus が消える。cockpit を載せていた頃に、そのログイン / ログアウトで実際に起きた不具合。PR #10)
   - **コンテナ内の `/run/user/<uid>` は、コンテナの logind が GUI ユーザー用に作るディレクトリ** (`kvm` では tmpfs、非特権の `kvm-gui` では tmpfs をマウントできないので `/run` 直下のディレクトリ)。`gui-user-setup` がこのユーザーを linger にしているので起動時から存在する (session bus 付き)。GUI アプリはこれを使う
   - **`/tmp/.X11-unix` は読み取り専用でマウント** (X11 フォールバック用)。読み取り専用にするのは、コンテナの systemd-tmpfiles がホストの X ソケットを削除してしまうのを防ぐため (同じ理由で **`tmpfiles.d/x11.conf` をマスク**)
   - **どちらのコンテナでも GUI ユーザーはホストユーザーの写し**: 起動時に `gui-user.service` が `kvm.sh up` を実行したホストユーザーの名前・uid/gid で作る (イメージには一般ユーザーを焼き込んでいない)。ホストの runtime dir は 0700 なので、その中のソケットに届くには uid の一致が必要。**パスワードは設定しない** (コンテナにログインするものは無く、ユーザーはロックされたまま。ホストのパスワードやハッシュはコンテナに渡さない)。値は `podman run -e` で渡し、コンテナ内では PID 1 の environ から読む
   - **WSL、または `/dev/dri` が無いホストではソフトウェア描画** (`LIBGL_ALWAYS_SOFTWARE=1`)。`/dev/dri` があれば `--device` で `kvm-gui` に渡し、`gui` が `renderD*` を 0666 にする。`KVM_SOFTWARE_GL=1` で強制できる
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

   ディスプレイのあるホストではさらに:

   ```bash
   sudo podman exec kvm-gui systemctl is-system-running                          # running
   sudo podman exec kvm-gui runuser -u "$USER" -- virsh -c qemu:///system list   # 一般ユーザーが kvm-gui から kvm の libvirt に接続できること
   ```

   `degraded` なら `./kvm.sh shell` (または `./kvm.sh shell gui`) で `systemctl --failed` を見る。ログは `./kvm.sh logs`。

   <details>
   <summary>補足: 動作確認</summary>

   - `systemctl is-system-running` が両コンテナで `running` (`degraded` ではない) ことは、Containerfile の unit マスク群 (`iscsid.socket` / `NetworkManager-wait-online.service` など) が効いているかの実質的な回帰テスト
   - `/run/libvirt/virtqemud-sock` が `srw-rw---- root libvirt` なのは `virtd-socket.conf` の drop-in が効いている証拠。`kvm-gui` から一般ユーザーで `virsh` が通ることが、コンテナをまたぐ libvirt 接続の回帰テスト ([選択した方針](#選択した方針))
   - `./kvm.sh logs` は `kvm` の `kvm-libvirt-conf` / `virtqemud` / `gui-user` の journal、`./kvm.sh logs gui` は `kvm-gui` の `/var/log/gui.log` と `gui-user` の journal を出す
   - 変更後の回帰確認は付録の確認手順 ([物理 GNOME](#付録-物理-almalinux-10--gnome-での確認手順) / [WSL2](#付録-windows--wsl2-での確認手順)) を手で流す。期待結果は [SPEC.md 9 章](SPEC.md#9-検証手順)

   </details>

---

## 使い方の基本

| サブコマンド | 用途 | 使う手順書 |
|---|---|---|
| `./kvm.sh build [kvm\|gui]` | 2 つのイメージをビルド (`localhost/kvm-container/kvm`、`localhost/kvm-container/gui`)。`build kvm` / `build gui` で片方だけ | 本書 [手順 4](#実施手順) |
| `./kvm.sh up [kvm\|gui]` | `kvm` を起動し、ディスプレイがあれば `kvm-gui` も起動 (kvm モジュールのロードと `/dev/kvm` の権限調整も行う)。`up gui` は `kvm-gui` だけ (再ログイン後など。`up` は `kvm-gui` が別のセッション用なら作り直す) | 本書 [手順 5](#実施手順) / [表示先が変わったとき](#表示先が変わったとき-再ログイン後) |
| `KVM_BRIDGE=br0 ./kvm.sh up` | VM をホストのブリッジ `br0` に接続できるようにして起動 | [bridge.md](bridge.md) |
| `./kvm.sh virt-install ...` | VM を作る (`kvm` コンテナ内の virt-install) | [vm.md](vm.md) |
| `./kvm.sh virsh ...` | virsh (`kvm` コンテナ)。`list` / `start` / `shutdown` / `destroy` / `undefine` など | [vm.md](vm.md) |
| `./kvm.sh viewer [VM名]` | VM の画面を virt-viewer で表示 (VM 名を省くと一覧から選ぶダイアログ) | [vm.md](vm.md) |
| `./kvm.sh shell [kvm\|gui]` | コンテナ内 root シェル (既定 `kvm`) | 本書 [手順 6](#実施手順) |
| `./kvm.sh logs [kvm\|gui]` | libvirt の journal と GUI アプリのログ | 本書 [手順 6](#実施手順) |
| `./kvm.sh down [kvm\|gui]` | コンテナ停止・削除 (VM のディスク / 定義はホストの `data/` に残る)。引数なしで両方 | 本書 [ロールバック](#ロールバック) |
| `./kvm.sh clean` | コンテナと `data/` のデータをすべて削除 (確認あり) | 本書 [ロールバック](#ロールバック) |
| `./kvm.sh install-desktop` | アクティビティ (アプリ一覧) から Virt Viewer を起動できるようにする | [desktop.md](desktop.md) |
| `./kvm.sh uninstall-desktop` | 上記の解除 | [desktop.md](desktop.md) |

- `up` は足りないイメージを自動でビルドする。`viewer` は先に `up` を実行するので、コンテナが止まっていても、再ログインで表示先が変わっていても、そのまま使える
- `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `KVM_SOFTWARE_GL` / `TZ` / `KVM_CLEAN_YES`) は、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける。一覧は補足の[環境変数](#環境変数)
- `./kvm.sh` を引数なしで実行すると、`kvm.sh` 冒頭のヘッダコメント (サブコマンドと環境変数の一覧) が出る

## 表示先が変わったとき (再ログイン後)

GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えたりした場合は `up` を実行する。`kvm-gui` だけが作り直され、`kvm` と VM は動いたまま (`viewer` も同じことをしてから起動する)。再ログインで `/run/user/<uid>` は作り直されるが、`kvm-gui` は古い runtime dir をマウントしたまま中身だけ消えるので、`up` は渡した引数 (ラベル `kvm.gui-session`) とコンテナ内の Wayland ソケット / 認証ファイルの実在の両方を確かめて作り直す。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh up gui
./kvm.sh virsh list   # VM が動いたまま
```

`>> the host session has changed: recreating kvm-gui (the kvm container and its VMs keep running)` が出る。何も変わっていなければ `>> kvm-gui is already running`。引数なしの `./kvm.sh up` でも同じ (`kvm` は `>> kvm is already running` で素通りする)。

## 更新

通常の更新は `git pull` のあと `./kvm.sh down` → `./kvm.sh build` → `./kvm.sh up` (動いている VM は `down` で ACPI 停止する。この流れは本実行していない)。旧版から更新する場合は次のとおり。

1. **`down` が VM をシャットダウンしない版から**: VM を止めてから `./kvm.sh down && ./kvm.sh build kvm && ./kvm.sh up` で `kvm` イメージを作り直す
1. **cockpit / firefox を使っていた版から**: `./kvm.sh down && ./kvm.sh build && ./kvm.sh up` で両イメージを作り直す。`COCKPIT_BIND` / `COCKPIT_PORT` は使われなくなり、ホストの 9091 番で listen するものは無くなる。`data/` はそのまま使える。Firefox のランチャーを入れていた場合は `./kvm.sh install-desktop` (または `uninstall-desktop`) が古い `kvm-firefox.desktop` を消す
1. **1 コンテナ構成の頃から**: `./kvm.sh down` で古い `kvm` コンテナを消してから `./kvm.sh build && ./kvm.sh up` する (古いコンテナは `/run/libvirt` を共有していないので、動いたままだと `kvm-gui` から libvirt に届かない)。古いイメージ `localhost/qemu-kvm-cockpit` は `sudo podman rmi localhost/qemu-kvm-cockpit` で消せる。`data/` はそのまま使える (`kvm-libvirt-conf.service` が libvirt の設定を更新する)

## ロールバック

コンテナを止めて消す。動いている VM は先に ACPI でシャットダウンされる (`>> shutting down the running VMs (up to 120 s)...`。120 秒で電源断)。`data/` (VM のディスク・定義) は残り、`/run/kvm-container` は消える。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh down
```

VM を止めるだけならここまで (`clean` は内部で `down` を呼ぶので、`data/` も消すときは `down` を先に貼らなくてもよい)。**ここから先は VM のディスク・定義が消える。**

```bash
./kvm.sh clean
```

`This deletes the VM disks and definitions as well. Continue? [y/N]` に `y` と答える (`KVM_CLEAN_YES=1 ./kvm.sh clean` で省略できる)。`data/` ごと消える。

イメージも消すなら `sudo podman rmi localhost/kvm-container/kvm:latest localhost/kvm-container/gui:latest` (本実行していない)。ホストに入れた podman はそのまま残す。

---

## 補足

### 対象と検証環境

- **目的**: qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナに収め、qemu も libvirt も入れていない軽量なホストで VM を動かし、その画面をホストのデスクトップに表示する。VM の作成・操作はコマンドライン (`virt-install` / `virsh`)、画面の表示は virt-viewer (ブラウザや Web コンソールは使わない)。`kvm-gui` は `kvm` の libvirt に共有 unix ソケット経由で接続する。デスクトップの再ログイン後は `kvm-gui` だけを作り直せるので、VM を止めずに済む。ディスプレイの無いホストでは `kvm` だけを使う (GUI イメージのビルドも不要)
- **進め方**: ホストに入れるのは podman だけ。`kvm.sh` が `sudo podman` でビルド・起動・停止をすべて行う。読者が書き換えるのは手順 1 の `REPO` だけ (既定の clone 先ならそれも不要)
- **状態**: 物理 AlmaLinux 10.2 + GNOME (Wayland、SELinux Enforcing) で通しの動作確認済み (PR #15 `ae650c0`: `up`、`running`、AVC 0、`/dev/dri` 0666、Wayland 直結、`down` → `up`、`clean`。PR #26 `ba2fee2`: `kvm` 再ビルド、両コンテナ `running`、VM のライフサイクル一式)。Windows 11 + WSL2 (WSLg) は 1 コンテナ構成の頃 (PR #12 `4e60c56`: `KVM_HOST=wsl` / `generic` / `headless` の分岐、PR #14 `7b42e14`: `--network host`、`down` で `virbr0` が消える、`default` の VM が DHCP) に確認したもので、**2 コンテナ構成 (PR #18) 以降の実行記録は無い**。**ディスプレイの無いホストは通しで検証していない** (`KVM_HOST=headless` の分岐は PR #12 で WSL2 上で確認)。手順 4 の `cd "${REPO:?…}" && ./kvm.sh build`、「表示先が変わったとき」の `cd "${REPO:?…}" && ./kvm.sh up gui`、付録の `cd "${REPO:?…}" && ./kvm.sh up && ./kvm.sh viewer "${VM_NAME:?…}"` (WSL2) と `./kvm.sh viewer "${VM_NAME:?…}"` は README の例を変数形に書き換えたもので、その形では再実行していない。手順 1 の `ls -l "${REPO}/kvm.sh"`、手順 2 の `rpm -q podman`、手順 3 の `wsl --version` のブロック、手順 6 の `./kvm.sh virsh list --all`、「表示先が変わったとき」の `./kvm.sh up gui` のブロックは新規の確認行で本実行していない (手順 6 の他の行は付録の確認手順から抜き出したもの。`$USER` をクォートした以外は同じ)

| 項目 | 物理 AlmaLinux 10 + GNOME | Windows + WSL2 | ディスプレイ無し |
|---|---|---|---|
| ホスト | AlmaLinux 10.2 + GNOME (Wayland)、SELinux Enforcing、AMD | Windows 11 + WSL2 (WSLg)。ディストリは記録に無い | — |
| 確認した版 | PR #15 (1 コンテナ構成、cockpit の頃)、PR #26 (現行の 2 コンテナ構成) | PR #12 / #14 (1 コンテナ構成、firefox / cockpit の頃) | 未検証 |
| 画面表示 | GNOME (Wayland) デスクトップ | WSLg 経由で Windows デスクトップ | 無し |
| `KVM_BRIDGE` | 未検証 (NIC が無線のみ) | ダミーブリッジで機構を確認 ([bridge.md](bridge.md#対象と検証環境)) | — |

対応ホスト:

| ホスト | 画面表示 |
| --- | --- |
| Windows 11 + WSL2 (AlmaLinux 10 など任意のディストリ) | WSLg 経由で Windows デスクトップに表示 |
| 物理マシン / VM の AlmaLinux 10 + GNOME | GNOME (Wayland) デスクトップに表示 |
| ディスプレイの無いホスト (SSH のみ) | 画面表示なし。VM の作成・操作は `./kvm.sh virt-install` / `./kvm.sh virsh` |

> **注記**: 環境固有の値は**シェル変数**で書いてある。[手順 1](#実施手順) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 意味 | 例 |
> |---|---|---|
> | `${REPO}` | このリポジトリを clone した場所。`data/` はこの中にできる。ユーザーのホームディレクトリ配下にする | `~/kvm-container` |
>
> `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` / `KVM_SOFTWARE_GL` / `TZ` / `KVM_CLEAN_YES`) は手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける ([環境変数](#環境変数))。出力例・表の中の値は `<VM名>` / `<uid>` / `<ホストユーザー名>` のプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない。
>
> パスワード・鍵・トークンは扱わない。コンテナにはホストのパスワードもハッシュも渡していない (GUI ユーザーはロックされたまま)。

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

### 実施前の状態

| 項目 | 状態 |
|---|---|
| ホスト OS | AlmaLinux 10 (物理 / VM / WSL2 のディストリ)。qemu・libvirt・virt-viewer は未導入のままでよい |
| podman | 未導入、または導入済み (root で使う) |
| 仮想化支援 | KVM が使える CPU (SVM / VT-x が有効)。WSL2 はネストした仮想化 |
| 画面 | GNOME (Wayland) のセッション、または WSLg。無ければ `kvm` だけを使う |
| `/dev/kvm` | 無くてよい。`up` が `kvm_amd` / `kvm_intel` をロードして 0666 にする |
| ホスト上の libvirt | 動いていないこと (`virbr0` / 192.168.122.0/24 が衝突する) |
| リポジトリ | ユーザーのホームディレクトリ配下に clone 済み。`data/` はまだ無い |

### 選択した方針

| コンテナ | 中身 | 権限 |
| --- | --- | --- |
| `kvm` | libvirt + qemu-kvm + virt-install (サーバ側。VM が動いている間は常駐) | `--privileged --network host` |
| `kvm-gui` | virt-viewer (デスクトップ側。ディスプレイのあるホストだけ) | 非特権 (`--network host`, SELinux ラベル分離なし) |

- **コマンドライン + virt-viewer**: VM の作成・操作は `kvm` コンテナ内の `virt-install` / `virsh` をパススルーし、画面は `kvm-gui` の virt-viewer で出す。ブラウザや Web コンソール (cockpit) は廃止した (PR #25)。RHEL 10 系の qemu-kvm には SPICE が無いので、グラフィックスは VNC ([vm.md](vm.md#選択した方針))
- **`kvm` は `--privileged --network host`**: KVM、libvirt の `default` ネットワーク (NAT / dnsmasq)、ホストのブリッジへの接続のため。`kvm-gui` は非特権だが `--security-opt label=disable`。SELinux Enforcing のホストで、特権コンテナが作った unix ソケットへ接続し、ホストの runtime dir を読むため
- **コンテナをまたぐ libvirt 接続**: `/run/libvirt` はホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナにバインドマウントしたもの。別コンテナからの接続では、デーモンが `SO_PEERCRED` で得る pid が 0 になる (pid 名前空間が違う) ため、libvirt 既定の polkit 認証は使えない。代わりに `auth_unix_rw = "none"` にし、ソケットの権限 (`root:libvirt 0660`) でアクセスを制限する。モジュラーデーモンは systemd のソケット活性化なので、権限は `/etc/libvirt/*.conf` の `unix_sock_*` ではなく `virt*d.socket` の drop-in (`container/kvm/virtd-socket.conf`) で決まる。`libvirt` グループの gid は両イメージで同じ値に固定し (Containerfile の `LIBVIRT_GID`)、`kvm-gui` 側のユーザーがこのグループでソケットに届くようにする。`/etc/libvirt` はホストの `data/etc-libvirt` で空のときしかイメージから初期化されないため、`auth_unix_rw` と qemu.conf の設定 (`security_driver = "none"`、`namespaces = []`) は `kvm` の起動時に `kvm-libvirt-conf.service` が毎回冪等に書き込む (既存の `data/` もそのまま使える)。詳細は [SPEC.md 3.5](SPEC.md#35-コンテナ間の-libvirt-接続) と [6 章](SPEC.md#6-設計上の不変条件)
- **`sudo podman`**: `kvm.sh` は root の podman を `sudo` で呼ぶ (`PODMAN="sudo podman"` 固定)。`--privileged`、`--network host`、`/dev/kvm` の受け渡し、ホストの `/run` 配下のディレクトリ共有のため。利用者は `sudo` を付けずに `./kvm.sh` を実行する
- **`data/` はバインドマウント**: リポジトリ内の `data/` (git 管理外) 配下のディレクトリをコンテナにバインドマウントする。バインドマウントは named volume と違い初回にイメージ側の内容をコピーしないため、空のときだけ `kvm.sh up` が `kvm` イメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーしてから起動する ([手順 5 の補足](#実施手順))
- **ホスト種別の差異は `host_*` フック**: `kvm.sh` に汎用実装 (`host_kvm_missing_hint` / `host_default_runtime_dir` / `host_force_software_gl`) を置き、`host/wsl.sh` が WSL2 検出時だけ上書きする ([SPEC.md 5.6](SPEC.md#56-ホスト種別フック-host_))

### 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `KVM_HOST` | `auto` | `wsl` / `generic` / `headless` で判定を上書き (判定は `host/wsl.sh`) |
| `KVM_SOFTWARE_GL` | 未設定 | `1` でソフトウェア描画を強制 |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン |
| `KVM_CLEAN_YES` | 未設定 | `1` で `clean` の確認を省略 |
| `KVM_BRIDGE` | 未設定 | ホストの既存ブリッジ名 (例 `br0`)。libvirt ネットワーク `bridged` として登録し、VM をホストと同じセグメントに接続できる。手順は [bridge.md](bridge.md) |

いずれも `KVM_HOST=headless ./kvm.sh up` のようにコマンドの前に付ける。`kvm.sh` がどこで読むかは [SPEC.md 4.2](SPEC.md#42-環境変数-ホスト側の入力)。

### 完了時点の状態

想定される状態 (出力例は本書用の整形で、実測の写しではない):

- `sudo podman ps` に `kvm` (イメージ `localhost/kvm-container/kvm:latest`) と、ディスプレイのあるホストでは `kvm-gui` (`localhost/kvm-container/gui:latest`) が `Up` で並ぶ。ディスプレイの無いホストは `kvm` だけ
- `sudo ls "${REPO}/data"` は `etc-libvirt  home  var-libvirt` (root 所有)。`ls /run/kvm-container/libvirt` に libvirt のソケットが並ぶ
- 両コンテナで `systemctl is-system-running` が `running`。`kvm` では `virtqemud` など libvirt のモジュラーデーモンがソケット活性化で待ち受け、`libvirt-guests.service` が有効。GUI ユーザー (ホストユーザーの写し) がロックされた状態で存在し、`/run/user/<uid>` と session bus がある
- ホスト上に libvirt の `virbr0` (192.168.122.0/24)、dnsmasq、nftables のルールができる (`--network host`)
- `./kvm.sh virsh list --all` は空 (VM は [vm.md](vm.md) で作る)

コンテナ実行仕様の表は [SPEC.md 1.1](SPEC.md#11-目的) と [3.3](SPEC.md#33-コンテナ実行仕様-podman-run)、共有物とマウントの表は [4.4](SPEC.md#44-マウント仕様と表示の仕組み)、ファイル一覧は [付録 A](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)。

### 注意点

- **`kvm.sh` は一般ユーザーで実行する**。root で実行すると止まる (コンテナ内のユーザーをホストユーザーに合わせるため)
- **再ログイン後は `up`**: GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えた場合は `./kvm.sh up` を実行する。`kvm-gui` だけが作り直され、VM は動いたまま (`viewer` も同じことをしてから起動する)
- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu なので、`down` で VM を止めてからホストを止める。`down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない。`down` (と `clean`) は動いている VM を先に ACPI でシャットダウンし (`libvirt-guests.service`)、120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は電源を切られる。`down` の時点で動いていた VM は次の `up` で起動しない (`up` で起動させたい VM には `virsh autostart` を設定する。[vm.md](vm.md))
- **`data/` は root 所有**: ホストから読み書きするには `sudo` がいる。SELinux Enforcing でも `:Z` は不要。`data/` を消すのは `clean` だけ (`down` では残る)
- **ホストのネットワーク名前空間を共有する** (`--network host`、両コンテナ):
  - ホスト自身で libvirt を動かしていると `virbr0` / 192.168.122.0/24 が衝突する。`up` 時にホストに `virbr0` があると警告する (警告だけで `up` は止まらない。コンテナの異常終了で残った場合は `down` してから `sudo ip link del virbr0` で削除し、`up` し直す)
  - `kvm-gui` も `--network host` (virt-viewer が VM の VNC に届くため)。listen するものは無いので、ホストと衝突するポートやソケットは無い。`kvm` 側も VM の VNC (loopback) 以外にホストで listen するものは無い
  - libvirt の `default` ネットワークの `virbr0`・dnsmasq・nftables ルールはホスト上に作られ、`net.ipv4.ip_forward=1` もホストに効く。コンテナ内の `iscsid.socket` / `iscsiuio.socket` (abstract unix ソケットがホストの `iscsid` と衝突して degraded になる) と NetworkManager (入るとホストの NIC を管理し始める) はマスクしている ([SPEC.md 4.5](SPEC.md#45-ネットワークとポート) / [6 章](SPEC.md#6-設計上の不変条件))
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
- **コンテナ名は `kvm` と `kvm-gui` に固定** (スクリプト内の変数名は `KVM_CONTAINER` / `GUI_CONTAINER`。`NAME` は WSL がホスト名に使うため避けている)。イメージ名も `localhost/kvm-container/{kvm,gui}` に固定
- **`viewer` は `up` を経由する**: `kvm` が止まっていれば起動し、表示先が変わっていれば `kvm-gui` を作り直してから virt-viewer を開く。そのため `viewer` でも sudo のパスワードを聞かれることがある

### 参照

- [SPEC.md](SPEC.md) — [1.1 目的](SPEC.md#11-目的) / [1.2 スコープ外](SPEC.md#12-スコープ外) / [2.1 ホスト種別と判定](SPEC.md#21-ホスト種別と判定) / [2.2 ホスト要件](SPEC.md#22-ホスト要件) / [2.3 実行ユーザーの要件](SPEC.md#23-実行ユーザーの要件) / [2.4 起動前に確認されるホスト資源](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [3.2 3 層構造とファイル](SPEC.md#32-3-層構造とファイル) / [3.3 コンテナ実行仕様](SPEC.md#33-コンテナ実行仕様-podman-run) / [3.5 コンテナ間の libvirt 接続](SPEC.md#35-コンテナ間の-libvirt-接続) / [4.1 CLI](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) / [4.2 環境変数](SPEC.md#42-環境変数-ホスト側の入力) / [4.4 マウント仕様と表示の仕組み](SPEC.md#44-マウント仕様と表示の仕組み) / [4.6 永続化データ](SPEC.md#46-永続化データ-data-と共有-run-dir) / [5.1 起動シーケンス](SPEC.md#51-起動シーケンス-kvmsh-up) / [5.2 停止シーケンス](SPEC.md#52-停止シーケンス-kvmsh-down) / [6 設計上の不変条件](SPEC.md#6-設計上の不変条件) / [7 セキュリティ考慮事項](SPEC.md#7-セキュリティ考慮事項) / [9 検証手順](SPEC.md#9-検証手順) (9.1 静的検査、9.2 物理 GNOME、9.3 WSL2) / [付録 A ファイル一覧](SPEC.md#付録-a-ファイル一覧とコンテナ内配置)
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

### 付録: Windows + WSL2 での確認手順

1 コンテナ構成の時点 (PR #12 / #14) で確認した項目。**2 コンテナ構成以降の再実行記録は無い。** 期待結果は [SPEC.md 9.3](SPEC.md#93-windows--wsl2)。ブリッジは WSL2 では使えない ([bridge.md](bridge.md#windows--wsl2-では使えません))。VM を 1 つ作り、vm.md 手順 1 の `VM_NAME` を設定したシェルで貼る。最初のブロックは WSLg 経由で Windows デスクトップに VM の画面が出ることを確かめる (`cd "${REPO:?…}"` と `viewer` の変数形は本実行していない。ウィンドウを閉じてから次へ)。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh up && ./kvm.sh viewer "${VM_NAME:?vm.md 手順 1 の VM_NAME を設定してから貼る}"
```

```bash
for c in kvm kvm-gui; do sudo podman exec $c systemctl is-system-running; done   # どちらも running
sudo podman exec kvm-gui ss -xp | grep wayland        # /mnt/wslg/runtime-dir/wayland-0 に接続していること (X11 フォールバックではない)
sudo podman exec kvm-gui findmnt /run/user/$UID       # ホストの runtime dir ではなく、コンテナ内 /run の下であること (非特権なので tmpfs ではない)
ls -A /run/user/$UID && systemctl --user is-system-running   # virt-viewer を開いて閉じた後も、ホスト側の一覧が変わらず running のままであること
```

#### 未確認事項

- ディスプレイの無いホストでの通し (手順 2〜6 と `virt-install` → `virsh console`)。`KVM_HOST=headless` の分岐だけ PR #12 で WSL2 上で確認
- 2 コンテナ構成 (PR #18 以降) での WSL2 の付録の再実行 (`ss -xp | grep wayland`、`findmnt /run/user/$UID`、ホストのセッションが無傷であること)
- `KVM_HOST=generic` の現行構成での再確認 (PR #12 で WSL2 上は確認済み)
- ロールバックの `sudo podman rmi …` と、更新の 3 項目・`git pull` からの通常更新
- 手順 1 / 2 / 3 / 6 の新規の確認行 (`ls -l "${REPO}/kvm.sh"`、`rpm -q podman`、`wsl --version`、`./kvm.sh virsh list --all`) と「表示先が変わったとき」の `./kvm.sh up gui` → `./kvm.sh virsh list`
