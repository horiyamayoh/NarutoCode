<#
.SYNOPSIS
NarutoCode Phase 1 implementation.
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
    [switch]$NoProgress
)

# Suppress progress output when -NoProgress is specified
if ($NoProgress)
{
    $ProgressPreference = 'SilentlyContinue'
}

# region Utility
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
        }; $x = $e.Trim(); if ($x.StartsWith('.'))
        {
            $x = $x.Substring(1)
        }; $x = $x.ToLowerInvariant(); if ($x)
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
        }; $x = $p.Trim(); if ($x)
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
        $lines = $Rows | ConvertTo-Csv -NoTypeInformation
    }
    elseif ($Headers -and $Headers.Count -gt 0)
    {
        $obj = [ordered]@{}; foreach ($h in $Headers)
        {
            $obj[$h] = $null
        }; $tmp = [pscustomobject]$obj | ConvertTo-Csv -NoTypeInformation; $lines = @($tmp[0])
    }
    $content = ''; if ($lines.Count -gt 0)
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
    $x = $x.TrimStart('/'); if ($x.StartsWith('./'))
    {
        $x = $x.Substring(2)
    }
    return $x
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
        $ok = $false; foreach ($p in $IncludePathPatterns)
        {
            if ($path -like $p)
            {
                $ok = $true; break
            }
        }; if (-not $ok)
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
        }; return $true
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
        }; $t = [string]$a; if ($t -match '[\s"]')
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
    $all = New-Object 'System.Collections.Generic.List[string]'; foreach ($a in $Arguments)
    {
        $null = $all.Add([string]$a)
    }; if ($script:SvnGlobalArguments)
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
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $process = New-Object System.Diagnostics.Process; $process.StartInfo = $psi
        $null = $process.Start(); $out = $process.StandardOutput.ReadToEnd(); $err = $process.StandardError.ReadToEnd(); $process.WaitForExit()
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
    $idx = $Text.IndexOf('<?xml'); if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<log')
    }; if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<info')
    }; if ($idx -lt 0)
    {
        $idx = $Text.IndexOf('<diff')
    }; if ($idx -lt 0)
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
    $entries = @(); if ($xml -and $xml.log -and $xml.log.logentry)
    {
        $entries = @($xml.log.logentry)
    }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $entries)
    {
        $rev = 0; try
        {
            $rev = [int]$e.revision
        }
        catch
        {
            $null = $_
        }
        $authorNode = $e.SelectSingleNode('author'); $author = if ($authorNode)
        {
            [string]$authorNode.InnerText
        }
        else
        {
            ''
        }; if ([string]::IsNullOrWhiteSpace($author))
        {
            $author = '(unknown)'
        }
        $date = $null; $dateText = [string]$e.date; if ($dateText)
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
                    $null = $_; $date = $null
                }
            }
        }
        $msg = [string]$e.msg
        $paths = New-Object 'System.Collections.Generic.List[object]'
        $pathNodes = @(); if ($e.paths -and $e.paths.path)
        {
            $pathNodes = @($e.paths.path)
        }
        foreach ($p in $pathNodes)
        {
            $raw = [string]$p.'#text'; if ([string]::IsNullOrWhiteSpace($raw))
            {
                continue
            }
            $path = ConvertTo-PathKey -Path $raw; if (-not $path)
            {
                continue
            }
            $copyPath = $null; if ($p.HasAttribute('copyfrom-path'))
            {
                $copyPath = ConvertTo-PathKey -Path ($p.GetAttribute('copyfrom-path'))
            }
            $copyRev = $null; if ($p.HasAttribute('copyfrom-rev'))
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
            $paths.Add([pscustomobject]@{ Path = $path; Action = [string]$p.action; CopyFromPath = $copyPath; CopyFromRev = $copyRev; IsDirectory = $raw.Trim().EndsWith('/') }) | Out-Null
        }
        $list.Add([pscustomobject]@{
                Revision = $rev; Author = $author; Date = $date; Message = $msg
                ChangedPaths = $paths.ToArray(); ChangedPathsFiltered = @()
                FileDiffStats = @{}; FilesChanged = @(); AddedLines = 0; DeletedLines = 0; Churn = 0; Entropy = 0.0; MsgLen = 0; MessageShort = ''
            }) | Out-Null
    }
    return $list.ToArray() | Sort-Object Revision
}
function ConvertFrom-SvnUnifiedDiff
{
    [CmdletBinding()]param([string]$DiffText)
    $result = @{}
    if ([string]::IsNullOrEmpty($DiffText))
    {
        return $result
    }
    $lines = $DiffText -split "`r?`n"
    $current = $null
    foreach ($line in $lines)
    {
        if ($line -like 'Index: *')
        {
            $file = ConvertTo-PathKey -Path $line.Substring(7).Trim()
            if ($file)
            {
                if (-not $result.ContainsKey($file))
                {
                    $result[$file] = [pscustomobject]@{ AddedLines = 0; DeletedLines = 0; Hunks = (New-Object 'System.Collections.Generic.List[object]'); IsBinary = $false }
                }; $current = $result[$file]
            }
            continue
        }
        if ($null -eq $current)
        {
            continue
        }
        if ($line -match '^@@\s*-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s*@@')
        {
            $current.Hunks.Add([pscustomobject]@{ OldStart = [int]$Matches[1]; OldCount = if ($Matches[2])
                    {
                        [int]$Matches[2]
                    }
                    else
                    {
                        1
                    }; NewStart = [int]$Matches[3]; NewCount = if ($Matches[4])
                    {
                        [int]$Matches[4]
                    }
                    else
                    {
                        1
                    }
                }) | Out-Null
            continue
        }
        if ($line -match '^Cannot display: file marked as a binary type\.' -or $line -match '^Binary files .* differ')
        {
            $current.IsBinary = $true; continue
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
            $current.AddedLines++; continue
        }
        if ($line[0] -eq '-')
        {
            $current.DeletedLines++; continue
        }
    }
    return $result
}
function ConvertFrom-SvnBlameXml
{
    [CmdletBinding()]param([string]$XmlText)
    $xml = ConvertFrom-SvnXmlText -Text $XmlText -ContextLabel 'svn blame'
    $entries = @(); if ($xml -and $xml.blame -and $xml.blame.target -and $xml.blame.target.entry)
    {
        $entries = @($xml.blame.target.entry)
    }
    $byRev = @{}; $byAuthor = @{}; $total = 0
    foreach ($entry in $entries)
    {
        $total++
        $commit = $entry.commit; if ($null -eq $commit)
        {
            continue
        }
        $rev = $null; try
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
            }; $byRev[$rev]++
        }
        $author = [string]$commit.author; if ([string]::IsNullOrWhiteSpace($author))
        {
            $author = '(unknown)'
        }
        if (-not $byAuthor.ContainsKey($author))
        {
            $byAuthor[$author] = 0
        }; $byAuthor[$author]++
    }
    return [pscustomobject]@{ LineCountTotal = $total; LineCountByRevision = $byRev; LineCountByAuthor = $byAuthor }
}
function Get-Entropy
{
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0)
    {
        return 0.0
    }
    $sum = 0.0; foreach ($v in $Values)
    {
        $sum += [double]$v
    }
    if ($sum -le 0)
    {
        return 0.0
    }
    $e = 0.0; foreach ($v in $Values)
    {
        $x = [double]$v; if ($x -le 0)
        {
            continue
        }; $p = $x / $sum; $e += (-1.0) * $p * ([Math]::Log($p, 2.0))
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
    [CmdletBinding()]param([string]$Repo, [string]$FilePath, [int]$ToRevision)
    $url = $Repo.TrimEnd('/') + '/' + (ConvertTo-PathKey -Path $FilePath).TrimStart('/') + '@' + [string]$ToRevision
    $text = Invoke-SvnCommand -Arguments @('blame', '--xml', '-r', [string]$ToRevision, $url) -ErrorContext ("svn blame $FilePath")
    ConvertFrom-SvnBlameXml -XmlText $text
}
function Get-CommitterMetric
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits)
    $states = @{}; $fileAuthors = @{}
    foreach ($c in $Commits)
    {
        $a = [string]$c.Author; foreach ($f in @($c.FilesChanged))
        {
            if (-not $fileAuthors.ContainsKey($f))
            {
                $fileAuthors[$f] = New-Object 'System.Collections.Generic.HashSet[string]'
            }; $null = $fileAuthors[$f].Add($a)
        }
    }
    foreach ($c in $Commits)
    {
        $a = [string]$c.Author
        if (-not $states.ContainsKey($a))
        {
            $states[$a] = [ordered]@{
                Author = $a; CommitCount = 0; ActiveDays = (New-Object 'System.Collections.Generic.HashSet[string]'); Files = (New-Object 'System.Collections.Generic.HashSet[string]'); Dirs = (New-Object 'System.Collections.Generic.HashSet[string]')
                Added = 0; Deleted = 0; Binary = 0; ActA = 0; ActM = 0; ActD = 0; ActR = 0
                MsgLen = 0; Issue = 0; Fix = 0; Revert = 0; Merge = 0; FileChurn = @{}
            }
        }
        $s = $states[$a]
        $s.CommitCount++; if ($c.Date)
        {
            $null = $s.ActiveDays.Add(([datetime]$c.Date).ToString('yyyy-MM-dd'))
        }
        $s.Added += [int]$c.AddedLines; $s.Deleted += [int]$c.DeletedLines
        $msg = [string]$c.Message; if ($null -eq $msg)
        {
            $msg = ''
        }; $s.MsgLen += $msg.Length
        $m = Get-MessageMetricCount -Message $msg; $s.Issue += $m.IssueIdMentionCount; $s.Fix += $m.FixKeywordCount; $s.Revert += $m.RevertKeywordCount; $s.Merge += $m.MergeKeywordCount
        foreach ($f in @($c.FilesChanged))
        {
            $null = $s.Files.Add($f)
            $idx = $f.LastIndexOf('/'); $dir = if ($idx -lt 0)
            {
                '.'
            }
            else
            {
                $f.Substring(0, $idx)
            }; if ($dir)
            {
                $null = $s.Dirs.Add($dir)
            }
            $d = $c.FileDiffStats[$f]; $ch = [int]$d.AddedLines + [int]$d.DeletedLines
            if (-not $s.FileChurn.ContainsKey($f))
            {
                $s.FileChurn[$f] = 0
            }; $s.FileChurn[$f] += $ch
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
                }; 'M'
                {
                    $s.ActM++
                }; 'D'
                {
                    $s.ActD++
                }; 'R'
                {
                    $s.ActR++
                }
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $states.Values)
    {
        $net = [int]$s.Added - [int]$s.Deleted; $ch = [int]$s.Added + [int]$s.Deleted
        $coAvg = 0.0; $coMax = 0.0
        if ($s.Files.Count -gt 0)
        {
            $vals = @(); foreach ($f in $s.Files)
            {
                if ($fileAuthors.ContainsKey($f))
                {
                    $vals += [Math]::Max(0, $fileAuthors[$f].Count - 1)
                }
            }; if ($vals.Count -gt 0)
            {
                $coAvg = ($vals | Measure-Object -Average).Average; $coMax = ($vals | Measure-Object -Maximum).Maximum
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
                Author = [string]$s.Author; CommitCount = [int]$s.CommitCount; ActiveDays = [int]$s.ActiveDays.Count; FilesTouched = [int]$s.Files.Count; DirsTouched = [int]$s.Dirs.Count
                AddedLines = [int]$s.Added; DeletedLines = [int]$s.Deleted; NetLines = $net; TotalChurn = $ch
                ChurnPerCommit = Get-RoundedNumber -Value $churnPerCommit
                DeletedToAddedRatio = Get-RoundedNumber -Value ([int]$s.Deleted / [double][Math]::Max(1, [int]$s.Added))
                ChurnToNetRatio = Get-RoundedNumber -Value ($ch / [double][Math]::Max(1, [Math]::Abs($net)))
                BinaryChangeCount = [int]$s.Binary; ActionAddCount = [int]$s.ActA; ActionModCount = [int]$s.ActM; ActionDelCount = [int]$s.ActD; ActionRepCount = [int]$s.ActR
                SurvivedLinesToToRev = $null; DeadAddedLinesApprox = $null; OwnedLinesToToRev = $null; OwnershipShareToToRev = $null
                AuthorChangeEntropy = Get-RoundedNumber -Value $entropy; AvgCoAuthorsPerTouchedFile = Get-RoundedNumber -Value $coAvg; MaxCoAuthorsPerTouchedFile = [int]$coMax
                MsgLenTotalChars = [int]$s.MsgLen; MsgLenAvgChars = Get-RoundedNumber -Value $msgLenAvg
                IssueIdMentionCount = [int]$s.Issue; FixKeywordCount = [int]$s.Fix; RevertKeywordCount = [int]$s.Revert; MergeKeywordCount = [int]$s.Merge
            }) | Out-Null
    }
    return @($rows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'; Descending = $true }, Author)
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
                $states[$f] = [ordered]@{ FilePath = $f; Commits = (New-Object 'System.Collections.Generic.HashSet[int]'); Authors = (New-Object 'System.Collections.Generic.HashSet[string]'); Dates = (New-Object 'System.Collections.Generic.List[datetime]'); Added = 0; Deleted = 0; Binary = 0; Create = 0; Delete = 0; Replace = 0; AuthorChurn = @{} }
            }
            $s = $states[$f]; $added = $s.Commits.Add([int]$c.Revision); if ($added -and $c.Date)
            {
                $null = $s.Dates.Add([datetime]$c.Date)
            }; $null = $s.Authors.Add($author)
        }
        foreach ($f in @($c.FilesChanged))
        {
            $s = $states[$f]; $d = $c.FileDiffStats[$f]; $a = [int]$d.AddedLines; $del = [int]$d.DeletedLines; $s.Added += $a; $s.Deleted += $del; if ([bool]$d.IsBinary)
            {
                $s.Binary++
            }; if (-not $s.AuthorChurn.ContainsKey($author))
            {
                $s.AuthorChurn[$author] = 0
            }; $s.AuthorChurn[$author] += ($a + $del)
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            $s = $states[[string]$p.Path]; switch (([string]$p.Action).ToUpperInvariant())
            {
                'A'
                {
                    $s.Create++
                }; 'D'
                {
                    $s.Delete++
                }; 'R'
                {
                    $s.Replace++
                }
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $states.Values)
    {
        $cc = [int]$s.Commits.Count; $add = [int]$s.Added; $del = [int]$s.Deleted; $ch = $add + $del
        $first = $null; $last = $null; if ($cc -gt 0)
        {
            $first = ($s.Commits | Measure-Object -Minimum).Minimum; $last = ($s.Commits | Measure-Object -Maximum).Maximum
        }
        $avg = 0.0; if ($s.Dates.Count -gt 1)
        {
            $dates = @($s.Dates | Sort-Object -Unique); $vals = @(); for ($i = 1; $i -lt $dates.Count; $i++)
            {
                $vals += (New-TimeSpan -Start $dates[$i - 1] -End $dates[$i]).TotalDays
            }; if ($vals.Count -gt 0)
            {
                $avg = ($vals | Measure-Object -Average).Average
            }
        }
        $topShare = 0.0; if ($ch -gt 0 -and $s.AuthorChurn.Count -gt 0)
        {
            $mx = ($s.AuthorChurn.Values | Measure-Object -Maximum).Maximum; $topShare = $mx / [double]$ch
        }
        $rows.Add([pscustomobject][ordered]@{
                FilePath = [string]$s.FilePath; FileCommitCount = $cc; FileAuthors = [int]$s.Authors.Count; AddedLines = $add; DeletedLines = $del; NetLines = ($add - $del); TotalChurn = $ch; BinaryChangeCount = [int]$s.Binary
                CreateCount = [int]$s.Create; DeleteCount = [int]$s.Delete; ReplaceCount = [int]$s.Replace; FirstChangeRev = $first; LastChangeRev = $last; AvgDaysBetweenChanges = Get-RoundedNumber -Value $avg
                SurvivedLinesFromRangeToToRev = $null; DeadAddedLinesApprox = $null; TopAuthorShareByChurn = Get-RoundedNumber -Value $topShare; TopAuthorShareByBlame = $null; HotspotScore = ($cc * $ch); RankByHotspot = 0
            }) | Out-Null
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'HotspotScore'; Descending = $true }, @{Expression = 'TotalChurn'; Descending = $true }, FilePath)
    $rank = 0; foreach ($r in $sorted)
    {
        $rank++; $r.RankByHotspot = $rank
    }
    return $sorted
}
function Get-CoChangeMetric
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits, [int]$TopNCount = 50, [int]$LargeCommitFileThreshold = 100)
    $pair = @{}; $fileCount = @{}; $commitTotal = 0
    foreach ($c in $Commits)
    {
        $files = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($f in @($c.FilesChanged))
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
            }; $fileCount[$f]++
        }
        if ($files.Count -gt $LargeCommitFileThreshold)
        {
            continue
        }
        $list = @($files | Sort-Object)
        for ($i = 0; $i -lt ($list.Count - 1); $i++)
        {
            for ($j = $i + 1; $j -lt $list.Count; $j++)
            {
                $k = $list[$i] + [char]31 + $list[$j]; if (-not $pair.ContainsKey($k))
                {
                    $pair[$k] = 0
                }; $pair[$k]++
            }
        }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $pair.Keys)
    {
        $p = $k -split [char]31, 2; $a = $p[0]; $b = $p[1]; $co = [int]$pair[$k]; $ca = [int]$fileCount[$a]; $cb = [int]$fileCount[$b]
        $j = 0.0; $den = ($ca + $cb - $co); if ($den -gt 0)
        {
            $j = $co / [double]$den
        }
        $lift = 0.0; if ($commitTotal -gt 0 -and $ca -gt 0 -and $cb -gt 0)
        {
            $pab = $co / [double]$commitTotal; $pa = $ca / [double]$commitTotal; $pb = $cb / [double]$commitTotal; if (($pa * $pb) -gt 0)
            {
                $lift = $pab / ($pa * $pb)
            }
        }
        $rows.Add([pscustomobject][ordered]@{ FileA = $a; FileB = $b; CoChangeCount = $co; Jaccard = Get-RoundedNumber -Value $j; Lift = Get-RoundedNumber -Value $lift }) | Out-Null
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'CoChangeCount'; Descending = $true }, @{Expression = 'Jaccard'; Descending = $true }, @{Expression = 'Lift'; Descending = $true }, FileA, FileB)
    if ($TopNCount -gt 0)
    {
        return @($sorted | Select-Object -First $TopNCount)
    }
    return $sorted
}
function Write-PlantUmlFile
{
    param([string]$OutDirectory, [object[]]$Committers, [object[]]$Files, [object[]]$Couplings, [int]$TopNCount, [string]$EncodingName)
    $topCommitters = @($Committers | Sort-Object -Property @{Expression = 'TotalChurn'; Descending = $true }, Author | Select-Object -First $TopNCount)
    $topFiles = @($Files | Sort-Object -Property RankByHotspot | Select-Object -First $TopNCount)
    $topCouplings = @($Couplings | Sort-Object -Property @{Expression = 'CoChangeCount'; Descending = $true }, @{Expression = 'Jaccard'; Descending = $true } | Select-Object -First $TopNCount)

    $sb1 = New-Object System.Text.StringBuilder
    [void]$sb1.AppendLine('@startuml'); [void]$sb1.AppendLine('salt'); [void]$sb1.AppendLine('{'); [void]$sb1.AppendLine('{T'); [void]$sb1.AppendLine('+ Author | CommitCount | TotalChurn')
    foreach ($r in $topCommitters)
    {
        [void]$sb1.AppendLine(("| {0} | {1} | {2}" -f ([string]$r.Author).Replace('|', '\|'), $r.CommitCount, $r.TotalChurn))
    }
    [void]$sb1.AppendLine('}'); [void]$sb1.AppendLine('}'); [void]$sb1.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'contributors_summary.puml') -Content $sb1.ToString() -EncodingName $EncodingName

    $sb2 = New-Object System.Text.StringBuilder
    [void]$sb2.AppendLine('@startuml'); [void]$sb2.AppendLine('salt'); [void]$sb2.AppendLine('{'); [void]$sb2.AppendLine('{T'); [void]$sb2.AppendLine('+ Rank | FilePath | HotspotScore')
    foreach ($r in $topFiles)
    {
        [void]$sb2.AppendLine(("| {0} | {1} | {2}" -f $r.RankByHotspot, ([string]$r.FilePath).Replace('|', '\|'), $r.HotspotScore))
    }
    [void]$sb2.AppendLine('}'); [void]$sb2.AppendLine('}'); [void]$sb2.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'hotspots.puml') -Content $sb2.ToString() -EncodingName $EncodingName

    $sb3 = New-Object System.Text.StringBuilder
    [void]$sb3.AppendLine('@startuml'); [void]$sb3.AppendLine('left to right direction'); [void]$sb3.AppendLine('skinparam linetype ortho')
    foreach ($r in $topCouplings)
    {
        [void]$sb3.AppendLine(('"{0}" -- "{1}" : co={2}\nj={3}' -f ([string]$r.FileA).Replace('"', '\"'), ([string]$r.FileB).Replace('"', '\"'), $r.CoChangeCount, $r.Jaccard))
    }
    [void]$sb3.AppendLine('@enduml')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'cochange_network.puml') -Content $sb3.ToString() -EncodingName $EncodingName
}
# endregion Utility

try
{
    $startedAt = Get-Date
    if ($FromRev -gt $ToRev)
    {
        $tmp = $FromRev; $FromRev = $ToRev; $ToRev = $tmp
    }
    if (-not $OutDir)
    {
        $OutDir = Join-Path (Get-Location) ("NarutoCode_out_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    $cacheDir = Join-Path $OutDir 'cache'; New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null

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
        $null = $ga.Add('--username'); $null = $ga.Add($Username)
    }
    if ($Password)
    {
        $plain = ConvertTo-PlainText -SecureValue $Password; if ($plain)
        {
            $null = $ga.Add('--password'); $null = $ga.Add($plain)
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
    $svnVersion = $null; try
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

    $diffArgs = New-Object 'System.Collections.Generic.List[string]'; $null = $diffArgs.Add('diff'); $null = $diffArgs.Add('--internal-diff')
    if (-not $IncludeProperties)
    {
        $null = $diffArgs.Add('--ignore-properties')
    }
    if ($ForceBinary)
    {
        $null = $diffArgs.Add('--force')
    }
    $ext = New-Object 'System.Collections.Generic.List[string]'; if ($IgnoreAllSpace)
    {
        $null = $ext.Add('--ignore-all-space')
    }
    elseif ($IgnoreSpaceChange)
    {
        $null = $ext.Add('--ignore-space-change')
    }; if ($IgnoreEolStyle)
    {
        $null = $ext.Add('--ignore-eol-style')
    }
    if ($ext.Count -gt 0)
    {
        $null = $diffArgs.Add('--extensions'); $null = $diffArgs.Add(($ext.ToArray() -join ' '))
    }

    $revToAuthor = @{}
    foreach ($c in $commits)
    {
        $rev = [int]$c.Revision; $revToAuthor[$rev] = [string]$c.Author
        $cacheFile = Join-Path $cacheDir ("diff_r{0}.txt" -f $rev)
        $diffText = ''
        if (Test-Path $cacheFile)
        {
            $diffText = Get-Content -Path $cacheFile -Raw -Encoding UTF8
        }
        else
        {
            $a = New-Object 'System.Collections.Generic.List[string]'; foreach ($x in $diffArgs)
            {
                $null = $a.Add([string]$x)
            }; $null = $a.Add('-c'); $null = $a.Add([string]$rev); $null = $a.Add($targetUrl)
            $diffText = Invoke-SvnCommand -Arguments $a.ToArray() -ErrorContext ("svn diff -c $rev")
            Set-Content -Path $cacheFile -Value $diffText -Encoding UTF8
        }

        $raw = ConvertFrom-SvnUnifiedDiff -DiffText $diffText
        $filtered = @{}
        foreach ($path in $raw.Keys)
        {
            if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
            {
                $filtered[$path] = $raw[$path]
            }
        }
        $c.FileDiffStats = $filtered; $c.FilesChanged = @($filtered.Keys | Sort-Object)

        $fpaths = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in @($c.ChangedPaths))
        {
            if ($null -eq $p)
            {
                continue
            }; if ($p.PSObject.Properties.Match('IsDirectory').Count -gt 0 -and [bool]$p.IsDirectory)
            {
                continue
            }
            $path = ConvertTo-PathKey -Path ([string]$p.Path); if (-not $path)
            {
                continue
            }
            if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
            {
                $fpaths.Add([pscustomobject]@{Path = $path; Action = [string]$p.Action; CopyFromPath = [string]$p.CopyFromPath; CopyFromRev = $p.CopyFromRev; IsDirectory = $false }) | Out-Null
            }
        }
        $c.ChangedPathsFiltered = $fpaths.ToArray()

        $added = 0; $deleted = 0; $ch = @()
        foreach ($f in $c.FilesChanged)
        {
            $d = $c.FileDiffStats[$f]; $added += [int]$d.AddedLines; $deleted += [int]$d.DeletedLines; $ch += ([int]$d.AddedLines + [int]$d.DeletedLines)
        }
        $c.AddedLines = $added; $c.DeletedLines = $deleted; $c.Churn = $added + $deleted; $c.Entropy = Get-Entropy -Values @($ch | ForEach-Object { [double]$_ })
        $msg = [string]$c.Message; if ($null -eq $msg)
        {
            $msg = ''
        }; $c.MsgLen = $msg.Length; $one = ($msg -replace '(\r?\n)+', ' ').Trim(); if ($one.Length -gt 140)
        {
            $one = $one.Substring(0, 140) + '...'
        }; $c.MessageShort = $one
    }

    $committerRows = @(Get-CommitterMetric -Commits $commits)
    $fileRows = @(Get-FileMetric -Commits $commits)
    $couplingRows = @(Get-CoChangeMetric -Commits $commits -TopNCount $TopN)
    $commitRows = @(
        $commits | Sort-Object Revision | ForEach-Object {
            [pscustomobject][ordered]@{
                Revision = [int]$_.Revision
                Date = if ($_.Date)
                {
                    ([datetime]$_.Date).ToString('o')
                }
                else
                {
                    $null
                }
                Author = [string]$_.Author
                MsgLen = [int]$_.MsgLen
                Message = [string]$_.MessageShort
                FilesChangedCount = @($_.FilesChanged).Count
                AddedLines = [int]$_.AddedLines
                DeletedLines = [int]$_.DeletedLines
                Churn = [int]$_.Churn
                Entropy = (Get-RoundedNumber -Value ([double]$_.Entropy))
            }
        }
    )

    if (-not $NoBlame -and $fileRows.Count -gt 0)
    {
        $authorSurvived = @{}; $authorOwned = @{}; $ownedTotal = 0
        $fileMap = @{}; foreach ($r in $fileRows)
        {
            $fileMap[[string]$r.FilePath] = $r
        }
        foreach ($file in @($fileMap.Keys))
        {
            try
            {
                $b = Get-SvnBlameSummary -Repo $targetUrl -FilePath $file -ToRevision $ToRev
            }
            catch
            {
                continue
            }
            $ownedTotal += [int]$b.LineCountTotal
            foreach ($a in $b.LineCountByAuthor.Keys)
            {
                if (-not $authorOwned.ContainsKey($a))
                {
                    $authorOwned[$a] = 0
                }; $authorOwned[$a] += [int]$b.LineCountByAuthor[$a]
            }
            $surv = 0; foreach ($rk in $b.LineCountByRevision.Keys)
            {
                $rv = [int]$rk; $cnt = [int]$b.LineCountByRevision[$rk]; if ($rv -lt $FromRev -or $rv -gt $ToRev)
                {
                    continue
                }; $surv += $cnt; $sa = '(unknown)'; if ($revToAuthor.ContainsKey($rv))
                {
                    $sa = [string]$revToAuthor[$rv]
                }; if (-not $authorSurvived.ContainsKey($sa))
                {
                    $authorSurvived[$sa] = 0
                }; $authorSurvived[$sa] += $cnt
            }
            $fr = $fileMap[$file]
            $fr.SurvivedLinesFromRangeToToRev = $surv
            $dead = [int]$fr.AddedLines - $surv
            if ($dead -lt 0)
            {
                $dead = 0
            }
            $fr.DeadAddedLinesApprox = $dead
            $mx = 0
            if ($b.LineCountByAuthor.Count -gt 0)
            {
                $mx = ($b.LineCountByAuthor.Values | Measure-Object -Maximum).Maximum
            }
            $topBlameShare = if ($b.LineCountTotal -gt 0)
            {
                $mx / [double]$b.LineCountTotal
            }
            else
            {
                0
            }
            $fr.TopAuthorShareByBlame = Get-RoundedNumber -Value $topBlameShare
        }
        foreach ($r in $committerRows)
        {
            $a = [string]$r.Author
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
            $r.SurvivedLinesToToRev = $sur
            $dead = [int]$r.AddedLines - $sur
            if ($dead -lt 0)
            {
                $dead = 0
            }
            $r.DeadAddedLinesApprox = $dead
            $r.OwnedLinesToToRev = $own
            $ownShare = if ($ownedTotal -gt 0)
            {
                $own / [double]$ownedTotal
            }
            else
            {
                0
            }
            $r.OwnershipShareToToRev = Get-RoundedNumber -Value $ownShare
        }
        foreach ($r in $fileRows)
        {
            if ($null -eq $r.SurvivedLinesFromRangeToToRev)
            {
                $r.SurvivedLinesFromRangeToToRev = 0; $r.DeadAddedLinesApprox = [int]$r.AddedLines; $r.TopAuthorShareByBlame = 0.0
            }
        }
    }

    $headersCommitter = @('Author', 'CommitCount', 'ActiveDays', 'FilesTouched', 'DirsTouched', 'AddedLines', 'DeletedLines', 'NetLines', 'TotalChurn', 'ChurnPerCommit', 'DeletedToAddedRatio', 'ChurnToNetRatio', 'BinaryChangeCount', 'ActionAddCount', 'ActionModCount', 'ActionDelCount', 'ActionRepCount', 'SurvivedLinesToToRev', 'DeadAddedLinesApprox', 'OwnedLinesToToRev', 'OwnershipShareToToRev', 'AuthorChangeEntropy', 'AvgCoAuthorsPerTouchedFile', 'MaxCoAuthorsPerTouchedFile', 'MsgLenTotalChars', 'MsgLenAvgChars', 'IssueIdMentionCount', 'FixKeywordCount', 'RevertKeywordCount', 'MergeKeywordCount')
    $headersFile = @('FilePath', 'FileCommitCount', 'FileAuthors', 'AddedLines', 'DeletedLines', 'NetLines', 'TotalChurn', 'BinaryChangeCount', 'CreateCount', 'DeleteCount', 'ReplaceCount', 'FirstChangeRev', 'LastChangeRev', 'AvgDaysBetweenChanges', 'SurvivedLinesFromRangeToToRev', 'DeadAddedLinesApprox', 'TopAuthorShareByChurn', 'TopAuthorShareByBlame', 'HotspotScore', 'RankByHotspot')
    $headersCommit = @('Revision', 'Date', 'Author', 'MsgLen', 'Message', 'FilesChangedCount', 'AddedLines', 'DeletedLines', 'Churn', 'Entropy')
    $headersCoupling = @('FileA', 'FileB', 'CoChangeCount', 'Jaccard', 'Lift')

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
        StartTime = $startedAt.ToString('o'); EndTime = $finishedAt.ToString('o'); DurationSeconds = Get-RoundedNumber -Value ((New-TimeSpan -Start $startedAt -End $finishedAt).TotalSeconds) -Digits 3
        RepoUrl = $targetUrl; FromRev = $FromRev; ToRev = $ToRev; AuthorFilter = $Author; SvnExecutable = $script:SvnExecutable; SvnVersion = $svnVersion
        NoBlame = [bool]$NoBlame; Parallel = $Parallel; TopN = $TopN; Encoding = $Encoding; CommitCount = @($commits).Count; FileCount = @($fileRows).Count; OutputDirectory = (Resolve-Path $OutDir).Path
        Parameters = [ordered]@{ IncludePaths = $IncludePaths; ExcludePaths = $ExcludePaths; IncludeExtensions = $IncludeExtensions; ExcludeExtensions = $ExcludeExtensions; EmitPlantUml = [bool]$EmitPlantUml; NonInteractive = [bool]$NonInteractive; TrustServerCert = [bool]$TrustServerCert; IgnoreSpaceChange = [bool]$IgnoreSpaceChange; IgnoreAllSpace = [bool]$IgnoreAllSpace; IgnoreEolStyle = [bool]$IgnoreEolStyle; IncludeProperties = [bool]$IncludeProperties; ForceBinary = [bool]$ForceBinary }
        Outputs = [ordered]@{ CommittersCsv = 'committers.csv'; FilesCsv = 'files.csv'; CommitsCsv = 'commits.csv'; CouplingsCsv = 'couplings.csv'; RunMetaJson = 'run_meta.json'; ContributorsPlantUml = if ($EmitPlantUml)
            {
                'contributors_summary.puml'
            }
            else
            {
                $null
            }; HotspotsPlantUml = if ($EmitPlantUml)
            {
                'hotspots.puml'
            }
            else
            {
                $null
            }; CoChangePlantUml = if ($EmitPlantUml)
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

    Write-Host ''; Write-Host '===== NarutoCode Phase 1 ====='; Write-Host ("Repo         : {0}" -f $targetUrl); Write-Host ("Range        : r{0} -> r{1}" -f $FromRev, $ToRev); Write-Host ("Commits      : {0}" -f @($commits).Count); Write-Host ("Files        : {0}" -f @($fileRows).Count); Write-Host ("OutDir       : {0}" -f (Resolve-Path $OutDir).Path)

    [pscustomobject]@{ OutDir = (Resolve-Path $OutDir).Path; Committers = $committerRows; Files = $fileRows; Commits = $commitRows; Couplings = $couplingRows; RunMeta = [pscustomobject]$meta }
}
catch
{
    Write-Error $_
    exit 1
}
