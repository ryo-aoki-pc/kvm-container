# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

qemu-kvm / libvirt / cockpit / firefox / virt-manager を 1 つの systemd コンテナ (podman, root, `--privileged --network host`)
に同梱し、軽量なホストで VM を動かしてその画面をホストのデスクトップ (WSLg / GNOME Wayland) に表示するためのもの。
中身は **シェルスクリプト + Containerfile + systemd unit** だけで、ビルドシステムもテストスイートも無い。

## コマンド

```bash
./kvm.sh build            # podman build -t localhost/qemu-kvm-cockpit:latest
./kvm.sh up               # 起動 (kvm モジュール、data/ の初期化、GUI 引数の組み立てを含む)
./kvm.sh down             # 停止・削除 (data/ は残る)
./kvm.sh shell            # コンテナ内 root シェル
./kvm.sh logs             # /var/log/gui.log + virtqemud/cockpit.socket/gui-user の journal
./kvm.sh virsh list       # virsh -c qemu:///system
KVM_HOST=headless ./kvm.sh up      # ホスト種別判定の上書き (auto|wsl|generic|headless)
COCKPIT_PORT=9092 ./kvm.sh up      # cockpit のポート変更 (既定 9091)
KVM_BRIDGE=br0 ./kvm.sh up         # ホストのブリッジを libvirt ネットワーク "bridged" として登録
```

検証は自動化されていない。変更後は README 末尾の「確認手順」(物理 AlmaLinux 10 GNOME / Windows + WSL2) を手で流す。
特に `sudo podman exec kvm systemctl is-system-running` が `running` (degraded ではない) であることは、
Containerfile の unit マスク群が効いているかの実質的な回帰テストになっている。

シェルスクリプトを触ったら最低限 `bash -n kvm.sh host/wsl.sh container/gui container/gui-user-setup` と、
入っていれば `shellcheck` をかける。

## 構造

3 層に分かれており、どの層を触るかで影響範囲が変わる。

1. **ホスト側 (`kvm.sh`, `host/wsl.sh`)** — `sudo podman` を呼ぶだけ。ホストのセッション環境
   (`XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`) を読んで `podman run` の
   引数 (`GUI_ARGS`) と、ホストユーザーの名前・uid/gid・パスワードハッシュ (`HOST_ARGS`) に変換する。
2. **イメージ (`Containerfile`)** — AlmaLinux 10 minimal + `microdnf`。パッケージは「依存で入らないものだけ」を列挙する方針
   (コメントに依存関係の理由が書いてある)。unit の enable / mask もここ。
3. **コンテナ内 (`container/`)** — 起動時に自分を環境に合わせる部分。`gui-user-setup` (ユーザーの同期)、
   `kvm-perms.service` (デバイス権限)、`cockpit-listen-generator` (listen アドレス)、`kvm-net-teardown.service` (終了処理)、
   `gui` (GUI アプリ起動)。

**ホスト → コンテナの値渡しは PID 1 の environ 経由**。`kvm.sh` が `podman run -e` で渡した値を、コンテナ内のスクリプトが
`tr '\0' '\n' </proc/1/environ` で読む (`HOST_USER` / `HOST_UID` / `HOST_GID` / `HOST_PASSWORD_HASH` / `COCKPIT_LISTEN` /
`HOST_RUNTIME_DIR`)。新しい値を渡すときはこの流儀に合わせる。パスワードハッシュだけは `--env-file` (コマンドラインに出さない)、
`container/gui` は `runuser` の前にこれらを `unset` する。

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
- **`--network host` の帰結**: cockpit はホストで直接 listen するので `podman -p` は使えず、
  `cockpit-listen-generator` が `cockpit.socket` の `ListenStream` を書き換える。既定ポートは 9090 ではなく **9091**
  (AlmaLinux 10 のホストは自前の `cockpit.socket` で 9090 を使っていることが多い)。
  `iscsid.socket` / `iscsiuio.socket` は abstract unix ソケットがネットワーク名前空間に属しホストと衝突するためマスク、
  `NetworkManager.service` はホストの NIC を管理し始めるためマスク、`NetworkManager-wait-online.service` は
  podman の eth0 が online にならず 60 秒待って degraded になるためマスク。
  libvirt の `virbr0` はホスト上に作られるので、`kvm-net-teardown.service` が停止時に `net-destroy` する。
- **コンテナの GUI/cockpit ユーザーはホストユーザーの写し**。イメージにはテンプレートユーザー `admin` (uid 1000) が入っていて、
  `gui-user-setup` が起動時にリネーム + uid/gid 変更 + パスワードハッシュ設定を行う (ホストの runtime dir が 0700 なので
  uid 一致が必要、cockpit はコンテナ内の `/etc/shadow` で認証する)。`kvm.sh` は root で実行させない。
- **`data/` はバインドマウントなのでイメージの内容が自動でコピーされない**。`prepare_data_dir` が空のときだけ
  一時コンテナを起こして `cp -a` する (`--security-opt label=disable` が必要: data はユーザーのホーム配下 = `user_home_t`)。
  `data/var-libvirt` → `/var/lib/libvirt`、`data/etc-libvirt` → `/etc/libvirt`、`data/home` → `/home/<ホストユーザー名>`。
  `data/` は git 管理外で root 所有。読み書きには `sudo` がいる。
- コンテナ名は `kvm` 固定 (変数名は `CONTAINER`。`NAME` は WSL がホスト名に使うため避けている)。

## 慣習

- **コード内のコメントと実行時メッセージは英語、README とコミットメッセージは日本語** (コミット f5dd92c で統一済み)。
- `kvm.sh` の実行時出力は `>> ` が進捗、`!! ` が警告/エラー (stderr)。
- 挙動を変えたら README の該当表・確認手順と、`kvm.sh` 冒頭のヘッダコメント (`*)` ケースが `sed -n '2,20p'` で表示する
  usage) の両方を更新する。
- 新しいホスト依存の挙動は `host_*` フック経由で足す。新しい環境変数は `kvm.sh` 冒頭の既定値定義・ヘッダコメント・
  README の環境変数表の 3 箇所に反映する。
