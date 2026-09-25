# VM をホストのブリッジに接続する手順 (`KVM_BRIDGE` / NetworkManager、物理 AlmaLinux 10 + GNOME)

## 実施手順

> [!IMPORTANT]
> - **物理マシン / VM の AlmaLinux 10 + GNOME (NetworkManager) で、一般ユーザーのシェルから実行する**。`sudo -i` した root のシェルでは `kvm.sh` が止まる
> - **GNOME にログインした端末 (コンソール) から行う**。手順 2 の 3 つ目のブロックは NIC の接続をブリッジに切り替えるので、その NIC 越しの ssh は切れる
> - **前提は[導入](setup.md)を通し、`./kvm.sh up` が動くこと**。ブリッジ自体はホスト側で作る (`kvm.sh` はホストのネットワーク設定を変更しない)
> - **手順 2 と手順 3 では sudo のパスワードを聞かれる**。そのブロックだけ続けて貼らない

- 手順 1 で変数を設定したシェルで、上から順にコードブロックを貼る
- 各手順の末尾の「補足」(折り畳み) と後半の[補足](#補足)は、実行するだけなら読まなくてよい。折り畳みの中のブロックも貼らなくてよい
- 手順の後: VM を作るのは手順 5 ([vm.md](vm.md) を `VM_NETWORK=bridged` で通す)。戻すときは[ロールバック](#ロールバック)

> [!WARNING]
> **本書は通しで実行していない** ([対象と検証環境](#対象と検証環境))。
>
> - 記述は `kvm.sh` の実装 (`check_host_network` / `sync_bridged_network`) から書いた
> - 手順 2 の nmcli は物理ホストで本実行していない (検証に使った物理ホストは NIC が無線のみ)

1. **変数を設定する**

   **必須**: ブリッジに収容する物理 NIC の名前を入れる (`ip -br link` で確認する)。

   ```bash
   NIC=   # ← ブリッジに収容する物理 NIC (ip -br link で確認。例: enp1s0)。<NIC>
   ```

   **任意**: 既定のままでよければそのまま貼る。`NIC_CON` は `NIC` から自動で入る。

   ```bash
   BRIDGE=br0             # 作るブリッジの名前。libvirt ネットワーク bridged の実体になる。<BRIDGE>
   REPO=~/kvm-container   # このリポジトリを clone した場所 (ホームディレクトリ配下)。<REPO>
   NIC_CON=$(nmcli -g NAME,DEVICE connection show --active | awk -F: -v d="${NIC}" '$2==d{print $1}')   # NIC の現在の接続名 (自動)。<NIC_CON>
   ```

   値を読み戻し、リポジトリ直下に移る。`NIC` が空のままだと最後の行で止まる。

   ```bash
   for v in NIC BRIDGE REPO NIC_CON; do
     printf '%-8s = %s\n' "$v" "${!v}"
   done
   cd "${REPO:?手順 1 の REPO が空のまま。手順 1 を貼り直す}" && ls -l kvm.sh
   ip -br addr show "${NIC:?手順 1 の NIC が空のまま。値を入れて貼り直す}"
   ```

   - `NIC_CON` が空なら、ここで止める。`NIC` の名前が違うか、その NIC に active な接続が無い (`nmcli connection show --active` で確かめる)
   - `ip -br addr show` で NIC が `UP` で IP を持っていること (この IP がブリッジ側に移る)
   - **`NIC_CON` の値を控えておく**。ロールバックで NIC の元の接続を上げるのに使う
   - 新しいシェルを開いたら (SSH を張り直したあとも)、上のブロックを貼り直してから先へ進む。**手順 2 の後に貼り直すと `NIC_CON` の値が変わる** (この手順の補足)

   <details>
   <summary>補足: 変数について</summary>

   - `NIC_CON` (接続名) と `NIC` (デバイス名) は別物で、同じとは限らない (`Wired connection 1` のような名前のことがある)。`nmcli connection down` は接続名を取るので、`nmcli -g NAME,DEVICE connection show --active` の出力からデバイス名で引いている。README にあった `awk -F: '$2=="enp1s0"{print $1}'` を `-v d="${NIC}"` で変数化した形で、その形では再実行していない
   - `NIC_CON` は手順 1 の時点の値を保持する。手順 2 で NIC の接続を切り替えたあとにシェルを開き直して手順 1 を貼ると、NIC に付いている接続は `bridge-slave-<NIC>` なので `NIC_CON` はその名前になる。ロールバックで元の接続名が要るので、手順 1 の読み戻しの出力を控えておく

   </details>

1. **ブリッジを作る (NetworkManager)**

   物理 NIC をブリッジに収容し、IP はブリッジ側に持たせる。まずブリッジの接続を作る。sudo のパスワードを聞かれる (単独で貼る)。

   ```bash
   sudo nmcli connection add type bridge ifname "${BRIDGE:?手順 1 の BRIDGE が空のまま。手順 1 を貼り直す}" con-name "${BRIDGE}" ipv4.method auto
   ```

   **次のブロックは、パスワードを入れてから貼る。** NIC をブリッジに収容する接続を作る。

   ```bash
   sudo nmcli connection add type bridge-slave ifname "${NIC:?手順 1 の NIC が空のまま。値を入れて貼り直す}" master "${BRIDGE}"
   ```

   次のブロックは NIC の接続を落としてブリッジを上げる。

   - **注意**: この NIC 越しに ssh でつないでいるとセッションが切れ、2 つ目のコマンドが走らないことがある。コンソール (GNOME の端末) から、このブロックだけを単独で貼る

   ```bash
   sudo nmcli connection down "${NIC_CON:?手順 1 の NIC_CON が空のまま。手順 1 を貼り直す}" && sudo nmcli connection up "${BRIDGE}"
   ```

   **次のブロックは、ブリッジが上がって IP が付いてから貼る** (数秒かかる)。

   ```bash
   ip -br addr show "${BRIDGE}"                  # UP で、LAN の DHCP から IP が付く (NIC と同じ IP になるかは未確認)
   ls -d "/sys/class/net/${BRIDGE}/bridge"       # kvm.sh がブリッジと判定する条件 (このディレクトリがあること)
   ```

   - `ls -d` が `No such file or directory` なら、手順 3 の `up` は `!! KVM_BRIDGE=... is not a bridge on this host` で止まる
   - そのときはブリッジの名前と状態を見直してから先へ進む

   <details>
   <summary>補足: nmcli でブリッジを作る</summary>

   - 1 つ目のブロック: `type bridge` の接続 `${BRIDGE}` を作る (ifname と con-name を同じにする)。`ipv4.method auto` はブリッジが DHCP で IP を受ける設定
   - 2 つ目のブロック: NIC を収容する `type bridge-slave` の接続を作る。接続名は指定していないので NetworkManager の既定 (`bridge-slave-<NIC>`) になる。1 つ目と分けたのは、sudo のパスワードの入力で 2 行目が食われないようにするため
   - 3 つ目のブロック: NIC の元の接続を落とし、ブリッジを上げる。これで NIC は bridge-slave としてブリッジに付き、IP はブリッジ側に来る。その NIC 越しの ssh はここで切れる (`&&` の 2 つ目が走らずに終わることがあるので、コンソールから貼る)
   - 4 つ目のブロックの `ls -d /sys/class/net/<ブリッジ名>/bridge` は、`kvm.sh` の `check_host_network` が `KVM_BRIDGE` をブリッジと判定する条件そのもの ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))
   - 無線 NIC はここでは使えない ([注意点](#無線-nic-は-l2-ブリッジできない))

   </details>

1. **ブリッジを登録して起動する**

   先に `kvm` を止める。動いている VM は ACPI でシャットダウンされる (最大 120 秒待つ)。

   ```bash
   cd "${REPO:?手順 1 の REPO が空のまま。手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
   ```

   - `kvm` が動いたままだと、次の `up` は `>> kvm is already running` で戻り、`bridged` は登録されない (この手順の補足)
   - **次のブロックは `down` が終わってから貼る**。sudo のタイムスタンプが切れていればパスワードを聞かれる

   ```bash
   KVM_BRIDGE="${BRIDGE:?手順 1 の BRIDGE が空のまま。手順 1 を貼り直す}" ./kvm.sh up
   ```

   - `>> waiting for libvirt...` のあとに、`>> libvirt network "bridged" -> host bridge <ブリッジ名> (use it with …)` と出る
   - 最後に `>> ready. VMs: ...` で戻る。**次のブロックは `>> ready.` が出てから貼る**
   - **注意**: 以後、`kvm` を起動するすべての経路に毎回 `KVM_BRIDGE=` を付ける
   - 付けずに `kvm` を起動すると `bridged` は削除される (`>> KVM_BRIDGE is not set: removing the libvirt network "bridged"`)
   - `./kvm.sh viewer` も内部で `up` を呼ぶので、`KVM_BRIDGE=br0 ./kvm.sh viewer` にする
   - `./kvm.sh up gui` (再ログイン後の `kvm-gui` の作り直し) は `bridged` に影響しない。`kvm` が動いている限り `bridged` はそのまま

   <details>
   <summary>補足: <code>bridged</code> の登録と <code>KVM_BRIDGE</code> の付け忘れ</summary>

   - `bridged` の登録は `sync_bridged_network` ([SPEC.md 5.6](SPEC.md#56-ブリッジ同期-sync_bridged_network)) が行う。これは `start_kvm` が `podman run` で `kvm` を新しく起動し、libvirt の readiness を確認した直後にしか走らない。`kvm` がすでに動いていると `start_kvm` は `>> kvm is already running` で先に戻るので (`kvm.sh` の `start_kvm` 冒頭)、`KVM_BRIDGE=` を付けて `up` しても何も起きない。そのため手順 3 は `down kvm` → `KVM_BRIDGE=… up` の 2 ブロックにしてある
   - 起動前に `check_host_network` が `/sys/class/net/<ブリッジ名>/bridge` の有無を確かめ、無ければ `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/bridge.md)` で exit 1 する ([SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時))。手順 2 を飛ばしたときに出る
   - `sync_bridged_network` は毎回 define し直す (active なら `net-destroy` してから define → autostart → start)。`KVM_BRIDGE` の値を変えるとその値に追従する。`KVM_BRIDGE` が無いと `bridged` を `net-destroy` / `net-undefine` する。定義は `data/etc-libvirt` (`/etc/libvirt/qemu/networks/`) に永続化されるが、この削除で消える
   - `viewer` は内部で `up` を呼ぶ (`kvm` が止まっていれば起動する) ので、`kvm` が止まった状態で `KVM_BRIDGE=` 無しに `viewer` を実行すると `bridged` が削除される。`kvm` を起動し得る経路 (`up`、`up kvm`、`viewer`) には毎回 `KVM_BRIDGE=` を付ける。`up gui` は `kvm` に触らないので影響しない
   - `down kvm` は動いている VM を `libvirt-guests` が ACPI でシャットダウンしてから止める (120 秒で電源断、`podman rm -t` は 180 秒。[SPEC.md 5.2](SPEC.md#52-停止シーケンス-kvmsh-down))。`down` の時点で動いていた VM は次の `up` で起動しない (`virsh autostart` の VM を除く。[vm.md 手順 6](vm.md#実施手順))。`down kvm` の間 `kvm-gui` は残るが libvirt に届かない状態になり、次の `up` で `kvm` が起動して共有の `/run/libvirt` が空にされると復帰する。`down` (両方) でもよい

   </details>

1. **動作確認する**

   ```bash
   ./kvm.sh virsh net-list                # bridged が active (default と並ぶ)
   ./kvm.sh virsh net-dumpxml bridged     # forward mode が bridge、bridge name が BRIDGE の値
   ```

   - `net-list` に `bridged` が無ければ、`kvm` を止めずに `up` したか、`KVM_BRIDGE=` を付け忘れている。手順 3 をやり直す

   <details>
   <summary>補足: 動作確認</summary>

   - `net-list` で `bridged` が active なこと。`KVM_BRIDGE` 周りを変えたときの確認点は [SPEC.md 9.4](SPEC.md#94-その他の確認点-変更内容に応じて) (`KVM_BRIDGE` 無しで `up` すると消えることも含む)
   - `net-dumpxml bridged` は `kvm.sh` が define した XML (`<name>bridged</name>`、`<forward mode="bridge"/>`、`<bridge name="<ブリッジ名>"/>`) を返す想定。新規の確認行で本実行していないので、出力にはこれに libvirt が足す `<uuid>` などが加わる

   </details>

1. **VM をブリッジにつなぐ**

   [vm.md](vm.md#実施手順) を手順 1 から行う。vm.md 手順 1 の任意ブロックでは `VM_NETWORK=bridged` にして貼る。

   - vm.md 手順 3 の `virt-install` が `--network network=bridged` で VM を作る
   - VM は LAN の DHCP から IP を取る (ホストと同じセグメント)

   vm.md 手順 3 の後に、VM が `bridged` につながっていることを確かめる (vm.md 手順 1 の変数を設定したシェルで貼る)。

   ```bash
   ./kvm.sh virsh domiflist "${VM_NAME:?vm.md 手順 1 の VM_NAME を設定してから貼る}"   # Type が network、Source が bridged
   ```

   - 既存の VM の付け替え (定義の `<source network='default'/>` を `bridged` にする) は本書では扱わない (この手順の補足)

   <details>
   <summary>補足: VM の接続</summary>

   - `--network` を省くと、virt-install はホストの既定経路がブリッジ (`bridge0` など) 上にあればそのブリッジに、無ければ `default` (NAT、192.168.122.0/24) につなぐ (`kvm` はホストのネットワーク名前空間を共有するので、ホストのブリッジが見える)。手順 2 のあとはホストの既定経路がブリッジ上にあるので、`--network` を省いた VM もそのブリッジに直接つながり得る (この経路は `bridged` を経由しない)。vm.md 手順 3 は `VM_NETWORK` で `--network` を明示する ([SPEC.md 8 章](SPEC.md#8-既知の制限事項))
   - `bridged` の VM は tap がブリッジのポートになり、VM 自身の MAC で LAN に出る。仮想スイッチが MAC アドレスの詐称を許さない環境では、この形は通信できない
   - 既存の VM の付け替えは、`kvm` イメージにエディタが無いので `virsh edit` がそのままでは使えない。`virsh dumpxml` → 編集 → `virsh define` の手順も未検証
   - `domiflist` の確認は新規の行で、本実行していない

   </details>

## ロールバック

> [!WARNING]
> **以下は本実行していない。最後のブロックでブリッジを消すと、その NIC 越しの ssh は切れる。** コンソール (GNOME の端末) から行う。
>
> - 先に `bridged` につないだ VM を止め、`default` に付け替える (本書では扱わない) か削除する ([vm.md](vm.md#vm-を削除する))
> - `bridged` の VM が残ったまま `KVM_BRIDGE` 無しで `up` したときの挙動は未確認 ([未確認事項](#未確認事項))

`bridged` を外す (`KVM_BRIDGE` を付けずに `kvm` を起動し直す)。まず `kvm` を止める。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。手順 1 を貼り直す}" && ./kvm.sh down kvm   # 動いている VM は ACPI で停止
```

**次のブロックは `down` が終わってから貼る。**

```bash
./kvm.sh up                  # KVM_BRIDGE 無し: bridged を削除する (>> KVM_BRIDGE is not set: removing ...)
```

**次のブロックは `>> ready.` が出てから貼る。**

```bash
./kvm.sh virsh net-list      # bridged が消えている (default だけ)
```

ホストのブリッジと bridge-slave を消す。コンソールから、このブロックだけを単独で貼る。sudo のパスワードを聞かれる。

- `NIC_CON` は手順 1 で控えた元の接続名。新しいシェルなら、手順 1 を貼り直さずに `NIC_CON=` で控えた名前を入れてから貼る (手順 1 を貼り直すと `bridge-slave-…` の名前になる)
- bridge-slave の接続名は NetworkManager の既定 (`bridge-slave-<NIC>`)。違っていれば `nmcli connection show` で確かめる

```bash
sudo nmcli connection delete "${BRIDGE:?手順 1 の BRIDGE が空のまま。手順 1 を貼り直す}" "bridge-slave-${NIC:?手順 1 の NIC が空のまま。値を入れて貼り直す}"
```

**次のブロックは、パスワードを入れて削除が終わってから貼る。** NIC の元の接続を上げる (ここでブリッジは消えているので、NIC に IP が戻るまで通信できない)。

```bash
sudo nmcli connection up "${NIC_CON:?手順 1 で控えた元の接続名を NIC_CON に入れてから貼る}"
```

- `ip -br addr show "${NIC}"` で、NIC に LAN の IP が戻っていることを確かめる

---

## 補足

### 対象と検証環境

- **目的**: VM にホストと同じセグメントの IP (LAN の DHCP) を割り当てる
  - `kvm` コンテナは `--network host` でホストのネットワーク名前空間を共有するので、libvirt はホスト上のブリッジに VM の tap を直接つなげる
  - `KVM_BRIDGE=<ブリッジ名>` を付けて `up` すると、そのブリッジが libvirt ネットワーク `bridged` (`<forward mode="bridge"/>`) として登録され、VM 作成時に選べる
- **進め方**: ブリッジはホスト側で NetworkManager (`nmcli`) に作らせ、`kvm.sh` には `KVM_BRIDGE=` で名前だけ渡す。VM は vm.md を `VM_NETWORK=bridged` で通して作る。読者が書き換えるのは手順 1 の `NIC` だけ (ブリッジ名を `br0` 以外にするなら `BRIDGE` も)
- **状態**:
  - **本書は通しで実行していない。** `KVM_BRIDGE` の機構 (`bridged` の登録・削除と、`bridged` につないだ VM の疎通) を現行構成で確認した記録は無い
  - 本書の記述は `kvm.sh` の実装 (`check_host_network` / `sync_bridged_network`。[SPEC.md 2.4](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) / [5.6](SPEC.md#56-ブリッジ同期-sync_bridged_network)) から書いたもの
  - **手順 2 の nmcli 手順も物理ホストで本実行していない** (物理 AlmaLinux 10.2 + GNOME での通しの確認 PR #15 `ae650c0` は NIC が無線のみで `KVM_BRIDGE` を試していない)
  - README の例を変数形に書き換えたもので、その形では再実行していない行: 手順 1 の `NIC_CON` の式 (`awk -F: -v d="${NIC}" '$2==d{print $1}'`)、手順 2 の nmcli 行、手順 3 の `KVM_BRIDGE="${BRIDGE}" ./kvm.sh up`
  - 新規の確認行で本実行していないもの: 手順 1 の読み戻しと `cd`、手順 2 の `ip -br addr show` / `ls -d`、手順 3 の `./kvm.sh down kvm`、手順 4 の `net-dumpxml`、手順 5 の `domiflist`、ロールバックの各ブロック (手順 4 の `net-list` は README にあった行)

| 項目 | 値 |
|---|---|
| `KVM_BRIDGE` の機構 (`bridged` の登録・削除) | 未検証。`kvm.sh` の実装から記述した |
| 手順 2 の nmcli 手順 | 未検証。物理 AlmaLinux 10.2 + GNOME (PR #15 `ae650c0`) は NIC が無線のみ |
| 物理ホストのブリッジに VM をつなぎ LAN の DHCP から IP を取ること | 未検証 |
| NetworkManager | 物理ホストの AlmaLinux 10 の既定 (`nmcli`)。版は記録していない |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[手順 1](#実施手順) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 意味 | 例 |
> |---|---|---|
> | `${NIC}` | ブリッジに収容する物理 NIC の名前。`ip -br link` で確認する | `enp1s0` |
> | `${BRIDGE}` | 作るブリッジの名前。`nmcli` の接続名にも同じ名前を使い、`KVM_BRIDGE` に渡す | `br0` |
> | `${REPO}` | このリポジトリを clone した場所 (ホームディレクトリ配下) | `~/kvm-container` |
> | `${NIC_CON}` | NIC に今付いている NetworkManager の接続名。NIC 名と同じとは限らない (`nmcli -g NAME,DEVICE connection show --active` から自動で入る) | `enp1s0` / `Wired connection 1` |
>
> - `kvm.sh` 自身が読む環境変数 (`KVM_BRIDGE` など) は手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のようにコマンドの前に付ける。一覧は [setup.md の環境変数](setup.md#環境変数)
> - 手順 5 の `VM_NAME` と `VM_NETWORK` は [vm.md](vm.md) の手順 1 の変数
> - 出力例・表の中の値は `<ブリッジ名>` / `<VM名>` / `<NIC>` のプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない
> - パスワード・鍵・トークンは扱わない

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

### 実施前の状態

| 項目 | 状態 |
|---|---|
| ホスト | [導入](setup.md) 済み。`./kvm.sh up` で `kvm` (と `kvm-gui`) が起動できる |
| ホストの NIC | 物理 NIC に NetworkManager の接続が 1 つ付き、LAN の DHCP から IP を持っている。ブリッジは無い |
| libvirt ネットワーク | `default` (NAT、`virbr0`、192.168.122.0/24) だけ。`bridged` は未定義 |
| VM | あれば `default` につながっている (`--network` を省いた VM も、ホストにブリッジが無ければ `default`) |

### 選択した方針

- **ブリッジはホスト側で作り、`kvm.sh` は名前を受け取るだけ**: `kvm.sh` はホストのネットワーク設定を変更しない ([SPEC.md 1.2](SPEC.md#12-スコープ外))
  - コンテナ内の NetworkManager はマスクしてあり (入るとホストの NIC を管理し始める)、ブリッジを作る場所はホストしかない
- **`--network host` の上に `<forward mode="bridge"/>`**: `kvm` コンテナがホストのネットワーク名前空間を共有するので、libvirt はホストのブリッジに VM の tap を直接つなげる
  - `KVM_BRIDGE` のブリッジを libvirt ネットワーク `bridged` として登録し、VM 側は `--network network=bridged` で選ぶ (vm.md の `VM_NETWORK=bridged`)
  - 定義は `data/etc-libvirt` に永続化され、`KVM_BRIDGE` を付けずに `up` すると削除される ([SPEC.md 4.5](SPEC.md#45-ネットワークとポート))
- **IP はブリッジ側に持たせる**: 物理 NIC をブリッジのポートにし、`ipv4.method auto` でブリッジが DHCP を受ける。VM はホストと同じ LAN の DHCP から IP を受け取る
- **`default` (NAT) はそのまま残る**: `bridged` は追加であり、`default` を置き換えない。ブリッジを作れないホスト (無線 NIC しか無いなど) は `default` を使う

### 完了時点の状態

想定 (物理ホストでは本実行していない):

- ホスト: `nmcli connection show` に `<ブリッジ名>` (bridge) と `bridge-slave-<NIC>` (ethernet) があり、NIC の元の接続は inactive
  - `ip -br addr` で LAN の IP はブリッジに付き、NIC は IP を持たない。`/sys/class/net/<ブリッジ名>/bridge` がある
- libvirt (`./kvm.sh virsh net-list --all`): `default` と `bridged` がともに active / autostart。`bridged` の定義は `data/etc-libvirt/qemu/networks/bridged.xml` に永続化される
- `kvm.sh`: `KVM_BRIDGE=<ブリッジ名>` を付けた `up` / `viewer` で `>> libvirt network "bridged" -> host bridge <ブリッジ名> ...` が出る。付けないと `>> KVM_BRIDGE is not set: removing the libvirt network "bridged"` で消える
- VM: `--network network=bridged` で作った VM は LAN の DHCP から IP を取り、ホストの隣接テーブルには VM 自身の MAC が載る (いずれも未検証)

### 注意点

#### 毎回 `KVM_BRIDGE=` を付ける

- `bridged` は `kvm` の起動時に `KVM_BRIDGE` の有無で同期される
  - `KVM_BRIDGE=` を付けずに `kvm` を起動する経路 (`up`、`up kvm`、`viewer`) を 1 度でも通ると `bridged` は削除される
  - `bridged` につないだ VM がそのとき定義されたままだとどうなるか (起動時に `bridged` が見つからず失敗する想定) は未検証
- ブリッジがホストに無い (手順 2 の前、再起動でブリッジが上がっていない、名前の打ち間違い) と、`up` は `!! KVM_BRIDGE=<ブリッジ名> is not a bridge on this host. Create it first (see docs/bridge.md)` と本書を指して exit 1 する。ホスト側のブリッジを直してから `up` し直す
- シェルの `export KVM_BRIDGE=br0` にすれば毎回付けなくて済むが、本書はそれを検証していない (`kvm.sh` は `KVM_BRIDGE=${KVM_BRIDGE:-}` で環境から読むだけなので動く想定)

#### ホストのネットワーク名前空間の共有

`kvm` / `kvm-gui` はともに `--network host` で、libvirt が作るものはすべてホスト上に現れる。全体は [setup.md の注意点](setup.md#注意点)。本書に関わるのは次の 2 点:

- ホストに `virbr0` が残っていると (ホスト自身の libvirt、またはコンテナの異常終了の残骸) `up` が警告し、`default` の起動が失敗する。残骸なら `sudo ip link del virbr0` で消す
  - `bridged` はこれとは別で、ホストのブリッジを `kvm.sh` が消すことは無い
  - `kvm-net-teardown.service` は active な libvirt ネットワークを `net-destroy` し、`ip link del` のフォールバックは `virbr*` だけに掛ける。`<forward mode="bridge"/>` の `net-destroy` はホストのブリッジに触らない
- コンテナ内の NetworkManager はマスクしてある (入るとホストの NIC やブリッジを管理し始める)。ブリッジの操作は必ずホストの `nmcli` で行う

#### 無線 NIC は L2 ブリッジできない

Wi-Fi の NIC は (4 アドレス形式などの例外を除き) 自分以外の MAC のフレームを送れないので、ブリッジのポートにしても VM は LAN に出られない。

- 物理 AlmaLinux 10 + GNOME での通しの確認 (PR #15) で `KVM_BRIDGE` を試せなかったのはこのため (NIC が無線のみ)
- 有線 NIC のあるホストで行う。無線しか無いホストは `default` (NAT) を使う

### 参照

- [SPEC.md 1.2 スコープ外](SPEC.md#12-スコープ外) — ホストのネットワーク設定の変更が対象外である理由
- [SPEC.md 2.4 起動前に確認されるホスト資源](SPEC.md#24-起動前に確認されるホスト資源-check_host_networkkvm-の起動時) — `check_host_network` のブリッジ確認と `virbr0` の警告
- [SPEC.md 4.2 環境変数](SPEC.md#42-環境変数-ホスト側の入力) — `KVM_BRIDGE` を読む場所
- [SPEC.md 4.5 ネットワークとポート](SPEC.md#45-ネットワークとポート) — `default` / `bridged` と `--network host` の図
- [SPEC.md 5.6 ブリッジ同期](SPEC.md#56-ブリッジ同期-sync_bridged_network) — `sync_bridged_network` のフロー
- [SPEC.md 8 章 既知の制限事項](SPEC.md#8-既知の制限事項) — `virt-install` の既定ネットワーク
- [SPEC.md 9.4 その他の確認点](SPEC.md#94-その他の確認点-変更内容に応じて) — `KVM_BRIDGE` 周りを変えたときの確認
- [setup.md](setup.md) の[環境変数](setup.md#環境変数)と[注意点](setup.md#注意点)、[vm.md](vm.md) の[手順 1・3](vm.md#実施手順) (`VM_NETWORK`)
- `man nmcli` / `man nm-settings-nmcli` (`bridge`、`bridge-slave`、`ipv4.method`) / `man virsh` (`net-list`、`net-dumpxml`、`net-undefine`、`domiflist`) / `man virt-install` (`--network`)

### 未確認事項

- 手順 2 の nmcli 手順 (物理ホスト、有線 NIC) の本実行。ブリッジが DHCP で NIC と同じ IP を引き継ぐか、ブリッジを上げたあとの ssh の復帰
- 手順 1 の `NIC_CON` の式 (`awk -v d="${NIC}"` 形) と、手順 1〜3 の変数形・新規の行
- 手順 4 の `net-dumpxml bridged` の実際の出力
- 物理ホストのブリッジに `--network network=bridged` (vm.md の `VM_NETWORK=bridged`) でつないだ VM が LAN の DHCP から IP を取ること、手順 5 の `domiflist` の出力
- `KVM_BRIDGE` を付けた `up` で `bridged` が登録されること、`KVM_BRIDGE` 無しの `up` で削除されること (実行記録なし)
- `bridged` につないだ VM が定義されたまま `KVM_BRIDGE` 無しで `up` したときの挙動 (`bridged` の削除が失敗するか、VM の起動が失敗するか)
- ロールバックの nmcli (`connection delete` と元の接続の `up`) と、`KVM_BRIDGE` 無しの `up` で `bridged` が消えるところ (README には書かれていたが本書の形では再実行していない)
- `export KVM_BRIDGE=br0` にしたときの `viewer` / `up` の挙動
- 既存 VM の `bridged` → `default` の付け替え手順
