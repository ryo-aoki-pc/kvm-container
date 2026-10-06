# qemu-kvm コンテナ 導入と VM の作成・操作手順 (AlmaLinux 10 / podman、物理 GNOME / ディスプレイ無し)

関連文書: [検証記録](verification/setup.md) / [参照情報](reference/setup.md)

## 実施手順

> [!IMPORTANT]
> - **すべて対象ホストの一般ユーザーのシェルで実行する**。root や `sudo -i` のシェルでは、`kvm.sh` が `!! run kvm.sh as a regular user, not root` で止まる
> - **画面を使うなら、GNOME にログインした端末から実行する**。SSH のシェルからでは `kvm-gui` が起動しない
> - **ホストの `sudo` は、パスワードを聞かれずに実行できるようにしておく**。本書は、どのブロックでも `sudo` が止まらない前提で書いてある。sudoers の設定は読者が行う (書き方は扱わない。権限上の意味は [SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項))
> - **VM を作るなら、インストールに使う ISO を先にホストにダウンロードしておく** ([導入の手順 1](#導入する-1-度だけ) でそのパスを入れる)
> - **VM を作るのは x86_64 のホスト**。[VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) で使う SATA と e1000e は、aarch64 の qemu-kvm には無い
> - **CPU の仮想化支援 (SVM / VT-x) が使えるホストが必要**。VM の中で実行するなら、外側のハイパーバイザーがネストした仮想化をゲストへ提供していること。提供されない VM ではイメージをビルドできても `up` は通らない
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
- コンテナのタイムゾーンを変えるときは、`TZ=UTC ./kvm.sh up` のように起動コマンドの前に `TZ=` を付ける (既定 `Asia/Tokyo`)
- VM をホストのブリッジにつなぐなら、導入の手順 1 の `VM_NETWORK` を `bridged` にし、導入の後に[ブリッジの節](#vm-をホストのブリッジにつなぐ-任意)の手順 1〜8 を行ってから VM を作る
- サブコマンドの一覧は[使い方の基本](reference/setup.md#使い方の基本)。実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [SPEC.md](SPEC.md)

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

   - `ISO` には、ホストにダウンロードしておいた ISO の絶対パスを入れる (`~` 始まりも可。代入値を引用符で囲むと `~` は展開されない)
   - `ISO` を使うのは [VM 作成の手順 1](#vm-を作る-vm-ごとに-1-度) から。空のままだと、そこで止まる
   - `REPO` から `VM_NETWORK` までは、既定のままでよければそのまま貼る
   - clone 先を `~/kvm-container` 以外にするときだけ `REPO` を変える。ユーザーのホームディレクトリ配下にする
   - 値を読み戻して確かめる
   - clone 済みなら、最後の行でリポジトリ直下に移る
   - **新しいシェルを開いたら** (SSH を張り直したあとも)、この手順の 2 つのブロックを貼り直してから、続きのシナリオへ進む


1. podman と git を入れる。

   ```bash
   sudo dnf install podman git
   ```

   - ホストに入れるのは podman と git だけ (podman は root で使う)
   - qemu・libvirt・virt-viewer はホストに入れない
   - **次の手順は、`[y/N]` に答えてインストールが終わってから貼る** (続けて貼ると答えとして食われる)


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
   - `already exists and is not an empty directory` で止まったら、`REPO` を変えてこの節の手順 1 から貼り直す
   - 以降の手順は、このディレクトリ (リポジトリ直下) で貼る


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
   - ホスト自身の libvirt は停止しておく (`virbr0` / 192.168.122.0/24 の衝突を避ける)
   - 画面があっても使わない場合は、`KVM_HOST=headless` を各 `up` の前に付け、この節の手順 7 は飛ばす


1. `kvm` のイメージをビルドする。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh build kvm
   ```

   - 時間がかかる (AlmaLinux 10 minimal のイメージ取得と `microdnf` でのパッケージ導入)
   - ビルドの最後に `Successfully tagged localhost/kvm-container/kvm:latest` が出ればよい
   - ビルドが失敗したら `./kvm.sh build kvm 2>&1 | tee build.log` のように出力を残して原因を確認する
   - **次の手順は、ビルドが終わってから貼る**


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
   - `!! /dev/kvm not found …`、または `modprobe: ERROR: could not insert 'kvm_amd': Operation not supported` などで止まったら、ファームウェアの SVM (AMD) / VT-x (Intel) を見直す。VM の中なら、外側のハイパーバイザーがネストした仮想化を提供しているかも確認する。コンテナの `--privileged` だけでは CPU の仮想化支援を足せない
   - `!! virbr0 already exists on the host …` は警告だけで、`kvm` は起動してしまう
   - 前回のコンテナの残骸なら `./kvm.sh down` → `sudo ip link del virbr0` → `./kvm.sh up` の順にやり直す
   - **次の手順は、`>> ready.` が出てから貼る**


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
   - **注意**: aarch64 のホストでは通らない想定。qemu-kvm に SATA と e1000e が無い


1. virt-viewer で画面を開き、インストールする。

   ```bash
   ./kvm.sh viewer "${VM_NAME}"
   ```

   - ホストのデスクトップに virt-viewer のウィンドウが開き、インストーラの画面が出る。ウィンドウの中でインストールを進める
   - インストーラが最後に再起動すると VM は `shut off` になり、ウィンドウも閉じる
   - **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする
   - シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で開き、`Ctrl+]` で抜ける。ISO のインストーラがシリアルに出るかは ISO による
   - **次の手順は、VM が `shut off` になるか、ウィンドウを閉じてから貼る** (`viewer` はウィンドウが閉じるまで戻らない)


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
- ブリッジの節を通したホストでは、この節の手順 1 の `./kvm.sh up` を `KVM_BRIDGE=br0 ./kvm.sh up` に変えて貼る

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
   - **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする
   - シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で開き、`Ctrl+]` で抜ける。ISO のインストーラがシリアルに出るかは ISO による
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
   - ホストの停止に任せると、VM が正常にシャットダウンできるとは限らない
   - ホストの起動後は、この節の手順 1 から貼る。起動するのは、自動起動を設定した VM だけ


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
- ブリッジ自体はホスト側で作る (`kvm.sh` はホストのネットワーク設定を変更しない)。無線 NIC しか無いホストでは使えない
- 元に戻すのは[ロールバック](#ロールバック)の手順 1〜4

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
   - 新しいシェルを開いたら (SSH を張り直したあとも)、[導入の手順 1](#導入する-1-度だけ) と、この手順の 2 つのブロックを貼り直してから先へ進む。**この節の手順 4 の後に貼り直すと `NIC_CON` の値が変わる**


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


1. コンソールから単独で、NIC の接続を落としてブリッジを上げる。

   ```bash
   sudo nmcli connection down "${NIC_CON:?この節の手順 1 の NIC_CON が空のまま。この節の手順 1 を貼り直す}" && sudo nmcli connection up "${BRIDGE}"
   ```

   - **注意**: この NIC 越しに ssh でつないでいるとセッションが切れ、2 つ目のコマンドが走らないことがある。コンソール (GNOME の端末) から、このブロックだけを単独で貼る
   - **次の手順は、ブリッジが上がって IP が付いてから貼る** (数秒かかる)


1. ブリッジが上がり、`kvm.sh` がブリッジと判定できるか確かめる。

   ```bash
   ip -br addr show "${BRIDGE}"                  # UP で、LAN の DHCP から IP が付く
   ls -d "/sys/class/net/${BRIDGE}/bridge"       # kvm.sh がブリッジと判定する条件 (このディレクトリがあること)
   ```

   - `ip -br addr show` でブリッジが `UP` で、LAN の DHCP から IP が付く
   - `ls -d` が `No such file or directory` なら、この節の手順 7 の `up` は `!! KVM_BRIDGE=... is not a bridge on this host` で止まる
   - そのときはブリッジの名前と状態を見直してから先へ進む


1. ブリッジを登録するため、先に `kvm` を止める。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。導入の手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
   ```

   - 動いている VM は ACPI でシャットダウンされる (最大 120 秒待つ)
   - `kvm` が動いたままだと、この節の手順 7 の `up` は `>> kvm is already running` で戻り、`bridged` は登録されない
   - **次の手順は、`down` が終わってから貼る**


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


1. [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) の後に、VM が `bridged` につながっていることを確かめる。

   ```bash
   ./kvm.sh virsh domiflist "${VM_NAME:?導入の手順 1 の VM_NAME を設定してから貼る}"   # Type が network、Source が bridged
   ```

   - [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェル (リポジトリ直下) で貼る
   - `Type` が `network`、`Source` が `bridged` ならよい
   - 既存の VM の付け替え (定義の `<source network='default'/>` を `bridged` にする) は本書では扱わない


---

## VM を削除する

- [導入の手順 1](#導入する-1-度だけ) の変数を設定したシェル (リポジトリ直下) で貼る。コンテナが止まっていれば、先に [VM 利用の手順 1](#vm-を使う-繰り返し) で起動する
- コンテナごと止める・`data/` ごと消すのは[ロールバック](#ロールバック)の手順 5〜7 (`down` は `data/` を残し、`clean` だけが消す)
- 共有 ISO を消さないため、`--remove-all-storage` は使わず、消すディスクを `--storage` で指定する
- UEFI の VM は `--nvram` を付ける。BIOS の VM に付けてもよい

> [!CAUTION]
> **この節の手順 5 で、VM の定義・UEFI 変数・ディスク (`sda`) が消え、取り戻せない。** ISO は残る。

1. 削除するディスクと、CD-ROM の中身を確かめる。

   ```bash
   ./kvm.sh virsh domblklist "${VM_NAME:?導入の手順 1 の VM_NAME が空のまま。値を入れて貼り直す}"   # sda = 消すディスク。sdb に ISO が入ったままなら次の手順で取り出す
   ```

   - `sda` が消すディスク
   - `sdb` が `-` なら、この節の手順 2 は飛ばす (`--cdrom` でインストールした VM は、Windows 以外はインストール後に取り出されている)
   - `vda` が出たら virtio で作った VM。この節の `sda` を `vda` に、`sdb` を `sda` に読み替えて貼る

1. `sdb` に他の VM と共有している ISO が入ったままのときだけ、取り出す。

   ```bash
   ./kvm.sh virsh change-media "${VM_NAME}" sdb --eject --config   # CD-ROM から ISO を取り出す (定義にも反映)
   ```


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


---

## 更新

- リポジトリを最新にし、イメージを作り直してコンテナを起動し直す。`data/` (VM のディスク・定義) はそのまま使える
- ブリッジの節を通したホストでは、この節の手順 2 の最後の `./kvm.sh up` を `KVM_BRIDGE=br0 ./kvm.sh up` に変えて貼る (`br0` はブリッジの節の手順 1 の `BRIDGE`)。付けないと `bridged` が消える

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

---

## ロールバック

- 上から順に、通した節の分だけ実行する
- ブリッジの節を通したときは、先に `bridged` につないだ VM を止め、`default` に付け替える (本書では扱わない) か[VM を削除する](#vm-を削除する)で消す
- ブリッジの節を通したときは、この節の手順 4 を GNOME の端末 (コンソール) から単独で貼る。ブリッジを消すと、その NIC 越しの ssh は切れる

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

   - 画面の無いホストには `gui` のイメージが無いが、`--ignore` で無視される
   - ホストに入れた podman と git はそのまま残す
   - clone したリポジトリも要らなければ、`clean` の後に `cd ~ && rm -rf "${REPO}"` で消す

---

## 変更後に確認する

変更内容に合うシナリオを、[導入の手順 1](#導入する-1-度だけ) の変数を設定した一般ユーザーのシェルで行う。期待結果は [SPEC.md 9 章](SPEC.md#9-検証手順)。

### 物理 AlmaLinux 10 + GNOME で確認する

先に [VM 作成の手順 3](#vm-を作る-vm-ごとに-1-度) で VM を作り、GNOME にログインした端末で貼る。

1. コンテナを起動し、権限・接続・SELinux を確かめる。

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

   - 両コンテナが `running`、ソケットが `srw-rw---- root libvirt`、SELinux 拒否が無いことを確かめる
   - **次の手順は、`>> ready.` が出てから貼る**

1. VM の画面を開いて表示を確かめる。

   ```bash
   ./kvm.sh viewer "${VM_NAME:?導入の手順 1 の VM_NAME を設定してから貼る}"
   ```

   - VM のコンソールが見えることを確かめる
   - **次の手順は、ウィンドウを閉じてから貼る**

1. VM 名を省いて一覧のダイアログを確かめる。

   ```bash
   ./kvm.sh viewer
   ```

   - VM を選ぶダイアログが出ることを確かめる
   - **次の手順は、ダイアログを閉じてから貼る**

1. GNOME からログアウト・再ログインし、変数を貼り直して起動する。

   ```bash
   ./kvm.sh up                                            # kvm-gui だけが作り直され、./kvm.sh virsh list の VM が動いたままであること
   ```

   - `kvm-gui` だけが作り直され、VM が動いたままであることを確かめる

1. コンテナを止め、ホスト上のネットワークとソケットの削除を確かめる。

   ```bash
   ./kvm.sh down; ip link show virbr0; ls /run/kvm-container   # どちらも残っていないこと
   ```

   - `virbr0` と `/run/kvm-container` が残っていないことを確かめる

### ディスプレイの無いホストで確認する

グラフィカルセッション外のシェル (SSH など) で貼る。

1. 画面を使わずにコンテナを起動する。

   ```bash
   cd "${REPO:?導入の手順 1 の REPO が空のまま。値を入れて貼り直す}"
   KVM_HOST=headless ./kvm.sh up      # >> ready. のあとに >> no display found: GUI disabled ... が出ること
   ```

   - `>> ready.` と `>> no display found: GUI disabled ...` が出る
   - **次の手順は、`>> ready.` が出てから貼る**

1. GUI と viewer が拒否されることを確かめる。

   ```bash
   KVM_HOST=headless ./kvm.sh up gui; echo "exit=$?"    # !! no display found ... the GUI container is not needed / exit=1
   KVM_HOST=headless ./kvm.sh viewer; echo "exit=$?"    # !! no display found ... manage the VMs with ./kvm.sh virsh / exit=2
   ```

   - `up gui` は終了 1、`viewer` は終了 2 になる

1. コンテナ・権限・ネットワーク・SELinux を確かめる。

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

   - `kvm` だけが `running` で、SELinux 拒否が無いことを確かめる

1. `KVM_HOST` を付けない起動と、停止後の削除を確かめる。

   ```bash
   ./kvm.sh down; ./kvm.sh up                           # 同じ >> no display found ... が出て >> ready. まで進むこと
   ./kvm.sh down; ip link show virbr0; ls /run/kvm-container   # どちらも残っていないこと
   ```

   - `KVM_HOST` 無しでも画面無しとして起動する
   - 最後の `down` 後に `virbr0` と `/run/kvm-container` が残らない

### VM のライフサイクルを確認する

物理 AlmaLinux 10 + GNOME のホストで、使い捨て VM `lctest` を作成して削除する。

- boot ISO `AlmaLinux-10.2-x86_64-boot.iso` は、先に [VM 作成の手順 1](#vm-を作る-vm-ごとに-1-度) で `data/var-libvirt/images/` に置く
- `ks.cfg` は `data/` の外のリポジトリ直下に用意し、`poweroff` と `%packages` の `qemu-guest-agent` を含める。終了後は誤ってコミットしないよう消す
- 待ち時間のあるブロックは 1 行ずつ結果を見ながら貼る。`virt-install` の後は `domstate` が `shut off` になるまで数分待ってから `start` 以降を貼る
- シリアルログ `/var/log/libvirt/qemu/lctest-serial.log` は `kvm` コンテナ内にある。`down` で消えるため、その前に確認する

1. キックスタート用 ISO を作り、VM のインストールと OS 起動を確かめる。

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

   - インストール完了後に `domstate` が `shut off` になるまで待つ
   - `guest-ping` が応答し、IP が取れていることを確かめる

1. 単独で VM の画面を開く。

   ```bash
   ./kvm.sh viewer lctest                                  # ログインプロンプトが見えること
   ```

   - ログインプロンプトが見えることを確かめる
   - **次の手順は、virt-viewer を開いたまま、別の端末でリポジトリ直下に移って貼る**

1. 画面を開いたまま、別の端末で再起動・シャットダウンを行う。

   ```bash
   ./kvm.sh virsh reboot lctest                            # 再起動して guest agent が戻ること
   ./kvm.sh virsh shutdown lctest                          # 数秒で shut off (shutdown)。viewer のウィンドウは閉じる
   ```

   - シャットダウンすると viewer のウィンドウが閉じる
   - **次の手順は、`./kvm.sh virsh domstate lctest` が `shut off` になってから貼る**

1. VM が停止したら、休止・強制停止・自動起動・削除を確かめる。

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

   - 各行の期待結果を確認してから次の行へ進む
   - 最後に定義とディスクが消え、ISO が残ることを確かめる
