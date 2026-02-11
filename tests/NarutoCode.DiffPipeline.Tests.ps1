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
}
