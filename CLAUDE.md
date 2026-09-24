# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

qemu-kvm / libvirt / virt-viewer を 2 つの systemd コンテナ (podman, root) に収め、軽量なホストで VM を動かして
その画面をホストのデスクトップ (GNOME Wayland) に表示するためのもの。VM の作成・操作はコマンドライン
(`./kvm.sh virt-install` / `./kvm.sh virsh`)、画面は `./kvm.sh viewer` (virt-viewer)。ブラウザや Web コンソールは使わない。
`kvm` (libvirt + qemu-kvm + virt-install、`--privileged --network host`) がサーバ、`kvm-gui` (virt-viewer、非特権、
ディスプレイのあるホストだけ) がデスクトップクライアントで、`kvm-gui` は共有した `/run/libvirt` のソケット経由で `kvm` の libvirt に接続する。
中身は **シェルスクリプト + Containerfile + systemd unit** だけで、ビルドシステムもテストスイートも無い。

## コマンド

```bash
./kvm.sh build [kvm|gui]  # podman build --target <role> -t localhost/kvm-container/<role>:latest (引数なしで両方)
./kvm.sh up [kvm|gui]     # 起動 (kvm モジュール、data/ の初期化、GUI 引数の組み立てを含む)。引数なしは kvm + (ディスプレイがあれば) gui
./kvm.sh down [kvm|gui]   # 停止・削除 (data/ は残る)。引数なしで両方 + /run/kvm-container の削除
./kvm.sh shell [kvm|gui]  # コンテナ内 root シェル (既定 kvm)
./kvm.sh logs [kvm|gui]   # kvm: kvm-libvirt-conf/virtqemud/gui-user の journal、gui: /var/log/gui.log + gui-user の journal
./kvm.sh virt-install ... # virt-install --connect qemu:///system (kvm コンテナ)。VM の作成
./kvm.sh virsh list       # virsh -c qemu:///system (kvm コンテナ)
./kvm.sh viewer [VM]      # virt-viewer (kvm-gui コンテナ、ホストの画面)。VM 名を省くと一覧から選ぶダイアログ
KVM_HOST=headless ./kvm.sh up      # 画面があっても GUI コンテナを起動しない (auto|headless)
KVM_BRIDGE=br0 ./kvm.sh up         # ホストのブリッジを libvirt ネットワーク "bridged" として登録
```

検証は自動化されていない。変更後は `docs/setup.md` の付録「確認手順」(物理 AlmaLinux 10 GNOME / ディスプレイ無し) と
`docs/vm.md` の付録「VM のライフサイクルの確認手順」を手で流す (期待結果は `docs/SPEC.md` 9 章)。利用者級の確認は `docs/setup.md` 手順 5。
特に `sudo podman exec kvm systemctl is-system-running` と `sudo podman exec kvm-gui systemctl is-system-running` が
`running` (degraded ではない) であることは、Containerfile の unit マスク群が効いているかの実質的な回帰テストになっている。
`sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` はコンテナをまたぐ libvirt 接続の回帰テスト。

シェルスクリプトを触ったら最低限 `bash -n` と `shellcheck` を
`kvm.sh container/gui/gui container/common/gui-user-setup container/kvm/libvirt-conf`
にかける (指摘ゼロを保つ。ホストに shellcheck が無ければ `gui` イメージの使い捨てコンテナで実行できる。`docs/SPEC.md` 9.1 節)。

## 構造

3 層に分かれており、どの層を触るかで影響範囲が変わる。現状実装の仕様書 (図付き) は `docs/SPEC.md`。

ドキュメントの構成: `README.md` は手順書の一覧 (用途 / 検証環境) と記法だけ。手順は `docs/setup.md` (導入。他 3 本の前提) / `docs/vm.md` /
`docs/desktop.md` / `docs/bridge.md`。各手順書は setup-notes と同じ骨格 (`## 実施手順` → 手順 0 の変数ブロック (必須は 1 変数 1 ブロック、
任意は 1 ブロック、`${VAR:?}` で空を止める、bash ブロックに `<...>` を置かない) → 任意節 → `## ロールバック` → `## 補足`: 対象と検証環境 /
実施前の状態 / 選択した方針 / 手順の補足 / 完了時点の状態 / 注意点 / 参照 / 付録)。説明が `docs/SPEC.md` にある事項は節番号で参照する。
検証していないことを「動く」と書かず、検証範囲が変わったら手順書の「対象と検証環境」の状態行と `README.md` の一覧を更新する。
`kvm.sh` の実行時メッセージを `docs/SPEC.md` が引用している箇所 (2.4 節) は原文のまま揃える。

1. **ホスト側 (`kvm.sh`)** — `sudo podman` を呼ぶだけ。ホストのセッション環境
   (`XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`) を読んで `podman run` の
   引数 (`GUI_ARGS`) と、ホストユーザーの名前・uid/gid (`HOST_ARGS`) に変換する。
2. **イメージ (`Containerfile`)** — AlmaLinux 10 minimal + `microdnf` のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、
   両コンテナ共通のマスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui` (`podman build --target`)。
   パッケージは「依存で入らないものだけ」を、それが来るステージに列挙する方針 (コメントに依存関係の理由が書いてある)。
   unit の enable / mask もここ。
3. **コンテナ内 (`container/`)** — 起動時に自分を環境に合わせる部分。ロールごとのディレクトリに分かれる:
   `common/` は `gui-user-setup` (GUI ユーザーの作成、両イメージ)、`kvm/` は `kvm-perms.service` (デバイス権限)、
   `kvm-libvirt-conf.service` + `libvirt-conf` (`/etc/libvirt` の設定)、`virtd-socket.conf` (ソケット権限の drop-in)、
   `kvm-net-teardown.service` (終了処理)、`libvirt-guests` (停止時の VM シャットダウン設定)、`gui/` は `gui` (GUI アプリ起動)。

**ホスト → コンテナの値渡しは PID 1 の environ 経由**。`kvm.sh` が `podman run -e` で渡した値を、コンテナ内のスクリプトが
`tr '\0' '\n' </proc/1/environ` で読む (`HOST_USER` / `HOST_UID` / `HOST_GID` / `HOST_RUNTIME_DIR`)。新しい値を渡すときはこの流儀に合わせる。
パスワードは渡さない (コンテナにログインするものは無く、GUI ユーザーはロックされたまま)。`container/gui/gui` は `runuser` の前にこれらを `unset` する。

ホスト種別の抽象化は持たない。対応ホストは AlmaLinux 10 (GNOME あり / 画面なし) だけで、画面の有無は `have_display`
(`KVM_HOST=headless` か、`DISPLAY` / `WAYLAND_DISPLAY` の有無) だけで決まる。ホスト依存の分岐が要るときは `kvm.sh` 本体に直接書く。

## 壊しやすい不変条件

以下はいずれも実際の不具合を踏んだ結果その形になっている。理由を理解せずに変えないこと (各ファイルのコメントに詳細)。

- **ホストの `XDG_RUNTIME_DIR` は読み取り専用で `/run/host-xdg-runtime` にマウントし、`/run/user/<uid>` には絶対にマウントしない。**
  マウントするとコンテナの logind がそのディレクトリを自分のものとして扱い、`user-runtime-dir@.service` の停止処理で
  ホストの Wayland ソケットや session bus ごと削除してしまう (cockpit を載せていた頃に、そのログアウトで実際に起きた)。
  ソケットは `map_rt_path` で「コンテナ内から見た絶対パス」に変換して環境変数で渡す (unix ソケットは ro マウントでも connect できる)。
  runtime dir の外を指すシンボリックリンクは、そのソケットファイルだけを同じパスに ro マウントする。
- **コンテナ内の `/run/user/<uid>` は logind が作る tmpfs**。`gui-user-setup` が GUI ユーザーを linger 登録するので
  起動時から session bus 付きで存在する (GTK アプリが前提にする)。
- **`/tmp/.X11-unix` は読み取り専用マウント**、かつ `/etc/tmpfiles.d/x11.conf` をマスク。コンテナの systemd-tmpfiles に
  ホストの X ソケットを消させないため。
- **コンテナをまたぐ libvirt 接続**: `/run/libvirt` はホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナにバインドマウントしたもので、
  `kvm.sh` が `kvm` の起動前に空にし `down` で消す。別コンテナからの接続ではデーモンが見る peer の pid が 0 になり polkit 認証が
  成立しないので、`auth_unix_rw = "none"` + ソケット権限 (`root:libvirt 0660`) で制御する。ソケット活性化では権限は
  `/etc/libvirt/*.conf` の `unix_sock_*` ではなく `virt*d.socket` の drop-in (`container/kvm/virtd-socket.conf`) で決まる。
  `libvirt` グループの gid は Containerfile の `base` 段で固定 (`LIBVIRT_GID`) し両イメージで揃える。`/etc/libvirt` は `data/etc-libvirt` で空のときしか
  seed されないので、この設定と qemu.conf の設定は `kvm-libvirt-conf.service` が起動ごとに冪等に書く (Containerfile で sed しない)。
- **`kvm-gui` は `--privileged` ではないが `--security-opt label=disable`**。SELinux Enforcing のホストで特権コンテナ (spc_t) が作った
  unix ソケットへ `connectto` し、ホストの runtime dir (`user_tmp_t`) を読むため。`/dev/dri` は `--device` で渡し、`gui` が
  `renderD*` を 0666 にする。非特権なので `/run/user/<uid>` の tmpfs マウントは失敗し、systemd がディレクトリ作成にフォールバックする (想定内)。
- **再ログイン後は `kvm-gui` だけ作り直す**: `start_gui` は `GUI_ARGS` のハッシュを `kvm.gui-session` ラベルに記録し、`up` のたびに
  ラベルと、コンテナ内で Wayland ソケット / XAUTHORITY がまだ存在するか (再ログインで古い runtime dir がマウントに残って中身だけ消える) を
  確かめて、違えば `rm -f` して作り直す。`viewer` は必ず `up` を経由する。
- **`--network host` の帰結** (両コンテナ): libvirt の `virbr0` はホスト上に作られるので、`kvm-net-teardown.service` が停止時に `net-destroy` する。
  `iscsid.socket` / `iscsiuio.socket` は abstract unix ソケットがネットワーク名前空間に属しホストと衝突するためマスク。
  `NetworkManager.service` (ホストの NIC を管理し始める) と `NetworkManager-wait-online.service` (podman の eth0 が online にならず
  60 秒待って degraded になる) は今のパッケージ構成では入らないが、依存で入ったときのためにマスクしたままにする。
  `kvm-gui` も `--network host` (virt-viewer が VM の VNC に届くため) だが、listen するものは無い。
- **`kvm` の停止では VM を先にシャットダウンする**。`libvirt-guests.service` が無いとコンテナの systemd が qemu の scope をすぐ止め、
  VM は電源断と同じ状態になる (次の起動で XFS のジャーナル復旧が走ったのを確認済み)。`container/kvm/libvirt-guests` で
  `ON_SHUTDOWN=shutdown` / `ON_BOOT=ignore` / `SHUTDOWN_TIMEOUT=120`、`kvm-net-teardown.service` は `Before=libvirt-guests.service`、
  `kvm.sh` の `KVM_STOP_TIMEOUT` (`podman rm -t`) は `SHUTDOWN_TIMEOUT` より長くする。
- **両コンテナの GUI ユーザーはホストユーザーの写し**。イメージには一般ユーザーを焼き込まず、`gui-user-setup` が起動時に
  ホストユーザーの名前・uid/gid でユーザーを作り、そのイメージにあるグループ (`libvirt` / `video` / `render`) に入れる
  (ホストの runtime dir が 0700 なので uid 一致が必要)。パスワードは設定しない。`kvm.sh` は root で実行させない。
- **`data/` はバインドマウントなのでイメージの内容が自動でコピーされない**。`prepare_data_dir` が空のときだけ
  `kvm` イメージで一時コンテナを起こして `cp -a` する (`--security-opt label=disable` が必要: data はユーザーのホーム配下 = `user_home_t`)。
  `data/var-libvirt` → `/var/lib/libvirt` (kvm)、`data/etc-libvirt` → `/etc/libvirt` (kvm)、
  `data/home` → `/home/<ホストユーザー名>` (両方)。`data/` は git 管理外で root 所有。読み書きには `sudo` がいる。
- コンテナ名は `kvm` と `kvm-gui`、イメージ名は `localhost/kvm-container/{kvm,gui}` に固定 (変数名は `KVM_CONTAINER` / `GUI_CONTAINER` /
  `KVM_IMAGE` / `GUI_IMAGE`。`NAME` は他の用途と紛れるため避けている)。

## 慣習

- **コード内のコメントと実行時メッセージは英語、README・docs/*.md とコミットメッセージは日本語** (コミット f5dd92c で統一済み)。
- `kvm.sh` の実行時出力は `>> ` が進捗、`!! ` が警告/エラー (stderr)。
- 挙動を変えたら該当する手順書 (`docs/setup.md` の使い方の基本・補足・付録、`docs/vm.md` の付録など。対象環境が変わるときは
  `README.md` の一覧も) と、`kvm.sh` 冒頭のヘッダコメント (`usage` が 2 行目から最初の非コメント行まで表示する) の両方と、`docs/SPEC.md` の該当節 (表・図) を更新する。
- 新しい環境変数は `kvm.sh` 冒頭の既定値定義・ヘッダコメント・
  `docs/setup.md` 補足「環境変数」の表 (と `README.md` 記法の一覧行) の 3 箇所に反映する。
