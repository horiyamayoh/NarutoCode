<#
.SYNOPSIS
Runspace 並列実行時の明示 Context 受け渡しを検証する。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
}

Describe 'Get-RunspaceNarutoContext' {
    It 'creates independent context snapshot for runspace use' {
        $runspaceContext = Get-RunspaceNarutoContext -Context $script:TestContext

        $runspaceContext | Should -Not -BeNullOrEmpty
        $runspaceContext.Runtime.SvnExecutable | Should -Be $script:TestContext.Runtime.SvnExecutable
        $runspaceContext.Caches.SharedSha1 | Should -BeNullOrEmpty
        $runspaceContext.Constants.ContextHashNeighborK | Should -Be $script:TestContext.Constants.ContextHashNeighborK
    }
}

Describe 'Hash helpers with explicit Context' {
    It 'Get-Sha1Hex returns deterministic 40-char hash' {
        $a = Get-Sha1Hex -Context $script:TestContext -Text 'alpha'
        $b = Get-Sha1Hex -Context $script:TestContext -Text 'alpha'

        $a | Should -Be $b
        $a.Length | Should -Be 40
    }

    It 'Get-PathCacheHash and ConvertTo-LineHash work with explicit Context' {
        $pathHash = Get-PathCacheHash -Context $script:TestContext -FilePath '/src/main.cs'
        $lineHash = ConvertTo-LineHash -Context $script:TestContext -FilePath '/src/main.cs' -Content 'int x = 1;'

        $pathHash.Length | Should -Be 40
        $lineHash.Length | Should -Be 40
    }
}

Describe 'Invoke-ParallelWork explicit Context DI' {
    It 'worker can call Context-required functions via $Context variable' {
        $worker = {
            param($Item, $Index)
            [void]$Index
            return [pscustomobject]@{
                Input = [string]$Item
                Hash = (Get-Sha1Hex -Context $Context -Text $Item)
            }
        }

        $results = @(Invoke-ParallelWork -InputItems @('alpha', 'beta') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @('Get-Sha1Hex') -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $script:TestContext)
            } -ErrorContext 'runspace explicit context')

        $results.Count | Should -Be 2
        $results[0].Hash.Length | Should -Be 40
        $results[1].Hash.Length | Should -Be 40
    }

    It 'PSDefaultParameterValues safety net auto-fills Context for worker that omits explicit -Context' {
        $worker = {
            param($Item, $Index)
            [void]$Index
            # -Context を明示的に渡していないが、$PSDefaultParameterValues が
            # Runspace ISS に注入されているため Mandatory プロンプトでハングしない
            return (Get-Sha1Hex -Text $Item)
        }

        $results = @(Invoke-ParallelWork -InputItems @('safety-net') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @('Get-Sha1Hex') -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $script:TestContext)
            } -ErrorContext 'runspace default param safety net')

        $results.Count | Should -Be 1
        $results[0].Length | Should -Be 40
    }

    It 'throws when worker passes $null as -Context argument' {
        $worker = {
            param($Item, $Index)
            [void]$Index
            return (Get-Sha1Hex -Context $null -Text $Item)
        }

        {
            $null = Invoke-ParallelWork -InputItems @('x') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @('Get-Sha1Hex') -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $script:TestContext)
            } -ErrorContext 'runspace null context'
        } | Should -Throw
    }

    It 'ConvertTo-LineHash works inside runspace with explicit Context' {
        $worker = {
            param($Item, $Index)
            [void]$Index
            return (ConvertTo-LineHash -Context $Context -FilePath $Item.Path -Content $Item.Content)
        }

        $items = @(
            [pscustomobject]@{ Path = '/src/a.cs'; Content = 'int x = 1;' },
            [pscustomobject]@{ Path = '/src/b.cs'; Content = 'return 0;' }
        )
        $results = @(Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @(
                'ConvertTo-LineHash',
                'Get-Sha1Hex',
                'ConvertTo-PathKey'
            ) -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $script:TestContext)
            } -ErrorContext 'runspace line hash')

        $results.Count | Should -Be 2
        foreach ($r in $results) {
            $r.Length | Should -Be 40
        }
    }
}


