<#
.SYNOPSIS
NarutoCode Phase 1 + Phase 2 implementation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Alias('Path')][string]$RepoUrl,
    [Parameter(Mandatory = $true)][Alias('FromRevision', 'Pre', 'Start', 'StartRevision', 'From')][int]$FromRev,
    [Parameter(Mandatory = $true)][Alias('ToRevision', 'Post', 'End', 'EndRevision', 'To')][int]$ToRev,
    [Alias('Name', 'User')][string]$Author,
    [string]$SvnExecutable = 'svn',
    [string]$OutDir,
    [string]$Username,
    [securestring]$Password,
    [switch]$NonInteractive,
    [switch]$TrustServerCert,
    [switch]$NoBlame,
    [ValidateRange(1, 128)][int]$Parallel = [Math]::Max(1, [Environment]::ProcessorCount),
    [string[]]$IncludePaths,
    [string[]]$ExcludePaths,
    [string[]]$IncludeExtensions,
    [string[]]$ExcludeExtensions,
    [switch]$EmitPlantUml,
    [ValidateRange(1, 5000)][int]$TopN = 50,
    [ValidateSet('UTF8', 'UTF8BOM', 'Unicode', 'ASCII')][string]$Encoding = 'UTF8',
    [switch]$IgnoreSpaceChange,
    [switch]$IgnoreAllSpace,
    [switch]$IgnoreEolStyle,
    [switch]$IncludeProperties,
    [switch]$ForceBinary,
    [switch]$NoProgress,
    [ValidateRange(0, 2)][int]$DeadDetailLevel = 0
)

# Suppress progress output when -NoProgress is specified
if ($NoProgress)
{
    $ProgressPreference = 'SilentlyContinue'
}

# region Utility
$script:StrictModeEnabled = $true
$script:ColDeadAdded = '消滅追加行数'
$script:ColSelfDead = '自己消滅行数'
$script:ColOtherDead = '被他者消滅行数'
$script:StrictBlameCacheHits = 0
$script:StrictBlameCacheMisses = 0

function Initialize-StrictModeContext
{
    $script:StrictModeEnabled = $true
    $script:StrictBlameCacheHits = 0
    $script:StrictBlameCacheMisses = 0
    $script:ColDeadAdded = '消滅追加行数'
    $script:ColSelfDead = '自己消滅行数'
    $script:ColOtherDead = '被他者消滅行数'
}
function ConvertTo-NormalizedExtension
{
    param([string[]]$Extensions)
    if (-not $Extensions)
    {
        return @()
    }
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $Extensions)
    {
        if ([string]::IsNullOrWhiteSpace($e))
        {
            continue
        }
        $x = $e.Trim()
        if ($x.StartsWith('.'))
        {
            $x = $x.Substring(1)
        }
        $x = $x.ToLowerInvariant()
        if ($x)
        {
            $null = $list.Add($x)
        }
    }
    return $list.ToArray() | Select-Object -Unique
}
function ConvertTo-NormalizedPatternList
{
    param([string[]]$Patterns)
    if (-not $Patterns)
    {
        return @()
    }
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $Patterns)
    {
        if ([string]::IsNullOrWhiteSpace($p))
        {
            continue
        }
        $x = $p.Trim()
        if ($x)
        {
            $null = $list.Add($x)
        }
    }
    return $list.ToArray() | Select-Object -Unique
}
function ConvertTo-PlainText
{
    param([securestring]$SecureValue)
    if ($null -eq $SecureValue)
    {
        return $null
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try
    {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally
    {
        if ($bstr -ne [IntPtr]::Zero)
        {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
function Get-TextEncoding
{
    param([string]$Name)
    switch ($Name.ToLowerInvariant())
    {
        'utf8'
        {
            return (New-Object System.Text.UTF8Encoding($false))
        }
        'utf8bom'
        {
            return (New-Object System.Text.UTF8Encoding($true))
        }
        'unicode'
        {
            return [System.Text.Encoding]::Unicode
        }
        'ascii'
        {
            return [System.Text.Encoding]::ASCII
        }
        default
        {
            throw "Unsupported encoding: $Name"
        }
    }
}
function Write-TextFile
{
    param([string]$FilePath, [string]$Content, [string]$EncodingName = 'UTF8')
    # Resolve to absolute path so .NET WriteAllText uses the correct base directory
    # (PowerShell $PWD and .NET Environment.CurrentDirectory can diverge)
    $FilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path $dir))
    {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($FilePath, $Content, (Get-TextEncoding -Name $EncodingName))
}
function Write-CsvFile
{
    param([string]$FilePath, [object[]]$Rows, [string[]]$Headers, [string]$EncodingName = 'UTF8')
    $lines = @()
    if (@($Rows).Count -gt 0)
    {
        $csvRows = $Rows
        if ($Headers -and $Headers.Count -gt 0)
        {
            $csvRows = $Rows | Select-Object -Property $Headers
        }
        $lines = $csvRows | ConvertTo-Csv -NoTypeInformation
    }
    elseif ($Headers -and $Headers.Count -gt 0)
    {
        $obj = [ordered]@{}
        foreach ($h in $Headers)
        {
            $obj[$h] = $null
        }
        $tmp = [pscustomobject]$obj | ConvertTo-Csv -NoTypeInformation
        $lines = @($tmp[0])
    }
    $content = ''
    if ($lines.Count -gt 0)
    {
        $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    }
    Write-TextFile -FilePath $FilePath -Content $content -EncodingName $EncodingName
}
function Write-JsonFile
{
    param($Data, [string]$FilePath, [int]$Depth = 12, [string]$EncodingName = 'UTF8')
    Write-TextFile -FilePath $FilePath -Content ($Data | ConvertTo-Json -Depth $Depth) -EncodingName $EncodingName
}
function Get-RoundedNumber
{
    param([double]$Value, [int]$Digits = 4) [Math]::Round($Value, $Digits)
}
function Format-MetricValue
{
    param([double]$Value)
    return $Value
}
function Add-Count
{
    param([hashtable]$Table, [string]$Key, [int]$Delta = 1)
    if ([string]::IsNullOrWhiteSpace($Key))
    {
        $Key = '(unknown)'
    }
    if (-not $Table.ContainsKey($Key))
    {
        $Table[$Key] = 0
    }
    $Table[$Key] = [int]$Table[$Key] + $Delta
}
function Get-NormalizedAuthorName
{
    param([string]$Author)
    if ([string]::IsNullOrWhiteSpace($Author))
    {
        return '(unknown)'
    }
    return $Author.Trim()
}
function ConvertTo-PathKey
{
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path))
    {
        return ''
    }
    $x = $Path.Trim() -replace '\\', '/'
    if ($x -match '^[a-zA-Z]+://')
    {
        $x = ([Uri]$x).AbsolutePath
    }
    $x = $x.TrimStart('/')
    if ($x.StartsWith('./'))
    {
        $x = $x.Substring(2)
    }
    return $x
}
function Get-Sha1Hex
{
    param([string]$Text)
    if ($null -eq $Text)
    {
        $Text = ''
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
    try
    {
        $hash = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}
function Get-PathCacheHash
{
    param([string]$FilePath)
    return Get-Sha1Hex -Text (ConvertTo-PathKey -Path $FilePath)
}
function Get-BlameCachePath
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    $dir = Join-Path (Join-Path $CacheDir 'blame') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -FilePath $FilePath) + '.xml')
}
function Get-CatCachePath
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    $dir = Join-Path (Join-Path $CacheDir 'cat') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -FilePath $FilePath) + '.txt')
}
function Read-BlameCacheFile
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $null
    }
    $path = Get-BlameCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if (-not (Test-Path $path))
    {
        return $null
    }
    return (Get-Content -Path $path -Raw -Encoding UTF8)
}
function Write-BlameCacheFile
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath, [string]$Content)
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return
    }
    $path = Get-BlameCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir))
    {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $path -Value $Content -Encoding UTF8
}
function Read-CatCacheFile
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $null
    }
    $path = Get-CatCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if (-not (Test-Path $path))
    {
        return $null
    }
    return (Get-Content -Path $path -Raw -Encoding UTF8)
}
function Write-CatCacheFile
{
    param([string]$CacheDir, [int]$Revision, [string]$FilePath, [string]$Content)
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return
    }
    $path = Get-CatCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir))
    {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $path -Value $Content -Encoding UTF8
}
function ConvertTo-TextLine
{
    param([string]$Text)
    if ($null -eq $Text)
    {
        return @()
    }
    $lines = $Text -split "`r`n|`n|`r", -1
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '')
    {
        if ($lines.Count -eq 1)
        {
            return @()
        }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return @($lines)
}
function Resolve-PathByRenameMap
{
    param([string]$FilePath, [hashtable]$RenameMap)
    $resolved = ConvertTo-PathKey -Path $FilePath
    if ($null -eq $RenameMap -or -not $resolved)
    {
        return $resolved
    }
    $guard = 0
    while ($RenameMap.ContainsKey($resolved) -and $guard -lt 4096)
    {
        $next = [string]$RenameMap[$resolved]
        if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $resolved)
        {
            break
        }
        $resolved = $next
        $guard++
    }
    return $resolved
}
function Get-DiffLineStat
{
    param([string]$DiffText)
    $added = 0
    $deleted = 0
    if ([string]::IsNullOrEmpty($DiffText))
    {
        return [pscustomobject]@{ AddedLines = 0; DeletedLines = 0 }
    }
    $lines = $DiffText -split "`r?`n"
    foreach ($line in $lines)
    {
        if (-not $line)
        {
            continue
        }
        if ($line.StartsWith('+++') -or $line.StartsWith('---') -or $line.StartsWith('@@') -or $line.StartsWith('Index: ') -or $line.StartsWith('===') -or $line -eq '\ No newline at end of file')
        {
            continue
        }
        if ($line[0] -eq '+')
        {
            $added++
            continue
        }
        if ($line[0] -eq '-')
        {
            $deleted++
            continue
        }
    }
    return [pscustomobject]@{ AddedLines = $added; DeletedLines = $deleted }
}
function Get-AllRepositoryFile
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Repo, [int]$Revision, [string[]]$IncludeExt, [string[]]$ExcludeExt, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
    $xmlText = Invoke-SvnCommand -Arguments @('list', '-R', '--xml', '-r', [string]$Revision, $Repo) -ErrorContext 'svn list'
    $xml = ConvertFrom-SvnXmlText -Text $xmlText -ContextLabel 'svn list'
    $nodes = @()
    if ($xml)
    {
        $entries = $xml.SelectNodes('/lists/list/entry')
        if ($entries -and $entries.Count -gt 0)
        {
            $nodes = @($entries)
        }
    }
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($node in $nodes)
    {
        if ([string]$node.kind -ne 'file')
        {
            continue
        }
        $nameNode = $node.SelectSingleNode('name')
        if ($null -eq $nameNode)
        {
            continue
        }
        $path = ConvertTo-PathKey -Path ([string]$nameNode.InnerText)
        if (-not $path)
        {
            continue
        }
        if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExt -ExcludeExt $ExcludeExt -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        {
            $files.Add($path) | Out-Null
        }
    }
    return @($files.ToArray() | Sort-Object -Unique)
}
function Initialize-CanonicalOffsetMap
{
    return (New-Object 'System.Collections.Generic.List[object]')
}
function Get-CanonicalLineNumber
{
    param([object[]]$OffsetEvents, [int]$LineNumber)
    $sum = 0
    foreach ($ev in @($OffsetEvents))
    {
        if ([int]$ev.Threshold -le $LineNumber)
        {
            $sum += [int]$ev.Delta
        }
    }
    return $LineNumber + $sum
}
function Add-CanonicalOffsetEvent
{
    param([System.Collections.Generic.List[object]]$OffsetEvents, [int]$ThresholdLine, [int]$ShiftDelta)
    if ($null -eq $OffsetEvents)
    {
        return
    }
    if ($ShiftDelta -eq 0)
    {
        return
    }
    $OffsetEvents.Add([pscustomobject]@{ Threshold = $ThresholdLine; Delta = $ShiftDelta }) | Out-Null
}
function Test-RangeOverlap
{
    param([int]$StartA, [int]$EndA, [int]$StartB, [int]$EndB)
    $left = [Math]::Max($StartA, $StartB)
    $right = [Math]::Min($EndA, $EndB)
    return ($left -le $right)
}
function Test-RangeTripleOverlap
{
    param([int]$StartA, [int]$EndA, [int]$StartB, [int]$EndB, [int]$StartC, [int]$EndC)
    $left = [Math]::Max([Math]::Max($StartA, $StartB), $StartC)
    $right = [Math]::Min([Math]::Min($EndA, $EndB), $EndC)
    return ($left -le $right)
}
function Test-ShouldCountFile
{
    param([string]$FilePath, [string[]]$IncludeExt, [string[]]$ExcludeExt, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
    if ([string]::IsNullOrWhiteSpace($FilePath))
    {
        return $false
    }
    $path = ConvertTo-PathKey -Path $FilePath
    if ($path.EndsWith('/'))
    {
        return $false
    }
    if ($IncludePathPatterns -and $IncludePathPatterns.Count -gt 0)
    {
        $ok = $false
        foreach ($p in $IncludePathPatterns)
        {
            if ($path -like $p)
            {
                $ok = $true
                break
            }
        }
        if (-not $ok)
        {
            return $false
        }
    }
    if ($ExcludePathPatterns -and $ExcludePathPatterns.Count -gt 0)
    {
        foreach ($p in $ExcludePathPatterns)
        {
            if ($path -like $p)
            {
                return $false
            }
        }
    }
    $ext = [System.IO.Path]::GetExtension($path)
    if ([string]::IsNullOrEmpty($ext))
    {
        if ($IncludeExt -and $IncludeExt.Count -gt 0)
        {
            return $false
        }
        return $true
    }
    $ext = $ext.TrimStart('.').ToLowerInvariant()
    if ($IncludeExt -and $IncludeExt.Count -gt 0 -and -not ($IncludeExt -contains $ext))
    {
        return $false
    }
    if ($ExcludeExt -and $ExcludeExt.Count -gt 0 -and ($ExcludeExt -contains $ext))
    {
        return $false
    }
    return $true
}
function Join-CommandArgument
{
    param([string[]]$Arguments)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $Arguments)
    {
        if ($null -eq $a)
        {
            continue
        }
        $t = [string]$a
        if ($t -match '[\s"]')
        {
            $null = $parts.Add('"' + $t.Replace('"', '\"') + '"')
        }
        else
        {
            $null = $parts.Add($t)
        }
    }
    return ($parts.ToArray() -join ' ')
}
function Invoke-SvnCommand
{
    [CmdletBinding()]param([string[]]$Arguments, [string]$ErrorContext = 'SVN command')
    $all = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $Arguments)
    {
        $null = $all.Add([string]$a)
    }
    if ($script:SvnGlobalArguments)
    {
        foreach ($a in $script:SvnGlobalArguments)
        {
            $null = $all.Add([string]$a)
        }
    }
    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:SvnExecutable
        $psi.Arguments = Join-CommandArgument -Arguments $all.ToArray()
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $null = $process.Start()
        $out = $process.StandardOutput.ReadToEnd()
        $err = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0)
        {
            throw "$ErrorContext failed (exit code $($process.ExitCode)).`nSTDERR: $err`nSTDOUT: $out"
        }
        return $out
    }
    finally
    {
        if ($process)
        {
            $process.Dispose()
        }
    }
}
function ConvertFrom-SvnXmlText
{
    param([string]$Text, [string]$ContextLabel = 'svn output')
    $idx = $Text.IndexOf('<?xml')
    if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<log')
    }
    if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<info')
    }
    if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<diff')
    }
    if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<blame')
    }
    if ($idx -gt 0)
    {
        $Text = $Text.Substring($idx)
    }
    try
    {
        return [xml]$Text
    }
    catch
    {
        throw "Failed to parse XML from $ContextLabel. $($_.Exception.Message)"
    }
}
function Resolve-SvnTargetUrl
{
    param([string]$Target)
    if (-not ($Target -match '^(https?|svn|file)://'))
    {
        throw "RepoUrl must be svn URL. Provided: '$Target'"
    }
    $xml = ConvertFrom-SvnXmlText -Text (Invoke-SvnCommand -Arguments @('info', '--xml', $Target) -ErrorContext 'svn info') -ContextLabel 'svn info'
    $url = [string]$xml.info.entry.url
    if ([string]::IsNullOrWhiteSpace($url))
    {
        throw "Could not validate repository URL: $Target"
    }
    return $url.TrimEnd('/')
}
function ConvertFrom-SvnLogXml
{
    [CmdletBinding()]param([string]$XmlText)
    $xml = ConvertFrom-SvnXmlText -Text $XmlText -ContextLabel 'svn log'
    $entries = @()
    if ($xml -and $xml.log -and $xml.log.logentry)
    {
        $entries = @($xml.log.logentry)
    }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $entries)
    {
        $rev = 0
        try
        {
            $rev = [int]$e.revision
        }
        catch
        {
            $null = $_
        }
        $authorNode = $e.SelectSingleNode('author')
        $author = if ($authorNode)
        {
            [string]$authorNode.InnerText
        }
        else
        {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($author))
        {
            $author = '(unknown)'
        }
        $date = $null
        $dateText = [string]$e.date
        if ($dateText)
        {
            try
            {
                $date = [datetime]::Parse($dateText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            }
            catch
            {
                try
                {
                    $date = [datetime]$dateText
                }
                catch
                {
                    $null = $_
                    $date = $null
                }
            }
        }
        $msg = [string]$e.msg
        $paths = New-Object 'System.Collections.Generic.List[object]'
        $pathNodes = @()
        $pathsNode = $e.SelectSingleNode('paths')
        if ($pathsNode)
        {
            $pathChildren = $pathsNode.SelectNodes('path')
            if ($pathChildren -and $pathChildren.Count -gt 0)
            {
                $pathNodes = @($pathChildren)
            }
        }
        foreach ($p in $pathNodes)
        {
            $raw = [string]$p.'#text'
            if ([string]::IsNullOrWhiteSpace($raw))
            {
                continue
            }
            $path = ConvertTo-PathKey -Path $raw
            if (-not $path)
            {
                continue
            }
            $copyPath = $null
            if ($p.HasAttribute('copyfrom-path'))
            {
                $copyPath = ConvertTo-PathKey -Path ($p.GetAttribute('copyfrom-path'))
            }
            $copyRev = $null
            if ($p.HasAttribute('copyfrom-rev'))
            {
                try
                {
                    $copyRev = [int]$p.GetAttribute('copyfrom-rev')
                }
                catch
                {
                    $null = $_
                }
            }
            $isDirectory = $false
            if ($p.HasAttribute('kind'))
            {
                $kind = [string]$p.GetAttribute('kind')
                if ($kind -ieq 'dir')
                {
                    $isDirectory = $true
                }
                elseif ($kind -ieq 'file')
                {
                    $isDirectory = $false
                }
            }
            if (-not $isDirectory -and $raw.Trim().EndsWith('/'))
            {
                $isDirectory = $true
            }
            $paths.Add([pscustomobject]@{ Path = $path
                    Action = [string]$p.action
                    CopyFromPath = $copyPath
                    CopyFromRev = $copyRev
                    IsDirectory = $isDirectory
                }) | Out-Null
        }
        $list.Add([pscustomobject]@{
                Revision = $rev
                Author = $author
                Date = $date
                Message = $msg
                ChangedPaths = $paths.ToArray()
                ChangedPathsFiltered = @()
                FileDiffStats = @{}
                FilesChanged = @()
                AddedLines = 0
                DeletedLines = 0
                Churn = 0
                Entropy = 0.0
                MsgLen = 0
                MessageShort = ''
            }) | Out-Null
    }
    return $list.ToArray() | Sort-Object Revision
}
function ConvertTo-LineHash
{
    param([string]$FilePath, [string]$Content)
    $norm = $Content -replace '\s+', ' '
    $norm = $norm.Trim()
    $raw = $FilePath + [char]0 + $norm
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
    try
    {
        $hash = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}
function Test-IsTrivialLine
{
    param([string]$Content)
    $t = $Content.Trim()
    if ($t.Length -le 3)
    {
        return $true
    }
    $trivials = @('{', '}', '};', 'else', 'else {', 'return;', 'break;', 'continue;', '});', ');', '(', ')', '')
    if ($trivials -contains $t)
    {
        return $true
    }
    return $false
}
function ConvertTo-ContextHash
{
    param([string]$FilePath, [string[]]$ContextLines, [int]$K = 3)
    $first = @()
    $last = @()
    if ($ContextLines -and $ContextLines.Count -gt 0)
    {
        $cnt = $ContextLines.Count
        $take = [Math]::Min($K, $cnt)
        $first = @($ContextLines[0..($take - 1)])
        if ($cnt -gt $K)
        {
            $startIdx = $cnt - $take
            $last = @($ContextLines[$startIdx..($cnt - 1)])
        }
        else
        {
            $last = $first
        }
    }
    $raw = $FilePath + '|' + ($first -join '|') + '|' + ($last -join '|')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
    try
    {
        $hash = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}
function ConvertFrom-SvnUnifiedDiff
{
    [CmdletBinding()]param([string]$DiffText, [int]$DetailLevel = 0)
    $result = @{}
    if ([string]::IsNullOrEmpty($DiffText))
    {
        return $result
    }
    $lines = $DiffText -split "`r?`n"
    $current = $null
    $currentFile = $null
    $currentHunk = $null
    $hunkContextLines = $null
    $hunkAddedHashes = $null
    $hunkDeletedHashes = $null
    foreach ($line in $lines)
    {
        if ($line -like 'Index: *')
        {
            if ($DetailLevel -ge 1 -and $null -ne $currentHunk -and $null -ne $currentFile)
            {
                $currentHunk.ContextHash = ConvertTo-ContextHash -FilePath $currentFile -ContextLines $hunkContextLines
                $currentHunk.AddedLineHashes = $hunkAddedHashes.ToArray()
                $currentHunk.DeletedLineHashes = $hunkDeletedHashes.ToArray()
            }
            $file = ConvertTo-PathKey -Path $line.Substring(7).Trim()
            if ($file)
            {
                if (-not $result.ContainsKey($file))
                {
                    $result[$file] = [pscustomobject]@{
                        AddedLines = 0
                        DeletedLines = 0
                        Hunks = (New-Object 'System.Collections.Generic.List[object]')
                        IsBinary = $false
                        AddedLineHashes = (New-Object 'System.Collections.Generic.List[string]')
                        DeletedLineHashes = (New-Object 'System.Collections.Generic.List[string]')
                    }
                }
                $current = $result[$file]
                $currentFile = $file
            }
            $currentHunk = $null
            $hunkContextLines = $null
            $hunkAddedHashes = $null
            $hunkDeletedHashes = $null
            continue
        }
        if ($null -eq $current)
        {
            continue
        }
        if ($line -match '^@@\s*-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s*@@')
        {
            if ($DetailLevel -ge 1 -and $null -ne $currentHunk -and $null -ne $currentFile)
            {
                $currentHunk.ContextHash = ConvertTo-ContextHash -FilePath $currentFile -ContextLines $hunkContextLines
                $currentHunk.AddedLineHashes = $hunkAddedHashes.ToArray()
                $currentHunk.DeletedLineHashes = $hunkDeletedHashes.ToArray()
            }
            $hunkObj = [pscustomobject]@{
                OldStart = [int]$Matches[1]
                OldCount = if ($Matches[2])
                {
                    [int]$Matches[2]
                }
                else
                {
                    1
                }
                NewStart = [int]$Matches[3]
                NewCount = if ($Matches[4])
                {
                    [int]$Matches[4]
                }
                else
                {
                    1
                }
                ContextHash = $null
                AddedLineHashes = @()
                DeletedLineHashes = @()
            }
            $current.Hunks.Add($hunkObj) | Out-Null
            $currentHunk = $hunkObj
            if ($DetailLevel -ge 1)
            {
                $hunkContextLines = New-Object 'System.Collections.Generic.List[string]'
                $hunkAddedHashes = New-Object 'System.Collections.Generic.List[string]'
                $hunkDeletedHashes = New-Object 'System.Collections.Generic.List[string]'
            }
            continue
        }
        if ($line -match '^Cannot display: file marked as a binary type\.' -or $line -match '^Binary files .* differ' -or $line -match '(?i)mime-type\s*=\s*application/octet-stream')
        {
            $current.IsBinary = $true
            continue
        }
        if (-not $line)
        {
            continue
        }
        if ($line.StartsWith('+++') -or $line.StartsWith('---') -or $line -eq '\ No newline at end of file')
        {
            continue
        }
        if ($line[0] -eq '+')
        {
            $current.AddedLines++
            if ($DetailLevel -ge 1 -and $null -ne $currentFile)
            {
                $content = $line.Substring(1)
                $h = ConvertTo-LineHash -FilePath $currentFile -Content $content
                $current.AddedLineHashes.Add($h)
                if ($null -ne $hunkAddedHashes)
                {
                    $hunkAddedHashes.Add($h)
                }
            }
            continue
        }
        if ($line[0] -eq '-')
        {
            $current.DeletedLines++
            if ($DetailLevel -ge 1 -and $null -ne $currentFile)
            {
                $content = $line.Substring(1)
                $h = ConvertTo-LineHash -FilePath $currentFile -Content $content
                $current.DeletedLineHashes.Add($h)
                if ($null -ne $hunkDeletedHashes)
                {
                    $hunkDeletedHashes.Add($h)
                }
            }
            continue
        }
        if ($DetailLevel -ge 1 -and $line.Length -gt 0 -and $line[0] -eq ' ' -and $null -ne $hunkContextLines)
        {
            $hunkContextLines.Add($line.Substring(1))
        }
    }
    if ($DetailLevel -ge 1 -and $null -ne $currentHunk -and $null -ne $currentFile)
    {
        $currentHunk.ContextHash = ConvertTo-ContextHash -FilePath $currentFile -ContextLines $hunkContextLines
        $currentHunk.AddedLineHashes = $hunkAddedHashes.ToArray()
        $currentHunk.DeletedLineHashes = $hunkDeletedHashes.ToArray()
    }
    return $result
}
function ConvertFrom-SvnBlameXml
{
    [CmdletBinding()]param([string]$XmlText, [string[]]$ContentLines)
    $xml = ConvertFrom-SvnXmlText -Text $XmlText -ContextLabel 'svn blame'
    $entries = @()
    if ($xml)
    {
        $targetNode = $xml.SelectSingleNode('blame/target')
        if ($targetNode)
        {
            $entryNodes = $targetNode.SelectNodes('entry')
            if ($entryNodes -and $entryNodes.Count -gt 0)
            {
                $entries = @($entryNodes)
            }
        }
    }
    $byRev = @{}
    $byAuthor = @{}
    $lineRows = New-Object 'System.Collections.Generic.List[object]'
    $total = 0
    foreach ($entry in $entries)
    {
        $total++
        $commit = $entry.commit
        $lineNumber = 0
        try
        {
            $lineNumber = [int]$entry.'line-number'
        }
        catch
        {
            $lineNumber = $total
        }
        $rev = $null
        $author = '(unknown)'
        if ($null -eq $commit)
        {
            $content = ''
            if ($ContentLines -and $lineNumber -gt 0 -and ($lineNumber - 1) -lt $ContentLines.Count)
            {
                $content = [string]$ContentLines[$lineNumber - 1]
            }
            $lineRows.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    Content = $content
                    Revision = $null
                    Author = '(unknown)'
                }) | Out-Null
            continue
        }
        try
        {
            $rev = [int]$commit.revision
        }
        catch
        {
            $null = $_
        }
        if ($null -ne $rev)
        {
            if (-not $byRev.ContainsKey($rev))
            {
                $byRev[$rev] = 0
            }
            $byRev[$rev]++
        }
        $authorNode = $commit.SelectSingleNode('author')
        $author = if ($authorNode)
        {
            [string]$authorNode.InnerText
        }
        else
        {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($author))
        {
            $author = '(unknown)'
        }
        if (-not $byAuthor.ContainsKey($author))
        {
            $byAuthor[$author] = 0
        }
        $byAuthor[$author]++

        $content = ''
        if ($ContentLines -and $lineNumber -gt 0 -and ($lineNumber - 1) -lt $ContentLines.Count)
        {
            $content = [string]$ContentLines[$lineNumber - 1]
        }
        $lineRows.Add([pscustomobject]@{
                LineNumber = $lineNumber
                Content = $content
                Revision = $rev
                Author = $author
            }) | Out-Null
    }
    return [pscustomobject]@{ LineCountTotal = $total
        LineCountByRevision = $byRev
        LineCountByAuthor = $byAuthor
        Lines = @($lineRows.ToArray() | Sort-Object LineNumber)
    }
}
function Get-Entropy
{
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0)
    {
        return 0.0
    }
    $sum = 0.0
    foreach ($v in $Values)
    {
        $sum += [double]$v
    }
    if ($sum -le 0)
    {
        return 0.0
    }
    $e = 0.0
    foreach ($v in $Values)
    {
        $x = [double]$v
        if ($x -le 0)
        {
            continue
        }
        $p = $x / $sum
        $e += (-1.0) * $p * ([Math]::Log($p, 2.0))
    }
    return $e
}
function Get-MessageMetricCount
{
    param([string]$Message)
    if ($null -eq $Message)
    {
        $Message = ''
    }
    [pscustomobject]@{
        IssueIdMentionCount = [regex]::Matches($Message, '(#\d+)|([A-Z][A-Z0-9]+-\d+)', 'IgnoreCase').Count
        FixKeywordCount = [regex]::Matches($Message, '\b(fix|bug|hotfix|defect|patch)\b', 'IgnoreCase').Count
        RevertKeywordCount = [regex]::Matches($Message, '\b(revert|backout|rollback)\b', 'IgnoreCase').Count
        MergeKeywordCount = [regex]::Matches($Message, '\bmerge\b', 'IgnoreCase').Count
    }
}
function Get-SvnBlameSummary
{
    [CmdletBinding()]param([string]$Repo, [string]$FilePath, [int]$ToRevision, [string]$CacheDir)
    $url = $Repo.TrimEnd('/') + '/' + (ConvertTo-PathKey -Path $FilePath).TrimStart('/') + '@' + [string]$ToRevision
    $text = Read-BlameCacheFile -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath
    if ([string]::IsNullOrEmpty($text))
    {
        $script:StrictBlameCacheMisses++
        $text = Invoke-SvnCommand -Arguments @('blame', '--xml', '-r', [string]$ToRevision, $url) -ErrorContext ("svn blame $FilePath")
        Write-BlameCacheFile -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath -Content $text
    }
    else
    {
        $script:StrictBlameCacheHits++
    }
    ConvertFrom-SvnBlameXml -XmlText $text
}
function Get-SvnBlameLine
{
    [CmdletBinding()]
    param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir)
    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision

    $blameXml = Read-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ([string]::IsNullOrEmpty($blameXml))
    {
        $script:StrictBlameCacheMisses++
        $blameXml = Invoke-SvnCommand -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        Write-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
    }
    else
    {
        $script:StrictBlameCacheHits++
    }

    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ($null -eq $catText)
    {
        $catText = Invoke-SvnCommand -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
        Write-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
    }
    $contentLines = ConvertTo-TextLine -Text $catText
    return (ConvertFrom-SvnBlameXml -XmlText $blameXml -ContentLines $contentLines)
}
function Get-LineIdentityKey
{
    param([object]$Line)
    if ($null -eq $Line)
    {
        return ''
    }
    $rev = if ($null -ne $Line.Revision)
    {
        [string]$Line.Revision
    }
    else
    {
        ''
    }
    $author = Get-NormalizedAuthorName -Author ([string]$Line.Author)
    $content = if ($null -ne $Line.Content)
    {
        [string]$Line.Content
    }
    else
    {
        ''
    }
    return ($rev + [char]31 + $author + [char]31 + $content)
}
function Get-LcsMatchedPair
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]]$PreviousKeys,
        [string[]]$CurrentKeys,
        [bool[]]$PreviousLocked,
        [bool[]]$CurrentLocked
    )

    $prev = @($PreviousKeys)
    $curr = @($CurrentKeys)
    $prevIdx = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0
        $i -lt $prev.Count
        $i++)
    {
        $isLocked = $false
        if ($null -ne $PreviousLocked -and $i -lt $PreviousLocked.Length)
        {
            $isLocked = [bool]$PreviousLocked[$i]
        }
        if (-not $isLocked)
        {
            $prevIdx.Add($i) | Out-Null
        }
    }
    $currIdx = New-Object 'System.Collections.Generic.List[int]'
    for ($j = 0
        $j -lt $curr.Count
        $j++)
    {
        $isLocked = $false
        if ($null -ne $CurrentLocked -and $j -lt $CurrentLocked.Length)
        {
            $isLocked = [bool]$CurrentLocked[$j]
        }
        if (-not $isLocked)
        {
            $currIdx.Add($j) | Out-Null
        }
    }

    $m = $prevIdx.Count
    $n = $currIdx.Count
    if ($m -eq 0 -or $n -eq 0)
    {
        return @()
    }

    $dp = New-Object 'int[,]' ($m + 1), ($n + 1)
    for ($i = 1
        $i -le $m
        $i++)
    {
        for ($j = 1
            $j -le $n
            $j++)
        {
            $iPrev = $i - 1
            $jPrev = $j - 1
            $leftPrev = [int]$prevIdx[$iPrev]
            $leftCurr = [int]$currIdx[$jPrev]
            if ($prev[$leftPrev] -ceq $curr[$leftCurr])
            {
                $dp[$i, $j] = $dp[$iPrev, $jPrev] + 1
            }
            else
            {
                $left = $dp[$iPrev, $j]
                $up = $dp[$i, $jPrev]
                $dp[$i, $j] = [Math]::Max($left, $up)
            }
        }
    }

    $pairs = New-Object 'System.Collections.Generic.List[object]'
    $i = $m
    $j = $n
    while ($i -gt 0 -and $j -gt 0)
    {
        $iPrev = $i - 1
        $jPrev = $j - 1
        $prevPos = [int]$prevIdx[$iPrev]
        $currPos = [int]$currIdx[$jPrev]
        if ($prev[$prevPos] -ceq $curr[$currPos])
        {
            $pairs.Add([pscustomobject]@{
                    PrevIndex = $prevPos
                    CurrIndex = $currPos
                }) | Out-Null
            $i--
            $j--
        }
        else
        {
            $iPrev = $i - 1
            $jPrev = $j - 1
            if ($dp[$iPrev, $j] -ge $dp[$i, $jPrev])
            {
                $i--
            }
            else
            {
                $j--
            }
        }
    }
    return @($pairs.ToArray() | Sort-Object PrevIndex, CurrIndex)
}
function Compare-BlameOutput
{
    [CmdletBinding()]
    param([object[]]$PreviousLines, [object[]]$CurrentLines)

    $prev = @($PreviousLines)
    $curr = @($CurrentLines)
    $m = $prev.Count
    $n = $curr.Count

    $prevIdentity = New-Object 'string[]' $m
    $currIdentity = New-Object 'string[]' $n
    $prevContent = New-Object 'string[]' $m
    $currContent = New-Object 'string[]' $n
    for ($i = 0
        $i -lt $m
        $i++)
    {
        $prevIdentity[$i] = Get-LineIdentityKey -Line $prev[$i]
        $prevContent[$i] = [string]$prev[$i].Content
    }
    for ($j = 0
        $j -lt $n
        $j++)
    {
        $currIdentity[$j] = Get-LineIdentityKey -Line $curr[$j]
        $currContent[$j] = [string]$curr[$j].Content
    }

    $matchedPairs = New-Object 'System.Collections.Generic.List[object]'
    $prevMatched = New-Object 'bool[]' $m
    $currMatched = New-Object 'bool[]' $n

    foreach ($pair in @(Get-LcsMatchedPair -PreviousKeys $prevIdentity -CurrentKeys $currIdentity -PreviousLocked $prevMatched -CurrentLocked $currMatched))
    {
        $prevIdx = [int]$pair.PrevIndex
        $currIdx = [int]$pair.CurrIndex
        $prevMatched[$prevIdx] = $true
        $currMatched[$currIdx] = $true
        $matchedPairs.Add([pscustomobject]@{
                PrevIndex = $prevIdx
                CurrIndex = $currIdx
                PrevLine = $prev[$prevIdx]
                CurrLine = $curr[$currIdx]
                MatchType = 'LcsIdentity'
            }) | Out-Null
    }

    $unmatchedPrevByKey = @{}
    for ($pi = 0
        $pi -lt $m
        $pi++)
    {
        if ($prevMatched[$pi])
        {
            continue
        }
        $key = Get-LineIdentityKey -Line $prev[$pi]
        if (-not $unmatchedPrevByKey.ContainsKey($key))
        {
            $unmatchedPrevByKey[$key] = New-Object 'System.Collections.Generic.List[int]'
        }
        $unmatchedPrevByKey[$key].Add($pi) | Out-Null
    }

    $movedPairs = New-Object 'System.Collections.Generic.List[object]'
    for ($ci = 0
        $ci -lt $n
        $ci++)
    {
        if ($currMatched[$ci])
        {
            continue
        }
        $key = Get-LineIdentityKey -Line $curr[$ci]
        if (-not $unmatchedPrevByKey.ContainsKey($key))
        {
            continue
        }
        $queue = $unmatchedPrevByKey[$key]
        if ($queue.Count -le 0)
        {
            continue
        }
        $prevIdx = [int]$queue[0]
        $queue.RemoveAt(0)
        $prevMatched[$prevIdx] = $true
        $currMatched[$ci] = $true
        $pair = [pscustomobject]@{
            PrevIndex = $prevIdx
            CurrIndex = $ci
            PrevLine = $prev[$prevIdx]
            CurrLine = $curr[$ci]
            MatchType = 'Move'
        }
        $matchedPairs.Add($pair) | Out-Null
        $movedPairs.Add($pair) | Out-Null
    }

    foreach ($pair in @(Get-LcsMatchedPair -PreviousKeys $prevContent -CurrentKeys $currContent -PreviousLocked $prevMatched -CurrentLocked $currMatched))
    {
        $prevIdx = [int]$pair.PrevIndex
        $currIdx = [int]$pair.CurrIndex
        if ($prevMatched[$prevIdx] -or $currMatched[$currIdx])
        {
            continue
        }
        $prevMatched[$prevIdx] = $true
        $currMatched[$currIdx] = $true
        $matchedPairs.Add([pscustomobject]@{
                PrevIndex = $prevIdx
                CurrIndex = $currIdx
                PrevLine = $prev[$prevIdx]
                CurrLine = $curr[$currIdx]
                MatchType = 'LcsContent'
            }) | Out-Null
    }

    $killed = New-Object 'System.Collections.Generic.List[object]'
    for ($pi = 0
        $pi -lt $m
        $pi++)
    {
        if (-not $prevMatched[$pi])
        {
            $killed.Add([pscustomobject]@{
                    Index = $pi
                    Line = $prev[$pi]
                }) | Out-Null
        }
    }
    $born = New-Object 'System.Collections.Generic.List[object]'
    for ($ci = 0
        $ci -lt $n
        $ci++)
    {
        if (-not $currMatched[$ci])
        {
            $born.Add([pscustomobject]@{
                    Index = $ci
                    Line = $curr[$ci]
                }) | Out-Null
        }
    }

    $reattributed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in @($matchedPairs.ToArray()))
    {
        $prevLine = $pair.PrevLine
        $currLine = $pair.CurrLine
        if ([string]$prevLine.Content -ceq [string]$currLine.Content -and (([string]$prevLine.Revision -ne [string]$currLine.Revision) -or ((Get-NormalizedAuthorName -Author ([string]$prevLine.Author)) -ne (Get-NormalizedAuthorName -Author ([string]$currLine.Author)))))
        {
            $reattributed.Add($pair) | Out-Null
        }
    }

    return [pscustomobject]@{
        KilledLines = @($killed.ToArray())
        BornLines = @($born.ToArray())
        MatchedPairs = @($matchedPairs.ToArray() | Sort-Object PrevIndex, CurrIndex)
        MovedPairs = @($movedPairs.ToArray())
        ReattributedPairs = @($reattributed.ToArray())
    }
}
function Get-CommitFileTransition
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object]$Commit)

    $paths = @($Commit.ChangedPathsFiltered)
    $pathMap = @{}
    $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $paths)
    {
        $path = ConvertTo-PathKey -Path ([string]$p.Path)
        if (-not $path)
        {
            continue
        }
        if (-not $pathMap.ContainsKey($path))
        {
            $pathMap[$path] = New-Object 'System.Collections.Generic.List[object]'
        }
        $pathMap[$path].Add($p) | Out-Null
        if (([string]$p.Action).ToUpperInvariant() -eq 'D')
        {
            $null = $deleted.Add($path)
        }
    }

    $renameNewToOld = @{}
    $consumedOld = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $paths)
    {
        $action = ([string]$p.Action).ToUpperInvariant()
        if (($action -ne 'A' -and $action -ne 'R') -or [string]::IsNullOrWhiteSpace([string]$p.CopyFromPath))
        {
            continue
        }
        $newPath = ConvertTo-PathKey -Path ([string]$p.Path)
        $oldPath = ConvertTo-PathKey -Path ([string]$p.CopyFromPath)
        if (-not $newPath -or -not $oldPath)
        {
            continue
        }
        if ($deleted.Contains($oldPath))
        {
            $renameNewToOld[$newPath] = $oldPath
            $null = $consumedOld.Add($oldPath)
        }
    }

    $result = New-Object 'System.Collections.Generic.List[object]'
    $dedup = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($newPath in @($renameNewToOld.Keys | Sort-Object))
    {
        $oldPath = [string]$renameNewToOld[$newPath]
        $key = $oldPath + [char]31 + $newPath
        if ($dedup.Add($key))
        {
            $result.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $newPath
                }) | Out-Null
        }
    }

    foreach ($oldPath in $deleted)
    {
        if ($consumedOld.Contains($oldPath))
        {
            continue
        }
        $key = $oldPath + [char]31
        if ($dedup.Add($key))
        {
            $result.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $null
                }) | Out-Null
        }
    }

    $candidates = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in @($Commit.FilesChanged))
    {
        $null = $candidates.Add((ConvertTo-PathKey -Path ([string]$f)))
    }
    foreach ($path in $pathMap.Keys)
    {
        $null = $candidates.Add($path)
    }

    foreach ($path in $candidates)
    {
        if (-not $path)
        {
            continue
        }
        if ($renameNewToOld.ContainsKey($path) -or $consumedOld.Contains($path) -or $deleted.Contains($path))
        {
            continue
        }
        $beforePath = $path
        $afterPath = $path
        if ($pathMap.ContainsKey($path))
        {
            $entries = $pathMap[$path]
            if ($null -ne $entries -and $entries.Count -gt 0)
            {
                $entry = $entries[0]
                $action = ([string]$entry.Action).ToUpperInvariant()
                if ($action -eq 'A')
                {
                    $beforePath = $null
                }
            }
        }
        $key = ([string]$beforePath) + [char]31 + ([string]$afterPath)
        if ($dedup.Add($key))
        {
            $result.Add([pscustomobject]@{
                    BeforePath = $beforePath
                    AfterPath = $afterPath
                }) | Out-Null
        }
    }

    return @($result.ToArray())
}
function Get-StrictHunkDetail
{
    [CmdletBinding()]
    param([object[]]$Commits, [hashtable]$RevToAuthor, [hashtable]$RenameMap)

    $offsetByFile = @{}
    $eventsByFile = @{}
    foreach ($c in @($Commits | Sort-Object Revision))
    {
        $rev = [int]$c.Revision
        $author = if ($RevToAuthor.ContainsKey($rev))
        {
            Get-NormalizedAuthorName -Author ([string]$RevToAuthor[$rev])
        }
        else
        {
            Get-NormalizedAuthorName -Author ([string]$c.Author)
        }
        foreach ($f in @($c.FilesChanged))
        {
            if (-not $c.FileDiffStats.ContainsKey($f))
            {
                continue
            }
            $d = $c.FileDiffStats[$f]
            if ($null -eq $d -or -not ($d.PSObject.Properties.Name -contains 'Hunks'))
            {
                continue
            }
            $hunksRaw = $d.Hunks
            if ($null -eq $hunksRaw)
            {
                continue
            }
            $hunks = New-Object 'System.Collections.Generic.List[object]'
            if ($hunksRaw -is [System.Collections.IEnumerable] -and -not ($hunksRaw -is [string]))
            {
                foreach ($hx in $hunksRaw)
                {
                    $hunks.Add($hx) | Out-Null
                }
            }
            else
            {
                $hunks.Add($hunksRaw) | Out-Null
            }
            if ($hunks.Count -eq 0)
            {
                continue
            }
            $resolved = Resolve-PathByRenameMap -FilePath $f -RenameMap $RenameMap
            if ([string]::IsNullOrWhiteSpace($resolved))
            {
                continue
            }
            if (-not $offsetByFile.ContainsKey($resolved))
            {
                $offsetByFile[$resolved] = Initialize-CanonicalOffsetMap
            }
            if (-not $eventsByFile.ContainsKey($resolved))
            {
                $eventsByFile[$resolved] = New-Object 'System.Collections.Generic.List[object]'
            }

            $offset = $offsetByFile[$resolved]
            $pending = New-Object 'System.Collections.Generic.List[object]'
            foreach ($h in @($hunks.ToArray() | Sort-Object OldStart, NewStart))
            {
                $oldStart = [int]$h.OldStart
                $oldCount = [int]$h.OldCount
                $newCount = [int]$h.NewCount
                if ($oldStart -lt 1)
                {
                    continue
                }
                $start = Get-CanonicalLineNumber -OffsetEvents $offset -LineNumber $oldStart
                $end = $start
                if ($oldCount -gt 0)
                {
                    $end = Get-CanonicalLineNumber -OffsetEvents $offset -LineNumber ($oldStart + $oldCount - 1)
                }
                if ($end -lt $start)
                {
                    $tmp = $start
                    $start = $end
                    $end = $tmp
                }
                $eventsByFile[$resolved].Add([pscustomobject]@{
                        Revision = $rev
                        Author = $author
                        Start = $start
                        End = $end
                    }) | Out-Null

                $shift = $newCount - $oldCount
                if ($shift -ne 0)
                {
                    $threshold = $oldStart + $oldCount
                    if ($oldCount -eq 0)
                    {
                        $threshold = $oldStart
                    }
                    $pending.Add([pscustomobject]@{
                            Threshold = $threshold
                            Delta = $shift
                        }) | Out-Null
                }
            }
            foreach ($p in @($pending.ToArray() | Sort-Object Threshold))
            {
                Add-CanonicalOffsetEvent -OffsetEvents $offset -ThresholdLine ([int]$p.Threshold) -ShiftDelta ([int]$p.Delta)
            }
        }
    }

    $authorRepeated = @{}
    $fileRepeated = @{}
    $authorPingPong = @{}
    $filePingPong = @{}
    foreach ($file in $eventsByFile.Keys)
    {
        $events = @($eventsByFile[$file].ToArray() | Sort-Object Revision)
        for ($i = 0
            $i -lt $events.Count
            $i++)
        {
            for ($j = $i + 1
                $j -lt $events.Count
                $j++)
            {
                $a1 = [string]$events[$i].Author
                $a2 = [string]$events[$j].Author
                if ($a1 -ne $a2)
                {
                    continue
                }
                if (Test-RangeOverlap -StartA ([int]$events[$i].Start) -EndA ([int]$events[$i].End) -StartB ([int]$events[$j].Start) -EndB ([int]$events[$j].End))
                {
                    Add-Count -Table $authorRepeated -Key $a1
                    Add-Count -Table $fileRepeated -Key $file
                }
            }
        }
        for ($i = 0
            $i -lt ($events.Count - 2)
            $i++)
        {
            for ($j = $i + 1
                $j -lt ($events.Count - 1)
                $j++)
            {
                $a1 = [string]$events[$i].Author
                $a2 = [string]$events[$j].Author
                if ($a1 -eq $a2)
                {
                    continue
                }
                if (-not (Test-RangeOverlap -StartA ([int]$events[$i].Start) -EndA ([int]$events[$i].End) -StartB ([int]$events[$j].Start) -EndB ([int]$events[$j].End)))
                {
                    continue
                }
                for ($k = $j + 1
                    $k -lt $events.Count
                    $k++)
                {
                    $a3 = [string]$events[$k].Author
                    if ($a3 -ne $a1)
                    {
                        continue
                    }
                    if (Test-RangeTripleOverlap -StartA ([int]$events[$i].Start) -EndA ([int]$events[$i].End) -StartB ([int]$events[$j].Start) -EndB ([int]$events[$j].End) -StartC ([int]$events[$k].Start) -EndC ([int]$events[$k].End))
                    {
                        Add-Count -Table $authorPingPong -Key $a1
                        Add-Count -Table $filePingPong -Key $file
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        AuthorRepeatedHunk = $authorRepeated
        AuthorPingPong = $authorPingPong
        FileRepeatedHunk = $fileRepeated
        FilePingPong = $filePingPong
    }
}
function Get-ExactDeathAttribution
{
    [CmdletBinding()]
    param(
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [hashtable]$RenameMap = @{}
    )

    $authorBorn = @{}
    $authorDead = @{}
    $authorSelfDead = @{}
    $authorOtherDead = @{}
    $authorSurvived = @{}
    $authorCrossRevert = @{}
    $authorRemovedByOthers = @{}

    $fileBorn = @{}
    $fileDead = @{}
    $fileSurvived = @{}
    $fileSelfCancel = @{}
    $fileCrossRevert = @{}

    $authorInternalMove = @{}
    $fileInternalMove = @{}

    $authorModifiedOthersCode = @{}
    $revsWhereKilledOthers = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($c in @($Commits | Sort-Object Revision))
    {
        $rev = [int]$c.Revision
        if ($rev -lt $FromRevision -or $rev -gt $ToRevision)
        {
            continue
        }
        $killer = if ($RevToAuthor.ContainsKey($rev))
        {
            Get-NormalizedAuthorName -Author ([string]$RevToAuthor[$rev])
        }
        else
        {
            Get-NormalizedAuthorName -Author ([string]$c.Author)
        }
        $transitions = @(Get-CommitFileTransition -Commit $c)
        foreach ($t in $transitions)
        {
            try
            {
                $beforePath = if ($null -ne $t.BeforePath)
                {
                    ConvertTo-PathKey -Path ([string]$t.BeforePath)
                }
                else
                {
                    $null
                }
                $afterPath = if ($null -ne $t.AfterPath)
                {
                    ConvertTo-PathKey -Path ([string]$t.AfterPath)
                }
                else
                {
                    $null
                }
                if ([string]::IsNullOrWhiteSpace($beforePath) -and [string]::IsNullOrWhiteSpace($afterPath))
                {
                    continue
                }

                $isBinary = $false
                foreach ($bp in @($beforePath, $afterPath))
                {
                    if (-not $bp)
                    {
                        continue
                    }
                    if ($c.FileDiffStats.ContainsKey($bp))
                    {
                        $d = $c.FileDiffStats[$bp]
                        if ($null -ne $d -and $d.PSObject.Properties.Match('IsBinary') -and [bool]$d.IsBinary)
                        {
                            $isBinary = $true
                        }
                    }
                }
                if ($isBinary)
                {
                    continue
                }

                $metricFile = if ($afterPath)
                {
                    Resolve-PathByRenameMap -FilePath $afterPath -RenameMap $RenameMap
                }
                else
                {
                    Resolve-PathByRenameMap -FilePath $beforePath -RenameMap $RenameMap
                }

                $prevLines = @()
                if ($beforePath)
                {
                    $prevBlame = Get-SvnBlameLine -Repo $TargetUrl -FilePath $beforePath -Revision ($rev - 1) -CacheDir $CacheDir
                    $prevLines = @($prevBlame.Lines)
                }
                $currLines = @()
                if ($afterPath)
                {
                    $currBlame = Get-SvnBlameLine -Repo $TargetUrl -FilePath $afterPath -Revision $rev -CacheDir $CacheDir
                    $currLines = @($currBlame.Lines)
                }

                $cmp = Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines
                $moveCount = @($cmp.MovedPairs).Count
                if ($moveCount -gt 0)
                {
                    Add-Count -Table $authorInternalMove -Key $killer -Delta $moveCount
                    Add-Count -Table $fileInternalMove -Key $metricFile -Delta $moveCount
                }

                foreach ($born in @($cmp.BornLines))
                {
                    $line = $born.Line
                    $bornRev = $null
                    try
                    {
                        $bornRev = [int]$line.Revision
                    }
                    catch
                    {
                        $bornRev = $null
                    }
                    if ($null -eq $bornRev -or $bornRev -ne $rev)
                    {
                        continue
                    }
                    if ($bornRev -lt $FromRevision -or $bornRev -gt $ToRevision)
                    {
                        continue
                    }
                    $bornAuthor = Get-NormalizedAuthorName -Author ([string]$line.Author)
                    Add-Count -Table $authorBorn -Key $bornAuthor
                    Add-Count -Table $authorSurvived -Key $bornAuthor
                    Add-Count -Table $fileBorn -Key $metricFile
                    Add-Count -Table $fileSurvived -Key $metricFile
                }

                foreach ($killed in @($cmp.KilledLines))
                {
                    $line = $killed.Line
                    $bornRev = $null
                    try
                    {
                        $bornRev = [int]$line.Revision
                    }
                    catch
                    {
                        $bornRev = $null
                    }
                    if ($null -eq $bornRev -or $bornRev -lt $FromRevision -or $bornRev -gt $ToRevision)
                    {
                        continue
                    }
                    $bornAuthor = Get-NormalizedAuthorName -Author ([string]$line.Author)
                    Add-Count -Table $authorDead -Key $bornAuthor
                    Add-Count -Table $fileDead -Key $metricFile
                    Add-Count -Table $authorSurvived -Key $bornAuthor -Delta (-1)
                    Add-Count -Table $fileSurvived -Key $metricFile -Delta (-1)
                    if ($bornAuthor -eq $killer)
                    {
                        Add-Count -Table $authorSelfDead -Key $bornAuthor
                        Add-Count -Table $fileSelfCancel -Key $metricFile
                    }
                    else
                    {
                        Add-Count -Table $authorOtherDead -Key $bornAuthor
                        Add-Count -Table $authorCrossRevert -Key $bornAuthor
                        Add-Count -Table $authorRemovedByOthers -Key $bornAuthor
                        Add-Count -Table $fileCrossRevert -Key $metricFile
                        Add-Count -Table $authorModifiedOthersCode -Key $killer
                        $null = $revsWhereKilledOthers.Add(([string]$rev + [char]31 + $killer))
                    }
                }
            }
            catch
            {
                throw ("Strict blame attribution failed at r{0} (before='{1}', after='{2}'): {3}" -f $rev, [string]$t.BeforePath, [string]$t.AfterPath, $_.Exception.Message)
            }
        }
    }

    try
    {
        $strictHunk = Get-StrictHunkDetail -Commits $Commits -RevToAuthor $RevToAuthor -RenameMap $RenameMap
    }
    catch
    {
        throw ("Strict hunk analysis failed: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    }
    return [pscustomobject]@{
        AuthorBorn = $authorBorn
        AuthorDead = $authorDead
        AuthorSurvived = $authorSurvived
        AuthorSelfDead = $authorSelfDead
        AuthorOtherDead = $authorOtherDead
        AuthorCrossRevert = $authorCrossRevert
        AuthorRemovedByOthers = $authorRemovedByOthers
        FileBorn = $fileBorn
        FileDead = $fileDead
        FileSurvived = $fileSurvived
        FileSelfCancel = $fileSelfCancel
        FileCrossRevert = $fileCrossRevert
        AuthorInternalMoveCount = $authorInternalMove
        FileInternalMoveCount = $fileInternalMove
        AuthorRepeatedHunk = $strictHunk.AuthorRepeatedHunk
        AuthorPingPong = $strictHunk.AuthorPingPong
        FileRepeatedHunk = $strictHunk.FileRepeatedHunk
        FilePingPong = $strictHunk.FilePingPong
        AuthorModifiedOthersCode = $authorModifiedOthersCode
        RevsWhereKilledOthers = $revsWhereKilledOthers
    }
}
function Get-CommitterMetric
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits)
    $states = @{}
    $fileAuthors = @{}
    foreach ($c in $Commits)
    {
        $a = [string]$c.Author
        foreach ($f in @($c.FilesChanged))
        {
            if (-not $fileAuthors.ContainsKey($f))
            {
                $fileAuthors[$f] = New-Object 'System.Collections.Generic.HashSet[string]'
            }
            $null = $fileAuthors[$f].Add($a)
        }
    }
    foreach ($c in $Commits)
    {
        $a = [string]$c.Author
        if (-not $states.ContainsKey($a))
        {
            $states[$a] = [ordered]@{
                Author = $a
                CommitCount = 0
                ActiveDays = (New-Object 'System.Collections.Generic.HashSet[string]')
                Files = (New-Object 'System.Collections.Generic.HashSet[string]')
                Dirs = (New-Object 'System.Collections.Generic.HashSet[string]')
                Added = 0
                Deleted = 0
                Binary = 0
                ActA = 0
                ActM = 0
                ActD = 0
                ActR = 0
                MsgLen = 0
                Issue = 0
                Fix = 0
                Revert = 0
                Merge = 0
                FileChurn = @{}
            }
        }
        $s = $states[$a]
        $s.CommitCount++
        if ($c.Date)
        {
            $null = $s.ActiveDays.Add(([datetime]$c.Date).ToString('yyyy-MM-dd'))
        }
        $s.Added += [int]$c.AddedLines
        $s.Deleted += [int]$c.DeletedLines
        $msg = [string]$c.Message
        if ($null -eq $msg)
        {
            $msg = ''
        }
        $s.MsgLen += $msg.Length
        $m = Get-MessageMetricCount -Message $msg
        $s.Issue += $m.IssueIdMentionCount
        $s.Fix += $m.FixKeywordCount
        $s.Revert += $m.RevertKeywordCount
        $s.Merge += $m.MergeKeywordCount
        foreach ($f in @($c.FilesChanged))
        {
            $null = $s.Files.Add($f)
            $idx = $f.LastIndexOf('/')
            $dir = if ($idx -lt 0)
            {
                '.'
            }
            else
            {
                $f.Substring(0, $idx)
            }
            if ($dir)
            {
                $null = $s.Dirs.Add($dir)
            }
            $d = $c.FileDiffStats[$f]
            $ch = [int]$d.AddedLines + [int]$d.DeletedLines
            if (-not $s.FileChurn.ContainsKey($f))
            {
                $s.FileChurn[$f] = 0
            }
            $s.FileChurn[$f] += $ch
            if ([bool]$d.IsBinary)
            {
                $s.Binary++
            }
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            switch (([string]$p.Action).ToUpperInvariant())
            {
                'A'
                {
                    $s.ActA++
                }
                'M'
                {
                    $s.ActM++
                }
                'D'
                {
                    $s.ActD++
                }
                'R'
                {
                    $s.ActR++
                }
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $states.Values)
    {
        $net = [int]$s.Added - [int]$s.Deleted
        $ch = [int]$s.Added + [int]$s.Deleted
        $coAvg = 0.0
        $coMax = 0.0
        if ($s.Files.Count -gt 0)
        {
            $vals = @()
            foreach ($f in $s.Files)
            {
                if ($fileAuthors.ContainsKey($f))
                {
                    $vals += [Math]::Max(0, $fileAuthors[$f].Count - 1)
                }
            }
            if ($vals.Count -gt 0)
            {
                $coAvg = ($vals | Measure-Object -Average).Average
                $coMax = ($vals | Measure-Object -Maximum).Maximum
            }
        }
        $entropy = Get-Entropy -Values @($s.FileChurn.Values | ForEach-Object { [double]$_ })
        $churnPerCommit = if ($s.CommitCount -gt 0)
        {
            $ch / [double]$s.CommitCount
        }
        else
        {
            0
        }
        $msgLenAvg = if ($s.CommitCount -gt 0)
        {
            $s.MsgLen / [double]$s.CommitCount
        }
        else
        {
            0
        }
        $rows.Add([pscustomobject][ordered]@{
                '作者' = [string]$s.Author
                'コミット数' = [int]$s.CommitCount
                '活動日数' = [int]$s.ActiveDays.Count
                '変更ファイル数' = [int]$s.Files.Count
                '変更ディレクトリ数' = [int]$s.Dirs.Count
                '追加行数' = [int]$s.Added
                '削除行数' = [int]$s.Deleted
                '純増行数' = $net
                '総チャーン' = $ch
                'コミットあたりチャーン' = Format-MetricValue -Value $churnPerCommit
                '削除対追加比' = if ([int]$s.Added -gt 0)
                {
                    Format-MetricValue -Value ([int]$s.Deleted / [double]$s.Added)
                }
                else
                {
                    $null
                }
                'チャーン対純増比' = if ([Math]::Abs($net) -gt 0)
                {
                    Format-MetricValue -Value ($ch / [double][Math]::Abs($net))
                }
                else
                {
                    $null
                }
                'バイナリ変更回数' = [int]$s.Binary
                '追加アクション数' = [int]$s.ActA
                '変更アクション数' = [int]$s.ActM
                '削除アクション数' = [int]$s.ActD
                '置換アクション数' = [int]$s.ActR
                '生存行数' = $null
                $script:ColDeadAdded = $null
                '所有行数' = $null
                '所有割合' = $null
                '自己相殺行数' = $null
                '自己差戻行数' = $null
                '他者差戻行数' = $null
                '被他者削除行数' = $null
                '同一箇所反復編集数' = $null
                'ピンポン回数' = $null
                '内部移動行数' = $null
                $script:ColSelfDead = $null
                $script:ColOtherDead = $null
                '他者コード変更行数' = $null
                '他者コード変更生存行数' = $null
                '変更エントロピー' = Format-MetricValue -Value $entropy
                '平均共同作者数' = Format-MetricValue -Value $coAvg
                '最大共同作者数' = [int]$coMax
                'メッセージ総文字数' = [int]$s.MsgLen
                'メッセージ平均文字数' = Format-MetricValue -Value $msgLenAvg
                '課題ID言及数' = [int]$s.Issue
                '修正キーワード数' = [int]$s.Fix
                '差戻キーワード数' = [int]$s.Revert
                'マージキーワード数' = [int]$s.Merge
            }) | Out-Null
    }
    return @($rows.ToArray() | Sort-Object -Property @{Expression = '総チャーン'
            Descending = $true
        }, '作者')
}
function Get-FileMetric
{
    [CmdletBinding()]param([object[]]$Commits)
    $states = @{}
    foreach ($c in $Commits)
    {
        $author = [string]$c.Author
        $files = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in @($c.FilesChanged))
        {
            $null = $files.Add([string]$f)
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            $null = $files.Add([string]$p.Path)
        }
        foreach ($f in $files)
        {
            if (-not $states.ContainsKey($f))
            {
                $states[$f] = [ordered]@{ FilePath = $f
                    Commits = (New-Object 'System.Collections.Generic.HashSet[int]')
                    Authors = (New-Object 'System.Collections.Generic.HashSet[string]')
                    Dates = (New-Object 'System.Collections.Generic.List[datetime]')
                    Added = 0
                    Deleted = 0
                    Binary = 0
                    Create = 0
                    Delete = 0
                    Replace = 0
                    AuthorChurn = @{}
                }
            }
            $s = $states[$f]
            $added = $s.Commits.Add([int]$c.Revision)
            if ($added -and $c.Date)
            {
                $null = $s.Dates.Add([datetime]$c.Date)
            }
            $null = $s.Authors.Add($author)
        }
        foreach ($f in @($c.FilesChanged))
        {
            $s = $states[$f]
            $d = $c.FileDiffStats[$f]
            $a = [int]$d.AddedLines
            $del = [int]$d.DeletedLines
            $s.Added += $a
            $s.Deleted += $del
            if ([bool]$d.IsBinary)
            {
                $s.Binary++
            }
            if (-not $s.AuthorChurn.ContainsKey($author))
            {
                $s.AuthorChurn[$author] = 0
            }
            $s.AuthorChurn[$author] += ($a + $del)
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            $s = $states[[string]$p.Path]
            switch (([string]$p.Action).ToUpperInvariant())
            {
                'A'
                {
                    $s.Create++
                }
                'D'
                {
                    $s.Delete++
                }
                'R'
                {
                    $s.Replace++
                }
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $states.Values)
    {
        $cc = [int]$s.Commits.Count
        $add = [int]$s.Added
        $del = [int]$s.Deleted
        $ch = $add + $del
        $first = $null
        $last = $null
        if ($cc -gt 0)
        {
            $first = ($s.Commits | Measure-Object -Minimum).Minimum
            $last = ($s.Commits | Measure-Object -Maximum).Maximum
        }
        $avg = 0.0
        if ($s.Dates.Count -gt 1)
        {
            $dates = @($s.Dates | Sort-Object -Unique)
            $vals = @()
            for ($i = 1
                $i -lt $dates.Count
                $i++)
            {
                $vals += (New-TimeSpan -Start $dates[$i - 1] -End $dates[$i]).TotalDays
            }
            if ($vals.Count -gt 0)
            {
                $avg = ($vals | Measure-Object -Average).Average
            }
        }
        $topShare = 0.0
        if ($ch -gt 0 -and $s.AuthorChurn.Count -gt 0)
        {
            $mx = ($s.AuthorChurn.Values | Measure-Object -Maximum).Maximum
            $topShare = $mx / [double]$ch
        }
        $rows.Add([pscustomobject][ordered]@{
                'ファイルパス' = [string]$s.FilePath
                'コミット数' = $cc
                '作者数' = [int]$s.Authors.Count
                '追加行数' = $add
                '削除行数' = $del
                '純増行数' = ($add - $del)
                '総チャーン' = $ch
                'バイナリ変更回数' = [int]$s.Binary
                '作成回数' = [int]$s.Create
                '削除回数' = [int]$s.Delete
                '置換回数' = [int]$s.Replace
                '初回変更リビジョン' = $first
                '最終変更リビジョン' = $last
                '平均変更間隔日数' = Format-MetricValue -Value $avg
                '生存行数 (範囲指定)' = $null
                $script:ColDeadAdded = $null
                '最多作者チャーン占有率' = Format-MetricValue -Value $topShare
                '最多作者blame占有率' = $null
                '自己相殺行数 (合計)' = $null
                '他者差戻行数 (合計)' = $null
                '同一箇所反復編集数 (合計)' = $null
                'ピンポン回数 (合計)' = $null
                '内部移動行数 (合計)' = $null
                'ホットスポットスコア' = ($cc * $ch)
                'ホットスポット順位' = 0
            }) | Out-Null
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'ホットスポットスコア'
            Descending = $true
        }, @{Expression = '総チャーン'
            Descending = $true
        }, 'ファイルパス')
    $rank = 0
    foreach ($r in $sorted)
    {
        $rank++
        $r.'ホットスポット順位' = $rank
    }
    return $sorted
}
function Get-CoChangeMetric
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits, [int]$TopNCount = 50)
    $pair = @{}
    $fileCount = @{}
    $commitTotal = 0
    foreach ($c in $Commits)
    {
        $files = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in @($c.FilesChanged))
        {
            $null = $files.Add([string]$f)
        }
        if ($files.Count -eq 0)
        {
            continue
        }
        $commitTotal++
        foreach ($f in $files)
        {
            if (-not $fileCount.ContainsKey($f))
            {
                $fileCount[$f] = 0
            }
            $fileCount[$f]++
        }
        $list = @($files | Sort-Object)
        for ($i = 0
            $i -lt ($list.Count - 1)
            $i++)
        {
            for ($j = $i + 1
                $j -lt $list.Count
                $j++)
            {
                $k = $list[$i] + [char]31 + $list[$j]
                if (-not $pair.ContainsKey($k))
                {
                    $pair[$k] = 0
                }
                $pair[$k]++
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $pair.Keys)
    {
        $p = $k -split [char]31, 2
        $a = $p[0]
        $b = $p[1]
        $co = [int]$pair[$k]
        $ca = [int]$fileCount[$a]
        $cb = [int]$fileCount[$b]
        $j = 0.0
        $den = ($ca + $cb - $co)
        if ($den -gt 0)
        {
            $j = $co / [double]$den
        }
        $lift = 0.0
        if ($commitTotal -gt 0 -and $ca -gt 0 -and $cb -gt 0)
        {
            $pab = $co / [double]$commitTotal
            $pa = $ca / [double]$commitTotal
            $pb = $cb / [double]$commitTotal
            if (($pa * $pb) -gt 0)
            {
                $lift = $pab / ($pa * $pb)
            }
        }
        $rows.Add([pscustomobject][ordered]@{ 'ファイルA' = $a
                'ファイルB' = $b
                '共変更回数' = $co
                'Jaccard' = Format-MetricValue -Value $j
                'リフト値' = Format-MetricValue -Value $lift
            }) | Out-Null
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = '共変更回数'
            Descending = $true
        }, @{Expression = 'Jaccard'
            Descending = $true
        }, @{Expression = 'リフト値'
            Descending = $true
        }, 'ファイルA', 'ファイルB')
    if ($TopNCount -gt 0)
    {
        return @($sorted | Select-Object -First $TopNCount)
    }
    return $sorted
}
function Write-PlantUmlFile
{
    param([string]$OutDirectory, [object[]]$Committers, [object[]]$Files, [object[]]$Couplings, [int]$TopNCount, [string]$EncodingName)
    $topCommitters = @($Committers | Sort-Object -Property @{Expression = '総チャーン'
            Descending = $true
        }, '作者' | Select-Object -First $TopNCount)
    $topFiles = @($Files | Sort-Object -Property 'ホットスポット順位' | Select-Object -First $TopNCount)
    $topCouplings = @($Couplings | Sort-Object -Property @{Expression = '共変更回数'
            Descending = $true
        }, @{Expression = 'Jaccard'
            Descending = $true
        } | Select-Object -First $TopNCount)

    $sb1 = New-Object System.Text.StringBuilder
    [void]$sb1.AppendLine('@startuml')
    [void]$sb1.AppendLine(''' NOTE: This PlantUML shows top N entries only. See CSV files for complete data.')
    [void]$sb1.AppendLine(''' StrictMode is enabled - all metric values are exact where mathematically definable.')
    [void]$sb1.AppendLine('salt')
    [void]$sb1.AppendLine('{')
    [void]$sb1.AppendLine('{T')
    [void]$sb1.AppendLine('+ 作者 | コミット数 | 総チャーン')
    foreach ($r in $topCommitters)
    {
        [void]$sb1.AppendLine(("| {0} | {1} | {2}" -f ([string]$r.'作者').Replace('|', '\|'), $r.'コミット数', $r.'総チャーン'))
    }
    [void]$sb1.AppendLine('}')
    [void]$sb1.AppendLine('}')
    [void]$sb1.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'contributors_summary.puml') -Content $sb1.ToString() -EncodingName $EncodingName

    $sb2 = New-Object System.Text.StringBuilder
    [void]$sb2.AppendLine('@startuml')
    [void]$sb2.AppendLine(''' NOTE: This PlantUML shows top N entries only. See CSV files for complete data.')
    [void]$sb2.AppendLine(''' StrictMode is enabled - all metric values are exact where mathematically definable.')
    [void]$sb2.AppendLine('salt')
    [void]$sb2.AppendLine('{')
    [void]$sb2.AppendLine('{T')
    [void]$sb2.AppendLine('+ ホットスポット順位 | ファイルパス | ホットスポットスコア')
    foreach ($r in $topFiles)
    {
        [void]$sb2.AppendLine(("| {0} | {1} | {2}" -f $r.'ホットスポット順位', ([string]$r.'ファイルパス').Replace('|', '\|'), $r.'ホットスポットスコア'))
    }
    [void]$sb2.AppendLine('}')
    [void]$sb2.AppendLine('}')
    [void]$sb2.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'hotspots.puml') -Content $sb2.ToString() -EncodingName $EncodingName

    $sb3 = New-Object System.Text.StringBuilder
    [void]$sb3.AppendLine('@startuml')
    [void]$sb3.AppendLine(''' NOTE: This PlantUML shows top N entries only. See CSV files for complete data.')
    [void]$sb3.AppendLine(''' StrictMode is enabled - all metric values are exact where mathematically definable.')
    [void]$sb3.AppendLine('left to right direction')
    [void]$sb3.AppendLine('skinparam linetype ortho')
    foreach ($r in $topCouplings)
    {
        [void]$sb3.AppendLine(('"{0}" -- "{1}" : co={2}\nj={3}' -f ([string]$r.'ファイルA').Replace('"', '\"'), ([string]$r.'ファイルB').Replace('"', '\"'), $r.'共変更回数', $r.'Jaccard'))
    }
    [void]$sb3.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'cochange_network.puml') -Content $sb3.ToString() -EncodingName $EncodingName
}
function Get-DeadLineDetail
{
    [CmdletBinding()]
    param(
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [int]$DetailLevel = 1,
        [hashtable]$RenameMap = @{}
    )
    $authorSelfCancel = @{}
    $authorCrossRevert = @{}
    $authorRemovedByOthers = @{}
    $fileSelfCancel = @{}
    $fileCrossRevert = @{}
    $authorRepeatedHunk = @{}
    $authorPingPong = @{}
    $fileRepeatedHunk = @{}
    $filePingPong = @{}
    $addedMultiset = @{}
    $hunkAuthorCount = @{}
    $hunkEvents = @{}
    $fileInternalMoveCount = @{}
    $authorInternalMoveCount = @{}
    $sorted = @($Commits | Sort-Object Revision)
    foreach ($c in $sorted)
    {
        $rev = [int]$c.Revision
        $cAuthor = if ($RevToAuthor.ContainsKey($rev))
        {
            [string]$RevToAuthor[$rev]
        }
        else
        {
            [string]$c.Author
        }
        foreach ($f in @($c.FilesChanged))
        {
            $d = $c.FileDiffStats[$f]
            if ($null -eq $d)
            {
                continue
            }
            $resolvedFile = $f
            if ($RenameMap.ContainsKey($f))
            {
                $resolvedFile = [string]$RenameMap[$f]
            }
            $fileAddedHashes = @()
            $fileDeletedHashes = @()
            if ($d.PSObject.Properties.Match('AddedLineHashes').Count -gt 0 -and $null -ne $d.AddedLineHashes)
            {
                $fileAddedHashes = @($d.AddedLineHashes)
            }
            if ($d.PSObject.Properties.Match('DeletedLineHashes').Count -gt 0 -and $null -ne $d.DeletedLineHashes)
            {
                $fileDeletedHashes = @($d.DeletedLineHashes)
            }
            if ($DetailLevel -ge 2 -and $fileAddedHashes.Count -gt 0 -and $fileDeletedHashes.Count -gt 0)
            {
                $addSet = @{}
                foreach ($ah in $fileAddedHashes)
                {
                    if (-not $addSet.ContainsKey($ah))
                    {
                        $addSet[$ah] = 0
                    }
                    $addSet[$ah]++
                }
                $delSet = @{}
                foreach ($dh in $fileDeletedHashes)
                {
                    if (-not $delSet.ContainsKey($dh))
                    {
                        $delSet[$dh] = 0
                    }
                    $delSet[$dh]++
                }
                $moveCount = 0
                foreach ($mk in $addSet.Keys)
                {
                    if ($delSet.ContainsKey($mk))
                    {
                        $moveCount += [Math]::Min([int]$addSet[$mk], [int]$delSet[$mk])
                    }
                }
                if ($moveCount -gt 0)
                {
                    if (-not $fileInternalMoveCount.ContainsKey($resolvedFile))
                    {
                        $fileInternalMoveCount[$resolvedFile] = 0
                    }
                    $fileInternalMoveCount[$resolvedFile] += $moveCount
                    if (-not $authorInternalMoveCount.ContainsKey($cAuthor))
                    {
                        $authorInternalMoveCount[$cAuthor] = 0
                    }
                    $authorInternalMoveCount[$cAuthor] += $moveCount
                }
            }
            foreach ($delHash in $fileDeletedHashes)
            {
                $key = $resolvedFile + [char]31 + $delHash
                if ($addedMultiset.ContainsKey($key))
                {
                    $queue = $addedMultiset[$key]
                    if ($queue.Count -gt 0)
                    {
                        $origAuthor = [string]$queue[0]
                        $queue.RemoveAt(0)
                        if ($origAuthor -eq $cAuthor)
                        {
                            if (-not $authorSelfCancel.ContainsKey($cAuthor))
                            {
                                $authorSelfCancel[$cAuthor] = 0
                            }
                            $authorSelfCancel[$cAuthor]++
                            if (-not $fileSelfCancel.ContainsKey($resolvedFile))
                            {
                                $fileSelfCancel[$resolvedFile] = 0
                            }
                            $fileSelfCancel[$resolvedFile]++
                        }
                        else
                        {
                            if (-not $authorCrossRevert.ContainsKey($origAuthor))
                            {
                                $authorCrossRevert[$origAuthor] = 0
                            }
                            $authorCrossRevert[$origAuthor]++
                            if (-not $authorRemovedByOthers.ContainsKey($origAuthor))
                            {
                                $authorRemovedByOthers[$origAuthor] = 0
                            }
                            $authorRemovedByOthers[$origAuthor]++
                            if (-not $fileCrossRevert.ContainsKey($resolvedFile))
                            {
                                $fileCrossRevert[$resolvedFile] = 0
                            }
                            $fileCrossRevert[$resolvedFile]++
                        }
                        if ($queue.Count -eq 0)
                        {
                            $addedMultiset.Remove($key)
                        }
                    }
                }
            }
            foreach ($addHash in $fileAddedHashes)
            {
                $key = $resolvedFile + [char]31 + $addHash
                if (-not $addedMultiset.ContainsKey($key))
                {
                    $addedMultiset[$key] = New-Object 'System.Collections.Generic.List[string]'
                }
                $addedMultiset[$key].Add($cAuthor)
            }
            if ($DetailLevel -ge 2)
            {
                foreach ($hunk in @($d.Hunks))
                {
                    $ctxHash = $null
                    if ($hunk.PSObject.Properties.Match('ContextHash').Count -gt 0)
                    {
                        $ctxHash = $hunk.ContextHash
                    }
                    if (-not $ctxHash)
                    {
                        continue
                    }
                    $hunkKey = $resolvedFile + [char]31 + $ctxHash
                    $authorHunkKey = $cAuthor + [char]31 + $hunkKey
                    if (-not $hunkAuthorCount.ContainsKey($authorHunkKey))
                    {
                        $hunkAuthorCount[$authorHunkKey] = 0
                    }
                    $hunkAuthorCount[$authorHunkKey]++
                    if (-not $hunkEvents.ContainsKey($hunkKey))
                    {
                        $hunkEvents[$hunkKey] = New-Object 'System.Collections.Generic.List[string]'
                    }
                    $hunkEvents[$hunkKey].Add($cAuthor)
                }
            }
        }
    }
    if ($DetailLevel -ge 2)
    {
        foreach ($ahk in $hunkAuthorCount.Keys)
        {
            $cnt = [int]$hunkAuthorCount[$ahk]
            if ($cnt -gt 1)
            {
                $repeat = $cnt - 1
                $parts = $ahk -split [char]31, 3
                $hAuthor = $parts[0]
                $hFile = $parts[1]
                if (-not $authorRepeatedHunk.ContainsKey($hAuthor))
                {
                    $authorRepeatedHunk[$hAuthor] = 0
                }
                $authorRepeatedHunk[$hAuthor] += $repeat
                if (-not $fileRepeatedHunk.ContainsKey($hFile))
                {
                    $fileRepeatedHunk[$hFile] = 0
                }
                $fileRepeatedHunk[$hFile] += $repeat
            }
        }
        foreach ($hk in $hunkEvents.Keys)
        {
            $evList = @($hunkEvents[$hk])
            $hFile = ($hk -split [char]31, 2)[0]
            if ($evList.Count -ge 3)
            {
                for ($i = 0
                    $i -le ($evList.Count - 3)
                    $i++)
                {
                    $aa = [string]$evList[$i]
                    $bb = [string]$evList[$i + 1]
                    $cc = [string]$evList[$i + 2]
                    if ($aa -ne $bb -and $aa -eq $cc)
                    {
                        if (-not $authorPingPong.ContainsKey($aa))
                        {
                            $authorPingPong[$aa] = 0
                        }
                        $authorPingPong[$aa]++
                        if (-not $filePingPong.ContainsKey($hFile))
                        {
                            $filePingPong[$hFile] = 0
                        }
                        $filePingPong[$hFile]++
                    }
                }
            }
        }
    }
    return [pscustomobject]@{
        AuthorSelfCancel = $authorSelfCancel
        AuthorCrossRevert = $authorCrossRevert
        AuthorRemovedByOthers = $authorRemovedByOthers
        FileSelfCancel = $fileSelfCancel
        FileCrossRevert = $fileCrossRevert
        AuthorRepeatedHunk = $authorRepeatedHunk
        AuthorPingPong = $authorPingPong
        FileRepeatedHunk = $fileRepeatedHunk
        FilePingPong = $filePingPong
        FileInternalMoveCount = $fileInternalMoveCount
        AuthorInternalMoveCount = $authorInternalMoveCount
    }
}
function Get-RenameMap
{
    [CmdletBinding()]
    param([object[]]$Commits)
    $map = @{}
    foreach ($c in ($Commits | Sort-Object Revision))
    {
        foreach ($p in @($c.ChangedPaths))
        {
            if ($null -eq $p)
            {
                continue
            }
            $action = ([string]$p.Action).ToUpperInvariant()
            if (($action -eq 'A' -or $action -eq 'R') -and $p.CopyFromPath)
            {
                $oldPath = ConvertTo-PathKey -Path ([string]$p.CopyFromPath)
                $newPath = ConvertTo-PathKey -Path ([string]$p.Path)
                if ($oldPath -and $newPath -and $oldPath -ne $newPath)
                {
                    $map[$oldPath] = $newPath
                    foreach ($k in @($map.Keys))
                    {
                        if ([string]$map[$k] -eq $oldPath)
                        {
                            $map[$k] = $newPath
                        }
                    }
                }
            }
        }
    }
    return $map
}
# endregion Utility

try
{
    $startedAt = Get-Date
    Initialize-StrictModeContext
    if ($NoBlame)
    {
        throw "-NoBlame is not supported in strict-only mode."
    }
    if ($DeadDetailLevel -lt 2)
    {
        $DeadDetailLevel = 2
    }
    if ($FromRev -gt $ToRev)
    {
        $tmp = $FromRev
        $FromRev = $ToRev
        $ToRev = $tmp
    }
    if (-not $OutDir)
    {
        $OutDir = Join-Path (Get-Location) ("NarutoCode_out_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    # Resolve relative OutDir to absolute path based on PowerShell $PWD
    $OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
    $cacheDir = Join-Path $OutDir 'cache'
    New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null

    $IncludeExtensions = ConvertTo-NormalizedExtension -Extensions $IncludeExtensions
    $ExcludeExtensions = ConvertTo-NormalizedExtension -Extensions $ExcludeExtensions
    $IncludePaths = ConvertTo-NormalizedPatternList -Patterns $IncludePaths
    $ExcludePaths = ConvertTo-NormalizedPatternList -Patterns $ExcludePaths
    if ($IgnoreAllSpace -and $IgnoreSpaceChange)
    {
        $IgnoreSpaceChange = $false
    }

    $svnCmd = Get-Command $SvnExecutable -ErrorAction SilentlyContinue
    if (-not $svnCmd)
    {
        throw "svn executable not found: '$SvnExecutable'. Install Subversion client or specify -SvnExecutable."
    }
    $script:SvnExecutable = $svnCmd.Source
    $ga = New-Object 'System.Collections.Generic.List[string]'
    if ($Username)
    {
        $null = $ga.Add('--username')
        $null = $ga.Add($Username)
    }
    if ($Password)
    {
        $plain = ConvertTo-PlainText -SecureValue $Password
        if ($plain)
        {
            $null = $ga.Add('--password')
            $null = $ga.Add($plain)
        }
    }
    if ($NonInteractive)
    {
        $null = $ga.Add('--non-interactive')
    }
    if ($TrustServerCert)
    {
        $null = $ga.Add('--trust-server-cert')
    }
    $script:SvnGlobalArguments = $ga.ToArray()

    $targetUrl = Resolve-SvnTargetUrl -Target $RepoUrl
    $svnVersion = $null
    try
    {
        $svnVersion = (Invoke-SvnCommand -Arguments @('--version', '--quiet') -ErrorContext 'svn version').Split("`n")[0].Trim()
    }
    catch
    {
        $null = $_
    }

    $logText = Invoke-SvnCommand -Arguments @('log', '--xml', '--verbose', '-r', "$FromRev`:$ToRev", $targetUrl) -ErrorContext 'svn log'
    $commits = @(ConvertFrom-SvnLogXml -XmlText $logText)
    if ($Author)
    {
        if ($Author -match '[\*\?\[]')
        {
            $commits = @($commits | Where-Object { ([string]$_.Author) -like $Author })
        }
        else
        {
            $commits = @($commits | Where-Object { ([string]$_.Author) -ieq $Author })
        }
    }

    $diffArgs = New-Object 'System.Collections.Generic.List[string]'
    $null = $diffArgs.Add('diff')
    $null = $diffArgs.Add('--internal-diff')
    if (-not $IncludeProperties)
    {
        $null = $diffArgs.Add('--ignore-properties')
    }
    if ($ForceBinary)
    {
        $null = $diffArgs.Add('--force')
    }
    $ext = New-Object 'System.Collections.Generic.List[string]'
    if ($IgnoreAllSpace)
    {
        $null = $ext.Add('--ignore-all-space')
    }
    elseif ($IgnoreSpaceChange)
    {
        $null = $ext.Add('--ignore-space-change')
    }
    if ($IgnoreEolStyle)
    {
        $null = $ext.Add('--ignore-eol-style')
    }
    if ($ext.Count -gt 0)
    {
        $null = $diffArgs.Add('--extensions')
        $null = $diffArgs.Add(($ext.ToArray() -join ' '))
    }

    $revToAuthor = @{}
    foreach ($c in $commits)
    {
        $rev = [int]$c.Revision
        $revToAuthor[$rev] = [string]$c.Author
        $cacheFile = Join-Path $cacheDir ("diff_r{0}.txt" -f $rev)
        $diffText = ''
        if (Test-Path $cacheFile)
        {
            $diffText = Get-Content -Path $cacheFile -Raw -Encoding UTF8
        }
        else
        {
            $a = New-Object 'System.Collections.Generic.List[string]'
            foreach ($x in $diffArgs)
            {
                $null = $a.Add([string]$x)
            }
            $null = $a.Add('-c')
            $null = $a.Add([string]$rev)
            $null = $a.Add($targetUrl)
            $diffText = Invoke-SvnCommand -Arguments $a.ToArray() -ErrorContext ("svn diff -c $rev")
            Set-Content -Path $cacheFile -Value $diffText -Encoding UTF8
        }

        $raw = ConvertFrom-SvnUnifiedDiff -DiffText $diffText -DetailLevel $DeadDetailLevel
        $filtered = @{}
        foreach ($path in $raw.Keys)
        {
            if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
            {
                $filtered[$path] = $raw[$path]
            }
        }
        $c.FileDiffStats = $filtered

        $fpaths = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in @($c.ChangedPaths))
        {
            if ($null -eq $p)
            {
                continue
            }
            if ($p.PSObject.Properties.Match('IsDirectory').Count -gt 0 -and [bool]$p.IsDirectory)
            {
                continue
            }
            $path = ConvertTo-PathKey -Path ([string]$p.Path)
            if (-not $path)
            {
                continue
            }
            if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
            {
                $fpaths.Add([pscustomobject]@{Path = $path
                        Action = [string]$p.Action
                        CopyFromPath = [string]$p.CopyFromPath
                        CopyFromRev = $p.CopyFromRev
                        IsDirectory = $false
                    }) | Out-Null
            }
        }
        $c.ChangedPathsFiltered = $fpaths.ToArray()
        $allowedFilePaths = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($fp in @($c.ChangedPathsFiltered))
        {
            $path = ConvertTo-PathKey -Path ([string]$fp.Path)
            if ($path)
            {
                $null = $allowedFilePaths.Add($path)
            }
        }
        $filteredByLog = @{}
        foreach ($key in $c.FileDiffStats.Keys)
        {
            if ($allowedFilePaths.Contains([string]$key))
            {
                $filteredByLog[$key] = $c.FileDiffStats[$key]
            }
        }
        $c.FileDiffStats = $filteredByLog
        $c.FilesChanged = @($c.FileDiffStats.Keys | Sort-Object)

        $deletedSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            if (([string]$p.Action).ToUpperInvariant() -eq 'D')
            {
                $null = $deletedSet.Add((ConvertTo-PathKey -Path ([string]$p.Path)))
            }
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            $action = ([string]$p.Action).ToUpperInvariant()
            if (($action -ne 'A' -and $action -ne 'R') -or [string]::IsNullOrWhiteSpace([string]$p.CopyFromPath))
            {
                continue
            }
            $newPath = ConvertTo-PathKey -Path ([string]$p.Path)
            $oldPath = ConvertTo-PathKey -Path ([string]$p.CopyFromPath)
            if (-not $newPath -or -not $oldPath -or -not $deletedSet.Contains($oldPath))
            {
                continue
            }
            if (-not $c.FileDiffStats.ContainsKey($oldPath) -or -not $c.FileDiffStats.ContainsKey($newPath))
            {
                continue
            }
            $copyRev = $p.CopyFromRev
            if ($null -eq $copyRev)
            {
                $copyRev = $rev - 1
            }

            $cmpArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($x in $diffArgs)
            {
                $cmpArgs.Add([string]$x) | Out-Null
            }
            $cmpArgs.Add(($targetUrl.TrimEnd('/') + '/' + $oldPath + '@' + [string]$copyRev)) | Out-Null
            $cmpArgs.Add(($targetUrl.TrimEnd('/') + '/' + $newPath + '@' + [string]$rev)) | Out-Null
            $realDiff = Invoke-SvnCommand -Arguments $cmpArgs.ToArray() -ErrorContext ("svn diff rename pair r{0} {1}->{2}" -f $rev, $oldPath, $newPath)
            $realParsed = ConvertFrom-SvnUnifiedDiff -DiffText $realDiff -DetailLevel $DeadDetailLevel
            $realStat = $null
            if ($realParsed.ContainsKey($newPath))
            {
                $realStat = $realParsed[$newPath]
            }
            elseif ($realParsed.ContainsKey($oldPath))
            {
                $realStat = $realParsed[$oldPath]
            }
            elseif ($realParsed.Keys.Count -gt 0)
            {
                $firstKey = @($realParsed.Keys | Sort-Object | Select-Object -First 1)[0]
                $realStat = $realParsed[$firstKey]
            }
            if ($null -eq $realStat)
            {
                $realStat = [pscustomobject]@{
                    AddedLines = 0
                    DeletedLines = 0
                    Hunks = @()
                    IsBinary = $false
                    AddedLineHashes = @()
                    DeletedLineHashes = @()
                }
            }

            $newStat = $c.FileDiffStats[$newPath]
            $oldStat = $c.FileDiffStats[$oldPath]
            $newStat.AddedLines = [int]$realStat.AddedLines
            $newStat.DeletedLines = [int]$realStat.DeletedLines
            if ($newStat.PSObject.Properties.Match('Hunks').Count -gt 0)
            {
                $srcHunks = New-Object 'System.Collections.Generic.List[object]'
                if ($realStat.PSObject.Properties.Match('Hunks').Count -gt 0 -and $null -ne $realStat.Hunks)
                {
                    if ($realStat.Hunks -is [System.Collections.IEnumerable] -and -not ($realStat.Hunks -is [string]))
                    {
                        foreach ($h in $realStat.Hunks)
                        {
                            $srcHunks.Add($h) | Out-Null
                        }
                    }
                    else
                    {
                        $srcHunks.Add($realStat.Hunks) | Out-Null
                    }
                }
                $dstHunks = $newStat.Hunks
                if ($dstHunks -is [System.Collections.IList])
                {
                    $dstHunks.Clear()
                    foreach ($h in $srcHunks.ToArray())
                    {
                        $dstHunks.Add($h) | Out-Null
                    }
                }
                else
                {
                    $newStat.Hunks = $srcHunks.ToArray()
                }
            }
            if ($newStat.PSObject.Properties.Match('AddedLineHashes').Count -gt 0)
            {
                $srcAddedHashes = New-Object 'System.Collections.Generic.List[string]'
                if ($realStat.PSObject.Properties.Match('AddedLineHashes').Count -gt 0 -and $null -ne $realStat.AddedLineHashes)
                {
                    if ($realStat.AddedLineHashes -is [System.Collections.IEnumerable] -and -not ($realStat.AddedLineHashes -is [string]))
                    {
                        foreach ($h in $realStat.AddedLineHashes)
                        {
                            $srcAddedHashes.Add([string]$h) | Out-Null
                        }
                    }
                    else
                    {
                        $srcAddedHashes.Add([string]$realStat.AddedLineHashes) | Out-Null
                    }
                }
                $dstAddedHashes = $newStat.AddedLineHashes
                if ($dstAddedHashes -is [System.Collections.IList])
                {
                    $dstAddedHashes.Clear()
                    foreach ($h in $srcAddedHashes.ToArray())
                    {
                        $dstAddedHashes.Add($h) | Out-Null
                    }
                }
                else
                {
                    $newStat.AddedLineHashes = $srcAddedHashes.ToArray()
                }
            }
            if ($newStat.PSObject.Properties.Match('DeletedLineHashes').Count -gt 0)
            {
                $srcDeletedHashes = New-Object 'System.Collections.Generic.List[string]'
                if ($realStat.PSObject.Properties.Match('DeletedLineHashes').Count -gt 0 -and $null -ne $realStat.DeletedLineHashes)
                {
                    if ($realStat.DeletedLineHashes -is [System.Collections.IEnumerable] -and -not ($realStat.DeletedLineHashes -is [string]))
                    {
                        foreach ($h in $realStat.DeletedLineHashes)
                        {
                            $srcDeletedHashes.Add([string]$h) | Out-Null
                        }
                    }
                    else
                    {
                        $srcDeletedHashes.Add([string]$realStat.DeletedLineHashes) | Out-Null
                    }
                }
                $dstDeletedHashes = $newStat.DeletedLineHashes
                if ($dstDeletedHashes -is [System.Collections.IList])
                {
                    $dstDeletedHashes.Clear()
                    foreach ($h in $srcDeletedHashes.ToArray())
                    {
                        $dstDeletedHashes.Add($h) | Out-Null
                    }
                }
                else
                {
                    $newStat.DeletedLineHashes = $srcDeletedHashes.ToArray()
                }
            }
            if ($newStat.PSObject.Properties.Match('IsBinary').Count -gt 0 -and $realStat.PSObject.Properties.Match('IsBinary').Count -gt 0)
            {
                $newStat.IsBinary = [bool]$realStat.IsBinary
            }

            $oldStat.AddedLines = 0
            $oldStat.DeletedLines = 0
            if ($oldStat.PSObject.Properties.Match('Hunks').Count -gt 0)
            {
                if ($oldStat.Hunks -is [System.Collections.IList])
                {
                    $oldStat.Hunks.Clear()
                }
                else
                {
                    $oldStat.Hunks = @()
                }
            }
            if ($oldStat.PSObject.Properties.Match('AddedLineHashes').Count -gt 0)
            {
                if ($oldStat.AddedLineHashes -is [System.Collections.IList])
                {
                    $oldStat.AddedLineHashes.Clear()
                }
                else
                {
                    $oldStat.AddedLineHashes = @()
                }
            }
            if ($oldStat.PSObject.Properties.Match('DeletedLineHashes').Count -gt 0)
            {
                if ($oldStat.DeletedLineHashes -is [System.Collections.IList])
                {
                    $oldStat.DeletedLineHashes.Clear()
                }
                else
                {
                    $oldStat.DeletedLineHashes = @()
                }
            }
        }

        $added = 0
        $deleted = 0
        $ch = @()
        foreach ($f in $c.FilesChanged)
        {
            $d = $c.FileDiffStats[$f]
            $added += [int]$d.AddedLines
            $deleted += [int]$d.DeletedLines
            $ch += ([int]$d.AddedLines + [int]$d.DeletedLines)
        }
        $c.AddedLines = $added
        $c.DeletedLines = $deleted
        $c.Churn = $added + $deleted
        $c.Entropy = Get-Entropy -Values @($ch | ForEach-Object { [double]$_ })
        $msg = [string]$c.Message
        if ($null -eq $msg)
        {
            $msg = ''
        }
        $c.MsgLen = $msg.Length
        $one = ($msg -replace '(\r?\n)+', ' ').Trim()
        if ($one.Length -gt 140)
        {
            $one = $one.Substring(0, 140) + '...'
        }
        $c.MessageShort = $one
    }

    $committerRows = @(Get-CommitterMetric -Commits $commits)
    $fileRows = @(Get-FileMetric -Commits $commits)
    $couplingRows = @(Get-CoChangeMetric -Commits $commits -TopNCount $TopN)
    $commitRows = @(
        $commits | Sort-Object Revision | ForEach-Object {
            [pscustomobject][ordered]@{
                'リビジョン' = [int]$_.Revision
                '日時' = if ($_.Date)
                {
                    ([datetime]$_.Date).ToString('o')
                }
                else
                {
                    $null
                }
                '作者' = [string]$_.Author
                'メッセージ文字数' = [int]$_.MsgLen
                'メッセージ' = [string]$_.MessageShort
                '変更ファイル数' = @($_.FilesChanged).Count
                '追加行数' = [int]$_.AddedLines
                '削除行数' = [int]$_.DeletedLines
                'チャーン' = [int]$_.Churn
                'エントロピー' = (Format-MetricValue -Value ([double]$_.Entropy))
            }
        }
    )

    if ($fileRows.Count -gt 0)
    {
        $renameMap = Get-RenameMap -Commits $commits
        $strictDetail = Get-ExactDeathAttribution -Commits $commits -RevToAuthor $revToAuthor -TargetUrl $targetUrl -FromRevision $FromRev -ToRevision $ToRev -CacheDir $cacheDir -RenameMap $renameMap
        if ($null -eq $strictDetail)
        {
            throw "Strict death attribution returned null."
        }
        $authorSurvived = $strictDetail.AuthorSurvived
        $authorOwned = @{}
        $ownedTotal = 0
        $fileMap = @{}
        foreach ($r in $fileRows)
        {
            $fileMap[[string]$r.'ファイルパス'] = $r
        }

        $blameByFile = @{}
        $ownershipTargets = @(Get-AllRepositoryFile -Repo $targetUrl -Revision $ToRev -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
        $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in $ownershipTargets)
        {
            $null = $existingFileSet.Add([string]$f)
        }
        foreach ($file in $ownershipTargets)
        {
            try
            {
                $b = Get-SvnBlameSummary -Repo $targetUrl -FilePath $file -ToRevision $ToRev -CacheDir $cacheDir
            }
            catch
            {
                throw ("Strict ownership blame failed for '{0}' at r{1}: {2}" -f $file, $ToRev, $_.Exception.Message)
            }
            $blameByFile[$file] = $b
            $ownedTotal += [int]$b.LineCountTotal
            foreach ($a in $b.LineCountByAuthor.Keys)
            {
                Add-Count -Table $authorOwned -Key ([string]$a) -Delta ([int]$b.LineCountByAuthor[$a])
            }
        }

        # Compute authorModifiedOthersSurvived: count lines in the final blame (ToRev)
        # whose (revision, author) pair is in revsWhereKilledOthers.
        $authorModifiedOthersSurvived = @{}
        $revsKilledOthersSet = $strictDetail.RevsWhereKilledOthers
        foreach ($file in $blameByFile.Keys)
        {
            $bData = $blameByFile[$file]
            if ($null -eq $bData -or $null -eq $bData.Lines)
            {
                continue
            }
            foreach ($bLine in @($bData.Lines))
            {
                $bLineRev = $null
                try
                {
                    $bLineRev = [int]$bLine.Revision
                }
                catch
                {
                    continue
                }
                if ($null -eq $bLineRev -or $bLineRev -lt $FromRev -or $bLineRev -gt $ToRev)
                {
                    continue
                }
                $bLineAuthor = Get-NormalizedAuthorName -Author ([string]$bLine.Author)
                $lookupKey = [string]$bLineRev + [char]31 + $bLineAuthor
                if ($revsKilledOthersSet.Contains($lookupKey))
                {
                    Add-Count -Table $authorModifiedOthersSurvived -Key $bLineAuthor
                }
            }
        }

        foreach ($r in $fileRows)
        {
            $fp = [string]$r.'ファイルパス'
            $resolvedFp = Resolve-PathByRenameMap -FilePath $fp -RenameMap $renameMap
            $isOldRenamePath = ($renameMap.ContainsKey($fp) -and ([string]$renameMap[$fp] -ne $fp))
            $metricKey = if ($isOldRenamePath)
            {
                $null
            }
            else
            {
                $resolvedFp
            }

            $b = $null
            $existsAtToRev = $false
            if ($metricKey)
            {
                $existsAtToRev = $existingFileSet.Contains([string]$metricKey)
            }
            $lookupCandidates = if ($existsAtToRev)
            {
                @($metricKey, $fp, $resolvedFp)
            }
            else
            {
                @()
            }
            $lookupErrors = New-Object 'System.Collections.Generic.List[string]'
            foreach ($lookup in $lookupCandidates)
            {
                if (-not $lookup)
                {
                    continue
                }
                if ($blameByFile.ContainsKey($lookup))
                {
                    $b = $blameByFile[$lookup]
                    break
                }
                try
                {
                    $tmpB = Get-SvnBlameSummary -Repo $targetUrl -FilePath $lookup -ToRevision $ToRev -CacheDir $cacheDir
                    $blameByFile[$lookup] = $tmpB
                    $b = $tmpB
                    break
                }
                catch
                {
                    $lookupErrors.Add(([string]$lookup + ': ' + $_.Exception.Message)) | Out-Null
                }
            }
            if ($null -eq $b -and $existsAtToRev)
            {
                throw ("Strict file blame lookup failed for '{0}' at r{1}. Attempts: {2}" -f $metricKey, $ToRev, ($lookupErrors.ToArray() -join ' | '))
            }

            $sur = if ($metricKey -and $strictDetail.FileSurvived.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileSurvived[$metricKey]
            }
            else
            {
                0
            }
            $dead = if ($metricKey -and $strictDetail.FileDead.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileDead[$metricKey]
            }
            else
            {
                0
            }
            $r.'生存行数 (範囲指定)' = $sur
            $r.($script:ColDeadAdded) = $dead

            $fsc = if ($metricKey -and $strictDetail.FileSelfCancel.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileSelfCancel[$metricKey]
            }
            else
            {
                0
            }
            $fcr = if ($metricKey -and $strictDetail.FileCrossRevert.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileCrossRevert[$metricKey]
            }
            else
            {
                0
            }
            $frh = if ($metricKey -and $strictDetail.FileRepeatedHunk.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileRepeatedHunk[$metricKey]
            }
            else
            {
                0
            }
            $fpp = if ($metricKey -and $strictDetail.FilePingPong.ContainsKey($metricKey))
            {
                [int]$strictDetail.FilePingPong[$metricKey]
            }
            else
            {
                0
            }
            $fim = if ($metricKey -and $strictDetail.FileInternalMoveCount.ContainsKey($metricKey))
            {
                [int]$strictDetail.FileInternalMoveCount[$metricKey]
            }
            else
            {
                0
            }
            $r.'自己相殺行数 (合計)' = $fsc
            $r.'他者差戻行数 (合計)' = $fcr
            $r.'同一箇所反復編集数 (合計)' = $frh
            $r.'ピンポン回数 (合計)' = $fpp
            $r.'内部移動行数 (合計)' = $fim

            $mx = 0
            if ($null -ne $b -and $b.LineCountByAuthor.Count -gt 0)
            {
                $mx = ($b.LineCountByAuthor.Values | Measure-Object -Maximum).Maximum
            }
            $topBlameShare = if ($null -ne $b -and $b.LineCountTotal -gt 0)
            {
                $mx / [double]$b.LineCountTotal
            }
            else
            {
                0
            }
            $r.'最多作者blame占有率' = Format-MetricValue -Value $topBlameShare
        }

        foreach ($r in $committerRows)
        {
            $a = [string]$r.'作者'
            $sur = if ($authorSurvived.ContainsKey($a))
            {
                [int]$authorSurvived[$a]
            }
            else
            {
                0
            }
            $own = if ($authorOwned.ContainsKey($a))
            {
                [int]$authorOwned[$a]
            }
            else
            {
                0
            }
            $r.'生存行数' = $sur
            $dead = if ($strictDetail.AuthorDead.ContainsKey($a))
            {
                [int]$strictDetail.AuthorDead[$a]
            }
            else
            {
                0
            }
            $r.($script:ColDeadAdded) = $dead
            $r.'所有行数' = $own
            $ownShare = if ($ownedTotal -gt 0)
            {
                $own / [double]$ownedTotal
            }
            else
            {
                0
            }
            $r.'所有割合' = Format-MetricValue -Value $ownShare

            $sc = if ($strictDetail.AuthorSelfDead.ContainsKey($a))
            {
                [int]$strictDetail.AuthorSelfDead[$a]
            }
            else
            {
                0
            }
            $cr = if ($strictDetail.AuthorOtherDead.ContainsKey($a))
            {
                [int]$strictDetail.AuthorOtherDead[$a]
            }
            else
            {
                0
            }
            $rh = if ($strictDetail.AuthorRepeatedHunk.ContainsKey($a))
            {
                [int]$strictDetail.AuthorRepeatedHunk[$a]
            }
            else
            {
                0
            }
            $pp = if ($strictDetail.AuthorPingPong.ContainsKey($a))
            {
                [int]$strictDetail.AuthorPingPong[$a]
            }
            else
            {
                0
            }
            $im = if ($strictDetail.AuthorInternalMoveCount.ContainsKey($a))
            {
                [int]$strictDetail.AuthorInternalMoveCount[$a]
            }
            else
            {
                0
            }
            $r.'自己相殺行数' = $sc
            $r.'自己差戻行数' = $sc
            $r.'他者差戻行数' = $cr
            $r.'被他者削除行数' = $cr
            $r.'同一箇所反復編集数' = $rh
            $r.'ピンポン回数' = $pp
            $r.'内部移動行数' = $im
            $r.($script:ColSelfDead) = $sc
            $r.($script:ColOtherDead) = $cr

            $moc = if ($strictDetail.AuthorModifiedOthersCode.ContainsKey($a))
            {
                [int]$strictDetail.AuthorModifiedOthersCode[$a]
            }
            else
            {
                0
            }
            $mocs = if ($authorModifiedOthersSurvived.ContainsKey($a))
            {
                [int]$authorModifiedOthersSurvived[$a]
            }
            else
            {
                0
            }
            $r.'他者コード変更行数' = $moc
            $r.'他者コード変更生存行数' = $mocs
        }
    }

    $headersCommitter = @('作者', 'コミット数', '活動日数', '変更ファイル数', '変更ディレクトリ数', '追加行数', '削除行数', '純増行数', '総チャーン', 'コミットあたりチャーン', '削除対追加比', 'チャーン対純増比', 'バイナリ変更回数', '追加アクション数', '変更アクション数', '削除アクション数', '置換アクション数', '生存行数', $script:ColDeadAdded, '所有行数', '所有割合', '自己相殺行数', '自己差戻行数', '他者差戻行数', '被他者削除行数', '同一箇所反復編集数', 'ピンポン回数', '内部移動行数', $script:ColSelfDead, $script:ColOtherDead, '他者コード変更行数', '他者コード変更生存行数', '変更エントロピー', '平均共同作者数', '最大共同作者数', 'メッセージ総文字数', 'メッセージ平均文字数', '課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
    $headersFile = @('ファイルパス', 'コミット数', '作者数', '追加行数', '削除行数', '純増行数', '総チャーン', 'バイナリ変更回数', '作成回数', '削除回数', '置換回数', '初回変更リビジョン', '最終変更リビジョン', '平均変更間隔日数', '生存行数 (範囲指定)', $script:ColDeadAdded, '最多作者チャーン占有率', '最多作者blame占有率', '自己相殺行数 (合計)', '他者差戻行数 (合計)', '同一箇所反復編集数 (合計)', 'ピンポン回数 (合計)', '内部移動行数 (合計)', 'ホットスポットスコア', 'ホットスポット順位')
    $headersCommit = @('リビジョン', '日時', '作者', 'メッセージ文字数', 'メッセージ', '変更ファイル数', '追加行数', '削除行数', 'チャーン', 'エントロピー')
    $headersCoupling = @('ファイルA', 'ファイルB', '共変更回数', 'Jaccard', 'リフト値')

    Write-CsvFile -FilePath (Join-Path $OutDir 'committers.csv') -Rows $committerRows -Headers $headersCommitter -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'files.csv') -Rows $fileRows -Headers $headersFile -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'commits.csv') -Rows $commitRows -Headers $headersCommit -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'couplings.csv') -Rows $couplingRows -Headers $headersCoupling -EncodingName $Encoding
    if ($EmitPlantUml)
    {
        Write-PlantUmlFile -OutDirectory $OutDir -Committers $committerRows -Files $fileRows -Couplings $couplingRows -TopNCount $TopN -EncodingName $Encoding
    }

    $finishedAt = Get-Date
    $meta = [ordered]@{
        StartTime = $startedAt.ToString('o')
        EndTime = $finishedAt.ToString('o')
        DurationSeconds = Format-MetricValue -Value ((New-TimeSpan -Start $startedAt -End $finishedAt).TotalSeconds)
        RepoUrl = $targetUrl
        FromRev = $FromRev
        ToRev = $ToRev
        AuthorFilter = $Author
        SvnExecutable = $script:SvnExecutable
        SvnVersion = $svnVersion
        StrictMode = $true
        NoBlame = [bool]$NoBlame
        DeadDetailLevel = $DeadDetailLevel
        Parallel = $Parallel
        TopN = $TopN
        Encoding = $Encoding
        CommitCount = @($commits).Count
        FileCount = @($fileRows).Count
        OutputDirectory = (Resolve-Path $OutDir).Path
        StrictBlameCallCount = [int]($script:StrictBlameCacheHits + $script:StrictBlameCacheMisses)
        StrictBlameCacheHits = [int]$script:StrictBlameCacheHits
        StrictBlameCacheMisses = [int]$script:StrictBlameCacheMisses
        NonStrictMetrics = @('課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
        NonStrictReason = '正規表現ベースのヒューリスティックであり厳密化不可能'
        Parameters = [ordered]@{ IncludePaths = $IncludePaths
            ExcludePaths = $ExcludePaths
            IncludeExtensions = $IncludeExtensions
            ExcludeExtensions = $ExcludeExtensions
            EmitPlantUml = [bool]$EmitPlantUml
            NonInteractive = [bool]$NonInteractive
            TrustServerCert = [bool]$TrustServerCert
            IgnoreSpaceChange = [bool]$IgnoreSpaceChange
            IgnoreAllSpace = [bool]$IgnoreAllSpace
            IgnoreEolStyle = [bool]$IgnoreEolStyle
            IncludeProperties = [bool]$IncludeProperties
            ForceBinary = [bool]$ForceBinary
        }
        Outputs = [ordered]@{ CommittersCsv = 'committers.csv'
            FilesCsv = 'files.csv'
            CommitsCsv = 'commits.csv'
            CouplingsCsv = 'couplings.csv'
            RunMetaJson = 'run_meta.json'
            ContributorsPlantUml = if ($EmitPlantUml)
            {
                'contributors_summary.puml'
            }
            else
            {
                $null
            }
            HotspotsPlantUml = if ($EmitPlantUml)
            {
                'hotspots.puml'
            }
            else
            {
                $null
            }
            CoChangePlantUml = if ($EmitPlantUml)
            {
                'cochange_network.puml'
            }
            else
            {
                $null
            }
        }
    }
    Write-JsonFile -Data $meta -FilePath (Join-Path $OutDir 'run_meta.json') -Depth 12 -EncodingName $Encoding

    $phaseLabel = 'StrictMode'
    Write-Host ''
    Write-Host ("===== NarutoCode {0} =====" -f $phaseLabel)
    Write-Host ("Repo         : {0}" -f $targetUrl)
    Write-Host ("Range        : r{0} -> r{1}" -f $FromRev, $ToRev)
    Write-Host ("Commits      : {0}" -f @($commits).Count)
    Write-Host ("Files        : {0}" -f @($fileRows).Count)
    Write-Host ("OutDir       : {0}" -f (Resolve-Path $OutDir).Path)

    [pscustomobject]@{ OutDir = (Resolve-Path $OutDir).Path
        Committers = $committerRows
        Files = $fileRows
        Commits = $commitRows
        Couplings = $couplingRows
        RunMeta = [pscustomobject]$meta
    }
}
catch
{
    Write-Error ("{0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}
