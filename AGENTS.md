# AGENTS.md — NarutoCode 開発ルール

## 1. プロジェクト概要

NarutoCode は SVN リポジトリの履歴（差分規模）を解析する PowerShell スクリプトです。
PowerShell 5.1 を対象としています。

### 設計思想: 数学的厳密性の原則

本プロジェクトでは、**原理的に回避不能な場合を除き、数学的・論理的に厳密なロジックのみを採用する**。以下は一切許容しない：

- **ヒューリスティック**: 経験則に基づくフィルタリング・閾値判定（例: 「100 ファイル以上のコミットを除外」）
- **省略**: 計算コスト削減を目的としたデータの切り捨て・サンプリング
- **回避可能な誤差**: 丸め、近似式、概算ラベル付き指標
- **概算**: 厳密に計算可能であるにもかかわらず近似で代替すること

性能上の制約がある場合は、精度を犠牲にするのではなく、キャッシュ・並列化・アルゴリズム改善で対処する。
「原理的に厳密化不可能」と判断した場合のみ例外とし、その根拠をドキュメントに明記すること。

---

## 2. ファイル構成ルール

### 原則: 単一スクリプト構成

- スクリプト本体は **NarutoCode.ps1 の 1 ファイルのみ**
- すべてのロジック（関数・変数・メイン処理）を NarutoCode.ps1 内に記述する

### 許可される操作

| 対象 | 操作 |
|---|---|
| `NarutoCode.ps1` | 関数追加・修正 |
| `tests/*.Tests.ps1` | テストファイルの追加・修正 |
| `docs/*.md` | ドキュメントの追加・修正 |
| `README.md`, `AGENTS.md` | 更新 |

### 禁止される操作

- `Private/`, `Public/` などモジュール分割用フォルダの作成
- `.psm1`, `.psd1` などモジュールファイルの作成
- NarutoCode.ps1 以外の `.ps1` 実行スクリプトの作成（テスト用 `.Tests.ps1` は除く）
- 外部ファイルへの関数・ロジックの切り出し

### フォルダ構成

```
NarutoCode/
├── NarutoCode.ps1                     # スクリプト本体（唯一の実行ファイル）
├── Format.ps1                         # フォーマット適用 & 静的解析スクリプト
├── RunTests.ps1                       # Pester テスト実行スクリプト
├── Setup.ps1                          # 開発環境セットアップスクリプト
├── RequiredModules.psd1               # 依存モジュール定義
├── .PSScriptAnalyzerSettings.psd1     # 静的解析 & フォーマッター設定
├── README.md                          # プロジェクト概要・使い方
├── AGENTS.md                          # 本ファイル（AI エージェント向けルール）
├── LICENSE                            # ライセンスファイル
├── .gitignore
├── docs/                              # 設計メモ・仕様書・使い方ガイド
└── tests/                             # Pester テストファイル
```

---

## 3. コーディング規約

- PowerShell 5.1 互換のコードを書くこと
- テキストエンコーディングは UTF-8 with BOM であることに注意する
- `using namespace` や PowerShell クラス構文など 5.1 で問題がある機能は避ける
- パラメータには適切な型指定・バリデーション属性を付与する
- Comment-Based Help を維持・更新する
- **セミコロン `;` で複数の文を 1 行に圧縮してはならない**（各文は独立した行に記述）

```powershell
# 悪い例
$a = 1; $b = 2; $c = $a + $b

# 良い例
$a = 1
$b = 2
$c = $a + $b
```

---

## 4. 品質チェック（コード変更後の必須手順）

コード変更後は以下の手順を **必ず** 実行する。

### 手順 1: フォーマット適用 & 静的解析

```powershell
.\Format.ps1
```

- `Format.ps1` は以下を自動実行する:
  1. `Invoke-Formatter` によるフォーマット適用（厳密な Allman スタイル）
  2. `Invoke-ScriptAnalyzer` による静的解析
- 設定ファイル: `.PSScriptAnalyzerSettings.psd1`（共通）
- **違反が 0 件になるまで修正すること**（Error / Warning / Information すべて対象）
- 除外ルールは `.PSScriptAnalyzerSettings.psd1` に定義されたもののみ許可

### 補足: 静的解析の単独実行

```powershell
Invoke-ScriptAnalyzer -Path .\NarutoCode.ps1 -Settings .\.PSScriptAnalyzerSettings.psd1
```

---

## 5. テスト

- テストフレームワーク: **Pester**
- テストファイルの命名規則: `*.Tests.ps1`
- 配置先: `tests/` フォルダ直下

---

## 6. コミット規約（Conventional Commits）

コミットメッセージは **日本語** で、以下の形式に従う：

```
<type>: <説明>
```

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
