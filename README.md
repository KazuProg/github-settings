# github-settings

GitHub リポジトリの推奨設定を `gh` CLI 経由で一括適用するツール。

新規リポジトリ作成後に Web UI で手作業する代わりに、`settings/` の JSON を元に API で設定を揃える。`--dry-run` で適用前に差分を確認できる。

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール済みであること
- [`jq`](https://jqlang.github.io/jq/) がインストール済みであること
- `gh auth login` 済みで、対象リポジトリへの書き込み権限（`repo` スコープ）があること
- **対象リポジトリは GitHub 上に既に存在していること**（本ツールはリポジトリの新規作成は行わない）

## クイックスタート

```bash
./setup.sh
```

対話形式で以下を進める。

1. 対象リポジトリ（`owner/repo`）の入力
2. リポジトリの存在確認（public / private を表示）
3. プリセット選択（`settings/presets/` の一覧から選択、または (none)）
4. 任意 rulesets の有効化確認（リポジトリ単位）
5. `--dry-run` の実行（任意・デフォルト: はい）
6. 本番適用の実行（任意・デフォルト: いいえ）

feature の on/off（release immutability、private vulnerability reporting、Dependabot alerts / security updates）は `settings/settings.json` の `features` セクションで宣言的に管理する。

## 直接実行

対話なしで適用する場合は `apply.sh` を直接使う。

```bash
# 差分確認のみ（API への書き込みなし）
./apply.sh owner/repo --dry-run

# 設定を適用
./apply.sh owner/repo

# プリセットを指定して適用
./apply.sh owner/repo --preset internal-tool --dry-run
```

## プリセット

用途ごとに異なる設定パターンを `settings/presets/<name>/` にまとめておき、`--preset <name>` で選択できる。プリセットが提供する `settings.json` は **完全な設定**（default の全キー + 差分）として扱われ、指定時は default の `settings/settings.json` は読まれない。

プリセットで差し替えられるもの:

- `settings.json` — default `settings/settings.json` の代わりに読まれる（自己完結。default の全キーを含める必要がある）
- `rulesets/required/*.json` / `rulesets/optional/*.json` — 同名ファイルは default `settings/rulesets/{required,optional}/` を上書き。preset 側にしかないファイルは追加として扱われる（配置先のサブディレクトリで必須 / 任意が決まる）
- `post-setup.sh` — 実行可能なら Rulesets の後に呼ばれる（`--no-post-setup` でスキップ可能）
- `preset.json` — プリセットの説明文（`description`）

現在同梱するプリセット:

- `github-flow`: 単一 `main` + Conventional Commits + `cocogitto` 自動リリース運用を想定。マージ方法(`allow_*_merge` / `allowed_merge_methods`)は省略し GitHub 側の現状を維持、`default-branch-protection` に `lint-commits` / `no-fixup-commits` / `release` の status check を統合、`release-dispatch` Environment（手動リリースの承認ゲート）を作成、post-setup で bump-level ラベルと release Deploy Key（`RELEASE_DEPLOY_KEY` secret + ruleset bypass 登録）を作成

## 適用される設定（9 ステップ）

| #   | 項目                                                                                                 | 設定ファイル / API                                                                                               |
| --- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| 1   | 一般設定（Issues、マージ方法、Secret scanning など）                                                   | `settings/settings.json` (`.general`)                                                                            |
| 2   | Release immutability の有効化（`features.immutable_releases`）                                         | `PUT .../immutable-releases`                                                                                     |
| 3   | Actions 権限                                                                                         | `settings/settings.json` (`.actions.permissions`)                                                                |
| 4   | 許可する Actions（`allowed_actions: selected` の場合）                                                 | `settings/settings.json` (`.actions.selected`)                                                                   |
| 5   | Private vulnerability reporting の有効化（public のみ / `features.private_vulnerability_reporting`）   | `PUT .../private-vulnerability-reporting`                                                                        |
| 6   | Dependabot alerts の有効化（`features.dependabot_alerts`）                                             | `PUT .../vulnerability-alerts`                                                                                   |
| 7   | Dependabot security updates の有効化（`features.dependabot_security_updates`）                         | `PUT .../automated-security-fixes`                                                                               |
| 8   | Rulesets                                                                                             | `settings/rulesets/required/*.json`（常時適用）+ `settings/rulesets/optional/*.json`（`--with-rulesets` で任意）     |
| 9   | Environments（Required reviewers）                                                                     | `settings/settings.json` (`.environments`) → `PUT .../environments/{name}`                                       |

### 現在の推奨値の概要

**一般設定** (`settings/settings.json`)

- Issues: ON / Wiki・Discussions・Projects: OFF
- マージ方法: merge commit のみ（squash・rebase は OFF）
- マージ後のブランチ自動削除: ON
- PR ブランチの更新提案: ON
- auto-merge: ON（public、または Pro 以上の private のみ有効）
- Secret scanning / push protection: ON（public、または Advanced Security 有効な private のみ）

**Release immutability**（ステップ 2）

- リリース公開後の assets / tags の改変を禁止
- リリース運用を始める前でも有効化される（個人開発では必須ではない）

**Actions** (`settings/settings.json` の `.actions`)

- Actions: 有効
- 許可範囲: `selected`（GitHub 公式・検証済み publisher のみ）
- カスタム Action パターン: なし

**Rulesets**（ステップ 8）

- 常時適用: `settings/rulesets/required/*.json` に配置したファイル。デフォルトは `default-branch-protection.json` のみ
  - 対象: リポジトリの **default branch**（`~DEFAULT_BRANCH`。`main` 固定ではない）
  - 有効ルール: ブランチ作成・削除・force push 禁止、PR 経由 merge のみ
  - merge 方法: merge commit のみ（一般設定の squash / rebase OFF と揃える）
  - Approve 数 0、レビュースレッド解決必須
- 任意適用: `settings/rulesets/optional/*.json` に配置したファイル（`--with-rulesets <basename>`）
  - 例: `no-fixup-commits.json` — `.github/workflows/no-fixup-commits.yml` を配置したリポジトリ向け
  - default branch への merge 前に `no-fixup-commits` ステータスチェックを必須化
  - 例: `lint-commits.json` — `.github/workflows/lint-commits.yml` を配置したリポジトリ向け
  - default branch への merge 前に `commitlint` ステータスチェックを必須化
- 必須 / 任意はサブディレクトリで区別する（`required/` = 常時適用、`optional/` = `--with-rulesets` 指定時のみ）
- ruleset の `bypass_actors` は apply 対象外（サーバー側の既存値をそのまま保持する）。手動 / post-setup で登録した bypass actor（Deploy Key 等）は再適用しても消えない

各 JSON の値を編集すれば、適用内容をリポジトリやチームの方針に合わせて変更できる。

**Environments**（ステップ 9、`settings/settings.json` の `.environments`）

- 各エントリの `name` で Environment を作成し、`reviewers`（GitHub username 配列）を Required reviewers として設定する
- `reviewers` が空のエントリはエラーで停止する（無保護の Environment を誤って作成しないため）
- default 設定では `environments: []`（未使用）。github-flow プリセットは `release-dispatch` エントリを持つが、`reviewers` は空のプレースホルダーなので導入時に GitHub username を追記する必要がある

## dry-run の挙動

`--dry-run` では API への書き込みは行わない。

- **JSON 設定ステップ（1, 3, 4）**: ライブ API の現在値と `settings/` の desired 値を比較し、差分をカラー diff で表示する。API が返さないフィールドは desired 値で補完して比較する。
- **有効化のみのステップ（2, 5, 6, 7）**: 各エンドポイントの GET で有効済みかを確認し、`(already enabled)` または `(would enable …)` を表示する。
- **Rulesets（8）**: `(would create: …)` または `(would update: …, id=…)` を表示する。内容の diff は出さない。
- **Environments（9）**: Environment 未作成なら `(would create: …)`、Required reviewers が一致していなければ `(would update: …)`、一致していれば `(no diff: …)` を表示する。`reviewers` が空のエントリは dry-run でもエラーで停止する。
- **スキップされるステップ**: `(skipped; …)` と表示する（後述）。

## リポジトリ種別による制限とスキップ

GitHub の制限により、apply 時に一部設定をスキップしたり、apply 後も dry-run に diff が残ることがある。いずれもスクリプトの不具合ではない。

| 対象                            | 条件                  | apply 時                         | dry-run                     |
| ------------------------------- | --------------------- | -------------------------------- | --------------------------- |
| Secret scanning                 | private + GHAS なし   | PATCH から除外                   | スキップ表示、diff に出ない |
| Private vulnerability reporting | private               | スキップ                         | スキップ表示                |
| Rulesets                        | private + Free プラン | スキップ                         | スキップ表示                |
| Environments (Required reviewers) | private + Pro/Team 未満 | スキップ                       | 判定不可(後述)              |
| `allow_auto_merge`              | private + Free プラン | エラーにならないが GitHub が無視 | diff が残る（無視してよい） |

上表の対象以外（Issues、マージ方法、Actions、Dependabot、release immutability 等）は private でも通常どおり適用される。Rulesets は **public、または Pro 以上の private** でのみ利用可能。Environments の Required reviewers は **public、または Pro(個人)/Team(組織)以上の private** でのみ利用可能。GitHub 側がこの制約に対する具体的なエラー応答を公開していないため、apply 時は書き込み失敗を private リポジトリ限定でプラン制約とみなしてスキップする。dry-run は読み取り専用のため同じ判定ができず、プラン制約で実際にはスキップされるケースも `(would create: …)` と表示されることがある。

Advanced Security が有効な private リポジトリでは、ステップ 1 の `security_and_analysis` も適用される。auto-merge は Pro 以上の private、または public で有効化できる。

## スコープ外

本ツールが**カバーしない**設定の例:

| 項目                                | 備考                                                             |
| ----------------------------------- | ---------------------------------------------------------------- |
| CodeQL / Dependabot version updates | リポジトリの言語・構成に依存するため、profile 分岐での対応を想定 |
| Grouped security updates            | リポジトリ単位の REST API が存在しない                           |
| リポジトリの新規作成                | GitHub 上で先に作成してから実行する                              |

## 開発（本リポジトリの変更時）

本リポジトリのコード品質は [lefthook](https://github.com/evilmartians/lefthook) で管理している。

```bash
# lefthook（https://github.com/evilmartians/lefthook#install 参照）
# その他: jq, shellcheck, shfmt, uv（YAML チェックは uvx yamllint で実行）
lefthook install
```

pre-commit では空白・EOF 修正、shfmt、shellcheck、JSON/YAML 構文チェックを実行する。

```bash
lefthook run pre-commit --all-files
```

## ディレクトリ構成

```
.
├── setup.sh              # 対話型セットアップ
├── apply.sh              # 設定適用（--dry-run 対応）
├── rulesets-common.sh    # ruleset 検出ヘルパー（apply.sh / setup.sh 共有）
└── settings/
    ├── settings.json                  # 一般設定 / Actions / features を統合
    ├── rulesets/
    │   ├── required/
    │   │   └── default-branch-protection.json
    │   └── optional/
    │       ├── no-fixup-commits.json
    │       └── lint-commits.json
    └── presets/
        └── github-flow/
            ├── preset.json
            ├── settings.json                       # 自己完結の完全な設定
            ├── post-setup.sh                       # bump-level ラベル + release Deploy Key 作成
            └── rulesets/
                └── required/
                    └── default-branch-protection.json  # status checks 統合版
```

## トラブルシューティング

**`repository not found`**

対象リポジトリが GitHub 上に存在しないか、`gh` の認証アカウントにアクセス権がない。リポジトリを先に作成するか、`gh auth status` でログイン状態を確認する。

**`required command not found: jq`**

`jq` が未インストール。パッケージマネージャまたは [jq 公式](https://jqlang.github.io/jq/download/) からインストールする。

**`gh:` で始まる API エラー**

途中のステップで失敗すると以降は実行されない。成功済みのステップはロールバックされないため、修正後に再実行する。Secret scanning スキップや auto-merge の diff 残りなど、リポジトリ種別による制限は上記「リポジトリ種別による制限とスキップ」を参照。

**`selected-actions API unavailable`（dry-run 時）**

ステップ 3 で `allowed_actions` がまだ `all` の場合、ステップ 4 の API が使えないため dry-run では desired 値のプレビューのみ表示される。本番適用時はステップ 3 の後にステップ 4 が正常に実行される。

**Rulesets が適用されない (private + Free プラン)**

GitHub Free では private リポジトリで rulesets API が使えない。ステップ 8 はスキップされ、その他の設定は通常どおり適用される。rulesets を使いたい場合は Pro 以上にアップグレードするか、リポジトリを public にする。
