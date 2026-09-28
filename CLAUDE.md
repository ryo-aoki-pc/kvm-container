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

検証は自動化されていない。変更後は `docs/setup.md` の付録の確認手順 (物理 AlmaLinux 10 GNOME / ディスプレイ無し / VM のライフサイクル) を
手で流す (期待結果は `docs/SPEC.md` 9 章)。利用者級の確認は `docs/setup.md` 手順 9。
特に `sudo podman exec kvm systemctl is-system-running` と `sudo podman exec kvm-gui systemctl is-system-running` が
`running` (degraded ではない) であることは、Containerfile の unit マスク群が効いているかの実質的な回帰テストになっている。
`sudo podman exec kvm-gui runuser -u $USER -- virsh -c qemu:///system list` はコンテナをまたぐ libvirt 接続の回帰テスト。

シェルスクリプトを触ったら最低限 `bash -n` と `shellcheck` を
`kvm.sh container/gui/gui container/common/gui-user-setup container/kvm/libvirt-conf`
にかける (指摘ゼロを保つ。ホストに shellcheck が無ければ `gui` イメージの使い捨てコンテナで実行できる。`docs/SPEC.md` 9.1 節)。

## 構造

3 層に分かれており、どの層を触るかで影響範囲が変わる。現状実装の仕様書 (図付き) は `docs/SPEC.md`。

ドキュメントの構成: `README.md` は手順書の節の一覧 (節 / 用途 / 使うサブコマンド。検証範囲の列は置かない) と記法だけ。手順書は `docs/setup.md` の 1 本で、
`## 実施手順` の手順 1〜9 が導入、手順 10〜17 が VM の作成と操作。骨格は setup-notes と同じ (`## 実施手順` → 任意節 (見出しの末尾に「(任意)」: ブリッジ・アクティビティ) →
使い方の基本 / 表示先が変わったとき / VM を削除する / 更新 → `## ロールバック` → `## 補足`: 対象と検証環境 / 実施前の状態 / 選択した方針 /
任意節の補足や複数の手順にまたがる説明 (「環境変数」「ブリッジにつなぐときの補足」「アクティビティから起動するときの補足」「VM を削除するときの注意」) /
完了時点の状態 / 注意点 / 参照 / 付録)。任意節の補足の小見出しは、本体の `### 注意点` などとアンカーが重ならない名前にする。
状態の要約 (補足の状態行を変えたらここも直す): 導入は物理 AlmaLinux 10.2 + GNOME とディスプレイ無しのホスト (aarch64、`up` 〜 `down`) で本実行済み、
VM のライフサイクルは物理 GNOME で本実行済み (手順 12 の `--cdrom` 形は未再実行、ディスプレイ無しでは未検証)、アクティビティの節は旧ランチャーでだけ、ブリッジの節は未検証。

手順は `## 実施手順` の中の番号付きリスト (マーカーはすべて `1.`、番号付き見出しは使わない) で、手順 1 が変数ブロック (必須は 1 変数 1 ブロックで、説明は
「変数を設定する (`ISO` は必ず値を入れる)。」。任意は 1 ブロックで末尾に読み戻し、`${VAR:?}` で空を止める、bash ブロックに `<...>` を置かない。変える必要の無い値
(固定の URL・パス、`${USER}` などの言い換え) は変数にせずコマンドに直接書く。任意節だけで使う値 (ブリッジの `NIC` など) はその節の手順 1 に置く)。
新しいシェルで貼り直す変数のブロックには、読み戻し以外のコマンドを足さない (確認は次の手順に置く)。例外は手順 1 の最後の `[ ! -d "${REPO}" ] || cd "${REPO}"` だけ
(貼り直しても害が無く、以降の `./kvm.sh` を相対パスで動かすため)。各手順は setup-notes の CLAUDE.md「手順の形」と同じく、1 行の説明 (太字にしない 1 文で「〜する。」、
目安は 60 字まで。実行する場所・条件・前提もここ) → コマンドのブロック (間に何も挟まない。並べてよいのは 1 変数だけのブロックの後にほかのブロック 1 つ。言語は bash) →
確認の箇条書き (段落・表・出力例を置かない。出力は判定に要る 1 行だけ引く) → `<details><summary>補足: …</summary>` の折り畳み (手順の最後に 1 つまで。
中は見出しを使わず太字の段落にし、貼る必要のあるコマンドは置かない。出力例もここ)、の順に置く。
止める箇所 (下記)・別の端末・条件付きの操作・別々の操作や確認で手順を分け、止める手順の最後の箇条書きは「**次の手順は、〜してから貼る**」にする。
条件付きの手順は条件を 1 行の説明に書き (「〜ときだけ、」。1 つの条件が複数の手順にかかるなら、それぞれに)、判定する手順に「〜なら、この節の手順 N は飛ばす」と書く
(代わりに行う手順は「(この節の手順 N の代わりに)」、元に戻す手順は最後に置いて「元に戻すときは、」で始める)。
つなぎの文 (「値を読み戻す」「次に〜を確かめる」) だけで分かれていたブロックは、コマンドを変えずに 1 つにまとめる。
コマンドの無い操作 (アクティビティからの起動、ウィンドウの操作、同じ手順書の別の手順に戻ること) は直前の手順の箇条書きに書く
(独立した手順にするのは、前に手順が無いとき、別の手順書に任せるとき、最後に別のマシンから確かめるときだけ)。

`## 実施手順` の後ろの節 (任意節・更新・ロールバック・VM を削除する など) も、貼るコマンドがあれば同じ形の番号付きリストにする
(節ごとに 1 から。リード → リスト → `---` の順で、リストの後ろには何も置かない。表だけの「使い方の基本」はそのまま。`##` 見出しは変えない)。
任意節は `## 実施手順` のリードの「手順の後:」から案内し、途中に挟むもの (ブリッジの節) は「手順 9 の後に…の手順 1〜8 を行ってから手順 10 に進む」と書く。
任意節を元に戻す手順は `## ロールバック` に「〜の節を通したときだけ、」の手順として置く (リードは「上から順に、通した節の分だけ実行する」)。
単に「手順 N」と書いたら `## 実施手順` の手順で、後ろの節の手順は節の中では「この節の手順 N」、外からは「`[ロールバック](#ロールバック)の手順 N`」
(補足・付録からは「ブリッジの節の手順 N」「アクティビティの節の手順 N」) と書く。手順へのリンクは `[手順 N](#実施手順)` で、`## 実施手順` の中ではリンクにしない
(「手順 N の補足」「この手順の補足」と書く)。「次のブロック」のような位置の言い方はしない。
手順を分けたりまとめたりしたら、本文・補足・付録・`> [!IMPORTANT]`・`README.md`・`docs/SPEC.md`・この CLAUDE.md の番号と参照を付け替え、
検証の記録 (状態行・付録) は同じコマンドを指すように付け替えて範囲を広げない。
`## 実施手順` の直下は `> [!IMPORTANT]` (実行する場所とユーザー・ホストの sudo の前提・対話入力のある手順・別の場所で行う操作。複数の節にまたがる注意もここ) と読み方の箇条書き。
本実行していない任意節 (ブリッジの節、現行エントリのアクティビティの節) は、節のリードの箇条書きに検証範囲を書く (アラートにしない)。

表現の規則も setup-notes (8835dd5) に揃える: 手順の本文は「操作 → 確認」の箇条書き (1 項目に 1 つの事実で、末尾に「。」を付けない。理由・実測は折り畳みへ)、
リードや補足も含めて 150 字を超える段落を残さない (「選択した方針」「注意点」も箇条書きに割る)、アラートは本文の最上位だけ
(番号付きリストや `<details>` の中は GitHub が描画しない。手順の中の注意は `- **注意**: …`)。アラートの使い分けは `[!IMPORTANT]` = 実施手順のリードの前提、
`[!WARNING]` = 手順の外の節で事故につながる注意、`[!CAUTION]` = 取り戻せない削除 (`clean`、`undefine --storage`) をする手順のある節のリード
(手順を名指しし、その手順の 1 行の説明にも「(取り戻せない)」。`uninstall-desktop` のような軽い削除には付けない)、`[!NOTE]` = 補足「対象と検証環境」の注記。
`[!TIP]` は使わず、アラートは 1 文書 5 個まで、アラート同士を空行だけで続けて置かない。補足の状態行は入れ子の箇条書き、`**` を約物に接して閉じない。
付録 (最初の `### 付録` から後) は検証記録なので書き直さない (未確認事項の更新と、手順番号の付け替えは可)。未確認事項は付録の中の `#### 未確認事項` に置く。
括弧は setup-notes の全角には揃えず、半角の `(…)` (前に空白) のままにする。

**上から順に貼るだけで通る**ことを保つ: clone も `docs/setup.md` の手順に含め、画面の有無などの分岐は読者に選ばせずブロックの中で判定する
(`[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || …`、`sudo podman container exists kvm-gui`)。手順書はホストの `sudo` がパスワードを聞かない前提で書く
(sudoers の設定は読者の責任で、書き方は載せない。前提は `docs/setup.md` の「実施前の状態」に書く)。手順を分けるのは
sudo 以外の理由 (ビルド・`up` / `down` / `cp` の完了待ち、`[y/N]` の応答待ち、ssh の切断、ウィンドウが開く、目視の確認) があるときだけにする。
説明が `docs/SPEC.md` にある事項は節番号で参照する。
検証していないことを「動く」と書かず、検証範囲が変わったら補足の状態行と、この欄の状態の要約を合わせて直す (`README.md` には検証範囲を書かない)。
`kvm.sh` の実行時メッセージを `docs/SPEC.md` (2.4 節) と `docs/setup.md` (ブリッジの節とその補足) が引用している箇所は原文のまま揃える。

1. **ホスト側 (`kvm.sh`)** — `sudo podman` を呼ぶだけ。ホストのセッション環境
   (`XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` / `PULSE_SERVER`) を読んで `podman run` の
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
- 挙動を変えたら該当する手順書 (`docs/setup.md` の該当する手順・使い方の基本・補足・付録。対象環境や検証範囲が変わるときは補足の状態行と、
  上の「ドキュメントの構成」の状態の要約も) と、`kvm.sh` 冒頭のヘッダコメント (`usage` が 2 行目から最初の非コメント行まで表示する) の両方と、`docs/SPEC.md` の該当節 (表・図) を更新する。
- 新しい環境変数は `kvm.sh` 冒頭の既定値定義・ヘッダコメント・
  `docs/setup.md` 補足「環境変数」の表 (と `README.md` 記法の一覧行) の 3 箇所に反映する。
