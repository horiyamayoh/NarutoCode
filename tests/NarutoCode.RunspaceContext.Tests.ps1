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
        $runtime.ParallelExecutor | Should -Not -BeNullOrEmpty
        @($runtime.ParallelFunctionCatalog).Count | Should -BeGreaterThan 0
        $runtime.RequestBroker | Should -Not -BeNullOrEmpty
        $runtime.MemoryGovernor | Should -Not -BeNullOrEmpty
        $runtime.StageResults.Count | Should -Be 0
        $runtime.StageDurations.Count | Should -Be 0
        $script:TestContext.Runtime.RequestBroker | Should -Be $runtime.RequestBroker
        $script:TestContext.Runtime.MemoryGovernor | Should -Be $runtime.MemoryGovernor
    }
}

Describe 'Pipeline runtime disposal' {
    It 'disposes executor and clears runtime references' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 3
        $executor = $runtime.ParallelExecutor
        $gateway = Get-ContextSvnGatewayState -Context $context
        $event = New-Object System.Threading.ManualResetEventSlim($false)
        $gateway.InFlightCommands['test'] = [pscustomobject]@{
            Event = $event
            Output = $null
            Error = $null
        }
        $gateway.CommandCache['k'] = 'v'
        $runtime.RequestBroker.Requests['rk'] = [pscustomobject]@{
            Key = 'rk'
        }
        $runtime.RequestBroker.Results['rk'] = [pscustomobject]@{
            Success = $true
        }
        [void]$runtime.RequestBroker.RegistrationOrder.Add('rk')

        Dispose-PipelineRuntime -Context $context -Runtime $runtime

        [bool]$executor.Disposed | Should -BeTrue
        $runtime.ParallelSemaphore | Should -BeNullOrEmpty
        $context.Runtime.PipelineRuntime | Should -BeNullOrEmpty
        $context.Runtime.RequestBroker | Should -BeNullOrEmpty
        $context.Runtime.MemoryGovernor | Should -BeNullOrEmpty
        $context.Runtime.SvnGateway | Should -BeNullOrEmpty
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
        $context.Runtime.DedupExecCount = 0

        $resolver = {
            param($Context, $Request)
            [void]$Request
            $Context.Runtime.DedupExecCount++
            return [pscustomobject]@{
                Value = 42
            }
        }

        $first = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '20' -Flags @('diff', '--internal-diff') -Resolver $resolver
        $second = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '20' -Flags @('--internal-diff', 'diff') -Resolver $resolver
        $results = Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($first, $second)

        [int]$context.Runtime.DedupExecCount | Should -Be 1
        $results.ContainsKey($first) | Should -BeTrue
        [bool]$results[$first].Success | Should -BeTrue
        [int]$results[$first].Payload.Value | Should -Be 42
    }
}

Describe 'Request broker consume retrieval' {
    It 'removes consumed request/result entries from broker' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 2
        $broker = $runtime.RequestBroker

        $requestKey = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '10' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'ok'
        }
        [void](Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($requestKey))

        $broker.Results.ContainsKey($requestKey) | Should -BeTrue
        $broker.Requests.ContainsKey($requestKey) | Should -BeTrue
        $broker.RegistrationOrder.Count | Should -Be 1

        $consumed = Get-SvnRequestResult -Broker $broker -RequestKey $requestKey -Consume -ThrowIfMissing

        [bool]$consumed.Success | Should -BeTrue
        [string]$consumed.Payload | Should -Be 'ok'
        $broker.Results.ContainsKey($requestKey) | Should -BeFalse
        $broker.Requests.ContainsKey($requestKey) | Should -BeFalse
        $broker.RegistrationOrder.Count | Should -Be 0
    }

    It 'purges unconsumed request/result entries by key set' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 2
        $broker = $runtime.RequestBroker

        $keepKey = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '11' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'keep'
        }
        $purgeKey = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '12' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'purge'
        }
        [void](Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($keepKey, $purgeKey))

        Remove-SvnRequestEntry -Broker $broker -RequestKeys @($purgeKey)

        $broker.Results.ContainsKey($purgeKey) | Should -BeFalse
        $broker.Requests.ContainsKey($purgeKey) | Should -BeFalse
        $broker.RegistrationOrder.Contains($purgeKey) | Should -BeFalse
        $broker.Results.ContainsKey($keepKey) | Should -BeTrue
        $broker.Requests.ContainsKey($keepKey) | Should -BeTrue
        $broker.RegistrationOrder.Contains($keepKey) | Should -BeTrue
    }
}

Describe 'Request resolver contract' {
    It 'rejects resolver that captures free variables' {
        $broker = New-RequestBroker
        $captured = 42
        $caught = $null
        try
        {
            [void](Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '10' -Flags @('diff') -Resolver {
                    param($Context, $Request)
                    [void]$Context
                    [void]$Request
                    return $captured
                })
        }
        catch
        {
            $caught = $_.Exception
        }

        $caught | Should -Not -BeNullOrEmpty
        [string]$caught.Data['ErrorCode'] | Should -Be 'INPUT_REQUEST_RESOLVER_FREE_VARIABLE_NOT_ALLOWED'
    }

    It 'accepts resolver that uses only declared locals and metadata' {
        $broker = New-RequestBroker

        $key = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '10' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            $revision = [int]$Request.Metadata.Revision
            return $revision
        } -Metadata @{
            Revision = 10
        }

        [string]$key | Should -Not -BeNullOrEmpty
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

Describe 'Request broker streaming resolve' {
    It 'consumes results on resolve and invokes callback' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 4
        $broker = $runtime.RequestBroker
        $callbacks = New-Object 'System.Collections.Generic.List[string]'

        $keyA = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '21' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'A'
        }
        $keyB = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '22' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'B'
        }

        [void](Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($keyA, $keyB) -ConsumeOnResolve -OnResolved {
                param($Broker, $RequestKey, $Request, $Result, $ConsumedResult)
                [void]$Broker
                [void]$Request
                [void]$Result
                [void]$callbacks.Add(([string]$RequestKey + ':' + [string]$ConsumedResult.Payload))
            })

        $broker.Results.Count | Should -Be 0
        $broker.Requests.Count | Should -Be 0
        $broker.RegistrationOrder.Count | Should -Be 0
        @($callbacks | Sort-Object) | Should -Be @(
            ($keyA + ':A'),
            ($keyB + ':B')
        )
    }

    It 'wraps callback failure with INTERNAL_REQUEST_RESOLVE_CALLBACK_FAILED' {
        $context = New-NarutoContext -SvnExecutable 'svn'
        $context = Initialize-StrictModeContext -Context $context
        $runtime = New-PipelineRuntime -Context $context -Parallel 2
        $broker = $runtime.RequestBroker
        $requestKey = Register-SvnRequest -Broker $broker -Operation 'diff' -Path 'https://example.invalid/svn/repo/trunk' -Revision '' -RevisionRange '31' -Flags @('diff') -Resolver {
            param($Context, $Request)
            [void]$Context
            [void]$Request
            return 'ok'
        }

        $caught = $null
        try
        {
            [void](Wait-SvnRequest -Context $context -Broker $broker -RequestKeys @($requestKey) -ConsumeOnResolve -OnResolved {
                    param($Broker, $RequestKey, $Request, $Result, $ConsumedResult)
                    [void]$Broker
                    [void]$RequestKey
                    [void]$Request
                    [void]$Result
                    [void]$ConsumedResult
                    throw 'callback failure'
                })
        }
        catch
        {
            $caught = $_.Exception
        }

        $caught | Should -Not -BeNullOrEmpty
        [string]$caught.Data['ErrorCode'] | Should -Be 'INTERNAL_REQUEST_RESOLVE_CALLBACK_FAILED'
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
