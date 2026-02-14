<#
.SYNOPSIS
Base aggregation focused tests.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
    $script:Headers = Get-MetricHeader -Context $script:TestContext

    $script:BaseCommits = @(
        [pscustomobject]@{
            Revision = 1
            Author = 'alice'
            Date = [datetime]'2026-01-01'
            Message = 'fix #123'
            ChangedPathsFiltered = @(
                [pscustomobject]@{
                    Path = 'src/A.cs'
                    Action = 'M'
                },
                [pscustomobject]@{
                    Path = 'src/B.cs'
                    Action = 'A'
                }
            )
            FileDiffStats = @{
                'src/A.cs' = [pscustomobject]@{
                    AddedLines = 3
                    DeletedLines = 1
                    Hunks = @()
                    IsBinary = $false
                }
                'src/B.cs' = [pscustomobject]@{
                    AddedLines = 2
                    DeletedLines = 0
                    Hunks = @()
                    IsBinary = $false
                }
            }
            FilesChanged = @('src/A.cs', 'src/B.cs')
        },
        [pscustomobject]@{
            Revision = 2
            Author = 'bob'
            Date = [datetime]'2026-01-02'
            Message = 'merge branch'
            ChangedPathsFiltered = @([pscustomobject]@{
                    Path = 'src/A.cs'
                    Action = 'M'
                })
            FileDiffStats = @{
                'src/A.cs' = [pscustomobject]@{
                    AddedLines = 1
                    DeletedLines = 2
                    Hunks = @()
                    IsBinary = $false
                }
            }
            FilesChanged = @('src/A.cs')
        }
    )

    foreach ($commit in $script:BaseCommits)
    {
        Set-CommitDerivedMetric -Commit $commit
    }
}

Describe 'Base aggregation refactor' {
    It 'keeps committer file and co-change outputs stable for same input' {
        $committerRows = @(Get-CommitterMetric -Commits $script:BaseCommits)
        $fileRows = @(Get-FileMetric -Commits $script:BaseCommits)
        $coRows = @(Get-CoChangeMetric -Commits $script:BaseCommits -TopNCount 10)

        $committerAuthor = $script:Headers.Committer[0]
        $committerCommitCount = $script:Headers.Committer[1]
        $committerAdded = $script:Headers.Committer[5]
        $filePath = $script:Headers.File[0]
        $fileCommitCount = $script:Headers.File[1]
        $fileAuthorCount = $script:Headers.File[2]
        $couplingFileA = $script:Headers.Coupling[0]
        $couplingFileB = $script:Headers.Coupling[1]
        $couplingCount = $script:Headers.Coupling[2]

        $alice = $committerRows | Where-Object { $_.$committerAuthor -eq 'alice' }
        $fileA = $fileRows | Where-Object { $_.$filePath -eq 'src/A.cs' }

        $alice.$committerCommitCount | Should -Be 1
        $alice.$committerAdded | Should -Be 5
        $fileA.$fileCommitCount | Should -Be 2
        $fileA.$fileAuthorCount | Should -Be 2
        $coRows.Count | Should -Be 1
        $coRows[0].$couplingFileA | Should -Be 'src/A.cs'
        $coRows[0].$couplingFileB | Should -Be 'src/B.cs'
        $coRows[0].$couplingCount | Should -Be 1
    }

    It 'uses shared metric column definitions for headers' {
        $definitions = Get-MetricColumnDefinitions -Context $script:TestContext
        ($definitions.Committer -join '|') | Should -Be ($script:Headers.Committer -join '|')
        ($definitions.File -join '|') | Should -Be ($script:Headers.File -join '|')
        ($definitions.Commit -join '|') | Should -Be ($script:Headers.Commit -join '|')
        ($definitions.Coupling -join '|') | Should -Be ($script:Headers.Coupling -join '|')
    }

    It 'aligns metric headers and row properties' {
        $committerRows = @(Get-CommitterMetric -Commits $script:BaseCommits)
        $fileRows = @(Get-FileMetric -Commits $script:BaseCommits)
        $commitRows = @(New-CommitRowFromCommit -Commits $script:BaseCommits)
        $couplingRows = @(Get-CoChangeMetric -Commits $script:BaseCommits -TopNCount 10)

        foreach ($column in @($script:Headers.Committer))
        {
            $committerRows[0].PSObject.Properties.Name -contains $column | Should -BeTrue
        }
        foreach ($column in @($script:Headers.File))
        {
            $fileRows[0].PSObject.Properties.Name -contains $column | Should -BeTrue
        }
        foreach ($column in @($script:Headers.Commit))
        {
            $commitRows[0].PSObject.Properties.Name -contains $column | Should -BeTrue
        }
        foreach ($column in @($script:Headers.Coupling))
        {
            $couplingRows[0].PSObject.Properties.Name -contains $column | Should -BeTrue
        }
    }
}






