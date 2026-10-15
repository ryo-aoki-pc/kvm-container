# kvm-container のロールバックと注意点

setup-notes の[仮想マシンのセットアップの「kvm-container」](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container)で入れたものを戻す。背景は[参考資料](../reference/setup.md)、検証は[検証記録](../verification/setup.md)。「この節の手順 N」はこの文書の手順を指す。

## ロールバック

- 上から順に、通した節の分だけ実行する
- 一般ユーザーのシェルで行う。変数はこの節の手順 1 で設定する
- [ブリッジの項](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-をホストのブリッジにつなぐ)を通したときは、先に `bridged` につないだ VM を止め、`default` に付け替える (この文書では扱わない) か[VM を削除する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-を削除する)で消す
- ブリッジの項を通したときは、この節の手順 5 を GNOME の端末 (コンソール) から単独で貼る。ブリッジを消すと、その NIC 越しの ssh は切れる

> [!CAUTION]
> **この節の手順 7 で `data/` ごと、VM のディスク・定義が消え、取り戻せない。**

1. 変数を設定する (ブリッジを戻すときは、`NIC`・`NIC_CON` に値を入れる)。

   ```bash
   NIC=       # ← ブリッジに収容した物理 NIC (ブリッジを戻すときだけ)。<NIC>
   NIC_CON=   # ← 控えた NIC の元の接続名 (ブリッジを戻すときだけ)。<NIC_CON>
   ```

   ```bash
   REPO=~/kvm-container   # clone 先。ユーザーのホームディレクトリ配下にする。<REPO>
   BRIDGE=br0             # 戻すブリッジの名前。<BRIDGE>
   printf '\n\033[7m 確認 \033[0m\n'
   for v in NIC NIC_CON REPO BRIDGE; do
     printf '%-10s = %s\n' "$v" "${!v}"
   done
   [ ! -d "${REPO}" ] || cd "${REPO}"
   ```

   - `REPO` は、[kvm-container を導入する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-を導入する)の手順 1 と同じ値を入れる
   - `BRIDGE`・`NIC` は、[kvm-container の VM をホストのブリッジにつなぐ](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-をホストのブリッジにつなぐ)の手順 1 と同じ値を入れる。`NIC`・`NIC_CON` は、ブリッジの項を通していなければ空のままでよい
   - `NIC_CON` には、同じ項の手順 1 で控えた元の接続名を手で入れる。同じ項の手順 1 を貼り直して取らない (同じ項の手順 4 の後は `bridge-slave-…` の名前になる)
   - 値を読み戻して確かめる
   - 最後の行でリポジトリ直下に移る
   - 新しいシェルを開いたら、この手順の 2 つのブロックを貼り直してから先へ進む

1. ブリッジの項を通したときだけ、`bridged` を外すため、まず `kvm` を止める。

   ```bash
   cd "${REPO:?この節の手順 1 の REPO が空のまま。この節の手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
   ```

   - **次の手順は、`down` が終わってから貼る**

1. ブリッジの項を通したときだけ、`KVM_BRIDGE` を付けずに `kvm` を起動し直し、`bridged` を削除する。

   ```bash
   ./kvm.sh up                  # KVM_BRIDGE 無し: bridged を削除する (>> KVM_BRIDGE is not set: removing ...)
   ```

   - **次の手順は、`>> ready.` が出てから貼る**

1. ブリッジの項を通したときだけ、`bridged` が消えたか確かめる。

   ```bash
   ./kvm.sh virsh net-list      # bridged が消えている (default だけ)
   ```

   - `bridged` が消え、`default` だけならよい
   - bridge-slave の接続名は NetworkManager の既定 (`bridge-slave-<NIC>`)。違っていれば `nmcli connection show` で確かめる
   - **次の手順は、`NIC_CON` に元の接続名が入っているのを確かめてから、コンソールで単独で貼る** (ブリッジを消すと、その NIC 越しの ssh は切れる)

1. ブリッジの項を通したときだけ、コンソールから単独で、ブリッジを消して NIC の元の接続を上げる。

   ```bash
   sudo nmcli connection delete "${BRIDGE:?この節の手順 1 の BRIDGE が空のまま。この節の手順 1 を貼り直す}" "bridge-slave-${NIC:?この節の手順 1 の NIC が空のまま。この節の手順 1 を貼り直す}"
   sudo nmcli connection up "${NIC_CON:?この節の手順 1 の NIC_CON が空のまま。この節の手順 1 を貼り直す}"
   ```

   - ブリッジを消してから NIC に IP が戻るまでは通信できないので、2 行を続けて実行する
   - `ip -br addr show "${NIC}"` で、NIC に LAN の IP が戻っていることを確かめる

1. コンテナを止めて消す。

   ```bash
   cd "${REPO:?この節の手順 1 の REPO が空のまま。この節の手順 1 を貼り直す}" && ./kvm.sh down
   ```

   - 動いている VM は先に ACPI でシャットダウンされる (`>> shutting down the running VMs (up to 120 s)...`。120 秒で電源断)
   - `data/` (VM のディスク・定義) は残り、`/run/kvm-container` は消える
   - VM を止めるだけならここまでで、この節の手順 7・8 は飛ばす
   - **次の手順は、`down` が終わってから貼る**

1. `data/` ごと消すときだけ、`clean` で VM のディスク・定義も消す (取り戻せない)。

   ```bash
   ./kvm.sh clean
   ```

   - `This deletes the VM disks and definitions as well. Continue? [y/N]` に `y` と答える
   - `clean` は内部で `down` を呼ぶので、この節の手順 6 を飛ばしてもよい
   - **次の手順は、`[y/N]` に答えてから貼る** (続けて貼ると答えとして食われる)

1. イメージも消すときだけ、`kvm` と `gui` のイメージを消す。

   ```bash
   sudo podman rmi --ignore localhost/kvm-container/kvm:latest localhost/kvm-container/gui:latest
   ```

   - 画面の無いホストには `gui` のイメージが無いが、`--ignore` で無視される
   - ホストに入れた podman と git はそのまま残す
   - clone したリポジトリも要らなければ、`clean` の後に `cd ~ && rm -rf "${REPO:?この節の手順 1 の REPO が空のまま。この節の手順 1 を貼り直す}"` で消す

---

## 注意点

- **`kvm.sh` は一般ユーザーで実行する**。root で実行すると止まる (コンテナ内のユーザーをホストユーザーに合わせるため)
- **再ログイン後は `up`**: GNOME からログアウト / 再ログインしたり、ホスト側の `DISPLAY` 等を変えた場合は `./kvm.sh up` を実行する。`kvm-gui` だけが作り直され、VM は動いたまま (`viewer` も同じことをしてから起動する。[再ログイン](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-gui-を再ログイン後に使う))
- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu なので、`down` で VM を止めてからホストを止める ([kvm-container の VM を使う](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-を使う)の手順 7)
  - `down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない
  - `down` (と `clean`) は動いている VM を先に ACPI でシャットダウンする (`libvirt-guests.service`)。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は電源を切られる
  - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には `virsh autostart` を設定する ([kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 7)
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
- **VM を作るのは x86_64 のホスト**: [kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 4 の SATA (AHCI) と e1000e は、aarch64 の qemu-kvm に無い ([参考資料の VM を作る / 手順 4 の補足](../reference/setup.md#vm-を作る--手順-4-補足-virt-install-のオプション))
- **SPICE は無い**: グラフィックスは VNC。`--graphics spice` は使えない
- **`--network` を省いた場合**: ホストの既定経路がブリッジ上にあると `default` (NAT) にならない。正本の [kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 4 は `VM_NETWORK` で明示しているので、この挙動に当たるのは `--network` を省いて自分で `virt-install` したときだけ
- **ゲストの画面はホストのデスクトップにしか出ない**: SSH だけのホストでは `virsh console` かネットワーク経由

### VM を削除するときの注意

- UEFI の VM (`<os firmware='efi'>`) は `--nvram` が無いと `Cannot undefine domain with NVRAM/varstore` で失敗する。BIOS の VM に付けても害は無い
- `--remove-all-storage` は CD-ROM に入ったままの ISO も削除する
  - 複数の VM で共有している ISO を消さないように、`--storage sda` のように消すディスクを指定する
  - または先に `./kvm.sh virsh change-media <VM名> sdb --eject --config` で取り出す (`--cdrom` でインストールした VM は、Windows 以外はインストール後に取り出されているが、後から入れた場合は残る)
- `undefine --nvram --storage sda` で消えるのは定義 (`data/etc-libvirt/qemu/<VM名>.xml`)・UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`)・`sda` のディスクだけで、ISO は残る ([SPEC.md 9.5 節](../SPEC.md#95-vm-のライフサイクル))
- ターゲット名は作ったときのバスで決まる。[kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 4 の VM はディスクが `sda`・CD-ROM が `sdb`、virtio で作った VM はディスクが `vda`・CD-ROM が `sda`
  - virtio の VM に `--storage sda` を付けると、CD-ROM に入ったままの ISO が消え、qcow2 は残る
  - CD-ROM が空なら `Volume 'sda' was not found in domain's definition.` で止まり、何も消えない
  - そのため、[kvm-container の VM を削除する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-を削除する)の手順 2 で `vda` が出たら、`sda` を `vda` に、`sdb` を `sda` に読み替える

---
