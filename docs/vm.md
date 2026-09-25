# VM の作成と操作手順 (virt-install / virt-viewer / virsh)

## 実施手順

> [!IMPORTANT]
> - **[導入](setup.md)を通したホストで、一般ユーザーのシェルから実行する**。前提は `./kvm.sh virsh list` が通ること ([導入の手順 7](setup.md#実施手順))。`sudo -i` した root のシェルでは `kvm.sh` が止まる
> - **インストールに使う ISO は、先にホストにダウンロードしておく** (手順 1 でそのパスを入れる)
> - **手順 4 はホストのデスクトップにウィンドウが開く**。GNOME にログインした端末から行い、ウィンドウの中でインストールを進める。ディスプレイの無いホストでは画面は出ない (手順 4 の注意)
> - **ホストの `sudo` はパスワードを聞かれない前提**。sudoers は読者が設定する ([導入の実施前の状態](setup.md#実施前の状態))

- 手順 1 で変数を設定したシェルで、上から順にコードブロックを貼る
- 各手順の末尾の「補足」(折り畳み) と後半の[補足](#補足)は、実行するだけなら読まなくてよい。折り畳みの中のブロックも貼らなくてよい
- 手順の後: 消すときは [VM を削除する](#vm-を削除する)。コンテナごと止める・消すのは[導入のロールバック](setup.md#ロールバック)
- VM をホストのブリッジにつなぐ場合は、先に [bridge.md](bridge.md) の手順 1〜4 を行い、本書の手順 1 で `VM_NETWORK=bridged` にする

1. **変数を設定する**

   **必須**: インストールに使う ISO をホストにダウンロードしておき、そのパスを入れる。

   ```bash
   ISO=   # ← ダウンロードした ISO のホスト側パス (例: ~/Downloads/AlmaLinux-10-latest-x86_64-dvd.iso)。<ISO>
   ```

   **任意**: 既定のままでよければそのまま貼る (値は旧 README の例と同じ)。

   ```bash
   REPO=~/kvm-container   # このリポジトリを clone した場所 (ホームディレクトリ配下)。<REPO>
   VM_NAME=alma10         # VM 名。ディスクは /var/lib/libvirt/images/${VM_NAME}.qcow2 になる。<VM_NAME>
   VM_MEMORY=4096         # メモリ (MiB)。<VM_MEMORY>
   VM_VCPUS=2             # vCPU 数。<VM_VCPUS>
   VM_DISK=20             # ディスクの大きさ (GiB)。<VM_DISK>
   VM_NETWORK=default     # VM をつなぐ libvirt ネットワーク。bridge.md を通したホストで LAN に直接つなぐなら bridged。<VM_NETWORK>
   ```

   値を読み戻し、リポジトリ直下に移る。`ISO` が空のままだと最後の行で止まる。

   ```bash
   for v in ISO REPO VM_NAME VM_MEMORY VM_VCPUS VM_DISK VM_NETWORK; do
     printf '%-10s = %s\n' "$v" "${!v}"
   done
   cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ls -l "${ISO:?手順 1 の ISO が空のまま。値を入れて貼り直す}"
   ```

   - `ls -l` が `No such file or directory` なら、`ISO` のパスを直してから先へ進む
   - **新しいシェルを開いたら** (SSH を張り直したあとも)、上の 3 つのブロックを貼り直してから先へ進む。最後のブロックでリポジトリ直下に移る

   <details>
   <summary>補足: 変数について</summary>

   - `ISO` はホスト側のパス。`ISO=~/Downloads/...` のように `~` で始めれば代入時に展開される (引用符で囲むと展開されない)。手順 2 でコピーし、手順 3 では `basename` だけをコンテナ内のパスに付ける
   - `ISO` は絶対パス (`~` 始まりを含む) で入れる。相対パスで入れると、最後のブロックの `cd` の後で見つからなくなる
   - `VM_NAME` は libvirt のドメイン名で、ディスク `/var/lib/libvirt/images/<VM名>.qcow2`、定義 `data/etc-libvirt/qemu/<VM名>.xml`、UEFI 変数 `data/var-libvirt/qemu/nvram/<VM名>_VARS.fd` の名前になる。削除 (`undefine`) もこの名前で行う
   - `VM_MEMORY` は MiB、`VM_DISK` は GiB (`virt-install` の単位)。既定値は旧 README の例 (`alma10` / 4096 / 2 / 20)
   - `VM_NETWORK` は手順 3 の `--network network=` に渡す libvirt ネットワークの名前。`default` は NAT (`virbr0`、192.168.122.0/24)、`bridged` は [bridge.md](bridge.md) で `KVM_BRIDGE` を付けて登録したホストのブリッジ
   - 変数はそのシェルの中だけで有効。以降のブロックは、最後のブロックで移ったリポジトリ直下で貼る

   </details>

1. **ISO を置く**

   ISO の大きさによっては時間がかかる (単独で貼る)。

   ```bash
   sudo cp "${ISO:?手順 1 の ISO が空のまま。値を入れて貼り直す}" data/var-libvirt/images/
   ```

   **次のブロックは `cp` が終わってから貼る。**

   ```bash
   sudo ls -l data/var-libvirt/images/   # ISO が root 所有で置かれている
   ```

   <details>
   <summary>補足: ISO の置き場所</summary>

   - `data/` は `sudo podman` で動くコンテナのバインドマウントなので root や qemu 所有になる。ホストから置く・消すには `sudo` が要る ([SPEC.md 4.6 節](SPEC.md#46-永続化データ-data-と共有-run-dir))
   - `data/var-libvirt` → `kvm` の `/var/lib/libvirt`、`data/etc-libvirt` → `/etc/libvirt`。ISO もディスクも VM 定義もホストの `data/` に残り、`./kvm.sh down` では消えない (`clean` だけが消す)
   - SELinux が Enforcing でも `:Z` などのラベル付けは要らない (`kvm` は `--privileged`)

   </details>

1. **VM を作る**

   ```bash
   ./kvm.sh virt-install --name "${VM_NAME:?手順 1 の VM_NAME が空のまま。値を入れて貼り直す}" --memory "${VM_MEMORY}" --vcpus "${VM_VCPUS}" --disk "size=${VM_DISK}" \
     --cdrom "/var/lib/libvirt/images/$(basename "${ISO:?手順 1 の ISO が空のまま。値を入れて貼り直す}")" --osinfo detect=on,require=off \
     --network "network=${VM_NETWORK:?手順 1 の VM_NETWORK が空のまま。手順 1 を貼り直す}" --graphics vnc --noautoconsole
   ```

   - `virt-install` はすぐ戻り、VM はインストーラが起動した状態 (`running`) になる
   - ディスクは `/var/lib/libvirt/images/${VM_NAME}.qcow2` (ホストの `data/var-libvirt/images/`) に作られる
   - `VM_NETWORK=bridged` でネットワークが見つからないと言われたら、[bridge.md](bridge.md) の手順 3 (`KVM_BRIDGE` を付けた `up`) を先に行う

   <details>
   <summary>補足: virt-install のオプション</summary>

   - `--osinfo` に OS 名を渡す場合の候補は `./kvm.sh virt-install --osinfo list` で確認できる
   - `--graphics vnc` と `--noautoconsole` は固定 (理由は後半の補足の[選択した方針](#選択した方針))
   - `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。本書は手順 1 の `VM_NETWORK` で明示し、ホストによってつなぎ先が変わらないようにした。ネットワークの仕様は [SPEC.md 4.5 節](SPEC.md#45-ネットワークとポート)
   - `default` につないだ VM がネットワークに出られること (インストーラがリポジトリに届き、起動後に `domifaddr --source agent` で IP が取れること) は PR #26 のライフサイクル確認で見ている ([付録](#付録-vm-のライフサイクルの確認手順))。そのときは `--network` を省いた形で、そのホストでは `default` につながった
   - `virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない。キックスタートは `OEMDRV` ラベルの ISO にして渡す ([付録](#付録-vm-のライフサイクルの確認手順)、[SPEC.md 8 章](SPEC.md#8-既知の制限事項))
   - `--cdrom` の VM は、インストーラの再起動で一度 `shut off` になり、以後はディスクから起動する。インストール後の CD-ROM は空 (`domblklist` の `sda` が `-`) になる (旧 README の記述と virt-install の仕様による。実測は `--location` + キックスタート形で、`--cdrom` 形は再実行していない)

   </details>

1. **画面を開いてインストールする**

   ホストのデスクトップに virt-viewer のウィンドウが開く (単独で貼る)。

   ```bash
   ./kvm.sh viewer "${VM_NAME}"
   ```

   - インストーラの画面が出るので、ウィンドウの中でインストールを進める
   - インストーラが最後に再起動すると VM は `shut off` になり、ウィンドウも閉じる (`--location` + キックスタートでの実測。`--cdrom` 形では再実行していない)
   - **次のブロックは、VM が `shut off` になるか、ウィンドウを閉じてから貼る** (`viewer` はウィンドウが閉じるまで戻らない)
   - **注意**: ディスプレイの無いホストでは `!! no display found ...` で終わる (終了コード 2)。ゲストにはシリアルコンソールかネットワーク経由でアクセスする (この手順の補足。未検証)

   <details>
   <summary>補足: viewer</summary>

   - `viewer` は先に `up` を実行する。コンテナが止まっていても、再ログインで表示先が変わっていても (`kvm-gui` だけ作り直される)、そのまま使える。VM は動いたまま ([導入の「表示先が変わったとき」](setup.md#表示先が変わったとき-再ログイン後))
   - VM 名を省くと一覧から選ぶダイアログが出る。`install-desktop` 後はアクティビティの「Virt Viewer」も同じ ([desktop.md](desktop.md))
   - ディスプレイの無いホスト (`DISPLAY` / `WAYLAND_DISPLAY` が無い、または `KVM_HOST=headless`) では `!! no display found ...` で終了コード 2 になる。シリアルコンソールは `./kvm.sh virsh console "${VM_NAME}"` で、抜けるのは `Ctrl+]`。ISO のインストーラがシリアルに出るかは ISO 次第 (未検証)
   - `viewer` は virt-viewer のウィンドウが閉じるまで戻らない。VM が `shut off` になるとウィンドウは自動で閉じる (`shutdown` で確認。[SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))

   </details>

1. **動作確認する**

   ```bash
   ./kvm.sh virsh list --all                       # VM_NAME の行がある (インストール完了後は shut off)
   ./kvm.sh virsh domblklist "${VM_NAME}"          # vda = /var/lib/libvirt/images/${VM_NAME}.qcow2。sda はインストール中は ISO、終了後は空 (-)
   sudo ls -l "${REPO}/data/var-libvirt/images/"   # ${VM_NAME}.qcow2 と ISO がある (root / qemu 所有)
   ```

   <details>
   <summary>補足: 動作確認</summary>

   - `domblklist` は削除の前にも使う。ディスクのターゲット名 (`vda` など) と CD-ROM (`sda`) の中身が分かる
   - ディスクファイルは `data/var-libvirt/images/<VM名>.qcow2`。`sudo ls -l` で所有者が root / qemu になっているのは仕様 (手順 2 の補足)

   </details>

1. **起動と停止と自動起動**

   インストール後の VM をディスクから起動する。

   ```bash
   ./kvm.sh virsh start "${VM_NAME}"
   ./kvm.sh virsh domstate "${VM_NAME}"            # running
   ```

   - 画面を見るなら `./kvm.sh viewer "${VM_NAME}"` (手順 4 と同じ。ウィンドウが閉じるまで戻らない)
   - **次のブロックは、OS が起動してログイン画面になってから貼る** (起動途中の OS は ACPI に応じないことがある)

   ACPI で停止する (単独で貼る)。

   ```bash
   ./kvm.sh virsh shutdown "${VM_NAME}"            # ACPI で停止 (destroy は強制停止)
   ```

   - `shutdown` は非同期で、コマンドはすぐ戻る
   - **次のブロックは、数十秒待ってから貼る**。`domstate` が `running` のままなら、少し待ってもう一度貼る

   ```bash
   ./kvm.sh virsh domstate "${VM_NAME}"            # shut off
   ./kvm.sh virsh autostart "${VM_NAME}"           # up で自動起動する (解除は --disable)
   ```

   - `./kvm.sh down` (と `clean`) は、動いている VM を先に ACPI でシャットダウンする。120 秒たっても止まらない VM は電源を切られる
   - `down` の時点で動いていた VM は次の `up` で起動しない。`up` で起動させたい VM には上の `autostart` を設定する
   - ホストを再起動・シャットダウンする前に `./kvm.sh down` で VM を止める ([注意点](#注意点))

   <details>
   <summary>補足: 停止の仕組み (libvirt-guests)</summary>

   - `virsh shutdown` は ACPI の電源ボタンに相当し、ゲスト OS がシャットダウンを行う。`destroy` は電源断
   - `./kvm.sh down` (と `clean`) では、コンテナ内の `libvirt-guests.service` (`container/kvm/libvirt-guests`: `ON_SHUTDOWN=shutdown` / `ON_BOOT=ignore` / `SHUTDOWN_TIMEOUT=120`) が動いている VM を一斉に ACPI でシャットダウンする。これが無いとコンテナの systemd が qemu の scope をすぐ止め、VM は電源断と同じ状態になる (次の起動でルートの XFS のジャーナル復旧が走るのを PR #26 で確認)
   - `down` の `podman rm -t` は 180 秒 (`kvm.sh` の `KVM_STOP_TIMEOUT`) で、VM の待ちは 120 秒。120 秒たっても止まらない VM (OS が無い、ACPI を無視するなど) は scope の停止で電源を切られる。ACPI に応じない VM では `down` が 122 秒で終わることを確認している ([SPEC.md 5.2 節](SPEC.md#52-停止シーケンス-kvmsh-down))
   - `ON_BOOT=ignore` なので、`down` の時点で動いていた VM は次の `up` で起動しない。起動するのは `virsh autostart` を設定した VM だけ (`data/etc-libvirt/qemu/autostart/` の symlink)

   </details>

---

## VM を削除する

手順 1 の変数を設定したシェル (リポジトリ直下) で貼る。まず、削除するディスクと CD-ROM の中身を確かめる。

```bash
./kvm.sh virsh domblklist "${VM_NAME:?手順 1 の VM_NAME が空のまま。値を入れて貼り直す}"   # vda = 消すディスク。sda に ISO が入ったままなら次のブロックで取り出す
```

`sda` に他の VM と共有している ISO が入ったままなら、取り出す (任意。本実行していない)。

- `--cdrom` でインストールした VM はインストール後に取り出されているので、普通は `sda` が `-` で、このブロックは要らない

```bash
./kvm.sh virsh change-media "${VM_NAME}" sda --eject --config   # CD-ROM から ISO を取り出す (定義にも反映)
```

VM を ACPI で止める (単独で貼る)。急ぐなら `shutdown` を `destroy` (強制停止) に変える。

```bash
./kvm.sh virsh shutdown "${VM_NAME}"
```

- 止まっている VM では `domain is not running` のエラーになるが、そのまま先へ進んでよい
- **次のブロックは、数十秒待ってから貼る**

```bash
./kvm.sh virsh domstate "${VM_NAME}"   # shut off。running のままなら少し待ってもう一度貼る
```

> [!CAUTION]
> **次のブロックで、VM の定義・UEFI 変数・ディスク (`vda`) が消え、取り戻せない。** ISO は残る。

```bash
./kvm.sh virsh undefine "${VM_NAME}" --nvram --storage vda   # 定義・UEFI 変数・ディスクを削除 (ISO は残る)
sudo ls "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}/data/var-libvirt/images" "${REPO}/data/etc-libvirt/qemu"   # qcow2 と xml が消え、ISO は残っている
```

ISO も消すなら、他の VM が使っていないことを `domblklist` で確かめてから貼る (任意。本実行していない)。

```bash
sudo rm "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}/data/var-libvirt/images/$(basename "${ISO:?手順 1 の ISO が空のまま。値を入れて貼り直す}")"
```

- コンテナごと止める・`data/` ごと消すのは[導入のロールバック](setup.md#ロールバック) (`down` は `data/` を残し、`clean` だけが消す)
- 削除の注意は補足の[VM を削除するときの注意](#vm-を削除するときの注意)

---

## 補足

### 対象と検証環境

- **目的**: [導入](setup.md)済みのホストで、ISO から VM を 1 つ作り、画面をホストのデスクトップに出してインストールし、`virsh` で起動・停止・自動起動・削除ができるようにする
  - VM の操作はすべて `./kvm.sh virt-install` / `./kvm.sh virsh` (`kvm` コンテナ内の `virt-install` / `virsh --connect qemu:///system` の省略形)
  - 画面は `./kvm.sh viewer` (`kvm-gui` コンテナの virt-viewer) で出す。ブラウザや Web コンソールは使わない
- **進め方**: 手順 1 で ISO のパスと VM 名を決め、以降のコマンドはそのまま貼る。読者が書き換えるのは `ISO` だけで、VM 名・メモリ・vCPU・ディスク・ネットワークは既定 (旧 README の例と `default`) のままでもよい
- **状態**:
  - 物理 AlmaLinux 10.2 + GNOME、SELinux Enforcing で、作成 → 起動 → `viewer` → `reboot` → `shutdown` → `suspend` / `resume` → `destroy` → 稼働中の `down kvm` → `autostart` → `undefine --nvram --storage vda` の一式を通した (PR #26。[付録](#付録-vm-のライフサイクルの確認手順))
  - **ただしそのときの作成は `--location` + キックスタート形で、`--network` も省いていた。** 手順 3 の `--cdrom` 形は README の例を変数形に書き換え、`--network "network=${VM_NETWORK}"` を足したもので、その形では再実行していない
  - 手順 2・5・6 と「VM を削除する」の各行も README の例を変数形に書き換えたもので、その形では再実行していない
  - 新しく足した行で、本実行していないもの: 手順 1 の `VM_NETWORK` と `cd`、手順 5 の `sudo ls -l`、手順 6 の `domstate`、削除の `change-media --eject --config`・`shutdown` と `domstate` のブロック・ISO の `sudo rm` (`--remove-all-storage` が ISO を消すことは `lctest` で確認した)
  - ディスプレイの無いホストでの VM の作成・操作 (`virt-install` / `virsh console`) は未検証。そこで確認したのは `up` 〜 `down` だけ ([導入](setup.md#対象と検証環境))

| 項目 | 値 |
|---|---|
| 検証ホスト | 物理 AlmaLinux 10.2 + GNOME、SELinux Enforcing (PR #26) |
| 確認した内容 | VM のライフサイクル一式 ([付録](#付録-vm-のライフサイクルの確認手順)。期待結果は [SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル)) |
| VM の作成形 | `--location` + キックスタート (`OEMDRV` ISO)、`--network` 省略。手順 3 の `--cdrom` 形は未再実行 |
| ゲスト OS | AlmaLinux 10.2 (boot ISO `AlmaLinux-10.2-x86_64-boot.iso`) |
| ディスプレイ無し | 未検証 (`viewer` が使えないことは [SPEC.md 8 章](SPEC.md#8-既知の制限事項)) |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[手順 1](#実施手順) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 意味 | 例 |
> |---|---|---|
> | `${ISO}` | ダウンロードした ISO のホスト側パス。手順 2 で `data/var-libvirt/images/` にコピーし、手順 3 では `basename` だけを使う | `~/Downloads/AlmaLinux-10-latest-x86_64-dvd.iso` |
> | `${REPO}` | このリポジトリを clone した場所。`data/` はその中にある | `~/kvm-container` |
> | `${VM_NAME}` | VM 名。ディスク (`<VM名>.qcow2`)、定義 (`data/etc-libvirt/qemu/<VM名>.xml`)、UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`) の名前になる | `alma10` |
> | `${VM_MEMORY}` / `${VM_VCPUS}` / `${VM_DISK}` | `virt-install` の `--memory` (MiB) / `--vcpus` / `--disk size=` (GiB) | `4096` / `2` / `20` |
> | `${VM_NETWORK}` | VM をつなぐ libvirt ネットワーク (`virt-install --network network=`)。`default` は NAT、`bridged` は [bridge.md](bridge.md) で登録したホストのブリッジ | `default` / `bridged` |
>
> - `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` など) は手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のように前に付ける。一覧は[導入の補足](setup.md#環境変数)
> - 出力例・表の中の値は `<VM名>` / `<uid>` などのプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない
> - ゲスト OS のパスワードはこの文書に載せない

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

### 実施前の状態

| 項目 | 状態 |
|---|---|
| コンテナ | [導入](setup.md)を通し `./kvm.sh up` 済み。`sudo podman exec kvm systemctl is-system-running` が `running` |
| VM | `./kvm.sh virsh list --all` に VM が無い (あっても構わない。`VM_NAME` が重ならないようにする) |
| `data/var-libvirt/images/` | `kvm` イメージから seed された空のディレクトリ (root 所有) |
| ISO | ホストにダウンロード済み (`data/` の外) |
| ホスト | qemu / libvirt / virt-viewer は入っていない (要らない) |

### 選択した方針

- **VM の作成・操作はコマンドライン** — `./kvm.sh virt-install` は `sudo podman exec -it kvm virt-install --connect qemu:///system`、`./kvm.sh virsh` は `sudo podman exec -it kvm virsh -c qemu:///system` の省略形 ([SPEC.md 4.1 節](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-))。ホストに virt-install / virsh を入れない
- **`--graphics vnc`** — RHEL 10 系の qemu-kvm には SPICE が無いため。VNC は `kvm` がホストの loopback で listen し、`kvm-gui` の virt-viewer が libvirt 経由で接続する
- **`--noautoconsole`** — `kvm` コンテナに virt-viewer が無いため。画面は `./kvm.sh viewer` で開く
- **`--osinfo detect=on,require=off`** — ISO から OS を検出し、検出できなくても中断しない。OS 名を渡すなら `--osinfo list` の候補から選ぶ
- **`--network` は明示する** — 省くと virt-install がホストの既定経路からつなぎ先を選び、ブリッジのあるホストでは `default` にならない。手順 1 の `VM_NETWORK` (既定 `default`) で決め、[bridge.md](bridge.md) を通したホストでは `bridged` を選べるようにした
- **ISO は `data/var-libvirt/images/` に置く** — ホストの `data/var-libvirt` が `kvm` コンテナの `/var/lib/libvirt` なので、コンテナ内では `/var/lib/libvirt/images/` に見える。手順 3 の `--cdrom` に渡すのはコンテナ内のパス
- **削除は `undefine --nvram --storage vda`** — `--remove-all-storage` は CD-ROM に入ったままの ISO も消すので、消すディスクを `--storage` で指定する。`--nvram` は UEFI の VM に必須で、BIOS の VM に付けても害は無い

### VM を削除するときの注意

- UEFI の VM (`<os firmware='efi'>`) は `--nvram` が無いと `Cannot undefine domain with NVRAM/varstore` で失敗する。BIOS の VM に付けても害は無い
- `--remove-all-storage` は CD-ROM に入ったままの ISO も削除する
  - 複数の VM で共有している ISO を消さないように、`--storage vda` のように消すディスクを指定する
  - または先に `./kvm.sh virsh change-media <VM名> sda --eject --config` で取り出す (`--cdrom` でインストールした VM はインストール後に取り出されているが、後から入れた場合は残る)
- `undefine --nvram --storage vda` で消えるのは定義 (`data/etc-libvirt/qemu/<VM名>.xml`)・UEFI 変数 (`data/var-libvirt/qemu/nvram/<VM名>_VARS.fd`)・`vda` のディスクだけで、ISO は残る ([SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))

### 完了時点の状態

手順 6 まで終えた直後 (VM は停止、自動起動あり):

```
$ ./kvm.sh virsh list --all
 Id   Name     State
-------------------------
 -    <VM名>   shut off
$ ./kvm.sh virsh domblklist <VM名>
 Target   Source
------------------------------------------------
 vda      /var/lib/libvirt/images/<VM名>.qcow2
 sda      -
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
- 「VM を削除する」まで行うと `<VM名>.qcow2` / `<VM名>.xml` / `<VM名>_VARS.fd` が消え、ISO だけが残る

### 注意点

- **ホストを再起動・シャットダウンする前に `./kvm.sh down`**: VM はコンテナの中の qemu。`down` は VM のシャットダウンを待つが、ホストの停止ではコンテナごと止められるため、VM が正常にシャットダウンできるとは限らない
- **`down` 時に動いていた VM は次の `up` で起動しない**: `up` で起動させたい VM には `virsh autostart` を設定する (手順 6)
- **ACPI に応じない VM**: OS の無い VM や ACPI の電源ボタンを無視する OS は、`virsh shutdown` では止まらず、`down` でも 120 秒待ったあと電源断と同じ状態で止まる。`destroy` で止める
- **削除時の共有 ISO**: `--remove-all-storage` は使わない。`domblklist` で確認して `--storage vda` (上の「VM を削除するときの注意」)
- **SPICE は無い**: グラフィックスは VNC。`--graphics spice` は使えない
- **`--network` を省いた場合**: ホストの既定経路がブリッジ上にあると `default` (NAT) にならない。本書の手順 3 は `VM_NETWORK` で明示しているので、この挙動に当たるのは `--network` を省いて自分で `virt-install` したときだけ
- **`down` が VM をシャットダウンしない版から更新した場合**: VM を止めてから `kvm` イメージを作り直す ([導入の「更新」](setup.md#更新))
- **ゲストの画面はホストのデスクトップにしか出ない**: SSH だけのホストでは `virsh console` かネットワーク経由 (未検証)

### 参照

- [SPEC.md 4.1 節](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) — `viewer` / `virt-install` / `virsh` サブコマンドの動作と終了コード
- [SPEC.md 4.5 節](SPEC.md#45-ネットワークとポート) — `default` / `bridged` ネットワーク、VNC の listen 先
- [SPEC.md 4.6 節](SPEC.md#46-永続化データ-data-と共有-run-dir) — `data/` の所有者と seed
- [SPEC.md 5.2 節](SPEC.md#52-停止シーケンス-kvmsh-down) — `down` で VM がシャットダウンされる順序と待ち時間
- [SPEC.md 8 章](SPEC.md#8-既知の制限事項) — SPICE 非対応、`--nvram`、`--remove-all-storage`、`--initrd-inject`、`--network` の既定
- [SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル) — 付録の期待結果と検証している項目の表
- [setup.md](setup.md) — 導入、使い方の基本、更新、ロールバック。[bridge.md](bridge.md) — ブリッジ。[desktop.md](desktop.md) — アクティビティからの起動
- `man virt-install` (`--cdrom` / `--location` / `--osinfo` / `--network`)、`man virsh` (`shutdown` / `destroy` / `autostart` / `undefine` / `change-media` / `domblklist`)

---

### 付録: VM のライフサイクルの確認手順

OS の入った使い捨ての VM `lctest` で、作成から削除までを確認する (手順の詳細と期待結果は [SPEC.md 9.5 節](SPEC.md#95-vm-のライフサイクル))。変更後の回帰確認に手で流す。PR #26 で物理 AlmaLinux 10.2 + GNOME (SELinux Enforcing) で通した記録なので、VM 名 `lctest` と boot ISO `AlmaLinux-10.2-x86_64-boot.iso` は変数にせずそのまま書いてある。
キックスタートは `data/` 以外の場所で書き、`OEMDRV` ラベルの ISO にして渡す (`virt-install --initrd-inject` は `kvm` イメージに `cpio` が無いので使えない)。
`ks.cfg` には `poweroff` と、`%packages` に `qemu-guest-agent` を入れておく。

- boot ISO は先に [手順 2](#実施手順) で `data/var-libvirt/images/` に置く (手順 1 の `ISO` にその boot ISO のパスを入れる)
- `ks.cfg` はカレントディレクトリ (最初のブロックの `cd` の後なのでリポジトリ直下) に置いてあるものとして `podman cp` している。別の場所に書いたならパスを読み替える。リポジトリ直下に置いた `ks.cfg` は `.gitignore` に無く `git status` に untracked として出るので、終わったら消す (誤ってコミットしない)
- 検証記録なので、待ち時間のある行が同じブロックに並んでいる。1 行ずつ結果を見ながら貼る (`virt-install` の後は `domstate` が `shut off` になるまで数分待ってから `start` 以降を貼る)

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}"
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

- 手順 3 の `--cdrom` 形での通し (作成からインストール完了まで)。検証記録は `--location` + キックスタート形だけ
- 手順 3 の `--network "network=${VM_NETWORK}"` (`default` / `bridged` のどちらも。検証記録は `--network` を省いた形だけ)
- 「VM を削除する」の `change-media --eject --config`、`shutdown` と `domstate` のブロック、ISO の `sudo rm`
- ディスプレイ無しのホストでの `./kvm.sh virsh console` (ISO のインストーラがシリアルに出るかも含む)
- 手順 1 の `cd`、手順 5・6 の変数形の行と、`sudo ls -l` / `domstate` の新規行
- 「完了時点の状態」の出力例 (表示形式から組み立てたもので、そのまま取った実測ではない)
