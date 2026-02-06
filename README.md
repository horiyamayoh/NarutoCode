# NarutoCode

SVN リポジトリの履歴を解析し、差分規模（追加行・削除行・変更ファイル数）を集計する PowerShell スクリプトです。

## 特徴

- 指定リビジョン範囲のコミット差分を自動集計
- Author（コミッター）でのフィルタリング
- 拡張子・パスによるフィルタリング（Include / Exclude）
- 空白・改行コード差分の無視オプション
- CSV / JSON / Markdown 形式での出力
- リビジョン別内訳の表示

## 動作環境

- **PowerShell 5.1** 以上
- **Subversion（svn）** コマンドラインクライアントがパスに通っていること

## 使い方

```powershell
# 基本: r200〜r250 のうち特定ユーザーのコミットを集計
.\NarutoCode.ps1 -Path https://svn.example.com/repos/proj/trunk `
    -FromRevision 200 -ToRevision 250 -Author Y.Hoge

# エイリアスを使った短い書き方
.\NarutoCode.ps1 -Path https://svn.example.com/repos/proj/trunk `
    -Pre 200 -Post 250 -Name Y.Hoge

# 空白・改行差分を無視して JSON 出力
.\NarutoCode.ps1 -Path https://svn.example.com/repos/proj/trunk `
    -From 200 -To 250 -IgnoreAllSpace -IgnoreEolStyle -OutputJson .\result.json
```

## パラメータ

| パラメータ | 必須 | 説明 |
|---|---|---|
| `-Path` | ✅ | SVN リポジトリ URL（http/https/svn スキーム） |
| `-FromRevision` | ✅ | 開始リビジョン番号 |
| `-ToRevision` | ✅ | 終了リビジョン番号 |
| `-Author` | | SVN の author 名でフィルタ |
| `-SvnExecutable` | | svn コマンドのパス（既定: `svn`） |
| `-IgnoreSpaceChange` | | 空白量の変更を無視 |
| `-IgnoreAllSpace` | | 空白の違いをすべて無視 |
| `-IgnoreEolStyle` | | 改行コード差分を無視 |
| `-IncludeExtensions` | | カウント対象の拡張子（例: `cs`, `ps1`） |
| `-ExcludeExtensions` | | カウント除外の拡張子 |
| `-ExcludePaths` | | ワイルドカードでパス除外 |
| `-OutputCsv` | | CSV ファイルに出力 |
| `-OutputJson` | | JSON ファイルに出力 |
| `-OutputMarkdown` | | Markdown ファイルに出力 |
| `-ShowPerRevision` | | リビジョン別内訳を表示 |
| `-NoProgress` | | 進捗バー表示を無効化 |

## フォルダ構成

```
NarutoCode/
├── docs/           # ドキュメント
├── tests/          # Pester テスト
├── NarutoCode.ps1  # スクリプト本体
├── README.md       # 本ファイル
├── AGENTS.md       # AI エージェント向け開発ルール
└── LICENSE
```

> **設計方針:** 配布容易性のため、スクリプト本体は `NarutoCode.ps1` の1ファイルに集約しています。

## ライセンス

[MIT License](LICENSE) — 自由に改変・再配布できます。
