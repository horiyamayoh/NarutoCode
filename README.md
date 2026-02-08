# NarutoCode

SVN リポジトリの履歴を解析し、コミット品質・変更傾向のメトリクスを生成する PowerShell スクリプトです。

## 特徴

- 指定リビジョン範囲の SVN 履歴を自動解析
- コードチャーンと生存分析（svn blame による行レベル追跡）
- 自己相殺・他者差戻の検出（行ハッシュ / per-revision blame）
- ホットスポットスコアリング（コミット頻度 × チャーン）
- 共変更カップリング分析（Jaccard / Lift）
- 拡張子・パスによるフィルタリング（Include / Exclude）
- 空白・改行コード差分の無視オプション
- CSV レポートおよび PlantUML / SVG 可視化の自動出力

## 動作環境

- **PowerShell 5.1** 以上
- **Subversion（svn）** コマンドラインクライアントがパスに通っていること

## 使い方

```powershell
# 基本: r200〜r250 の履歴を解析（最小構成・3引数のみ）
.\NarutoCode.ps1 -RepoUrl https://svn.example.com/repos/proj/trunk `
    -FromRev 200 -ToRev 250

# 出力先を明示し、Java ファイルのみ対象
.\NarutoCode.ps1 -RepoUrl https://svn.example.com/repos/proj/trunk `
    -FromRev 200 -ToRev 250 -OutDir .\out -IncludeExtensions cs,java

# SVN 認証付き + 空白差分を無視 + CI 環境向け
.\NarutoCode.ps1 -RepoUrl https://svn.example.com/repos/proj/trunk `
    -FromRev 200 -ToRev 250 -Username svnuser -Password $secPwd `
    -IgnoreWhitespace -NonInteractive -NoProgress
```

## パラメータ

| パラメータ | 必須 | 既定値 | 説明 |
|---|---|---|---|
| `-RepoUrl` | ✅ | — | SVN リポジトリ URL（trunk やブランチまで指定） |
| `-FromRev` | ✅ | — | 解析範囲の開始リビジョン番号 |
| `-ToRev` | ✅ | — | 解析範囲の終了リビジョン番号 |
| `-SvnExecutable` | | `svn` | svn コマンドのパスまたは名前 |
| `-OutDir` | | `NarutoCode_out` | 出力先ディレクトリ（キャッシュ含む） |
| `-Username` | | | SVN 認証用ユーザー名（`--username` に渡される） |
| `-Password` | | | SVN 認証用パスワード（SecureString 型） |
| `-NonInteractive` | | | svn の対話プロンプトを抑止（CI 向け） |
| `-TrustServerCert` | | | SSL 証明書の検証をスキップ |
| `-Parallel` | | CPU コア数 | 並列ワーカー数の上限（1〜128） |
| `-IncludePaths` | | | 解析対象パスのワイルドカードパターン配列 |
| `-ExcludePaths` | | | 解析除外パスのワイルドカードパターン配列 |
| `-IncludeExtensions` | | | 解析対象の拡張子配列（例: `cs`, `java`） |
| `-ExcludeExtensions` | | | 解析除外の拡張子配列（例: `dll`, `exe`） |
| `-TopN` | | `50` | 可視化に表示する上位件数（CSV は全件出力） |
| `-Encoding` | | `UTF8` | 出力ファイルのエンコーディング |
| `-IgnoreWhitespace` | | | diff 時に空白・改行コードの差異を無視 |
| `-NoProgress` | | | 進捗バー表示を抑止 |

> 旧パラメータ名（`-Path`, `-FromRevision`, `-ToRevision` 等）はエイリアスとして引き続き使用可能です。

## 出力ファイル

```
<OutDir>/
├── run_meta.json              ← 実行条件・結果の記録
├── committers.csv             ← 開発者ごとの集計
├── files.csv                  ← ファイルごとの集計
├── commits.csv                ← コミット単位のログ
├── couplings.csv              ← ファイル同時変更ペアの関連度
├── contributors_summary.puml  ← コミッター表（PlantUML）
├── hotspots.puml              ← ホットスポット表（PlantUML）
├── cochange_network.puml      ← 共変更ネットワーク図（PlantUML）
├── contributors_summary.svg   ← コミッター表（SVG）
├── hotspots.svg               ← ホットスポット表（SVG）
├── cochange_network.svg       ← 共変更ネットワーク図（SVG）
└── cache/                     ← diff / blame / cat のキャッシュ
```

詳細な指標の読み方は [docs/metrics_guide.md](docs/metrics_guide.md) を参照してください。

## フォルダ構成

```
NarutoCode/
├── docs/           # 設計メモ・仕様書・指標ガイド
├── tests/          # Pester テスト
├── NarutoCode.ps1  # スクリプト本体（唯一の実行ファイル）
├── Format.ps1      # フォーマット適用 & 静的解析
├── RunTests.ps1    # テスト実行スクリプト
├── README.md       # 本ファイル
├── AGENTS.md       # AI エージェント向け開発ルール
└── LICENSE
```

> **設計方針:** 配布容易性のため、スクリプト本体は `NarutoCode.ps1` の1ファイルに集約しています。

## ライセンス

[MIT License](LICENSE) — 自由に改変・再配布できます。
