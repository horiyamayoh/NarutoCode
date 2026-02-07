# AGENTS.md — NarutoCode 開発ルール

## プロジェクト概要

NarutoCode は SVN リポジトリの履歴（差分規模）を解析する PowerShell スクリプトです。
PowerShell 5.1 を対象としています。

## 厳守事項

- スクリプト本体は **NarutoCode.ps1 の1ファイルのみ** とする
  - 関数・クラス・モジュールを別ファイルに分割してはならない
  - すべてのロジックは NarutoCode.ps1 内に記述する
- テストファイルは `tests/` フォルダ内に配置する（複数ファイル可）
- ドキュメントは `docs/` フォルダおよびルート直下の Markdown に配置する

## 許可される操作

- NarutoCode.ps1 内への関数追加・修正
- `tests/` 以下へのテストファイル追加・修正
- `docs/` 以下へのドキュメント追加・修正
- README.md, AGENTS.md の更新

## 禁止される操作

- `Private/`, `Public/` などのモジュール分割用フォルダの作成
- `.psm1`, `.psd1` などモジュールファイルの作成
- NarutoCode.ps1 以外の `.ps1` 実行スクリプトの作成（テスト用 `.Tests.ps1` は除く）
- 外部ファイルへの関数・ロジックの切り出し
- **エージェントがターミナルで Pester テストやスクリプトを実行すること（VS Code がクラッシュするため厳禁）**
  - テストの実行はユーザーが手動で行う。エージェントはコマンドを提示するのみとする

## 静的解析（PSScriptAnalyzer）

- 静的解析ツールとして **PSScriptAnalyzer** を使用する
- 設定ファイル: `.PSScriptAnalyzerSettings.psd1`（プロジェクトルート）
- **エージェントは静的解析の実行を許可する**（テスト実行の禁止とは異なる）
- **コード変更後は必ず `Invoke-ScriptAnalyzer` を実行し、指摘事項を全件解消すること**
  - Error / Warning / Information すべてを対象とする
  - 除外ルールは `.PSScriptAnalyzerSettings.psd1` に定義されたもののみ許可
- 実行コマンド: `Invoke-ScriptAnalyzer -Path .\NarutoCode.ps1 -Settings .\.PSScriptAnalyzerSettings.psd1`

## コードフォーマット（Invoke-Formatter）

- フォーマッターは **PSScriptAnalyzer の `Invoke-Formatter`** を使用する
- 設定ファイルは静的解析と共通: `.PSScriptAnalyzerSettings.psd1`
- スタイル: **厳密な Allman スタイル**（1行ブロックも展開、波括弧は必ず独立行）
- フォーマット適用コマンド:

```powershell
$code = Get-Content -Path .\NarutoCode.ps1 -Raw
$formatted = Invoke-Formatter -ScriptDefinition $code `
    -Settings .\.PSScriptAnalyzerSettings.psd1
Set-Content -Path .\NarutoCode.ps1 -Value $formatted -NoNewline -Encoding UTF8
```

- フォーマット後は必ず `Invoke-ScriptAnalyzer` で違反が 0 件であることを確認する
- `Invoke-Formatter` は AST ベースのため、セミコロン連結文の分離は行わない。必要に応じて手動で分離する

## フォルダ構成

```
NarutoCode/
├── docs/                              # 設計メモ・仕様書・使い方ガイド
├── tests/                             # Pester テストファイル
├── NarutoCode.ps1                     # スクリプト本体（唯一の実行ファイル）
├── .PSScriptAnalyzerSettings.psd1     # 静的解析 & フォーマッター設定
├── README.md                          # プロジェクト概要・使い方
├── AGENTS.md                          # 本ファイル（AI エージェント向けルール）
└── .gitignore
```

## テストについて

- テストフレームワークは **Pester** を使用する
- テストファイルの命名規則: `*.Tests.ps1`
- テストは `tests/` フォルダ直下に配置する

## コーディング規約

- PowerShell 5.1 互換のコードを書くこと
- `using namespace` や PowerShell クラス構文など 5.1 で問題がある機能は避ける
- パラメータには適切な型指定・バリデーション属性を付与する
- Comment-Based Help を維持・更新する
- **セミコロン `;` で複数の文を1行に圧縮してはならない**
  - 各文は独立した行に記述すること
  - 悪い例: `$a = 1; $b = 2; $c = $a + $b`
  - 良い例:
    ```powershell
    $a = 1
    $b = 2
    $c = $a + $b
    ```

## コミット規約（Conventional Commits）

コミットメッセージは **日本語** で、以下の形式に従う：

```
<type>: <説明>
```

### type 一覧

| type | 用途 |
|---|---|
| `feat` | 新機能の追加 |
| `fix` | バグ修正 |
| `refactor` | リファクタリング（機能変更なし） |
| `test` | テストの追加・修正 |
| `docs` | ドキュメントの追加・修正 |
| `style` | コードスタイル・フォーマットの変更（動作に影響なし） |
| `chore` | ビルド・ツール・設定等の変更 |
| `perf` | パフォーマンス改善 |

### 例

```
feat: 拡張子フィルタ機能を追加
fix: XML パース時の文字化けを修正
refactor: 関数名を Approved Verbs に準拠させる
test: Normalize-Extensions のテストを追加
docs: README にパラメータ一覧を追記
style: Allman スタイルにフォーマット統一
chore: PSScriptAnalyzer の設定ファイルを追加
```
