# NarutoCode アルゴリズム厳密化設計書

## 1. 概要

本設計書は、NarutoCode が出力する全指標のうち、近似・概算・丸め・ヒューリスティック等により
数学的に厳密でない値を出力しているものを網羅的に特定し、
それぞれについて「数学的に完全に正しい計算方法」への変更設計を記述する。

### 1.1 設計方針

- **計算コストは制約としない。** ユーザーはローカルに SVN ダンプをコピーした専用サーバーで
  夜間・休日にフルパワーで計算を回す運用を想定している。
- **近似ゼロ** を目指す。原理的に厳密化不可能なものだけを例外として明示する。

### 1.2 実装状態

> **注意: Strict モードは現在デフォルトで常時有効です。**
> 当初は `-StrictMode` スイッチで切り替える設計だったが、
> 概算モードを維持する必要がなくなったため、以下の動作がデフォルトとなった：

- `DeadDetailLevel` は常に最大（2）
- per-revision blame を常時実行
- `Get-RoundedNumber` による丸めを行わない
- 共変更分析のファイル数上限なし（全コミットを無条件に集計）
- リネーム時の追加/削除行数の二重計上を補正
- ハッシュベースの指標を per-revision blame ベースに置き換え済み

また以下の旧パラメータは削除済み：
- `-StrictMode`: 不要（常時有効）
- `-NoBlame`: 削除（blame は常時実行）
- `-DeadDetailLevel`: 削除（常に最大値 2）

---

## 2. 厳密化対象の全体マップ

全 30 件を「厳密化に必要なアルゴリズム変更」の 10 グループに分類する。

### 凡例
- **カテゴリ A**: 既に `(概算)` ラベルが付いている指標
- **カテゴリ B**: ラベルなしだが実際は近似値を出力している指標（隠れた近似）
- **カテゴリ C**: 丸め・ゼロ除算回避・クランプ等による精度損失

### 全 30 件一覧

| No. | 指標名 | 出力先 | カテゴリ | 厳密化グループ |
|-----|--------|--------|----------|----------------|
| 1 | 消滅追加行数 | committers / files | — | G1: per-revision blame |
| ~~2~~ | ~~自己消滅行数~~ | ~~committers~~ | — | 削除済み（自己相殺行数に統合） |
| ~~3~~ | ~~被他者消滅行数~~ | ~~committers~~ | — | 削除済み（他者差戻行数に統合） |
| 4 | 自己相殺行数 | committers | B | G1: per-revision blame |
| ~~5~~ | ~~自己差戻行数~~ | ~~committers~~ | — | 削除済み（自己相殺行数に統合） |
| 6 | 他者差戻行数 | committers | B | G1: per-revision blame |
| ~~7~~ | ~~被他者削除行数~~ | ~~committers~~ | — | 削除済み（他者差戻行数に統合） |
| 8 | 内部移動行数 | committers / files | B | G1: per-revision blame |
| 9 | 生存行数 | committers | B | G1: per-revision blame |
| 10 | 生存行数 (範囲指定) | files | B | G1: per-revision blame |
| 11 | 所有行数 | committers | B | G2: 全ファイル blame |
| 12 | 所有割合 | committers | B | G2: 全ファイル blame |
| 13 | 他者コード変更行数 | committers | — | G1: per-revision blame |
| 14 | 他者コード変更生存行数 | committers | — | G1 + G2: per-revision blame + 全ファイル blame |
| 13 | 最多作者blame占有率 | files | B | G1: per-revision blame |
| 14 | 同一箇所反復編集数 | committers / files | B | G3: 正準行範囲追跡 |
| 15 | ピンポン回数 | committers / files | B | G3: 正準行範囲追跡 |
| 16 | 追加行数 | 全CSV | B | G4: リネーム二重計上補正 |
| 17 | 削除行数 | 全CSV | B | G4: リネーム二重計上補正 |
| 18 | 共変更回数 | couplings | B | G5: 大規模コミット上限撤廃 |
| 19 | Jaccard | couplings | B | G5 + G6: 上限撤廃 + 丸め除去 |
| 20 | リフト値 | couplings | B | G5 + G6: 上限撤廃 + 丸め除去 |
| 21 | コミットあたりチャーン | committers | C | G6: 丸め除去 |
| 22 | 削除対追加比 | committers | C | G6 + G7: 丸め除去 + null化 |
| 23 | チャーン対純増比 | committers | C | G6 + G7: 丸め除去 + null化 |
| 24 | 変更エントロピー | committers / commits | C | G6: 丸め除去 |
| 25 | 平均共同作者数 | committers | C | G6: 丸め除去 |
| 26 | メッセージ平均文字数 | committers | C | G6: 丸め除去 |
| 27 | 平均変更間隔日数 | files | C | G6: 丸め除去 |
| 28 | 最多作者チャーン占有率 | files | C | G6: 丸め除去 |
| 29 | 課題ID言及数 | commits | B | G8: 原理的に厳密化不可能 |
| 30 | 修正/差戻/マージキーワード数 | commits | B | G8: 原理的に厳密化不可能 |

---

## 3. 厳密化グループ G1: per-revision blame による行レベル完全履歴

### 3.1 対象指標（13 件）

| No. | 指標名 | 現行の近似原因 |
|-----|--------|---------------|
| 1 | 消滅追加行数 | `max(0, 追加行数 − 生存行数)` — 現行の正式計算式 |
| ~~2~~ | ~~自己消滅行数~~ | 削除済み（自己相殺行数に統合） |
| ~~3~~ | ~~被他者消滅行数~~ | 削除済み（他者差戻行数に統合） |
| 4 | 自己相殺行数 | SHA1 ハッシュ照合 — トリビアル行（`}` 等）で偽陽性 |
| ~~5~~ | ~~自己差戻行数~~ | 削除済み（自己相殺行数に統合） |
| 6 | 他者差戻行数 | 同じハッシュ照合問題 |
| ~~7~~ | ~~被他者削除行数~~ | 削除済み（他者差戻行数に統合） |
| 8 | 内部移動行数 | 同一コミット内のハッシュ照合 — トリビアル行で誤検出 |
| 9 | 生存行数 | ToRev 時点の blame のみ — 途中経過が不明 |
| 10 | 生存行数 (範囲指定) | 同上 |
| 13 | 最多作者blame占有率 | ToRev blame のみに依存 |

また、`max(0, dead)` クランプ（NarutoCode.ps1 L1922, L1963, L2035, L2038）は
per-revision blame 導入により負値が原理的に発生しなくなるため、自然に解消される。

### 3.2 現行アルゴリズムの問題点

#### 3.2.1 blame が ToRev の最終状態のみ

現在 `Get-SvnBlameSummary`（L831）は ToRev 時点でのみ `svn blame` を実行し、
各行の「最終更新リビジョン」を取得する。これにより：

- ある行が range 内の r100 で追加され、r105 で他者に上書きされた場合、
  blame は r105 を返す。r100 の作者の「生存行数」にカウントされない。
- ファイルが ToRev より前に削除された場合、blame 自体が失敗し
  全追加行が dead 扱いになる（L2044-L2046）。

#### 3.2.2 ハッシュベース照合の偽陽性

`ConvertTo-LineHash`（L500-L518）は `SHA1(filePath + \0 + normalizedContent)` を計算する。
旧 `Get-DeadLineDetail`（削除済み）で追加行ハッシュと削除行ハッシュを照合していたが、
以下の問題があったため `Get-ExactDeathAttribution`（blame ベース）に完全置換された：

- `Test-IsTrivialLine`（L526-L540）で定義されたトリビアル行（`{`, `}`, `return;` 等）
  のフィルタリングが**実際には呼び出されていなかった**。
  トリビアル行は同一ファイル内で頻出するため、大量の偽陽性 self-cancel が発生していた。
- `addedMultiset` は FIFO キューで消費されるため、
  同一ハッシュの複数行がある場合に「最初の追加者」が消費された。
  これは実際の行の対応関係と一致しない場合があった。
- リネーム時、diff パース段階ではハッシュが旧パス名で計算されるが、
  旧関数内では `$resolvedFile`（リネーム後パス）でキーを構築していた。
  旧パスで計算されたハッシュと新パスでのキーの不一致により、
  リネーム前後のマッチングが正しく動作しなかった。

### 3.3 厳密アルゴリズム: per-revision blame 比較

#### 3.3.1 基本原理

ファイル $f$ が変更された各リビジョン $r$ について、$r$ の直前と直後の blame 出力を比較し、
**どの行が消えたか（= 誰の行を誰が消したか）** を直接観測する。

```
入力:
  F = { f | f はリビジョン範囲 [FromRev, ToRev] 内で変更されたファイル }
  R(f) = { r | r はファイル f が変更されたリビジョン } （昇順ソート）

処理:
  For each f ∈ F:
    Let R(f) = [r₁, r₂, ..., rₖ]
    
    blame_prev ← svn blame f@(r₁ - 1)    # range 開始前の状態
    
    For i = 1 to k:
      blame_curr ← svn blame f@rᵢ        # rᵢ 適用後の状態
      killer ← revToAuthor[rᵢ]
      
      # LCS アルゴリズムで 2 つの blame 出力を整列
      alignment ← LCS(blame_prev.contents, blame_curr.contents)
      
      For each line L in blame_prev that has no match in alignment:
        # L は rᵢ で消滅した行
        original_author ← L.attributed_author
        born_rev ← L.attributed_revision
        Record: LineKilled(f, original_author, killer, born_rev, rᵢ)
      
      For each line L in blame_curr that has no match in alignment:
        # L は rᵢ で誕生した行
        Record: LineBorn(f, killer, rᵢ)
      
      For each matched pair (L_prev, L_curr) in alignment:
        If L_prev.attributed_revision ≠ L_curr.attributed_revision:
          # 内容は同じだが blame 属性が変化 → 行の再帰属（merge 等）
          # 厳密にはこれは「移動」でも「削除」でもない
          Record: LineReattributed(f, L_prev, L_curr, rᵢ)
      
      blame_prev ← blame_curr

出力: LineKilled[] と LineBorn[] の完全リスト
```

#### 3.3.2 LCS（最長共通部分列）アルゴリズム

2 つの blame 出力（行の配列）を整列する関数。各行は `(content, revision, author)` のタプル。

```
function Compare-BlameOutputs:
  入力:
    prev_lines: blame_prev の行配列 (content のみ抽出した文字列配列)
    curr_lines: blame_curr の行配列 (同上)
  
  処理:
    # 標準的な LCS DP テーブルを構築
    # content の完全一致で比較（ハッシュではなく原文）
    m ← len(prev_lines)
    n ← len(curr_lines)
    dp[0..m][0..n] ← 0
    
    For i = 1 to m:
      For j = 1 to n:
        If prev_lines[i] == curr_lines[j]:
          dp[i][j] ← dp[i-1][j-1] + 1
        Else:
          dp[i][j] ← max(dp[i-1][j], dp[i][j-1])
    
    # バックトラックで一致・不一致を分類
    matched_prev ← {}    # prev 側で curr と一致した行インデックス集合
    matched_curr ← {}    # curr 側で prev と一致した行インデックス集合
    
    i ← m, j ← n
    While i > 0 and j > 0:
      If prev_lines[i] == curr_lines[j]:
        matched_prev.add(i)
        matched_curr.add(j)
        i--, j--
      ElseIf dp[i-1][j] >= dp[i][j-1]:
        i--
      Else:
        j--
    
    killed_lines ← { prev[i] | i ∉ matched_prev }
    born_lines ← { curr[j] | j ∉ matched_curr }
    
  出力: (killed_lines, born_lines, matched_pairs)
```

#### 3.3.3 大規模ファイルへの対応

LCS の計算量は $O(m \times n)$ で、大規模ファイル（数万行）では重くなる。
以下の最適化を適用する：

1. **行内容のハッシュ化による前処理**: 行内容を整数 ID にマッピングし、
   整数配列の LCS に帰着させる（比較コストを $O(1)$ に削減）。
2. **差分が小さい場合の最適化**: `svn diff -c rᵢ` のハンク情報から
   変更範囲を特定し、変更のない行ブロックを事前にマッチさせて
   LCS の計算範囲を狭める。
3. **Hunt-McIlroy アルゴリズム**: 差分が小さい場合に
   $O((m+n) \log m)$ で動作する diff アルゴリズムを使用する。

#### 3.3.4 削除済みファイルの扱い

ファイルがリビジョン $r_d$ で削除（action=D）された場合：

```
# 削除直前のリビジョンで blame を取得
blame_before_deletion ← svn blame f@(rᵢ - 1)

# blame_after は空（ファイルが存在しない）
# → blame_before_deletion の全行が killed
For each line L in blame_before_deletion:
  Record: LineKilled(f, L.attributed_author, author_of(rᵢ), L.attributed_revision, rᵢ)
```

現行コードでは `try/catch` で blame 失敗をスキップしている（L1886-L1892）が、
厳密モードでは削除直前の blame を明示的に取得する。

#### 3.3.5 blame キャッシュ

per-revision blame は SVN リビジョンに対して不変であるため、
既存の diff キャッシュ（`cache/diff_r{REV}.txt`）と同じパターンでキャッシュする。

```
キャッシュディレクトリ構成:
  cache/
  ├── diff_r1.txt
  ├── diff_r2.txt
  ├── ...
  └── blame/
      ├── r0/
      │   ├── {pathHash}.xml      ← SHA1(filePath) をファイル名に使用
      │   └── ...
      ├── r3/
      │   └── {pathHash}.xml
      └── ...

キャッシュキー: (revision, filePath) のペア
キャッシュ内容: svn blame --xml の生 XML 出力
無効化: 不要（SVN リビジョンは不変）
```

#### 3.3.6 `ConvertFrom-SvnBlameXml` の拡張

現在の `ConvertFrom-SvnBlameXml`（L730-L800）は行を集約して
`LineCountByRevision` / `LineCountByAuthor` を返す。
per-revision blame 比較には**行単位の生データ**が必要。

```powershell
# 現行の戻り値（集約済み）:
[pscustomobject]@{
    LineCountTotal = $total
    LineCountByRevision = $byRev      # hashtable[rev → count]
    LineCountByAuthor = $byAuthor     # hashtable[author → count]
}

# 厳密モード用の追加戻り値:
[pscustomobject]@{
    LineCountTotal = $total
    LineCountByRevision = $byRev
    LineCountByAuthor = $byAuthor
    Lines = @(                        # ★ 新規: 行単位データの配列
        [pscustomobject]@{
            LineNumber = 1
            Content = "public class Helper {"   # ★ svn blame の行内容
            Revision = 100
            Author = "alice"
        },
        ...
    )
}
```

行内容を取得するには `svn blame` コマンドに `--xml` を使うだけでは不十分
（XML 出力には行内容が含まれない）。
代替案:

- **案 A**: `svn blame -r REV URL` （非 XML）のプレーンテキスト出力をパースする。
  各行が `REV  AUTHOR  CONTENT` 形式で出力される。
- **案 B**: `svn blame --xml` で revision/author を取得し、
  `svn cat -r REV URL` で行内容を取得して突合する。
  行番号で 1:1 対応するため確実。

**案 B を採用する。** `svn cat` の出力も同様にキャッシュする。

```
キャッシュ追加:
  cache/
  └── cat/
      ├── r3/
      │   └── {pathHash}.txt     ← svn cat の生テキスト出力
      └── ...
```

### 3.4 厳密化後の各指標の計算方法

#### 3.4.1 消滅追加行数（No.1）

```
現行: max(0, 追加行数 − 生存行数)
厳密: count({ e ∈ LineBorn | born_rev ∈ [FromRev, ToRev]
                             AND ∃ LineKilled where same line })
     = LineBorn のうち、後続の LineKilled イベントが存在するものの件数
```

per-revision blame により、各行の誕生と死亡を個別に追跡するため、
diff 累積の追加行数との乖離は発生しない。

#### 3.4.2 自己消滅行数 / 被他者消滅行数（No.2, No.3）

```
現行（No.2）: min(自己相殺行数, max(0, 消滅追加行数 − 内部移動行数))
現行（No.3）: max(0, 調整後消滅 − 自己消滅)

厳密（No.2）: count({ (born, killed) |
                born.author == killed.killer
                AND born.rev ∈ [FromRev, ToRev] })

厳密（No.3）: count({ (born, killed) |
                born.author ≠ killed.killer
                AND born.rev ∈ [FromRev, ToRev] })
```

`min()` / `max()` のクランプが不要になる。
2 つの合計は必ず No.1（消滅追加行数）と一致する。

#### 3.4.3 自己相殺行数 / 自己差戻行数（No.4, No.5）

```
現行: SHA1 ハッシュ照合による addedMultiset マッチング
厳密: No.2（自己消滅行数）と同義
     = per-revision blame で「自分が追加した行を自分が消した」件数
```

厳密モードでは No.2 と No.4/5 は同じ値になる。
（概算モードでは No.4 は「content hash が一致した行」、
No.2 は「No.4 を上限として消滅行数から割り当てた値」であり、
異なる値になりうる。）

#### 3.4.4 他者差戻行数 / 被他者削除行数（No.6, No.7）

```
現行: SHA1 ハッシュ照合。
     No.6 = 自分が追加した行を他者が削除した件数（ハッシュ一致）
     No.7 = No.6 と同値

厳密: No.3（被他者消滅行数）と同義
     = per-revision blame で「自分が追加した行を他者が消した」件数
```

#### 3.4.5 内部移動行数（No.8）

```
現行: 同一コミット・同一ファイル内で AddedLineHash と DeletedLineHash が
     一致する行数の min(add_count, del_count)

厳密: per-revision blame 比較で、rᵢ の前後で：
     - blame 属性（revision, author）が変化せず
     - 行番号のみが変化した行の件数
     = LCS alignment で matched_pair となった行のうち、
       行番号が変わったもの
```

blame 属性が不変で行番号だけ変化した場合、
その行は「移動」されたと判定できる。
ハッシュ照合では `}` 等のトリビアル行が誤検出されるが、
blame ベースでは各行の identity が revision 属性で一意に決まるため偽陽性がない。

#### 3.4.6 生存行数（No.9, No.10）

```
現行: ToRev 時点の blame で、revision ∈ [FromRev, ToRev] の行数を合計

厳密: count({ e ∈ LineBorn |
              born_rev ∈ [FromRev, ToRev]
              AND ∄ LineKilled for same line })
     = range 内で追加され、ToRev 時点でまだ生存している行数
```

per-revision blame では各行の誕生・死亡を個別追跡するため、
ToRev のスナップショットだけに頼る必要がない。
結果として、途中で上書きされた行も正確に追跡できる。

#### 3.4.7 最多作者blame占有率（No.13）

```
現行: ToRev 時点の blame で max(authorLineCount) / totalLines

厳密: 同じ計算だが、per-revision blame の副産物として
     ToRev 時点の blame が取得済みのため、追加コストなし。
     丸め除去（G6）のみ適用。
```

この指標は ToRev 時点の blame スナップショットで定義される指標であり、
per-revision blame でも最終状態の blame は取得されるため、
計算方法自体は変わらない。丸めの除去のみが変更点。

### 3.5 必要な新規関数

| 関数名 | 責務 | 入出力 |
|--------|------|--------|
| `Get-SvnBlameLines` | 指定リビジョンでのファイルの blame を行単位で取得 | (Repo, FilePath, Rev) → Line[] |
| `Get-SvnCatContent` | 指定リビジョンでのファイル内容を取得 | (Repo, FilePath, Rev) → string |
| `Compare-BlameOutputs` | 2 つの blame 行配列を LCS で整列し差分を返す | (prevLines, currLines) → (killed, born, matched) |
| `Get-ExactDeathAttribution` | 全ファイル・全リビジョンの per-revision blame を実行し完全な行履歴を構築 | (Commits, RevToAuthor, TargetUrl, ...) → LineHistory |
| `Read-BlameCacheFile` | blame キャッシュの読込 | (cacheDir, rev, filePath) → string or $null |
| `Write-BlameCacheFile` | blame キャッシュの書込 | (cacheDir, rev, filePath, content) → void |

### 3.6 既存関数への変更

| 関数 / コード箇所 | 変更内容 |
|-------------------|---------|
| `ConvertFrom-SvnBlameXml`（L730-L800） | 行単位データ（`Lines` プロパティ）を追加返却するモードを追加 |
| `Get-SvnBlameSummary`（L831-L839） | リビジョン引数を一般化（現在は ToRev 固定で呼ばれている） |
| ~~`Get-DeadLineDetail`~~（削除済み） | `Get-ExactDeathAttribution` に完全置換のため削除 |
| blame セクション（L1870-L2050） | `$StrictMode` 分岐を追加し、per-revision blame パイプラインを統合 |
| committer metric 代入（L2000-L2040） | 厳密値の代入。列名から `(概算)` を除去 |
| file metric 代入（L1905-L1942, L2044-L2090） | 同上 |

### 3.7 列名の変更

`-StrictMode` 有効時、概算ラベルを除去する。

| 現行列名 | 厳密モード列名 |
|----------|---------------|
| `消滅追加行数 (概算)` | `消滅追加行数`（実装済み） |
| `自己消滅行数 (概算)` | 削除済み（自己相殺行数に統合） |
| `被他者消滅行数 (概算)` | 削除済み（他者差戻行数に統合） |

CSV ヘッダ配列（L2095-L2100）を条件分岐する。

---

## 4. 厳密化グループ G2: 全ファイル blame による所有行数の完全化

### 4.1 対象指標（2 件）

| No. | 指標名 | 現行の近似原因 |
|-----|--------|---------------|
| 11 | 所有行数 | 変更ファイルのみ blame → 未変更ファイルの所有行が未カウント |
| 12 | 所有割合 | 同上（分子と分母の両方が不完全） |

### 4.2 現行アルゴリズムの問題点

現行コード（L1870-L1878）は、分析範囲内で変更されたファイル集合 `$fileMap.Keys` に
対してのみ `svn blame` を実行する。

著者 A が過去に 1000 行を書いたファイルが、今回の分析範囲内で変更されていない場合、
そのファイルの blame は取得されず、A の「所有行数」にカウントされない。

### 4.3 厳密アルゴリズム

```
入力: TargetUrl, ToRev

処理:
  # ToRev 時点のリポジトリ内の全ファイル一覧を取得
  all_files ← svn list -R --xml -r ToRev TargetUrl
  
  # フィルタ適用（IncludePaths, ExcludePaths, IncludeExtensions, ExcludeExtensions）
  target_files ← filter(all_files, user_filters)
  
  # 全ファイルに対して blame を実行
  For each f ∈ target_files:
    blame ← svn blame --xml -r ToRev TargetUrl/f@ToRev
    For each author a in blame:
      authorOwned[a] += blame.lineCountByAuthor[a]
    ownedTotal += blame.lineCountTotal
  
  # 所有割合の計算
  For each author a:
    ownershipShare[a] = authorOwned[a] / ownedTotal

出力: authorOwned, ownershipShare
```

### 4.4 必要な変更

| 変更箇所 | 内容 |
|----------|------|
| 新規関数 `Get-AllRepositoryFiles` | `svn list -R --xml -r ToRev` で全ファイル一覧を取得 |
| blame セクション（L1870-L1878） | `$StrictMode` 時は `$fileMap.Keys` の代わりに全ファイルを対象にする |
| blame キャッシュ | G1 で導入するキャッシュ基盤を共用 |

### 4.5 SVN コマンド

```
svn list -R --xml -r {ToRev} {TargetUrl}
```

出力は XML 形式でディレクトリエントリとファイルエントリを含む。
ディレクトリはスキップし、ファイルのみを抽出する。

---

## 5. 厳密化グループ G3: 正準行範囲追跡による「同一箇所」の厳密定義

### 5.1 対象指標（2 件）

| No. | 指標名 | 現行の近似原因 |
|-----|--------|---------------|
| 14 | 同一箇所反復編集数 | ContextHash（前後 3 行）が周辺コード変更で不安定 |
| 15 | ピンポン回数 | 同上 |

### 5.2 現行アルゴリズムの問題点

`ConvertTo-ContextHash`（L536-L574）は `SHA1(filePath | first3Context | last3Context)` を計算し、
hunk の「場所」を識別する。しかし：

1. **コンテキスト行のシフト**: 前のリビジョンで周辺に行が挿入/削除されると、
   同じ論理的箇所のコンテキスト行が変化し、異なる ContextHash が生成される。
   → **同一箇所なのに別箇所と判定**（偽陰性 = 過少カウント）
2. **コンテキスト行の偶然一致**: 異なる箇所が同じ前後 3 行を持つ場合、
   同じ ContextHash が生成される。
   → **別箇所なのに同一箇所と判定**（偽陽性 = 過大カウント）

### 5.3 厳密アルゴリズム: 正準行番号空間による箇所追跡

#### 5.3.1 正準行番号の定義

ファイル $f$ について、FromRev 時点の行番号を「正準行番号」とする。
以降の各リビジョンの diff ハンクが行番号にもたらすシフト量を累積的に合成し、
任意のリビジョンにおける行番号を正準行番号空間にマッピングする。

```
For file f:
  canonical_offset[f] ← identity mapping  # 初期状態: 行番号 = 正準行番号
  
  For each revision r where f was modified (in ascending order):
    For each hunk h in diff(f, r):
      # ハンクは old 空間の [h.OldStart, h.OldStart + h.OldCount - 1] を
      #         new 空間の [h.NewStart, h.NewStart + h.NewCount - 1] に変換する
      shift = h.NewCount - h.OldCount
      
      # ハンクの正準行範囲を記録
      canonical_start = canonical_offset[f].map(h.OldStart)
      canonical_end = canonical_offset[f].map(h.OldStart + h.OldCount - 1)
      hunk_canonical_range[f][r] = (canonical_start, canonical_end)
      hunk_author[f][r] = revToAuthor[r]
      
      # ハンク以降の行の正準オフセットを更新
      canonical_offset[f].shift_after(h.OldStart + h.OldCount, shift)
```

#### 5.3.2 「同一箇所」の判定

2 つのハンク（ファイル $f$、リビジョン $r_1$ と $r_2$）が「同一箇所」であるとは：

$$\text{canonical\_range}(f, r_1) \cap \text{canonical\_range}(f, r_2) \neq \emptyset$$

すなわち、正準行番号空間で行範囲がオーバーラップすること。

#### 5.3.3 同一箇所反復編集数の厳密計算

```
For file f:
  # 同一作者が同一箇所を複数回編集した回数
  For each pair (r₁, r₂) where r₁ < r₂ and same author:
    If canonical_range(f, r₁) ∩ canonical_range(f, r₂) ≠ ∅:
      repeated[author][f]++
```

#### 5.3.4 ピンポン回数の厳密計算

```
For file f:
  # 時系列で同一箇所に A→B→A パターンが発生した回数
  For each triple (r₁, r₂, r₃) where r₁ < r₂ < r₃:
    a₁ = hunk_author[f][r₁]
    a₂ = hunk_author[f][r₂]
    a₃ = hunk_author[f][r₃]
    If a₁ ≠ a₂ AND a₁ == a₃:
      If canonical_range(f, r₁) ∩ canonical_range(f, r₂) ∩ canonical_range(f, r₃) ≠ ∅:
        ping_pong[a₁][f]++
```

### 5.4 必要な新規関数

| 関数名 | 責務 |
|--------|------|
| `New-CanonicalOffsetMap` | ファイルごとの正準行番号マッピングを初期化 |
| `Update-CanonicalOffsetMap` | ハンクのシフト量で正準オフセットを更新 |
| `Get-CanonicalHunkRange` | ハンクの (OldStart, OldCount) を正準行番号に変換 |
| `Test-RangeOverlap` | 2 つの行範囲がオーバーラップするか判定 |
| `Get-StrictRepeatedHunkEdits` | 正準行範囲ベースで同一箇所反復を計算 |
| `Get-StrictPingPong` | 正準行範囲ベースでピンポンを計算 |

### 5.5 既存関数への変更

| 関数 / コード箇所 | 変更内容 |
|-------------------|---------|
| `ConvertTo-ContextHash`（L536-L574） | `$StrictMode` 時は呼び出さない |
| `ConvertFrom-SvnUnifiedDiff`（L576-L728） | ハンクの OldStart/OldCount を確実に返却（現行で既に実装済み） |
| ~~`Get-DeadLineDetail`~~（削除済み） | `Get-StrictHunkEventsByFile` + `Get-StrictHunkOverlapSummary` に置換 |

---

## 6. 厳密化グループ G4: リネーム時の追加/削除行数の二重計上補正

### 6.1 対象指標（2 件）

| No. | 指標名 | 現行の近似原因 |
|-----|--------|---------------|
| 16 | 追加行数 | リネーム時に旧パス全削除 + 新パス全追加で水増し |
| 17 | 削除行数 | 同上 |

### 6.2 現行アルゴリズムの問題点

SVN がファイルをリネーム（action=R）した場合、`svn diff -c rev` は
サーバー設定やクライアントバージョンに依存して：

- **パターン A**: 旧パスの全行削除 + 新パスの全行追加 として出力する
- **パターン B**: 旧パスと新パスの実際の差分のみを出力する

パターン A の場合、500 行のファイルをリネームしただけで
`追加行数 += 500`, `削除行数 += 500` と水増しされる。

現行コードの `ConvertFrom-SvnUnifiedDiff`（L576-L728）は
diff 出力をそのままパースし、リネームの検出を行っていない。

### 6.3 厳密アルゴリズム

```
For each commit c:
  rename_pairs ← {}
  
  # SVN ログからリネームペアを検出
  For each path_change p in c.ChangedPathsFiltered:
    If (p.Action == 'R' OR (p.Action == 'A' AND p.CopyFromPath ≠ null)):
      # 同一コミット内に対応する D アクションがあるか探す
      old_path ← p.CopyFromPath
      new_path ← p.Path
      rename_pairs.add((old_path, new_path, p.CopyFromRev))
  
  # リネームペアごとに実際の差分を取得
  For each (old_path, new_path, copy_from_rev) in rename_pairs:
    # 旧パスと新パスの実際の内容差分を取得
    real_diff ← svn diff {TargetUrl}/old_path@(copy_from_rev) {TargetUrl}/new_path@(c.Revision)
    real_stats ← parse(real_diff)
    
    # ナイーブな diff から得た水増し分を差し引く
    naive_old_stats ← c.FileDiffStats[old_path]  # 全行削除としてカウントされたもの
    naive_new_stats ← c.FileDiffStats[new_path]  # 全行追加としてカウントされたもの
    
    # 補正
    adjustment_added ← (naive_old_stats.Added + naive_new_stats.Added) - real_stats.Added
    adjustment_deleted ← (naive_old_stats.Deleted + naive_new_stats.Deleted) - real_stats.Deleted
    
    c.AddedLines -= adjustment_added
    c.DeletedLines -= adjustment_deleted
```

### 6.4 必要な変更

| 変更箇所 | 内容 |
|----------|------|
| メインループ内 diff 処理（L1760-L1850） | リネームペアの検出と補正 diff の取得 |
| `Get-CommitterMetric`（L842-L1035） | 補正済み行数を使用 |
| `Get-FileMetric`（L1037-L1193） | 補正済み行数を使用 |
| commits.csv 行数 | 補正済み行数を出力 |

### 6.5 追加の SVN コマンド

リネームペアごとに 1 回の `svn diff` が追加で必要：

```
svn diff {TargetUrl}/old_path@{CopyFromRev} {TargetUrl}/new_path@{Rev}
```

---

## 7. 厳密化グループ G5: 共変更分析の大規模コミット上限撤廃

### 7.1 対象指標（3 件）

| No. | 指標名 | 現行の近似原因 |
|-----|--------|---------------|
| 18 | 共変更回数 | 解消済み（ファイル数上限を撤廃） |
| 19 | Jaccard | 丸め除去済み |
| 20 | リフト値 | 丸め除去済み |

### 7.2 旧アルゴリズムの問題点（解消済み）

旧実装では `$LargeCommitFileThreshold = 100` により、
100 ファイル以上を含むコミットは co-change 集計からスキップされていた。
これはヒューリスティックなフィルタリングであり、設計方針「回避可能な近似を一切許容しない」に反するため撤廃した。
現在はファイル数にかかわらず全コミットを集計する。

### 7.3 厳密アルゴリズム

```powershell
# 変更: $LargeCommitFileThreshold のガードを削除
# 全コミットの全ペアを集計する

# ペア数の計算: n ファイルのコミットで C(n,2) = n(n-1)/2 ペア
# n=500 → 124,750 ペア。メモリ上は問題ない。
```

### 7.4 必要な変更

| 変更箇所 | 内容 |
|----------|------|
| `Get-CoChangeMetric`（L1219-L1221） | `$StrictMode` 時に `continue` を実行しない |
| `Get-CoChangeMetric` パラメータ | `$LargeCommitFileThreshold` のデフォルトを `[int]::MaxValue` にするか、`$StrictMode` で無効化 |
| `run_meta.json` | `LargeCommitFileThreshold` の値を記録（再現性） |

---

## 8. 厳密化グループ G6: 丸め（`Get-RoundedNumber`）の除去

### 8.1 対象指標（12 件）

| No. | 指標名 | コード箇所 |
|-----|--------|-----------|
| 19 | Jaccard | L1270 |
| 20 | リフト値 | L1271 |
| 21 | コミットあたりチャーン | L999 |
| 22 | 削除対追加比 | L1000 |
| 23 | チャーン対純増比 | L1001 |
| 24 | 変更エントロピー（committers） | L1020 |
| 24 | 変更エントロピー（commits） | L1857 |
| 25 | 平均共同作者数 | L1021 |
| 26 | メッセージ平均文字数 | L1024 |
| 27 | 平均変更間隔日数 | L1164 |
| 28 | 最多作者チャーン占有率 | L1167 |
| 13 | 最多作者blame占有率 | L1940 |
| 12 | 所有割合 | L1977 |
| — | DurationSeconds（run_meta.json） | L2117 |

### 8.2 現行の実装

```powershell
function Get-RoundedNumber
{
    param([double]$Value, [int]$Digits = 4) [Math]::Round($Value, $Digits)
}
```

全箇所で小数点以下 4 桁に丸めている（DurationSeconds のみ 3 桁）。
最大誤差は $\pm 0.00005$。

### 8.3 厳密アルゴリズム

`$StrictMode` 時は `Get-RoundedNumber` を呼び出さず、`[double]` のまま出力する。

```powershell
# 変更方針: 各呼び出し箇所で条件分岐

# 例:
'コミットあたりチャーン' = if ($StrictMode) { $churnPerCommit } else { Get-RoundedNumber -Value $churnPerCommit }
```

ただし呼び出し箇所が 14 箇所あるため、ラッパー関数を用意する方が保守性が高い：

```powershell
function Format-MetricValue {
    param([double]$Value, [int]$Digits = 4)
    if ($script:StrictMode) { return $Value }
    return Get-RoundedNumber -Value $Value -Digits $Digits
}
```

### 8.4 必要な変更

| 変更箇所 | 内容 |
|----------|------|
| `Get-RoundedNumber` の全 14 呼び出し箇所 | `Format-MetricValue` に置換 |
| 新規関数 `Format-MetricValue` | `$StrictMode` で分岐するラッパー |

---

## 9. 厳密化グループ G7: `max(1, x)` によるゼロ除算回避の除去

### 9.1 対象指標（2 件）

| No. | 指標名 | コード箇所 | 現行の問題 |
|-----|--------|-----------|-----------|
| 22 | 削除対追加比 | L1000 | 追加行数 = 0 のとき `削除行数 / 1` という無意味な値を出力 |
| 23 | チャーン対純増比 | L1001 | 純増行数 = 0 のとき `チャーン / 1` という無意味な値を出力 |

### 9.2 現行の実装

```powershell
'削除対追加比' = Get-RoundedNumber -Value ([int]$s.Deleted / [double][Math]::Max(1, [int]$s.Added))
'チャーン対純増比' = Get-RoundedNumber -Value ($ch / [double][Math]::Max(1, [Math]::Abs($net)))
```

`max(1, x)` は分母が 0 になることを防ぐが、
数学的に分母 = 0 のとき比率は**未定義**（$\frac{k}{0}$ は $\infty$ だが、$\frac{0}{0}$ は不定）。
クランプにより算出される値は定義上の正しい意味を持たない。

### 9.3 厳密アルゴリズム

```powershell
'削除対追加比' = if ([int]$s.Added -gt 0) {
    Format-MetricValue -Value ([int]$s.Deleted / [double]$s.Added)
} else {
    $null    # 数学的に未定義 → null として出力
}

'チャーン対純増比' = if ([Math]::Abs($net) -gt 0) {
    Format-MetricValue -Value ($ch / [double][Math]::Abs($net))
} else {
    $null    # 数学的に未定義 → null として出力
}
```

### 9.4 必要な変更

| 変更箇所 | 内容 |
|----------|------|
| `Get-CommitterMetric` L1000 | 条件分岐で `$null` を返す |
| `Get-CommitterMetric` L1001 | 同上 |
| metrics_guide.md の説明 | `max(1, ...)` の注記を更新 |

---

## 10. 厳密化グループ G8: 原理的に厳密化不可能な指標

### 10.1 対象指標（3 件）

| No. | 指標名 | 理由 |
|-----|--------|------|
| 29 | 課題ID言及数 | フリーテキストからの ID 抽出は正規表現では原理的に完全にできない |
| 30 | 修正/差戻/マージキーワード数 | 自然言語テキストのキーワードマッチは偽陽性/偽陰性が不可避 |

### 10.2 現行の実装

```powershell
# L804-L807 (Get-MessageMetricCount)
IssueIdMentionCount  = [regex]::Matches($Message, '(#\d+)|([A-Z][A-Z0-9]+-\d+)', 'IgnoreCase').Count
FixKeywordCount      = [regex]::Matches($Message, '\b(fix|bug|hotfix|defect|patch)\b', 'IgnoreCase').Count
RevertKeywordCount   = [regex]::Matches($Message, '\b(revert|backout|rollback)\b', 'IgnoreCase').Count
MergeKeywordCount    = [regex]::Matches($Message, '\bmerge\b', 'IgnoreCase').Count
```

### 10.3 厳密化不可能の根拠

- **課題ID言及数**: `#123` はコメント中の色コード（`#FFF`）やバージョン番号と区別できない。
  `PROJ-123` も変数名と区別できない。外部の課題追跡システム（JIRA、Redmine 等）の
  API にアクセスして実在する ID を照合しない限り、偽陽性を排除できない。
  → **外部システム連携は NarutoCode の設計方針（§2: SVN CLI のみ）に反する。**

- **キーワード数**: 「fix」が「fixture」の一部でないかはワードバウンダリで防げるが、
  「This is not a fix」のような否定文脈は検出できない。
  自然言語理解が必要であり、正規表現の限界を超える。

### 10.4 対処方針

これらの指標は **`-StrictMode` でも現行のまま維持** する。
ただし、`run_meta.json` に以下を記録する：

```json
{
  "StrictMode": true,
  "NonStrictMetrics": [
    "課題ID言及数",
    "修正キーワード数",
    "差戻キーワード数",
    "マージキーワード数"
  ],
  "NonStrictReason": "正規表現ベースのヒューリスティックであり厳密化不可能"
}
```

---

## 11. 厳密化グループ G9: PlantUML 出力の TopN 切り捨て

### 11.1 現状

PlantUML 出力（`Write-PlantUmlFile` L1295-L1380）は `-TopN`（デフォルト 50）で
上位 N 件のみを出力する。これはデータの切り捨てであるが、
**CSV にはフルデータが出力されている** ため、PlantUML は可視化の便宜に過ぎない。

### 11.2 対処方針

PlantUML の TopN は「指標の近似」ではなく「表示の制限」であるため、
`-StrictMode` でも現行動作を維持する。
ただし、`-StrictMode` 時は以下を出力に追記する：

```plantuml
' NOTE: This PlantUML shows top N entries only. See CSV files for complete data.
' StrictMode is enabled — all metric values are exact.
```

---

## 12. 厳密化グループ G10: 作者同一性（エイリアスマッピング）

### 12.1 現状

SVN ユーザー名がそのまま作者名として使用される。
同一人物が複数のユーザー名でコミットしている場合（例: `tanaka` と `t.tanaka`）、
別人として集計される。

### 12.2 対処方針

これは「近似」というより「入力データの前提」の問題である。
SVN の情報だけでは同一人物の判定は原理的に不可能。

`-StrictMode` の範囲外とし、別途 `-AuthorAliasFile` パラメータとして設計する。
本設計書の対象外とする。

---

## 13. 実装計画

### 13.1 実装順序

依存関係と影響範囲に基づき、以下の順序で実装する。

```
Phase A: 独立した軽微な変更（G5, G6, G7 — 他に依存しない）
  ├── A-1: -StrictMode パラメータ追加・基盤整備
  ├── A-2: G6 丸め除去（Format-MetricValue 導入）
  ├── A-3: G7 max(1,x) 除去（$null 出力化）
  └── A-4: G5 100ファイル上限撤廃（実装済み）

Phase B: リネーム補正（G4 — diff パースに依存）
  └── B-1: G4 リネーム二重計上補正

Phase C: per-revision blame 基盤（G1 — 最大の変更）
  ├── C-1: blame/cat キャッシュ基盤
  ├── C-2: ConvertFrom-SvnBlameXml の行単位拡張
  ├── C-3: Compare-BlameOutputs (LCS 実装)
  ├── C-4: Get-ExactDeathAttribution
  └── C-5: メインパイプラインへの統合・列名変更

Phase D: 全ファイル blame（G2 — G1 の基盤を利用）
  └── D-1: G2 全ファイル blame による所有行数完全化

Phase E: 正準行範囲追跡（G3 — 独立だが複雑度が高い）
  ├── E-1: 正準行オフセットマッピング実装
  └── E-2: G3 同一箇所反復・ピンポンの厳密化

Phase F: テスト・ドキュメント
  ├── F-1: テストベースラインの作成（StrictMode 用 expected_output）
  ├── F-2: ユニットテスト追加
  └── F-3: metrics_guide.md / column_name_translations.md 更新
```

### 13.2 各 Phase の概算規模

| Phase | 新規/変更行数 | 新規関数数 | テスト行数 |
|-------|-------------|-----------|-----------|
| A | ~80 行 | 1 | ~50 行 |
| B | ~100 行 | 1 | ~60 行 |
| C | ~500 行 | 6 | ~300 行 |
| D | ~60 行 | 1 | ~40 行 |
| E | ~250 行 | 6 | ~150 行 |
| F | — | — | ~200 行 |
| **合計** | **~990 行** | **15 関数** | **~800 行** |

### 13.3 run_meta.json への記録

`-StrictMode` 有効時、以下のフィールドを追加する：

```json
{
  "StrictMode": true,
  "StrictBlameCallCount": 2700,
  "StrictBlameCacheHits": 2650,
  "StrictBlameCacheMisses": 50,
  "NonStrictMetrics": ["課題ID言及数", "修正キーワード数", "差戻キーワード数", "マージキーワード数"]
}
```

---

## 14. まとめ

### 14.1 厳密化可能: 28 件

| グループ | 件数 | 方法 |
|----------|------|------|
| G1: per-revision blame | 13 | 各リビジョンで blame を取得し LCS で比較 |
| G2: 全ファイル blame | 2 | ToRev 時点の全ファイルに blame を実行 |
| G3: 正準行範囲追跡 | 2 | diff ハンクの行番号シフトを累積し正準空間で比較 |
| G4: リネーム補正 | 2 | リネームペアの実差分を取得して水増し分を差し引く |
| G5: 上限撤廃 | 3 | 100 ファイル上限のガードを除去（実装済み） |
| G6: 丸め除去 | 12 | `Get-RoundedNumber` を `[double]` 完全精度に置換 |
| G7: null 化 | 2 | `max(1, x)` を `$null` 出力に置換 |

※一部の指標は複数グループに該当するため（例: Jaccard は G5 + G6）、
 グループ別件数の単純合計は重複を含む。

### 14.2 原理的に厳密化不可能: 3 件

| 指標 | 理由 |
|------|------|
| 課題ID言及数 | フリーテキストからの正規表現抽出。外部 ITS 連携なしでは不完全 |
| 修正キーワード数 | 自然言語の文脈理解が必要 |
| 差戻/マージキーワード数 | 同上 |

### 14.3 厳密化対象外: 2 件

| 項目 | 理由 |
|------|------|
| PlantUML TopN | 可視化の制限であり指標の近似ではない |
| 作者エイリアス | SVN 情報のみでは判定不可能。別パラメータとして設計 |

## Strict Refactor Responsibility Update (2026-02)

The Strict pipeline keeps output compatibility while splitting responsibilities into smaller units.

### Main orchestration flow

1. `Get-StrictExecutionContext`
- Resolves rename map.
- Executes exact death attribution.
- Builds ownership aggregate.
- Computes modified-others-survived helper data.

2. `Update-StrictMetricsOnRows`
- Applies strict metrics to file rows.
- Applies strict metrics to committer rows.

3. `Update-StrictAttributionMetric`
- Acts as a thin orchestrator.
- Returns only strict summary outputs (`KillMatrix`, `AuthorSelfDead`, `AuthorBorn`).

### Commit attribution internals

- `Resolve-StrictKillerAuthor`: resolves killer author per revision.
- `Invoke-StrictCommitAttribution`: executes transition-level strict attribution for one commit.
- Transition decomposition:
  - `Get-CommitTransitionRenameContext`
  - `ConvertTo-CommitRenameTransitions`
  - `ConvertTo-CommitNonRenameTransitions`

### Hunk analysis decomposition

- Event generation:
  - `ConvertTo-StrictHunkList`
  - `Get-StrictCanonicalHunkEvents`
- Overlap judgment:
  - `Test-StrictHunkRangeOverlap`
  - `Get-StrictHunkOverlapSummary`

### Row reflection decomposition

- Files:
  - value calculation: `Get-StrictFileRowMetricValues`
  - row assignment: `Set-StrictFileRowMetricValues`
- Committers:
  - value calculation: `Get-StrictCommitterRowMetricValues`
  - row assignment: `Set-StrictCommitterRowMetricValues`
