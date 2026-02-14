<#
.SYNOPSIS
Pipeline runtime / request broker 検証。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
}

Describe 'Pipeline runtime' {
    It 'creates runtime with request broker and stage registries' {
        $runtime = New-PipelineRuntime -Context $script:TestContext -Parallel 4

        $runtime | Should -Not -BeNullOrEmpty
        $runtime.Parallel | Should -Be 4
        $runtime.RequestBroker | Should -Not -BeNullOrEmpty
        $runtime.StageResults.Count | Should -Be 0
        $runtime.StageDurations.Count | Should -Be 0
        $script:TestContext.Runtime.RequestBroker | Should -Be $runtime.RequestBroker
    }
}

Describe 'Request broker dedup' {
    It 'returns same key for duplicate (op, rev, path) registration' {
        $broker = New-RequestBroker
        $resolver = {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'ok'
        }

        $keyA = Register-SvnRequest -Broker $broker -Operation 'blame_line' -Path 'trunk/src/a.cs' -Revision '10' -RevisionRange '' -Flags @('--xml') -Resolver $resolver
        $keyB = Register-SvnRequest -Broker $broker -Operation 'blame_line' -Path 'trunk/src/a.cs' -Revision '10' -RevisionRange '' -Flags @('--xml') -Resolver $resolver

        $keyA | Should -Be $keyB
        $broker.Requests.Count | Should -Be 1
        $broker.RegistrationOrder.Count | Should -Be 1
    }

    It 'executes deduplicated request once and shares result' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 8
        $broker = $runtime.RequestBroker
        $script:execCount = 0

        $resolver = {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            $script:execCount++
            return [pscustomobject]@{
                Value = 42
            }
        }

        $first = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '20' -Flags @('diff', '--internal-diff') -Resolver $resolver
        $second = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '20' -Flags @('--internal-diff', 'diff') -Resolver $resolver
        $results = Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($first, $second)

        $script:execCount | Should -Be 1
        $results.ContainsKey($first) | Should -BeTrue
        [bool]$results[$first].Success | Should -BeTrue
        [int]$results[$first].Payload.Value | Should -Be 42
    }
}
