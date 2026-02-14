<#
.SYNOPSIS
Diff pipeline focused tests.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
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

    Context 'Invoke-CommitDiffPrefetch comment mask with rename header' {
        BeforeEach {
            $script:origGetCachedOrFetchDiffTextPrefetch = (Get-Item function:Get-CachedOrFetchDiffText).ScriptBlock.ToString()
            $script:origGetCachedOrFetchCatTextPrefetch = (Get-Item function:Get-CachedOrFetchCatText).ScriptBlock.ToString()
            $script:origConvertFromSvnUnifiedDiffPrefetch = (Get-Item function:ConvertFrom-SvnUnifiedDiff).ScriptBlock.ToString()
            $script:prefetchCatLookups = New-Object 'System.Collections.Generic.List[string]'
            $script:prefetchLineMaskByPath = $null
        }

        AfterEach {
            Set-Item -Path function:Get-CachedOrFetchDiffText -Value $script:origGetCachedOrFetchDiffTextPrefetch
            Set-Item -Path function:Get-CachedOrFetchCatText -Value $script:origGetCachedOrFetchCatTextPrefetch
            Set-Item -Path function:ConvertFrom-SvnUnifiedDiff -Value $script:origConvertFromSvnUnifiedDiffPrefetch
        }

        It 'uses old path/revision from diff header when building comment masks' {
            Set-Item -Path function:Get-CachedOrFetchDiffText -Value {
                param(
                    [hashtable]$Context,
                    [string]$CacheDir,
                    [int]$Revision,
                    [string]$TargetUrl,
                    [string[]]$DiffArguments
                )
                [void]$Context
                [void]$CacheDir
                [void]$Revision
                [void]$TargetUrl
                [void]$DiffArguments
                return @"
Index: src/new.cs
===================================================================
--- src/old.cs	(revision 9)
+++ src/new.cs	(revision 10)
@@ -1 +1 @@
-// old comment
+int x = 1;
"@
            }
            Set-Item -Path function:Get-CachedOrFetchCatText -Value {
                param(
                    [hashtable]$Context,
                    [string]$Repo,
                    [string]$FilePath,
                    [int]$Revision,
                    [string]$CacheDir
                )
                [void]$Context
                [void]$Repo
                [void]$CacheDir
                $lookupKey = [string]$FilePath + '@' + [string]$Revision
                [void]$script:prefetchCatLookups.Add($lookupKey)
                if ($FilePath -eq 'src/old.cs' -and $Revision -eq 9)
                {
                    return "// old comment`n"
                }
                if ($FilePath -eq 'src/new.cs' -and $Revision -eq 10)
                {
                    return "int x = 1;`n"
                }
                return $null
            }
            Set-Item -Path function:ConvertFrom-SvnUnifiedDiff -Value {
                param(
                    [string]$DiffText,
                    [int]$DetailLevel,
                    [switch]$ExcludeCommentOnlyLines,
                    [hashtable]$LineMaskByPath
                )
                [void]$DiffText
                [void]$DetailLevel
                [void]$ExcludeCommentOnlyLines
                $script:prefetchLineMaskByPath = $LineMaskByPath
                return @{
                    'src/new.cs' = [pscustomobject]@{
                        AddedLines = 0
                        DeletedLines = 0
                        Hunks = @()
                        IsBinary = $false
                        AddedLineHashes = @()
                        DeletedLineHashes = @()
                    }
                }
            }

            $prefetchItems = @(
                [pscustomobject]@{
                    Revision = 10
                    CacheDir = '.cache'
                    TargetUrl = 'https://example.invalid/svn/repo'
                    DiffArguments = @('diff', '--internal-diff')
                    ChangedPaths = @(
                        [pscustomobject]@{
                            Path = 'src/new.cs'
                            Action = 'A'
                            CopyFromPath = 'src/old.cs'
                            CopyFromRev = 9
                        }
                    )
                    ExcludeCommentOnlyLines = $true
                }
            )

            $raw = Invoke-CommitDiffPrefetch -Context $script:TestContext -PrefetchItems $prefetchItems -Parallel 1

            $raw.ContainsKey(10) | Should -BeTrue
            @($script:prefetchCatLookups) | Should -Be @('src/old.cs@9', 'src/new.cs@10')
            $script:prefetchLineMaskByPath.ContainsKey('src/new.cs') | Should -BeTrue
            @($script:prefetchLineMaskByPath['src/new.cs'].OldMask) | Should -Be @($true)
            @($script:prefetchLineMaskByPath['src/new.cs'].NewMask) | Should -Be @($false)
        }
    }

    Context 'Invoke-CommitDiffPrefetch Replace fallback without copyFromPath' {
        BeforeEach {
            $script:origGetCachedOrFetchDiffTextReplace = (Get-Item function:Get-CachedOrFetchDiffText).ScriptBlock.ToString()
            $script:origGetCachedOrFetchCatTextReplace = (Get-Item function:Get-CachedOrFetchCatText).ScriptBlock.ToString()
            $script:origConvertFromSvnUnifiedDiffReplace = (Get-Item function:ConvertFrom-SvnUnifiedDiff).ScriptBlock.ToString()
            $script:replaceCatLookups = New-Object 'System.Collections.Generic.List[string]'
            $script:replaceLineMaskByPath = $null
        }

        AfterEach {
            Set-Item -Path function:Get-CachedOrFetchDiffText -Value $script:origGetCachedOrFetchDiffTextReplace
            Set-Item -Path function:Get-CachedOrFetchCatText -Value $script:origGetCachedOrFetchCatTextReplace
            Set-Item -Path function:ConvertFrom-SvnUnifiedDiff -Value $script:origConvertFromSvnUnifiedDiffReplace
        }

        It 'uses same path at revision-1 as old when Replace has no copyFromPath and no diff header' {
            Set-Item -Path function:Get-CachedOrFetchDiffText -Value {
                param(
                    [hashtable]$Context,
                    [string]$CacheDir,
                    [int]$Revision,
                    [string]$TargetUrl,
                    [string[]]$DiffArguments
                )
                [void]$Context
                [void]$CacheDir
                [void]$Revision
                [void]$TargetUrl
                [void]$DiffArguments
                # diff ヘッダーなし（フォールバック経路を強制）
                return ''
            }
            Set-Item -Path function:Get-CachedOrFetchCatText -Value {
                param(
                    [hashtable]$Context,
                    [string]$Repo,
                    [string]$FilePath,
                    [int]$Revision,
                    [string]$CacheDir
                )
                [void]$Context
                [void]$Repo
                [void]$CacheDir
                $lookupKey = [string]$FilePath + '@' + [string]$Revision
                [void]$script:replaceCatLookups.Add($lookupKey)
                if ($FilePath -eq 'src/target.cs' -and $Revision -eq 9)
                {
                    return "// old version`n"
                }
                if ($FilePath -eq 'src/target.cs' -and $Revision -eq 10)
                {
                    return "int y = 2;`n"
                }
                return $null
            }
            Set-Item -Path function:ConvertFrom-SvnUnifiedDiff -Value {
                param(
                    [string]$DiffText,
                    [int]$DetailLevel,
                    [switch]$ExcludeCommentOnlyLines,
                    [hashtable]$LineMaskByPath
                )
                [void]$DiffText
                [void]$DetailLevel
                [void]$ExcludeCommentOnlyLines
                $script:replaceLineMaskByPath = $LineMaskByPath
                return @{}
            }

            $prefetchItems = @(
                [pscustomobject]@{
                    Revision = 10
                    CacheDir = '.cache'
                    TargetUrl = 'https://example.invalid/svn/repo'
                    DiffArguments = @('diff', '--internal-diff')
                    ChangedPaths = @(
                        [pscustomobject]@{
                            Path = 'src/target.cs'
                            Action = 'R'
                            CopyFromPath = ''
                            CopyFromRev = $null
                        }
                    )
                    ExcludeCommentOnlyLines = $true
                }
            )

            Invoke-CommitDiffPrefetch -Context $script:TestContext -PrefetchItems $prefetchItems -Parallel 1

            @($script:replaceCatLookups) | Should -Be @('src/target.cs@9', 'src/target.cs@10')
            $script:replaceLineMaskByPath.ContainsKey('src/target.cs') | Should -BeTrue
            @($script:replaceLineMaskByPath['src/target.cs'].OldMask) | Should -Be @($true)
            @($script:replaceLineMaskByPath['src/target.cs'].NewMask) | Should -Be @($false)
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
            $commit.MessageShort.Length | Should -Be ($script:TestContext.Constants.CommitMessageMaxLength + 3)
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

Describe 'Invoke-NarutoCodePipeline run_meta write policy' {
    BeforeEach {
        $script:origResolvePipelineExecutionStateMeta = (Get-Item function:Resolve-PipelineExecutionState).ScriptBlock.ToString()
        $script:origInvokePipelineLogStageMeta = (Get-Item function:Invoke-PipelineLogStage).ScriptBlock.ToString()
        $script:origInvokePipelineDiffStageMeta = (Get-Item function:Invoke-PipelineDiffStage).ScriptBlock.ToString()
        $script:origInvokePipelineAggregationCommitterStageMeta = (Get-Item function:Invoke-PipelineAggregationCommitterStage).ScriptBlock.ToString()
        $script:origInvokePipelineAggregationFileStageMeta = (Get-Item function:Invoke-PipelineAggregationFileStage).ScriptBlock.ToString()
        $script:origInvokePipelineAggregationCouplingStageMeta = (Get-Item function:Invoke-PipelineAggregationCouplingStage).ScriptBlock.ToString()
        $script:origInvokePipelineAggregationCommitStageMeta = (Get-Item function:Invoke-PipelineAggregationCommitStage).ScriptBlock.ToString()
        $script:origInvokePipelineStrictStageMeta = (Get-Item function:Invoke-PipelineStrictStage).ScriptBlock.ToString()
        $script:origWritePipelineCsvArtifactsMeta = (Get-Item function:Write-PipelineCsvArtifacts).ScriptBlock.ToString()
        $script:origWritePipelineVisualizationArtifactsMeta = (Get-Item function:Write-PipelineVisualizationArtifacts).ScriptBlock.ToString()
        $script:origWriteJsonFileMeta = (Get-Item function:Write-JsonFile).ScriptBlock.ToString()
        $script:origWriteRunSummaryMeta = (Get-Item function:Write-RunSummary).ScriptBlock.ToString()
        $script:runMetaWriteCount = 0
        $script:testOutDirMeta = Join-Path $env:TEMP ('narutocode_run_meta_policy_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testOutDirMeta -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Set-Item -Path function:Resolve-PipelineExecutionState -Value $script:origResolvePipelineExecutionStateMeta
        Set-Item -Path function:Invoke-PipelineLogStage -Value $script:origInvokePipelineLogStageMeta
        Set-Item -Path function:Invoke-PipelineDiffStage -Value $script:origInvokePipelineDiffStageMeta
        Set-Item -Path function:Invoke-PipelineAggregationCommitterStage -Value $script:origInvokePipelineAggregationCommitterStageMeta
        Set-Item -Path function:Invoke-PipelineAggregationFileStage -Value $script:origInvokePipelineAggregationFileStageMeta
        Set-Item -Path function:Invoke-PipelineAggregationCouplingStage -Value $script:origInvokePipelineAggregationCouplingStageMeta
        Set-Item -Path function:Invoke-PipelineAggregationCommitStage -Value $script:origInvokePipelineAggregationCommitStageMeta
        Set-Item -Path function:Invoke-PipelineStrictStage -Value $script:origInvokePipelineStrictStageMeta
        Set-Item -Path function:Write-PipelineCsvArtifacts -Value $script:origWritePipelineCsvArtifactsMeta
        Set-Item -Path function:Write-PipelineVisualizationArtifacts -Value $script:origWritePipelineVisualizationArtifactsMeta
        Set-Item -Path function:Write-JsonFile -Value $script:origWriteJsonFileMeta
        Set-Item -Path function:Write-RunSummary -Value $script:origWriteRunSummaryMeta
        Remove-Item -Path $script:testOutDirMeta -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes run_meta.json exactly once in pipeline execution' {
        Set-Item -Path function:Resolve-PipelineExecutionState -Value {
            param(
                [hashtable]$Context,
                [string]$RepoUrl,
                [int]$FromRevision,
                [int]$ToRevision,
                [string]$OutDirectory,
                [string[]]$IncludePaths,
                [string[]]$ExcludePaths,
                [string[]]$IncludeExtensions,
                [string[]]$ExcludeExtensions,
                [string]$SvnExecutable,
                [string]$Username,
                [securestring]$Password,
                [switch]$NonInteractive,
                [switch]$TrustServerCert,
                [switch]$ExcludeCommentOnlyLines
            )
            [void]$Context
            [void]$RepoUrl
            [void]$FromRevision
            [void]$ToRevision
            [void]$IncludePaths
            [void]$ExcludePaths
            [void]$IncludeExtensions
            [void]$ExcludeExtensions
            [void]$SvnExecutable
            [void]$Username
            [void]$Password
            [void]$NonInteractive
            [void]$TrustServerCert
            [void]$ExcludeCommentOnlyLines
            return [pscustomobject]@{
                RepoUrl = 'https://example.invalid/svn/repo'
                FromRevision = 1
                ToRevision = 2
                OutDirectory = $script:testOutDirMeta
                CacheDir = (Join-Path $script:testOutDirMeta 'cache')
                IncludePaths = @()
                ExcludePaths = @()
                IncludeExtensions = @()
                ExcludeExtensions = @()
                TargetUrl = 'https://example.invalid/svn/repo'
                LogPathPrefix = ''
                SvnVersion = '1.14.2'
                ExcludeCommentOnlyLines = $false
            }
        }
        Set-Item -Path function:Invoke-PipelineLogStage -Value {
            param([hashtable]$Context, [object]$ExecutionState)
            [void]$Context
            [void]$ExecutionState
            return [pscustomobject]@{
                Commits = @([pscustomobject]@{
                        Revision = 2
                        Author = 'alice'
                        FilesChanged = @('src/A.cs')
                        ChangedPathsFiltered = @()
                        FileDiffStats = @{}
                    })
            }
        }
        Set-Item -Path function:Invoke-PipelineDiffStage -Value {
            param([hashtable]$Context, [object]$ExecutionState, [object[]]$Commits, [switch]$IgnoreWhitespace, [int]$Parallel)
            [void]$Context
            [void]$ExecutionState
            [void]$IgnoreWhitespace
            [void]$Parallel
            return [pscustomobject]@{
                Commits = @($Commits)
                RevToAuthor = @{ 2 = 'alice' }
                RenameMap = @{}
            }
        }
        Set-Item -Path function:Invoke-PipelineAggregationCommitterStage -Value {
            param([hashtable]$Context, [object[]]$Commits, [hashtable]$RenameMap)
            [void]$Context
            [void]$Commits
            [void]$RenameMap
            return @([pscustomobject]@{
                    '作者' = 'alice'
                })
        }
        Set-Item -Path function:Invoke-PipelineAggregationFileStage -Value {
            param([hashtable]$Context, [object[]]$Commits, [hashtable]$RenameMap)
            [void]$Context
            [void]$Commits
            [void]$RenameMap
            return @([pscustomobject]@{
                    'ファイルパス' = 'src/A.cs'
                })
        }
        Set-Item -Path function:Invoke-PipelineAggregationCouplingStage -Value {
            param([hashtable]$Context, [object[]]$Commits, [hashtable]$RenameMap)
            [void]$Context
            [void]$Commits
            [void]$RenameMap
            return @([pscustomobject]@{
                    'ファイルA' = 'src/A.cs'
                    'ファイルB' = 'src/B.cs'
                })
        }
        Set-Item -Path function:Invoke-PipelineAggregationCommitStage -Value {
            param([hashtable]$Context, [object[]]$Commits)
            [void]$Context
            return @([pscustomobject]@{
                    'リビジョン' = 2
                })
        }
        Set-Item -Path function:Invoke-PipelineStrictStage -Value {
            param([hashtable]$Context, [object]$ExecutionState, [object]$LogAndDiffStage, [object]$AggregationStage, [int]$Parallel)
            [void]$Context
            [void]$ExecutionState
            [void]$LogAndDiffStage
            [void]$AggregationStage
            [void]$Parallel
            return [pscustomobject]@{
                KillMatrix = @{ alice = @{ alice = 0 } }
                AuthorSelfDead = @{ alice = 0 }
                AuthorBorn = @{ alice = 1 }
            }
        }
        Set-Item -Path function:Write-PipelineCsvArtifacts -Value {
            param(
                [hashtable]$Context,
                [string]$OutDirectory,
                [object[]]$CommitterRows,
                [object[]]$FileRows,
                [object[]]$CommitRows,
                [object[]]$CouplingRows,
                [object]$StrictResult,
                [string]$Encoding,
                [string[]]$ArtifactNames
            )
            [void]$Context
            [void]$OutDirectory
            [void]$CommitterRows
            [void]$FileRows
            [void]$CommitRows
            [void]$CouplingRows
            [void]$StrictResult
            [void]$Encoding
            return @($ArtifactNames)
        }
        Set-Item -Path function:Write-PipelineVisualizationArtifacts -Value {
            param(
                [hashtable]$Context,
                [string]$OutDirectory,
                [object[]]$CommitterRows,
                [object[]]$FileRows,
                [object[]]$CommitRows,
                [object[]]$CouplingRows,
                [object]$StrictResult,
                [int]$TopNCount,
                [string]$Encoding,
                [string[]]$VisualizationFunctions
            )
            [void]$Context
            [void]$OutDirectory
            [void]$CommitterRows
            [void]$FileRows
            [void]$CommitRows
            [void]$CouplingRows
            [void]$StrictResult
            [void]$TopNCount
            [void]$Encoding
            return @($VisualizationFunctions)
        }
        Set-Item -Path function:Write-JsonFile -Value {
            param([object]$Data, [string]$FilePath, [int]$Depth, [string]$EncodingName)
            [void]$Data
            [void]$Depth
            [void]$EncodingName
            if ([string]$FilePath -like '*run_meta.json')
            {
                $script:runMetaWriteCount++
            }
        }
        Set-Item -Path function:Write-RunSummary -Value {
            param(
                [string]$TargetUrl,
                [int]$FromRevision,
                [int]$ToRevision,
                [object[]]$Commits,
                [int]$CommitCount,
                [object[]]$FileRows,
                [string]$OutDirectory
            )
            [void]$TargetUrl
            [void]$FromRevision
            [void]$ToRevision
            [void]$Commits
            [void]$CommitCount
            [void]$FileRows
            [void]$OutDirectory
        }

        $context = New-NarutoContext -SvnExecutable 'svn'
        [void](Invoke-NarutoCodePipeline -Context $context -RepoUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 2 -SvnExecutable 'svn' -OutDirectory $script:testOutDirMeta -Parallel 4 -TopNCount 10 -Encoding 'UTF8')

        $script:runMetaWriteCount | Should -Be 1
    }
}






