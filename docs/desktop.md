# アクティビティから Virt Viewer を起動する手順 (GNOME / `kvm.sh install-desktop`)

## 実施手順

> [!IMPORTANT]
> - **GNOME にログインした端末で、`sudo` を付けずに一般ユーザーとして実行する**。`install-desktop` は root だと `!! run this without sudo` で止まる
> - **前提は[導入](setup.md)を通してあること**。`gui` イメージは無くてもよい (手順 3 の `install-desktop` が自分でビルドする。時間がかかる)
> - **パスワード無しの `sudo podman` は、先に自分で sudoers に設定しておく**。書き方は本書では扱わず、手順 2 で確かめるだけ (権限上の意味は [SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項))
> - **手順 4 の途中で、GNOME のアクティビティから起動する操作がある**。手順 3・4 は、sudo のタイムスタンプが切れていればパスワードを聞かれる

- 手順 1 で変数を設定したシェルで、上から順にコードブロックを貼る
- 各手順の末尾の「補足」(折り畳み) と後半の[補足](#補足)は、実行するだけなら読まなくてよい。折り畳みの中のブロックも貼らなくてよい
- できあがると、GNOME のアクティビティで「Virt Viewer」を検索し、クリックで起動できる (デスクトップにアイコンは置かない)。起動すると VM を一覧から選ぶダイアログが出る
- 手順の後: 戻すときは[ロールバック](#ロールバック)。VM の作成・操作は [vm.md](vm.md)

> [!WARNING]
> **現行の Virt Viewer エントリで本書を通した記録は無い** ([対象と検証環境](#対象と検証環境))。
>
> - 仕組み (`install-desktop` → アクティビティから `launch` → `uninstall-desktop`) は、旧 firefox / virt-manager のランチャーで通した (PR #15)
> - 手順 4 の確認のブロックは本実行していない (手順 1・2 は `0cab212` で実行した)

1. **変数を設定する**

   - **編集するものは無い**。clone 先が `~/kvm-container` 以外のときだけ `REPO` を変える
   - **新しいシェルを開いたら** (SSH を張り直したあとも)、先にこのブロックを貼り直す。最後の行でリポジトリ直下に移る

   ```bash
   REPO=~/kvm-container   # このリポジトリを clone した場所 (ホームディレクトリ配下)。<REPO>
   printf 'REPO = %s\n' "${REPO}"
   cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ls -l kvm.sh
   ```

   - `kvm.sh` の行が出ればよい。見つからなければ `REPO` を直して貼り直す

   <details>
   <summary>補足: 変数について</summary>

   `REPO` は `install-desktop` を実行する場所を指すだけ。`.desktop` に埋まるのは `kvm.sh` が `cd "$(dirname "$0")"` したあとの `$PWD/kvm.sh`。`REPO` をシンボリックリンク経由で書くとそのリンクのパスが埋まる (bash の `cd` は論理パスを保つ) が、リンクが残る限り動く。

   </details>

1. **パスワード無しの sudo podman を確かめる**

   ```bash
   sudo -k; sudo -n podman ps >/dev/null && echo 'passwordless sudo podman: ok'
   ```

   - `passwordless sudo podman: ok` と出れば通っている
   - `sudo: a password is required` と出たら、sudoers を整えてからこのブロックを貼り直す (書き方は本書では扱わない)
   - 通らないまま手順 3 に進んでも配置はできるが、アクティビティからの起動は失敗する (通知で知らされる)

   <details>
   <summary>補足: パスワード無しの sudo podman</summary>

   - アクティビティから起動したプロセスには端末が無く、sudo のパスワードを入力できない。そのためランチャーが呼ぶ `kvm.sh launch` は `sudo -n podman exec kvm-gui gui virt-viewer` を実行する
   - `sudo -k` は sudo のタイムスタンプを消す。直前に対話的な `sudo` を通していると、そのタイムスタンプで `sudo -n` が通ってしまい NOPASSWD の有無を見誤るため、先に消してから `sudo -n` を試す。端末の無いプロセスでは既定 (`timestamp_type=tty`) の sudo タイムスタンプは使えないはずなので、この形が実際の起動条件に近い (未検証)
   - NOPASSWD が無いまま起動すると、`launch` は `sudo -n` のエラー出力に `password` を含むことを見て、通知に `could not start virt-viewer: ... configure passwordless sudo for podman (launch runs sudo -n without a terminal)` と出す
   - コンテナが起動していないときは、通知で `check that the GUI container is running (./kvm.sh up)` と `./kvm.sh up` を案内する。**`launch` は `./kvm.sh viewer` と違って `up` を経由しない** ので、コンテナが止まっていれば自分で `./kvm.sh up` する
   - 通知は `notify-send` (無ければ `zenity`、どちらも無ければ stderr のみ)。経路の図は [SPEC.md 4.7 節](SPEC.md#47-デスクトップ統合-activities-からの起動)

   </details>

1. **ランチャーを配置する**

   ```bash
   cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh install-desktop
   ```

   - `gui` イメージが無ければ、先に `>> building localhost/kvm-container/gui ...` でビルドが走る
   - 最後に `>> installed: ...` と `>> search for "Virt Viewer" in the Activities overview ...` が出れば配置できている
   - sudo のパスワードを聞かれたら、答えてから次のブロックを貼る
   - リポジトリを別の場所に移動したら、手順 1 から貼り直してこのブロックを再実行する (`.desktop` の `Exec` は絶対パス)

   <details>
   <summary>補足: 配置されるもの</summary>

   `install-desktop` が配置するもの:

   | 場所 | 内容 |
   | --- | --- |
   | `~/.local/share/applications/kvm-virt-viewer.desktop` | ランチャー。`Exec` は `<このリポジトリ>/kvm.sh launch virt-viewer` (絶対パス) |
   | `~/.local/share/icons/hicolor/<size>/apps/virt-viewer.png` | イメージ内のアイコンをコピー |

   - 配置先は `${XDG_DATA_HOME:-$HOME/.local/share}` 配下 (`XDG_DATA_HOME` を変えていればそちら)
   - テンプレートは `desktop/kvm-virt-viewer.desktop`。`install-desktop` が `@KVM_SH@` を `<このリポジトリ>/kvm.sh` の絶対パスに `sed` で置換して配置する
   - アイコンは `gui` イメージの一時コンテナ (`--rm --network none`) から `hicolor` の `apps/virt-viewer.*` だけを `tar` で取り出す。`gui` イメージが無ければその前にビルドする。取り出しに失敗しても続行し、`>> (could not extract the virt-viewer icon; a generic icon will be shown)` と出て汎用アイコンになる
   - 以前のバージョンが入れた `kvm-firefox.desktop` / `kvm-virt-manager.desktop` とそのアイコン (`icons/hicolor/*/apps/{firefox,virt-manager}.*`) は、`install-desktop` / `uninstall-desktop` が削除する (firefox + cockpit と virt-manager は廃止した)
   - 最後に `update-desktop-database -q` (あれば) を実行する。アクティビティにすぐ出ないときは一度ログアウトする

   </details>

1. **動作確認する**

   コンテナを起動しておく。

   ```bash
   ./kvm.sh up
   ```

   - `>> ready. VMs: ...` (すでに動いていれば `>> kvm is already running` / `>> kvm-gui is already running`) が出るまで待つ
   - sudo のパスワードを聞かれたら答える

   出たら、GNOME のアクティビティ (Super キー) で「Virt Viewer」を検索して起動する。

   - VM の選択ダイアログが出れば動いている (VM が 1 つも無ければ、先に [vm.md 手順 3](vm.md#実施手順) で作る)
   - 起動しないときは、失敗の理由がデスクトップ通知に出る
   - **次のブロックは、ダイアログを閉じてから (起動しなければ通知を見てから) 貼る**

   配置先を確かめる。

   ```bash
   grep -E '^(TryExec|Exec)=' "${XDG_DATA_HOME:-$HOME/.local/share}/applications/kvm-virt-viewer.desktop"
   ls "${XDG_DATA_HOME:-$HOME/.local/share}"/icons/hicolor/*/apps/virt-viewer.*
   ```

   - `TryExec` / `Exec` に `${REPO}/kvm.sh` の絶対パスが入っていること
   - アイコンが 1 つ以上あること
   - 起動しない場合は `./kvm.sh logs gui` (`kvm-gui` 内 `/var/log/gui.log`) と `journalctl --user -b` を確認する

   <details>
   <summary>補足: 起動と切り分け</summary>

   - 起動直後は、`kvm-gui` 内の `gui` が systemd の起動完了 (ユーザーの同期) を待ってからアプリを起動する。`./kvm.sh up` の直後に起動すると、その待ちのぶんダイアログが出るのが遅れる (待ちの上限は 60 秒。[SPEC.md 5.3 節](SPEC.md#53-gui-起動シーケンス-containerguiguikvm-gui-内))
   - 起動しない場合は `./kvm.sh logs gui` (`kvm-gui` 内 `/var/log/gui.log` の末尾と `gui-user.service` の journal) と `journalctl --user -b` を確認する。失敗の理由はデスクトップ通知にも出る
   - 手順 4 の `grep` / `ls` は配置の確認だけで、起動の確認はアクティビティから実際に開いて行う (機械的に確かめる手段は用意していない)

   </details>

---

## ロールバック

`.desktop` とアイコンを削除する。sudo は要らない。

```bash
cd "${REPO:?手順 1 の REPO が空のまま。値を入れて貼り直す}" && ./kvm.sh uninstall-desktop
```

- 以前のバージョンが入れた `kvm-firefox.desktop` / `kvm-virt-manager.desktop` とそのアイコンも一緒に消える (firefox + cockpit と virt-manager は廃止した)
- 手順 2 の前に整えた sudoers は戻さない (本書の範囲外)
- コンテナと VM はそのまま残る。コンテナごと止める・消すのは[導入のロールバック](setup.md#ロールバック)
- `uninstall-desktop` は PR #15 で旧ランチャー (firefox / virt-manager) に対して本実行した。現行の Virt Viewer エントリに対する本実行記録は無い

---

## 補足

### 対象と検証環境

- **目的**: 物理マシン / VM の AlmaLinux 10 + GNOME で、`./kvm.sh viewer` を端末から打つ代わりに、アクティビティ (アプリ一覧) の「Virt Viewer」から VM の画面を開けるようにする
  - ランチャーは `~/.local/share/applications/` に置く `.desktop` ファイル 1 つとアイコンだけで、ホストにパッケージは入れない
- **進め方**: NOPASSWD の `sudo podman` を確かめ、`./kvm.sh install-desktop` で配置し、`./kvm.sh up` してからアクティビティで起動する。読者が書き換える値は無い (clone 先を変えたときだけ手順 1 の `REPO`)
- **状態**:
  - 仕組み (`install-desktop` → アクティビティから `launch` → `uninstall-desktop`) は PR #15 で物理 AlmaLinux 10.2 + GNOME (Wayland、SELinux Enforcing) で通した
  - **ただしそのときのランチャーは旧 firefox / virt-manager のもので、現行の Virt Viewer エントリ (PR #25 で置き換え) を本実行した記録は無い**
  - 手順 1 の `cd` と `ls -l kvm.sh`、手順 2 の `sudo -k; sudo -n podman ps` は `0cab212` で実行した (物理 AlmaLinux 10.2 + GNOME、`passwordless sudo podman: ok`)。手順 4 の `grep` / `ls` は `install-desktop` を実行していないので未実行
  - 手順 3 とロールバックの `cd "${REPO:?…}" && ./kvm.sh …` は README の例を変数形に書き換えたもので、その形では再実行していない

| 項目 | 値 |
|---|---|
| 検証ホスト | 物理 AlmaLinux 10.2 + GNOME (Wayland)、SELinux Enforcing、AMD (PR #15) |
| 確認した内容 | `install-desktop` → アクティビティからの起動 (`launch`) → `uninstall-desktop` の一巡 (旧 firefox / virt-manager ランチャー) |
| 現行 Virt Viewer エントリ | 本実行記録なし (PR #25 は静的検査のみ) |
| ディスプレイ無し | 対象外 (アクティビティが無い) |

> [!NOTE]
> 環境固有の値は**シェル変数**で書いてある。[手順 1](#実施手順) で 1 度だけ設定すれば、以降のコマンドはそのまま貼って実行できる。
>
> | 変数 | 意味 | 例 |
> |---|---|---|
> | `${REPO}` | このリポジトリを clone した場所。`install-desktop` はここの `kvm.sh` の絶対パスを `.desktop` に埋める | `~/kvm-container` |
>
> - `kvm.sh` 自身が読む環境変数 (`KVM_HOST` / `KVM_BRIDGE` など) は手順 1 の変数ではなく、`KVM_BRIDGE=br0 ./kvm.sh up` のように前に付ける。一覧は[導入の補足](setup.md#環境変数)
> - 出力例・表の中の値は `<このリポジトリ>` / `<size>` などのプレースホルダで書いてある。`<...>` を含むコマンドは bash のコードブロックに置いていない
> - sudoers の内容とホストのパスワードはこの文書に載せない

手順書全体に関わる理由・実測・落とし穴と検証記録 (手順ごとのものは各手順の末尾の「補足」にある)。手順を実行するだけなら読まなくてよい。

### 実施前の状態

| 項目 | 状態 |
|---|---|
| [導入](setup.md) | 済み (`./kvm.sh virsh list` が通る)。`gui` イメージは有っても無くてもよい |
| `~/.local/share/applications/` | `kvm-virt-viewer.desktop` は無い。旧版の `kvm-firefox.desktop` / `kvm-virt-manager.desktop` が残っていてもよい (手順 3 が消す) |
| sudoers | `sudo podman` は対話的 (パスワードあり)。`launch` のためには NOPASSWD が要る (読者が設定し、手順 2 で確かめる) |
| VM の画面 | 端末から `./kvm.sh viewer` で開いている |

### 選択した方針

- **検索して起動する形にし、デスクトップにアイコンは置かない**: GNOME の標準の流儀 (`~/.local/share/applications/` の `.desktop`) に合わせる。ホストに直接入れたアプリと同じ使い勝手になる
- **`Exec` は絶対パス、`TryExec` で存在確認**: `.desktop` は `Exec="<このリポジトリ>/kvm.sh" launch virt-viewer` と `TryExec=<このリポジトリ>/kvm.sh` を持つ
  - リポジトリを移動すると `TryExec` の対象が無くなり、古いエントリは自動で非表示になる
  - そのため移動後は `install-desktop` の再実行が要る
- **`launch` は `sudo -n`**: アクティビティから起動したプロセスには端末が無く、sudo のパスワードを入力できない
  - `launch` は `sudo -n podman exec kvm-gui gui virt-viewer` を実行し、失敗の理由はデスクトップ通知で伝える
  - podman の NOPASSWD sudo はホスト root 相当の権限付与になる。設定するかは利用者の判断なので、sudoers の書き方は本書に載せない ([SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項))
- **エントリは VM の選択ダイアログを開く**: Virt Viewer のエントリは、VM 名なしの `./kvm.sh viewer` と同じく VM の選択ダイアログを開く。VM ごとにエントリは作らない

### 完了時点の状態

- `~/.local/share/applications/kvm-virt-viewer.desktop` があり、`TryExec` / `Exec` に `<このリポジトリ>/kvm.sh` の絶対パスが入っている
- `~/.local/share/icons/hicolor/<size>/apps/virt-viewer.png` (イメージにあるサイズごと) がある
- アクティビティで「Virt Viewer」を検索すると出て、起動すると VM の選択ダイアログ → virt-viewer のウィンドウが開く (コンテナが起動している間だけ)
- コンテナ・VM・`data/` には変更は無い。ホストにパッケージは増えない
- 旧版の `kvm-firefox.desktop` / `kvm-virt-manager.desktop` は消えている

### 注意点

- **NOPASSWD の意味**: `launch` のために podman を NOPASSWD にすると、そのユーザーはパスワード無しでホスト root 相当の操作ができる
  - 通常の `./kvm.sh` は対話的な `sudo` のままで動くので、アクティビティからの起動を使わないなら設定しなくてよい ([SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項))
- **リポジトリを移動したら再実行**: `.desktop` は絶対パス。`TryExec` により古いパスのエントリは自動で非表示になるだけで、直るわけではない。`./kvm.sh install-desktop` を再実行する
- **コンテナが起動していないと通知だけ出る**: `launch` は `up` を経由しない。再ログイン後に表示先が変わったときも同じで、先に端末から `./kvm.sh up` する ([導入の「表示先が変わったとき」](setup.md#表示先が変わったとき-再ログイン後))
- **`./kvm.sh viewer` はそのまま使える**: ランチャーを入れても端末からの `./kvm.sh viewer` は変わらない。こちらは `up` を経由するので、コンテナが止まっていても再ログイン後でもそのまま使える

### 参照

- [SPEC.md 4.7 節](SPEC.md#47-デスクトップ統合-activities-からの起動) — `.desktop` の主要キー、アイコン抽出、通知の経路 (図 13)
- [SPEC.md 4.1 節](SPEC.md#41-cli-kvmsh-サブコマンド-ロール-) — `install-desktop` / `uninstall-desktop` / `launch` の CLI
- [SPEC.md 5.3 節](SPEC.md#53-gui-起動シーケンス-containerguiguikvm-gui-内) — `gui` が起動完了を待つ処理
- [SPEC.md 7 章](SPEC.md#7-セキュリティ考慮事項) — ホスト側の sudo の扱い
- `desktop/kvm-virt-viewer.desktop` — テンプレート
- [導入](setup.md) — `up` / `viewer` / 再ログイン後の扱い

---

### 付録: 検証記録 (PR #15、旧ランチャー)

物理 AlmaLinux 10.2 + GNOME (Wayland、SELinux Enforcing、AMD) で、当時の firefox / virt-manager ランチャーに対して `./kvm.sh install-desktop` → アクティビティから起動 (`launch`) → `./kvm.sh uninstall-desktop` を通した記録がある (通しの動作確認の一部)。配置先・`@KVM_SH@` の置換・`sudo -n` による `launch`・通知の経路はこの時点から変わっていない (通知の文言と対象アプリは変わった)。旧エントリの削除 (`remove_legacy_desktop`) は PR #24 (virt-manager 廃止) で加わり、PR #25 でランチャーを Virt Viewer 1 つに置き換えて firefox のエントリも削除対象にした。PR #25 の検証は静的検査のみ。

#### 未確認事項

- 現行の Virt Viewer エントリで `install-desktop` → アクティビティから起動 → 選択ダイアログ → `uninstall-desktop` を通すこと
- 手順 4 の `grep` / `ls` (新規の確認行。手順 1 の `cd` と `ls -l kvm.sh`、手順 2 の `sudo -k; sudo -n podman ps` は `0cab212` で実行した)
- sudoers の具体的な書き方と、それで `launch` が通ること
- 旧エントリ (`kvm-firefox.desktop` / `kvm-virt-manager.desktop`) が残ったホストでの `install-desktop` による削除
- アイコン抽出に失敗したときの汎用アイコン表示
