<#
.SYNOPSIS
Count SVN diff size (added/deleted lines, files changed) in a revision range.

.DESCRIPTION
指定したリビジョン範囲の差分規模を集計します。

指定した Author(ユーザー) がコミットした各 revision について
`svn diff -c <rev>` を実行し、追加行/削除行を合算します。

PowerShell 5.1 を想定しています。

.PARAMETER Path
SVN リポジトリ URL（http/https/svn スキーム）。
ローカルの Working Copy パスは非対応です。必ずリポジトリURLを指定してください。

.PARAMETER FromRevision
開始リビジョン番号 (例: 200)。Alias: Pre, Start, StartRevision, From

.PARAMETER ToRevision
終了リビジョン番号 (例: 250)。Alias: Post, End, EndRevision, To

.PARAMETER Author
SVN の author 名。未指定の場合は author でフィルタせず全件対象にします。Alias: Name, User

.PARAMETER SvnExecutable
svn コマンドのパス。既定: svn

.PARAMETER IgnoreSpaceChange
空白の「量の変更」を無視します(インデント変更などを抑制)。Subversion の diff オプションとして --ignore-space-change を使用します。

.PARAMETER IgnoreAllSpace
空白の違いをすべて無視します。IgnoreSpaceChange より強いです。--ignore-all-space を使用します。

.PARAMETER IgnoreEolStyle
改行コード差分を無視します。--ignore-eol-style を使用します。

.PARAMETER IncludeProperties
既定ではプロパティ差分は無視します(--ignore-properties)。
このスイッチを付けるとプロパティ差分も出力/解析対象にします（※行数計測はテキスト差分中心のため推奨しません）。

.PARAMETER ForceBinary
バイナリ扱いのファイルでも diff を強制表示します(--force)。テキストなのに mime-type が binary になっている場合などに。

.PARAMETER IncludeExtensions
指定した拡張子のファイルのみ行数をカウントします（例: cs, ps1, cpp）。
ドット有無はどちらでも OK です。

.PARAMETER ExcludeExtensions
指定した拡張子のファイルは行数カウント対象から外します。

.PARAMETER ExcludePaths
ワイルドカードでパスを除外します（例: */Generated/*, *.min.js）。

.PARAMETER OutputCsv
結果を CSV に出力します。

.PARAMETER OutputJson
結果を JSON に出力します。

.PARAMETER OutputMarkdown
結果を Markdown に出力します。

.PARAMETER ShowPerRevision
コンソールに revision 別の内訳を表示します。

.PARAMETER NoProgress
進捗表示(Write-Progress)を無効化します。

.EXAMPLE
# 例) r200〜r250 のうち Y.Hoge のコミットだけを拾って、各コミットの差分を合算
.\CountSvnDiff.ps1 -Path https://svn.example.com/repos/proj/trunk -FromRevision 200 -ToRevision 250 -Author Y.Hoge

.EXAMPLE
# 例) alias を使う (ユーザー提示の形に寄せた呼び方)
.\CountSvnDiff.ps1 -Path https://svn.example.com/repos/proj/trunk -Pre 200 -Post 250 -Name Y.Hoge

.EXAMPLE
# 例) 範囲全体（全コミット者）の差分を計測し、結果を JSON 出力
.\CountSvnDiff.ps1 -Path https://svn.example.com/repos/proj/trunk -From 200 -To 250 -IgnoreAllSpace -IgnoreEolStyle -OutputJson .\result.json

.EXAMPLE
# 例) リモート URL を指定
.\CountSvnDiff.ps1 -Path https://svn.example.com/repos/project/trunk -From 100 -To 200
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [Alias('Pre', 'Start', 'StartRevision', 'From')]
    [int]$FromRevision,

    [Parameter(Mandatory = $true)]
    [Alias('Post', 'End', 'EndRevision', 'To')]
    [int]$ToRevision,

    [Parameter(Mandatory = $false)]
    [Alias('Name', 'User')]
    [string]$Author,

    [Parameter(Mandatory = $false)]
    [string]$SvnExecutable = 'svn',

    [switch]$IgnoreSpaceChange,
    [switch]$IgnoreAllSpace,
    [switch]$IgnoreEolStyle,
    [switch]$IncludeProperties,
    [switch]$ForceBinary,

    [string[]]$IncludeExtensions,
    [string[]]$ExcludeExtensions,
    [string[]]$ExcludePaths,

    [string]$OutputCsv,
    [string]$OutputJson,
    [string]$OutputMarkdown,

    [switch]$ShowPerRevision,
    [switch]$NoProgress
)

# region Utility

function ConvertTo-NormalizedExtension
{
    param([string[]]$Extensions)

    if (-not $Extensions) { return @() }

    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $Extensions)
    {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        $x = $e.Trim()
        if ($x.StartsWith('.')) { $x = $x.Substring(1) }
        $x = $x.ToLowerInvariant()
        if ($x.Length -gt 0) { $null = $list.Add($x) }
    }
    # unique
    return $list.ToArray() | Select-Object -Unique
}

function Invoke-SvnCommand
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = "SVN command"
    )

    Write-Verbose "Executing: $script:SvnExecutable $($Arguments -join ' ')"

    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:SvnExecutable
        $psi.Arguments = $Arguments -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        # SVN出力は常にUTF-8で処理（日本語環境でもXMLパースを正しく行うため）
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        $null = $process.Start()

        # 同期読み取り（XMLの構造を壊さないため）
        $outputText = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()

        # プロセスが完全に終了するまで待機（タイムアウト設定）
        $timeout = 300000 # 5分
        if (-not $process.WaitForExit($timeout))
        {
            try { $process.Kill() } catch { Write-Verbose "Failed to kill process: $($_.Exception.Message)" }
            throw "$ErrorContext timed out after $($timeout/1000) seconds"
        }

        $exitCode = $process.ExitCode

        Write-Verbose "Exit code: $exitCode"
        Write-Verbose "Output length: $($outputText.Length) chars"
        if ($errorText)
        {
            Write-Verbose "STDERR length: $($errorText.Length) chars"
            Write-Verbose "STDERR output: $errorText"
        }

        # 終了コードが0以外の場合はエラー
        if ($exitCode -ne 0)
        {
            $errorMsg = "$ErrorContext failed (exit code $exitCode)."
            if ($errorText)
            {
                $errorMsg += "`nSTDERR: $errorText"
            }
            if ($outputText)
            {
                $preview = $outputText
                if ($preview.Length -gt 1000) { $preview = $preview.Substring(0, 1000) + "`n...(truncated)" }
                $errorMsg += "`nSTDOUT: $preview"
            }
            throw $errorMsg
        }

        return $outputText
    }
    finally
    {
        if ($process) { $process.Dispose() }
    }
}

function ConvertFrom-SvnXmlText
{
    param([Parameter(Mandatory = $true)][string]$Text, [string]$ContextLabel = 'svn output')

    Write-Verbose "Parsing XML from $ContextLabel (length: $($Text.Length) chars)"

    # svn の警告などで XML の前に余計な行が混ざる可能性があるため、XML 開始位置を探す
    $idx = $Text.IndexOf('<?xml')
    if ($idx -lt 0) { $idx = $Text.IndexOf('<log') }
    if ($idx -lt 0) { $idx = $Text.IndexOf('<info') }
    if ($idx -lt 0) { $idx = $Text.IndexOf('<diff') }

    $xmlText = $Text
    if ($idx -gt 0)
    {
        Write-Verbose "Skipping $idx characters before XML content"
        $xmlText = $Text.Substring($idx)
    }

    Write-Verbose "XML text to parse (length: $($xmlText.Length) chars)"

    # デバッグ: XMLの最初と最後を表示
    if ($xmlText.Length -lt 1000)
    {
        Write-Verbose "XML content (full):`n$xmlText"
    }
    else
    {
        $head = $xmlText.Substring(0, [Math]::Min(500, $xmlText.Length))
        $tail = if ($xmlText.Length -gt 500) { $xmlText.Substring([Math]::Max(0, $xmlText.Length - 500)) } else { "" }
        Write-Verbose "XML content (first 500 chars):`n$head"
        Write-Verbose "XML content (last 500 chars):`n$tail"
    }

    try
    {
        return [xml]$xmlText
    }
    catch
    {
        $preview = $xmlText
        if ($preview.Length -gt 2000)
        {
            $preview = $preview.Substring(0, 1000) + "`n`n... (middle truncated) ...`n`n" + $preview.Substring($preview.Length - 1000)
        }
        throw "Failed to parse XML from $ContextLabel.`n--- Raw (head and tail) ---`n$preview`n--- Error ---`n$($_.Exception.Message)"
    }
}

function Resolve-SvnTargetUrl
{
    param([Parameter(Mandatory = $true)][string]$Target)

    # URLスキームで始まることを確認
    if (-not ($Target -match '^(https?|svn|file)://'))
    {
        throw "Path must be a remote SVN repository URL (http://, https://, svn://, or file://). Local working copy paths are not supported. Provided: '$Target'"
    }

    Write-Verbose "Validating SVN repository URL: $Target"

    # URLが有効かチェック（svn info で確認）
    try
    {
        $infoText = Invoke-SvnCommand -Arguments @('info', '--xml', $Target) -ErrorContext "svn info (validating URL)"
        $xml = ConvertFrom-SvnXmlText -Text $infoText -ContextLabel 'svn info'
        $url = $xml.info.entry.url

        if ([string]::IsNullOrWhiteSpace($url))
        {
            throw "Could not validate repository URL. Target='$Target'"
        }

        Write-Verbose "Validated URL: $url"
        return $url.Trim()
    }
    catch
    {
        throw "Failed to validate SVN URL '$Target': $($_.Exception.Message)"
    }
}

function Test-ShouldCountFile
{
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$IncludeExt,
        [string[]]$ExcludeExt,
        [string[]]$ExcludePathPatterns
    )

    if ($ExcludePathPatterns)
    {
        foreach ($pat in $ExcludePathPatterns)
        {
            if ([string]::IsNullOrWhiteSpace($pat)) { continue }
            if ($FilePath -like $pat) { return $false }
        }
    }

    $ext = [System.IO.Path]::GetExtension($FilePath)
    if ([string]::IsNullOrEmpty($ext))
    {
        # 拡張子なしファイルは IncludeExt 指定時は除外
        if ($IncludeExt -and $IncludeExt.Count -gt 0) { return $false }
        return $true
    }

    $extNorm = $ext.TrimStart('.').ToLowerInvariant()

    if ($IncludeExt -and $IncludeExt.Count -gt 0)
    {
        if (-not ($IncludeExt -contains $extNorm)) { return $false }
    }

    if ($ExcludeExt -and $ExcludeExt.Count -gt 0)
    {
        if ($ExcludeExt -contains $extNorm) { return $false }
    }

    return $true
}

function Measure-SvnDiffStreaming
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DiffArguments,

        [string[]]$IncludeExt,
        [string[]]$ExcludeExt,
        [string[]]$ExcludePathPatterns
    )

    $linesAdded = 0
    $linesDeleted = 0

    $files = New-Object 'System.Collections.Generic.HashSet[string]'
    $binaryFiles = New-Object 'System.Collections.Generic.HashSet[string]'

    $currentFile = $null
    $countThisFile = $true
    $isBinary = $false

    Write-Verbose "Running diff with arguments: $($DiffArguments -join ' ')"

    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:SvnExecutable
        $psi.Arguments = $DiffArguments -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        # SVN出力は常にUTF-8で処理
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        $null = $process.Start()

        # 標準出力を行単位で処理
        while (-not $process.StandardOutput.EndOfStream)
        {
            $line = $process.StandardOutput.ReadLine()

            # file start
            if ($line -like 'Index: *')
            {
                $currentFile = $line.Substring(7).Trim()
                $isBinary = $false
                $countThisFile = $true
                if ($currentFile)
                {
                    $countThisFile = Test-ShouldCountFile -FilePath $currentFile -IncludeExt $IncludeExt -ExcludeExt $ExcludeExt -ExcludePathPatterns $ExcludePathPatterns
                }
                if ($countThisFile -and -not [string]::IsNullOrWhiteSpace($currentFile))
                {
                    $null = $files.Add($currentFile)
                }
                continue
            }

            if (-not $countThisFile) { continue }

            # binary hints
            if ($line -match '^Cannot display: file marked as a binary type\.')
            {
                if ($currentFile) { $null = $binaryFiles.Add($currentFile) }
                $isBinary = $true
                continue
            }
            if ($line -match '^Binary files .* differ')
            {
                if ($currentFile) { $null = $binaryFiles.Add($currentFile) }
                $isBinary = $true
                continue
            }
            if ($isBinary) { continue }

            if ($line.Length -eq 0) { continue }

            # skip diff headers
            if ($line.StartsWith('+++')) { continue }
            if ($line.StartsWith('---')) { continue }

            # count hunks
            $first = $line[0]
            if ($first -eq '+')
            {
                if ($line -eq '+\ No newline at end of file') { continue }
                $linesAdded++
                continue
            }
            if ($first -eq '-')
            {
                if ($line -eq '-\ No newline at end of file') { continue }
                $linesDeleted++
                continue
            }
        }

        # エラー出力を読み取る（ブロックしないように最後に）
        $errorText = $process.StandardError.ReadToEnd()

        $process.WaitForExit()
        $exitCode = $process.ExitCode

        if ($exitCode -ne 0)
        {
            $errorMsg = "svn diff failed (exit code $exitCode)."
            if ($errorText)
            {
                $errorMsg += "`nSTDERR: $errorText"
            }
            throw $errorMsg
        }

        if ($errorText)
        {
            Write-Verbose "svn diff STDERR (non-fatal): $errorText"
        }
    }
    finally
    {
        if ($process) { $process.Dispose() }
    }

    return [pscustomobject]@{
        LinesAdded = $linesAdded
        LinesDeleted = $linesDeleted
        NetLines = ($linesAdded - $linesDeleted)
        TextLinesChanged = ($linesAdded + $linesDeleted)
        FilesChanged = $files.Count
        BinaryFilesChanged = $binaryFiles.Count
        Files = $files
        BinaryFiles = $binaryFiles
    }
}

function Write-FileIfRequested
{
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path $dir))
    {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # PowerShell 5.1: Set-Content -Encoding UTF8 は BOM 付き。問題になる場合は Out-File などに変更してください。
    Set-Content -Path $FilePath -Value $Content -Encoding UTF8
}

# endregion Utility

try
{
    # Normalize / validate
    $IncludeExtensions = ConvertTo-NormalizedExtension -Extensions $IncludeExtensions
    $ExcludeExtensions = ConvertTo-NormalizedExtension -Extensions $ExcludeExtensions

    if ($IgnoreAllSpace -and $IgnoreSpaceChange)
    {
        Write-Verbose "Both -IgnoreAllSpace and -IgnoreSpaceChange specified. Using -IgnoreAllSpace."
        $IgnoreSpaceChange = $false
    }

    if ($FromRevision -gt $ToRevision)
    {
        Write-Verbose "Swapping revisions because FromRevision > ToRevision"
        $tmp = $FromRevision
        $FromRevision = $ToRevision
        $ToRevision = $tmp
    }

    # Check svn existence
    $svnCmd = Get-Command $SvnExecutable -ErrorAction SilentlyContinue
    if (-not $svnCmd)
    {
        throw "svn executable not found: '$SvnExecutable'. Install Subversion client or specify -SvnExecutable."
    }
    $script:SvnExecutable = $svnCmd.Source
    Write-Verbose "Using SVN executable: $script:SvnExecutable"

    # Validate and resolve URL (リモートURLのみ)
    Write-Verbose "Validating repository URL: $Path"
    $targetUrl = Resolve-SvnTargetUrl -Target $Path

    # Build common diff args
    $commonDiffArgs = New-Object 'System.Collections.Generic.List[string]'
    $null = $commonDiffArgs.Add('diff')
    $null = $commonDiffArgs.Add('--internal-diff')

    if (-not $IncludeProperties)
    {
        $null = $commonDiffArgs.Add('--ignore-properties')
    }

    if ($ForceBinary)
    {
        $null = $commonDiffArgs.Add('--force')
    }

    # diff "extensions" args (whitespace/eol ignores)
    $extArgs = New-Object 'System.Collections.Generic.List[string]'
    if ($IgnoreAllSpace) { $null = $extArgs.Add('--ignore-all-space') }
    elseif ($IgnoreSpaceChange) { $null = $extArgs.Add('--ignore-space-change') }
    if ($IgnoreEolStyle) { $null = $extArgs.Add('--ignore-eol-style') }

    if ($extArgs.Count -gt 0)
    {
        # svn diff は -x(--extensions) を複数回受け付けない実装があるため 1 つにまとめて渡す
        $null = $commonDiffArgs.Add('--extensions')
        $null = $commonDiffArgs.Add(($extArgs.ToArray() -join ' '))
    }

    # Fetch log (for commit list / incremental targets)
    Write-Verbose "Fetching SVN log for r$FromRevision`:r$ToRevision"
    $logText = Invoke-SvnCommand -Arguments @('log', $targetUrl, '--xml', '--verbose', '-r', "$FromRevision`:$ToRevision") -ErrorContext "svn log"
    $logXml = ConvertFrom-SvnXmlText -Text $logText -ContextLabel 'svn log'

    $logEntries = @()
    if ($logXml -and $logXml.log -and $logXml.log.logentry)
    {
        $logEntries = @($logXml.log.logentry) | Sort-Object { [int]$_.revision }
    }

    Write-Verbose "Found $($logEntries.Count) log entries in range"

    $filteredEntries = $logEntries
    if (-not [string]::IsNullOrWhiteSpace($Author))
    {
        # wildcard を許可: *Hoge* のような指定もできる
        if ($Author -match '[\*\?\[]')
        {
            $filteredEntries = $logEntries | Where-Object { ([string]$_.author) -like $Author }
        }
        else
        {
            $filteredEntries = $logEntries | Where-Object { ([string]$_.author) -ieq $Author }
        }
        Write-Verbose "Filtered to $($filteredEntries.Count) entries for author: $Author"
    }

    $resultRows = New-Object 'System.Collections.Generic.List[object]'

    $allFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $allBinaryFiles = New-Object 'System.Collections.Generic.HashSet[string]'

    $overall = [ordered]@{
        Path = $Path
        TargetUrl = $targetUrl
        FromRevision = $FromRevision
        ToRevision = $ToRevision
        Author = $Author
        CommitsMatched = $filteredEntries.Count
        LinesAdded = 0
        LinesDeleted = 0
        NetLines = 0
        TextLinesChanged = 0
        FilesChangedUnique = 0
        BinaryFilesChangedUnique = 0
        StartedAt = (Get-Date)
        FinishedAt = $null
        Notes = $null
    }

    # Incremental モード: 各コミットごとにdiffを取得して集計
    if ($filteredEntries.Count -eq 0)
    {
        $overall.Notes = "No matching commits in range."
        Write-Verbose "No matching commits found"
    }
    else
    {
        $total = $filteredEntries.Count
        $i = 0

        foreach ($e in $filteredEntries)
        {
            $i++

            $rev = [int]$e.revision
            $date = $null
            try { $date = [datetime]::Parse([string]$e.date) } catch { $date = $e.date }

            $msg = [string]$e.msg
            if ($msg)
            {
                $msgOneLine = ($msg -replace "(\r?\n)+", " ").Trim()
                if ($msgOneLine.Length -gt 80) { $msgOneLine = $msgOneLine.Substring(0, 80) + '…' }
            }
            else
            {
                $msgOneLine = ''
            }

            $paths = @()
            if ($e.paths -and $e.paths.path) { $paths = @($e.paths.path) }

            $pathsAdded = ($paths | Where-Object { $_.action -eq 'A' }).Count
            $pathsDeleted = ($paths | Where-Object { $_.action -eq 'D' }).Count
            $pathsModified = ($paths | Where-Object { $_.action -eq 'M' }).Count
            $pathsReplaced = ($paths | Where-Object { $_.action -eq 'R' }).Count

            if (-not $NoProgress)
            {
                $pct = [int](($i / [double]$total) * 100)
                Write-Progress -Activity "Counting SVN diffs" -Status ("r{0} ({1}/{2})" -f $rev, $i, $total) -PercentComplete $pct
            }

            Write-Verbose "Processing revision $rev ($i/$total)"

            $diffArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($a in $commonDiffArgs) { $null = $diffArgs.Add($a) }
            $null = $diffArgs.Add('-c')
            $null = $diffArgs.Add([string]$rev)
            $null = $diffArgs.Add($targetUrl)

            $m = Measure-SvnDiffStreaming -DiffArguments $diffArgs.ToArray() -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -ExcludePathPatterns $ExcludePaths

            foreach ($f in $m.Files) { $null = $allFiles.Add($f) }
            foreach ($bf in $m.BinaryFiles) { $null = $allBinaryFiles.Add($bf) }

            $row = [pscustomobject]@{
                Revision = $rev
                Date = $date
                Author = [string]$e.author
                Message = $msgOneLine
                PathsChanged = $paths.Count
                PathsAdded = $pathsAdded
                PathsDeleted = $pathsDeleted
                PathsModified = $pathsModified
                PathsReplaced = $pathsReplaced
                FilesChanged = $m.FilesChanged
                BinaryFilesChanged = $m.BinaryFilesChanged
                LinesAdded = $m.LinesAdded
                LinesDeleted = $m.LinesDeleted
                NetLines = $m.NetLines
                TextLinesChanged = $m.TextLinesChanged
            }

            $null = $resultRows.Add($row)

            $overall.LinesAdded += $m.LinesAdded
            $overall.LinesDeleted += $m.LinesDeleted
        }

        $overall.NetLines = ($overall.LinesAdded - $overall.LinesDeleted)
        $overall.TextLinesChanged = ($overall.LinesAdded + $overall.LinesDeleted)
    }

    if (-not $NoProgress)
    {
        Write-Progress -Activity "Counting SVN diffs" -Completed
    }

    $overall.FilesChangedUnique = $allFiles.Count
    $overall.BinaryFilesChangedUnique = $allBinaryFiles.Count
    $overall.FinishedAt = (Get-Date)

    # Console output
    Write-Host ""
    Write-Host "===== SVN Diff Size Report ====="
    Write-Host ("Path        : {0}" -f $Path)
    Write-Host ("Target URL  : {0}" -f $targetUrl)
    Write-Host ("Range       : r{0} -> r{1}" -f $FromRevision, $ToRevision)
    if (-not [string]::IsNullOrWhiteSpace($Author))
    {
        Write-Host ("Author      : {0}" -f $Author)
    }
    else
    {
        Write-Host "Author      : (all)"
    }
    Write-Host ("Commits     : {0}" -f $filteredEntries.Count)

    Write-Host ""
    Write-Host "---- Totals ----"
    Write-Host ("Files changed (unique)        : {0}" -f $overall.FilesChangedUnique)
    Write-Host ("Binary files changed (unique) : {0}" -f $overall.BinaryFilesChangedUnique)
    Write-Host ("Lines added                   : {0}" -f $overall.LinesAdded)
    Write-Host ("Lines deleted                 : {0}" -f $overall.LinesDeleted)
    Write-Host ("Net lines                     : {0}" -f $overall.NetLines)
    Write-Host ("Text lines changed (+/-)      : {0}" -f $overall.TextLinesChanged)
    if ($overall.Notes)
    {
        Write-Host ""
        Write-Host ("NOTE: {0}" -f $overall.Notes)
    }

    if ($ShowPerRevision -and $resultRows.Count -gt 0)
    {
        Write-Host ""
        Write-Host "---- Per revision ----"
        $resultRows | Select-Object Revision, Date, Author, FilesChanged, LinesAdded, LinesDeleted, NetLines, Message | Format-Table -AutoSize | Out-Host
    }

    # Export files
    if ($OutputCsv)
    {
        # Export summary + detail rows (same file, summary as first row)
        $csvRows = New-Object 'System.Collections.Generic.List[object]'
        $summaryRow = [pscustomobject]@{
            Revision = ("r{0}:r{1}" -f $FromRevision, $ToRevision)
            Date = $overall.FinishedAt
            Author = $Author
            Message = "SUMMARY"
            PathsChanged = $null
            PathsAdded = $null
            PathsDeleted = $null
            PathsModified = $null
            PathsReplaced = $null
            FilesChanged = $overall.FilesChangedUnique
            BinaryFilesChanged = $overall.BinaryFilesChangedUnique
            LinesAdded = $overall.LinesAdded
            LinesDeleted = $overall.LinesDeleted
            NetLines = $overall.NetLines
            TextLinesChanged = $overall.TextLinesChanged
        }
        $null = $csvRows.Add($summaryRow)
        foreach ($r in $resultRows) { $null = $csvRows.Add($r) }

        $dir = Split-Path -Parent $OutputCsv
        if ($dir -and -not (Test-Path $dir))
        {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $csvRows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host ("CSV written : {0}" -f $OutputCsv)
    }

    if ($OutputJson)
    {
        $obj = [pscustomobject]@{
            Summary = [pscustomobject]$overall
            Details = $resultRows
        }
        $json = $obj | ConvertTo-Json -Depth 8
        Write-FileIfRequested -FilePath $OutputJson -Content $json
        Write-Host ("JSON written: {0}" -f $OutputJson)
    }

    if ($OutputMarkdown)
    {
        $md = New-Object System.Text.StringBuilder
        [void]$md.AppendLine("# SVN Diff Size Report")
        [void]$md.AppendLine("")
        [void]$md.AppendLine(('* Path: `{0}`' -f $Path))
        [void]$md.AppendLine(('* Target URL: `{0}`' -f $targetUrl))
        [void]$md.AppendLine(('* Range: `r{0}:r{1}`' -f $FromRevision, $ToRevision))
        if ($Author) { [void]$md.AppendLine(('* Author: `{0}`' -f $Author)) } else { [void]$md.AppendLine("* Author: (all)") }
        [void]$md.AppendLine(('* Commits matched: `{0}`' -f $filteredEntries.Count))
        [void]$md.AppendLine("")
        [void]$md.AppendLine("## Totals")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("| Item | Value |")
        [void]$md.AppendLine("|---|---:|")
        [void]$md.AppendLine("| Files changed (unique) | " + $overall.FilesChangedUnique + " |")
        [void]$md.AppendLine("| Binary files changed (unique) | " + $overall.BinaryFilesChangedUnique + " |")
        [void]$md.AppendLine("| Lines added | " + $overall.LinesAdded + " |")
        [void]$md.AppendLine("| Lines deleted | " + $overall.LinesDeleted + " |")
        [void]$md.AppendLine("| Net lines | " + $overall.NetLines + " |")
        [void]$md.AppendLine("| Text lines changed (+/-) | " + $overall.TextLinesChanged + " |")
        if ($overall.Notes)
        {
            [void]$md.AppendLine("")
            [void]$md.AppendLine("> NOTE: " + $overall.Notes)
        }

        if ($resultRows.Count -gt 0)
        {
            [void]$md.AppendLine("")
            [void]$md.AppendLine("## Details")
            [void]$md.AppendLine("")
            [void]$md.AppendLine("| Revision | Date | Author | Files | + | - | Net | Message |")
            [void]$md.AppendLine("|---:|---|---|---:|---:|---:|---:|---|")
            foreach ($r in $resultRows)
            {
                $rev = $r.Revision
                $d = $r.Date
                $a = $r.Author
                $f = $r.FilesChanged
                $p = $r.LinesAdded
                $m = $r.LinesDeleted
                $n = $r.NetLines
                $msg = $r.Message
                if ($msg) { $msg = $msg.Replace('|', '\|') }
                [void]$md.AppendLine(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f $rev, $d, $a, $f, $p, $m, $n, $msg))
            }
        }

        Write-FileIfRequested -FilePath $OutputMarkdown -Content $md.ToString()
        Write-Host ("Markdown written: {0}" -f $OutputMarkdown)
    }

    # Output object (so user can pipe if desired)
    [pscustomobject]@{
        Summary = [pscustomobject]$overall
        Details = $resultRows
    }
}
catch
{
    Write-Error $_
    Write-Verbose "Error details: $($_.Exception.Message)"
    Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
