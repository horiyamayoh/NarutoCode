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
| `-ExcludeCommentOnlyLines` | | | コメント専用行（コードを含まない行）を全メトリクスで除外 |
| `-NoProgress` | | | 進捗バー表示を抑止 |

> 旧パラメータ名（`-Path`, `-FromRevision`, `-ToRevision` 等）はエイリアスとして引き続き使用可能です。
> `-ExcludeCommentOnlyLines` は拡張子ごとの組み込みプロファイル（`CStyle` / `CSharpStyle` / `JsTsStyle` / `PowerShellStyle` / `IniStyle`）を使い、コメント記法と文字列リテラル境界の両方を判定します。

## 出力ファイル

```
<OutDir>/
├── run_meta.json              ← 実行条件・結果の記録
├── committers.csv             ← 開発者ごとの集計
├── files.csv                  ← ファイルごとの集計
├── commits.csv                ← コミット単位のログ
├── couplings.csv              ← ファイル同時変更ペアの関連度
├── kill_matrix.csv            ← 作者間の削除関係（キルマトリクス）
├── contributors_summary.puml  ← コミッター表（PlantUML）
├── hotspots.puml              ← ホットスポット表（PlantUML）
├── cochange_network.puml      ← 共変更ネットワーク図（PlantUML）
├── file_hotspot.svg           ← ファイルのホットスポット散布図
├── file_quality_scatter.svg   ← ファイル品質散布図
├── committer_outcome_combined.svg
├── committer_outcome_*.svg    ← 作者別の成果/差戻可視化
├── committer_scatter_combined.svg
├── committer_scatter_*.svg    ← 作者別のリワーク散布図
├── team_survived_share.svg    ← 生存行数のチーム内シェア
├── team_interaction_heatmap.svg
├── team_activity_profile.svg  ← チーム活動プロファイル
├── commit_timeline.svg        ← 時系列コミット量
├── commit_scatter.svg         ← コミット粒度散布図
└── cache/                     ← diff / blame / cat のキャッシュ
```

`-TopN` は可視化ファイルの表示件数にのみ適用され、CSV は常に全件出力されます。

詳細な指標の読み方は [docs/metrics_guide.md](docs/metrics_guide.md) を参照してください。  
並列ランタイムの設計思想と進捗は [docs/parallel_runtime_design.md](docs/parallel_runtime_design.md) を参照してください。

## 並列性能の目安（SLO）

- 基準環境: `tests/fixtures/svn_repo/repo`、`-FromRev 1 -ToRev 20`
- 判定はウォームアップ 1 回の後、本計測 5 回の中央値で比較
- 必須条件:
  - `median(step3_diff + step5_strict, -Parallel 4) <= 0.80 * median(..., -Parallel 1)`
  - `median(total wallclock, -Parallel 4) < median(total wallclock, -Parallel 1)`

`run_meta.json` の `DurationSeconds` は実行全体の壁時計時間を表し、`StageDurations` は `step8_meta` を含む全ステージを出力します。

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

## エラーコード / 終了コード / error_report.json

- コア解析は `fail-fast`、可視化は `best-effort` として動作します。
- 失敗時は `[ErrorCode] メッセージ` を 1 回だけ表示し、カテゴリ別終了コードで終了します。

| Category | 終了コード |
|---|---|
| INPUT | 10 |
| ENV | 20 |
| SVN | 30 |
| PARSE | 40 |
| STRICT | 50 |
| OUTPUT | 60 |
| INTERNAL | 70 |

失敗時には `OutDir` 配下に `error_report.json` を出力します（`OutDir` 未指定時は `NarutoCode_out`）。

`error_report.json` の主なフィールド:
- `Timestamp`
- `ErrorCode`
- `Category`
- `Message`
- `Context`
- `ExitCode`

成功時の `run_meta.json` には `Diagnostics` セクションが追加されます。
- `WarningCount`
- `WarningCodes`
- `SkippedOutputs`

詳細な方針は `docs/error_handling_policy.md` を参照してください。
## テスト実行（RunTests.ps1）

```powershell
# 通常実行（Oracle 統合テストは除外）
.\RunTests.ps1

# Oracle 統合テストを含めて実行
.\RunTests.ps1 -RunOracleIntegration
```

`RunTests.ps1` は既定で `Oracle` タグ付きテストを除外します。
`-RunOracleIntegration` を指定したときだけ、`Oracle` タグ付き統合テストを実行します。

## Breaking change: explicit Context for library-style usage

When dot-sourcing NarutoCode.ps1 and calling functions directly, implicit global context is no longer used.

- Create a context explicitly with New-NarutoContext.
- Initialize runtime/strict sections with Initialize-StrictModeContext -Context <ctx> when needed.
- Pass -Context <ctx> explicitly to Context-aware functions.
