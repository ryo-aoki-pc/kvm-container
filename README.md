# qemu-kvm コンテナ (AlmaLinux 10)

qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナ (`kvm` = サーバ、`kvm-gui` = デスクトップ側) に収め、qemu も libvirt も入れていない軽いホストで VM を動かして、その画面をホストのデスクトップ (GNOME Wayland) に表示する。VM の作成・操作はコマンドライン (`./kvm.sh virt-install` / `./kvm.sh virsh`)、画面は virt-viewer (`./kvm.sh viewer`)。ブラウザや Web コンソールは使わない。

## 導入

- 対象: AlmaLinux 10 のホストの一般ユーザー (画面を使うなら GNOME の端末、画面の無いホストは SSH のシェル)。Windows 11 の手順は無い
- 前提: パスワードを聞かない `sudo`、CPU の仮想化支援 (VM の中ならネストした仮想化)。VM を作るのは x86_64 のホストだけ
- 手順は setup-notes の仮想マシンのセットアップの「[kvm-container](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container)」にある。ホストに入れるのは podman と git だけ

| 用途 | AlmaLinux 10 |
| --- | --- |
| 導入 (ホストごとに 1 度) | [kvm-container を導入する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-を導入する) |
| VM を作る (VM ごとに 1 度) | [kvm-container で VM を作る](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-で-vm-を作る) |
| VM を使う | [kvm-container の VM を使う](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-を使う) |
| 再ログインの後 | [kvm-container の GUI を再ログイン後に使う](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-gui-を再ログイン後に使う) |
| LAN に直接つなぐ | [kvm-container の VM をホストのブリッジにつなぐ](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-をホストのブリッジにつなぐ) |
| VM を消す | [kvm-container の VM を削除する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-の-vm-を削除する) |
| 更新 | [kvm-container を更新する](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-を更新する) |
| 戻す | [ロールバック](docs/extra/setup.md#ロールバック) |

## 文書

- [仕様](docs/SPEC.md): CLI・環境変数・マウント・起動と停止の順序・不変条件 (図付き)
- [参考資料](docs/reference/setup.md): 正本の各手順の背景、サブコマンドの一覧、選択した方針
- [注意点](docs/extra/setup.md#注意点)
- [検証記録](docs/verification/setup.md)
- 変更するとき: [変更後の確認](docs/dev/check.md)と [AGENTS.md](AGENTS.md)
