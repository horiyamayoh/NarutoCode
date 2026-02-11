<#
.SYNOPSIS
Runspace 並列実行時の $script:NarutoContext 伝搬テスト。
並列ワーカー内で $script:NarutoContext を参照する関数が正しく動作することを検証する。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
}

Describe 'Runspace $script:NarutoContext injection' {
    Context 'Invoke-ParallelWork sets $script:NarutoContext in Runspace' {
        It 'worker can access $script:NarutoContext when NarutoContext is injected via SessionVariables' {
            $worker = {
                param($Item, $Index)
                [void]$Index
                # $script:NarutoContext が invokeScript で設定されていることを確認する
                if ($null -eq $script:NarutoContext)
                {
                    throw '$script:NarutoContext is null in Runspace'
                }
                return [pscustomobject]@{
                    HasContext = ($null -ne $script:NarutoContext)
                    HasRuntime = ($null -ne $script:NarutoContext.Runtime)
                    SvnExecutable = [string]$script:NarutoContext.Runtime.SvnExecutable
                }
            }
            $results = @(Invoke-ParallelWork -InputItems @('item1', 'item2') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @() -SessionVariables @{
                    NarutoContext = (Get-RunspaceNarutoContext -Context $script:NarutoContext)
                } -ErrorContext 'test context injection')

            $results.Count | Should -Be 2
            foreach ($r in $results)
            {
                $r.HasContext | Should -BeTrue
                $r.HasRuntime | Should -BeTrue
                $r.SvnExecutable | Should -Be 'svn'
            }
        }
    }

    Context 'Get-Sha1Hex null-safety' {
        It 'works when Context is null' {
            $result = Get-Sha1Hex -Context $null -Text 'hello'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'works when Context.Caches is null' {
            $emptyCtx = @{
                Caches = $null
            }
            $result = Get-Sha1Hex -Context $emptyCtx -Text 'hello'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'works with valid Context and SharedSha1 null' {
            $ctx = @{
                Caches = @{
                    SharedSha1 = $null
                }
            }
            $result = Get-Sha1Hex -Context $ctx -Text 'hello'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'returns consistent hash regardless of Context presence' {
            $withCtx = Get-Sha1Hex -Context $script:NarutoContext -Text 'test-string'
            $withNull = Get-Sha1Hex -Context $null -Text 'test-string'
            $withCtx | Should -Be $withNull
        }
    }

    Context 'Get-PathCacheHash with Context parameter' {
        It 'works with explicit Context' {
            $result = Get-PathCacheHash -Context $script:NarutoContext -FilePath '/src/main.cs'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'works with null Context' {
            $result = Get-PathCacheHash -Context $null -FilePath '/src/main.cs'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'returns consistent hash regardless of Context' {
            $a = Get-PathCacheHash -Context $script:NarutoContext -FilePath '/src/main.cs'
            $b = Get-PathCacheHash -Context $null -FilePath '/src/main.cs'
            $a | Should -Be $b
        }
    }

    Context 'ConvertTo-LineHash with Context parameter' {
        It 'works with explicit Context' {
            $result = ConvertTo-LineHash -Context $script:NarutoContext -FilePath '/src/main.cs' -Content 'int x = 1;'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'works with null Context' {
            $result = ConvertTo-LineHash -Context $null -FilePath '/src/main.cs' -Content 'int x = 1;'
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'returns consistent hash regardless of Context' {
            $a = ConvertTo-LineHash -Context $script:NarutoContext -FilePath '/src/main.cs' -Content 'hello world'
            $b = ConvertTo-LineHash -Context $null -FilePath '/src/main.cs' -Content 'hello world'
            $a | Should -Be $b
        }
    }

    Context 'ConvertTo-ContextHash with Context parameter' {
        It 'passes Context to Get-Sha1Hex' {
            $result = ConvertTo-ContextHash -Context $script:NarutoContext -FilePath '/src/main.cs' -ContextLines @('line1', 'line2', 'line3')
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }

        It 'works with null Context by using default K value' {
            # Context が null の場合 $K のデフォルト値解決が失敗するため、
            # 明示的に -K を渡す必要がある
            $result = ConvertTo-ContextHash -Context $null -FilePath '/src/main.cs' -ContextLines @('line1', 'line2') -K 3
            $result | Should -Not -BeNullOrEmpty
            $result.Length | Should -Be 40
        }
    }

    Context 'Invoke-ParallelWork with Get-Sha1Hex in Runspace' {
        It 'Get-Sha1Hex works inside parallel Runspace via $script:NarutoContext' {
            $worker = {
                param($Item, $Index)
                [void]$Index
                # Runspace 内で Get-Sha1Hex を呼ぶ。
                # $script:NarutoContext が設定されていなければデフォルト引数が null になり例外が発生する。
                $hash = Get-Sha1Hex -Text $Item
                return [pscustomobject]@{
                    Input = [string]$Item
                    Hash = [string]$hash
                }
            }
            $results = @(Invoke-ParallelWork -InputItems @('alpha', 'beta') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @('Get-Sha1Hex') -SessionVariables @{
                    NarutoContext = (Get-RunspaceNarutoContext -Context $script:NarutoContext)
                } -ErrorContext 'test sha1 in runspace')

            $results.Count | Should -Be 2
            $results[0].Hash.Length | Should -Be 40
            $results[1].Hash.Length | Should -Be 40
            # ハッシュの一貫性を検証
            $expected0 = Get-Sha1Hex -Context $script:NarutoContext -Text 'alpha'
            $expected1 = Get-Sha1Hex -Context $script:NarutoContext -Text 'beta'
            $results[0].Hash | Should -Be $expected0
            $results[1].Hash | Should -Be $expected1
        }

        It 'ConvertTo-LineHash works inside parallel Runspace' {
            $worker = {
                param($Item, $Index)
                [void]$Index
                return (ConvertTo-LineHash -FilePath $Item.Path -Content $Item.Content)
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
                    NarutoContext = (Get-RunspaceNarutoContext -Context $script:NarutoContext)
                } -ErrorContext 'test linehash in runspace')

            $results.Count | Should -Be 2
            foreach ($r in $results)
            {
                $r | Should -Not -BeNullOrEmpty
                $r.Length | Should -Be 40
            }
        }

        It 'Get-PathCacheHash works inside parallel Runspace' {
            $worker = {
                param($Item, $Index)
                [void]$Index
                return (Get-PathCacheHash -FilePath $Item)
            }
            $results = @(Invoke-ParallelWork -InputItems @('/src/main.cs', '/src/util.cs') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @(
                    'Get-PathCacheHash',
                    'Get-Sha1Hex',
                    'ConvertTo-PathKey'
                ) -SessionVariables @{
                    NarutoContext = (Get-RunspaceNarutoContext -Context $script:NarutoContext)
                } -ErrorContext 'test pathcachehash in runspace')

            $results.Count | Should -Be 2
            foreach ($r in $results)
            {
                $r | Should -Not -BeNullOrEmpty
                $r.Length | Should -Be 40
            }
        }
    }

    Context 'Invoke-ParallelWork without NarutoContext SessionVariable' {
        It 'Get-Sha1Hex still works with null $script:NarutoContext due to null-safety' {
            $worker = {
                param($Item, $Index)
                [void]$Index
                return (Get-Sha1Hex -Text $Item)
            }
            # NarutoContext を SessionVariables に渡さない場合でも
            # Get-Sha1Hex の null 安全化により例外が発生しない
            $results = @(Invoke-ParallelWork -InputItems @('test1') -WorkerScript $worker -MaxParallel 2 -RequiredFunctions @('Get-Sha1Hex') -SessionVariables @{} -ErrorContext 'test sha1 without context')

            $results.Count | Should -Be 1
            $results[0] | Should -Not -BeNullOrEmpty
            $results[0].Length | Should -Be 40
        }
    }
}
