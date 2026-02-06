<#
.SYNOPSIS
Run NarutoCode Pester tests and PSScriptAnalyzer lint.

.PARAMETER Output
Pester output level. Default: Detailed

.PARAMETER SkipLint
Skip PSScriptAnalyzer static analysis.

.PARAMETER LintOnly
Run only PSScriptAnalyzer without Pester tests.
#>
[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed',

    [switch]$SkipLint,

    [switch]$LintOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failCount = 0

# ============================================================
# PSScriptAnalyzer (Lint)
# ============================================================
if (-not $SkipLint) {
    $analyzerModule = Get-Module PSScriptAnalyzer -ListAvailable |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $analyzerModule) {
        Write-Warning 'PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Force'
        Write-Warning 'Skipping static analysis.'
    }
    else {
        Import-Module PSScriptAnalyzer -RequiredVersion $analyzerModule.Version -Force -ErrorAction SilentlyContinue

        Write-Host ''
        Write-Host '=== PSScriptAnalyzer ===' -ForegroundColor Cyan

        $settingsPath = Join-Path $PSScriptRoot '.PSScriptAnalyzerSettings.psd1'
        $scriptPath = Join-Path $PSScriptRoot 'NarutoCode.ps1'

        $analyzerParams = @{ Path = $scriptPath }
        if (Test-Path $settingsPath) {
            $analyzerParams['Settings'] = $settingsPath
        }

        $lintResults = Invoke-ScriptAnalyzer @analyzerParams

        if ($lintResults) {
            $lintResults | Format-Table -Property Severity, RuleName, Line, Message -AutoSize
            $lintErrors = @($lintResults | Where-Object { $_.Severity -eq 'Error' })
            $lintWarnings = @($lintResults | Where-Object { $_.Severity -eq 'Warning' })
            $lintInfo = @($lintResults | Where-Object { $_.Severity -eq 'Information' })
            Write-Host "Lint: $($lintErrors.Count) Error(s), $($lintWarnings.Count) Warning(s), $($lintInfo.Count) Info" -ForegroundColor Yellow
            $failCount += $lintErrors.Count
        }
        else {
            Write-Host 'Lint: No issues found.' -ForegroundColor Green
        }
        Write-Host ''
    }
}

if ($LintOnly) {
    exit $failCount
}

# ============================================================
# Pester Tests
# ============================================================
$pesterModule = Get-Module Pester -ListAvailable |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterModule) {
    Write-Error 'Pester 5.x is not installed. Run: Install-Module Pester -Force -SkipPublisherCheck'
    exit 1
}

Import-Module Pester -RequiredVersion $pesterModule.Version -Force

$testPath = Join-Path $PSScriptRoot 'tests'
$result = Invoke-Pester -Path $testPath -Output $Output -PassThru

$failCount += $result.FailedCount

exit $failCount
