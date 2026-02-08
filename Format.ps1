<#
.SYNOPSIS
NarutoCode.ps1 に Invoke-Formatter を適用してインデント・スタイルを自動整形する。
#>
[CmdletBinding()]
param()

$scriptPath = Join-Path $PSScriptRoot 'NarutoCode.ps1'
$settingsPath = Join-Path $PSScriptRoot '.PSScriptAnalyzerSettings.psd1'

if (-not (Test-Path $scriptPath))
{
    Write-Error "スクリプトが見つかりません: $scriptPath"
    return
}
if (-not (Test-Path $settingsPath))
{
    Write-Error "設定ファイルが見つかりません: $settingsPath"
    return
}

Write-Host 'フォーマット適用中...' -ForegroundColor Cyan

$code = Get-Content -Path $scriptPath -Raw -Encoding UTF8
$formatted = Invoke-Formatter -ScriptDefinition $code -Settings $settingsPath

# BOM 付き UTF-8 で保存
[System.IO.File]::WriteAllText($scriptPath, $formatted, [System.Text.UTF8Encoding]::new($true))

Write-Host 'フォーマット完了。静的解析を実行します...' -ForegroundColor Cyan

$violations = Invoke-ScriptAnalyzer -Path $scriptPath -Settings $settingsPath
if ($violations)
{
    Write-Warning "違反が $($violations.Count) 件あります:"
    $violations | Format-Table -Property Severity, RuleName, Line, Message -AutoSize -Wrap
}
else
{
    Write-Host '違反なし (0 件)' -ForegroundColor Green
}
