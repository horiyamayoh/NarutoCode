# エラーハンドリング方針（NarutoCode）

## 1. 基本方針
- コア解析処理は `fail-fast` とし、異常時は `ErrorCode` 付き例外を即時送出する。
- 可視化・補助出力は `best-effort` とし、失敗は `NarutoResult(Status='Skipped')` で返して解析本体は継続する。
- ユーザー向けメッセージは日本語、`ErrorCode` は英大文字スネークケースで管理する。

## 2. NarutoResult 契約
内部関数の戻り値は原則として `NarutoResult`（`[pscustomobject]`）を返す。

| フィールド | 型 | 意味 |
|---|---|---|
| `IsSuccess` | `bool` | 成功可否。`Status='Success'` のとき `True`。 |
| `Status` | `string` | `Success` / `Skipped` / `Failure`。 |
| `ErrorCode` | `string` | 機械判定用コード。 |
| `Message` | `string` | 人間向け説明。 |
| `Data` | `object` | 正常データまたは補助情報。 |
| `Context` | `hashtable` | 追加診断情報。 |

`$null` や空配列によるセンチネル返却は廃止し、`Status` で意味を表現する。

## 3. 例外契約
`Throw-NarutoError` で生成する例外は `System.Exception.Data` に次を格納する。

- `ErrorCode`
- `Category`
- `Context`

`Get-NarutoErrorInfo` は `ErrorRecord/Exception` からこれらを標準形へ抽出する。

## 4. ログ基準
- コア失敗: 例外送出（`Throw-NarutoError`）し、上位で 1 回だけ最終表示する。
- 可視化スキップ: `Write-NarutoDiagnostic -Level Verbose` を基本とする。
- 出力先不備や `error_report.json` 生成失敗など運用上重要な事象: `Warning` で出力する。

`Write-NarutoDiagnostic` は `Context.Diagnostics` を更新する。

- `WarningCount`
- `WarningCodes`
- `SkippedOutputs`

## 5. ErrorCode とカテゴリ
カテゴリは `INPUT`, `ENV`, `SVN`, `PARSE`, `STRICT`, `OUTPUT`, `INTERNAL` を使用する。

代表的な `ErrorCode`:

- `INPUT`: `INPUT_INVALID_REPO_URL`, `INPUT_UNSUPPORTED_ENCODING`, `INPUT_REQUIRED_FUNCTION_NOT_FOUND`
- `ENV`: `ENV_SVN_EXECUTABLE_NOT_FOUND`
- `SVN`: `SVN_COMMAND_FAILED`, `SVN_TARGET_MISSING`, `SVN_VERSION_UNAVAILABLE`, `SVN_REPOSITORY_VALIDATION_FAILED`
- `PARSE`: `PARSE_XML_FAILED`
- `STRICT`: `STRICT_BLAME_LOOKUP_FAILED`, `STRICT_BLAME_ATTRIBUTION_FAILED`, `STRICT_HUNK_ANALYSIS_FAILED`, `STRICT_OWNERSHIP_BLAME_FAILED`, `STRICT_DEATH_ATTRIBUTION_NULL`
- `OUTPUT`: `OUTPUT_DIRECTORY_EMPTY`, `OUTPUT_DIRECTORY_CREATE_FAILED`, `OUTPUT_VISUALIZATION_SKIPPED`, `OUTPUT_PROJECT_DASHBOARD_NO_DATA`
- `INTERNAL`: `INTERNAL_UNEXPECTED_ERROR`, `INTERNAL_PARALLEL_WORK_FAILED`
- レポート出力関連: `ERROR_REPORT_WRITTEN`, `ERROR_REPORT_WRITE_FAILED`, `ERROR_REPORT_SKIPPED_NO_OUTDIR`

## 6. 終了コード
CLI 実行時はカテゴリから終了コードを確定する。

| Category | ExitCode |
|---|---|
| `INPUT` | `10` |
| `ENV` | `20` |
| `SVN` | `30` |
| `PARSE` | `40` |
| `STRICT` | `50` |
| `OUTPUT` | `60` |
| `INTERNAL` | `70` |

## 7. 失敗時成果物
スクリプト直実行時の失敗では次を行う。

- コンソールへ `[ErrorCode] メッセージ` を 1 回だけ表示
- `error_report.json` を `OutDirectory` 配下に出力（未指定時は `NarutoCode_out`）
- `error_report.json` 必須フィールド:
  - `Timestamp`
  - `ErrorCode`
  - `Category`
  - `Message`
  - `Context`
  - `ExitCode`

`error_report.json` 生成に失敗した場合は Warning を追加出力し、元の失敗を優先する。

## 8. 成功時診断メタデータ
`run_meta.json` の `Diagnostics` には次を記録する。

- `WarningCount`
- `WarningCodes`
- `SkippedOutputs`
