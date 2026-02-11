<#
.SYNOPSIS
    集計ロジックの整合性・エッジケース・クロスチェックを検証するテスト。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
    $script:Headers = Get-MetricHeader -Context $script:NarutoContext

    # region ヘルパー関数
    function New-TestCommit
    {
        <#
        .SYNOPSIS
            テスト用のコミットオブジェクトを構築する。
        #>
        param(
            [int]$Revision,
            [string]$Author,
            [datetime]$Date,
            [string]$Message = 'test commit',
            [hashtable]$FileDiffStats,
            [object[]]$ChangedPathsFiltered
        )
        $filesChanged = @($FileDiffStats.Keys | Sort-Object)
        $commit = [pscustomobject]@{
            Revision             = $Revision
            Author               = $Author
            Date                 = $Date
            Message              = $Message
            ChangedPathsFiltered = $ChangedPathsFiltered
            FileDiffStats        = $FileDiffStats
            FilesChanged         = $filesChanged
        }
        Set-CommitDerivedMetric -Commit $commit
        return $commit
    }

    function New-TestDiffStat
    {
        <#
        .SYNOPSIS
            テスト用の DiffStat を構築する。
        #>
        param(
            [int]$AddedLines = 0,
            [int]$DeletedLines = 0,
            [switch]$IsBinary
        )
        return [pscustomobject]@{
            AddedLines   = $AddedLines
            DeletedLines = $DeletedLines
            Hunks        = @()
            IsBinary     = [bool]$IsBinary
        }
    }

    function New-TestChangedPath
    {
        <#
        .SYNOPSIS
            テスト用の ChangedPathEntry を構築する。
        #>
        param(
            [string]$Path,
            [string]$Action = 'M'
        )
        return [pscustomobject]@{
            Path   = $Path
            Action = $Action
        }
    }
    # endregion
}

Describe 'ConvertTo-PathKey path normalization consistency' {
    It 'strips leading slash' {
        $result = ConvertTo-PathKey -Path '/trunk/src/Main.cs'
        $result | Should -Be 'trunk/src/Main.cs'
    }

    It 'converts backslash to forward slash' {
        $result = ConvertTo-PathKey -Path 'trunk\src\Main.cs'
        $result | Should -Be 'trunk/src/Main.cs'
    }

    It 'strips URL scheme to path only' {
        $url = ConvertTo-PathKey -Path 'https://svn.example.com/repos/trunk/src/Main.cs'
        $relative = ConvertTo-PathKey -Path 'repos/trunk/src/Main.cs'
        $url | Should -Be $relative
    }

    It 'strips dot-slash prefix' {
        $dotSlashPath = '.' + '/src/Main.cs'
        $dotSlash = ConvertTo-PathKey -Path $dotSlashPath
        $plain = ConvertTo-PathKey -Path 'src/Main.cs'
        $dotSlash | Should -Be $plain
    }

    It 'normalizes spaces in path correctly' {
        $result = ConvertTo-PathKey -Path '/trunk/my project/file name.cs'
        $result | Should -Be 'trunk/my project/file name.cs'
    }

    It 'returns empty string for null input' {
        $result = ConvertTo-PathKey -Path $null
        $result | Should -Be ''
    }

    It 'returns empty string for whitespace-only input' {
        $result = ConvertTo-PathKey -Path '   '
        $result | Should -Be ''
    }

    It 'handles mixed backslash-forward slash path' {
        $result = ConvertTo-PathKey -Path '/trunk\dir/sub\file.txt'
        $result | Should -Be 'trunk/dir/sub/file.txt'
    }

    It 'idempotent: applying twice gives same result' {
        $first = ConvertTo-PathKey -Path '/trunk/src/Main.cs'
        $second = ConvertTo-PathKey -Path $first
        $second | Should -Be $first
    }
}

Describe 'Merge-CommitDiffForCommit intersection filter' {
    It 'keeps only paths present in both diff and ChangedPathsFiltered' {
        $commit = [pscustomobject]@{
            Revision             = 1
            Author               = 'tester'
            Date                 = [datetime]'2026-01-01'
            Message              = 'test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            1 = @{
                'src/A.cs' = (New-TestDiffStat -AddedLines 5 -DeletedLines 2)
                'src/B.cs' = (New-TestDiffStat -AddedLines 3 -DeletedLines 0)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FileDiffStats.Keys | Should -Contain 'src/A.cs'
        $commit.FileDiffStats.Keys | Should -Not -Contain 'src/B.cs'
    }

    It 'results in empty FileDiffStats when diff and log have no common paths' {
        $commit = [pscustomobject]@{
            Revision             = 2
            Author               = 'tester'
            Date                 = [datetime]'2026-01-02'
            Message              = 'no overlap'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'docs/README.md'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            2 = @{
                'src/X.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 0)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FileDiffStats.Count | Should -Be 0
        $commit.FilesChanged.Count | Should -Be 0
    }

    It 'handles empty rawDiffByRevision gracefully' {
        $commit = [pscustomobject]@{
            Revision             = 3
            Author               = 'tester'
            Date                 = [datetime]'2026-01-03'
            Message              = 'no diff'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{}
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FileDiffStats.Count | Should -Be 0
        $commit.FilesChanged.Count | Should -Be 0
    }

    It 'preserves pre-set ChangedPathsFiltered when not null' {
        $commit = [pscustomobject]@{
            Revision             = 4
            Author               = 'tester'
            Date                 = [datetime]'2026-01-04'
            Message              = 'pre-filtered'
            ChangedPaths         = @(
                [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M' },
                [pscustomobject]@{ Path = 'src/B.cs'; Action = 'M' }
            )
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            4 = @{
                'src/A.cs' = (New-TestDiffStat -AddedLines 1 -DeletedLines 0)
                'src/B.cs' = (New-TestDiffStat -AddedLines 2 -DeletedLines 0)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FileDiffStats.Keys | Should -Contain 'src/A.cs'
        $commit.FileDiffStats.Keys | Should -Not -Contain 'src/B.cs'
    }

    It 'normalizes paths with leading slash in ChangedPathsFiltered for matching' {
        $commit = [pscustomobject]@{
            Revision             = 5
            Author               = 'tester'
            Date                 = [datetime]'2026-01-05'
            Message              = 'leading slash test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = '/trunk/src/A.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            5 = @{
                'trunk/src/A.cs' = (New-TestDiffStat -AddedLines 7 -DeletedLines 1)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FileDiffStats.Count | Should -Be 1
        $commit.FilesChanged | Should -Contain 'trunk/src/A.cs'
    }

    It 'FilesChanged is sorted after merge' {
        $commit = [pscustomobject]@{
            Revision             = 6
            Author               = 'tester'
            Date                 = [datetime]'2026-01-06'
            Message              = 'sort check'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'z.cs'; Action = 'M' },
                [pscustomobject]@{ Path = 'a.cs'; Action = 'M' },
                [pscustomobject]@{ Path = 'm.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            6 = @{
                'z.cs' = (New-TestDiffStat -AddedLines 1)
                'a.cs' = (New-TestDiffStat -AddedLines 1)
                'm.cs' = (New-TestDiffStat -AddedLines 1)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $commit.FilesChanged | Should -Be @('a.cs', 'm.cs', 'z.cs')
    }
}
Describe 'Cross-check aggregation consistency (3 authors, 5 commits, 4 files)' {
    BeforeAll {
        # Scenario:
        # r1: alice -> A.cs(10+0), B.cs(20+0)   [Add]
        # r2: bob   -> A.cs(5+3),  C.cs(15+0)   [Modify, Add]
        # r3: alice -> B.cs(2+5)                 [Modify]
        # r4: carol -> A.cs(8+2), B.cs(3+1), D.cs(25+0) [Modify, Modify, Add]
        # r5: bob   -> C.cs(1+7)                 [Modify]
        $script:CrossCheckCommits = @(
            (New-TestCommit -Revision 1 -Author 'alice' -Date ([datetime]'2026-01-01') -FileDiffStats @{
                    'src/A.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 0)
                    'src/B.cs' = (New-TestDiffStat -AddedLines 20 -DeletedLines 0)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'src/A.cs' -Action 'A'),
                    (New-TestChangedPath -Path 'src/B.cs' -Action 'A')
                )),
            (New-TestCommit -Revision 2 -Author 'bob' -Date ([datetime]'2026-01-02') -FileDiffStats @{
                    'src/A.cs' = (New-TestDiffStat -AddedLines 5 -DeletedLines 3)
                    'src/C.cs' = (New-TestDiffStat -AddedLines 15 -DeletedLines 0)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'src/A.cs' -Action 'M'),
                    (New-TestChangedPath -Path 'src/C.cs' -Action 'A')
                )),
            (New-TestCommit -Revision 3 -Author 'alice' -Date ([datetime]'2026-01-03') -FileDiffStats @{
                    'src/B.cs' = (New-TestDiffStat -AddedLines 2 -DeletedLines 5)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'src/B.cs' -Action 'M')
                )),
            (New-TestCommit -Revision 4 -Author 'carol' -Date ([datetime]'2026-01-04') -FileDiffStats @{
                    'src/A.cs' = (New-TestDiffStat -AddedLines 8 -DeletedLines 2)
                    'src/B.cs' = (New-TestDiffStat -AddedLines 3 -DeletedLines 1)
                    'src/D.cs' = (New-TestDiffStat -AddedLines 25 -DeletedLines 0)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'src/A.cs' -Action 'M'),
                    (New-TestChangedPath -Path 'src/B.cs' -Action 'M'),
                    (New-TestChangedPath -Path 'src/D.cs' -Action 'A')
                )),
            (New-TestCommit -Revision 5 -Author 'bob' -Date ([datetime]'2026-01-05') -FileDiffStats @{
                    'src/C.cs' = (New-TestDiffStat -AddedLines 1 -DeletedLines 7)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'src/C.cs' -Action 'M')
                ))
        )

        $script:CommitterRows = @(Get-CommitterMetric -Commits $script:CrossCheckCommits)
        $script:FileRows = @(Get-FileMetric -Commits $script:CrossCheckCommits)
        $script:CommitRows = @(New-CommitRowFromCommit -Commits $script:CrossCheckCommits)

        # Header column accessors
        $script:ColCommitterAuthor = $script:Headers.Committer[0]
        $script:ColCommitterCommitCount = $script:Headers.Committer[1]
        $script:ColCommitterAdded = $script:Headers.Committer[5]
        $script:ColCommitterDeleted = $script:Headers.Committer[6]
        $script:ColCommitterChurn = $script:Headers.Committer[8]

        $script:ColFilePath = $script:Headers.File[0]
        $script:ColFileCommitCount = $script:Headers.File[1]
        $script:ColFileAuthorCount = $script:Headers.File[2]
        $script:ColFileAdded = $script:Headers.File[3]
        $script:ColFileDeleted = $script:Headers.File[4]
        $script:ColFileChurn = $script:Headers.File[6]

        $script:ColCommitRevision = $script:Headers.Commit[0]
        $script:ColCommitAdded = $script:Headers.Commit[6]
        $script:ColCommitDeleted = $script:Headers.Commit[7]
        $script:ColCommitChurn = $script:Headers.Commit[8]
    }

    Context 'Committer total matches commit total' {
        It 'all committers added sum equals all commits added sum' {
            $committerAdded = ($script:CommitterRows | ForEach-Object { $_.$($script:ColCommitterAdded) } | Measure-Object -Sum).Sum
            $commitAdded = ($script:CrossCheckCommits | ForEach-Object { $_.AddedLines } | Measure-Object -Sum).Sum
            $committerAdded | Should -Be $commitAdded
        }

        It 'all committers deleted sum equals all commits deleted sum' {
            $committerDeleted = ($script:CommitterRows | ForEach-Object { $_.$($script:ColCommitterDeleted) } | Measure-Object -Sum).Sum
            $commitDeleted = ($script:CrossCheckCommits | ForEach-Object { $_.DeletedLines } | Measure-Object -Sum).Sum
            $committerDeleted | Should -Be $commitDeleted
        }

        It 'all committers churn sum equals all commits churn sum' {
            $committerChurn = ($script:CommitterRows | ForEach-Object { $_.$($script:ColCommitterChurn) } | Measure-Object -Sum).Sum
            $commitChurn = ($script:CrossCheckCommits | ForEach-Object { $_.Churn } | Measure-Object -Sum).Sum
            $committerChurn | Should -Be $commitChurn
        }
    }

    Context 'File total matches commit total' {
        It 'all files added sum equals all commits added sum' {
            $fileAdded = ($script:FileRows | ForEach-Object { $_.$($script:ColFileAdded) } | Measure-Object -Sum).Sum
            $commitAdded = ($script:CrossCheckCommits | ForEach-Object { $_.AddedLines } | Measure-Object -Sum).Sum
            $fileAdded | Should -Be $commitAdded
        }

        It 'all files deleted sum equals all commits deleted sum' {
            $fileDeleted = ($script:FileRows | ForEach-Object { $_.$($script:ColFileDeleted) } | Measure-Object -Sum).Sum
            $commitDeleted = ($script:CrossCheckCommits | ForEach-Object { $_.DeletedLines } | Measure-Object -Sum).Sum
            $fileDeleted | Should -Be $commitDeleted
        }

        It 'all files churn sum equals all commits churn sum' {
            $fileChurn = ($script:FileRows | ForEach-Object { $_.$($script:ColFileChurn) } | Measure-Object -Sum).Sum
            $commitChurn = ($script:CrossCheckCommits | ForEach-Object { $_.Churn } | Measure-Object -Sum).Sum
            $fileChurn | Should -Be $commitChurn
        }
    }

    Context 'Committer total matches file total' {
        It 'all committers added sum equals all files added sum' {
            $committerAdded = ($script:CommitterRows | ForEach-Object { $_.$($script:ColCommitterAdded) } | Measure-Object -Sum).Sum
            $fileAdded = ($script:FileRows | ForEach-Object { $_.$($script:ColFileAdded) } | Measure-Object -Sum).Sum
            $committerAdded | Should -Be $fileAdded
        }

        It 'all committers deleted sum equals all files deleted sum' {
            $committerDeleted = ($script:CommitterRows | ForEach-Object { $_.$($script:ColCommitterDeleted) } | Measure-Object -Sum).Sum
            $fileDeleted = ($script:FileRows | ForEach-Object { $_.$($script:ColFileDeleted) } | Measure-Object -Sum).Sum
            $committerDeleted | Should -Be $fileDeleted
        }
    }

    Context 'Commit rows match commit objects' {
        It 'commits.csv added sum equals commit objects added sum' {
            $csvAdded = ($script:CommitRows | ForEach-Object { $_.$($script:ColCommitAdded) } | Measure-Object -Sum).Sum
            $objAdded = ($script:CrossCheckCommits | ForEach-Object { $_.AddedLines } | Measure-Object -Sum).Sum
            $csvAdded | Should -Be $objAdded
        }

        It 'commits.csv deleted sum equals commit objects deleted sum' {
            $csvDeleted = ($script:CommitRows | ForEach-Object { $_.$($script:ColCommitDeleted) } | Measure-Object -Sum).Sum
            $objDeleted = ($script:CrossCheckCommits | ForEach-Object { $_.DeletedLines } | Measure-Object -Sum).Sum
            $csvDeleted | Should -Be $objDeleted
        }
    }

    Context 'Individual committer values are correct' {
        It 'alice added/deleted equals sum of her commits (r1,r3) FileDiffStats' {
            # alice: r1(A.cs 10+0, B.cs 20+0), r3(B.cs 2+5)
            $alice = $script:CommitterRows | Where-Object { $_.$($script:ColCommitterAuthor) -eq 'alice' }
            $alice.$($script:ColCommitterAdded) | Should -Be (10 + 20 + 2) # 32
            $alice.$($script:ColCommitterDeleted) | Should -Be (0 + 0 + 5) # 5
        }

        It 'bob added/deleted equals sum of his commits (r2,r5) FileDiffStats' {
            # bob: r2(A.cs 5+3, C.cs 15+0), r5(C.cs 1+7)
            $bob = $script:CommitterRows | Where-Object { $_.$($script:ColCommitterAuthor) -eq 'bob' }
            $bob.$($script:ColCommitterAdded) | Should -Be (5 + 15 + 1) # 21
            $bob.$($script:ColCommitterDeleted) | Should -Be (3 + 0 + 7) # 10
        }

        It 'carol added/deleted equals sum of her commits (r4) FileDiffStats' {
            # carol: r4(A.cs 8+2, B.cs 3+1, D.cs 25+0)
            $carol = $script:CommitterRows | Where-Object { $_.$($script:ColCommitterAuthor) -eq 'carol' }
            $carol.$($script:ColCommitterAdded) | Should -Be (8 + 3 + 25) # 36
            $carol.$($script:ColCommitterDeleted) | Should -Be (2 + 1 + 0) # 3
        }
    }

    Context 'Individual file values are correct' {
        It 'src/A.cs totals match sum from r1,r2,r4' {
            # A.cs: r1(10+0), r2(5+3), r4(8+2)
            $fileA = $script:FileRows | Where-Object { $_.$($script:ColFilePath) -eq 'src/A.cs' }
            $fileA.$($script:ColFileAdded) | Should -Be (10 + 5 + 8) # 23
            $fileA.$($script:ColFileDeleted) | Should -Be (0 + 3 + 2) # 5
            $fileA.$($script:ColFileCommitCount) | Should -Be 3
            $fileA.$($script:ColFileAuthorCount) | Should -Be 3
        }

        It 'src/B.cs totals match sum from r1,r3,r4' {
            # B.cs: r1(20+0), r3(2+5), r4(3+1)
            $fileB = $script:FileRows | Where-Object { $_.$($script:ColFilePath) -eq 'src/B.cs' }
            $fileB.$($script:ColFileAdded) | Should -Be (20 + 2 + 3) # 25
            $fileB.$($script:ColFileDeleted) | Should -Be (0 + 5 + 1) # 6
            $fileB.$($script:ColFileCommitCount) | Should -Be 3
            $fileB.$($script:ColFileAuthorCount) | Should -Be 2
        }

        It 'src/C.cs totals match sum from r2,r5' {
            # C.cs: r2(15+0), r5(1+7)
            $fileC = $script:FileRows | Where-Object { $_.$($script:ColFilePath) -eq 'src/C.cs' }
            $fileC.$($script:ColFileAdded) | Should -Be (15 + 1) # 16
            $fileC.$($script:ColFileDeleted) | Should -Be (0 + 7) # 7
            $fileC.$($script:ColFileCommitCount) | Should -Be 2
            $fileC.$($script:ColFileAuthorCount) | Should -Be 1
        }

        It 'src/D.cs totals match sum from r4' {
            # D.cs: r4(25+0)
            $fileD = $script:FileRows | Where-Object { $_.$($script:ColFilePath) -eq 'src/D.cs' }
            $fileD.$($script:ColFileAdded) | Should -Be 25
            $fileD.$($script:ColFileDeleted) | Should -Be 0
            $fileD.$($script:ColFileCommitCount) | Should -Be 1
            $fileD.$($script:ColFileAuthorCount) | Should -Be 1
        }
    }
}

Describe 'Edge case aggregation' {
    Context 'Binary file commit' {
        It 'binary file has zero added/deleted lines' {
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats @{
                'logo.png' = (New-TestDiffStat -IsBinary)
            } -ChangedPathsFiltered @(
                (New-TestChangedPath -Path 'logo.png' -Action 'A')
            )
            $commit.AddedLines | Should -Be 0
            $commit.DeletedLines | Should -Be 0
            $commit.Churn | Should -Be 0
        }
    }

    Context 'Empty commit (no files changed)' {
        It 'produces zero metrics' {
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats @{} -ChangedPathsFiltered @()
            $commit.AddedLines | Should -Be 0
            $commit.DeletedLines | Should -Be 0
            $commit.Churn | Should -Be 0
        }

        It 'FilesChanged is empty array' {
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats @{} -ChangedPathsFiltered @()
            $commit.FilesChanged.Count | Should -Be 0
        }
    }

    Context 'Entropy calculation' {
        It 'entropy is 0 for single file commit' {
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats @{
                'a.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 0)
            } -ChangedPathsFiltered @(
                (New-TestChangedPath -Path 'a.cs')
            )
            $commit.Entropy | Should -Be 0
        }

        It 'entropy is 1 for two files with equal churn' {
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats @{
                'a.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 0)
                'b.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 0)
            } -ChangedPathsFiltered @(
                (New-TestChangedPath -Path 'a.cs'),
                (New-TestChangedPath -Path 'b.cs')
            )
            $commit.Entropy | Should -Be 1
        }
    }

    Context 'File added then deleted in same range' {
        It 'both appear in File metrics with correct counts' {
            $commits = @(
                (New-TestCommit -Revision 1 -Author 'alice' -Date ([datetime]'2026-01-01') -FileDiffStats @{
                        'temp.cs' = (New-TestDiffStat -AddedLines 50 -DeletedLines 0)
                    } -ChangedPathsFiltered @(
                        (New-TestChangedPath -Path 'temp.cs' -Action 'A')
                    )),
                (New-TestCommit -Revision 2 -Author 'alice' -Date ([datetime]'2026-01-02') -FileDiffStats @{
                        'temp.cs' = (New-TestDiffStat -AddedLines 0 -DeletedLines 50)
                    } -ChangedPathsFiltered @(
                        (New-TestChangedPath -Path 'temp.cs' -Action 'D')
                    ))
            )
            $fileRows = @(Get-FileMetric -Commits $commits)
            $temp = $fileRows | Where-Object { $_.$($script:ColFilePath) -eq 'temp.cs' }
            $temp.$($script:ColFileAdded) | Should -Be 50
            $temp.$($script:ColFileDeleted) | Should -Be 50
            $temp.$($script:ColFileCommitCount) | Should -Be 2
        }
    }

    Context 'Large number of files in single commit' {
        It 'all files counted in metrics' {
            $diffStats = @{}
            $changedPaths = @()
            for ($i = 1; $i -le 20; $i++)
            {
                $name = "file$i.cs"
                $diffStats[$name] = (New-TestDiffStat -AddedLines $i -DeletedLines 0)
                $changedPaths += (New-TestChangedPath -Path $name -Action 'A')
            }
            $commit = New-TestCommit -Revision 1 -Author 'dev' -Date ([datetime]'2026-01-01') -FileDiffStats $diffStats -ChangedPathsFiltered $changedPaths
            $commit.FilesChanged.Count | Should -Be 20
            # Sum of 1..20 = 210
            $commit.AddedLines | Should -Be 210
        }
    }
}

Describe 'FilesChanged and ChangedPathsFiltered consistency' {
    It 'FilesChanged keys are subset of ConvertTo-PathKey applied ChangedPathsFiltered paths' {
        $commit = [pscustomobject]@{
            Revision             = 1
            Author               = 'tester'
            Date                 = [datetime]'2026-01-01'
            Message              = 'consistency'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = '/trunk/src/A.cs'; Action = 'M' },
                [pscustomobject]@{ Path = '/trunk/src/B.cs'; Action = 'A' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            1 = @{
                'trunk/src/A.cs' = (New-TestDiffStat -AddedLines 5)
                'trunk/src/B.cs' = (New-TestDiffStat -AddedLines 3)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $normalizedFilteredPaths = @($commit.ChangedPathsFiltered | ForEach-Object { ConvertTo-PathKey -Path $_.Path })
        foreach ($f in $commit.FilesChanged)
        {
            $normalizedFilteredPaths | Should -Contain $f
        }
    }

    It 'after merge, FileDiffStats keys equal FilesChanged' {
        $commit = [pscustomobject]@{
            Revision             = 1
            Author               = 'tester'
            Date                 = [datetime]'2026-01-01'
            Message              = 'key match'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'src/X.cs'; Action = 'M' },
                [pscustomobject]@{ Path = 'src/Y.cs'; Action = 'M' }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            1 = @{
                'src/X.cs' = (New-TestDiffStat -AddedLines 2)
                'src/Y.cs' = (New-TestDiffStat -AddedLines 4)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision
        $diffKeys = @($commit.FileDiffStats.Keys | Sort-Object)
        $filesChanged = @($commit.FilesChanged | Sort-Object)
        $diffKeys | Should -Be $filesChanged
    }
}

Describe 'Get-CommitDerivedChurnValues comprehensive' {
    It 'sums only FilesChanged keys from FileDiffStats (extra keys ignored)' {
        $commit = [pscustomobject]@{
            FilesChanged  = @('a.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 2 }
                'b.cs' = [pscustomobject]@{ AddedLines = 99; DeletedLines = 99 }
            }
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Added | Should -Be 10
        $result.Deleted | Should -Be 2
        $result.Churn | Should -Be 12
    }

    It 'throws under strict mode when FilesChanged references a key missing from FileDiffStats' {
        Set-StrictMode -Version Latest
        $commit = [pscustomobject]@{
            FilesChanged  = @('a.cs', 'missing.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{ AddedLines = 5; DeletedLines = 1 }
            }
        }
        { Get-CommitDerivedChurnValues -Commit $commit } | Should -Throw
    }

    It 'returns zero entropy for zero-churn commit' {
        $commit = [pscustomobject]@{
            FilesChanged  = @('a.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 0 }
            }
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Entropy | Should -Be 0
    }
}

Describe 'Set-CommitDerivedMetric integration' {
    It 'sets AddedLines, DeletedLines, Churn, Entropy on commit object' {
        $commit = [pscustomobject]@{
            Revision      = 1
            Author        = 'dev'
            Date          = [datetime]'2026-01-01'
            Message       = 'test'
            FilesChanged  = @('a.cs', 'b.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{
                    AddedLines   = 10
                    DeletedLines = 2
                    Hunks        = @()
                    IsBinary     = $false
                }
                'b.cs' = [pscustomobject]@{
                    AddedLines   = 5
                    DeletedLines = 3
                    Hunks        = @()
                    IsBinary     = $false
                }
            }
        }
        Set-CommitDerivedMetric -Commit $commit
        $commit.AddedLines | Should -Be 15
        $commit.DeletedLines | Should -Be 5
        $commit.Churn | Should -Be 20
        $commit.Entropy | Should -BeGreaterThan 0
    }

    It 'sets MsgLen and MessageShort' {
        $commit = [pscustomobject]@{
            Revision      = 1
            Author        = 'dev'
            Date          = [datetime]'2026-01-01'
            Message       = "line one`nline two"
            FilesChanged  = @()
            FileDiffStats = @{}
        }
        Set-CommitDerivedMetric -Commit $commit
        $commit.MsgLen | Should -BeGreaterThan 0
        $commit.MessageShort | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-CommitRowFromCommit output mapping' {
    It 'produces one row per commit with correct column structure' {
        $commits = @(
            (New-TestCommit -Revision 1 -Author 'alice' -Date ([datetime]'2026-01-01') -Message 'first' -FileDiffStats @{
                    'a.cs' = (New-TestDiffStat -AddedLines 10 -DeletedLines 2)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'a.cs')
                )),
            (New-TestCommit -Revision 2 -Author 'bob' -Date ([datetime]'2026-01-02') -Message 'second' -FileDiffStats @{
                    'b.cs' = (New-TestDiffStat -AddedLines 5 -DeletedLines 0)
                } -ChangedPathsFiltered @(
                    (New-TestChangedPath -Path 'b.cs')
                ))
        )
        $rows = @(New-CommitRowFromCommit -Commits $commits)
        $rows.Count | Should -Be 2

        $colRevision = $script:Headers.Commit[0]
        $colAdded = $script:Headers.Commit[6]
        $colDeleted = $script:Headers.Commit[7]

        $r1 = $rows | Where-Object { $_.$colRevision -eq 1 }
        $r1.$colAdded | Should -Be 10
        $r1.$colDeleted | Should -Be 2

        $r2 = $rows | Where-Object { $_.$colRevision -eq 2 }
        $r2.$colAdded | Should -Be 5
        $r2.$colDeleted | Should -Be 0
    }
}

# ===================================================================
# Bug Fix Verification: svn log / svn diff パス不一致 (trunk prefix)
# ===================================================================

Describe 'ConvertTo-DiffRelativePath' {
    It 'strips matching prefix from path' {
        $result = ConvertTo-DiffRelativePath -Path 'trunk/src/Main.cs' -LogPathPrefix 'trunk/'
        $result | Should -Be 'src/Main.cs'
    }

    It 'strips deep prefix' {
        $result = ConvertTo-DiffRelativePath -Path 'project/trunk/src/Main.cs' -LogPathPrefix 'project/trunk/'
        $result | Should -Be 'src/Main.cs'
    }

    It 'returns path unchanged when prefix does not match' {
        $result = ConvertTo-DiffRelativePath -Path 'branches/dev/src/Main.cs' -LogPathPrefix 'trunk/'
        $result | Should -Be 'branches/dev/src/Main.cs'
    }

    It 'returns path unchanged when prefix is empty' {
        $result = ConvertTo-DiffRelativePath -Path 'src/Main.cs' -LogPathPrefix ''
        $result | Should -Be 'src/Main.cs'
    }

    It 'returns path unchanged when prefix is null' {
        $result = ConvertTo-DiffRelativePath -Path 'src/Main.cs' -LogPathPrefix $null
        $result | Should -Be 'src/Main.cs'
    }

    It 'is case-insensitive for prefix matching' {
        $result = ConvertTo-DiffRelativePath -Path 'Trunk/src/Main.cs' -LogPathPrefix 'trunk/'
        $result | Should -Be 'src/Main.cs'
    }
}

Describe 'Merge-CommitDiffForCommit with LogPathPrefix (trunk prefix bug fix)' {
    It 'matches log paths with trunk prefix to diff paths without prefix' {
        # シナリオ: svn log は /trunk/src/A.cs を返し、svn diff は src/A.cs を返す
        $commit = [pscustomobject]@{
            Revision             = 10
            Author               = 'alice'
            Date                 = [datetime]'2026-01-10'
            Message              = 'trunk prefix test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'trunk/src/A.cs'; Action = 'M'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false },
                [pscustomobject]@{ Path = 'trunk/src/B.cs'; Action = 'A'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            10 = @{
                'src/A.cs' = (New-TestDiffStat -AddedLines 5 -DeletedLines 2)
                'src/B.cs' = (New-TestDiffStat -AddedLines 20)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -LogPathPrefix 'trunk/'

        $commit.FileDiffStats.Count | Should -Be 2
        $commit.FileDiffStats['src/A.cs'].AddedLines | Should -Be 5
        $commit.FileDiffStats['src/B.cs'].AddedLines | Should -Be 20
        $commit.FilesChanged | Should -Contain 'src/A.cs'
        $commit.FilesChanged | Should -Contain 'src/B.cs'
    }

    It 'normalizes ChangedPathsFiltered paths to diff-relative after merge' {
        $commit = [pscustomobject]@{
            Revision             = 11
            Author               = 'bob'
            Date                 = [datetime]'2026-01-11'
            Message              = 'normalize test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'trunk/src/X.cs'; Action = 'M'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            11 = @{
                'src/X.cs' = (New-TestDiffStat -AddedLines 3)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -LogPathPrefix 'trunk/'

        $commit.ChangedPathsFiltered[0].Path | Should -Be 'src/X.cs'
    }

    It 'normalizes CopyFromPath in ChangedPathsFiltered for rename correction' {
        $commit = [pscustomobject]@{
            Revision             = 12
            Author               = 'charlie'
            Date                 = [datetime]'2026-01-12'
            Message              = 'rename prefix test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'trunk/src/new.cs'; Action = 'R'; CopyFromPath = 'trunk/src/old.cs'; CopyFromRev = 11; IsDirectory = $false },
                [pscustomobject]@{ Path = 'trunk/src/old.cs'; Action = 'D'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            12 = @{
                'src/new.cs' = (New-TestDiffStat -AddedLines 50)
                'src/old.cs' = (New-TestDiffStat -DeletedLines 45)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -LogPathPrefix 'trunk/'

        $commit.ChangedPathsFiltered[0].Path | Should -Be 'src/new.cs'
        $commit.ChangedPathsFiltered[0].CopyFromPath | Should -Be 'src/old.cs'
        $commit.ChangedPathsFiltered[1].Path | Should -Be 'src/old.cs'
        $commit.FileDiffStats.Count | Should -Be 2
    }

    It 'works correctly without prefix (repo root)' {
        # リポジトリルート指定時は prefix が空で従来通り動作する
        $commit = [pscustomobject]@{
            Revision             = 13
            Author               = 'dev'
            Date                 = [datetime]'2026-01-13'
            Message              = 'no prefix test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            13 = @{
                'src/A.cs' = (New-TestDiffStat -AddedLines 7)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -LogPathPrefix ''

        $commit.FileDiffStats.Count | Should -Be 1
        $commit.FilesChanged | Should -Contain 'src/A.cs'
    }

    It 'handles deep prefix path (project/trunk/)' {
        $commit = [pscustomobject]@{
            Revision             = 14
            Author               = 'dev'
            Date                 = [datetime]'2026-01-14'
            Message              = 'deep prefix test'
            ChangedPaths         = @()
            ChangedPathsFiltered = @(
                [pscustomobject]@{ Path = 'project/trunk/src/A.cs'; Action = 'M'; CopyFromPath = ''; CopyFromRev = $null; IsDirectory = $false }
            )
            FileDiffStats        = @{}
            FilesChanged         = @()
        }
        $rawDiffByRevision = @{
            14 = @{
                'src/A.cs' = (New-TestDiffStat -AddedLines 3)
            }
        }
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -LogPathPrefix 'project/trunk/'

        $commit.FileDiffStats.Count | Should -Be 1
        $commit.FilesChanged | Should -Contain 'src/A.cs'
    }
}

Describe 'Get-RenameMap with LogPathPrefix' {
    It 'strips prefix from rename map keys and values' {
        $commits = @(
            [pscustomobject]@{
                Revision     = 1
                Author       = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path = '/trunk/src/old.cs'; Action = 'D'; CopyFromPath = $null; CopyFromRev = $null },
                    [pscustomobject]@{ Path = '/trunk/src/new.cs'; Action = 'A'; CopyFromPath = '/trunk/src/old.cs'; CopyFromRev = 0 }
                )
            }
        )
        $map = Get-RenameMap -Commits $commits -LogPathPrefix 'trunk/'

        $map.ContainsKey('src/old.cs') | Should -BeTrue
        $map['src/old.cs'] | Should -Be 'src/new.cs'

        # trunk/ 付きのキーが残っていないことを確認
        $map.ContainsKey('trunk/src/old.cs') | Should -BeFalse
    }

    It 'returns correct map without prefix' {
        $commits = @(
            [pscustomobject]@{
                Revision     = 1
                Author       = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path = '/src/old.cs'; Action = 'D'; CopyFromPath = $null; CopyFromRev = $null },
                    [pscustomobject]@{ Path = '/src/new.cs'; Action = 'A'; CopyFromPath = '/src/old.cs'; CopyFromRev = 0 }
                )
            }
        )
        $map = Get-RenameMap -Commits $commits -LogPathPrefix ''

        $map.ContainsKey('src/old.cs') | Should -BeTrue
        $map['src/old.cs'] | Should -Be 'src/new.cs'
    }
}

Describe 'New-CommitDiffPrefetchPlan with LogPathPrefix' {
    It 'strips prefix from ChangedPathsFiltered paths' {
        $commits = @(
            [pscustomobject]@{
                Revision             = 5
                Author               = 'alice'
                Date                 = [datetime]'2026-01-05'
                Message              = 'prefetch test'
                ChangedPaths         = @(
                    [pscustomobject]@{ Path = '/trunk/src/Main.cs'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null; IsDirectory = $false }
                )
                ChangedPathsFiltered = @()
                FileDiffStats        = @{}
                FilesChanged         = @()
            }
        )
        $plan = New-CommitDiffPrefetchPlan -Commits $commits -CacheDir 'dummy' -TargetUrl 'https://example.invalid/svn/repo/trunk' -DiffArguments @('diff') -LogPathPrefix 'trunk/'

        $commits[0].ChangedPathsFiltered.Count | Should -Be 1
        $commits[0].ChangedPathsFiltered[0].Path | Should -Be 'src/Main.cs'
        $plan.PrefetchItems.Count | Should -Be 1
    }

    It 'path pattern matching works with prefix-stripped paths' {
        $commits = @(
            [pscustomobject]@{
                Revision             = 6
                Author               = 'bob'
                Date                 = [datetime]'2026-01-06'
                Message              = 'pattern test'
                ChangedPaths         = @(
                    [pscustomobject]@{ Path = '/trunk/src/Main.cs'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null; IsDirectory = $false },
                    [pscustomobject]@{ Path = '/trunk/docs/readme.md'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null; IsDirectory = $false }
                )
                ChangedPathsFiltered = @()
                FileDiffStats        = @{}
                FilesChanged         = @()
            }
        )
        New-CommitDiffPrefetchPlan -Commits $commits -CacheDir 'dummy' -TargetUrl 'https://example.invalid/svn/repo/trunk' -DiffArguments @('diff') -IncludePathPatterns @('src/*') -LogPathPrefix 'trunk/'

        # src/Main.cs のみマッチし、docs/readme.md は除外される
        $commits[0].ChangedPathsFiltered.Count | Should -Be 1
        $commits[0].ChangedPathsFiltered[0].Path | Should -Be 'src/Main.cs'
    }
}
