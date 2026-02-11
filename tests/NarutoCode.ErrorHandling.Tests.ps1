<#
.SYNOPSIS
Pester tests for NarutoCode error handling contracts.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    Initialize-StrictModeContext
}

Describe 'NarutoResult constructors' {
    It 'creates success result' {
        $result = New-NarutoResultSuccess -Data 123 -Message 'ok' -ErrorCode 'TEST_OK' -Context @{ Name = 'value' }
        [bool]$result.IsSuccess | Should -BeTrue
        [string]$result.Status | Should -Be 'Success'
        [string]$result.ErrorCode | Should -Be 'TEST_OK'
        [string]$result.Message | Should -Be 'ok'
        [int]$result.Data | Should -Be 123
        [string]$result.Context.Name | Should -Be 'value'
    }

    It 'creates skipped result' {
        $result = New-NarutoResultSkipped -Data 'x' -Message 'skip' -ErrorCode 'TEST_SKIP' -Context @{ Reason = 'none' }
        [bool]$result.IsSuccess | Should -BeFalse
        [string]$result.Status | Should -Be 'Skipped'
        [string]$result.ErrorCode | Should -Be 'TEST_SKIP'
        [string]$result.Message | Should -Be 'skip'
        [string]$result.Data | Should -Be 'x'
        [string]$result.Context.Reason | Should -Be 'none'
    }

    It 'creates failure result' {
        $result = New-NarutoResultFailure -Data $null -Message 'failed' -ErrorCode 'TEST_FAIL' -Context @{ Scope = 'unit' }
        [bool]$result.IsSuccess | Should -BeFalse
        [string]$result.Status | Should -Be 'Failure'
        [string]$result.ErrorCode | Should -Be 'TEST_FAIL'
        [string]$result.Message | Should -Be 'failed'
        [string]$result.Context.Scope | Should -Be 'unit'
    }
}

Describe 'Throw-NarutoError' {
    It 'throws exception with ErrorCode Category and Context in Data' {
        $caught = $null
        try
        {
            Throw-NarutoError -Category 'SVN' -ErrorCode 'SVN_COMMAND_FAILED' -Message 'command failed' -Context @{ Revision = 10 }
        }
        catch
        {
            $caught = $_.Exception
        }

        $caught | Should -Not -BeNullOrEmpty
        [string]$caught.Message | Should -Be 'command failed'
        [string]$caught.Data['ErrorCode'] | Should -Be 'SVN_COMMAND_FAILED'
        [string]$caught.Data['Category'] | Should -Be 'SVN'
        $caught.Data['Context'] | Should -Not -BeNullOrEmpty
        [int]$caught.Data['Context'].Revision | Should -Be 10
    }
}

Describe 'Get-NarutoErrorInfo' {
    It 'extracts standardized fields from Exception' {
        $exception = $null
        try
        {
            Throw-NarutoError -Category 'OUTPUT' -ErrorCode 'OUTPUT_DIRECTORY_CREATE_FAILED' -Message 'cannot create directory' -Context @{ Path = 'x' }
        }
        catch
        {
            $exception = $_.Exception
        }

        $info = Get-NarutoErrorInfo -ErrorInput $exception
        [string]$info.ErrorCode | Should -Be 'OUTPUT_DIRECTORY_CREATE_FAILED'
        [string]$info.Category | Should -Be 'OUTPUT'
        [string]$info.Message | Should -Be 'cannot create directory'
        [string]$info.Context.Path | Should -Be 'x'
    }
}

Describe 'Resolve-NarutoExitCode' {
    It 'returns category specific exit code' {
        Resolve-NarutoExitCode -Category 'INPUT' | Should -Be 10
        Resolve-NarutoExitCode -Category 'ENV' | Should -Be 20
        Resolve-NarutoExitCode -Category 'SVN' | Should -Be 30
        Resolve-NarutoExitCode -Category 'PARSE' | Should -Be 40
        Resolve-NarutoExitCode -Category 'STRICT' | Should -Be 50
        Resolve-NarutoExitCode -Category 'OUTPUT' | Should -Be 60
        Resolve-NarutoExitCode -Category 'INTERNAL' | Should -Be 70
    }

    It 'falls back to INTERNAL exit code for unknown category' {
        Resolve-NarutoExitCode -Category 'UNKNOWN' | Should -Be 70
    }
}
