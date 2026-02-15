# NarutoCode 並列ランタイム設計書

## 1. 目的 / 非目的
### 1.1 目的
- Runspace 固有実装を撤去し、`DAG 実行 + SvnGateway + shared executor` へ統一する。
- Step 3/5 のボトルネックを優先改善しつつ、全 Step を同一方式で段階並列化可能にする。
- `-Parallel` 指定に対して決定的な成果物を維持したまま実行時間を短縮する。

### 1.2 非目的
- 数学的厳密性を下げる近似・省略・ヒューリスティック導入は行わない。
- 公開 CLI に細粒度並列パラメータを追加しない（`-Parallel` のみ維持）。

## 2. 設計原則
- 厳密性優先: 結果精度を下げる最適化は禁止。
- 決定性: `-Parallel` 値に依存せず、CSV/JSON の値と順序を一致させる。
- 単一路線: SVN I/O は `Invoke-SvnGatewayCommand` 経路に統一する。
- 拡張性: Step 固有の並列基盤は増やさず、DAG ノード定義で制御する。

## 3. Runtime 全体図
1. `Invoke-NarutoCodePipeline` が `New-PipelineRuntime` を生成する。
2. `Invoke-PipelineDag` が依存関係を解決してノードを実行する。
3. ノード内部の並列処理は `Invoke-ParallelWork`（shared executor）へ統一する。
4. `Invoke-SvnCommand` は `Invoke-SvnGatewayCommand` を介してコマンド重複を排除する。

## 4. SvnGateway 規則
- コマンドキーが一致した `svn` 呼び出しは 1 回のみ実行し、結果を共有する。
- `Invoke-SvnCommandCore` が外部プロセス実行の唯一入口。
- command cache は `SvnGatewayCommandCacheMaxEntries` を上限とし、Hard 圧力時は挿入停止。

## 5. 決定性契約
- DAG ノードは ID ソート順で実行し、依存解決順を安定化する。
- `StageDurations` はノード単位で記録し、成果物内容と独立させる。
- Step 6/7 は粗粒度ノード（`step6_csv`, `step7_visual`）で固定する。
- `step6_csv` / `step7_visual` は `step5_cleanup` 依存を必須とする。

## 6. Step 構成
1. `step2_log`
2. `step3_diff`
3. `step4_committer`, `step4_file`, `step4_coupling`, `step4_commit`
4. `step5_strict`
5. `step5_cleanup`
6. `step6_csv`
7. `step7_visual`
8. `step8_meta`（依存: `step4_file`, `step5_cleanup`, `step6_csv`, `step7_visual`）

## 7. 失敗時挙動
- first-failure-only を維持し、最初の失敗を再送出する。
- DAG の循環依存検出時は `INTERNAL_DAG_CYCLE_DETECTED` で失敗。
- Strict 内では既存の `STRICT_*` 例外コードを維持する。

## 8. メモリガバナ
- `New-PipelineRuntime` で governor state を初期化する。
- 観測ポイント:
  - `Invoke-PipelineDag` の stage start/end
  - strict attribution 開始/コミット境界などの高コスト区間
- 圧力ポリシー:
  - `Soft`: 有効並列度を半減（`ceil(P/2)`）
  - `Hard`: さらに半減 + cache purge
  - `Hard streak >= 3 at P=1`: emergency purge + forced GC

## 9. テスト戦略
- `-Parallel 1` と `-Parallel N` の成果物一致。
- Step 3/5 の失敗伝播（first-failure）回帰確認。
- DAG guard / merge order の決定性確認。
- `run_meta.StageDurations` のキー体系（`step6_csv`, `step7_visual`）確認。

## 10. 性能計測方針
- run_meta の `DurationSeconds` と `StageDurations` を継続記録する。
- `StrictBlameCacheHits/Misses` と `StrictBlameCallCount` を観測する。
- 同一入力で `-Parallel` 値を変えた比較（cold/warm、中央値）を継続する。
