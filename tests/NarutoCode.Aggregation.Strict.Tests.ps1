<#
.SYNOPSIS
Strict aggregation focused tests.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
    $script:Headers = Get-MetricHeader -Context $script:NarutoContext
}

Describe 'Strict aggregation refactor' {
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
        $row.($script:Headers.File[16]) | Should -Be 2
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
        $row.($script:Headers.Committer[19]) | Should -Be 2
        $row.($script:Headers.Committer[20]) | Should -Be 10
        $row.($script:Headers.Committer[21]) | Should -Be 0.5
        $row.($script:Headers.Committer[22]) | Should -Be 1
        $row.($script:Headers.Committer[23]) | Should -Be 1
        $row.($script:Headers.Committer[24]) | Should -Be 1
        $row.($script:Headers.Committer[29]) | Should -Be 1
        $row.($script:Headers.Committer[30]) | Should -Be 1
        $row.($script:Headers.Committer[31]) | Should -Be 6
        $row.($script:Headers.Committer[32]) | Should -Be 3
        $row.($script:Headers.Committer[33]) | Should -Be 0.5
        $row.($script:Headers.Committer[34]) | Should -Be 1
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
