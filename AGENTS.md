# AGENTS.md

このリポジトリで作業するコーディングエージェント（Claude Code・Codex・Grok Build・Antigravity CLI）への指示。Claude Code は CLAUDE.md の `@AGENTS.md` で、Codex・Grok Build・Antigravity CLI はこのファイルを直接読む。

利用者への回答・質問・報告は、常に日本語で書く（コードのコメントなどの言語は、このファイルのほかの決まりに従う）。

## 導入手順の正本

導入・利用・更新の手順は、setup-notes の [virtual-machines.md](https://github.com/ryo-aoki-pc/setup-notes/blob/main/docs/virtual-machines.md#kvm-container) の「kvm-container」とその子の項にある (AlmaLinux 10 だけ。2026-10-15 に almalinux-setup.md から移った)。このリポジトリには置かない。Windows 11 の手順は無い。

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

検証は自動化されていない。変更後は `docs/dev/check.md` の手順 (静的検査 / 物理 AlmaLinux 10 GNOME / ディスプレイ無し / VM のライフサイクル) を
手で流す (期待結果は `docs/SPEC.md` 9 章)。利用者の確認は正本の「kvm-container を導入する」の最終手順。
特に `sudo podman exec kvm systemctl is-system-running` と `sudo podman exec kvm-gui systemctl is-system-running` が
`running` (degraded ではない) であることは、Containerfile の unit マスク群が効いているかの実質的な回帰テストになっている。
`sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` はコンテナをまたぐ libvirt 接続の回帰テスト。

シェルスクリプトを触ったら最低限 `bash -n` と `shellcheck` を
`kvm.sh container/gui/gui container/common/gui-user-setup container/kvm/libvirt-conf`
にかける (指摘ゼロを保つ。ホストに shellcheck が無ければ `gui` イメージの使い捨てコンテナで実行できる。`docs/dev/check.md` の「静的検査」)。

## 構造

3 層に分かれており、どの層を触るかで影響範囲が変わる。現状実装の仕様書 (図付き) は `docs/SPEC.md`。

ドキュメントの置き場所は、下の「文書の置き場所」。手順の書き方は setup-notes の `docs/dev/writing-rules.md` に従う。

1. **ホスト側 (`kvm.sh`)** — `sudo podman` を呼ぶだけ。ホストのセッション環境
   (`XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY`) を読んで `podman run` の
   引数 (`GUI_ARGS`) と、ホストユーザーの名前・uid/gid (`HOST_ARGS`) に変換する。
1. **イメージ (`Containerfile`)** — AlmaLinux 10 minimal + `microdnf` のマルチステージ: `base` (systemd、固定 gid の `libvirt` グループ、
   両コンテナ共通のマスク) → `common` (`gui-user.service` = GUI ユーザーの起動時作成) → `kvm` / `gui` (`podman build --target`)。
   パッケージは「依存で入らないものだけ」を、それが来るステージに列挙する方針 (コメントに依存関係の理由が書いてある)。
   unit の enable / mask もここ。
1. **コンテナ内 (`container/`)** — 起動時に自分を環境に合わせる部分。ロールごとのディレクトリに分かれる:
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
- 挙動を変えたら、setup-notes の正本の手順・README の「導入」の表・参照情報 (`docs/reference/setup.md`)・変更後の確認 (`docs/dev/check.md`)・`kvm.sh` 冒頭のヘッダコメント (`usage` が 2 行目から最初の非コメント行まで表示する)・`docs/SPEC.md` の該当節 (表・図) を同期する。検証記録 (`docs/verification/setup.md`) の既存本文は保持し、新しい検証結果を追記する。
- 新しい環境変数は `kvm.sh` 冒頭の既定値定義・ヘッダコメント・
  `docs/reference/setup.md`「環境変数」の表の 3 箇所に反映する。

## 文書の置き場所

- 導入・利用・更新の手順は正本に置き、README の「導入」の表から正本の項へ直接リンクする (手順書の先頭やカテゴリの見出しへはリンクしない)。執筆規則は setup-notes の `docs/dev/writing-rules.md`
- `docs/extra/setup.md` はロールバックと注意点、`docs/reference/setup.md` は正本の各手順の背景と選定理由、`docs/verification/setup.md` は検証記録 (環境・日付・対象コミット・実出力・未確認事項)、`docs/SPEC.md` は実装の仕様、`docs/dev/check.md` は変更後の確認の手順
- 参考資料の見出しは `### <項> / 手順 N: 補足: <題>` にし、手順番号は正本の項の番号にする。正本の手順番号が変わったら付け替える
- 案内だけになった文書・節は消し、旧パスと移動先を setup-notes の集約対応表に足す。消すときは参照元のリンクを付け替える (検証記録は、削除前の固定コミットの URL にする)
- 検証記録の既存の本文・手順番号・出力は変えない。新しい対象版・環境・範囲は追記する

## 共同作業の規則

このリポジトリでは、Claude Code・Codex・Grok Build・Antigravity CLI が同じ規則で作業する。分担と `main` への取り込みは人が決める。

- 起動された worktree（作業ディレクトリ）の中だけでファイルを変える。ほかの worktree のファイルは変えない
- 今のブランチにだけコミットする。`main` にはコミットも push もしない
- 頼まれた範囲のファイルだけを変える。範囲の外を変えるときは、変える前に理由を書いて確かめる
- 終わったら、テストとリンターを通してから、目的ごとにコミットする。通らなければコミットせずに、結果を報告する
- コミットしたら、今のブランチを push し、`main` への Pull Request を作る（既にあれば足す）。`main` への取り込み（マージ）とブランチの削除は人が行う。今のブランチに `main` を取り込むのは、頼まれたときと、Pull Request が競合したときだけ
- 秘密情報（`.env`・鍵・トークン・パスワード）を読まない・書かない・出力しない
- レビューを頼まれたら、ファイルを変えずに、指摘を「重大度・場所（ファイル:行）・理由・直し方」で挙げる
- ほかの担当の変更は、`git diff main...agent/codex` のように git で読む（ほかの worktree へ移らない）
