<#
.SYNOPSIS
Strict aggregation focused tests.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
    $script:Headers = Get-MetricHeader -Context $script:TestContext
}

Describe 'Strict aggregation refactor' {
    It 'enables strict commit window mode when memory governor is in hard level' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 4
        $runtime.MemoryGovernor.CurrentLevel = 'Hard'

        (Test-UseStrictCommitWindowMode -Context $context) | Should -BeTrue
    }

    It 'throws INTERNAL_STRICT_WINDOW_PRELOAD_INCOMPLETE when required preload is missing' {
        $caught = $null
        try
        {
            Assert-StrictPreloadCoverage -RequiredTargets @(
                [pscustomobject]@{
                    FilePath = 'src/A.cs'
                    Revision = 10
                }
            ) -PreloadedBlameByKey @{} -Revision 10
        }
        catch
        {
            $caught = $_.Exception
        }

        $caught | Should -Not -BeNullOrEmpty
        [string]$caught.Data['ErrorCode'] | Should -Be 'INTERNAL_STRICT_WINDOW_PRELOAD_INCOMPLETE'
    }

    It 'builds commit transitions for rename add and delete combinations' {
        $commit = [pscustomobject]@{
            FilesChanged = @('src/New.cs', 'src/Added.cs')
            ChangedPathsFiltered = @(
                [pscustomobject]@{
                    Path = 'src/Old.cs'
                    Action = 'D'
                    CopyFromPath = $null
                    CopyFromRev = $null
                },
                [pscustomobject]@{
                    Path = 'src/New.cs'
                    Action = 'A'
                    CopyFromPath = 'src/Old.cs'
                    CopyFromRev = 9
                },
                [pscustomobject]@{
                    Path = 'src/Added.cs'
                    Action = 'A'
                    CopyFromPath = $null
                    CopyFromRev = $null
                },
                [pscustomobject]@{
                    Path = 'src/DeletedOnly.cs'
                    Action = 'D'
                    CopyFromPath = $null
                    CopyFromRev = $null
                }
            )
        }

        $rows = @(Get-CommitFileTransition -Commit $commit)
        $keys = @($rows | ForEach-Object { ([string]$_.BeforePath) + '|' + ([string]$_.AfterPath) })

        $rows.Count | Should -Be 3
        ($keys -contains 'src/Old.cs|src/New.cs') | Should -BeTrue
        ($keys -contains '|src/Added.cs') | Should -BeTrue
        ($keys -contains 'src/DeletedOnly.cs|') | Should -BeTrue
    }

    It 'updates file row strict columns from strict detail and blame data' {
        $commit = [pscustomobject]@{
            Revision = 10
            Author = 'alice'
            Date = [datetime]'2026-01-10'
            Message = 'refactor'
            ChangedPathsFiltered = @([pscustomobject]@{
                    Path = 'src/A.cs'
                    Action = 'M'
                })
            FileDiffStats = @{
                'src/A.cs' = [pscustomobject]@{
                    AddedLines = 2
                    DeletedLines = 1
                    Hunks = @()
                    IsBinary = $false
                }
            }
            FilesChanged = @('src/A.cs')
        }

        Set-CommitDerivedMetric -Commit $commit
        $fileRows = @(Get-FileMetric -Commits @($commit))
        $strictDetail = [pscustomobject]@{
            FileSurvived = @{ 'src/A.cs' = 8 }
            FileDead = @{ 'src/A.cs' = 2 }
            FileSelfCancel = @{ 'src/A.cs' = 1 }
            FileCrossRevert = @{ 'src/A.cs' = 2 }
            FileRepeatedHunk = @{ 'src/A.cs' = 3 }
            FilePingPong = @{ 'src/A.cs' = 1 }
            FileInternalMoveCount = @{ 'src/A.cs' = 4 }
        }
        $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$existingFileSet.Add('src/A.cs')
        $blameByFile = @{
            'src/A.cs' = [pscustomobject]@{
                LineCountByAuthor = @{
                    alice = 6
                    bob = 2
                }
                LineCountTotal = 8
            }
        }

        Update-FileRowWithStrictMetric -FileRows $fileRows -RenameMap @{} -StrictDetail $strictDetail -ExistingFileSet $existingFileSet -BlameByFile $blameByFile -TargetUrl 'https://example.invalid/svn/repo' -ToRevision 10 -CacheDir '.'

        $row = $fileRows[0]
        $row.($script:Headers.File[15]) | Should -Be 8
        $row.($script:Headers.File[16]) | Should -Be 0
        $row.($script:Headers.File[19]) | Should -Be 1
        $row.($script:Headers.File[20]) | Should -Be 2
        $row.($script:Headers.File[21]) | Should -Be 3
        $row.($script:Headers.File[22]) | Should -Be 1
        $row.($script:Headers.File[23]) | Should -Be 4
        $row.($script:Headers.File[18]) | Should -Be 0.75
    }

    It 'updates committer row strict columns from strict detail and ownership data' {
        $commit = [pscustomobject]@{
            Revision = 10
            Author = 'alice'
            Date = [datetime]'2026-01-10'
            Message = 'refactor'
            ChangedPathsFiltered = @([pscustomobject]@{
                    Path = 'src/A.cs'
                    Action = 'M'
                })
            FileDiffStats = @{
                'src/A.cs' = [pscustomobject]@{
                    AddedLines = 2
                    DeletedLines = 1
                    Hunks = @()
                    IsBinary = $false
                }
            }
            FilesChanged = @('src/A.cs')
        }

        Set-CommitDerivedMetric -Commit $commit
        $committerRows = @(Get-CommitterMetric -Commits @($commit))
        $strictDetail = [pscustomobject]@{
            AuthorDead = @{ alice = 2 }
            AuthorSelfDead = @{ alice = 1 }
            AuthorOtherDead = @{ alice = 1 }
            AuthorRepeatedHunk = @{ alice = 3 }
            AuthorPingPong = @{ alice = 1 }
            AuthorInternalMoveCount = @{ alice = 4 }
            AuthorModifiedOthersCode = @{ alice = 6 }
        }
        $authorSurvived = @{ alice = 8 }
        $authorOwned = @{ alice = 10 }
        $authorModifiedOthersSurvived = @{ alice = 3 }

        Update-CommitterRowWithStrictMetric -CommitterRows $committerRows -AuthorSurvived $authorSurvived -AuthorOwned $authorOwned -OwnedTotal 20 -StrictDetail $strictDetail -AuthorModifiedOthersSurvived $authorModifiedOthersSurvived

        $row = $committerRows[0]
        $row.($script:Headers.Committer[18]) | Should -Be 8
        $row.($script:Headers.Committer[19]) | Should -Be 0
        $row.($script:Headers.Committer[20]) | Should -Be 10
        $row.($script:Headers.Committer[21]) | Should -Be 0.5
        $row.($script:Headers.Committer[22]) | Should -Be 1
        $row.($script:Headers.Committer[23]) | Should -Be 1
        $row.($script:Headers.Committer[24]) | Should -Be 3
        $row.($script:Headers.Committer[25]) | Should -Be 1
        $row.($script:Headers.Committer[26]) | Should -Be 4
        $row.($script:Headers.Committer[27]) | Should -Be 6
        $row.($script:Headers.Committer[28]) | Should -Be 3
        $row.($script:Headers.Committer[29]) | Should -Be 0.5
        $row.($script:Headers.Committer[30]) | Should -Be 1
    }

    Context 'Strict execution orchestration' {
        BeforeEach {
            $script:origGetRenameMap = (Get-Item function:Get-RenameMap).ScriptBlock.ToString()
            $script:origGetExactDeathAttribution = (Get-Item function:Get-ExactDeathAttribution).ScriptBlock.ToString()
            $script:origGetStrictOwnershipAggregate = (Get-Item function:Get-StrictOwnershipAggregate).ScriptBlock.ToString()
            $script:origGetAuthorModifiedOthersSurvivedCount = (Get-Item function:Get-AuthorModifiedOthersSurvivedCount).ScriptBlock.ToString()
            $script:origUpdateStrictMetricsOnRows = (Get-Item function:Update-StrictMetricsOnRows).ScriptBlock.ToString()
        }

        AfterEach {
            Set-Item -Path function:Get-RenameMap -Value $script:origGetRenameMap
            Set-Item -Path function:Get-ExactDeathAttribution -Value $script:origGetExactDeathAttribution
            Set-Item -Path function:Get-StrictOwnershipAggregate -Value $script:origGetStrictOwnershipAggregate
            Set-Item -Path function:Get-AuthorModifiedOthersSurvivedCount -Value $script:origGetAuthorModifiedOthersSurvivedCount
            Set-Item -Path function:Update-StrictMetricsOnRows -Value $script:origUpdateStrictMetricsOnRows
        }

        It 'builds strict execution context with merged dependencies' {
            Set-Item -Path function:Get-RenameMap -Value {
                param([object[]]$Commits)
                [void]$Commits
                return @{ 'old.cs' = 'new.cs' }
            }
            Set-Item -Path function:Get-ExactDeathAttribution -Value {
                param(
                    [hashtable]$Context,
                    [object[]]$Commits,
                    [hashtable]$RevToAuthor,
                    [string]$TargetUrl,
                    [int]$FromRevision,
                    [int]$ToRevision,
                    [string]$CacheDir,
                    [hashtable]$RenameMap,
                    [int]$Parallel
                )
                [void]$Context
                [void]$Commits
                [void]$RevToAuthor
                [void]$TargetUrl
                [void]$FromRevision
                [void]$ToRevision
                [void]$CacheDir
                [void]$RenameMap
                [void]$Parallel
                return [pscustomobject]@{
                    AuthorSurvived = @{ alice = 10 }
                    RevsWhereKilledOthers = (New-Object 'System.Collections.Generic.HashSet[string]')
                    KillMatrix = @{ alice = @{ bob = 1 } }
                    AuthorSelfDead = @{ alice = 2 }
                    AuthorBorn = @{ alice = 11 }
                }
            }
            Set-Item -Path function:Get-StrictOwnershipAggregate -Value {
                param(
                    [hashtable]$Context,
                    [string]$TargetUrl,
                    [int]$ToRevision,
                    [string]$CacheDir,
                    [string[]]$IncludeExtensions,
                    [string[]]$ExcludeExtensions,
                    [string[]]$IncludePaths,
                    [string[]]$ExcludePaths,
                    [int]$Parallel
                )
                [void]$Context
                [void]$TargetUrl
                [void]$ToRevision
                [void]$CacheDir
                [void]$IncludeExtensions
                [void]$ExcludeExtensions
                [void]$IncludePaths
                [void]$ExcludePaths
                [void]$Parallel
                $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
                [void]$existingFileSet.Add('src/A.cs')
                return [pscustomobject]@{
                    AuthorOwned = @{ alice = 20 }
                    OwnedTotal = 40
                    BlameByFile = @{ 'src/A.cs' = [pscustomobject]@{ LineCountByAuthor = @{ alice = 20 }; LineCountTotal = 20 } }
                    ExistingFileSet = $existingFileSet
                }
            }
            Set-Item -Path function:Get-AuthorModifiedOthersSurvivedCount -Value {
                param(
                    [hashtable]$BlameByFile,
                    [System.Collections.Generic.HashSet[string]]$RevsWhereKilledOthers,
                    [int]$FromRevision,
                    [int]$ToRevision
                )
                [void]$BlameByFile
                [void]$RevsWhereKilledOthers
                [void]$FromRevision
                [void]$ToRevision
                return @{ alice = 5 }
            }

            $context = Get-StrictExecutionContext -Commits @() -RevToAuthor @{} -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 10 -CacheDir '.cache' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -Parallel 4 -RenameMap @{}

            $context.RenameMap['old.cs'] | Should -Be 'new.cs'
            $context.AuthorSurvived['alice'] | Should -Be 10
            $context.AuthorOwned['alice'] | Should -Be 20
            $context.OwnedTotal | Should -Be 40
            $context.AuthorModifiedOthersSurvived['alice'] | Should -Be 5
        }

        It 'orchestrates strict context building and row updates' {
            Set-Item -Path function:Get-RenameMap -Value {
                param([object[]]$Commits)
                [void]$Commits
                return @{}
            }
            Set-Item -Path function:Get-ExactDeathAttribution -Value {
                param(
                    [hashtable]$Context,
                    [object[]]$Commits,
                    [hashtable]$RevToAuthor,
                    [string]$TargetUrl,
                    [int]$FromRevision,
                    [int]$ToRevision,
                    [string]$CacheDir,
                    [hashtable]$RenameMap,
                    [int]$Parallel
                )
                [void]$Context
                [void]$Commits
                [void]$RevToAuthor
                [void]$TargetUrl
                [void]$FromRevision
                [void]$ToRevision
                [void]$CacheDir
                [void]$RenameMap
                [void]$Parallel
                return [pscustomobject]@{
                    AuthorSurvived = @{}
                    RevsWhereKilledOthers = (New-Object 'System.Collections.Generic.HashSet[string]')
                    KillMatrix = @{ alice = @{ bob = 2 } }
                    AuthorSelfDead = @{ alice = 1 }
                    AuthorBorn = @{ alice = 9 }
                }
            }
            Set-Item -Path function:Get-StrictOwnershipAggregate -Value {
                param(
                    [hashtable]$Context,
                    [string]$TargetUrl,
                    [int]$ToRevision,
                    [string]$CacheDir,
                    [string[]]$IncludeExtensions,
                    [string[]]$ExcludeExtensions,
                    [string[]]$IncludePaths,
                    [string[]]$ExcludePaths,
                    [int]$Parallel
                )
                [void]$Context
                [void]$TargetUrl
                [void]$ToRevision
                [void]$CacheDir
                [void]$IncludeExtensions
                [void]$ExcludeExtensions
                [void]$IncludePaths
                [void]$ExcludePaths
                [void]$Parallel
                return [pscustomobject]@{
                    AuthorOwned = @{}
                    OwnedTotal = 0
                    BlameByFile = @{}
                    ExistingFileSet = (New-Object 'System.Collections.Generic.HashSet[string]')
                }
            }
            Set-Item -Path function:Get-AuthorModifiedOthersSurvivedCount -Value {
                param(
                    [hashtable]$BlameByFile,
                    [System.Collections.Generic.HashSet[string]]$RevsWhereKilledOthers,
                    [int]$FromRevision,
                    [int]$ToRevision
                )
                [void]$BlameByFile
                [void]$RevsWhereKilledOthers
                [void]$FromRevision
                [void]$ToRevision
                return @{}
            }
            $script:strictRowsApplied = $false
            Set-Item -Path function:Update-StrictMetricsOnRows -Value {
                param(
                    [hashtable]$Context,
                    [object[]]$FileRows,
                    [object[]]$CommitterRows,
                    [object]$StrictExecutionContext,
                    [string]$TargetUrl,
                    [int]$ToRevision,
                    [string]$CacheDir
                )
                [void]$Context
                [void]$FileRows
                [void]$CommitterRows
                [void]$StrictExecutionContext
                [void]$TargetUrl
                [void]$ToRevision
                [void]$CacheDir
                $script:strictRowsApplied = $true
            }

            $fileRow = [pscustomobject]@{
                ($script:Headers.File[0]) = 'src/A.cs'
            }
            $result = Update-StrictAttributionMetric -Commits @() -RevToAuthor @{} -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 10 -CacheDir '.cache' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -FileRows @($fileRow) -CommitterRows @() -Parallel 4 -RenameMap @{}

            $script:strictRowsApplied | Should -BeTrue
            $result.KillMatrix['alice']['bob'] | Should -Be 2
            $result.AuthorSelfDead['alice'] | Should -Be 1
            $result.AuthorBorn['alice'] | Should -Be 9
        }
    }
}

Describe 'Strict hunk effective segments' {
    It 'does not create canonical events from comment-only hunks' {
        $offsetMap = Initialize-CanonicalOffsetMap
        $hunks = @(
            [pscustomobject]@{
                OldStart = 10
                OldCount = 1
                NewStart = 10
                NewCount = 1
                EffectiveSegments = @()
            }
        )
        $events = @(Get-StrictCanonicalHunkEvents -Hunks $hunks -Revision 10 -Author 'alice' -OffsetEvents $offsetMap)
        $events.Count | Should -Be 0
    }

    It 'uses effective segments for repeated hunk counting' {
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        Hunks = @(
                            [pscustomobject]@{
                                OldStart = 10
                                OldCount = 1
                                NewStart = 10
                                NewCount = 1
                                EffectiveSegments = @()
                            }
                        )
                    }
                }
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        Hunks = @(
                            [pscustomobject]@{
                                OldStart = 10
                                OldCount = 1
                                NewStart = 10
                                NewCount = 1
                                EffectiveSegments = @(
                                    [pscustomobject]@{
                                        OldStart = 10
                                        OldCount = 1
                                        NewStart = 10
                                        NewCount = 1
                                    }
                                )
                            }
                        )
                    }
                }
            },
            [pscustomobject]@{
                Revision = 3
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        Hunks = @(
                            [pscustomobject]@{
                                OldStart = 10
                                OldCount = 1
                                NewStart = 10
                                NewCount = 1
                                EffectiveSegments = @(
                                    [pscustomobject]@{
                                        OldStart = 10
                                        OldCount = 1
                                        NewStart = 10
                                        NewCount = 1
                                    }
                                )
                            }
                        )
                    }
                }
            }
        )
        $revToAuthor = @{
            1 = 'alice'
            2 = 'alice'
            3 = 'alice'
        }

        $detail = Get-StrictHunkDetail -Commits $commits -RevToAuthor $revToAuthor -RenameMap @{}
        (Get-HashtableIntValue -Table $detail.AuthorRepeatedHunk -Key 'alice') | Should -Be 1
    }
}

Describe 'Strict 多リビジョンシナリオ — Compare-BlameOutput の帰属分類' {
    Context '5リビジョンにわたる複数著者の重複編集' {
        It 'born行の数は新しいリビジョンの行の中で当該リビジョンに帰属するものだけ' {
            # before(r3): alice wrote line1, bob wrote line2
            # after(r4):  alice wrote line1, bob wrote line2, carol wrote line3
            # → bornは line3(carol) の1行のみ
            $prevLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 2; Author = 'bob' }
            )
            $currLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 2; Author = 'bob' }
                [pscustomobject]@{ LineNumber = 3; Content = 'line3'; Revision = 4; Author = 'carol' }
            )
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            @($result.BornLines).Count | Should -Be 1
            $result.BornLines[0].Line.Author | Should -Be 'carol'
            @($result.KilledLines).Count | Should -Be 0
        }

        It 'dead行の数は消えた行のみ（作者は元の行の帰属）' {
            # before(r4): alice line1, bob line2, carol line3
            # after(r5):  alice line1, carol line3
            # → dead は line2(bob) の1行
            $prevLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 2; Author = 'bob' }
                [pscustomobject]@{ LineNumber = 3; Content = 'line3'; Revision = 4; Author = 'carol' }
            )
            $currLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line3'; Revision = 4; Author = 'carol' }
            )
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            @($result.KilledLines).Count | Should -Be 1
            $result.KilledLines[0].Line.Author | Should -Be 'bob'
            @($result.BornLines).Count | Should -Be 0
        }

        It '行の置換（delete+add）で dead と born が各1行' {
            # before: alice line1
            # after:  bob newline1
            $prevLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
            )
            $currLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'newline1'; Revision = 5; Author = 'bob' }
            )
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            @($result.KilledLines).Count | Should -Be 1
            $result.KilledLines[0].Line.Author | Should -Be 'alice'
            @($result.BornLines).Count | Should -Be 1
            $result.BornLines[0].Line.Author | Should -Be 'bob'
        }

        It '空ファイルから複数行追加ですべてborn' {
            $prevLines = @()
            $currLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 3; Content = 'line3'; Revision = 1; Author = 'alice' }
            )
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            @($result.BornLines).Count | Should -Be 3
            @($result.KilledLines).Count | Should -Be 0
        }

        It '全行削除ですべてdead' {
            $prevLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 2; Author = 'bob' }
            )
            $currLines = @()
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            @($result.KilledLines).Count | Should -Be 2
            @($result.BornLines).Count | Should -Be 0
        }

        It '行の移動（順序変更）はmoveとして分類される' {
            # before: alice line1, bob line2
            # after:  bob line2, alice line1 (順序反転、同一内容+帰属)
            $prevLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line1'; Revision = 1; Author = 'alice' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line2'; Revision = 2; Author = 'bob' }
            )
            $currLines = @(
                [pscustomobject]@{ LineNumber = 1; Content = 'line2'; Revision = 2; Author = 'bob' }
                [pscustomobject]@{ LineNumber = 2; Content = 'line1'; Revision = 1; Author = 'alice' }
            )
            $result = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines

            # 行内容+帰属は同一なので killed/born ではなく matched/moved
            @($result.KilledLines).Count | Should -Be 0
            @($result.BornLines).Count | Should -Be 0
            @($result.MovedPairs).Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'Update-StrictAccumulatorFromComparison の帰属カウンタ' {
        It '範囲外リビジョンのborn行は加算されない' {
            $accumulator = New-StrictAttributionAccumulator
            $comparison = [pscustomobject]@{
                BornLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 3; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 10; Author = 'bob' } }
                )
                KilledLines = @()
                MovedPairs  = @()
            }

            # 範囲 FromRevision=5, ToRevision=10 → r3は範囲外
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'carol' -MetricFile 'src/A.cs' -FromRevision 5 -ToRevision 10

            # bornはr10の分のみ(Revision==currentRevision条件)
            [int]$accumulator.AuthorBorn['bob'] | Should -Be 1
            $accumulator.AuthorBorn.ContainsKey('alice') | Should -BeFalse
        }

        It 'born行のRevisionが現在リビジョンと一致しない場合はスキップされる' {
            $accumulator = New-StrictAttributionAccumulator
            $comparison = [pscustomobject]@{
                BornLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 8; Author = 'alice' } }
                )
                KilledLines = @()
                MovedPairs  = @()
            }

            # 現在リビジョンは10だがborn行のリビジョンは8
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'bob' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            $accumulator.AuthorBorn.ContainsKey('alice') | Should -BeFalse
        }

        It 'self-dead: キラーとborn作者が同一の場合AuthorSelfDeadに加算' {
            $accumulator = New-StrictAttributionAccumulator
            # alice が r5 で書いた行を alice 自身が r10 で削除
            $comparison = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                MovedPairs  = @()
            }

            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'alice' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            [int]$accumulator.AuthorSelfDead['alice'] | Should -Be 1
            [int]$accumulator.AuthorDead['alice'] | Should -Be 1
            $accumulator.AuthorOtherDead.ContainsKey('alice') | Should -BeFalse
        }

        It 'other-dead: キラーとborn作者が異なる場合AuthorOtherDeadとKillMatrixに加算' {
            $accumulator = New-StrictAttributionAccumulator
            # alice が r5 で書いた行を bob が r10 で削除
            $comparison = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                MovedPairs  = @()
            }

            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'bob' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            [int]$accumulator.AuthorOtherDead['alice'] | Should -Be 1
            [int]$accumulator.AuthorDead['alice'] | Should -Be 1
            [int]$accumulator.KillMatrix['bob']['alice'] | Should -Be 1
            [int]$accumulator.AuthorModifiedOthersCode['bob'] | Should -Be 1
            $accumulator.AuthorSelfDead.ContainsKey('alice') | Should -BeFalse
        }

        It 'survived = born - dead が正しく追跡される' {
            $accumulator = New-StrictAttributionAccumulator
            # alice: r5で3行born、r10でそのうち1行dead
            $bornComparison = [pscustomobject]@{
                BornLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                KilledLines = @()
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $bornComparison -Revision 5 -Killer 'alice' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            [int]$accumulator.AuthorSurvived['alice'] | Should -Be 3 -Because 'born直後のsurvived'
            [int]$accumulator.AuthorBorn['alice'] | Should -Be 3

            $deadComparison = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $deadComparison -Revision 10 -Killer 'bob' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            [int]$accumulator.AuthorSurvived['alice'] | Should -Be 2 -Because 'dead後のsurvived = 3 - 1'
            [int]$accumulator.AuthorDead['alice'] | Should -Be 1
        }

        It '範囲外リビジョンのdead行は加算されない' {
            $accumulator = New-StrictAttributionAccumulator
            # r3(範囲外)で生まれた行がr10で消された場合
            $comparison = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 3; Author = 'alice' } }
                )
                MovedPairs  = @()
            }

            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'bob' -MetricFile 'src/A.cs' -FromRevision 5 -ToRevision 10

            $accumulator.AuthorDead.ContainsKey('alice') | Should -BeFalse
        }

        It '内部移動はAuthorInternalMoveとFileInternalMoveに加算される' {
            $accumulator = New-StrictAttributionAccumulator
            $comparison = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @()
                MovedPairs  = @(
                    [pscustomobject]@{ PrevIndex = 0; CurrIndex = 2 }
                    [pscustomobject]@{ PrevIndex = 1; CurrIndex = 3 }
                )
            }

            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comparison -Revision 10 -Killer 'alice' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 10

            [int]$accumulator.AuthorInternalMove['alice'] | Should -Be 2
            [int]$accumulator.FileInternalMove['src/A.cs'] | Should -Be 2
        }

        It '複数リビジョンで累積カウントが正しい' {
            $accumulator = New-StrictAttributionAccumulator

            # r5: alice が 3行born
            $comp5 = [pscustomobject]@{
                BornLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                KilledLines = @()
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comp5 -Revision 5 -Killer 'alice' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 20

            # r7: bob が 2行born
            $comp7 = [pscustomobject]@{
                BornLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 7; Author = 'bob' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 7; Author = 'bob' } }
                )
                KilledLines = @()
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comp7 -Revision 7 -Killer 'bob' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 20

            # r10: carol が alice の1行を消し、bob の1行を消す
            $comp10 = [pscustomobject]@{
                BornLines   = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 10; Author = 'carol' } }
                )
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 7; Author = 'bob' } }
                )
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comp10 -Revision 10 -Killer 'carol' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 20

            # r15: alice が自分の1行を消す (self-dead)
            $comp15 = [pscustomobject]@{
                BornLines   = @()
                KilledLines = @(
                    [pscustomobject]@{ Line = [pscustomobject]@{ Revision = 5; Author = 'alice' } }
                )
                MovedPairs  = @()
            }
            Update-StrictAccumulatorFromComparison -Accumulator $accumulator -Comparison $comp15 -Revision 15 -Killer 'alice' -MetricFile 'src/A.cs' -FromRevision 1 -ToRevision 20

            # 検証
            [int]$accumulator.AuthorBorn['alice'] | Should -Be 3
            [int]$accumulator.AuthorBorn['bob'] | Should -Be 2
            [int]$accumulator.AuthorBorn['carol'] | Should -Be 1

            [int]$accumulator.AuthorDead['alice'] | Should -Be 2 -Because 'r10で1行, r15で1行'
            [int]$accumulator.AuthorDead['bob'] | Should -Be 1
            $accumulator.AuthorDead.ContainsKey('carol') | Should -BeFalse

            [int]$accumulator.AuthorSelfDead['alice'] | Should -Be 1 -Because 'r15で自身が削除'
            [int]$accumulator.AuthorOtherDead['alice'] | Should -Be 1 -Because 'r10でcarolが削除'
            [int]$accumulator.AuthorOtherDead['bob'] | Should -Be 1

            [int]$accumulator.AuthorSurvived['alice'] | Should -Be 1 -Because '3born - 2dead'
            [int]$accumulator.AuthorSurvived['bob'] | Should -Be 1 -Because '2born - 1dead'
            [int]$accumulator.AuthorSurvived['carol'] | Should -Be 1

            [int]$accumulator.KillMatrix['carol']['alice'] | Should -Be 1
            [int]$accumulator.KillMatrix['carol']['bob'] | Should -Be 1

            [int]$accumulator.FileSurvived['src/A.cs'] | Should -Be 3 -Because '(3+2+1)born - (1+1+1)dead'
            [int]$accumulator.FileDead['src/A.cs'] | Should -Be 3
        }
    }
}






