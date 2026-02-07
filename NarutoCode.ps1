<#
.SYNOPSIS
    SVN リポジトリの履歴を解析し、コミット品質・変更傾向のメトリクスを生成する。
.DESCRIPTION
    NarutoCode は指定リビジョン範囲（FromRev〜ToRev）の SVN 履歴を、
    svn log / diff / blame のみで分析し、以下のメトリクスを算出する：
    - コードチャーンと生存分析（svn blame による）
    - 自己相殺・他者差戻の検出（行ハッシュ追跡による）
    - ホットスポットスコアリング（コミット頻度 × チャーン）
    - 共変更カップリング（Jaccard / Lift）
    - Strict 死亡帰属（リビジョン横断の行単位 birth/death 追跡）

    出力は CSV レポートおよびオプションの PlantUML 可視化。
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

$script:StrictModeEnabled = $true
$script:ColDeadAdded = '消滅追加行数'       # 追加されたが ToRev 時点で生存していない行数
$script:ColSelfDead = '自己消滅行数'         # 追加した本人が後のコミットで削除した行数
$script:ColOtherDead = '被他者消滅行数'      # 別の作者によって削除された行数
$script:StrictBlameCacheHits = 0
$script:StrictBlameCacheMisses = 0

# region 初期化
function Initialize-StrictModeContext
{
    <#
    .SYNOPSIS
        Strict モード実行に必要なスクリプト状態を初期化する。
    #>
    $script:StrictModeEnabled = $true
    $script:StrictBlameCacheHits = 0
    $script:StrictBlameCacheMisses = 0
    $script:ColDeadAdded = '消滅追加行数'       # 追加されたが ToRev 時点で生存していない行数
    $script:ColSelfDead = '自己消滅行数'         # 追加した本人が後のコミットで削除した行数
    $script:ColOtherDead = '被他者消滅行数'      # 別の作者によって削除された行数
}
function ConvertTo-NormalizedExtension
{
    <#
    .SYNOPSIS
        拡張子フィルタ入力を比較可能な小文字形式に正規化する。
    #>
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
    <#
    .SYNOPSIS
        パスパターン入力を重複なしの正規化済み配列に整形する。
    #>
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
# endregion 初期化
# region エンコーディングと入出力
function ConvertTo-PlainText
{
    <#
    .SYNOPSIS
        SecureString を SVN 引数で扱える平文文字列に変換する。
    #>
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
    <#
    .SYNOPSIS
        出力指定名から対応するテキストエンコーディングを取得する。
    #>
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
    <#
    .SYNOPSIS
        指定エンコーディングでテキストファイルを安全に書き出す。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Content
        解析対象のテキスト入力を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
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
    <#
    .SYNOPSIS
        ヘッダー順を固定した CSV レポートを出力する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Rows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER Headers
        Headers の値を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
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
    <#
    .SYNOPSIS
        実行メタデータや集計結果を JSON 形式で保存する。
    .PARAMETER Data
        Data の値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Depth
        Depth の値を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
    param($Data, [string]$FilePath, [int]$Depth = 12, [string]$EncodingName = 'UTF8')
    Write-TextFile -FilePath $FilePath -Content ($Data | ConvertTo-Json -Depth $Depth) -EncodingName $EncodingName
}
# endregion エンコーディングと入出力
# region 数値と書式
function Get-RoundedNumber
{
    <#
    .SYNOPSIS
        指標表示用の数値を指定桁数で丸める。
    #>
    param([double]$Value, [int]$Digits = 4) [Math]::Round($Value, $Digits)
}
function Format-MetricValue
{
    <#
    .SYNOPSIS
        Strict 設定に応じて指標値の丸め有無を切り替える。
    #>
    param([double]$Value)
    return $Value
}
function Add-Count
{
    <#
    .SYNOPSIS
        ハッシュテーブルのカウンター項目を加算更新する。
    .PARAMETER Table
        更新対象のハッシュテーブルを指定する。
    .PARAMETER Key
        更新または参照に使用するキーを指定する。
    .PARAMETER Delta
        加算または移動量として反映する差分値を指定する。
    #>
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
# endregion 数値と書式
# region 並列実行
function Invoke-ParallelWork
{
    <#
    .SYNOPSIS
        RunspacePool を使って入力項目ごとの処理を並列実行する。
    .DESCRIPTION
        MaxParallel が 1 を超える場合は WorkerScript をテキスト化し、各 runspace 内で再生成する。
        そのため外側スコープのクロージャは保持されず、必要な値は InputItems または SessionVariables で渡す。
        RequiredFunctions で明示した関数だけを runspace 側へ注入し、実行環境の差異を抑える。
    .PARAMETER InputItems
        並列処理する入力項目配列を指定する。
    .PARAMETER WorkerScript
        各入力項目に対して実行する処理を指定する。
    .PARAMETER MaxParallel
        並列実行時の最大ワーカー数を指定する。
    .PARAMETER RequiredFunctions
        ワーカー runspace に注入する関数名一覧を指定する。
    .PARAMETER SessionVariables
        ワーカー runspace に注入する共有変数を指定する。
    .PARAMETER ErrorContext
        失敗時に付与するエラー文脈文字列を指定する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$InputItems,
        [scriptblock]$WorkerScript,
        [ValidateRange(1, 128)][int]$MaxParallel = 1,
        [string[]]$RequiredFunctions = @(),
        [hashtable]$SessionVariables = @{},
        [string]$ErrorContext = 'parallel work'
    )

    $items = @($InputItems)
    if ($items.Count -eq 0)
    {
        return @()
    }
    if ($null -eq $WorkerScript)
    {
        throw "WorkerScript is required for $ErrorContext."
    }

    $effectiveParallel = [Math]::Max(1, [Math]::Min([int]$MaxParallel, $items.Count))
    if ($effectiveParallel -le 1)
    {
        $sequentialResults = [System.Collections.Generic.List[object]]::new()
        for ($i = 0
            $i -lt $items.Count
            $i++)
        {
            try
            {
                [void]$sequentialResults.Add((& $WorkerScript -Item $items[$i] -Index $i))
            }
            catch
            {
                throw ("{0} failed at item index {1}: {2}" -f $ErrorContext, $i, $_.Exception.Message)
            }
        }
        return @($sequentialResults.ToArray())
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $iss.ImportPSModule(@('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility'))
    $requiredUnique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rawName in @($RequiredFunctions))
    {
        if ([string]::IsNullOrWhiteSpace([string]$rawName))
        {
            continue
        }
        $name = [string]$rawName
        if (-not $requiredUnique.Add($name))
        {
            continue
        }
        $functionPath = "function:{0}" -f $name
        try
        {
            $definition = (Get-Item -LiteralPath $functionPath -ErrorAction Stop).ScriptBlock.ToString()
        }
        catch
        {
            throw ("Required function '{0}' was not found for {1}." -f $name, $ErrorContext)
        }
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $definition)))
    }
    foreach ($key in @($SessionVariables.Keys))
    {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry([string]$key, $SessionVariables[$key], ("Injected for {0}" -f $ErrorContext))))
    }

    $workerText = $WorkerScript.ToString()
    $invokeScript = @'
param([string]$WorkerText, [object]$Item, [int]$Index)
try
{
    $worker = [scriptblock]::Create($WorkerText)
    $result = & $worker -Item $Item -Index $Index
    [pscustomobject]@{
        Index = [int]$Index
        Succeeded = $true
        Result = $result
        ErrorMessage = $null
        ErrorStack = $null
    }
}
catch
{
    [pscustomobject]@{
        Index = [int]$Index
        Succeeded = $false
        Result = $null
        ErrorMessage = $_.Exception.Message
        ErrorStack = $_.ScriptStackTrace
    }
}
'@

    $pool = [runspacefactory]::CreateRunspacePool($iss)
    $null = $pool.SetMinRunspaces(1)
    $null = $pool.SetMaxRunspaces($effectiveParallel)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $wrappedResults = [System.Collections.Generic.List[object]]::new()
    try
    {
        $pool.Open()
        for ($i = 0
            $i -lt $items.Count
            $i++)
        {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($invokeScript).AddArgument($workerText).AddArgument($items[$i]).AddArgument($i)
            $handle = $ps.BeginInvoke()
            [void]$jobs.Add([pscustomobject]@{
                    Index = $i
                    PowerShell = $ps
                    Handle = $handle
                })
        }

        foreach ($job in @($jobs.ToArray()))
        {
            if ($null -eq $job -or $null -eq $job.PowerShell)
            {
                [void]$wrappedResults.Add([pscustomobject]@{
                        Index = if ($null -ne $job)
                        {
                            [int]$job.Index
                        }
                        else
                        {
                            -1
                        }
                        Succeeded = $false
                        Result = $null
                        ErrorMessage = 'Worker handle was not initialized.'
                        ErrorStack = $null
                    })
                continue
            }
            $wrapped = $null
            try
            {
                $resultSet = $job.PowerShell.EndInvoke($job.Handle)
                if ($resultSet -and $resultSet.Count -gt 0)
                {
                    $wrapped = $resultSet[0]
                }
                else
                {
                    $wrapped = [pscustomobject]@{
                        Index = [int]$job.Index
                        Succeeded = $false
                        Result = $null
                        ErrorMessage = 'Worker returned no result.'
                        ErrorStack = $null
                    }
                }
            }
            catch
            {
                $wrapped = [pscustomobject]@{
                    Index = [int]$job.Index
                    Succeeded = $false
                    Result = $null
                    ErrorMessage = $_.Exception.Message
                    ErrorStack = $_.ScriptStackTrace
                }
            }
            finally
            {
                if ($job.PowerShell)
                {
                    $job.PowerShell.Dispose()
                    $job.PowerShell = $null
                }
            }
            [void]$wrappedResults.Add($wrapped)
        }
    }
    catch
    {
        throw ("{0} infrastructure failure: {1}" -f $ErrorContext, $_.Exception.Message)
    }
    finally
    {
        foreach ($job in @($jobs.ToArray()))
        {
            if ($null -ne $job -and $null -ne $job.PowerShell)
            {
                try
                {
                    $job.PowerShell.Dispose()
                }
                catch
                {
                    $null = $_
                }
            }
        }
        if ($pool)
        {
            $pool.Dispose()
        }
    }

    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($wrappedResults.ToArray()))
    {
        if ($null -eq $entry -or -not [bool]$entry.Succeeded)
        {
            [void]$failed.Add($entry)
        }
    }
    if ($failed.Count -gt 0)
    {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @($failed.ToArray()))
        {
            $idx = -1
            $msg = 'Unknown worker failure.'
            $stack = $null
            if ($null -ne $f)
            {
                $idx = [int]$f.Index
                $msg = [string]$f.ErrorMessage
                $stack = [string]$f.ErrorStack
            }
            $line = "[{0}] {1}" -f $idx, $msg
            if (-not [string]::IsNullOrWhiteSpace($stack))
            {
                $line += "`n" + $stack
            }
            [void]$lines.Add($line)
        }
        throw ("{0} failed for {1} item(s).`n{2}" -f $ErrorContext, $failed.Count, ($lines.ToArray() -join "`n"))
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($wrappedResults.ToArray()))
    {
        [void]$results.Add($entry.Result)
    }
    return @($results.ToArray())
}
# endregion 並列実行
# region パスとキャッシュ
function Get-NormalizedAuthorName
{
    <#
    .SYNOPSIS
        作者名の空値や余分な空白を正規化して比較可能にする。
    #>
    param([string]$Author)
    if ([string]::IsNullOrWhiteSpace($Author))
    {
        return '(unknown)'
    }
    return $Author.Trim()
}
function ConvertTo-PathKey
{
    <#
    .SYNOPSIS
        SVN パスを比較とキー参照に適した正規化文字列へ変換する。
    #>
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
    <#
    .SYNOPSIS
        文字列の SHA1 ハッシュを16進小文字で取得する。
    #>
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
    <#
    .SYNOPSIS
        パス文字列からキャッシュファイル名用ハッシュを生成する。
    #>
    param([string]$FilePath)
    return Get-Sha1Hex -Text (ConvertTo-PathKey -Path $FilePath)
}
function Get-BlameCachePath
{
    <#
    .SYNOPSIS
        blame XML キャッシュの保存先パスを組み立てる。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    #>
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    $dir = Join-Path (Join-Path $CacheDir 'blame') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -FilePath $FilePath) + '.xml')
}
function Get-CatCachePath
{
    <#
    .SYNOPSIS
        cat テキストキャッシュの保存先パスを組み立てる。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    #>
    param([string]$CacheDir, [int]$Revision, [string]$FilePath)
    $dir = Join-Path (Join-Path $CacheDir 'cat') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -FilePath $FilePath) + '.txt')
}
function Read-BlameCacheFile
{
    <#
    .SYNOPSIS
        blame XML キャッシュを読み込んで再利用する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    #>
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
    <#
    .SYNOPSIS
        blame XML をキャッシュとして保存する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Content
        解析対象のテキスト入力を指定する。
    #>
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
    <#
    .SYNOPSIS
        cat テキストキャッシュを読み込んで再利用する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    #>
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
    <#
    .SYNOPSIS
        cat テキストをキャッシュとして保存する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Content
        解析対象のテキスト入力を指定する。
    #>
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
    <#
    .SYNOPSIS
        入力文字列を改行区切りの行配列へ正規化する。
    #>
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
    <#
    .SYNOPSIS
        リネーム履歴をたどって最新側の論理パスへ解決する。
    #>
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
    <#
    .SYNOPSIS
        Unified diff テキストから追加削除行数を高速に集計する。
    #>
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
    <#
    .SYNOPSIS
        対象リビジョンのリポジトリ内ファイル一覧を条件付きで取得する。
    .PARAMETER Repo
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER IncludeExt
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExt
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    #>
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
    <#
    .SYNOPSIS
        正準行番号変換に使うオフセットイベント表を初期化する。
    #>
    return (New-Object 'System.Collections.Generic.List[object]')
}
function Get-CanonicalLineNumber
{
    <#
    .SYNOPSIS
        現在のオフセット情報から正準行番号を算出する。
    #>
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
    <#
    .SYNOPSIS
        行番号シフトを正準オフセットイベントとして登録する。
    .PARAMETER OffsetEvents
        OffsetEvents の値を指定する。
    .PARAMETER ThresholdLine
        ThresholdLine の値を指定する。
    .PARAMETER ShiftDelta
        加算または移動量として反映する差分値を指定する。
    #>
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
    <#
    .SYNOPSIS
        2つの行範囲が重なっているかを判定する。
    .PARAMETER StartA
        StartA の値を指定する。
    .PARAMETER EndA
        EndA の値を指定する。
    .PARAMETER StartB
        StartB の値を指定する。
    .PARAMETER EndB
        EndB の値を指定する。
    #>
    param([int]$StartA, [int]$EndA, [int]$StartB, [int]$EndB)
    $left = [Math]::Max($StartA, $StartB)
    $right = [Math]::Min($EndA, $EndB)
    return ($left -le $right)
}
function Test-RangeTripleOverlap
{
    <#
    .SYNOPSIS
        3つの行範囲に共通重複があるかを判定する。
    .PARAMETER StartA
        StartA の値を指定する。
    .PARAMETER EndA
        EndA の値を指定する。
    .PARAMETER StartB
        StartB の値を指定する。
    .PARAMETER EndB
        EndB の値を指定する。
    .PARAMETER StartC
        StartC の値を指定する。
    .PARAMETER EndC
        EndC の値を指定する。
    #>
    param([int]$StartA, [int]$EndA, [int]$StartB, [int]$EndB, [int]$StartC, [int]$EndC)
    $left = [Math]::Max([Math]::Max($StartA, $StartB), $StartC)
    $right = [Math]::Min([Math]::Min($EndA, $EndB), $EndC)
    return ($left -le $right)
}
function Test-ShouldCountFile
{
    <#
    .SYNOPSIS
        拡張子とパス条件から解析対象ファイルかを判定する。
    .DESCRIPTION
        拡張子条件とパスパターン条件を順序立てて評価し、解析対象の一貫性を維持する。
        この判定を共通化することで diff・blame・集計の対象ずれを防ぐ。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER IncludeExt
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExt
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    #>
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
# endregion パスとキャッシュ
# region SVN コマンド
function Join-CommandArgument
{
    <#
    .SYNOPSIS
        コマンド引数配列をログ用の安全な表示文字列へ結合する。
    #>
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
    <#
    .SYNOPSIS
        SVN コマンドを実行して標準出力と失敗情報を統一処理する。
    #>
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
    <#
    .SYNOPSIS
        SVN XML 出力を前処理して安全に XML オブジェクト化する。
    #>
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
    <#
    .SYNOPSIS
        入力 URL を SVN 実行用の正規化ターゲットに確定する。
    #>
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
# endregion SVN コマンド
# region ログ・差分パース
function ConvertFrom-SvnLogXml
{
    <#
    .SYNOPSIS
        SVN log XML をコミットオブジェクト配列へ変換する。
    .DESCRIPTION
        logentry と path ノードを走査し、リビジョン単位のコミット情報を正規化して構築する。
        作者欠損や copyfrom 情報も吸収し、後段の差分解析で扱える構造へ揃える。
        取得順に依存しないよう変更パスを整形し、集計パイプラインの入力を安定化する。
    #>
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
    <#
    .SYNOPSIS
        行内容をファイル文脈付きの比較用ハッシュに変換する。
    #>
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
    <#
    .SYNOPSIS
        誤判定を避けるため比較対象外の自明行かを判定する。
    #>
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
    <#
    .SYNOPSIS
        hunk 周辺文脈から位置識別用のコンテキストハッシュを作成する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER ContextLines
        ContextLines の値を指定する。
    .PARAMETER K
        K の値を指定する。
    #>
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
    <#
    .SYNOPSIS
        Unified diff をファイル別差分統計と hunk 情報へ変換する。
    .DESCRIPTION
        Index 行でファイル境界を確定し、hunk の確定漏れを防ぎながら順次パースする。
        hunk ヘッダーを基点に追加・削除・文脈行を収集し、必要時は行ハッシュも同時に構築する。
        バイナリ兆候を検出したファイルはテキスト行追跡対象から外し、誤集計を避ける。
    #>
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
        # ファイル境界を先に確定し、前hunkの確定漏れを防ぐ。
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
        # hunk単位で位置情報を持ち、後段の行追跡精度を担保する。
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
        # バイナリは行追跡不能なため早期にテキスト解析対象から外す。
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
# endregion ログ・差分パース
# region Blame パース
function ConvertFrom-SvnBlameXml
{
    <#
    .SYNOPSIS
        SVN blame XML とファイル内容を結合して行単位情報へ変換する。
    .DESCRIPTION
        blame XML の行帰属情報と cat 由来の実テキストを突き合わせ、行単位の解析基盤を作る。
        リビジョン別・作者別の件数を同時集計し、所有率計算と strict 帰属の双方で再利用する。
        XML 欠損や行数差異を吸収し、後段で扱いやすい統一形式を返す。
    #>
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
    <#
    .SYNOPSIS
        値分布の偏りを示すエントロピーを算出する。
    #>
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
    <#
    .SYNOPSIS
        コミットメッセージ中のキーワード出現数を集計する。
    #>
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
    <#
    .SYNOPSIS
        指定ファイルの blame 情報を取得して集計オブジェクト化する。
    .PARAMETER Repo
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    #>
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
    <#
    .SYNOPSIS
        指定リビジョンの blame 行情報をキャッシュ付きで取得する。
    .PARAMETER Repo
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    #>
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
function Initialize-SvnBlameLineCache
{
    <#
    .SYNOPSIS
        blame XML と cat を統合した行情報キャッシュを構築する。
    .PARAMETER Repo
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir)
    if ($Revision -le 0 -or [string]::IsNullOrWhiteSpace($FilePath))
    {
        return [pscustomobject]@{
            CacheHits = 0
            CacheMisses = 0
        }
    }

    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision

    $hits = 0
    $misses = 0

    $blameXml = Read-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ([string]::IsNullOrEmpty($blameXml))
    {
        $misses++
        $blameXml = Invoke-SvnCommand -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        Write-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
    }
    else
    {
        $hits++
    }

    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ($null -eq $catText)
    {
        $misses++
        $catText = Invoke-SvnCommand -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
        Write-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
    }
    else
    {
        $hits++
    }

    return [pscustomobject]@{
        CacheHits = $hits
        CacheMisses = $misses
    }
}
# endregion Blame パース
# region LCS・Blame 比較
function Get-LineIdentityKey
{
    <#
    .SYNOPSIS
        blame 行の同一性比較に使う識別キーを生成する。
    #>
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
    <#
    .SYNOPSIS
        LCS で2系列の一致インデックス対応を抽出する。
    .DESCRIPTION
        ロック済み要素を除外した2系列に対して DP で最長共通部分列を計算する。
        一致長テーブルを逆方向にたどり、順序を保った一致インデックスのみを復元する。
        identity 比較と content 比較の両段で使える共通 LCS 実装として設計する。
    .PARAMETER PreviousKeys
        PreviousKeys の値を指定する。
    .PARAMETER CurrentKeys
        CurrentKeys の値を指定する。
    .PARAMETER PreviousLocked
        PreviousLocked の値を指定する。
    .PARAMETER CurrentLocked
        CurrentLocked の値を指定する。
    #>
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

    # 未一致区間のみでDPを組み、既知一致を再計算しないため。
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
    # 後ろから復元して順序を保った一致ペアだけを採用するため。
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
    <#
    .SYNOPSIS
        前後 blame を照合して born・dead・move・再帰属を分類する。
    .DESCRIPTION
        まず identity LCS で帰属が連続する行を優先一致させ、移動検出の土台を作る。
        次に content LCS へフォールバックし、帰属変更で identity が崩れた行を救済する。
        未一致残余を born/dead として確定し、move・再帰属を分離して返す。
    #>
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

    # まず identity LCS で帰属が同じ行を優先一致させる。
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

    # 次に content LCS で帰属変更行を救済し誤検出を減らす。
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

    # 最後に未一致残余を born/dead として確定する。
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
# endregion LCS・Blame 比較
# region Strict 帰属
function Get-CommitFileTransition
{
    <#
    .SYNOPSIS
        コミット内のパス変化から before/after 遷移ペアを構築する。
    .DESCRIPTION
        変更パスと copyfrom 情報を突き合わせ、削除+追加を rename 遷移として復元する。
        before/after の遷移ペアを構築し、strict blame 比較で参照するファイル状態を確定する。
        rename で消費済みの旧パスを除外し、同一コミット内の重複遷移を抑止する。
    #>
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
    <#
    .SYNOPSIS
        hunk の正準行範囲を追跡して反復編集とピンポンを集計する。
    .DESCRIPTION
        各 hunk の old 範囲を正準行番号空間へ写像し、行番号ずれの影響を吸収する。
        重複範囲の重なり判定で同一作者の反復編集を集計し、局所的手戻りを可視化する。
        A→B→A の三者重なりを抽出してピンポン編集を数え、協業摩擦の兆候を捉える。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER RevToAuthor
        リビジョン番号と作者の対応表を指定する。
    .PARAMETER RenameMap
        RenameMap の値を指定する。
    #>
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
            # 行番号ずれを吸収するため、先に正準範囲へ写像して記録する。
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
        # 同一作者の重なりを数え、反復編集の密度を可視化するため。
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
        # A→B→A の往復を重なり範囲で絞り、偶然一致を減らすため。
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
function Get-StrictBlamePrefetchTarget
{
    <#
    .SYNOPSIS
        Strict blame の事前取得対象をリビジョン単位で列挙する。
    .DESCRIPTION
        コミット遷移ごとに比較対象となる before/after の blame 取得点を列挙する。
        同一 revision/path の重複を除去し、事前キャッシュの取得量を最小化する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Commits,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir
    )

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($c in @($Commits | Sort-Object Revision))
    {
        $rev = [int]$c.Revision
        if ($rev -lt $FromRevision -or $rev -gt $ToRevision)
        {
            continue
        }
        $transitions = @(Get-CommitFileTransition -Commit $c)
        foreach ($t in $transitions)
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

            if ($beforePath -and ($rev - 1) -gt 0)
            {
                # Unit Separator (U+001F) as key delimiter — never appears in file paths
                $key = [string]($rev - 1) + [char]31 + $beforePath
                if ($seen.Add($key))
                {
                    $blameXml = Read-BlameCacheFile -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath
                    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath
                    if ([string]::IsNullOrEmpty($blameXml) -or $null -eq $catText)
                    {
                        [void]$targets.Add([pscustomobject]@{
                                FilePath = $beforePath
                                Revision = [int]($rev - 1)
                            })
                    }
                }
            }
            if ($afterPath -and $rev -gt 0)
            {
                # Unit Separator (U+001F) as key delimiter — never appears in file paths
                $key = [string]$rev + [char]31 + $afterPath
                if ($seen.Add($key))
                {
                    $blameXml = Read-BlameCacheFile -CacheDir $CacheDir -Revision $rev -FilePath $afterPath
                    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision $rev -FilePath $afterPath
                    if ([string]::IsNullOrEmpty($blameXml) -or $null -eq $catText)
                    {
                        [void]$targets.Add([pscustomobject]@{
                                FilePath = $afterPath
                                Revision = [int]$rev
                            })
                    }
                }
            }
        }
    }

    return @($targets.ToArray())
}
function Invoke-StrictBlameCachePrefetch
{
    <#
    .SYNOPSIS
        Strict blame 解析に必要なキャッシュを並列事前構築する。
    .DESCRIPTION
        事前算出したターゲット一覧を並列処理し、blame/cat キャッシュを先行構築する。
        実測のヒット/ミス件数を集約し、run_meta へ反映する統計値を更新する。
    .PARAMETER Targets
        Targets の値を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    #>
    [CmdletBinding()]
    param(
        [object[]]$Targets,
        [string]$TargetUrl,
        [string]$CacheDir,
        [int]$Parallel = 1
    )
    $items = @($Targets)
    if ($items.Count -eq 0)
    {
        return
    }

    if ($Parallel -le 1)
    {
        foreach ($item in $items)
        {
            try
            {
                $prefetchStats = Initialize-SvnBlameLineCache -Repo $TargetUrl -FilePath ([string]$item.FilePath) -Revision ([int]$item.Revision) -CacheDir $CacheDir
                $script:StrictBlameCacheHits += [int]$prefetchStats.CacheHits
                $script:StrictBlameCacheMisses += [int]$prefetchStats.CacheMisses
            }
            catch
            {
                throw ("Strict blame prefetch failed for '{0}' at r{1}: {2}" -f [string]$item.FilePath, [int]$item.Revision, $_.Exception.Message)
            }
        }
        return
    }

    $prefetchItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items)
    {
        [void]$prefetchItems.Add([pscustomobject]@{
                FilePath = [string]$item.FilePath
                Revision = [int]$item.Revision
                TargetUrl = $TargetUrl
                CacheDir = $CacheDir
            })
    }

    $worker = {
        param($Item, $Index)
        $null = $Index # Required by Invoke-ParallelWork contract
        try
        {
            $stats = Initialize-SvnBlameLineCache -Repo $Item.TargetUrl -FilePath ([string]$Item.FilePath) -Revision ([int]$Item.Revision) -CacheDir $Item.CacheDir
            [pscustomobject]@{
                CacheHits = [int]$stats.CacheHits
                CacheMisses = [int]$stats.CacheMisses
            }
        }
        catch
        {
            throw ("Strict blame prefetch failed for '{0}' at r{1}: {2}" -f [string]$Item.FilePath, [int]$Item.Revision, $_.Exception.Message)
        }
    }
    $results = @(Invoke-ParallelWork -InputItems $prefetchItems.ToArray() -WorkerScript $worker -MaxParallel $Parallel -RequiredFunctions @(
            'ConvertTo-PathKey',
            'Get-Sha1Hex',
            'Get-PathCacheHash',
            'Get-BlameCachePath',
            'Get-CatCachePath',
            'Read-BlameCacheFile',
            'Write-BlameCacheFile',
            'Read-CatCacheFile',
            'Write-CatCacheFile',
            'Join-CommandArgument',
            'Invoke-SvnCommand',
            'Initialize-SvnBlameLineCache'
        ) -SessionVariables @{
            SvnExecutable = $script:SvnExecutable
            SvnGlobalArguments = @($script:SvnGlobalArguments)
        } -ErrorContext 'strict blame prefetch')

    foreach ($entry in @($results))
    {
        $script:StrictBlameCacheHits += [int]$entry.CacheHits
        $script:StrictBlameCacheMisses += [int]$entry.CacheMisses
    }
}
function Get-ExactDeathAttribution
{
    <#
    .SYNOPSIS
        行単位の誕生と消滅を追跡して厳密帰属メトリクスを算出する。
    .DESCRIPTION
        コミットごとに before/after blame を比較し、行の誕生・消滅・内部移動を直接観測する。
        born/dead と self/other 分類を同時更新し、作者別とファイル別の strict 指標を整合させる。
        最後に hunk 正準範囲解析を統合し、反復編集・ピンポンを含む詳細結果を返す。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER RevToAuthor
        リビジョン番号と作者の対応表を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER RenameMap
        RenameMap の値を指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    #>
    [CmdletBinding()]
    param(
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [hashtable]$RenameMap = @{},
        [int]$Parallel = 1
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

    $prefetchTargets = @(Get-StrictBlamePrefetchTarget -Commits $Commits -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir)
    Invoke-StrictBlameCachePrefetch -Targets $prefetchTargets -TargetUrl $TargetUrl -CacheDir $CacheDir -Parallel $Parallel

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

                # bornは範囲内追加のみ加算し、初期生存行として保持する。
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

                # deadは生存減算と自己/他者分類を同時更新し整合を保つ。
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
# endregion Strict 帰属
# region メトリクス計算
function Get-CommitterMetric
{
    <#
    .SYNOPSIS
        コミッター単位の基本メトリクスを集計して行オブジェクト化する。
    .DESCRIPTION
        コミット単位データから作者別に活動量・チャーン・行動属性を集約する。
        比率、エントロピー、共同編集者数など派生指標を算出し、比較可能な行形式へ整える。
        strict で後から上書きする列は null で初期化し、更新フローを分離する。
    #>
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
    <#
    .SYNOPSIS
        ファイル単位の基本メトリクスを集計して行オブジェクト化する。
    .DESCRIPTION
        コミット履歴をファイル軸で集約し、量・頻度・作者分散の基本指標を算出する。
        変更間隔や最多作者占有率、ホットスポットスコアを算出して優先度付けに備える。
        strict で補完する blame 依存列は null 初期化し、後段更新との整合を保つ。
    #>
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
    <#
    .SYNOPSIS
        共変更ペアの回数と関連度指標を算出する。
    .DESCRIPTION
        各コミットの一意ファイル集合から共変更ペア回数を集計し、周辺頻度も同時に保持する。
        Jaccard と Lift を算出して関連度を数値化し、順位付け可能な行データへ整形する。
    #>
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
# endregion メトリクス計算
# region PlantUML 出力
function Write-PlantUmlFile
{
    <#
    .SYNOPSIS
        集計結果の上位データを PlantUML 可視化ファイルとして出力する。
    .DESCRIPTION
        コミッター・ホットスポット・共変更ネットワークの3種類の puml を生成する。
        TopN 抽出結果を可視化しつつ、CSV が完全データであることを注記で明示する。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Committers の値を指定する。
    .PARAMETER Files
        Files の値を指定する。
    .PARAMETER Couplings
        Couplings の値を指定する。
    .PARAMETER TopNCount
        上位抽出件数を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
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
# endregion PlantUML 出力
# region 消滅行詳細
function Get-DeadLineDetail
{
    <#
    .SYNOPSIS
        差分ハッシュを使って行の自己相殺と他者差戻を詳細集計する。
    .DESCRIPTION
        diff 行ハッシュと hunk 文脈を用いて、自己相殺や他者差戻の詳細イベントを近似抽出する。
        リネーム解決と同一 hunk 追跡を組み合わせ、作者別・ファイル別の詳細統計を構築する。
        strict 計算が使えない場面でも比較可能な補助指標を提供する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER RevToAuthor
        リビジョン番号と作者の対応表を指定する。
    .PARAMETER DetailLevel
        DetailLevel の値を指定する。
    .PARAMETER RenameMap
        RenameMap の値を指定する。
    #>
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
function Get-HashtableIntValue
{
    <#
    .SYNOPSIS
        ハッシュテーブルから未定義時既定値付きで整数値を取得する。
    .PARAMETER Table
        更新対象のハッシュテーブルを指定する。
    .PARAMETER Key
        更新または参照に使用するキーを指定する。
    .PARAMETER Default
        値が存在しない場合の既定値を指定する。
    #>
    param([hashtable]$Table, [string]$Key, [int]$Default = 0)
    if ($null -eq $Table -or [string]::IsNullOrWhiteSpace($Key))
    {
        return $Default
    }
    if ($Table.ContainsKey($Key))
    {
        return [int]$Table[$Key]
    }
    return $Default
}
# endregion 消滅行詳細
# region SVN 引数ヘルパー
function Get-SvnGlobalArgumentList
{
    <#
    .SYNOPSIS
        認証と対話制御を含む共通 SVN 引数配列を構築する。
    .PARAMETER Username
        Username の値を指定する。
    .PARAMETER Password
        Password の値を指定する。
    .PARAMETER NonInteractive
        NonInteractive の値を指定する。
    .PARAMETER TrustServerCert
        TrustServerCert の値を指定する。
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Username, [securestring]$Password, [switch]$NonInteractive, [switch]$TrustServerCert)
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
    return $ga.ToArray()
}
function Get-SvnVersionSafe
{
    <#
    .SYNOPSIS
        利用中の SVN クライアントバージョンを安全に取得する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try
    {
        return (Invoke-SvnCommand -Arguments @('--version', '--quiet') -ErrorContext 'svn version').Split("`n")[0].Trim()
    }
    catch
    {
        return $null
    }
}
function Get-SvnDiffArgumentList
{
    <#
    .SYNOPSIS
        差分取得オプションから svn diff 引数配列を構築する。
    .PARAMETER IncludeProperties
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ForceBinary
        ForceBinary の値を指定する。
    .PARAMETER IgnoreAllSpace
        IgnoreAllSpace の値を指定する。
    .PARAMETER IgnoreSpaceChange
        IgnoreSpaceChange の値を指定する。
    .PARAMETER IgnoreEolStyle
        IgnoreEolStyle の値を指定する。
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$IncludeProperties, [switch]$ForceBinary, [switch]$IgnoreAllSpace, [switch]$IgnoreSpaceChange, [switch]$IgnoreEolStyle)
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
    $extensions = New-Object 'System.Collections.Generic.List[string]'
    if ($IgnoreAllSpace)
    {
        $null = $extensions.Add('--ignore-all-space')
    }
    elseif ($IgnoreSpaceChange)
    {
        $null = $extensions.Add('--ignore-space-change')
    }
    if ($IgnoreEolStyle)
    {
        $null = $extensions.Add('--ignore-eol-style')
    }
    if ($extensions.Count -gt 0)
    {
        $null = $diffArgs.Add('--extensions')
        $null = $diffArgs.Add(($extensions.ToArray() -join ' '))
    }
    return $diffArgs.ToArray()
}
function Get-CachedOrFetchDiffText
{
    <#
    .SYNOPSIS
        差分キャッシュを優先して必要時のみ svn diff を取得する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER DiffArguments
        svn diff 実行時に付与する追加引数配列を指定する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$CacheDir, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
    $cacheFile = Join-Path $CacheDir ("diff_r{0}.txt" -f $Revision)
    if (Test-Path $cacheFile)
    {
        return (Get-Content -Path $cacheFile -Raw -Encoding UTF8)
    }

    $fetchArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $DiffArguments)
    {
        $null = $fetchArgs.Add([string]$item)
    }
    $null = $fetchArgs.Add('-c')
    $null = $fetchArgs.Add([string]$Revision)
    $null = $fetchArgs.Add($TargetUrl)
    $diffText = Invoke-SvnCommand -Arguments $fetchArgs.ToArray() -ErrorContext ("svn diff -c {0}" -f $Revision)
    Set-Content -Path $cacheFile -Value $diffText -Encoding UTF8
    return $diffText
}
# endregion SVN 引数ヘルパー
# region 差分処理パイプライン
function Get-FilteredChangedPathEntry
{
    <#
    .SYNOPSIS
        変更パス一覧を拡張子とパターン条件で絞り込む。
    .PARAMETER ChangedPaths
        ChangedPaths の値を指定する。
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$ChangedPaths, [string[]]$IncludeExtensions, [string[]]$ExcludeExtensions, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
    $filtered = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pathEntry in @($ChangedPaths))
    {
        if ($null -eq $pathEntry)
        {
            continue
        }
        if ($pathEntry.PSObject.Properties.Match('IsDirectory').Count -gt 0 -and [bool]$pathEntry.IsDirectory)
        {
            continue
        }
        $path = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
        if (-not $path)
        {
            continue
        }
        if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        {
            $filtered.Add([pscustomobject]@{
                    Path = $path
                    Action = [string]$pathEntry.Action
                    CopyFromPath = [string]$pathEntry.CopyFromPath
                    CopyFromRev = $pathEntry.CopyFromRev
                    IsDirectory = $false
                }) | Out-Null
        }
    }
    return $filtered.ToArray()
}
function Set-DiffStatCollectionProperty
{
    <#
    .SYNOPSIS
        差分統計コレクション項目を指定プロパティで統一設定する。
    .DESCRIPTION
        辞書や配列で保持した差分統計に対して、指定プロパティを一括設定する。
        構造差を吸収して更新処理を共通化し、補正ロジックの重複を減らす。
    .PARAMETER TargetStat
        TargetStat の値を指定する。
    .PARAMETER SourceStat
        SourceStat の値を指定する。
    .PARAMETER PropertyName
        PropertyName の値を指定する。
    .PARAMETER AsString
        AsString の値を指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$TargetStat, [object]$SourceStat, [string]$PropertyName, [switch]$AsString)
    if ($TargetStat.PSObject.Properties.Match($PropertyName).Count -eq 0)
    {
        return
    }

    $sourceItems = New-Object 'System.Collections.Generic.List[object]'
    if ($SourceStat.PSObject.Properties.Match($PropertyName).Count -gt 0 -and $null -ne $SourceStat.$PropertyName)
    {
        $sourceValue = $SourceStat.$PropertyName
        if ($sourceValue -is [System.Collections.IEnumerable] -and -not ($sourceValue -is [string]))
        {
            foreach ($item in $sourceValue)
            {
                if ($AsString)
                {
                    $sourceItems.Add([string]$item) | Out-Null
                }
                else
                {
                    $sourceItems.Add($item) | Out-Null
                }
            }
        }
        else
        {
            if ($AsString)
            {
                $sourceItems.Add([string]$sourceValue) | Out-Null
            }
            else
            {
                $sourceItems.Add($sourceValue) | Out-Null
            }
        }
    }

    $targetValue = $TargetStat.$PropertyName
    if ($targetValue -is [System.Collections.IList])
    {
        $targetValue.Clear()
        foreach ($item in $sourceItems.ToArray())
        {
            $targetValue.Add($item) | Out-Null
        }
    }
    else
    {
        if ($AsString)
        {
            $TargetStat.$PropertyName = @($sourceItems.ToArray() | ForEach-Object { [string]$_ })
        }
        else
        {
            $TargetStat.$PropertyName = $sourceItems.ToArray()
        }
    }
}
function Clear-DiffStatCollectionProperty
{
    <#
    .SYNOPSIS
        差分統計コレクション項目の指定プロパティをクリアする。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$TargetStat, [string]$PropertyName)
    if ($TargetStat.PSObject.Properties.Match($PropertyName).Count -eq 0)
    {
        return
    }
    $targetValue = $TargetStat.$PropertyName
    if ($targetValue -is [System.Collections.IList])
    {
        $targetValue.Clear()
    }
    else
    {
        $TargetStat.$PropertyName = @()
    }
}
function Set-DiffStatFromSource
{
    <#
    .SYNOPSIS
        差分統計オブジェクトを別ソース値で上書き反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$TargetStat, [object]$SourceStat)
    $TargetStat.AddedLines = [int]$SourceStat.AddedLines
    $TargetStat.DeletedLines = [int]$SourceStat.DeletedLines
    Set-DiffStatCollectionProperty -TargetStat $TargetStat -SourceStat $SourceStat -PropertyName 'Hunks'
    Set-DiffStatCollectionProperty -TargetStat $TargetStat -SourceStat $SourceStat -PropertyName 'AddedLineHashes' -AsString
    Set-DiffStatCollectionProperty -TargetStat $TargetStat -SourceStat $SourceStat -PropertyName 'DeletedLineHashes' -AsString
    if ($TargetStat.PSObject.Properties.Match('IsBinary').Count -gt 0 -and $SourceStat.PSObject.Properties.Match('IsBinary').Count -gt 0)
    {
        $TargetStat.IsBinary = [bool]$SourceStat.IsBinary
    }
}
function Reset-DiffStatForRemovedPath
{
    <#
    .SYNOPSIS
        削除扱いパスの差分統計を空変更状態へ初期化する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$DiffStat)
    $DiffStat.AddedLines = 0
    $DiffStat.DeletedLines = 0
    Clear-DiffStatCollectionProperty -TargetStat $DiffStat -PropertyName 'Hunks'
    Clear-DiffStatCollectionProperty -TargetStat $DiffStat -PropertyName 'AddedLineHashes'
    Clear-DiffStatCollectionProperty -TargetStat $DiffStat -PropertyName 'DeletedLineHashes'
}
function Update-RenamePairDiffStat
{
    <#
    .SYNOPSIS
        リネーム対の実差分を取得して二重計上を補正する。
    .DESCRIPTION
        rename ペアの実差分を old@copyfrom と new@rev で再取得し、実際の変更量を求める。
        ナイーブ集計との差分をコミット統計へ反映し、追加削除の二重計上を補正する。
        必要時は hunk と行ハッシュも置き換え、後段の詳細解析精度を維持する。
    .PARAMETER Commit
        解析対象のコミット情報を指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER DiffArguments
        svn diff 実行時に付与する追加引数配列を指定する。
    .PARAMETER DeadDetailLevel
        DeadDetailLevel の値を指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$Commit, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments, [int]$DeadDetailLevel)
    $deletedSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        if (([string]$pathEntry.Action).ToUpperInvariant() -eq 'D')
        {
            $null = $deletedSet.Add((ConvertTo-PathKey -Path ([string]$pathEntry.Path)))
        }
    }

    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        $action = ([string]$pathEntry.Action).ToUpperInvariant()
        if (($action -ne 'A' -and $action -ne 'R') -or [string]::IsNullOrWhiteSpace([string]$pathEntry.CopyFromPath))
        {
            continue
        }

        $newPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
        $oldPath = ConvertTo-PathKey -Path ([string]$pathEntry.CopyFromPath)
        if (-not $newPath -or -not $oldPath -or -not $deletedSet.Contains($oldPath))
        {
            continue
        }
        if (-not $Commit.FileDiffStats.ContainsKey($oldPath) -or -not $Commit.FileDiffStats.ContainsKey($newPath))
        {
            continue
        }

        $copyRev = $pathEntry.CopyFromRev
        if ($null -eq $copyRev)
        {
            $copyRev = $Revision - 1
        }

        $compareArguments = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $DiffArguments)
        {
            $compareArguments.Add([string]$item) | Out-Null
        }
        $compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $oldPath + '@' + [string]$copyRev)) | Out-Null
        $compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $newPath + '@' + [string]$Revision)) | Out-Null

        $realDiff = Invoke-SvnCommand -Arguments $compareArguments.ToArray() -ErrorContext ("svn diff rename pair r{0} {1}->{2}" -f $Revision, $oldPath, $newPath)
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

        $newStat = $Commit.FileDiffStats[$newPath]
        $oldStat = $Commit.FileDiffStats[$oldPath]
        Set-DiffStatFromSource -TargetStat $newStat -SourceStat $realStat
        Reset-DiffStatForRemovedPath -DiffStat $oldStat
    }
}
function Set-CommitDerivedMetric
{
    <#
    .SYNOPSIS
        コミット単位の派生指標と短縮メッセージを設定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$Commit)
    $added = 0
    $deleted = 0
    $churnPerFile = @()
    foreach ($filePath in @($Commit.FilesChanged))
    {
        $diffStat = $Commit.FileDiffStats[$filePath]
        $added += [int]$diffStat.AddedLines
        $deleted += [int]$diffStat.DeletedLines
        $churnPerFile += ([int]$diffStat.AddedLines + [int]$diffStat.DeletedLines)
    }

    $Commit.AddedLines = $added
    $Commit.DeletedLines = $deleted
    $Commit.Churn = $added + $deleted
    $Commit.Entropy = Get-Entropy -Values @($churnPerFile | ForEach-Object { [double]$_ })

    $message = [string]$Commit.Message
    if ($null -eq $message)
    {
        $message = ''
    }
    $Commit.MsgLen = $message.Length
    $oneLineMessage = ($message -replace '(\r?\n)+', ' ').Trim()
    if ($oneLineMessage.Length -gt 140)
    {
        $oneLineMessage = $oneLineMessage.Substring(0, 140) + '...'
    }
    $Commit.MessageShort = $oneLineMessage
}
function Initialize-CommitDiffData
{
    <#
    .SYNOPSIS
        diff 取得・フィルタ・補正を実行してコミット差分データを初期化する。
    .DESCRIPTION
        コミット一覧に対して diff の取得・パースを並列実行し、リビジョン差分を初期化する。
        拡張子とパス条件で対象を絞り、ログ情報との突合で最終的な FilesChanged を確定する。
        rename 補正と派生指標計算を含め、後続集計が使う基礎データを完成させる。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER DiffArguments
        svn diff 実行時に付与する追加引数配列を指定する。
    .PARAMETER DeadDetailLevel
        DeadDetailLevel の値を指定する。
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object[]]$Commits,
        [string]$CacheDir,
        [string]$TargetUrl,
        [string[]]$DiffArguments,
        [int]$DeadDetailLevel,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePathPatterns,
        [string[]]$ExcludePathPatterns,
        [int]$Parallel = 1
    )
    $revToAuthor = @{}
    $phaseAItems = [System.Collections.Generic.List[object]]::new()
    foreach ($commit in @($Commits))
    {
        $revision = [int]$commit.Revision
        $revToAuthor[$revision] = [string]$commit.Author
        [void]$phaseAItems.Add([pscustomobject]@{
                Revision = $revision
                CacheDir = $CacheDir
                TargetUrl = $TargetUrl
                DiffArguments = @($DiffArguments)
                DeadDetailLevel = $DeadDetailLevel
            })
    }

    $phaseAResults = @()
    if ($phaseAItems.Count -gt 0)
    {
        $phaseAWorker = {
            param($Item, $Index)
            $null = $Index # Required by Invoke-ParallelWork contract
            $diffText = Get-CachedOrFetchDiffText -CacheDir $Item.CacheDir -Revision ([int]$Item.Revision) -TargetUrl $Item.TargetUrl -DiffArguments @($Item.DiffArguments)
            $rawDiffByPath = ConvertFrom-SvnUnifiedDiff -DiffText $diffText -DetailLevel ([int]$Item.DeadDetailLevel)
            [pscustomobject]@{
                Revision = [int]$Item.Revision
                RawDiffByPath = $rawDiffByPath
            }
        }
        $phaseAResults = @(Invoke-ParallelWork -InputItems $phaseAItems.ToArray() -WorkerScript $phaseAWorker -MaxParallel $Parallel -RequiredFunctions @(
                'ConvertTo-PathKey',
                'ConvertTo-LineHash',
                'ConvertTo-ContextHash',
                'ConvertFrom-SvnUnifiedDiff',
                'Join-CommandArgument',
                'Invoke-SvnCommand',
                'Get-CachedOrFetchDiffText'
            ) -SessionVariables @{
                SvnExecutable = $script:SvnExecutable
                SvnGlobalArguments = @($script:SvnGlobalArguments)
            } -ErrorContext 'commit diff prefetch')
    }

    $rawDiffByRevision = @{}
    foreach ($result in @($phaseAResults))
    {
        $rawDiffByRevision[[int]$result.Revision] = $result.RawDiffByPath
    }

    foreach ($commit in @($Commits))
    {
        $revision = [int]$commit.Revision
        $rawDiffByPath = @{}
        if ($rawDiffByRevision.ContainsKey($revision))
        {
            $rawDiffByPath = $rawDiffByRevision[$revision]
        }
        $filteredDiffByPath = @{}
        foreach ($path in $rawDiffByPath.Keys)
        {
            if (Test-ShouldCountFile -FilePath $path -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
            {
                $filteredDiffByPath[$path] = $rawDiffByPath[$path]
            }
        }
        $commit.FileDiffStats = $filteredDiffByPath

        $commit.ChangedPathsFiltered = Get-FilteredChangedPathEntry -ChangedPaths @($commit.ChangedPaths) -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns

        $allowedFilePathSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($pathEntry in @($commit.ChangedPathsFiltered))
        {
            $path = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
            if ($path)
            {
                $null = $allowedFilePathSet.Add($path)
            }
        }

        $filteredByLog = @{}
        foreach ($path in $commit.FileDiffStats.Keys)
        {
            if ($allowedFilePathSet.Contains([string]$path))
            {
                $filteredByLog[$path] = $commit.FileDiffStats[$path]
            }
        }
        $commit.FileDiffStats = $filteredByLog
        $commit.FilesChanged = @($commit.FileDiffStats.Keys | Sort-Object)

        Update-RenamePairDiffStat -Commit $commit -Revision $revision -TargetUrl $TargetUrl -DiffArguments $DiffArguments -DeadDetailLevel $DeadDetailLevel
        Set-CommitDerivedMetric -Commit $commit
    }
    return $revToAuthor
}
# endregion 差分処理パイプライン
# region Strict メトリクス更新
function New-CommitRowFromCommit
{
    <#
    .SYNOPSIS
        コミット配列から commits.csv 出力行を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits)
    return @(
        $Commits | Sort-Object Revision | ForEach-Object {
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
}
function Get-AuthorModifiedOthersSurvivedCount
{
    <#
    .SYNOPSIS
        他者コード変更行のうち最終版で生存した行数を作者別に集計する。
    .PARAMETER BlameByFile
        ファイルごとの blame 結果キャッシュを指定する。
    .PARAMETER RevsWhereKilledOthers
        RevsWhereKilledOthers の値を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$BlameByFile, [System.Collections.Generic.HashSet[string]]$RevsWhereKilledOthers, [int]$FromRevision, [int]$ToRevision)
    $authorModifiedOthersSurvived = @{}
    foreach ($file in $BlameByFile.Keys)
    {
        $blameData = $BlameByFile[$file]
        if ($null -eq $blameData -or $null -eq $blameData.Lines)
        {
            continue
        }
        foreach ($blameLine in @($blameData.Lines))
        {
            $blameLineRevision = $null
            try
            {
                $blameLineRevision = [int]$blameLine.Revision
            }
            catch
            {
                continue
            }
            if ($null -eq $blameLineRevision -or $blameLineRevision -lt $FromRevision -or $blameLineRevision -gt $ToRevision)
            {
                continue
            }
            $blameLineAuthor = Get-NormalizedAuthorName -Author ([string]$blameLine.Author)
            $lookupKey = [string]$blameLineRevision + [char]31 + $blameLineAuthor
            if ($RevsWhereKilledOthers.Contains($lookupKey))
            {
                Add-Count -Table $authorModifiedOthersSurvived -Key $blameLineAuthor
            }
        }
    }
    return $authorModifiedOthersSurvived
}
function Update-FileRowWithStrictMetric
{
    <#
    .SYNOPSIS
        Strict 詳細値と blame 結果で files 行メトリクスを更新する。
    .DESCRIPTION
        strict 詳細集計と blame 結果を使って files.csv 行へ厳密値を反映する。
        rename 別名や存在有無を考慮した段階的 lookup で blame 取得の失敗を抑える。
        生存・消滅・反復・所有率を一括更新し、可視化に使う列整合を保つ。
    .PARAMETER FileRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER RenameMap
        RenameMap の値を指定する。
    .PARAMETER StrictDetail
        StrictDetail の値を指定する。
    .PARAMETER ExistingFileSet
        ExistingFileSet の値を指定する。
    .PARAMETER BlameByFile
        ファイルごとの blame 結果キャッシュを指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object[]]$FileRows,
        [hashtable]$RenameMap,
        [object]$StrictDetail,
        [System.Collections.Generic.HashSet[string]]$ExistingFileSet,
        [hashtable]$BlameByFile,
        [string]$TargetUrl,
        [int]$ToRevision,
        [string]$CacheDir
    )
    foreach ($row in @($FileRows))
    {
        $filePath = [string]$row.'ファイルパス'
        $resolvedFilePath = Resolve-PathByRenameMap -FilePath $filePath -RenameMap $RenameMap
        $isOldRenamePath = ($RenameMap.ContainsKey($filePath) -and ([string]$RenameMap[$filePath] -ne $filePath))
        $metricKey = if ($isOldRenamePath)
        {
            $null
        }
        else
        {
            $resolvedFilePath
        }

        $blame = $null
        $existsAtToRevision = $false
        if ($metricKey)
        {
            $existsAtToRevision = $ExistingFileSet.Contains([string]$metricKey)
        }
        $lookupCandidates = if ($existsAtToRevision)
        {
            @($metricKey, $filePath, $resolvedFilePath)
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
            if ($BlameByFile.ContainsKey($lookup))
            {
                $blame = $BlameByFile[$lookup]
                break
            }
            try
            {
                $tmpBlame = Get-SvnBlameSummary -Repo $TargetUrl -FilePath $lookup -ToRevision $ToRevision -CacheDir $CacheDir
                $BlameByFile[$lookup] = $tmpBlame
                $blame = $tmpBlame
                break
            }
            catch
            {
                $lookupErrors.Add(([string]$lookup + ': ' + $_.Exception.Message)) | Out-Null
            }
        }
        if ($null -eq $blame -and $existsAtToRevision)
        {
            throw ("Strict file blame lookup failed for '{0}' at r{1}. Attempts: {2}" -f $metricKey, $ToRevision, ($lookupErrors.ToArray() -join ' | '))
        }

        $survived = 0
        $dead = 0
        $selfCancel = 0
        $crossRevert = 0
        $repeatedHunk = 0
        $pingPong = 0
        $internalMoveCount = 0
        if ($metricKey)
        {
            $survived = Get-HashtableIntValue -Table $StrictDetail.FileSurvived -Key $metricKey
            $dead = Get-HashtableIntValue -Table $StrictDetail.FileDead -Key $metricKey
            $selfCancel = Get-HashtableIntValue -Table $StrictDetail.FileSelfCancel -Key $metricKey
            $crossRevert = Get-HashtableIntValue -Table $StrictDetail.FileCrossRevert -Key $metricKey
            $repeatedHunk = Get-HashtableIntValue -Table $StrictDetail.FileRepeatedHunk -Key $metricKey
            $pingPong = Get-HashtableIntValue -Table $StrictDetail.FilePingPong -Key $metricKey
            $internalMoveCount = Get-HashtableIntValue -Table $StrictDetail.FileInternalMoveCount -Key $metricKey
        }

        $row.'生存行数 (範囲指定)' = $survived
        $row.($script:ColDeadAdded) = $dead
        $row.'自己相殺行数 (合計)' = $selfCancel
        $row.'他者差戻行数 (合計)' = $crossRevert
        $row.'同一箇所反復編集数 (合計)' = $repeatedHunk
        $row.'ピンポン回数 (合計)' = $pingPong
        $row.'内部移動行数 (合計)' = $internalMoveCount

        $maxOwned = 0
        if ($null -ne $blame -and $blame.LineCountByAuthor.Count -gt 0)
        {
            $maxOwned = ($blame.LineCountByAuthor.Values | Measure-Object -Maximum).Maximum
        }
        $topBlameShare = if ($null -ne $blame -and $blame.LineCountTotal -gt 0)
        {
            $maxOwned / [double]$blame.LineCountTotal
        }
        else
        {
            0
        }
        $row.'最多作者blame占有率' = Format-MetricValue -Value $topBlameShare
    }
}
function Update-CommitterRowWithStrictMetric
{
    <#
    .SYNOPSIS
        Strict 詳細値と所有情報で committers 行メトリクスを更新する。
    .DESCRIPTION
        strict 詳細結果と所有情報を突き合わせ、committers.csv 行へ厳密値を反映する。
        自己/他者消滅や反復編集など関連列を同時更新し、相互整合を維持する。
    .PARAMETER CommitterRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER AuthorSurvived
        AuthorSurvived の値を指定する。
    .PARAMETER AuthorOwned
        AuthorOwned の値を指定する。
    .PARAMETER OwnedTotal
        OwnedTotal の値を指定する。
    .PARAMETER StrictDetail
        StrictDetail の値を指定する。
    .PARAMETER AuthorModifiedOthersSurvived
        AuthorModifiedOthersSurvived の値を指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object[]]$CommitterRows,
        [hashtable]$AuthorSurvived,
        [hashtable]$AuthorOwned,
        [int]$OwnedTotal,
        [object]$StrictDetail,
        [hashtable]$AuthorModifiedOthersSurvived
    )
    foreach ($row in @($CommitterRows))
    {
        $author = [string]$row.'作者'
        $survived = Get-HashtableIntValue -Table $AuthorSurvived -Key $author
        $owned = Get-HashtableIntValue -Table $AuthorOwned -Key $author
        $dead = Get-HashtableIntValue -Table $StrictDetail.AuthorDead -Key $author
        $selfDead = Get-HashtableIntValue -Table $StrictDetail.AuthorSelfDead -Key $author
        $otherDead = Get-HashtableIntValue -Table $StrictDetail.AuthorOtherDead -Key $author
        $repeatedHunk = Get-HashtableIntValue -Table $StrictDetail.AuthorRepeatedHunk -Key $author
        $pingPong = Get-HashtableIntValue -Table $StrictDetail.AuthorPingPong -Key $author
        $internalMove = Get-HashtableIntValue -Table $StrictDetail.AuthorInternalMoveCount -Key $author
        $modifiedOthersCode = Get-HashtableIntValue -Table $StrictDetail.AuthorModifiedOthersCode -Key $author
        $modifiedOthersSurvived = Get-HashtableIntValue -Table $AuthorModifiedOthersSurvived -Key $author

        $row.'生存行数' = $survived
        $row.($script:ColDeadAdded) = $dead
        $row.'所有行数' = $owned
        $ownShare = if ($OwnedTotal -gt 0)
        {
            $owned / [double]$OwnedTotal
        }
        else
        {
            0
        }
        $row.'所有割合' = Format-MetricValue -Value $ownShare
        $row.'自己相殺行数' = $selfDead
        $row.'自己差戻行数' = $selfDead
        $row.'他者差戻行数' = $otherDead
        $row.'被他者削除行数' = $otherDead
        $row.'同一箇所反復編集数' = $repeatedHunk
        $row.'ピンポン回数' = $pingPong
        $row.'内部移動行数' = $internalMove
        $row.($script:ColSelfDead) = $selfDead
        $row.($script:ColOtherDead) = $otherDead
        $row.'他者コード変更行数' = $modifiedOthersCode
        $row.'他者コード変更生存行数' = $modifiedOthersSurvived
    }
}
function Update-StrictAttributionMetric
{
    <#
    .SYNOPSIS
        Strict 帰属解析を実行しファイル行と作者行へ反映する。
    .DESCRIPTION
        strict 帰属解析の実行と所有率計算をオーケストレーションし、更新順序を統制する。
        rename map、line death detail、ownership blame を統合して作者行とファイル行を更新する。
        並列取得時も単一集約経路でカウントを反映し、再現可能な出力を保証する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER RevToAuthor
        リビジョン番号と作者の対応表を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER CacheDir
        キャッシュディレクトリのパスを指定する。
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER FileRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER CommitterRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [object[]]$FileRows,
        [object[]]$CommitterRows,
        [int]$Parallel = 1
    )
    if (@($FileRows).Count -le 0)
    {
        return
    }

    $renameMap = Get-RenameMap -Commits $Commits
    $strictDetail = Get-ExactDeathAttribution -Commits $Commits -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -RenameMap $renameMap -Parallel $Parallel
    if ($null -eq $strictDetail)
    {
        throw "Strict death attribution returned null."
    }

    $authorSurvived = $strictDetail.AuthorSurvived
    $authorOwned = @{}
    $ownedTotal = 0
    $blameByFile = @{}
    $ownershipTargets = @(Get-AllRepositoryFile -Repo $TargetUrl -Revision $ToRevision -IncludeExt $IncludeExtensions -ExcludeExt $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
    $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($file in $ownershipTargets)
    {
        $null = $existingFileSet.Add([string]$file)
    }
    if ($Parallel -le 1)
    {
        foreach ($file in $ownershipTargets)
        {
            try
            {
                $blame = Get-SvnBlameSummary -Repo $TargetUrl -FilePath $file -ToRevision $ToRevision -CacheDir $CacheDir
            }
            catch
            {
                throw ("Strict ownership blame failed for '{0}' at r{1}: {2}" -f $file, $ToRevision, $_.Exception.Message)
            }
            $blameByFile[$file] = $blame
            $ownedTotal += [int]$blame.LineCountTotal
            foreach ($author in $blame.LineCountByAuthor.Keys)
            {
                Add-Count -Table $authorOwned -Key ([string]$author) -Delta ([int]$blame.LineCountByAuthor[$author])
            }
        }
    }
    else
    {
        $ownershipItems = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $ownershipTargets)
        {
            [void]$ownershipItems.Add([pscustomobject]@{
                    FilePath = [string]$file
                    ToRevision = [int]$ToRevision
                    TargetUrl = $TargetUrl
                    CacheDir = $CacheDir
                })
        }

        $ownershipWorker = {
            param($Item, $Index)
            $null = $Index # Required by Invoke-ParallelWork contract
            try
            {
                $blame = Get-SvnBlameSummary -Repo $Item.TargetUrl -FilePath ([string]$Item.FilePath) -ToRevision ([int]$Item.ToRevision) -CacheDir $Item.CacheDir
                [pscustomobject]@{
                    FilePath = [string]$Item.FilePath
                    Blame = $blame
                }
            }
            catch
            {
                throw ("Strict ownership blame failed for '{0}' at r{1}: {2}" -f [string]$Item.FilePath, [int]$Item.ToRevision, $_.Exception.Message)
            }
        }
        $ownershipResults = @(Invoke-ParallelWork -InputItems $ownershipItems.ToArray() -WorkerScript $ownershipWorker -MaxParallel $Parallel -RequiredFunctions @(
                'ConvertTo-PathKey',
                'Get-Sha1Hex',
                'Get-PathCacheHash',
                'Get-BlameCachePath',
                'Read-BlameCacheFile',
                'Write-BlameCacheFile',
                'ConvertFrom-SvnXmlText',
                'ConvertFrom-SvnBlameXml',
                'Join-CommandArgument',
                'Invoke-SvnCommand',
                'Get-SvnBlameSummary'
            ) -SessionVariables @{
                SvnExecutable = $script:SvnExecutable
                SvnGlobalArguments = @($script:SvnGlobalArguments)
            } -ErrorContext 'strict ownership blame')

        foreach ($entry in @($ownershipResults))
        {
            $file = [string]$entry.FilePath
            $blame = $entry.Blame
            $blameByFile[$file] = $blame
            $ownedTotal += [int]$blame.LineCountTotal
            foreach ($author in $blame.LineCountByAuthor.Keys)
            {
                Add-Count -Table $authorOwned -Key ([string]$author) -Delta ([int]$blame.LineCountByAuthor[$author])
            }
        }
    }

    $authorModifiedOthersSurvived = Get-AuthorModifiedOthersSurvivedCount -BlameByFile $blameByFile -RevsWhereKilledOthers $strictDetail.RevsWhereKilledOthers -FromRevision $FromRevision -ToRevision $ToRevision
    Update-FileRowWithStrictMetric -FileRows $FileRows -RenameMap $renameMap -StrictDetail $strictDetail -ExistingFileSet $existingFileSet -BlameByFile $blameByFile -TargetUrl $TargetUrl -ToRevision $ToRevision -CacheDir $CacheDir
    Update-CommitterRowWithStrictMetric -CommitterRows $CommitterRows -AuthorSurvived $authorSurvived -AuthorOwned $authorOwned -OwnedTotal $ownedTotal -StrictDetail $strictDetail -AuthorModifiedOthersSurvived $authorModifiedOthersSurvived
}
# endregion Strict メトリクス更新
# region ヘッダーとメタデータ
function Get-MetricHeader
{
    <#
    .SYNOPSIS
        CSV 出力に使う列ヘッダー定義を返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    return [pscustomobject]@{
        Committer = @('作者', 'コミット数', '活動日数', '変更ファイル数', '変更ディレクトリ数', '追加行数', '削除行数', '純増行数', '総チャーン', 'コミットあたりチャーン', '削除対追加比', 'チャーン対純増比', 'バイナリ変更回数', '追加アクション数', '変更アクション数', '削除アクション数', '置換アクション数', '生存行数', $script:ColDeadAdded, '所有行数', '所有割合', '自己相殺行数', '自己差戻行数', '他者差戻行数', '被他者削除行数', '同一箇所反復編集数', 'ピンポン回数', '内部移動行数', $script:ColSelfDead, $script:ColOtherDead, '他者コード変更行数', '他者コード変更生存行数', '変更エントロピー', '平均共同作者数', '最大共同作者数', 'メッセージ総文字数', 'メッセージ平均文字数', '課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
        File = @('ファイルパス', 'コミット数', '作者数', '追加行数', '削除行数', '純増行数', '総チャーン', 'バイナリ変更回数', '作成回数', '削除回数', '置換回数', '初回変更リビジョン', '最終変更リビジョン', '平均変更間隔日数', '生存行数 (範囲指定)', $script:ColDeadAdded, '最多作者チャーン占有率', '最多作者blame占有率', '自己相殺行数 (合計)', '他者差戻行数 (合計)', '同一箇所反復編集数 (合計)', 'ピンポン回数 (合計)', '内部移動行数 (合計)', 'ホットスポットスコア', 'ホットスポット順位')
        Commit = @('リビジョン', '日時', '作者', 'メッセージ文字数', 'メッセージ', '変更ファイル数', '追加行数', '削除行数', 'チャーン', 'エントロピー')
        Coupling = @('ファイルA', 'ファイルB', '共変更回数', 'Jaccard', 'リフト値')
    }
}
function New-RunMetaData
{
    <#
    .SYNOPSIS
        実行条件・集計件数・環境情報を run_meta 用構造にまとめる。
    .DESCRIPTION
        実行条件、フィルタ設定、成果物件数、処理時間を run_meta 用に集約する。
        strict キャッシュ統計や非厳密指標の注記を含め、再実行可能な監査情報を残す。
        CSV と可視化の出力先をまとめ、実行結果の追跡性を高める。
    .PARAMETER StartTime
        StartTime の値を指定する。
    .PARAMETER EndTime
        EndTime の値を指定する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER AuthorFilter
        AuthorFilter の値を指定する。
    .PARAMETER SvnVersion
        SvnVersion の値を指定する。
    .PARAMETER NoBlame
        NoBlame の値を指定する。
    .PARAMETER DeadDetailLevel
        DeadDetailLevel の値を指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    .PARAMETER TopN
        上位抽出件数を指定する。
    .PARAMETER Encoding
        出力時に使用する文字エンコーディングを指定する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER FileRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER OutDir
        出力先ディレクトリを指定する。
    .PARAMETER IncludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER EmitPlantUml
        EmitPlantUml の値を指定する。
    .PARAMETER NonInteractive
        NonInteractive の値を指定する。
    .PARAMETER TrustServerCert
        TrustServerCert の値を指定する。
    .PARAMETER IgnoreSpaceChange
        IgnoreSpaceChange の値を指定する。
    .PARAMETER IgnoreAllSpace
        IgnoreAllSpace の値を指定する。
    .PARAMETER IgnoreEolStyle
        IgnoreEolStyle の値を指定する。
    .PARAMETER IncludeProperties
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ForceBinary
        ForceBinary の値を指定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$AuthorFilter,
        [string]$SvnVersion,
        [switch]$NoBlame,
        [int]$DeadDetailLevel,
        [int]$Parallel,
        [int]$TopN,
        [string]$Encoding,
        [object[]]$Commits,
        [object[]]$FileRows,
        [string]$OutDir,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [switch]$EmitPlantUml,
        [switch]$NonInteractive,
        [switch]$TrustServerCert,
        [switch]$IgnoreSpaceChange,
        [switch]$IgnoreAllSpace,
        [switch]$IgnoreEolStyle,
        [switch]$IncludeProperties,
        [switch]$ForceBinary
    )
    return [ordered]@{
        StartTime = $StartTime.ToString('o')
        EndTime = $EndTime.ToString('o')
        DurationSeconds = Format-MetricValue -Value ((New-TimeSpan -Start $StartTime -End $EndTime).TotalSeconds)
        RepoUrl = $TargetUrl
        FromRev = $FromRevision
        ToRev = $ToRevision
        AuthorFilter = $AuthorFilter
        SvnExecutable = $script:SvnExecutable
        SvnVersion = $SvnVersion
        StrictMode = $true
        NoBlame = [bool]$NoBlame
        DeadDetailLevel = $DeadDetailLevel
        Parallel = $Parallel
        TopN = $TopN
        Encoding = $Encoding
        CommitCount = @($Commits).Count
        FileCount = @($FileRows).Count
        OutputDirectory = (Resolve-Path $OutDir).Path
        StrictBlameCallCount = [int]($script:StrictBlameCacheHits + $script:StrictBlameCacheMisses)
        StrictBlameCacheHits = [int]$script:StrictBlameCacheHits
        StrictBlameCacheMisses = [int]$script:StrictBlameCacheMisses
        NonStrictMetrics = @('課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
        NonStrictReason = '正規表現ベースのヒューリスティックであり厳密化不可能'
        Parameters = [ordered]@{
            IncludePaths = $IncludePaths
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
        Outputs = [ordered]@{
            CommittersCsv = 'committers.csv'
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
}
function Write-RunSummary
{
    <#
    .SYNOPSIS
        実行サマリーをコンソールへ整形表示する。
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER FromRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER ToRevision
        処理対象のリビジョン値を指定する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER FileRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER OutDir
        出力先ディレクトリを指定する。
    #>
    [CmdletBinding()]
    param([string]$TargetUrl, [int]$FromRevision, [int]$ToRevision, [object[]]$Commits, [object[]]$FileRows, [string]$OutDir)
    $phaseLabel = 'StrictMode'
    Write-Host ''
    Write-Host ("===== NarutoCode {0} =====" -f $phaseLabel)
    Write-Host ("Repo         : {0}" -f $TargetUrl)
    Write-Host ("Range        : r{0} -> r{1}" -f $FromRevision, $ToRevision)
    Write-Host ("Commits      : {0}" -f @($Commits).Count)
    Write-Host ("Files        : {0}" -f @($FileRows).Count)
    Write-Host ("OutDir       : {0}" -f (Resolve-Path $OutDir).Path)
}
function Get-RenameMap
{
    <#
    .SYNOPSIS
        コミット履歴から旧パスと新パスの対応表を構築する。
    .DESCRIPTION
        コミット履歴を時系列で走査し、旧パスから最新パスへの対応を段階的に構築する。
        連鎖リネームを伝播更新して、後段の path 解決が一意になるよう整備する。
    #>
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

# endregion ヘッダーとメタデータ
try
{
    # --- ステップ 1: パラメータの初期化と検証 ---
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
    $script:SvnGlobalArguments = Get-SvnGlobalArgumentList -Username $Username -Password $Password -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert

    $targetUrl = Resolve-SvnTargetUrl -Target $RepoUrl
    $svnVersion = Get-SvnVersionSafe

    # --- ステップ 2: SVN ログの取得とパース ---
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

    # --- ステップ 3: 差分の取得とコミット単位の差分統計構築 ---
    $diffArgs = Get-SvnDiffArgumentList -IncludeProperties:$IncludeProperties -ForceBinary:$ForceBinary -IgnoreAllSpace:$IgnoreAllSpace -IgnoreSpaceChange:$IgnoreSpaceChange -IgnoreEolStyle:$IgnoreEolStyle
    $revToAuthor = Initialize-CommitDiffData -Commits $commits -CacheDir $cacheDir -TargetUrl $targetUrl -DiffArguments $diffArgs -DeadDetailLevel $DeadDetailLevel -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths -Parallel $Parallel

    # --- ステップ 4: 基本メトリクス算出（コミッター / ファイル / カップリング / コミット） ---
    $committerRows = @(Get-CommitterMetric -Commits $commits)
    $fileRows = @(Get-FileMetric -Commits $commits)
    $couplingRows = @(Get-CoChangeMetric -Commits $commits -TopNCount $TopN)
    $commitRows = @(New-CommitRowFromCommit -Commits $commits)

    # --- ステップ 5: Strict 死亡帰属（blame ベースの行追跡） ---
    Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl $targetUrl -FromRevision $FromRev -ToRevision $ToRev -CacheDir $cacheDir -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -FileRows $fileRows -CommitterRows $committerRows -Parallel $Parallel

    # --- ステップ 6: CSV レポート出力 ---
    $headers = Get-MetricHeader
    Write-CsvFile -FilePath (Join-Path $OutDir 'committers.csv') -Rows $committerRows -Headers $headers.Committer -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'files.csv') -Rows $fileRows -Headers $headers.File -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'commits.csv') -Rows $commitRows -Headers $headers.Commit -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDir 'couplings.csv') -Rows $couplingRows -Headers $headers.Coupling -EncodingName $Encoding
    # --- ステップ 7: PlantUML 出力（指定時のみ） ---
    if ($EmitPlantUml)
    {
        Write-PlantUmlFile -OutDirectory $OutDir -Committers $committerRows -Files $fileRows -Couplings $couplingRows -TopNCount $TopN -EncodingName $Encoding
    }

    # --- ステップ 8: 実行メタデータとサマリーの書き出し ---
    $finishedAt = Get-Date
    $meta = New-RunMetaData -StartTime $startedAt -EndTime $finishedAt -TargetUrl $targetUrl -FromRevision $FromRev -ToRevision $ToRev -AuthorFilter $Author -SvnVersion $svnVersion -NoBlame:$NoBlame -DeadDetailLevel $DeadDetailLevel -Parallel $Parallel -TopN $TopN -Encoding $Encoding -Commits $commits -FileRows $fileRows -OutDir $OutDir -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -EmitPlantUml:$EmitPlantUml -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -IgnoreSpaceChange:$IgnoreSpaceChange -IgnoreAllSpace:$IgnoreAllSpace -IgnoreEolStyle:$IgnoreEolStyle -IncludeProperties:$IncludeProperties -ForceBinary:$ForceBinary
    Write-JsonFile -Data $meta -FilePath (Join-Path $OutDir 'run_meta.json') -Depth 12 -EncodingName $Encoding

    Write-RunSummary -TargetUrl $targetUrl -FromRevision $FromRev -ToRevision $ToRev -Commits $commits -FileRows $fileRows -OutDir $OutDir

    [pscustomobject]@{
        OutDir = (Resolve-Path $OutDir).Path
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
