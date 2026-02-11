<#
.SYNOPSIS
Diff pipeline focused tests.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
}

Describe 'Diff pipeline refactor' {
    Context 'Update-RenamePairDiffStat' {
        BeforeEach {
            $script:originalGetRenamePairRealDiffStat = (Get-Item function:Get-RenamePairRealDiffStat).ScriptBlock.ToString()
        }

        AfterEach {
            Set-Item -Path function:Get-RenamePairRealDiffStat -Value $script:originalGetRenamePairRealDiffStat
        }

        It 'applies corrected diff to new path and clears old path stats' {
            Set-Item -Path function:Get-RenamePairRealDiffStat -Value {
                param(
                    [hashtable]$Context,
                    [string]$TargetUrl,
                    [string[]]$DiffArguments,
                    [string]$OldPath,
                    [string]$NewPath,
                    [int]$CopyRevision,
                    [int]$Revision
                )
                [void]$Context
                [void]$TargetUrl
                [void]$DiffArguments
                [void]$OldPath
                [void]$NewPath
                [void]$CopyRevision
                [void]$Revision
                return [pscustomobject]@{
                    AddedLines = 2
                    DeletedLines = 1
                    Hunks = @([pscustomobject]@{
                            OldStart = 1
                            OldCount = 1
                            NewStart = 1
                            NewCount = 2
                        })
                    IsBinary = $false
                    AddedLineHashes = @('h1')
                    DeletedLineHashes = @('h2')
                }
            }

            $commit = [pscustomobject]@{
                ChangedPathsFiltered = @(
                    [pscustomobject]@{
                        Path = 'src/Old.cs'
                        Action = 'D'
                    },
                    [pscustomobject]@{
                        Path = 'src/New.cs'
                        Action = 'A'
                        CopyFromPath = 'src/Old.cs'
                        CopyFromRev = 9
                    }
                )
                FileDiffStats = @{
                    'src/Old.cs' = [pscustomobject]@{
                        AddedLines = 4
                        DeletedLines = 5
                        Hunks = @([pscustomobject]@{
                                OldStart = 1
                                OldCount = 1
                                NewStart = 1
                                NewCount = 1
                            })
                        IsBinary = $false
                        AddedLineHashes = @('old-a')
                        DeletedLineHashes = @('old-d')
                    }
                    'src/New.cs' = [pscustomobject]@{
                        AddedLines = 9
                        DeletedLines = 8
                        Hunks = @([pscustomobject]@{
                                OldStart = 2
                                OldCount = 1
                                NewStart = 2
                                NewCount = 1
                            })
                        IsBinary = $false
                        AddedLineHashes = @('new-a')
                        DeletedLineHashes = @('new-d')
                    }
                }
            }

            Update-RenamePairDiffStat -Commit $commit -Revision 10 -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @()

            $commit.FileDiffStats['src/New.cs'].AddedLines | Should -Be 2
            $commit.FileDiffStats['src/New.cs'].DeletedLines | Should -Be 1
            @($commit.FileDiffStats['src/New.cs'].AddedLineHashes).Count | Should -Be 1
            @($commit.FileDiffStats['src/Old.cs'].Hunks).Count | Should -Be 0
            @($commit.FileDiffStats['src/Old.cs'].AddedLineHashes).Count | Should -Be 0
            @($commit.FileDiffStats['src/Old.cs'].DeletedLineHashes).Count | Should -Be 0
            $commit.FileDiffStats['src/Old.cs'].AddedLines | Should -Be 0
            $commit.FileDiffStats['src/Old.cs'].DeletedLines | Should -Be 0
        }
    }

    Context 'Set-CommitDerivedMetric' {
        It 'updates churn and message summary fields' {
            $longMessage = ('x' * 150) + "`r`nsecond line"
            $commit = [pscustomobject]@{
                Message = $longMessage
                FilesChanged = @('src/A.cs', 'src/B.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        AddedLines = 3
                        DeletedLines = 1
                    }
                    'src/B.cs' = [pscustomobject]@{
                        AddedLines = 1
                        DeletedLines = 3
                    }
                }
            }

            Set-CommitDerivedMetric -Commit $commit

            $commit.AddedLines | Should -Be 4
            $commit.DeletedLines | Should -Be 4
            $commit.Churn | Should -Be 8
            $commit.Entropy | Should -Be 1
            $commit.MsgLen | Should -Be $longMessage.Length
            $commit.MessageShort.Contains("`n") | Should -BeFalse
            $commit.MessageShort.Length | Should -Be ($script:NarutoContext.Constants.CommitMessageMaxLength + 3)
            $commit.MessageShort.EndsWith('...') | Should -BeTrue
        }
    }

    Context 'Pipeline stage orchestration' {
        BeforeEach {
            $script:origInvokeSvnCommandStage = (Get-Item function:Invoke-SvnCommand).ScriptBlock.ToString()
            $script:origConvertFromSvnLogXmlStage = (Get-Item function:ConvertFrom-SvnLogXml).ScriptBlock.ToString()
            $script:origGetSvnDiffArgumentListStage = (Get-Item function:Get-SvnDiffArgumentList).ScriptBlock.ToString()
            $script:origInitializeCommitDiffDataStage = (Get-Item function:Initialize-CommitDiffData).ScriptBlock.ToString()
            $script:origGetRenameMapStage = (Get-Item function:Get-RenameMap).ScriptBlock.ToString()
            $script:origGetCommitterMetricStage = (Get-Item function:Get-CommitterMetric).ScriptBlock.ToString()
            $script:origGetFileMetricStage = (Get-Item function:Get-FileMetric).ScriptBlock.ToString()
            $script:origGetCoChangeMetricStage = (Get-Item function:Get-CoChangeMetric).ScriptBlock.ToString()
            $script:origNewCommitRowFromCommitStage = (Get-Item function:New-CommitRowFromCommit).ScriptBlock.ToString()
            $script:origUpdateStrictAttributionMetricStage = (Get-Item function:Update-StrictAttributionMetric).ScriptBlock.ToString()
        }

        AfterEach {
            Set-Item -Path function:Invoke-SvnCommand -Value $script:origInvokeSvnCommandStage
            Set-Item -Path function:ConvertFrom-SvnLogXml -Value $script:origConvertFromSvnLogXmlStage
            Set-Item -Path function:Get-SvnDiffArgumentList -Value $script:origGetSvnDiffArgumentListStage
            Set-Item -Path function:Initialize-CommitDiffData -Value $script:origInitializeCommitDiffDataStage
            Set-Item -Path function:Get-RenameMap -Value $script:origGetRenameMapStage
            Set-Item -Path function:Get-CommitterMetric -Value $script:origGetCommitterMetricStage
            Set-Item -Path function:Get-FileMetric -Value $script:origGetFileMetricStage
            Set-Item -Path function:Get-CoChangeMetric -Value $script:origGetCoChangeMetricStage
            Set-Item -Path function:New-CommitRowFromCommit -Value $script:origNewCommitRowFromCommitStage
            Set-Item -Path function:Update-StrictAttributionMetric -Value $script:origUpdateStrictAttributionMetricStage
        }

        It 'invokes log and diff stage dependencies and returns stage DTO' {
            Set-Item -Path function:Invoke-SvnCommand -Value {
                param([hashtable]$Context, [string[]]$Arguments, [string]$ErrorContext)
                [void]$Context
                [void]$ErrorContext
                $script:lastSvnArgumentsStage = @($Arguments)
                return '<log/>'
            }
            Set-Item -Path function:ConvertFrom-SvnLogXml -Value {
                param([string]$XmlText)
                [void]$XmlText
                return @([pscustomobject]@{ Revision = 5; Author = 'alice'; ChangedPaths = @() })
            }
            Set-Item -Path function:Get-SvnDiffArgumentList -Value {
                param([switch]$IgnoreWhitespace)
                $script:lastIgnoreWhitespaceStage = [bool]$IgnoreWhitespace
                return @('diff', '--internal-diff')
            }
            Set-Item -Path function:Initialize-CommitDiffData -Value {
                param(
                    [hashtable]$Context,
                    [object[]]$Commits,
                    [string]$CacheDir,
                    [string]$TargetUrl,
                    [string[]]$DiffArguments,
                    [string[]]$IncludeExtensions,
                    [string[]]$ExcludeExtensions,
                    [string[]]$IncludePathPatterns,
                    [string[]]$ExcludePathPatterns,
                    [string]$LogPathPrefix,
                    [switch]$ExcludeCommentOnlyLines,
                    [int]$Parallel
                )
                [void]$Context
                [void]$Commits
                [void]$CacheDir
                [void]$TargetUrl
                [void]$DiffArguments
                [void]$IncludeExtensions
                [void]$ExcludeExtensions
                [void]$IncludePathPatterns
                [void]$ExcludePathPatterns
                [void]$LogPathPrefix
                [void]$ExcludeCommentOnlyLines
                [void]$Parallel
                return @{ 5 = 'alice' }
            }
            Set-Item -Path function:Get-RenameMap -Value {
                param([object[]]$Commits, [string]$LogPathPrefix)
                [void]$Commits
                [void]$LogPathPrefix
                return @{ 'src/old.cs' = 'src/new.cs' }
            }

            $executionState = [pscustomobject]@{
                FromRevision = 1
                ToRevision = 5
                TargetUrl = 'https://example.invalid/svn/repo'
                CacheDir = 'cache'
                IncludeExtensions = @('cs')
                ExcludeExtensions = @('bin')
                IncludePaths = @('src/*')
                ExcludePaths = @('tmp/*')
                LogPathPrefix = ''
                ExcludeCommentOnlyLines = $false
            }

            $result = Invoke-PipelineLogAndDiffStage -ExecutionState $executionState -IgnoreWhitespace -Parallel 4

            $result.Commits.Count | Should -Be 1
            $result.RevToAuthor[5] | Should -Be 'alice'
            $result.RenameMap['src/old.cs'] | Should -Be 'src/new.cs'
            $script:lastIgnoreWhitespaceStage | Should -BeTrue
            $script:lastSvnArgumentsStage[0] | Should -Be 'log'
        }

        It 'invokes aggregation dependencies and returns aggregation DTO' {
            Set-Item -Path function:Get-CommitterMetric -Value {
                param([object[]]$Commits, [hashtable]$RenameMap)
                [void]$Commits
                [void]$RenameMap
                return @([pscustomobject]@{ '作者' = 'alice' })
            }
            Set-Item -Path function:Get-FileMetric -Value {
                param([object[]]$Commits, [hashtable]$RenameMap)
                [void]$Commits
                [void]$RenameMap
                return @([pscustomobject]@{ 'ファイルパス' = 'src/A.cs' })
            }
            Set-Item -Path function:Get-CoChangeMetric -Value {
                param([object[]]$Commits, [int]$TopNCount, [hashtable]$RenameMap)
                [void]$Commits
                [void]$RenameMap
                $script:lastTopNCountStage = $TopNCount
                return @([pscustomobject]@{ 'ファイルA' = 'src/A.cs'; 'ファイルB' = 'src/B.cs' })
            }
            Set-Item -Path function:New-CommitRowFromCommit -Value {
                param([object[]]$Commits)
                [void]$Commits
                return @([pscustomobject]@{ 'リビジョン' = 5 })
            }

            $result = Invoke-PipelineAggregationStage -Commits @([pscustomobject]@{ Revision = 5 }) -RenameMap @{ 'old' = 'new' }

            $result.CommitterRows.Count | Should -Be 1
            $result.FileRows.Count | Should -Be 1
            $result.CouplingRows.Count | Should -Be 1
            $result.CommitRows.Count | Should -Be 1
            $script:lastTopNCountStage | Should -Be 0
        }

        It 'invokes strict stage with merged dependencies' {
            Set-Item -Path function:Update-StrictAttributionMetric -Value {
                param(
                    [hashtable]$Context,
                    [object[]]$Commits,
                    [hashtable]$RevToAuthor,
                    [string]$TargetUrl,
                    [int]$FromRevision,
                    [int]$ToRevision,
                    [string]$CacheDir,
                    [string[]]$IncludeExtensions,
                    [string[]]$ExcludeExtensions,
                    [string[]]$IncludePaths,
                    [string[]]$ExcludePaths,
                    [object[]]$FileRows,
                    [object[]]$CommitterRows,
                    [int]$Parallel,
                    [hashtable]$RenameMap
                )
                [void]$Context
                [void]$Commits
                [void]$RevToAuthor
                [void]$TargetUrl
                [void]$FromRevision
                [void]$ToRevision
                [void]$CacheDir
                [void]$IncludeExtensions
                [void]$ExcludeExtensions
                [void]$IncludePaths
                [void]$ExcludePaths
                [void]$FileRows
                [void]$CommitterRows
                [void]$RenameMap
                $script:lastStrictParallelStage = $Parallel
                return [pscustomobject]@{
                    KillMatrix = @{ alice = @{ bob = 1 } }
                    AuthorSelfDead = @{ alice = 2 }
                    AuthorBorn = @{ alice = 3 }
                }
            }

            $executionState = [pscustomobject]@{
                TargetUrl = 'https://example.invalid/svn/repo'
                FromRevision = 1
                ToRevision = 10
                CacheDir = 'cache'
                IncludeExtensions = @('cs')
                ExcludeExtensions = @('bin')
                IncludePaths = @('src/*')
                ExcludePaths = @('tmp/*')
            }
            $logAndDiffStage = [pscustomobject]@{
                Commits = @([pscustomobject]@{ Revision = 10 })
                RevToAuthor = @{ 10 = 'alice' }
                RenameMap = @{ 'src/old.cs' = 'src/new.cs' }
            }
            $aggregationStage = [pscustomobject]@{
                FileRows = @([pscustomobject]@{ 'ファイルパス' = 'src/new.cs' })
                CommitterRows = @([pscustomobject]@{ '作者' = 'alice' })
            }

            $result = Invoke-PipelineStrictStage -ExecutionState $executionState -LogAndDiffStage $logAndDiffStage -AggregationStage $aggregationStage -Parallel 3

            $result.KillMatrix['alice']['bob'] | Should -Be 1
            $result.AuthorSelfDead['alice'] | Should -Be 2
            $result.AuthorBorn['alice'] | Should -Be 3
            $script:lastStrictParallelStage | Should -Be 3
        }
    }
}
