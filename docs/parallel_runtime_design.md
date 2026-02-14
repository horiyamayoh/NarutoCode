# NarutoCode 並列ランタイム設計書

## 1. 目的 / 非目的
### 1.1 目的
- Runspace 固有実装を撤去し、`DAG 実行 + RequestBroker + SvnGateway` へ統一する。
- Step 3/5 のボトルネックを優先改善しつつ、全Stepを同一方式で段階並列化可能にする。
- `(op, rev, path, flags, peg)` 単位で要求重複を排除し、決定的出力を維持する。

### 1.2 非目的
- 数学的厳密性を下げる近似・省略・ヒューリスティック導入は行わない。
- 公開 CLI に細粒度並列パラメータを追加しない（`-Parallel` のみ維持）。

## 2. 設計原則
- 厳密性優先: 結果精度を下げる最適化は禁止。
- 決定性: `-Parallel` 値に依存せず、CSV/JSON の値と順序を一致させる。
- 単一路線: SVN I/O は必ず Broker/Gateway 経路を通す。
- 拡張性: Step 固有の並列実装は増やさず、DAG ノード定義のみ追加する。

## 3. Runtime 全体図
1. `Invoke-NarutoCodePipeline` が `New-PipelineRuntime` を生成する。
2. `Invoke-PipelineDag` が依存関係を解決してノードを実行する。
3. ノード内部の SVN 要求は `Register-SvnRequest` で登録する。
4. `Wait-SvnRequest` が未解決要求を `Invoke-SvnGateway` で評価する。
5. `Invoke-SvnCommand` は `Invoke-SvnGatewayCommand` を介してコマンド重複を排除する。

## 4. Request キー仕様
- 正規化キー構成:
  - `op`
  - `revision`
  - `revision_range`
  - `path`
  - `peg`
  - `flags`（順序非依存）
- 正規化規則:
  - `op`/`flags` は小文字化
  - `path` は `ConvertTo-PathKey` で正規化
  - `flags` はソート後に連結

## 5. SvnGateway 融合規則
- コマンドキーが一致した `svn` 呼び出しは 1 回のみ実行し、結果を共有する。
- `blame_line_prefetch` / `blame_line` / `blame_summary` / `diff` は Broker の重複排除対象。
- `Invoke-SvnCommandCore` が外部プロセス実行の唯一入口。

## 6. 決定性契約
- DAG ノードは ID ソート順で実行し、依存解決順を安定化する。
- RequestBroker は登録順を保持し、結果辞書はキーで再参照する。
- run_meta に `StageDurations` を記録するが、成果物内容と独立させる。

## 7. Step 移行手順
1. ノードの `Action` を DAG に登録。
2. `BuildRequests` 相当処理として `Register-SvnRequest` を行う。
3. `Wait-SvnRequest` 後に `Reduce` 相当処理で既存集計へ反映。
4. 既存 Step ロジックの厳密性を維持したまま、直接 SVN 呼び出しを縮小する。

## 8. 失敗時挙動
- 未登録キー待機は `INTERNAL_REQUEST_KEY_NOT_FOUND` で失敗。
- Resolver 失敗は `SVN_REQUEST_FAILED` として共通化。
- DAG の循環依存検出時は `INTERNAL_DAG_CYCLE_DETECTED` で失敗。
- DAG ノード ID 未指定時は `INPUT_DAG_NODE_ID_REQUIRED` で失敗。
- Strict 内では既存の `STRICT_*` 例外コードを維持する。

## 9. テスト戦略
- `-Parallel 1` と `-Parallel N` の成果物一致。
- 重複登録時の単一実行保証。
- Step 3/5 の回帰（strict attribution / ownership / diff filtering）。
- `StageDurations` の run_meta 出力確認。

## 10. 性能計測方針
- run_meta の `DurationSeconds` と `StageDurations` を継続記録する。
- `StrictBlameCacheHits/Misses` と `StrictBlameCallCount` を観測する。
- 同一入力で `-Parallel` 値を変えた比較を継続し、回帰を監視する。

## 11. 進捗管理表

| Step | 状態 | Broker化 | Gateway融合対応 | 決定性テスト | 性能計測日 | 備考 |
|---|---|---|---|---|---|---|
| Step 2/3: Log+Diff | Done | Done | Done | Done | 2026-02-14 | Diff prefetch を登録/待機/還元に移行 |
| Step 4: Aggregation | Done | N/A | N/A | Done | 2026-02-14 | 純計算フェーズのため SVN I/O なし。4 DAG ノード（committer/file/coupling/commit）に分割し並列実行 |
| Step 5: Strict Attribution | Done | Done | Done | Done | 2026-02-14 | 遷移計画と preloaded blame の二相実行へ移行 |
| Step 6: CSV | Done | N/A | N/A | Done | 2026-02-14 | DAG ノードとして統合。出力順序決定性テスト済み |
| Step 7: Visualization | Done | N/A | N/A | Done | 2026-02-14 | DAG ノードとして統合。出力順序決定性テスト済み |
| Step 8: run_meta | Done | Done | Done | Done | 2026-02-14 | StageDurations 全ステージ出力完了 |
