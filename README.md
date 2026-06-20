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
3. `--dry-run` の実行（任意・デフォルト: はい）
4. 本番適用の実行（任意・デフォルト: いいえ）

## 直接実行

対話なしで適用する場合は `apply.sh` を直接使う。

```bash
# 差分確認のみ（API への書き込みなし）
./apply.sh owner/repo --dry-run

# 設定を適用
./apply.sh owner/repo
```

## 適用される設定（7 ステップ）

| #   | 項目                                                    | 設定ファイル / API                        |
| --- | ------------------------------------------------------- | ----------------------------------------- |
| 1   | 一般設定（Issues、マージ方法、Secret scanning など）    | `settings/settings.json`                  |
| 2   | Release immutability の有効化                           | `PUT .../immutable-releases`              |
| 3   | Actions 権限                                            | `settings/actions.json`                   |
| 4   | 許可する Actions（`allowed_actions: selected` の場合）  | `settings/actions-selected.json`          |
| 5   | Private vulnerability reporting の有効化（public のみ） | `PUT .../private-vulnerability-reporting` |
| 6   | Dependabot alerts の有効化                              | `PUT .../vulnerability-alerts`            |
| 7   | Dependabot security updates の有効化                    | `PUT .../automated-security-fixes`        |

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

**Actions** (`settings/actions.json`, `settings/actions-selected.json`)

- Actions: 有効
- 許可範囲: `selected`（GitHub 公式・検証済み publisher のみ）
- カスタム Action パターン: なし

各 JSON の値を編集すれば、適用内容をリポジトリやチームの方針に合わせて変更できる。

## dry-run の挙動

`--dry-run` では API への書き込みは行わない。

- **JSON 設定ステップ（1, 3, 4）**: ライブ API の現在値と `settings/` の desired 値を比較し、差分をカラー diff で表示する。API が返さないフィールドは desired 値で補完して比較する。
- **有効化のみのステップ（2, 5, 6, 7）**: 各エンドポイントの GET で有効済みかを確認し、`(already enabled)` または `(would enable …)` を表示する。
- **スキップされるステップ**: `(skipped; …)` と表示する（後述）。

## リポジトリ種別による制限とスキップ

GitHub の制限により、apply 時に一部設定をスキップしたり、apply 後も dry-run に diff が残ることがある。いずれもスクリプトの不具合ではない。

| 対象                            | 条件                  | apply 時                         | dry-run                     |
| ------------------------------- | --------------------- | -------------------------------- | --------------------------- |
| Secret scanning                 | private + GHAS なし   | PATCH から除外                   | スキップ表示、diff に出ない |
| Private vulnerability reporting | private               | スキップ                         | スキップ表示                |
| `allow_auto_merge`              | private + Free プラン | エラーにならないが GitHub が無視 | diff が残る（無視してよい） |

それ以外（Issues、マージ方法、Actions、Dependabot、release immutability 等）は private でも通常どおり適用される。

Advanced Security が有効な private リポジトリでは、ステップ 1 の `security_and_analysis` も適用される。auto-merge は Pro 以上の private、または public で有効化できる。

## スコープ外

本ツールが**カバーしない**設定の例:

| 項目                                | 備考                                                             |
| ----------------------------------- | ---------------------------------------------------------------- |
| ブランチ保護 / Rulesets             | 別途設定が必要。squash / rebase OFF は Ruleset と揃える前提      |
| CodeQL / Dependabot version updates | リポジトリの言語・構成に依存するため、profile 分岐での対応を想定 |
| Grouped security updates            | リポジトリ単位の REST API が存在しない                           |
| リポジトリの新規作成                | GitHub 上で先に作成してから実行する                              |

## ディレクトリ構成

```
.
├── setup.sh              # 対話型セットアップ
├── apply.sh              # 設定適用（--dry-run 対応）
└── settings/
    ├── settings.json           # 一般設定
    ├── actions.json            # Actions 権限
    └── actions-selected.json   # 許可する Actions（selected 時）
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
