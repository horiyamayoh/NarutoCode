# CSV 列名 英日対訳表

CSV / PlantUML の見出しを日本語化した際の対訳一覧です。

## 凡例

- **(概算)** / **(合計)** / **(範囲指定)** — 半角括弧で修飾語を付加
- **据置** — 意図的に英語のまま残した列名
- 内部オブジェクト（`ConvertFrom-SvnLogXml` パイプライン、JSON キー等）は対象外

---

## commits.csv（10 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| Revision | リビジョン | |
| Date | 日時 | |
| Author | 作者 | |
| MsgLen | メッセージ文字数 | |
| Message | メッセージ | |
| FilesChangedCount | 変更ファイル数 | |
| AddedLines | 追加行数 | |
| DeletedLines | 削除行数 | |
| Churn | チャーン | |
| Entropy | エントロピー | |

## committers.csv（40 列）

### Phase 1（基本指標 — 30 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| Author | 作者 | |
| CommitCount | コミット数 | |
| ActiveDays | 活動日数 | |
| FilesTouched | 変更ファイル数 | |
| DirsTouched | 変更ディレクトリ数 | |
| AddedLines | 追加行数 | |
| DeletedLines | 削除行数 | |
| NetLines | 純増行数 | |
| TotalChurn | 総チャーン | |
| ChurnPerCommit | コミットあたりチャーン | |
| DeletedToAddedRatio | 削除対追加比 | |
| ChurnToNetRatio | チャーン対純増比 | |
| ReworkRate | リワーク率 | 1 − |純増行数| ÷ 総チャーン |
| BinaryChangeCount | バイナリ変更回数 | |
| ActionAddCount | 追加アクション数 | |
| ActionModCount | 変更アクション数 | |
| ActionDelCount | 削除アクション数 | |
| ActionRepCount | 置換アクション数 | |
| SurvivedLinesToToRev | 生存行数 | blame 由来 |
| DeadAddedLinesApprox | 消滅追加行数 (概算) | 追加行数 − 生存行数 |
| OwnedLinesToToRev | 所有行数 | blame 由来 |
| OwnershipShareToToRev | 所有割合 | |
| AuthorChangeEntropy | 変更エントロピー | |
| AvgCoAuthorsPerTouchedFile | 平均共同作者数 | |
| MaxCoAuthorsPerTouchedFile | 最大共同作者数 | |
| MsgLenTotalChars | メッセージ総文字数 | |
| MsgLenAvgChars | メッセージ平均文字数 | |
| IssueIdMentionCount | 課題ID言及数 | |
| FixKeywordCount | 修正キーワード数 | |
| RevertKeywordCount | 差戻キーワード数 | |
| MergeKeywordCount | マージキーワード数 | |

### Phase 2（dead-detail 指標 — 7 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| SelfCancelLineCount | 自己相殺行数 | 自分が追加→自分が削除 |
| CrossRevertLines | 他者差戻行数 | 他者のコミットを自分が revert |
| RepeatedSameHunkEdits | 同一箇所反復編集数 | |
| PingPongCount | ピンポン回数 | A→B→A パターン |
| InternalMoveLineCount | 内部移動行数 | ファイル内の行移動 |
| ModifiedOthersCodeLines | 他者コード変更行数 | 他者が書いた行を自分が削除した行数。blame 由来 |
| ModifiedOthersCodeSurvivedLines | 他者コード変更生存行数 | 他者コード変更コミットで追加した行のうち ToRev 時点で生存している行数。blame 由来 |

### Phase 3（派生指標 — 2 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| OtherCodeChangeSurvivalRate | 他者コード変更生存率 | 他者コード変更生存行数 ÷ 他者コード変更行数 |
| PingPongPerCommit | ピンポン率 | ピンポン回数 ÷ コミット数 |

## files.csv（26 列）

### Phase 1（基本指標 — 20 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| FilePath | ファイルパス | |
| FileCommitCount | コミット数 | |
| FileAuthors | 作者数 | |
| AddedLines | 追加行数 | |
| DeletedLines | 削除行数 | |
| NetLines | 純増行数 | |
| TotalChurn | 総チャーン | |
| BinaryChangeCount | バイナリ変更回数 | |
| CreateCount | 作成回数 | |
| DeleteCount | 削除回数 | |
| ReplaceCount | 置換回数 | |
| FirstChangeRev | 初回変更リビジョン | |
| LastChangeRev | 最終変更リビジョン | |
| AvgDaysBetweenChanges | 平均変更間隔日数 | |
| ActivitySpanDays | 活動期間日数 | |
| SurvivedLinesFromRangeToToRev | 生存行数 (範囲指定) | blame 由来 |
| DeadAddedLines | 消滅追加行数 | `追加行数 − 生存行数 (範囲指定)` |
| TopAuthorShareByChurn | 最多作者チャーン占有率 | |
| TopAuthorShareByBlame | 最多作者blame占有率 | 据置：blame は固有名詞的 |
| HotspotScore | ホットスポットスコア | |
| RankByHotspot | ホットスポット順位 | |

### Phase 2（dead-detail 指標 — 5 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| SelfCancelLinesTotal | 自己相殺行数 (合計) | ファイル横断の合計 |
| CrossRevertLinesTotal | 他者差戻行数 (合計) | |
| RepeatedSameHunkEditsTotal | 同一箇所反復編集数 (合計) | |
| PingPongCountTotal | ピンポン回数 (合計) | |
| InternalMoveLinesTotal | 内部移動行数 (合計) | |

## couplings.csv（5 列）

| 英語（旧） | 日本語（新） | 備考 |
|---|---|---|
| FileA | ファイルA | |
| FileB | ファイルB | |
| CoChangeCount | 共変更回数 | |
| Jaccard | Jaccard | 据置：統計学の固有名詞 |
| Lift | リフト値 | |

## PlantUML ヘッダー

| ファイル | 英語（旧） | 日本語（新） |
|---|---|---|
| contributors_summary.puml | `+ Author \| CommitCount \| TotalChurn` | `+ 作者 \| コミット数 \| 総チャーン` |
| hotspots.puml | `+ Rank \| FilePath \| HotspotScore` | `+ ホットスポット順位 \| ファイルパス \| ホットスポットスコア` |
| cochange_network.puml | `co=N\nj=X` | 変更なし（ラベル略記のまま） |

---

## 翻訳方針メモ

1. **半角括弧** — 修飾語は `XXX (合計)` のように半角スペース＋半角括弧で付加。アンダースコア不使用。
2. **削除 vs 消滅** — 「削除」は diff の `-` 行による明示的アクション。「消滅」は `追加行数 − 生存行数` で算出される結果的な状態。
3. **据置** — `Jaccard`（統計学固有名詞）、`blame`（SCM 固有名詞）は英語のまま。
4. **対象外** — JSON キー (`run_meta.json`)、内部パイプラインオブジェクト (`Commit`, `PathChange`, `DiffStat`, `BlameSummary`) はすべて英語のまま。
