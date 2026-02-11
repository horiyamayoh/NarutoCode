<#
.SYNOPSIS
Helper function unit tests for refactored pipeline, aggregation, and strict modules.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
}

Describe 'Test-StrictHunkRangeOverlap' {
    It 'returns true for fully overlapping ranges' {
        Test-StrictHunkRangeOverlap -StartA 1 -EndA 10 -StartB 3 -EndB 7 | Should -BeTrue
    }

    It 'returns true for partially overlapping ranges' {
        Test-StrictHunkRangeOverlap -StartA 1 -EndA 5 -StartB 4 -EndB 8 | Should -BeTrue
    }

    It 'returns true for identical ranges' {
        Test-StrictHunkRangeOverlap -StartA 3 -EndA 7 -StartB 3 -EndB 7 | Should -BeTrue
    }

    It 'returns true when ranges share a single boundary point' {
        Test-StrictHunkRangeOverlap -StartA 1 -EndA 5 -StartB 5 -EndB 10 | Should -BeTrue
    }

    It 'returns false for non-overlapping ranges' {
        Test-StrictHunkRangeOverlap -StartA 1 -EndA 3 -StartB 4 -EndB 6 | Should -BeFalse
    }

    It 'returns false for reversed non-overlapping ranges' {
        Test-StrictHunkRangeOverlap -StartA 10 -EndA 15 -StartB 1 -EndB 9 | Should -BeFalse
    }

    It 'handles single-line ranges that match' {
        Test-StrictHunkRangeOverlap -StartA 5 -EndA 5 -StartB 5 -EndB 5 | Should -BeTrue
    }

    It 'handles single-line ranges that do not match' {
        Test-StrictHunkRangeOverlap -StartA 5 -EndA 5 -StartB 6 -EndB 6 | Should -BeFalse
    }
}

Describe 'Get-CommitDerivedChurnValues' {
    It 'returns zero values for commit with no files' {
        $commit = [pscustomobject]@{
            FilesChanged = @()
            FileDiffStats = @{}
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Added | Should -Be 0
        $result.Deleted | Should -Be 0
        $result.Churn | Should -Be 0
    }

    It 'correctly sums added and deleted lines across files' {
        $commit = [pscustomobject]@{
            FilesChanged = @('a.cs', 'b.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{
                    AddedLines = 10
                    DeletedLines = 3
                }
                'b.cs' = [pscustomobject]@{
                    AddedLines = 5
                    DeletedLines = 7
                }
            }
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Added | Should -Be 15
        $result.Deleted | Should -Be 10
        $result.Churn | Should -Be 25
    }

    It 'returns entropy of 1 for two files with equal churn' {
        $commit = [pscustomobject]@{
            FilesChanged = @('a.cs', 'b.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{
                    AddedLines = 5
                    DeletedLines = 0
                }
                'b.cs' = [pscustomobject]@{
                    AddedLines = 5
                    DeletedLines = 0
                }
            }
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Entropy | Should -Be 1
    }

    It 'returns entropy of 0 for a single file' {
        $commit = [pscustomobject]@{
            FilesChanged = @('a.cs')
            FileDiffStats = @{
                'a.cs' = [pscustomobject]@{
                    AddedLines = 10
                    DeletedLines = 2
                }
            }
        }
        $result = Get-CommitDerivedChurnValues -Commit $commit
        $result.Entropy | Should -Be 0
    }
}

Describe 'Get-CommitMessageSummary' {
    It 'returns full message when shorter than limit' {
        $result = Get-CommitMessageSummary -Message 'short message'
        $result.Length | Should -Be 13
        $result.Short | Should -Be 'short message'
    }

    It 'truncates long messages with ellipsis' {
        $longMsg = 'x' * 200
        $result = Get-CommitMessageSummary -Message $longMsg
        $result.Short.EndsWith('...') | Should -BeTrue
        $result.Short.Length | Should -Be ($script:NarutoContext.Constants.CommitMessageMaxLength + 3)
    }

    It 'collapses multi-line messages to single line' {
        $result = Get-CommitMessageSummary -Message "first line`r`nsecond line`nthird"
        $result.Short.Contains("`n") | Should -BeFalse
        $result.Short.Contains("`r") | Should -BeFalse
        $result.Short | Should -Be 'first line second line third'
    }

    It 'handles null message gracefully' {
        $result = Get-CommitMessageSummary -Message $null
        $result.Length | Should -Be 0
        $result.Short | Should -Be ''
    }

    It 'preserves original length including newlines' {
        $msg = "line1`r`nline2"
        $result = Get-CommitMessageSummary -Message $msg
        $result.Length | Should -Be $msg.Length
    }
}

Describe 'Get-RenameCorrectionCandidates' {
    It 'detects rename pair from A+D with CopyFromPath' {
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
                    CopyFromRev = 5
                }
            )
            FileDiffStats = @{
                'src/Old.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 10 }
                'src/New.cs' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0 }
            }
        }
        $candidates = @(Get-RenameCorrectionCandidates -Commit $commit -Revision 6)
        $candidates.Count | Should -Be 1
        $candidates[0].OldPath | Should -Be 'src/Old.cs'
        $candidates[0].NewPath | Should -Be 'src/New.cs'
        $candidates[0].CopyRevision | Should -Be 5
    }

    It 'returns nothing when no CopyFromPath is set' {
        $commit = [pscustomobject]@{
            ChangedPathsFiltered = @(
                [pscustomobject]@{
                    Path = 'src/A.cs'
                    Action = 'A'
                    CopyFromPath = $null
                    CopyFromRev = $null
                }
            )
            FileDiffStats = @{
                'src/A.cs' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0 }
            }
        }
        $candidates = @(Get-RenameCorrectionCandidates -Commit $commit -Revision 6)
        $candidates.Count | Should -Be 0
    }

    It 'ignores rename when old path was not deleted' {
        $commit = [pscustomobject]@{
            ChangedPathsFiltered = @(
                [pscustomobject]@{
                    Path = 'src/New.cs'
                    Action = 'A'
                    CopyFromPath = 'src/Old.cs'
                    CopyFromRev = 5
                }
            )
            FileDiffStats = @{
                'src/Old.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 0 }
                'src/New.cs' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0 }
            }
        }
        $candidates = @(Get-RenameCorrectionCandidates -Commit $commit -Revision 6)
        $candidates.Count | Should -Be 0
    }

    It 'defaults CopyRevision to Revision-1 when CopyFromRev is null' {
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
                    CopyFromRev = $null
                }
            )
            FileDiffStats = @{
                'src/Old.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 10 }
                'src/New.cs' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0 }
            }
        }
        $candidates = @(Get-RenameCorrectionCandidates -Commit $commit -Revision 10)
        $candidates.Count | Should -Be 1
        $candidates[0].CopyRevision | Should -Be 9
    }
}

Describe 'Get-CommitTransitionRenameContext' {
    It 'identifies rename pairs and consumed old paths' {
        $paths = @(
            [pscustomobject]@{ Path = 'src/Old.cs'; Action = 'D' },
            [pscustomobject]@{ Path = 'src/New.cs'; Action = 'A'; CopyFromPath = 'src/Old.cs'; CopyFromRev = 5 }
        )
        $result = Get-CommitTransitionRenameContext -Paths $paths
        $result.RenameNewToOld['src/New.cs'] | Should -Be 'src/Old.cs'
        $result.ConsumedOld.Contains('src/Old.cs') | Should -BeTrue
        $result.Deleted.Contains('src/Old.cs') | Should -BeTrue
    }

    It 'does not treat copy as rename when old path is not deleted' {
        $paths = @(
            [pscustomobject]@{ Path = 'src/Copy.cs'; Action = 'A'; CopyFromPath = 'src/Original.cs'; CopyFromRev = 5 },
            [pscustomobject]@{ Path = 'src/Original.cs'; Action = 'M' }
        )
        $result = Get-CommitTransitionRenameContext -Paths $paths
        $result.RenameNewToOld.Count | Should -Be 0
        $result.ConsumedOld.Count | Should -Be 0
    }
}

Describe 'ConvertTo-CommitRenameTransitions' {
    It 'generates before/after rows for rename pairs' {
        $renameMap = @{ 'src/New.cs' = 'src/Old.cs' }
        $dedup = New-Object 'System.Collections.Generic.HashSet[string]'
        $rows = @(ConvertTo-CommitRenameTransitions -RenameNewToOld $renameMap -Dedup $dedup)
        $rows.Count | Should -Be 1
        $rows[0].BeforePath | Should -Be 'src/Old.cs'
        $rows[0].AfterPath | Should -Be 'src/New.cs'
    }

    It 'deduplicates identical rename pairs' {
        $renameMap = @{ 'src/New.cs' = 'src/Old.cs' }
        $dedup = New-Object 'System.Collections.Generic.HashSet[string]'
        $rows1 = @(ConvertTo-CommitRenameTransitions -RenameNewToOld $renameMap -Dedup $dedup)
        $rows2 = @(ConvertTo-CommitRenameTransitions -RenameNewToOld $renameMap -Dedup $dedup)
        $rows1.Count | Should -Be 1
        $rows2.Count | Should -Be 0
    }
}

Describe 'ConvertTo-CommitNonRenameTransitions' {
    It 'generates delete-only transition for unrenamed deleted files' {
        $commit = [pscustomobject]@{
            FilesChanged = @()
        }
        $pathMap = @{}
        $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$deleted.Add('src/Removed.cs')
        $consumedOld = New-Object 'System.Collections.Generic.HashSet[string]'
        $dedup = New-Object 'System.Collections.Generic.HashSet[string]'

        $rows = @(ConvertTo-CommitNonRenameTransitions -Commit $commit -PathMap $pathMap -RenameNewToOld @{} -Deleted $deleted -ConsumedOld $consumedOld -Dedup $dedup)
        $delRow = $rows | Where-Object { $_.BeforePath -eq 'src/Removed.cs' }
        $delRow | Should -Not -BeNullOrEmpty
        $delRow.AfterPath | Should -BeNullOrEmpty
    }

    It 'skips consumed old paths' {
        $commit = [pscustomobject]@{
            FilesChanged = @()
        }
        $pathMap = @{}
        $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$deleted.Add('src/Old.cs')
        $consumedOld = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$consumedOld.Add('src/Old.cs')
        $dedup = New-Object 'System.Collections.Generic.HashSet[string]'

        $rows = @(ConvertTo-CommitNonRenameTransitions -Commit $commit -PathMap $pathMap -RenameNewToOld @{} -Deleted $deleted -ConsumedOld $consumedOld -Dedup $dedup)
        $delRow = $rows | Where-Object { $_.BeforePath -eq 'src/Old.cs' }
        $delRow | Should -BeNullOrEmpty
    }

    It 'generates add-only transition for new files' {
        $commit = [pscustomobject]@{
            FilesChanged = @('src/Brand.cs')
        }
        $pathMap = @{
            'src/Brand.cs' = @([pscustomobject]@{ Path = 'src/Brand.cs'; Action = 'A' })
        }
        $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
        $consumedOld = New-Object 'System.Collections.Generic.HashSet[string]'
        $dedup = New-Object 'System.Collections.Generic.HashSet[string]'

        $rows = @(ConvertTo-CommitNonRenameTransitions -Commit $commit -PathMap $pathMap -RenameNewToOld @{} -Deleted $deleted -ConsumedOld $consumedOld -Dedup $dedup)
        $addRow = $rows | Where-Object { $_.AfterPath -eq 'src/Brand.cs' }
        $addRow | Should -Not -BeNullOrEmpty
        $addRow.BeforePath | Should -BeNullOrEmpty
    }
}

Describe 'New-CommitDiffPrefetchPlan' {
    It 'builds prefetch items for commits with matching paths' {
        $commits = @(
            [pscustomobject]@{
                Revision = 10
                Author = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path = 'src/A.cs'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null }
                )
                ChangedPathsFiltered = @()
            }
        )
        $plan = New-CommitDiffPrefetchPlan -Commits $commits -CacheDir '.cache' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @() -IncludeExtensions @() -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @()
        $plan.RevToAuthor[10] | Should -Be 'alice'
        $plan.PrefetchItems.Count | Should -Be 1
        $plan.PrefetchItems[0].Revision | Should -Be 10
    }

    It 'skips commits with no matching paths after filter' {
        $commits = @(
            [pscustomobject]@{
                Revision = 10
                Author = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path = 'docs/README.md'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null }
                )
                ChangedPathsFiltered = @()
            }
        )
        $plan = New-CommitDiffPrefetchPlan -Commits $commits -CacheDir '.cache' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @() -IncludeExtensions @('cs') -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @()
        $plan.PrefetchItems.Count | Should -Be 0
        $plan.RevToAuthor[10] | Should -Be 'alice'
    }

    It 'populates RevToAuthor for all commits including skipped ones' {
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                ChangedPaths = @([pscustomobject]@{ Path = 'docs/x.md'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null })
                ChangedPathsFiltered = @()
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'bob'
                ChangedPaths = @([pscustomobject]@{ Path = 'src/B.cs'; Action = 'M'; CopyFromPath = $null; CopyFromRev = $null })
                ChangedPathsFiltered = @()
            }
        )
        $plan = New-CommitDiffPrefetchPlan -Commits $commits -CacheDir '.cache' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @() -IncludeExtensions @('cs') -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @()
        $plan.RevToAuthor[1] | Should -Be 'alice'
        $plan.RevToAuthor[2] | Should -Be 'bob'
        $plan.PrefetchItems.Count | Should -Be 1
    }
}

Describe 'Set-RenamePairDiffStatCorrection' {
    It 'overwrites new path stats and clears old path stats' {
        $commit = [pscustomobject]@{
            FileDiffStats = @{
                'src/Old.cs' = [pscustomobject]@{
                    AddedLines = 100
                    DeletedLines = 200
                    Hunks = @([pscustomobject]@{ OldStart = 1; OldCount = 1; NewStart = 1; NewCount = 1 })
                    IsBinary = $false
                    AddedLineHashes = @('h1', 'h2')
                    DeletedLineHashes = @('h3')
                }
                'src/New.cs' = [pscustomobject]@{
                    AddedLines = 300
                    DeletedLines = 400
                    Hunks = @([pscustomobject]@{ OldStart = 2; OldCount = 2; NewStart = 2; NewCount = 2 })
                    IsBinary = $false
                    AddedLineHashes = @('h4')
                    DeletedLineHashes = @('h5', 'h6')
                }
            }
        }
        $realStat = [pscustomobject]@{
            AddedLines = 5
            DeletedLines = 3
            Hunks = @([pscustomobject]@{ OldStart = 10; OldCount = 3; NewStart = 10; NewCount = 5 })
            IsBinary = $false
            AddedLineHashes = @('r1')
            DeletedLineHashes = @('r2')
        }

        Set-RenamePairDiffStatCorrection -Commit $commit -OldPath 'src/Old.cs' -NewPath 'src/New.cs' -RealStat $realStat

        $commit.FileDiffStats['src/New.cs'].AddedLines | Should -Be 5
        $commit.FileDiffStats['src/New.cs'].DeletedLines | Should -Be 3
        $commit.FileDiffStats['src/Old.cs'].AddedLines | Should -Be 0
        $commit.FileDiffStats['src/Old.cs'].DeletedLines | Should -Be 0
    }
}
