# qemu-kvm コンテナ (AlmaLinux 10)

qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナ (`kvm` = サーバ、`kvm-gui` = デスクトップ側) に収め、
qemu も libvirt も入れていない軽量なホストで VM を動かして、その画面をホストのデスクトップ (GNOME Wayland) に表示する。
VM の作成・操作はコマンドライン (`./kvm.sh virt-install` / `./kvm.sh virsh`)、画面は virt-viewer (`./kvm.sh viewer`)。ブラウザや Web コンソールは使わない。
手順書は導入・VM の作成・利用・再ログイン後のシナリオと、変更後の確認を番号付きリストで載せている。検証結果は [検証記録](docs/verification/setup.md)、背景や実装の説明は [参照情報](docs/reference/setup.md) に分けている。
実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [docs/SPEC.md](docs/SPEC.md)、変更時の注意は [CLAUDE.md](CLAUDE.md)。

## 手順書

- 手順書は [docs/setup.md](docs/setup.md) の 1 本。`## 実施手順` の下で、1 度だけ行うシナリオ (導入する、VM を作る) と繰り返すシナリオ (VM を使う、再ログインしたとき) を見出しで分けてある。ブリッジは任意の節
- 初めてなら、導入する → VM を作る → VM を使う の順に上から貼る。以後は、必要なシナリオだけを貼る
- 対象は AlmaLinux 10.2 (物理 GNOME / ディスプレイ無し)。検証範囲 (どの節を本実行したか) は、[検証記録の対象と検証環境](docs/verification/setup.md#対象と検証環境)の「状態」に書いてある

| 節 | 頻度 | 用途 | 使うサブコマンド |
|---|---|---|---|
| [導入する](docs/setup.md#導入する-1-度だけ) | 1 度だけ | podman と git だけのホストにこのリポジトリを clone し、イメージをビルドしてコンテナを起動する | `build` / `up` |
| [VM を作る](docs/setup.md#vm-を作る-vm-ごとに-1-度) | VM ごとに 1 度 | x86_64 のホストで、`virt-install` で VM (ディスクは SATA の SSD、NIC は e1000e) を作り、virt-viewer の画面でインストールして、自動起動を設定する | `virt-install` / `viewer` / `virsh` |
| [VM を使う](docs/setup.md#vm-を使う-繰り返し) | 繰り返し | コンテナと VM を起動し、virt-viewer で画面を見て、`virsh` で止める。ホストを止める前は `down` | `up` / `virsh` / `viewer` / `down` |
| [再ログインしたとき](docs/setup.md#再ログインしたとき-繰り返し) | 繰り返し | 再ログイン後に `kvm-gui` だけを作り直す (VM は動いたまま) | `up gui` |
| [VM をホストのブリッジにつなぐ (任意)](docs/setup.md#vm-をホストのブリッジにつなぐ-任意) | 任意、1 度だけ | VM にホストと同じセグメントの IP を割り当てる (NetworkManager のブリッジ) | `KVM_BRIDGE=… ./kvm.sh up` |
| [VM を削除する](docs/setup.md#vm-を削除する) | VM ごとに 1 度 | VM の定義・UEFI 変数・ディスクを消す (ISO は残る) | `virsh undefine` |
| [更新](docs/setup.md#更新) | 更新のたび | リポジトリを最新にし、イメージを作り直して起動し直す | `down` / `build` / `up` |
| [ロールバック](docs/setup.md#ロールバック) | 戻すとき | 任意の節を戻し、コンテナ・`data/`・イメージを消す | `down` / `clean` |

## 文書索引

手順・参照情報・検証記録を目的別に探すには [docs/README.md](docs/README.md) を参照する。

| 目的 | 文書 |
| --- | --- |
| 手順の背景やコマンド・環境変数を調べる | [参照情報](docs/reference/setup.md) |
| 過去の実施結果と未確認事項を確認する | [検証記録](docs/verification/setup.md) |
| CLI・マウント・起動停止の仕組みを調べる | [仕様書](docs/SPEC.md) |
| 手順書を編集する | [編集ガイド](docs/contributing.md#記法) |
| 実装を変更する | [CLAUDE.md](CLAUDE.md) |
