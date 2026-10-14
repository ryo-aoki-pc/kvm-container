# qemu-kvm コンテナ (AlmaLinux 10)

導入・利用・更新は [AlmaLinux 10 の手順](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/almalinux-setup.md) / [Windows 11 の手順](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/windows-setup.md) に集約している。設定仕様・開発者向け操作・過去の検証・ロールバックはこのリポジトリで管理する。

移動先は[集約対応表](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/dev/consolidation-map.md)で確認する。


qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナ (`kvm` = サーバ、`kvm-gui` = デスクトップ側) に収め、
qemu も libvirt も入れていない軽量なホストで VM を動かして、その画面をホストのデスクトップ (GNOME Wayland) に表示する。
VM の作成・操作はコマンドライン (`./kvm.sh virt-install` / `./kvm.sh virsh`)、画面は virt-viewer (`./kvm.sh viewer`)。ブラウザや Web コンソールは使わない。
手順書は導入・VM の作成・利用・再ログイン後のシナリオと、変更後の確認を番号付きリストで載せている。検証結果は [検証記録](docs/verification/setup.md)、背景や実装の説明は [参照情報](docs/reference/setup.md) に分けている。
実装の仕様 (CLI・環境変数・マウント・起動/停止シーケンス・不変条件、図付き) は [docs/SPEC.md](docs/SPEC.md)、変更時の注意は [AGENTS.md](AGENTS.md)。

## 手順書


[AlmaLinux 10 の kvm-container 導入](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container-を導入する) → VM 作成 → VM 利用の順に行う。ブリッジ・削除・更新も同冊にある。[元の案内と開発者検査](docs/setup.md)・[ロールバック](docs/extra/setup.md)・[検証記録](docs/verification/setup.md)・[仕様](docs/SPEC.md)はこのリポジトリに残す。

## 記法


利用者向け手順は setup-notes の執筆規則に揃える。操作と必要な前提・中断・分岐・待機・危険・期待結果は正本、選定理由と仕様は `docs/reference/setup.md`・`docs/SPEC.md`、過去の実測は `docs/verification/setup.md` に置く。開発者検査は [docs/setup.md](docs/setup.md#変更後に確認する)、取り消しは [docs/extra/setup.md](docs/extra/setup.md)。日本語文書・コミット、英語のコードコメント・実行メッセージを使う。
