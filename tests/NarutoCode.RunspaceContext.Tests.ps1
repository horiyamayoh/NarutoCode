<#
.SYNOPSIS
Pipeline runtime / gateway 検証。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
}

Describe 'Pipeline runtime' {
    It 'creates runtime with shared parallel executor and memory governor' {
        $runtime = New-PipelineRuntime -Context $script:TestContext -Parallel 4

        $runtime | Should -Not -BeNullOrEmpty
        $runtime.Parallel | Should -Be 4
        $runtime.ParallelExecutor | Should -Not -BeNullOrEmpty
        @($runtime.ParallelFunctionCatalog).Count | Should -BeGreaterThan 0
        $runtime.MemoryGovernor | Should -Not -BeNullOrEmpty
        $runtime.StageResults.Count | Should -Be 0
        $runtime.StageDurations.Count | Should -Be 0
        $script:TestContext.Runtime.MemoryGovernor | Should -Be $runtime.MemoryGovernor

        $result = @(Invoke-ParallelWork -InputItems @(1, 2) -WorkerScript {
                param($Item, $Index)
                [void]$Index
                return ([int]$Item * 2)
            } -MaxParallel 2 -Context $script:TestContext -ErrorContext 'runtime lazy executor test')

        $result | Should -Be @(2, 4)
        $runtime.ParallelExecutor | Should -Not -BeNullOrEmpty
        @($runtime.ParallelFunctionCatalog).Count | Should -BeGreaterThan 0
    }
}

Describe 'Pipeline runtime disposal' {
    It 'clears runtime references without shared executor state' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 3
        [void](Invoke-ParallelWork -InputItems @(1, 2, 3) -WorkerScript {
                param($Item, $Index)
                [void]$Index
                return [int]$Item
            } -MaxParallel 2 -Context $context -ErrorContext 'runtime dispose test')
        $gateway = Get-ContextSvnGatewayState -Context $context
        $event = New-Object System.Threading.ManualResetEventSlim($false)
        $gateway.InFlightCommands['test'] = [pscustomobject]@{
            Event = $event
            Output = $null
            Error = $null
        }
        $gateway.CommandCache['k'] = 'v'

        Dispose-PipelineRuntime -Context $context -Runtime $runtime

        $runtime.ParallelExecutor | Should -BeNullOrEmpty
        $runtime.ParallelSemaphore | Should -BeNullOrEmpty
        $context.Runtime.PipelineRuntime | Should -BeNullOrEmpty
        $context.Runtime.MemoryGovernor | Should -BeNullOrEmpty
        $context.Runtime.SvnGateway | Should -BeNullOrEmpty
    }
}

Describe 'Svn gateway command key normalization' {
    It 'keeps positional argument case differences as different keys' {
        $argsUpper = @('diff', '-c', '10', 'https://example.invalid/svn/Repo/Trunk')
        $argsLower = @('diff', '-c', '10', 'https://example.invalid/svn/repo/trunk')

        $keyUpper = Get-SvnGatewayCommandKey -Arguments $argsUpper
        $keyLower = Get-SvnGatewayCommandKey -Arguments $argsLower

        $keyUpper | Should -Not -BeExactly $keyLower
    }

    It 'normalizes option name case while preserving option values' {
        $argsA = @('log', '--XML', '-R', '10:20', 'https://example.invalid/svn/Repo/Trunk')
        $argsB = @('log', '--xml', '-r', '10:20', 'https://example.invalid/svn/Repo/Trunk')

        $keyA = Get-SvnGatewayCommandKey -Arguments $argsA
        $keyB = Get-SvnGatewayCommandKey -Arguments $argsB

        $keyA | Should -BeExactly $keyB
    }

    It 'preserves attached short option value case' {
        $argsA = @('propget', '-RHead')
        $argsB = @('propget', '-rhead')

        $keyA = Get-SvnGatewayCommandKey -Arguments $argsA
        $keyB = Get-SvnGatewayCommandKey -Arguments $argsB

        $keyA | Should -Not -BeExactly $keyB
    }

    It 'keeps positional argument order in key' {
        $argsA = @('diff', 'https://example.invalid/svn/Repo/src/Old.cs@9', 'https://example.invalid/svn/Repo/src/New.cs@10')
        $argsB = @('diff', 'https://example.invalid/svn/Repo/src/New.cs@10', 'https://example.invalid/svn/Repo/src/Old.cs@9')

        $keyA = Get-SvnGatewayCommandKey -Arguments $argsA
        $keyB = Get-SvnGatewayCommandKey -Arguments $argsB

        $keyA | Should -Not -BeExactly $keyB
    }
}

Describe 'Svn gateway in-flight dedup' {
    BeforeEach {
        $script:origInvokeSvnCommandCore = (Get-Item function:Invoke-SvnCommandCore).ScriptBlock
        Set-Item -Path function:Invoke-SvnCommandCore -Value {
            param(
                [hashtable]$Context,
                [string[]]$Arguments,
                [string]$ErrorContext
            )
            [void]$Context
            [void]$Arguments
            [void]$ErrorContext
            Start-Sleep -Milliseconds 120
            return 'gateway-output'
        }
    }

    AfterEach {
        Set-Item -Path function:Invoke-SvnCommandCore -Value $script:origInvokeSvnCommandCore
    }

    It 'executes source command once for concurrent identical requests' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $items = @(
            [pscustomobject]@{
                Context = $context
            },
            [pscustomobject]@{
                Context = $context
            }
        )
        $results = @(Invoke-ParallelWork -InputItems $items -WorkerScript {
                param($Item, $Index)
                [void]$Index
                return (Invoke-SvnGatewayCommand -Context $Item.Context -Arguments @('log', '--xml', 'https://example.invalid/svn/Repo/Trunk') -ErrorContext 'gateway concurrent test')
            } -MaxParallel 2 -RequiredFunctions @(
                'Invoke-SvnGatewayCommand',
                'Get-ContextSvnGatewayState',
                'Get-SvnGatewayCommandKey',
                'Invoke-WithContextLock',
                'Get-ContextSyncRoot',
                'Invoke-SvnCommandCore',
                'Throw-NarutoError'
            ) -ErrorContext 'gateway in-flight dedup test')

        $results[0] | Should -Be 'gateway-output'
        $results[1] | Should -Be 'gateway-output'
        [int]$context.Runtime.SvnGateway.SourceCommandCount | Should -Be 1
    }
}

Describe 'Svn gateway command cache budget' {
    BeforeEach {
        $script:origInvokeSvnCommandCoreBudget = (Get-Item function:Invoke-SvnCommandCore).ScriptBlock
        $script:gatewayBudgetExecutionCount = 0
        Set-Item -Path function:Invoke-SvnCommandCore -Value {
            param(
                [hashtable]$Context,
                [string[]]$Arguments,
                [string]$ErrorContext
            )
            [void]$Context
            [void]$ErrorContext
            $script:gatewayBudgetExecutionCount++
            return ('gateway-budget:' + ($Arguments -join ' '))
        }
    }

    AfterEach {
        Set-Item -Path function:Invoke-SvnCommandCore -Value $script:origInvokeSvnCommandCoreBudget
    }

    It 'does not grow command cache beyond configured max entries' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $context.Constants.SvnGatewayCommandCacheMaxEntries = 1

        $first = Invoke-SvnGatewayCommand -Context $context -Arguments @('log', '--xml', 'https://example.invalid/svn/repo/trunk/A.cs') -ErrorContext 'gateway cache budget test'
        $second = Invoke-SvnGatewayCommand -Context $context -Arguments @('log', '--xml', 'https://example.invalid/svn/repo/trunk/B.cs') -ErrorContext 'gateway cache budget test'
        $third = Invoke-SvnGatewayCommand -Context $context -Arguments @('log', '--xml', 'https://example.invalid/svn/repo/trunk/B.cs') -ErrorContext 'gateway cache budget test'

        $gateway = Get-ContextSvnGatewayState -Context $context

        $first | Should -Not -BeNullOrEmpty
        $second | Should -Be $third
        [int]$gateway.SourceCommandCount | Should -Be 3
        [int]$gateway.CommandCache.Count | Should -Be 1
        [int]$gateway.CommandCacheInsertSkippedCount | Should -BeGreaterOrEqual 2
    }

    It 'stops command cache insertions during hard memory pressure' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $context.Runtime.MemoryGovernor = @{
            CurrentLevel = 'Hard'
        }

        $resultA = Invoke-SvnGatewayCommand -Context $context -Arguments @('log', '--xml', 'https://example.invalid/svn/repo/trunk/C.cs') -ErrorContext 'gateway hard pressure test'
        $resultB = Invoke-SvnGatewayCommand -Context $context -Arguments @('log', '--xml', 'https://example.invalid/svn/repo/trunk/C.cs') -ErrorContext 'gateway hard pressure test'

        $gateway = Get-ContextSvnGatewayState -Context $context

        $resultA | Should -Be $resultB
        [int]$gateway.SourceCommandCount | Should -Be 2
        [int]$gateway.CommandCache.Count | Should -Be 0
        [int]$gateway.CommandCacheInsertSkippedCount | Should -BeGreaterOrEqual 2
    }
}

Describe 'Pipeline DAG guard' {
    It 'throws INTERNAL_DAG_CYCLE_DETECTED on cyclic dependencies' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 2
        $nodes = @(
            [pscustomobject]@{
                Id = 'a'
                DependsOn = @('b')
                AllowParallel = $false
                Action = {
                    return 'a'
                }
            },
            [pscustomobject]@{
                Id = 'b'
                DependsOn = @('a')
                AllowParallel = $false
                Action = {
                    return 'b'
                }
            }
        )

        $caught = $null
        try
        {
            [void](Invoke-PipelineDag -Context $context -Runtime $runtime -Nodes $nodes)
        }
        catch
        {
            $caught = $_.Exception
        }

        $caught | Should -Not -BeNullOrEmpty
        [string]$caught.Data['ErrorCode'] | Should -Be 'INTERNAL_DAG_CYCLE_DETECTED'
    }

    It 'accepts coarse step6/step7 graph with step5_cleanup dependency' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 4
        $nodes = @(
            [pscustomobject]@{
                Id = 'step4_file'
                DependsOn = @()
                AllowParallel = $false
                Action = { return @() }
            },
            [pscustomobject]@{
                Id = 'step5_cleanup'
                DependsOn = @('step4_file')
                AllowParallel = $false
                Action = { return $null }
            },
            [pscustomobject]@{
                Id = 'step6_csv'
                DependsOn = @('step4_file', 'step5_cleanup')
                AllowParallel = $true
                Action = { return 'csv' }
            },
            [pscustomobject]@{
                Id = 'step7_visual'
                DependsOn = @('step4_file', 'step5_cleanup')
                AllowParallel = $true
                Action = { return 'visual' }
            },
            [pscustomobject]@{
                Id = 'step8_meta'
                DependsOn = @('step4_file', 'step5_cleanup', 'step6_csv', 'step7_visual')
                AllowParallel = $false
                Action = { return 'meta' }
            }
        )

        $result = Invoke-PipelineDag -Context $context -Runtime $runtime -Nodes $nodes

        $result['step6_csv'] | Should -Be 'csv'
        $result['step7_visual'] | Should -Be 'visual'
        $result['step8_meta'] | Should -Be 'meta'
    }
}

Describe 'Pipeline DAG deterministic merge order' {
    It 'keeps deterministic stage merge order for step6_csv and step7_visual' {
        $orders = New-Object 'System.Collections.Generic.List[string]'
        for ($run = 0
            $run -lt 5
            $run++)
        {
            $context = New-NarutoContext -SvnExecutable 'svn'
            $context = Initialize-StrictModeContext -Context $context
            $runtime = New-PipelineRuntime -Context $context -Parallel 4
            $nodes = @(
                [pscustomobject]@{
                    Id = 'step_base'
                    DependsOn = @()
                    AllowParallel = $false
                    Action = {
                        return 'base'
                    }
                },
                [pscustomobject]@{
                    Id = 'step6_csv'
                    DependsOn = @('step_base')
                    AllowParallel = $true
                    Action = {
                        Start-Sleep -Milliseconds 120
                        return 'csv'
                    }
                },
                [pscustomobject]@{
                    Id = 'step7_visual'
                    DependsOn = @('step_base')
                    AllowParallel = $true
                    Action = {
                        Start-Sleep -Milliseconds 10
                        return 'visual'
                    }
                }
            )
            $stageResults = Invoke-PipelineDag -Context $context -Runtime $runtime -Nodes $nodes
            $stageResults['step6_csv'] | Should -Be 'csv'
            $stageResults['step7_visual'] | Should -Be 'visual'
            [void]$orders.Add((@($runtime.StageDurations.Keys) -join ','))
        }

        @($orders | Select-Object -Unique).Count | Should -Be 1
        $orders[0] | Should -Be 'step_base,step6_csv,step7_visual'
    }
}

Describe 'Pipeline post strict cleanup stage' {
    It 'releases step3 result and strict caches while preserving commit count' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 4
        $runtime.StageResults['step3_diff'] = [pscustomobject]@{
            Commits = @(
                [pscustomobject]@{ Revision = 1 },
                [pscustomobject]@{ Revision = 2 },
                [pscustomobject]@{ Revision = 3 }
            )
        }
        $context.Caches.SvnBlameSummaryMemoryCache['k1'] = [pscustomobject]@{ X = 1 }
        $context.Caches.SvnBlameLineMemoryCache['k2'] = [pscustomobject]@{ X = 1 }
        $gateway = Get-ContextSvnGatewayState -Context $context
        $gateway.CommandCache['cmd'] = 'payload'

        $result = Invoke-PipelinePostStrictCleanupStage -Context $context -Runtime $runtime

        [int]$result.CommitCount | Should -Be 3
        [int]$runtime.DerivedMeta.CommitCount | Should -Be 3
        $runtime.StageResults.ContainsKey('step3_diff') | Should -BeFalse
        $context.Caches.SvnBlameSummaryMemoryCache.Count | Should -Be 0
        $context.Caches.SvnBlameLineMemoryCache.Count | Should -Be 0
        $gateway.CommandCache.Count | Should -Be 0
    }
}

Describe 'Memory governor pressure streak' {
    It 'triggers emergency purge after 3 consecutive hard observations at P=1' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 4
        $governor = $runtime.MemoryGovernor
        $governor.CurrentParallel = 1
        $governor.LowestParallel = 1
        $governor.SoftLimitBytes = 1L
        $governor.HardLimitBytes = 1L
        $baselinePurgeCount = [int]$governor.CachePurgeCount

        [void](Watch-MemoryGovernor -Context $context -Reason 'hard-1')
        [void](Watch-MemoryGovernor -Context $context -Reason 'hard-2')
        [void](Watch-MemoryGovernor -Context $context -Reason 'hard-3')

        [string]$governor.CurrentLevel | Should -Be 'Hard'
        [int]$governor.HardStreak | Should -BeGreaterOrEqual 3
        [int]$governor.CurrentParallel | Should -Be 1
        [int]$governor.CachePurgeCount | Should -BeGreaterThan $baselinePurgeCount
    }
}
