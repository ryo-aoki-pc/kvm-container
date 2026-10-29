# kvm-container の注意点

setup-notes の[仮想マシンのセットアップの「kvm-container」](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container)で入れるときの注意点。背景は[参考資料](../reference/setup.md)、検証は[検証記録](https://github.com/ryo-aoki-pc/setup-notes-verification/blob/main/repos/kvm-container/docs/verification/setup.md)。

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
