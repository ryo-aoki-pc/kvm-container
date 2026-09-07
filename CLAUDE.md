# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

qemu-kvm / libvirt / cockpit / firefox / virt-manager を 2 つの systemd コンテナ (podman, root) に収め、軽量なホストで VM を動かして
その画面をホストのデスクトップ (WSLg / GNOME Wayland) に表示するためのもの。
`kvm` (libvirt + qemu-kvm + cockpit、`--privileged --network host`) がサーバ、`kvm-gui` (firefox / virt-manager / virt-viewer、非特権、
ディスプレイのあるホストだけ) がデスクトップクライアントで、`kvm-gui` は共有した `/run/libvirt` のソケット経由で `kvm` の libvirt に接続する。
中身は **シェルスクリプト + Containerfile + systemd unit** だけで、ビルドシステムもテストスイートも無い。

## コマンド

```bash
./kvm.sh build [kvm|gui]  # podman build --target <role> -t localhost/kvm-container/<role>:latest (引数なしで両方)
./kvm.sh up [kvm|gui]     # 起動 (kvm モジュール、data/ の初期化、GUI 引数の組み立てを含む)。引数なしは kvm + (ディスプレイがあれば) gui
./kvm.sh down [kvm|gui]   # 停止・削除 (data/ は残る)。引数なしで両方 + /run/kvm-container の削除
./kvm.sh shell [kvm|gui]  # コンテナ内 root シェル (既定 kvm)
./kvm.sh logs [kvm|gui]   # kvm: kvm-libvirt-conf/virtqemud/cockpit.socket/gui-user の journal、gui: /var/log/gui.log + gui-user の journal
./kvm.sh virsh list       # virsh -c qemu:///system (kvm コンテナ)
KVM_HOST=headless ./kvm.sh up      # ホスト種別判定の上書き (auto|wsl|generic|headless)
COCKPIT_PORT=9092 ./kvm.sh up      # cockpit のポート変更 (既定 9091)
KVM_BRIDGE=br0 ./kvm.sh up         # ホストのブリッジを libvirt ネットワーク "bridged" として登録
```

検証は自動化されていない。変更後は README 末尾の「確認手順」(物理 AlmaLinux 10 GNOME / Windows + WSL2) を手で流す。
特に `sudo podman exec kvm systemctl is-system-running` と `sudo podman exec kvm-gui systemctl is-system-running` が
`running` (degraded ではない) であることは、Containerfile の unit マスク群が効いているかの実質的な回帰テストになっている。
`sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` はコンテナをまたぐ libvirt 接続の回帰テスト。

シェルスクリプトを触ったら最低限 `bash -n kvm.sh host/wsl.sh container/gui/gui container/common/gui-user-setup container/kvm/libvirt-conf` と、
入っていれば `shellcheck` をかける。

## 構造

3 層に分かれており、どの層を触るかで影響範囲が変わる。

1. **ホスト側 (`kvm.sh`, `host/wsl.sh`)** — `sudo podman` を呼ぶだけ。ホストのセッション環境
   (`XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`) を読んで `podman run` の
   引数 (`GUI_ARGS`) と、ホストユーザーの名前・uid/gid・パスワードハッシュ (`HOST_ARGS`) に変換する。
2. **イメージ (`Containerfile`)** — AlmaLinux 10 minimal + `microdnf` のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、
   両コンテナ共通のマスク) → `common` (テンプレートユーザー `admin` + `gui-user.service`) → `kvm` / `gui` (`podman build --target`)。
   パッケージは「依存で入らないものだけ」を、それが来るステージに列挙する方針 (コメントに依存関係の理由が書いてある)。
   unit の enable / mask もここ。
3. **コンテナ内 (`container/`)** — 起動時に自分を環境に合わせる部分。ロールごとのディレクトリに分かれる:
   `common/` は `gui-user-setup` (ユーザーの同期、両イメージ)、`kvm/` は `kvm-perms.service` (デバイス権限)、
   `kvm-libvirt-conf.service` + `libvirt-conf` (`/etc/libvirt` の設定)、`virtd-socket.conf` (ソケット権限の drop-in)、
   `cockpit-listen-generator` (listen アドレス)、`kvm-net-teardown.service` (終了処理)、`gui/` は `gui` (GUI アプリ起動)。

**ホスト → コンテナの値渡しは PID 1 の environ 経由**。`kvm.sh` が `podman run -e` で渡した値を、コンテナ内のスクリプトが
`tr '\0' '\n' </proc/1/environ` で読む (`HOST_USER` / `HOST_UID` / `HOST_GID` / `HOST_PASSWORD_HASH` / `COCKPIT_LISTEN` /
`HOST_RUNTIME_DIR`)。新しい値を渡すときはこの流儀に合わせる。パスワードハッシュだけは `--env-file` (コマンドラインに出さない) で
`kvm` にだけ渡す (`kvm-gui` は uid の一致だけが必要)。`container/gui/gui` は `runuser` の前にこれらを `unset` する。

ホスト種別ごとの差異は `kvm.sh` 側に `host_*` フック (`host_kvm_missing_hint` / `host_default_runtime_dir` /
`host_force_software_gl`) の汎用実装を置き、`host/wsl.sh` が WSL2 検出時だけ上書きする。WSL 固有の分岐を `kvm.sh` 本体に
書かない。

## 壊しやすい不変条件

以下はいずれも実際の不具合を踏んだ結果その形になっている。理由を理解せずに変えないこと (各ファイルのコメントに詳細)。

- **ホストの `XDG_RUNTIME_DIR` は読み取り専用で `/run/host-xdg-runtime` にマウントし、`/run/user/<uid>` には絶対にマウントしない。**
  マウントするとコンテナの logind がそのディレクトリを自分のものとして扱い、cockpit ログアウト時に
  `user-runtime-dir@.service` がホストの Wayland ソケットや session bus ごと削除してしまう。
  ソケットは `map_rt_path` で「コンテナ内から見た絶対パス」に変換して環境変数で渡す (unix ソケットは ro マウントでも connect できる)。
  runtime dir の外を指すシンボリックリンク (WSLg の `/mnt/wslg/...`) は、そのソケットファイルだけを同じパスに ro マウントする。
- **コンテナ内の `/run/user/<uid>` は logind が作る tmpfs**。`gui-user-setup` が GUI ユーザーを linger 登録するので
  起動時から session bus 付きで存在し、cockpit ログアウトでも消えない。
- **`/tmp/.X11-unix` は読み取り専用マウント**、かつ `/etc/tmpfiles.d/x11.conf` をマスク。コンテナの systemd-tmpfiles に
  ホストの X ソケットを消させないため。
- **コンテナをまたぐ libvirt 接続**: `/run/libvirt` はホストの `/run/kvm-container/libvirt` (tmpfs) を両コンテナにバインドマウントしたもので、
  `kvm.sh` が `kvm` の起動前に空にし `down` で消す。別コンテナからの接続ではデーモンが見る peer の pid が 0 になり polkit 認証が
  成立しないので、`auth_unix_rw = "none"` + ソケット権限 (`root:libvirt 0660`) で制御する。ソケット活性化では権限は
  `/etc/libvirt/*.conf` の `unix_sock_*` ではなく `virt*d.socket` の drop-in (`container/kvm/virtd-socket.conf`) で決まる。
  `libvirt` グループの gid は Containerfile の `base` 段で固定 (`LIBVIRT_GID`) し両イメージで揃える。`kvm` 側の `libvirtdbus`
  (cockpit-machines が使う libvirt-dbus のユーザー) もこのグループに入れる。`/etc/libvirt` は `data/etc-libvirt` で空のときしか
  seed されないので、この設定と qemu.conf の設定は `kvm-libvirt-conf.service` が起動ごとに冪等に書く (Containerfile で sed しない)。
- **`kvm-gui` は `--privileged` ではないが `--security-opt label=disable`**。SELinux Enforcing のホストで特権コンテナ (spc_t) が作った
  unix ソケットへ `connectto` し、ホストの runtime dir (`user_tmp_t`) を読むため。`/dev/dri` は `--device` で渡し、`gui` が
  `renderD*` を 0666 にする。非特権なので `/run/user/<uid>` の tmpfs マウントは失敗し、systemd がディレクトリ作成にフォールバックする (想定内)。
- **再ログイン後は `kvm-gui` だけ作り直す**: `start_gui` は `GUI_ARGS` のハッシュを `kvm.gui-session` ラベルに記録し、`up` のたびに
  ラベルと、コンテナ内で Wayland ソケット / XAUTHORITY がまだ存在するか (再ログインで古い runtime dir がマウントに残って中身だけ消える) を
  確かめて、違えば `rm -f` して作り直す。`firefox` / `virt-manager` / `viewer` は必ず `up` を経由する。
- **`--network host` の帰結** (両コンテナ): cockpit はホストで直接 listen するので `podman -p` は使えず、
  `cockpit-listen-generator` が `cockpit.socket` の `ListenStream` を書き換える。既定ポートは 9090 ではなく **9091**
  (AlmaLinux 10 のホストは自前の `cockpit.socket` で 9090 を使っていることが多い)。
  `iscsid.socket` / `iscsiuio.socket` は abstract unix ソケットがネットワーク名前空間に属しホストと衝突するためマスク、
  `NetworkManager.service` はホストの NIC を管理し始めるためマスク、`NetworkManager-wait-online.service` は
  podman の eth0 が online にならず 60 秒待って degraded になるためマスク。
  libvirt の `virbr0` はホスト上に作られるので、`kvm-net-teardown.service` が停止時に `net-destroy` する。
- **両コンテナの GUI/cockpit ユーザーはホストユーザーの写し**。イメージ (`common` 段) にはテンプレートユーザー `admin` (uid 1000) が入っていて、
  `gui-user-setup` が起動時にリネーム + uid/gid 変更 + (`kvm` では) パスワードハッシュ設定を行う (ホストの runtime dir が 0700 なので
  uid 一致が必要、cockpit はコンテナ内の `/etc/shadow` で認証する)。`kvm.sh` は root で実行させない。
- **`data/` はバインドマウントなのでイメージの内容が自動でコピーされない**。`prepare_data_dir` が空のときだけ
  `kvm` イメージで一時コンテナを起こして `cp -a` する (`--security-opt label=disable` が必要: data はユーザーのホーム配下 = `user_home_t`)。
  `data/var-libvirt` → `/var/lib/libvirt` (kvm rw、gui ro)、`data/etc-libvirt` → `/etc/libvirt` (kvm)、
  `data/home` → `/home/<ホストユーザー名>` (両方)。`data/` は git 管理外で root 所有。読み書きには `sudo` がいる。
- コンテナ名は `kvm` と `kvm-gui`、イメージ名は `localhost/kvm-container/{kvm,gui}` に固定 (変数名は `KVM_CONTAINER` / `GUI_CONTAINER` /
  `KVM_IMAGE` / `GUI_IMAGE`。`NAME` は WSL がホスト名に使うため避けている)。

## 慣習

- **コード内のコメントと実行時メッセージは英語、README とコミットメッセージは日本語** (コミット f5dd92c で統一済み)。
- `kvm.sh` の実行時出力は `>> ` が進捗、`!! ` が警告/エラー (stderr)。
- 挙動を変えたら README の該当表・確認手順と、`kvm.sh` 冒頭のヘッダコメント (`usage` が 2 行目から最初の非コメント行まで表示する)
  の両方を更新する。
- 新しいホスト依存の挙動は `host_*` フック経由で足す。新しい環境変数は `kvm.sh` 冒頭の既定値定義・ヘッダコメント・
  README の環境変数表の 3 箇所に反映する。
