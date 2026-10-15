# 変更後の確認

`kvm.sh`・コンテナの定義を変えたら、変更内容に合うシナリオを、setup-notes の[kvm-container を導入する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-を導入する)の手順 1 の `REPO` (VM を開くなら[kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 1 の `VM_NAME` も) を設定した一般ユーザーのシェルで行う。期待結果と静的検査は [SPEC.md 9 章](../SPEC.md#9-検証手順)。

- ホストの `sudo` がパスワードを求めず、処理が止まらないことを前提にする
- GUI の検査は GNOME にログインした一般ユーザーの端末で行う。`sudo -i` や SSH のシェルでは行わない
- 対話画面を閉じ、待機や確認が終わってプロンプトへ戻ってから次のブロックを貼る

## 物理 AlmaLinux 10 + GNOME で確認する

先に[kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)で VM を作り、GNOME にログインした端末で貼る。

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
   ./kvm.sh viewer "${VM_NAME:?VM を作るの手順 1 の VM_NAME を設定してから貼る}"
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

## ディスプレイの無いホストで確認する

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

## VM のライフサイクルを確認する

物理 AlmaLinux 10 + GNOME のホストで、使い捨て VM `lctest` を作成して削除する。

- boot ISO `AlmaLinux-10.2-x86_64-boot.iso` は、先に[kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る)の手順 1・2 で `data/var-libvirt/images/` に置く
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
