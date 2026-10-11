# kvm-container を戻す

## ロールバック

- 上から順に、通した節の分だけ実行する
- 正本の [導入の手順 1](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md#kvm-container-を導入する任意)で `REPO` を設定した一般ユーザーのシェルで行う
- ブリッジの設定を戻す場合は [ブリッジの手順 1](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md#kvm-container-の-vm-をホストのブリッジにつなぐ任意)の `BRIDGE`・`NIC` を使う。`NIC_CON` は当時控えた NIC の元の接続名で、現在の `bridge-slave-…` の名前ではない。手順 4 の前に手順 3 で確認する
- ブリッジの節を通したときは、先に `bridged` につないだ VM を止め、`default` に付け替える (本書では扱わない) か[VM を削除する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md#kvm-container-の-vm-を削除する)で消す
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
   - 新しいシェルなら、[導入の手順 1](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md#kvm-container-を導入する任意) と[ブリッジの手順 1](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md#kvm-container-の-vm-をホストのブリッジにつなぐ任意)を貼り直してから、`NIC_CON=` に控えた名前を入れ直す (ブリッジの手順 1 を貼り直すと、`NIC_CON` は `bridge-slave-…` の名前になる)
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
