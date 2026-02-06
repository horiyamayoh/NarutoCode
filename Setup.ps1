<#
.SYNOPSIS
NarutoCode 開発環境のセットアップスクリプト。

.DESCRIPTION
RequiredModules.psd1 に定義されたモジュールを指定バージョンでインストールします。
新しい開発環境で最初に1回実行してください。

.PARAMETER Scope
インストールスコープ。既定: CurrentUser
AllUsers を指定する場合は管理者権限が必要です。

.EXAMPLE
.\Setup.ps1

.EXAMPLE
.\Setup.ps1 -Scope AllUsers
#>
[CmdletBinding()]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '=== NarutoCode Development Setup ===' -ForegroundColor Cyan
Write-Host ''

# RequiredModules.psd1 を読み込む
$reqFile = Join-Path $PSScriptRoot 'RequiredModules.psd1'
if (-not (Test-Path $reqFile))
{
    Write-Error "RequiredModules.psd1 not found: $reqFile"
    exit 1
}

$requirements = Import-PowerShellDataFile -Path $reqFile

foreach ($mod in $requirements.Modules)
{
    $name    = $mod.Name
    $version = $mod.RequiredVersion
    $desc    = $mod.Description

    Write-Host "Checking $name $version ($desc) ..." -NoNewline

    $installed = Get-Module $name -ListAvailable |
        Where-Object { $_.Version -eq $version }

    if ($installed)
    {
        Write-Host ' OK (already installed)' -ForegroundColor Green
    }
    else
    {
        Write-Host ' Installing...' -ForegroundColor Yellow -NoNewline
        Install-Module -Name $name `
            -RequiredVersion $version `
            -Scope $Scope `
            -Force `
            -SkipPublisherCheck `
            -AllowClobber
        Write-Host ' Done' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== Setup Complete ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Installed modules:' -ForegroundColor White

foreach ($mod in $requirements.Modules)
{
    $info = Get-Module $mod.Name -ListAvailable |
        Where-Object { $_.Version -eq $mod.RequiredVersion } |
        Select-Object -First 1
    if ($info)
    {
        Write-Host "  $($info.Name) v$($info.Version)" -ForegroundColor Green
    }
    else
    {
        Write-Host "  $($mod.Name) v$($mod.RequiredVersion) - NOT FOUND" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host '  .\RunTests.ps1          # Lint + Test'
Write-Host '  .\RunTests.ps1 -LintOnly  # Lint only'
Write-Host ''
