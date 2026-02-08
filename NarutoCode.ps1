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
    [switch]$EmitCharts,
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
$script:ColDeadAdded = '消滅追加行数'       # 追加されたが ToRev 時点で生存していない行数
$script:ColSelfDead = '自己消滅行数'         # 追加した本人が後のコミットで削除した行数
$script:ColOtherDead = '被他者消滅行数'      # 別の作者によって削除された行数
$script:StrictBlameCacheHits = 0
$script:StrictBlameCacheMisses = 0

# region Utility
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
function ConvertTo-NormalizedScore
{
    <#
    .SYNOPSIS
        最優秀者を 1 とした正規化スコアへ変換する。
    .DESCRIPTION
        非反転軸は value / max で正規化する。最大値の人が 1.0 になり、
        他の人は実値の比率に応じた位置に配置される。
        反転軸（低いほど良い指標）は (max - value) / (max - min) で
        最小値の人が 1.0 になる。
    .PARAMETER Value
        正規化対象の実測値を指定する。
    .PARAMETER Min
        正規化に使用する最小値を指定する。
    .PARAMETER Max
        正規化に使用する最大値を指定する。
    .PARAMETER Invert
        指定時は正規化結果を反転し、低い値を高スコアとして扱う。
    #>
    param([double]$Value, [double]$Min, [double]$Max, [switch]$Invert)
    if ($Invert)
    {
        if ($Max -eq $Min)
        {
            return 0.0
        }
        $normalized = ($Max - $Value) / ($Max - $Min)
    }
    else
    {
        if ($Max -le 0)
        {
            return 0.0
        }
        $normalized = $Value / $Max
    }
    if ($normalized -lt 0)
    {
        $normalized = 0.0
    }
    if ($normalized -gt 1)
    {
        $normalized = 1.0
    }
    return $normalized
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
                '他者コード変更生存率' = $null
                'ピンポン率' = $null
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
function ConvertTo-SvgColor
{
    <#
    .SYNOPSIS
        ホットスポット順位を赤から緑のグラデーション色に変換する。
    .DESCRIPTION
        順位が低い（1位）ほど赤色、順位が高い（悪い）ほど緑色のグラデーションを返す。
        赤: 高リスク（頻繁に変更されるホットスポット）
        緑: 低リスク（安定したファイル）
    .PARAMETER Rank
        対象ファイルのホットスポット順位を指定する（1以上の整数）。
    .PARAMETER MaxRank
        可視化対象における最下位のホットスポット順位を指定する（1以上の整数）。
    .OUTPUTS
        System.String
        #RRGGBB 形式のカラーコードを返す。
    .EXAMPLE
        ConvertTo-SvgColor -Rank 1 -MaxRank 10
        最もリスクの高い赤色を返す。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Rank,
        [Parameter(Mandatory = $true)]
        [int]$MaxRank
    )

    # 入力値を正の範囲にクランプ
    $clampedRank = [Math]::Max(1, $Rank)
    $clampedMaxRank = [Math]::Max(1, $MaxRank)

    # 0.0〜1.0 の正規化比率を計算
    $ratio = 0.0
    if ($clampedMaxRank -gt 1)
    {
        $ratio = ($clampedRank - 1) / [double]($clampedMaxRank - 1)
    }
    $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $ratio))

    # グラデーション定義: 赤（高リスク）→ 緑（低リスク）
    $startR = 230
    $startG = 57
    $startB = 70
    $endR = 46
    $endG = 160
    $endB = 67

    # 線形補間で RGB 値を算出
    $r = [int][Math]::Round($startR + (($endR - $startR) * $ratio))
    $g = [int][Math]::Round($startG + (($endG - $startG) * $ratio))
    $b = [int][Math]::Round($startB + (($endB - $startB) * $ratio))

    return ('#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b)
}
function Write-FileBubbleChart
{
    <#
    .SYNOPSIS
        ファイル別メトリクスをバブルチャート SVG として出力する。
    .DESCRIPTION
        TopN のファイルをホットスポット順位順で選び、コミット数と作者数を軸に配置する。
        バブル面積は総チャーンに比例させ、色はホットスポット順位を赤から緑で表現する。
        X軸: コミット数、Y軸: 作者数、バブルサイズ: 総チャーン、色: ホットスポット順位
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する（必須）。
    .PARAMETER Files
        Get-FileMetric が返したファイル行データを指定する（必須）。
    .PARAMETER TopNCount
        可視化対象とする上位件数を指定する（0以下の場合は全件）。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    .EXAMPLE
        Write-FileBubbleChart -OutDirectory '.\output' -Files $fileMetrics -TopNCount 50 -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Files,
        [Parameter(Mandatory = $false)]
        [int]$TopNCount = 0,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )

    # 入力検証
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-FileBubbleChart: OutDirectory が空です。'
        return
    }

    if (-not $Files -or @($Files).Count -eq 0)
    {
        Write-Verbose 'Write-FileBubbleChart: Files が空です。SVG を生成しません。'
        return
    }
    $topFiles = @(
        $Files |
            Where-Object {
                $null -ne $_
            } |
            Sort-Object -Property 'ホットスポット順位', 'ファイルパス'
    )
    if ($TopNCount -gt 0)
    {
        $topFiles = @($topFiles | Select-Object -First $TopNCount)
    }

    $svgWidth = 1280.0
    $svgHeight = 760.0
    $plotLeft = 110.0
    $plotTop = 94.0
    $plotRight = $svgWidth - 320.0
    $plotBottom = $svgHeight - 108.0
    $plotWidth = $plotRight - $plotLeft
    $plotHeight = $plotBottom - $plotTop
    $tickCount = 6

    $maxCommit = 0.0
    $maxAuthors = 0.0
    $maxChurn = 0.0
    $maxRank = 1
    foreach ($f in $topFiles)
    {
        $commitCount = [double]$f.'コミット数'
        $authorCount = [double]$f.'作者数'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'
        if ($commitCount -gt $maxCommit)
        {
            $maxCommit = $commitCount
        }
        if ($authorCount -gt $maxAuthors)
        {
            $maxAuthors = $authorCount
        }
        if ($churnCount -gt $maxChurn)
        {
            $maxChurn = $churnCount
        }
        if ($rank -gt $maxRank)
        {
            $maxRank = $rank
        }
    }
    if ($maxCommit -le 0.0)
    {
        $maxCommit = 1.0
    }
    if ($maxAuthors -le 0.0)
    {
        $maxAuthors = 1.0
    }
    if ($maxRank -le 0)
    {
        $maxRank = 1
    }

    $minRadius = 9.0
    $maxRadius = 56.0
    $minArea = [Math]::PI * $minRadius * $minRadius
    $maxArea = [Math]::PI * $maxRadius * $maxRadius
    $radiusCalculator = {
        param([double]$ChurnValue)
        if ($maxChurn -le 0.0)
        {
            return $minRadius
        }
        $ratio = $ChurnValue / $maxChurn
        $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $ratio))
        $area = $minArea + (($maxArea - $minArea) * $ratio)
        return [Math]::Sqrt($area / [Math]::PI)
    }

    $rankStartColor = ConvertTo-SvgColor -Rank 1 -MaxRank $maxRank
    $rankEndColor = ConvertTo-SvgColor -Rank $maxRank -MaxRank $maxRank

    # XML 宣言の encoding を、実際の書き込みエンコーディングと一致させる
    $xmlEncoding = if ($null -ne $EncodingName -and $EncodingName -ne '')
    {
        $EncodingName
    }
    else
    {
        'UTF-8'
    }

    $legendX = $plotRight + 24.0
    $legendY = $plotTop + 8.0
    $legendWidth = [Math]::Max(180.0, ($svgWidth - $legendX) - 20.0)
    $legendHeight = 206.0

    # SVG 構築開始
    $sb = New-Object System.Text.StringBuilder

    # XML 宣言と SVG ルート要素
    [void]$sb.AppendLine(('<?xml version="1.0" encoding="{0}"?>' -f $xmlEncoding))
    $titleX = $svgWidth / 2.0
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" role="img" aria-label="ファイル別ホットスポット バブルチャート">' -f $svgWidth, $svgHeight))

    # グラデーション定義（凡例用）
    [void]$sb.AppendLine('  <defs>')
    [void]$sb.AppendLine('    <style><![CDATA[')
    [void]$sb.AppendLine('      text { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; }')
    [void]$sb.AppendLine('      .chart-title { font-size: 26px; font-weight: 700; fill: #1f2937; text-anchor: middle; }')
    [void]$sb.AppendLine('      .axis-grid { stroke: #d1d5db; stroke-width: 1; stroke-dasharray: 4 4; }')
    [void]$sb.AppendLine('      .axis-line { stroke: #1f2937; stroke-width: 1.8; }')
    [void]$sb.AppendLine('      .axis-tick { font-size: 12px; fill: #475569; }')
    [void]$sb.AppendLine('      .axis-label { font-size: 16px; fill: #0f172a; font-weight: 600; text-anchor: middle; }')
    [void]$sb.AppendLine('      .legend-title { font-size: 13px; fill: #1f2937; font-weight: 700; }')
    [void]$sb.AppendLine('      .legend-body { font-size: 12px; fill: #475569; }')
    [void]$sb.AppendLine('      .bubble-marker { fill-opacity: 0.74; stroke: #1f2937; stroke-width: 1.1; filter: url(#bubbleShadow); }')
    [void]$sb.AppendLine('      .bubble-label { font-size: 11px; fill: #0f172a; paint-order: stroke; stroke: #ffffff; stroke-width: 3; stroke-linejoin: round; }')
    [void]$sb.AppendLine('    ]]></style>')
    [void]$sb.AppendLine('    <linearGradient id="rankGradient" x1="0%" y1="0%" x2="100%" y2="0%">')
    [void]$sb.AppendLine(('      <stop offset="0%" stop-color="{0}" />' -f $rankStartColor))
    [void]$sb.AppendLine(('      <stop offset="100%" stop-color="{0}" />' -f $rankEndColor))
    [void]$sb.AppendLine('    </linearGradient>')
    [void]$sb.AppendLine('    <filter id="bubbleShadow" x="-20%" y="-20%" width="140%" height="140%">')
    [void]$sb.AppendLine('      <feDropShadow dx="0" dy="1.5" stdDeviation="1.6" flood-color="#0f172a" flood-opacity="0.20" />')
    [void]$sb.AppendLine('    </filter>')
    [void]$sb.AppendLine('  </defs>')

    # 背景とタイトル
    [void]$sb.AppendLine(('  <rect x="0" y="0" width="{0}" height="{1}" fill="#f8fafc" />' -f $svgWidth, $svgHeight))
    [void]$sb.AppendLine(('  <text class="chart-title" x="{0}" y="44">ファイル別ホットスポット バブルチャート</text>' -f $titleX))
    [void]$sb.AppendLine(('  <rect x="{0}" y="{1}" width="{2}" height="{3}" rx="10" ry="10" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2" />' -f $plotLeft, $plotTop, $plotWidth, $plotHeight))

    # X軸グリッド線とラベル（コミット数）
    for ($i = 0
        $i -le $tickCount
        $i++)
    {
        $xValue = ($maxCommit * $i) / [double]$tickCount
        $x = $plotLeft + (($plotWidth * $i) / [double]$tickCount)
        $xRounded = [Math]::Round($x, 2)
        $xLabel = [int][Math]::Round($xValue)
        [void]$sb.AppendLine(('  <line class="axis-grid" x1="{0}" y1="{1}" x2="{0}" y2="{2}" />' -f $xRounded, $plotTop, $plotBottom))
        [void]$sb.AppendLine(('  <text class="axis-tick" x="{0}" y="{1}" text-anchor="middle">{2}</text>' -f $xRounded, ($plotBottom + 24.0), $xLabel))
    }
    # Y軸グリッド線とラベル（作者数）
    for ($i = 0
        $i -le $tickCount
        $i++)
    {
        $yValue = ($maxAuthors * $i) / [double]$tickCount
        $y = $plotBottom - (($plotHeight * $i) / [double]$tickCount)
        $yRounded = [Math]::Round($y, 2)
        $yLabel = [int][Math]::Round($yValue)
        [void]$sb.AppendLine(('  <line class="axis-grid" x1="{0}" y1="{2}" x2="{1}" y2="{2}" />' -f $plotLeft, $plotRight, $yRounded))
        [void]$sb.AppendLine(('  <text class="axis-tick" x="{0}" y="{1}" text-anchor="end">{2}</text>' -f ($plotLeft - 12.0), ($yRounded + 4.0), $yLabel))
    }

    # 座標軸の描画
    [void]$sb.AppendLine(('  <line class="axis-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}" />' -f $plotLeft, $plotBottom, $plotRight))
    [void]$sb.AppendLine(('  <line class="axis-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}" />' -f $plotLeft, $plotTop, $plotBottom))

    # 軸ラベル
    [void]$sb.AppendLine(('  <text class="axis-label" x="{0}" y="{1}">コミット数</text>' -f ($plotLeft + ($plotWidth / 2.0)), ($svgHeight - 40.0)))
    [void]$sb.AppendLine(('  <text class="axis-label" x="{0}" y="{1}" transform="rotate(-90 {0} {1})">作者数</text>' -f 42, ($plotTop + ($plotHeight / 2.0))))

    # 凡例エリアの描画
    [void]$sb.AppendLine(('  <rect x="{0}" y="{1}" width="{2}" height="{3}" rx="10" ry="10" fill="#ffffff" stroke="#d6dce5" stroke-width="1.1" />' -f $legendX, $legendY, $legendWidth, $legendHeight))
    [void]$sb.AppendLine(('  <text class="legend-title" x="{0}" y="{1}">凡例</text>' -f ($legendX + 14.0), ($legendY + 24.0)))
    [void]$sb.AppendLine(('  <text class="legend-body" x="{0}" y="{1}">面積 ∝ 総チャーン</text>' -f ($legendX + 14.0), ($legendY + 44.0)))
    $legendLargeRadius = & $radiusCalculator -ChurnValue $maxChurn
    $legendMediumRadius = & $radiusCalculator -ChurnValue ($maxChurn * 0.45)
    $legendSmallRadius = & $radiusCalculator -ChurnValue ($maxChurn * 0.15)
    [void]$sb.AppendLine(('  <circle cx="{0}" cy="{1}" r="{2}" fill="#ffffff" stroke="#64748b" />' -f ($legendX + 54.0), ($legendY + 114.0), [Math]::Round($legendLargeRadius, 2)))
    [void]$sb.AppendLine(('  <circle cx="{0}" cy="{1}" r="{2}" fill="#ffffff" stroke="#64748b" />' -f ($legendX + 118.0), ($legendY + 124.0), [Math]::Round($legendMediumRadius, 2)))
    [void]$sb.AppendLine(('  <circle cx="{0}" cy="{1}" r="{2}" fill="#ffffff" stroke="#64748b" />' -f ($legendX + 170.0), ($legendY + 132.0), [Math]::Round($legendSmallRadius, 2)))
    [void]$sb.AppendLine(('  <text class="legend-body" x="{0}" y="{1}">色: ホットスポット順位</text>' -f ($legendX + 14.0), ($legendY + 168.0)))
    [void]$sb.AppendLine(('  <rect x="{0}" y="{1}" width="{2}" height="10" fill="url(#rankGradient)" stroke="#aeb7c4" />' -f ($legendX + 14.0), ($legendY + 174.0), ($legendWidth - 32.0)))
    [void]$sb.AppendLine(('  <text class="legend-body" x="{0}" y="{1}">1位</text>' -f ($legendX + 14.0), ($legendY + 192.0)))
    [void]$sb.AppendLine(('  <text class="legend-body" x="{0}" y="{1}" text-anchor="end">{2}位</text>' -f ($legendX + $legendWidth - 18.0), ($legendY + 192.0), $maxRank))

    # バブルの描画順序: 大きいバブルを背面に配置（総チャーン降順）
    $drawOrder = @(
        $topFiles |
            Sort-Object -Property @{Expression = {
                    [double]$_.'総チャーン'
                }
                Descending = $true
            }, @{Expression = 'ホットスポット順位'
                Descending = $false
            }, 'ファイルパス'
    )

    # 各ファイルをバブルとして描画
    foreach ($f in $drawOrder)
    {
        $filePath = [string]$f.'ファイルパス'
        $commitCount = [double]$f.'コミット数'
        $authorCount = [double]$f.'作者数'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'

        $radius = & $radiusCalculator -ChurnValue $churnCount
        $x = $plotLeft + (($commitCount / $maxCommit) * $plotWidth)
        $y = $plotBottom - (($authorCount / $maxAuthors) * $plotHeight)
        $x = [Math]::Min($plotRight - $radius - 1.0, [Math]::Max($plotLeft + $radius + 1.0, $x))
        $y = [Math]::Min($plotBottom - $radius - 1.0, [Math]::Max($plotTop + $radius + 1.0, $y))
        $bubbleColor = ConvertTo-SvgColor -Rank $rank -MaxRank $maxRank
        $label = Split-Path -Path $filePath -Leaf
        if ([string]::IsNullOrWhiteSpace($label))
        {
            $label = $filePath
        }
        $safePath = ConvertTo-SvgEscapedText -Text $filePath
        if ([string]::IsNullOrEmpty($safePath))
        {
            $safePath = ''
        }
        $tooltip = ('{0}&#10;コミット数={1}, 作者数={2}, 総チャーン={3}, 順位={4}' -f $safePath, [int][Math]::Round($commitCount), [int][Math]::Round($authorCount), [int][Math]::Round($churnCount), $rank)

        $xRounded = [Math]::Round($x, 2)
        $yRounded = [Math]::Round($y, 2)
        $radiusRounded = [Math]::Round($radius, 2)
        [void]$sb.AppendLine(('  <circle class="bubble-marker" cx="{0}" cy="{1}" r="{2}" fill="{3}">' -f $xRounded, $yRounded, $radiusRounded, $bubbleColor))
        [void]$sb.AppendLine(('    <title>{0}</title>' -f $tooltip))
        [void]$sb.AppendLine('  </circle>')

        $labelX = $xRounded
        $labelY = [Math]::Round($yRounded + 4.0, 2)
        $labelAnchor = 'middle'
        $labelFontSize = 11.0
        $maxLabelWidth = [Math]::Max(18.0, ($radiusRounded * 2.0) - 10.0)
        if ($radiusRounded -lt 24.0)
        {
            $labelY = [Math]::Round($yRounded - $radiusRounded - 4.0, 2)
            if ($xRounded -lt ($plotLeft + ($plotWidth / 2.0)))
            {
                $labelX = [Math]::Round($xRounded + $radiusRounded + 8.0, 2)
                $labelAnchor = 'start'
                $maxLabelWidth = [Math]::Max(30.0, ($svgWidth - 12.0) - $labelX)
            }
            else
            {
                $labelX = [Math]::Round($xRounded - $radiusRounded - 8.0, 2)
                $labelAnchor = 'end'
                $maxLabelWidth = [Math]::Max(30.0, $labelX - 12.0)
            }
        }
        $labelY = [Math]::Round([Math]::Min($plotBottom - 4.0, [Math]::Max($plotTop + 12.0, $labelY)), 2)
        $fittedLabel = Get-SvgFittedText -Text $label -MaxWidth $maxLabelWidth -FontSize $labelFontSize
        if (-not [string]::IsNullOrWhiteSpace($fittedLabel))
        {
            if ($labelAnchor -eq 'middle')
            {
                $halfWidth = (Measure-SvgTextWidth -Text $fittedLabel -FontSize $labelFontSize) / 2.0
                $labelX = [Math]::Round([Math]::Min($svgWidth - 12.0 - $halfWidth, [Math]::Max(12.0 + $halfWidth, $labelX)), 2)
            }
            else
            {
                $labelX = [Math]::Round([Math]::Min($svgWidth - 12.0, [Math]::Max(12.0, $labelX)), 2)
            }
            $safeLabel = ConvertTo-SvgEscapedText -Text $fittedLabel
            if ([string]::IsNullOrEmpty($safeLabel))
            {
                $safeLabel = ''
            }
            [void]$sb.AppendLine(('  <text class="bubble-label" x="{0}" y="{1}" text-anchor="{2}">{3}</text>' -f $labelX, $labelY, $labelAnchor, $safeLabel))
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'file_bubble.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Write-FileHeatMap
{
    <#
    .SYNOPSIS
        ファイル別メトリクスのヒートマップ SVG を出力する。
    .DESCRIPTION
        ホットスポット順位の上位ファイルを行、比較可能なメトリクスを列として
        0-1 正規化したヒートマップを SVG で生成する。
        Phase 2 の追加列が存在する場合は、同一ヒートマップへ列を拡張して描画する。
        セルの色は白（最小値）から赤（最大値）のグラデーションで表現される。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する（必須）。
    .PARAMETER Files
        Get-FileMetric が返すファイル別メトリクス行を指定する（必須）。
    .PARAMETER TopNCount
        ヒートマップ対象にする上位件数を指定する（0以下の場合は全件）。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    .EXAMPLE
        Write-FileHeatMap -OutDirectory '.\output' -Files $fileMetrics -TopNCount 30 -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Files,
        [Parameter(Mandatory = $false)]
        [int]$TopNCount = 0,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )

    # 入力検証
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-FileHeatMap: OutDirectory が空です。'
        return
    }

    if (-not $Files -or @($Files).Count -eq 0)
    {
        Write-Verbose 'Write-FileHeatMap: Files が空です。SVG を生成しません。'
        return
    }

    # 可視化対象のメトリクス定義（基本 + Phase 2 オプショナル）
    $metrics = @(
        'コミット数',
        '作者数',
        '総チャーン',
        '消滅追加行数',
        '最多作者チャーン占有率',
        '最多作者blame占有率',
        '平均変更間隔日数',
        'ホットスポットスコア'
    )
    if (@($Files).Count -gt 0 -and ($Files[0].PSObject.Properties.Name -contains '自己相殺行数 (合計)'))
    {
        $metrics += @(
            '自己相殺行数 (合計)',
            '他者差戻行数 (合計)',
            '同一箇所反復編集数 (合計)',
            'ピンポン回数 (合計)'
        )
    }
    $targetFiles = @($Files | Sort-Object -Property 'ホットスポット順位')
    if ($TopNCount -gt 0)
    {
        $targetFiles = @($targetFiles | Select-Object -First $TopNCount)
    }

    $toNumber = {
        param([object]$Value)
        if ($null -eq $Value)
        {
            return 0.0
        }
        if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal])
        {
            return [double]$Value
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text))
        {
            return 0.0
        }
        $numberStyles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
        $parsed = 0.0
        if ([double]::TryParse($text, $numberStyles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed))
        {
            return $parsed
        }
        if ([double]::TryParse($text, $numberStyles, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed))
        {
            return $parsed
        }
        return 0.0
    }

    $toDisplayValue = {
        param([object]$Value)
        if ($null -eq $Value)
        {
            return '-'
        }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal])
        {
            return ([double]$Value).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
        {
            return [string]$Value
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text))
        {
            return '-'
        }
        return $text
    }

    $escapeXml = {
        param([string]$Text)
        if ($null -eq $Text)
        {
            return ''
        }
        $escaped = [System.Security.SecurityElement]::Escape($Text)
        if ($null -eq $escaped)
        {
            return ''
        }
        return $escaped
    }

    $toDisplayPath = {
        param([string]$Path, [double]$MaxWidth, [double]$FontSize)
        return Get-SvgCompactPathLabel -Path $Path -MaxWidth $MaxWidth -FontSize $FontSize
    }

    $toCellColor = {
        param([double]$NormalizedValue)
        $v = [Math]::Max(0.0, [Math]::Min(1.0, [double]$NormalizedValue))
        $r = [Math]::Round(255.0 + ((231.0 - 255.0) * $v))
        $g = [Math]::Round(255.0 + ((76.0 - 255.0) * $v))
        $b = [Math]::Round(255.0 + ((60.0 - 255.0) * $v))
        return ('#{0}{1}{2}' -f ([int]$r).ToString('X2'), ([int]$g).ToString('X2'), ([int]$b).ToString('X2')).ToLowerInvariant()
    }

    $columnStats = @{}
    foreach ($metric in $metrics)
    {
        $numbers = New-Object 'System.Collections.Generic.List[double]'
        foreach ($row in $targetFiles)
        {
            $property = $row.PSObject.Properties[$metric]
            $rawValue = $null
            if ($null -ne $property)
            {
                $rawValue = $property.Value
            }
            $numbers.Add((& $toNumber $rawValue)) | Out-Null
        }
        $min = 0.0
        $max = 0.0
        if ($numbers.Count -gt 0)
        {
            $min = [double](($numbers | Measure-Object -Minimum).Minimum)
            $max = [double](($numbers | Measure-Object -Maximum).Maximum)
        }
        $columnStats[$metric] = [pscustomobject]@{
            Min = $min
            Max = $max
        }
    }

    # SVG キャンバスのサイズ計算
    $rowHeaderFontSize = 11.0
    $columnHeaderFontSize = 11.0
    $cellFontSize = 10.0
    $columnHeaderAngle = -40.0
    $cellWidth = 126
    $cellHeight = 32
    $rightMargin = 24
    $bottomMargin = 24
    $titleHeight = 34.0

    $rowHeaderWidthEstimate = 200.0
    foreach ($row in $targetFiles)
    {
        if ($null -eq $row)
        {
            continue
        }
        $pathForMeasure = [string]$row.'ファイルパス'
        $samplePath = & $toDisplayPath $pathForMeasure 340.0 $rowHeaderFontSize
        $sampleWidth = Measure-SvgTextWidth -Text $samplePath -FontSize $rowHeaderFontSize
        if ($sampleWidth -gt $rowHeaderWidthEstimate)
        {
            $rowHeaderWidthEstimate = $sampleWidth
        }
    }

    $leftMargin = [int][Math]::Ceiling([Math]::Max(220.0, $rowHeaderWidthEstimate + 28.0))
    $maxMetricWidth = 0.0
    foreach ($metric in $metrics)
    {
        $metricWidth = Measure-SvgTextWidth -Text ([string]$metric) -FontSize $columnHeaderFontSize
        if ($metricWidth -gt $maxMetricWidth)
        {
            $maxMetricWidth = $metricWidth
        }
    }

    $headerAngleRad = [Math]::Abs($columnHeaderAngle) * [Math]::PI / 180.0
    $headerRise = $maxMetricWidth * [Math]::Sin($headerAngleRad)
    $topMargin = [int][Math]::Ceiling([Math]::Max(108.0, $titleHeight + 22.0 + $headerRise))

    $rowCount = @($targetFiles).Count
    $columnCount = @($metrics).Count
    $gridWidth = $columnCount * $cellWidth
    $gridHeight = $rowCount * $cellHeight
    $totalWidth = $leftMargin + $gridWidth + $rightMargin
    $totalHeight = $topMargin + $gridHeight + $bottomMargin
    $rowHeaderX = $leftMargin - 10
    $rowHeaderMaxWidth = [Math]::Max(40.0, $leftMargin - 20.0)
    $gridRight = $leftMargin + $gridWidth

    # SVG 構築開始
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" role="img" aria-label="ファイル別メトリクス ヒートマップ">' -f $totalWidth, $totalHeight))
    [void]$sb.AppendLine('  <defs>')
    [void]$sb.AppendLine('    <style><![CDATA[')
    [void]$sb.AppendLine('      text { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; fill: #334155; }')
    [void]$sb.AppendLine('      .chart-title { font-size: 22px; font-weight: 700; text-anchor: middle; fill: #1e293b; }')
    [void]$sb.AppendLine('      .row-header { font-size: 11px; text-anchor: end; dominant-baseline: middle; fill: #334155; }')
    [void]$sb.AppendLine('      .col-header { font-size: 11px; text-anchor: middle; dominant-baseline: middle; fill: #334155; }')
    [void]$sb.AppendLine('      .cell-text { font-size: 10px; text-anchor: middle; dominant-baseline: middle; fill: #1f2937; }')
    [void]$sb.AppendLine('      .grid-line { stroke: #dce3ec; stroke-width: 1; }')
    [void]$sb.AppendLine('      .cell-frame { stroke: #d0d7e2; stroke-width: 1; }')
    [void]$sb.AppendLine('    ]]></style>')
    [void]$sb.AppendLine('  </defs>')
    [void]$sb.AppendLine(('  <rect x="0" y="0" width="{0}" height="{1}" fill="#f8fafc" />' -f $totalWidth, $totalHeight))
    [void]$sb.AppendLine(('  <text class="chart-title" x="{0}" y="32">ファイル別メトリクス ヒートマップ</text>' -f ($totalWidth / 2.0)))
    [void]$sb.AppendLine(('  <rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#ffffff" stroke="#cfd8e3" stroke-width="1.1" />' -f $leftMargin, $topMargin, $gridWidth, $gridHeight))

    # 列ヘッダー（メトリクス名）の描画
    for ($columnIndex = 0
        $columnIndex -lt $columnCount
        $columnIndex++)
    {
        $metric = [string]$metrics[$columnIndex]
        $headerX = $leftMargin + ($columnIndex * $cellWidth) + ($cellWidth / 2.0)
        $headerY = $topMargin - 12
        [void]$sb.AppendLine(('  <text class="col-header" x="{0}" y="{1}" transform="rotate({2} {0} {1})">{3}</text>' -f $headerX, $headerY, $columnHeaderAngle, (& $escapeXml $metric)))
    }

    # グリッド線の描画
    for ($rowIndex = 0
        $rowIndex -le $rowCount
        $rowIndex++)
    {
        $lineY = $topMargin + ($rowIndex * $cellHeight)
        [void]$sb.AppendLine(('  <line class="grid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}" />' -f $leftMargin, $lineY, $gridRight))
    }
    for ($columnIndex = 0
        $columnIndex -le $columnCount
        $columnIndex++)
    {
        $lineX = $leftMargin + ($columnIndex * $cellWidth)
        [void]$sb.AppendLine(('  <line class="grid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}" />' -f $lineX, $topMargin, ($topMargin + $gridHeight)))
    }

    # 各行（ファイル）とセル（メトリクス値）の描画
    for ($rowIndex = 0
        $rowIndex -lt $rowCount
        $rowIndex++)
    {
        $row = $targetFiles[$rowIndex]
        $filePath = [string]$row.'ファイルパス'
        $displayPath = & $toDisplayPath $filePath $rowHeaderMaxWidth $rowHeaderFontSize
        $rowY = $topMargin + ($rowIndex * $cellHeight)
        $rowTextY = $rowY + [Math]::Round($cellHeight / 2.0)

        if (($rowIndex % 2) -eq 1)
        {
            [void]$sb.AppendLine(('  <rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#f8fafc" />' -f $leftMargin, $rowY, $gridWidth, $cellHeight))
        }

        [void]$sb.AppendLine('  <g>')
        [void]$sb.AppendLine(('    <title>{0}</title>' -f (& $escapeXml $filePath)))
        [void]$sb.AppendLine(('    <text class="row-header" x="{0}" y="{1}">{2}</text>' -f $rowHeaderX, $rowTextY, (& $escapeXml $displayPath)))
        [void]$sb.AppendLine('  </g>')

        for ($columnIndex = 0
            $columnIndex -lt $columnCount
            $columnIndex++)
        {
            $metric = [string]$metrics[$columnIndex]
            $property = $row.PSObject.Properties[$metric]
            $rawValue = $null
            if ($null -ne $property)
            {
                $rawValue = $property.Value
            }
            $displayValue = & $toDisplayValue $rawValue
            $numericValue = & $toNumber $rawValue
            $stat = $columnStats[$metric]
            $range = [double]$stat.Max - [double]$stat.Min
            $normalizedValue = 0.0
            if ($range -gt 0.0)
            {
                $normalizedValue = ($numericValue - [double]$stat.Min) / $range
            }
            $cellColor = & $toCellColor $normalizedValue
            $cellX = $leftMargin + ($columnIndex * $cellWidth)
            $cellTextX = $cellX + [Math]::Round($cellWidth / 2.0)
            $cellTextY = $rowY + [Math]::Round($cellHeight / 2.0)
            $cellDisplay = Get-SvgFittedText -Text ([string]$displayValue) -MaxWidth ($cellWidth - 8.0) -FontSize $cellFontSize
            $title = '{0}: {1}={2}' -f $filePath, $metric, $displayValue
            [void]$sb.AppendLine('  <g>')
            [void]$sb.AppendLine(('    <title>{0}</title>' -f (& $escapeXml $title)))
            [void]$sb.AppendLine(('    <rect class="cell-frame" x="{0}" y="{1}" width="{2}" height="{3}" fill="{4}" />' -f $cellX, $rowY, $cellWidth, $cellHeight, $cellColor))
            [void]$sb.AppendLine(('    <text class="cell-text" x="{0}" y="{1}">{2}</text>' -f $cellTextX, $cellTextY, (& $escapeXml $cellDisplay)))
            [void]$sb.AppendLine('  </g>')
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'file_heatmap.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Get-SafeFileName
{
    <#
    .SYNOPSIS
        Windows 互換の安全なファイル名を生成する。
    .DESCRIPTION
        無効文字の除去、予約デバイス名の正規化、長さ制限を適用し、
        Windows 環境で確実に使用可能なファイル名を返す。
    .PARAMETER BaseName
        サニタイズ対象の基本名を指定する。
    .PARAMETER Extension
        ファイル拡張子を指定する（ドットを含む、例: ".svg"）。
    .PARAMETER MaxLength
        ファイル名の最大長を指定する（拡張子を含む）。デフォルトは 100 文字。
    .OUTPUTS
        System.String
        サニタイズされた安全なファイル名を返す。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BaseName,
        [Parameter(Mandatory = $false)]
        [string]$Extension = '',
        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 100
    )

    $safe = [string]$BaseName
    if ([string]::IsNullOrWhiteSpace($safe))
    {
        $safe = '(unknown)'
    }
    $safe = $safe.Trim()

    # 無効な文字を置換
    # GetInvalidFileNameChars() はプラットフォーム依存のため、Windows 固有の無効文字を明示的に処理
    $windowsInvalidChars = [char[]]@('<', '>', ':', '"', '/', '\', '|', '?', '*')
    foreach ($invalidChar in $windowsInvalidChars)
    {
        $safe = $safe.Replace([string]$invalidChar, '_')
    }
    # プラットフォームの無効文字も処理（制御文字など）
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars())
    {
        $safe = $safe.Replace([string]$invalidChar, '_')
    }

    # 末尾のドットとスペースを除去（Windows では問題となる）
    $safe = $safe.TrimEnd('. ')

    # Windows 予約デバイス名のチェックと正規化
    # 予約名: CON, PRN, AUX, NUL, COM1-9, LPT1-9
    $reservedNames = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )

    # 予約名は大文字小文字を区別しない
    $upperSafe = $safe.ToUpperInvariant()
    foreach ($reserved in $reservedNames)
    {
        if ($upperSafe -eq $reserved)
        {
            # 予約名の場合はアンダースコアを接頭辞として付与
            $safe = "_$safe"
            break
        }
    }

    # 空になった場合のフォールバック
    if ([string]::IsNullOrWhiteSpace($safe))
    {
        $safe = '(unknown)'
    }

    # 最大長の制限（拡張子を含む）
    $extLen = $Extension.Length
    $maxBaseLen = $MaxLength - $extLen
    if ($maxBaseLen -lt 1)
    {
        $maxBaseLen = 1
    }

    if ($safe.Length -gt $maxBaseLen)
    {
        # 長すぎる場合は切り詰めてハッシュを付与
        # NOTE: MD5 はセキュリティ目的ではなく、ファイル名の一意性確保のみに使用
        $hash = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($safe))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
        $truncLen = $maxBaseLen - 9
        if ($truncLen -lt 1)
        {
            $truncLen = 1
        }
        $safe = $safe.Substring(0, $truncLen) + '_' + $hash
    }

    return $safe + $Extension
}
function Write-CommitterRadarChart
{
    <#
    .SYNOPSIS
        コミッター品質を 9 軸レーダーチャート SVG として出力する。
    .DESCRIPTION
        追加行数が 0 を超えるコミッターを対象に品質指標を算出し、
        全コミッター間で min-max 正規化した値を作者別 SVG として保存する。
        各データポイント付近に生値を表示し、下部パネルに計算式・表示方向を併記する。
        各軸の意味:
        - コード生存率: 追加したコードが最終的に残っている割合
        - 変更エントロピー: 変更がファイル間で分散している度合い（高いほど良い）
        - 自己相殺率: 自分で追加したコードを自分で削除した割合（低いほど良い）
        - 被削除率: 他者に削除されたコードの割合（低いほど良い）
        - 他者コード変更生存率: 他者のコードを変更した後の生存率（高いほど良い）
        - ピンポン率: 反復編集の頻度（低いほど良い）
        - 所有集中度: コードベースへの貢献割合（高いほど良い）
        - 定着コミット量: 1コミットあたりで最終的に残したコード量（高いほど良い）
        - トータルコミット量: 追加+削除を合算したコミット総量（高いほど良い）
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する（必須）。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する（必須）。
    .PARAMETER TopNCount
        総チャーン上位として SVG を生成する件数を指定する（0以下の場合は出力しない）。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitterRadarChart -OutDirectory '.\output' -Committers $committers -TopNCount 10 -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$TopNCount = 0,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )

    # 入力検証
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-CommitterRadarChart: OutDirectory が空です。'
        return
    }

    if ($TopNCount -le 0)
    {
        Write-Verbose 'Write-CommitterRadarChart: TopNCount が 0 以下のため、出力しません。'
        return
    }

    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        Write-Verbose 'Write-CommitterRadarChart: Committers が空です。SVG を生成しません。'
        return
    }

    # 出力ディレクトリの作成
    if (-not (Test-Path -LiteralPath $OutDirectory))
    {
        try
        {
            $null = New-Item -LiteralPath $OutDirectory -ItemType Directory -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Write-CommitterRadarChart: 出力ディレクトリの作成に失敗しました: $_"
            return
        }
    }

    # レーダーチャートの 9 軸定義（Invert は値が小さいほど良い場合に true）

    $axisDefinitions = @(
        [pscustomobject][ordered]@{
            Label = 'コード生存率'
            Formula = '生存行数 / 追加行数'
            Unit = '率'
            Invert = $false
        },
        [pscustomobject][ordered]@{
            Label = '変更エントロピー'
            Formula = 'ファイル別チャーンのエントロピー'
            Unit = 'bit'
            Invert = $false
        },
        [pscustomobject][ordered]@{
            Label = '自己相殺率'
            Formula = '自己相殺行数 / 追加行数'
            Unit = '率'
            Invert = $true
        },
        [pscustomobject][ordered]@{
            Label = '被削除率'
            Formula = '被他者削除行数 / 追加行数'
            Unit = '率'
            Invert = $true
        },
        [pscustomobject][ordered]@{
            Label = '他者コード変更生存率'
            Formula = '他者コード変更生存行数 / 他者コード変更行数'
            Unit = '率'
            Invert = $false
        },
        [pscustomobject][ordered]@{
            Label = 'ピンポン率'
            Formula = 'ピンポン回数 / コミット数'
            Unit = '率'
            Invert = $true
        },
        [pscustomobject][ordered]@{
            Label = '所有集中度'
            Formula = '所有行数 / 全所有行数'
            Unit = '率'
            Invert = $false
        },
        [pscustomobject][ordered]@{
            Label = '定着コミット量'
            Formula = '生存行数 / コミット数'
            Unit = '行'
            Invert = $false
        },
        [pscustomobject][ordered]@{
            Label = 'トータルコミット量'
            Formula = '追加行数 + 削除行数'
            Unit = '行'
            Invert = $false
        }
    )

    $chartRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($committer in @($Committers))
    {
        if ($null -eq $committer)
        {
            continue
        }

        $addedLines = 0.0
        if ($null -ne $committer.'追加行数')
        {
            $addedLines = [double]$committer.'追加行数'
        }
        if ($addedLines -le 0)
        {
            continue
        }

        $survivedLines = 0.0
        if ($null -ne $committer.'生存行数')
        {
            $survivedLines = [double]$committer.'生存行数'
        }
        $changeEntropy = 0.0
        if ($null -ne $committer.'変更エントロピー')
        {
            $changeEntropy = [double]$committer.'変更エントロピー'
        }
        $deletedLines = 0.0
        if ($null -ne $committer.'削除行数')
        {
            $deletedLines = [double]$committer.'削除行数'
        }
        $selfCancelLines = 0.0
        if ($null -ne $committer.'自己相殺行数')
        {
            $selfCancelLines = [double]$committer.'自己相殺行数'
        }
        $removedByOthers = 0.0
        if ($null -ne $committer.'被他者削除行数')
        {
            $removedByOthers = [double]$committer.'被他者削除行数'
        }
        $otherChangeRate = 0.0
        if ($null -ne $committer.'他者コード変更生存率')
        {
            $otherChangeRate = [double]$committer.'他者コード変更生存率'
        }
        $pingPongPerCommit = 0.0
        if ($null -ne $committer.'ピンポン率')
        {
            $pingPongPerCommit = [double]$committer.'ピンポン率'
        }
        elseif ($null -ne $committer.'コミットあたりピンポン')
        {
            $pingPongPerCommit = [double]$committer.'コミットあたりピンポン'
        }
        $ownershipShare = 0.0
        if ($null -ne $committer.'所有割合')
        {
            $ownershipShare = [double]$committer.'所有割合'
        }
        $totalChurn = 0.0
        if ($null -ne $committer.'総チャーン')
        {
            $totalChurn = [double]$committer.'総チャーン'
        }
        $commitCount = 0.0
        if ($null -ne $committer.'コミット数')
        {
            $commitCount = [double]$committer.'コミット数'
        }
        $retainedVolumePerCommit = 0.0
        if ($commitCount -gt 0.0)
        {
            $retainedVolumePerCommit = $survivedLines / $commitCount
        }
        $totalCommitVolume = $addedLines + $deletedLines

        $rawScores = [ordered]@{
            'コード生存率' = $survivedLines / $addedLines
            '変更エントロピー' = $changeEntropy
            '自己相殺率' = $selfCancelLines / $addedLines
            '被削除率' = $removedByOthers / $addedLines
            '他者コード変更生存率' = $otherChangeRate
            'ピンポン率' = $pingPongPerCommit
            '所有集中度' = $ownershipShare
            '定着コミット量' = $retainedVolumePerCommit
            'トータルコミット量' = $totalCommitVolume
        }
        $chartRows.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$committer.'作者'))
                TotalChurn = $totalChurn
                RawScores = $rawScores
            }) | Out-Null
    }

    if ($chartRows.Count -eq 0)
    {
        return
    }

    $axisMinMax = @{}
    foreach ($axis in $axisDefinitions)
    {
        $axisLabel = [string]$axis.Label
        $axisValues = @($chartRows.ToArray() | ForEach-Object { [double]$_.RawScores[$axisLabel] })
        $stats = $axisValues | Measure-Object -Minimum -Maximum
        $axisMinMax[$axisLabel] = [pscustomobject][ordered]@{
            Min = [double]$stats.Minimum
            Max = [double]$stats.Maximum
        }
    }

    $topChartRows = @($chartRows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'
            Descending = $true
        }, 'Author' | Select-Object -First $TopNCount)
    if ($topChartRows.Count -eq 0)
    {
        return
    }

    $axisCount = $axisDefinitions.Count
    $svgWidth = 760.0
    $metricPanelX = 20.0
    $metricPanelY = 504.0
    $metricPanelWidth = $svgWidth - ($metricPanelX * 2.0)
    $metricBodyFontSize = 11.0
    $metricRowHeight = 18.0
    $metricPanelHeight = 52.0 + ($axisCount * $metricRowHeight)
    $svgHeight = [Math]::Ceiling($metricPanelY + $metricPanelHeight + 16.0)
    $centerX = $svgWidth / 2.0
    $centerY = 272.0
    $radius = 166.0
    $titleFontSize = 24.0
    $axisLabelFontSize = 13.0
    $guideLevels = @(0.25, 0.5, 0.75, 1.0)
    $labelRadius = 202.0
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($row in $topChartRows)
    {
        $outerPoints = New-Object 'System.Collections.Generic.List[object]'
        $dataPoints = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $axisCount; $i++)
        {
            $angle = (((2.0 * [Math]::PI) * $i) / [double]$axisCount) - ([Math]::PI / 2.0)
            $xOuter = $centerX + ($radius * [Math]::Cos($angle))
            $yOuter = $centerY + ($radius * [Math]::Sin($angle))
            $axisLabel = [string]$axisDefinitions[$i].Label
            $rawValue = [double]$row.RawScores[$axisLabel]
            # 生値の表示用フォーマット
            $rawDisplayOuter = if ([string]$axisDefinitions[$i].Unit -eq '行')
            {
                if ($rawValue -ge 10000)
                {
                    '{0:N0}' -f $rawValue
                }
                else
                {
                    '{0:F1}' -f $rawValue
                }
            }
            elseif ([string]$axisDefinitions[$i].Unit -eq 'bit')
            {
                '{0:F2} bit' -f $rawValue
            }
            else
            {
                '{0:P1}' -f $rawValue
            }
            $outerPoints.Add([pscustomobject][ordered]@{
                    X = $xOuter
                    Y = $yOuter
                    Angle = $angle
                    Label = $axisLabel
                    Invert = [bool]$axisDefinitions[$i].Invert
                    RawDisplay = $rawDisplayOuter
                }) | Out-Null
            $normalized = ConvertTo-NormalizedScore -Value $rawValue -Min ([double]$axisMinMax[$axisLabel].Min) -Max ([double]$axisMinMax[$axisLabel].Max) -Invert:$axisDefinitions[$i].Invert
            $xData = $centerX + (($radius * $normalized) * [Math]::Cos($angle))
            $yData = $centerY + (($radius * $normalized) * [Math]::Sin($angle))
            $dataPoints.Add([pscustomobject][ordered]@{
                    X = $xData
                    Y = $yData
                    Value = $normalized
                }) | Out-Null
        }

        $dataPolygonPoints = @($dataPoints.ToArray() | ForEach-Object { '{0:F2},{1:F2}' -f $_.X, $_.Y }) -join ' '
        $authorName = [string]$row.Author
        if ([string]::IsNullOrWhiteSpace($authorName))
        {
            $authorName = '(unknown)'
        }
        $fittedAuthorTitle = Get-SvgFittedText -Text $authorName -MaxWidth ($svgWidth - 64.0) -FontSize $titleFontSize
        $authorTitle = ConvertTo-SvgEscapedText -Text $fittedAuthorTitle
        if ([string]::IsNullOrEmpty($authorTitle))
        {
            $authorTitle = '(unknown)'
        }

        # 安全なファイル名を生成（予約名・長さ制限対応）
        # 著者名のみを先にサニタイズ（予約名処理のため、長さ制限なし）
        $safeAuthor = Get-SafeFileName -BaseName $authorName -Extension '' -MaxLength 999
        # フルファイル名を生成し、長さ制限を適用
        $fileName = Get-SafeFileName -BaseName "committer_radar_$safeAuthor" -Extension '.svg' -MaxLength 100
        if (-not $usedNames.Add($fileName))
        {
            $index = 2
            while ($true)
            {
                $candidateBase = "committer_radar_{0}_{1}" -f $safeAuthor, $index
                $candidate = Get-SafeFileName -BaseName $candidateBase -Extension '.svg' -MaxLength 100
                if ($usedNames.Add($candidate))
                {
                    $fileName = $candidate
                    break
                }
                $index++
            }
        }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" role="img" aria-label="コミッター品質レーダーチャート">' -f $svgWidth, $svgHeight))
        [void]$sb.AppendLine('  <defs>')
        [void]$sb.AppendLine('    <style><![CDATA[')
        [void]$sb.AppendLine('      text { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; }')
        [void]$sb.AppendLine('      .chart-title { font-size: 24px; font-weight: 700; fill: #1f2937; text-anchor: middle; }')
        [void]$sb.AppendLine('      .chart-subtitle { font-size: 13px; font-weight: 600; fill: #475569; text-anchor: middle; }')
        [void]$sb.AppendLine('      .guide-line { stroke: #d7dee9; stroke-width: 1; fill: none; }')
        [void]$sb.AppendLine('      .axis-line { stroke: #d0d8e4; stroke-width: 1; }')
        [void]$sb.AppendLine('      .axis-label { font-size: 13px; fill: #334155; dominant-baseline: middle; }')
        [void]$sb.AppendLine('      .radar-area { fill: rgba(37, 99, 235, 0.25); stroke: #2563eb; stroke-width: 2.4; }')
        [void]$sb.AppendLine('      .radar-point { fill: #1d4ed8; stroke: #ffffff; stroke-width: 1.2; }')
        [void]$sb.AppendLine('      .raw-value { font-size: 10px; fill: #1e40af; font-weight: 600; }')
        [void]$sb.AppendLine('      .metric-panel { fill: #ffffff; stroke: #d8e1eb; stroke-width: 1.1; }')
        [void]$sb.AppendLine('      .metric-title { font-size: 15px; font-weight: 700; fill: #1f2937; }')
        [void]$sb.AppendLine('      .metric-note { font-size: 11px; fill: #475569; }')
        [void]$sb.AppendLine('      .metric-label { font-size: 11px; font-weight: 700; fill: #334155; }')
        [void]$sb.AppendLine('      .metric-formula { font-size: 11px; fill: #475569; }')
        [void]$sb.AppendLine('    ]]></style>')
        [void]$sb.AppendLine('  </defs>')
        [void]$sb.AppendLine(('  <rect x="0" y="0" width="{0}" height="{1}" fill="#f8fafc" />' -f $svgWidth, $svgHeight))
        [void]$sb.AppendLine(('  <circle cx="{0}" cy="{1}" r="{2}" fill="#ffffff" stroke="#d9e2ee" stroke-width="1.1" />' -f $centerX, $centerY, ($radius + 28.0)))
        [void]$sb.AppendLine(("  <text class=""chart-title"" x=""{0:F2}"" y=""44"">{1}</text>" -f $centerX, $authorTitle))

        foreach ($level in $guideLevels)
        {
            $guidePoints = @()
            foreach ($point in @($outerPoints.ToArray()))
            {
                $gx = $centerX + (($point.X - $centerX) * $level)
                $gy = $centerY + (($point.Y - $centerY) * $level)
                $guidePoints += ('{0:F2},{1:F2}' -f $gx, $gy)
            }
            [void]$sb.AppendLine(("  <polygon class=""guide-line"" points=""{0}"" />" -f ($guidePoints -join ' ')))
        }

        foreach ($point in @($outerPoints.ToArray()))
        {
            [void]$sb.AppendLine(("  <line class=""axis-line"" x1=""{0:F2}"" y1=""{1:F2}"" x2=""{2:F2}"" y2=""{3:F2}"" />" -f $centerX, $centerY, $point.X, $point.Y))
        }

        [void]$sb.AppendLine(("  <polygon class=""radar-area"" points=""{0}"" />" -f $dataPolygonPoints))

        foreach ($point in @($dataPoints.ToArray()))
        {
            [void]$sb.AppendLine(("  <circle class=""radar-point"" cx=""{0:F2}"" cy=""{1:F2}"" r=""4.2"" />" -f $point.X, $point.Y))
        }

        # 軸ラベルの初期座標を算出し、下部で重なるラベルを垂直方向に離す
        $labelItems = New-Object 'System.Collections.Generic.List[object]'
        foreach ($point in @($outerPoints.ToArray()))
        {
            $labelX = $centerX + ($labelRadius * [Math]::Cos($point.Angle))
            $labelY = $centerY + ($labelRadius * [Math]::Sin($point.Angle))
            $anchor = 'middle'
            $axisCos = [Math]::Cos($point.Angle)
            if ($axisCos -gt 0.2)
            {
                $anchor = 'start'
            }
            elseif ($axisCos -lt -0.2)
            {
                $anchor = 'end'
            }
            $labelItems.Add([pscustomobject][ordered]@{
                    X = $labelX
                    Y = $labelY
                    Anchor = $anchor
                    Label = [string]$point.Label
                    Angle = $point.Angle
                    Invert = [bool]$point.Invert
                    RawDisplay = [string]$point.RawDisplay
                }) | Out-Null
        }

        # Y が下半分 (center より下) のラベルを Y 昇順に並べ、近すぎるペアを離す
        $minGap = 20.0
        $bottomLabels = @($labelItems.ToArray() | Where-Object { $_.Y -gt $centerY })
        $bottomSorted = @($bottomLabels | Sort-Object -Property Y)
        for ($bi = 1; $bi -lt $bottomSorted.Count; $bi++)
        {
            $prev = $bottomSorted[$bi - 1]
            $curr = $bottomSorted[$bi]
            $gap = $curr.Y - $prev.Y
            if ($gap -lt $minGap)
            {
                $curr.Y = $prev.Y + $minGap
            }
        }

        # Y が上半分 (center より上) のラベルを Y 降順に並べ、近すぎるペアを離す
        $topLabels = @($labelItems.ToArray() | Where-Object { $_.Y -lt $centerY })
        $topSorted = @($topLabels | Sort-Object -Property Y -Descending)
        for ($ti = 1; $ti -lt $topSorted.Count; $ti++)
        {
            $prev = $topSorted[$ti - 1]
            $curr = $topSorted[$ti]
            $gap = $prev.Y - $curr.Y
            if ($gap -lt $minGap)
            {
                $curr.Y = $prev.Y - $minGap
            }
        }

        foreach ($item in @($labelItems.ToArray()))
        {
            $maxLabelWidth = 0.0
            if ($item.Anchor -eq 'start')
            {
                $maxLabelWidth = [Math]::Max(40.0, ($svgWidth - 14.0) - $item.X)
            }
            elseif ($item.Anchor -eq 'end')
            {
                $maxLabelWidth = [Math]::Max(40.0, $item.X - 14.0)
            }
            else
            {
                $maxLabelWidth = [Math]::Max(60.0, [Math]::Min($item.X - 14.0, ($svgWidth - 14.0) - $item.X) * 2.0)
            }
            $dirMark = if ([bool]$item.Invert)
            {
                '↕'
            }
            else
            {
                '↗'
            }
            $labelWithDir = '{0} {1}' -f [string]$item.Label, $dirMark
            $fittedAxisLabel = Get-SvgFittedText -Text $labelWithDir -MaxWidth $maxLabelWidth -FontSize $axisLabelFontSize
            $escapedLabel = ConvertTo-SvgEscapedText -Text $fittedAxisLabel
            $escapedRawValue = ConvertTo-SvgEscapedText -Text ([string]$item.RawDisplay)
            [void]$sb.AppendLine(("  <text class=""axis-label"" x=""{0:F2}"" y=""{1:F2}"" text-anchor=""{2}""><tspan>{3}</tspan><tspan x=""{0:F2}"" dy=""1.2em"" class=""raw-value"">{4}</tspan></text>" -f $item.X, $item.Y, $item.Anchor, $escapedLabel, $escapedRawValue))
        }

        [void]$sb.AppendLine(("  <rect class=""metric-panel"" x=""{0:F2}"" y=""{1:F2}"" width=""{2:F2}"" height=""{3:F2}"" rx=""10"" ry=""10"" />" -f $metricPanelX, $metricPanelY, $metricPanelWidth, $metricPanelHeight))
        [void]$sb.AppendLine(("  <text class=""metric-title"" x=""{0:F2}"" y=""{1:F2}"">指標定義</text>" -f ($metricPanelX + 12.0), ($metricPanelY + 20.0)))
        $panelNote = '※全軸とも外側ほど高評価。↕が付いた指標は低いほど良いため反転表示。'
        $panelNoteFitted = Get-SvgFittedText -Text $panelNote -MaxWidth ($metricPanelWidth - 20.0) -FontSize 10.0
        [void]$sb.AppendLine(("  <text class=""metric-note"" x=""{0:F2}"" y=""{1:F2}"">{2}</text>" -f ($metricPanelX + 12.0), ($metricPanelY + 36.0), (ConvertTo-SvgEscapedText -Text $panelNoteFitted)))
        for ($metricIndex = 0
            $metricIndex -lt $axisDefinitions.Count
            $metricIndex++)
        {
            $axis = $axisDefinitions[$metricIndex]
            $dirMark = if ([bool]$axis.Invert)
            {
                '↕'
            }
            else
            {
                '↗'
            }
            $metricLineRaw = '{0}. {1} {2} ＝ {3}' -f ($metricIndex + 1), [string]$axis.Label, $dirMark, [string]$axis.Formula
            $lineY = $metricPanelY + 52.0 + ($metricIndex * $metricRowHeight)
            $metricLine = Get-SvgFittedText -Text $metricLineRaw -MaxWidth ($metricPanelWidth - 20.0) -FontSize $metricBodyFontSize
            [void]$sb.AppendLine(("  <text class=""metric-formula"" x=""{0:F2}"" y=""{1:F2}"">{2}</text>" -f ($metricPanelX + 12.0), $lineY, (ConvertTo-SvgEscapedText -Text $metricLine)))
        }

        [void]$sb.AppendLine('</svg>')
        Write-TextFile -FilePath (Join-Path $OutDirectory $fileName) -Content $sb.ToString() -EncodingName $EncodingName
    }
}

function Write-CommitterRadarChartCombined
{
    <#
    .SYNOPSIS
        全コミッターのレーダーチャートを横並びグリッドで 1 つの SVG にまとめて出力する。
    .DESCRIPTION
        TopN のコミッターごとに独立したレーダーチャートを描画し、
        横並びのグリッドとして 1 枚の SVG に配置する。
        各チャートの下部にレーダー面積スコア（総合指標）を併記し、
        チーム全体の傾向を俯瞰できるようにする。
        各指標は全コミッター間で min-max 正規化した相対評価値を使用する。
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する（必須）。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する（必須）。
    .PARAMETER TopNCount
        総チャーン上位として SVG に描画する件数を指定する（0以下の場合は出力しない）。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitterRadarChartCombined -OutDirectory '.\output' -Committers $committers -TopNCount 10 -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$TopNCount = 0,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )

    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-CommitterRadarChartCombined: OutDirectory が空です。'
        return
    }

    if ($TopNCount -le 0)
    {
        Write-Verbose 'Write-CommitterRadarChartCombined: TopNCount が 0 以下のため、出力しません。'
        return
    }

    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        Write-Verbose 'Write-CommitterRadarChartCombined: Committers が空です。SVG を生成しません。'
        return
    }

    if (-not (Test-Path -LiteralPath $OutDirectory))
    {
        try
        {
            $null = New-Item -LiteralPath $OutDirectory -ItemType Directory -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Write-CommitterRadarChartCombined: 出力ディレクトリの作成に失敗しました: $_"
            return
        }
    }

    # 軸定義（個別チャートと同一）
    $axisDefinitions = @(
        [pscustomobject][ordered]@{ Label = 'コード生存率'; Formula = '生存行数 / 追加行数'; Unit = '率'; Invert = $false },
        [pscustomobject][ordered]@{ Label = '変更エントロピー'; Formula = 'ファイル別チャーンのエントロピー'; Unit = 'bit'; Invert = $false },
        [pscustomobject][ordered]@{ Label = '自己相殺率'; Formula = '自己相殺行数 / 追加行数'; Unit = '率'; Invert = $true },
        [pscustomobject][ordered]@{ Label = '被削除率'; Formula = '被他者削除行数 / 追加行数'; Unit = '率'; Invert = $true },
        [pscustomobject][ordered]@{ Label = '他者コード変更生存率'; Formula = '他者コード変更生存行数 / 他者コード変更行数'; Unit = '率'; Invert = $false },
        [pscustomobject][ordered]@{ Label = 'ピンポン率'; Formula = 'ピンポン回数 / コミット数'; Unit = '率'; Invert = $true },
        [pscustomobject][ordered]@{ Label = '所有集中度'; Formula = '所有行数 / 全所有行数'; Unit = '率'; Invert = $false },
        [pscustomobject][ordered]@{ Label = '定着コミット量'; Formula = '生存行数 / コミット数'; Unit = '行'; Invert = $false },
        [pscustomobject][ordered]@{ Label = 'トータルコミット量'; Formula = '追加行数 + 削除行数'; Unit = '行'; Invert = $false }
    )

    # データ収集
    $chartRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($committer in @($Committers))
    {
        if ($null -eq $committer)
        {
            continue
        }
        $addedLines = 0.0
        if ($null -ne $committer.'追加行数')
        {
            $addedLines = [double]$committer.'追加行数'
        }
        if ($addedLines -le 0)
        {
            continue
        }
        $survivedLines = 0.0
        if ($null -ne $committer.'生存行数')
        {
            $survivedLines = [double]$committer.'生存行数'
        }
        $changeEntropy = 0.0
        if ($null -ne $committer.'変更エントロピー')
        {
            $changeEntropy = [double]$committer.'変更エントロピー'
        }
        $deletedLines = 0.0
        if ($null -ne $committer.'削除行数')
        {
            $deletedLines = [double]$committer.'削除行数'
        }
        $selfCancelLines = 0.0
        if ($null -ne $committer.'自己相殺行数')
        {
            $selfCancelLines = [double]$committer.'自己相殺行数'
        }
        $removedByOthers = 0.0
        if ($null -ne $committer.'被他者削除行数')
        {
            $removedByOthers = [double]$committer.'被他者削除行数'
        }
        $otherChangeRate = 0.0
        if ($null -ne $committer.'他者コード変更生存率')
        {
            $otherChangeRate = [double]$committer.'他者コード変更生存率'
        }
        $pingPongPerCommit = 0.0
        if ($null -ne $committer.'ピンポン率')
        {
            $pingPongPerCommit = [double]$committer.'ピンポン率'
        }
        elseif ($null -ne $committer.'コミットあたりピンポン')
        {
            $pingPongPerCommit = [double]$committer.'コミットあたりピンポン'
        }
        $ownershipShare = 0.0
        if ($null -ne $committer.'所有割合')
        {
            $ownershipShare = [double]$committer.'所有割合'
        }
        $totalChurn = 0.0
        if ($null -ne $committer.'総チャーン')
        {
            $totalChurn = [double]$committer.'総チャーン'
        }
        $commitCount = 0.0
        if ($null -ne $committer.'コミット数')
        {
            $commitCount = [double]$committer.'コミット数'
        }
        $retainedVolumePerCommit = 0.0
        if ($commitCount -gt 0.0)
        {
            $retainedVolumePerCommit = $survivedLines / $commitCount
        }
        $totalCommitVolume = $addedLines + $deletedLines

        $rawScores = [ordered]@{
            'コード生存率' = $survivedLines / $addedLines
            '変更エントロピー' = $changeEntropy
            '自己相殺率' = $selfCancelLines / $addedLines
            '被削除率' = $removedByOthers / $addedLines
            '他者コード変更生存率' = $otherChangeRate
            'ピンポン率' = $pingPongPerCommit
            '所有集中度' = $ownershipShare
            '定着コミット量' = $retainedVolumePerCommit
            'トータルコミット量' = $totalCommitVolume
        }
        $chartRows.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$committer.'作者'))
                TotalChurn = $totalChurn
                RawScores = $rawScores
            }) | Out-Null
    }

    if ($chartRows.Count -eq 0)
    {
        return
    }

    # min-max 算出（全コミッター横断で相対評価）
    $axisMinMax = @{}
    foreach ($axis in $axisDefinitions)
    {
        $axisLabel = [string]$axis.Label
        $axisValues = @($chartRows.ToArray() | ForEach-Object { [double]$_.RawScores[$axisLabel] })
        $stats = $axisValues | Measure-Object -Minimum -Maximum
        $axisMinMax[$axisLabel] = [pscustomobject][ordered]@{
            Min = [double]$stats.Minimum
            Max = [double]$stats.Maximum
        }
    }

    $topChartRows = @($chartRows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'
            Descending = $true
        }, 'Author')
    if ($topChartRows.Count -eq 0)
    {
        return
    }

    # グリッドレイアウト定数
    $axisCount = $axisDefinitions.Count
    $gridColumns = [Math]::Min(3, $topChartRows.Count)
    $gridRowCount = [Math]::Ceiling($topChartRows.Count / [double]$gridColumns)
    $cellWidth = 420.0
    $cellHeight = 440.0
    $cellPadding = 16.0
    $radius = 110.0
    $labelRadius = 144.0
    $axisLabelFontSize = 9.0
    $titleFontSize = 13.0
    $guideLevels = @(0.25, 0.5, 0.75, 1.0)
    $headerHeight = 52.0
    $svgWidth = ($cellWidth * $gridColumns) + ($cellPadding * ($gridColumns + 1))
    $svgHeight = $headerHeight + ($cellHeight * $gridRowCount) + ($cellPadding * ($gridRowCount + 1))

    # 各コミッターの正規化スコアとレーダー面積スコアを事前計算
    $rowDataList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $topChartRows)
    {
        $normalizedValues = New-Object 'System.Collections.Generic.List[double]'
        for ($i = 0; $i -lt $axisCount; $i++)
        {
            $axisLabel = [string]$axisDefinitions[$i].Label
            $rawValue = [double]$row.RawScores[$axisLabel]
            $normalized = ConvertTo-NormalizedScore -Value $rawValue -Min ([double]$axisMinMax[$axisLabel].Min) -Max ([double]$axisMinMax[$axisLabel].Max) -Invert:$axisDefinitions[$i].Invert
            $normalizedValues.Add($normalized) | Out-Null
        }
        # レーダー面積スコア: Shoelace 公式による多角形面積 / 最大面積 * 100
        $radarArea = 0.0
        $angleStep = (2.0 * [Math]::PI) / [double]$axisCount
        for ($i = 0; $i -lt $axisCount; $i++)
        {
            $j = ($i + 1) % $axisCount
            $radarArea += $normalizedValues[$i] * $normalizedValues[$j] * [Math]::Sin($angleStep)
        }
        $radarArea = $radarArea / 2.0
        # 最大面積 = 全軸が 1.0 の正 n 角形
        $maxArea = ($axisCount / 2.0) * [Math]::Sin($angleStep)
        $areaScore = 0.0
        if ($maxArea -gt 0.0)
        {
            $areaScore = ($radarArea / $maxArea) * 100.0
        }
        $rowDataList.Add([pscustomobject][ordered]@{
                Row = $row
                NormalizedValues = $normalizedValues.ToArray()
                AreaScore = $areaScore
            }) | Out-Null
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" role="img" aria-label="チーム全体レーダーチャート（グリッド）">' -f $svgWidth, $svgHeight))
    [void]$sb.AppendLine('  <defs>')
    [void]$sb.AppendLine('    <style><![CDATA[')
    [void]$sb.AppendLine('      text { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; }')
    [void]$sb.AppendLine('      .page-title { font-size: 18px; font-weight: 700; fill: #1f2937; text-anchor: middle; }')
    [void]$sb.AppendLine('      .page-subtitle { font-size: 11px; fill: #64748b; text-anchor: middle; }')
    [void]$sb.AppendLine('      .cell-bg { fill: #ffffff; stroke: #e2e8f0; stroke-width: 1; rx: 8; ry: 8; }')
    [void]$sb.AppendLine('      .cell-title { font-size: 13px; font-weight: 700; fill: #1f2937; text-anchor: middle; }')
    [void]$sb.AppendLine('      .guide-line { stroke: #e2e8f0; stroke-width: 0.7; fill: none; }')
    [void]$sb.AppendLine('      .axis-line { stroke: #d0d8e4; stroke-width: 0.7; }')
    [void]$sb.AppendLine('      .axis-label { font-size: 9px; fill: #475569; dominant-baseline: middle; }')
    [void]$sb.AppendLine('      .radar-area { fill: rgba(37, 99, 235, 0.25); stroke: #2563eb; stroke-width: 1.8; }')
    [void]$sb.AppendLine('      .radar-point { fill: #1d4ed8; stroke: #ffffff; stroke-width: 0.8; }')
    [void]$sb.AppendLine('      .raw-value { font-size: 9px; fill: #1e40af; font-weight: 600; }')
    [void]$sb.AppendLine('      .area-score { font-size: 12px; font-weight: 700; fill: #1e40af; text-anchor: middle; }')
    [void]$sb.AppendLine('      .area-label { font-size: 10px; fill: #64748b; text-anchor: middle; }')
    [void]$sb.AppendLine('    ]]></style>')
    [void]$sb.AppendLine('  </defs>')
    [void]$sb.AppendLine(('  <rect x="0" y="0" width="{0}" height="{1}" fill="#f1f5f9" />' -f $svgWidth, $svgHeight))
    [void]$sb.AppendLine(("  <text class=""page-title"" x=""{0:F2}"" y=""24"">チーム品質レーダーチャート</text>" -f ($svgWidth / 2.0)))
    $subtitleText = '{0} 名 ─ 外側ほど高評価（相対比較）' -f $topChartRows.Count
    [void]$sb.AppendLine(("  <text class=""page-subtitle"" x=""{0:F2}"" y=""42"">{1}</text>" -f ($svgWidth / 2.0), (ConvertTo-SvgEscapedText -Text $subtitleText)))

    # 各セルの描画
    for ($cellIdx = 0; $cellIdx -lt $topChartRows.Count; $cellIdx++)
    {
        $rowData = $rowDataList[$cellIdx]
        $row = $rowData.Row
        $normalizedValues = $rowData.NormalizedValues
        $areaScore = $rowData.AreaScore

        $colIdx = $cellIdx % $gridColumns
        $gridRow = [Math]::Floor($cellIdx / [double]$gridColumns)
        $cellX = $cellPadding + ($colIdx * ($cellWidth + $cellPadding))
        $cellY = $headerHeight + $cellPadding + ($gridRow * ($cellHeight + $cellPadding))
        $cellCenterX = $cellX + ($cellWidth / 2.0)
        $cellCenterY = $cellY + 34.0 + $labelRadius + 10.0

        # セル背景
        [void]$sb.AppendLine(("  <rect class=""cell-bg"" x=""{0:F2}"" y=""{1:F2}"" width=""{2:F2}"" height=""{3:F2}"" />" -f $cellX, $cellY, $cellWidth, $cellHeight))

        # 作者名タイトル
        $authorName = [string]$row.Author
        if ([string]::IsNullOrWhiteSpace($authorName))
        {
            $authorName = '(unknown)'
        }
        $fittedTitle = Get-SvgFittedText -Text $authorName -MaxWidth ($cellWidth - 40.0) -FontSize $titleFontSize
        $escapedTitle = ConvertTo-SvgEscapedText -Text $fittedTitle
        [void]$sb.AppendLine(("  <text class=""cell-title"" x=""{0:F2}"" y=""{1:F2}"">{2}</text>" -f $cellCenterX, ($cellY + 22.0), $escapedTitle))

        # ガイドライン背景円
        [void]$sb.AppendLine(("  <circle cx=""{0:F2}"" cy=""{1:F2}"" r=""{2:F2}"" fill=""#fafbfc"" stroke=""#e8ecf1"" stroke-width=""0.7"" />" -f $cellCenterX, $cellCenterY, ($radius + 6.0)))

        # 外周ポイント計算
        $outerPoints = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $axisCount; $i++)
        {
            $angle = (((2.0 * [Math]::PI) * $i) / [double]$axisCount) - ([Math]::PI / 2.0)
            $xOuter = $cellCenterX + ($radius * [Math]::Cos($angle))
            $yOuter = $cellCenterY + ($radius * [Math]::Sin($angle))
            $axisLabel = [string]$axisDefinitions[$i].Label
            $rawValue = [double]$row.RawScores[$axisLabel]
            $rawDisplayCombined = if ([string]$axisDefinitions[$i].Unit -eq '行')
            {
                if ($rawValue -ge 10000)
                {
                    '{0:N0}' -f $rawValue
                }
                else
                {
                    '{0:F1}' -f $rawValue
                }
            }
            elseif ([string]$axisDefinitions[$i].Unit -eq 'bit')
            {
                '{0:F2} bit' -f $rawValue
            }
            else
            {
                '{0:P1}' -f $rawValue
            }
            $outerPoints.Add([pscustomobject][ordered]@{
                    X = $xOuter
                    Y = $yOuter
                    Angle = $angle
                    Label = $axisLabel
                    Invert = [bool]$axisDefinitions[$i].Invert
                    RawDisplay = $rawDisplayCombined
                }) | Out-Null
        }

        # ガイドライン（同心多角形）
        foreach ($level in $guideLevels)
        {
            $guidePoints = @()
            foreach ($point in @($outerPoints.ToArray()))
            {
                $gx = $cellCenterX + (($point.X - $cellCenterX) * $level)
                $gy = $cellCenterY + (($point.Y - $cellCenterY) * $level)
                $guidePoints += ('{0:F2},{1:F2}' -f $gx, $gy)
            }
            [void]$sb.AppendLine(("  <polygon class=""guide-line"" points=""{0}"" />" -f ($guidePoints -join ' ')))
        }

        # 軸線
        foreach ($point in @($outerPoints.ToArray()))
        {
            [void]$sb.AppendLine(("  <line class=""axis-line"" x1=""{0:F2}"" y1=""{1:F2}"" x2=""{2:F2}"" y2=""{3:F2}"" />" -f $cellCenterX, $cellCenterY, $point.X, $point.Y))
        }

        # データポリゴン
        $dataPoints = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $axisCount; $i++)
        {
            $angle = (((2.0 * [Math]::PI) * $i) / [double]$axisCount) - ([Math]::PI / 2.0)
            $nv = $normalizedValues[$i]
            $xData = $cellCenterX + (($radius * $nv) * [Math]::Cos($angle))
            $yData = $cellCenterY + (($radius * $nv) * [Math]::Sin($angle))
            $dataPoints.Add([pscustomobject][ordered]@{
                    X = $xData
                    Y = $yData
                }) | Out-Null
        }
        $polygonPoints = @($dataPoints.ToArray() | ForEach-Object { '{0:F2},{1:F2}' -f $_.X, $_.Y }) -join ' '
        [void]$sb.AppendLine(("  <polygon class=""radar-area"" points=""{0}"" />" -f $polygonPoints))
        foreach ($point in @($dataPoints.ToArray()))
        {
            [void]$sb.AppendLine(("  <circle class=""radar-point"" cx=""{0:F2}"" cy=""{1:F2}"" r=""2.8"" />" -f $point.X, $point.Y))
        }

        # 軸ラベル（下部の重なり回避）
        $labelItems2 = New-Object 'System.Collections.Generic.List[object]'
        foreach ($point in @($outerPoints.ToArray()))
        {
            $labelX = $cellCenterX + ($labelRadius * [Math]::Cos($point.Angle))
            $labelY = $cellCenterY + ($labelRadius * [Math]::Sin($point.Angle))
            $anchor = 'middle'
            $axisCos = [Math]::Cos($point.Angle)
            if ($axisCos -gt 0.2)
            {
                $anchor = 'start'
            }
            elseif ($axisCos -lt -0.2)
            {
                $anchor = 'end'
            }
            $labelItems2.Add([pscustomobject][ordered]@{
                    X = $labelX
                    Y = $labelY
                    Anchor = $anchor
                    Label = [string]$point.Label
                    Invert = [bool]$point.Invert
                    RawDisplay = [string]$point.RawDisplay
                }) | Out-Null
        }

        $minGap2 = 14.0
        $bottomLabels2 = @($labelItems2.ToArray() | Where-Object { $_.Y -gt $cellCenterY })
        $bottomSorted2 = @($bottomLabels2 | Sort-Object -Property Y)
        for ($bi2 = 1; $bi2 -lt $bottomSorted2.Count; $bi2++)
        {
            $prev2 = $bottomSorted2[$bi2 - 1]
            $curr2 = $bottomSorted2[$bi2]
            $gap2 = $curr2.Y - $prev2.Y
            if ($gap2 -lt $minGap2)
            {
                $curr2.Y = $prev2.Y + $minGap2
            }
        }

        # Y が上半分のラベル重なり回避
        $topLabels2 = @($labelItems2.ToArray() | Where-Object { $_.Y -lt $cellCenterY })
        $topSorted2 = @($topLabels2 | Sort-Object -Property Y -Descending)
        for ($ti2 = 1; $ti2 -lt $topSorted2.Count; $ti2++)
        {
            $prev2 = $topSorted2[$ti2 - 1]
            $curr2 = $topSorted2[$ti2]
            $gap2 = $prev2.Y - $curr2.Y
            if ($gap2 -lt $minGap2)
            {
                $curr2.Y = $prev2.Y - $minGap2
            }
        }

        foreach ($item2 in @($labelItems2.ToArray()))
        {
            $maxLabelWidth2 = 0.0
            if ($item2.Anchor -eq 'start')
            {
                $maxLabelWidth2 = [Math]::Max(60.0, ($cellX + $cellWidth - 6.0) - $item2.X)
            }
            elseif ($item2.Anchor -eq 'end')
            {
                $maxLabelWidth2 = [Math]::Max(60.0, $item2.X - ($cellX + 6.0))
            }
            else
            {
                $maxLabelWidth2 = [Math]::Max(60.0, [Math]::Min($item2.X - ($cellX + 6.0), ($cellX + $cellWidth - 6.0) - $item2.X) * 2.0)
            }
            $dirMark2 = if ([bool]$item2.Invert)
            {
                '↕'
            }
            else
            {
                '↗'
            }
            $labelWithDir2 = '{0} {1}' -f [string]$item2.Label, $dirMark2
            $fittedLabel = Get-SvgFittedText -Text $labelWithDir2 -MaxWidth $maxLabelWidth2 -FontSize $axisLabelFontSize
            $escapedLabel = ConvertTo-SvgEscapedText -Text $fittedLabel
            $escapedRawValue2 = ConvertTo-SvgEscapedText -Text ([string]$item2.RawDisplay)
            [void]$sb.AppendLine(("  <text class=""axis-label"" x=""{0:F2}"" y=""{1:F2}"" text-anchor=""{2}""><tspan>{3}</tspan><tspan x=""{0:F2}"" dy=""1.1em"" class=""raw-value"">{4}</tspan></text>" -f $item2.X, $item2.Y, $item2.Anchor, $escapedLabel, $escapedRawValue2))
        }

        # レーダー面積スコア
        $areaDisplayY = $cellY + $cellHeight - 28.0
        [void]$sb.AppendLine(("  <text class=""area-label"" x=""{0:F2}"" y=""{1:F2}"">総合スコア（レーダー面積）</text>" -f $cellCenterX, $areaDisplayY))
        [void]$sb.AppendLine(("  <text class=""area-score"" x=""{0:F2}"" y=""{1:F2}"">{2:F1}%</text>" -f $cellCenterX, ($areaDisplayY + 16.0), $areaScore))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'committer_radar_combined.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

# endregion PlantUML 出力
# region SVG 出力
function ConvertTo-SvgNumberString
{
    <#
    .SYNOPSIS
        SVG 属性値向けに数値を InvariantCulture 文字列へ変換する。
    #>
    param([double]$Value)
    return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}
function ConvertTo-SvgGradientColor
{
    <#
    .SYNOPSIS
        スコアを赤→黄→緑のグラデーション色へ変換する。
    .PARAMETER Score
        正規化対象のスコア値を指定する。
    .PARAMETER Min
        スコア範囲の最小値を指定する。
    .PARAMETER Max
        スコア範囲の最大値を指定する。
    #>
    param([double]$Score, [double]$Min, [double]$Max)
    $t = 0.0
    if ($Max -gt $Min)
    {
        $t = ($Score - $Min) / ($Max - $Min)
        if ($t -lt 0.0)
        {
            $t = 0.0
        }
        elseif ($t -gt 1.0)
        {
            $t = 1.0
        }
    }

    $r = 0
    $g = 0
    $b = 0
    if ($t -lt 0.5)
    {
        $local = $t / 0.5
        $r = 231
        $g = [int][Math]::Round(76 + ((255 - 76) * $local))
        $b = [int][Math]::Round(60 + ((0 - 60) * $local))
    }
    else
    {
        $local = ($t - 0.5) / 0.5
        $r = [int][Math]::Round(255 + ((46 - 255) * $local))
        $g = [int][Math]::Round(255 + ((204 - 255) * $local))
        $b = [int][Math]::Round(0 + ((113 - 0) * $local))
    }

    return ('#{0}{1}{2}' -f $r.ToString('X2'), $g.ToString('X2'), $b.ToString('X2')).ToLowerInvariant()
}
function ConvertTo-SvgEscapedText
{
    <#
    .SYNOPSIS
        SVG テキスト用に XML 特殊文字をエスケープする。
    #>
    param([string]$Text)
    if ($null -eq $Text)
    {
        return ''
    }
    $escaped = [System.Security.SecurityElement]::Escape($Text)
    if ($null -eq $escaped)
    {
        return ''
    }
    return $escaped
}
function Get-SvgCharacterWidth
{
    <#
    .SYNOPSIS
        SVG テキスト描画向けに 1 文字あたりの概算幅を返す。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [char]$Character,
        [Parameter(Mandatory = $false)]
        [double]$FontSize = 12.0
    )

    $size = [Math]::Max(1.0, [double]$FontSize)
    $codePoint = [int]$Character
    $ratio = 0.56
    if ([char]::IsWhiteSpace($Character))
    {
        $ratio = 0.33
    }
    elseif (
        ($codePoint -ge 0x3000 -and $codePoint -le 0x303F) -or
        ($codePoint -ge 0x3040 -and $codePoint -le 0x30FF) -or
        ($codePoint -ge 0x3400 -and $codePoint -le 0x4DBF) -or
        ($codePoint -ge 0x4E00 -and $codePoint -le 0x9FFF) -or
        ($codePoint -ge 0xF900 -and $codePoint -le 0xFAFF) -or
        ($codePoint -ge 0xAC00 -and $codePoint -le 0xD7AF) -or
        ($codePoint -ge 0xFF01 -and $codePoint -le 0xFF60) -or
        ($codePoint -ge 0xFFE0 -and $codePoint -le 0xFFE6)
    )
    {
        $ratio = 1.00
    }
    elseif (
        $Character -eq '.' -or
        $Character -eq ',' -or
        $Character -eq ':' -or
        $Character -eq ';' -or
        $Character -eq '|' -or
        $Character -eq '!' -or
        $Character -eq 'i' -or
        $Character -eq 'l' -or
        $Character -eq 'I'
    )
    {
        $ratio = 0.34
    }
    elseif (
        $Character -eq 'W' -or
        $Character -eq 'M' -or
        $Character -eq '@' -or
        $Character -eq '#'
    )
    {
        $ratio = 0.82
    }

    return [Math]::Round($ratio * $size, 2)
}
function Measure-SvgTextWidth
{
    <#
    .SYNOPSIS
        SVG テキストの概算描画幅をピクセルで返す。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,
        [Parameter(Mandatory = $false)]
        [double]$FontSize = 12.0
    )

    if ([string]::IsNullOrEmpty($Text))
    {
        return 0.0
    }

    $width = 0.0
    foreach ($character in $Text.ToCharArray())
    {
        $width += Get-SvgCharacterWidth -Character $character -FontSize $FontSize
    }
    return [Math]::Round($width, 2)
}
function Get-SvgFittedText
{
    <#
    .SYNOPSIS
        指定幅に収まるように SVG ラベルを省略付きで調整する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,
        [Parameter(Mandatory = $false)]
        [double]$MaxWidth = 0.0,
        [Parameter(Mandatory = $false)]
        [double]$FontSize = 12.0,
        [Parameter(Mandatory = $false)]
        [string]$Ellipsis = '…'
    )

    if ([string]::IsNullOrEmpty($Text))
    {
        return ''
    }

    $allowedWidth = [Math]::Max(0.0, [double]$MaxWidth)
    if ($allowedWidth -le 0.0)
    {
        return ''
    }

    if ((Measure-SvgTextWidth -Text $Text -FontSize $FontSize) -le $allowedWidth)
    {
        return $Text
    }

    $ellipsisText = $Ellipsis
    if ([string]::IsNullOrEmpty($ellipsisText))
    {
        $ellipsisText = '…'
    }
    $ellipsisWidth = Measure-SvgTextWidth -Text $ellipsisText -FontSize $FontSize
    if ($ellipsisWidth -ge $allowedWidth)
    {
        return $ellipsisText
    }

    $buffer = New-Object 'System.Collections.Generic.List[char]'
    $currentWidth = 0.0
    foreach ($character in $Text.ToCharArray())
    {
        $charWidth = Get-SvgCharacterWidth -Character $character -FontSize $FontSize
        if (($currentWidth + $charWidth + $ellipsisWidth) -gt $allowedWidth)
        {
            break
        }
        $buffer.Add($character) | Out-Null
        $currentWidth += $charWidth
    }

    if ($buffer.Count -eq 0)
    {
        return $ellipsisText
    }

    return ((-join $buffer.ToArray()) + $ellipsisText)
}
function Get-SvgCompactPathLabel
{
    <#
    .SYNOPSIS
        パス文字列を末尾優先で SVG 表示幅に収まるラベルへ変換する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [double]$MaxWidth = 0.0,
        [Parameter(Mandatory = $false)]
        [double]$FontSize = 12.0
    )

    if ([string]::IsNullOrWhiteSpace($Path))
    {
        return ''
    }

    $normalizedPath = [string]$Path -replace '\\', '/'
    $allowedWidth = [Math]::Max(0.0, [double]$MaxWidth)
    if ($allowedWidth -le 0.0)
    {
        return ''
    }
    if ((Measure-SvgTextWidth -Text $normalizedPath -FontSize $FontSize) -le $allowedWidth)
    {
        return $normalizedPath
    }

    $fileName = Split-Path -Path $normalizedPath -Leaf
    if ([string]::IsNullOrWhiteSpace($fileName))
    {
        $parts = @($normalizedPath -split '/')
        if ($parts.Count -gt 0)
        {
            $fileName = [string]$parts[$parts.Count - 1]
        }
    }
    if ([string]::IsNullOrWhiteSpace($fileName))
    {
        $fileName = $normalizedPath
    }

    $prefix = '…/'
    $prefixWidth = Measure-SvgTextWidth -Text $prefix -FontSize $FontSize
    $remainingWidth = $allowedWidth - $prefixWidth
    if ($remainingWidth -gt 0.0)
    {
        $fittedFileName = Get-SvgFittedText -Text $fileName -MaxWidth $remainingWidth -FontSize $FontSize
        if (-not [string]::IsNullOrWhiteSpace($fittedFileName))
        {
            return ($prefix + $fittedFileName)
        }
    }

    return Get-SvgFittedText -Text $normalizedPath -MaxWidth $allowedWidth -FontSize $FontSize
}
function Get-TreemapWorstAspectRatio
{
    <#
    .SYNOPSIS
        Squarified Treemap 行候補の worst aspect ratio を計算する。
    #>
    param([object[]]$RowItems, [double]$ShortSide)
    $items = @($RowItems)
    if ($items.Count -eq 0 -or $ShortSide -le 0)
    {
        return [double]::PositiveInfinity
    }

    $sumArea = 0.0
    $maxArea = 0.0
    $minArea = [double]::PositiveInfinity
    foreach ($item in $items)
    {
        if ($null -eq $item)
        {
            continue
        }
        $area = [double]$item.Area
        if ($area -le 0)
        {
            continue
        }
        $sumArea += $area
        if ($area -gt $maxArea)
        {
            $maxArea = $area
        }
        if ($area -lt $minArea)
        {
            $minArea = $area
        }
    }

    if ($sumArea -le 0 -or $maxArea -le 0 -or $minArea -le 0)
    {
        return [double]::PositiveInfinity
    }

    $shortSideSquare = $ShortSide * $ShortSide
    $sumSquare = $sumArea * $sumArea
    $ratioA = ($shortSideSquare * $maxArea) / $sumSquare
    $ratioB = $sumSquare / ($shortSideSquare * $minArea)
    if ($ratioA -gt $ratioB)
    {
        return $ratioA
    }
    return $ratioB
}
function Add-SquarifiedTreemapRow
{
    <#
    .SYNOPSIS
        Squarified Treemap の 1 行を現在矩形へ配置し、残り領域を返す。
    #>
    param([object[]]$RowItems, [double]$X, [double]$Y, [double]$Width, [double]$Height)
    $items = @($RowItems)
    $rectangles = New-Object 'System.Collections.Generic.List[object]'
    if ($items.Count -eq 0)
    {
        return [pscustomobject]@{
            Rectangles = @()
            NextX = $X
            NextY = $Y
            NextWidth = $Width
            NextHeight = $Height
        }
    }

    $rowArea = 0.0
    foreach ($item in $items)
    {
        $rowArea += [double]$item.Area
    }

    if ($Width -ge $Height)
    {
        $rowHeight = 0.0
        if ($Width -gt 0)
        {
            $rowHeight = $rowArea / $Width
        }
        $rowHeight = [Math]::Max(0.0, [Math]::Min($rowHeight, $Height))
        $currentX = $X
        for ($index = 0
            $index -lt $items.Count
            $index++)
        {
            $item = $items[$index]
            $cellWidth = 0.0
            if ($rowHeight -gt 0)
            {
                $cellWidth = [double]$item.Area / $rowHeight
            }
            if ($index -eq ($items.Count - 1))
            {
                $cellWidth = ($X + $Width) - $currentX
            }
            $cellWidth = [Math]::Max(0.0, $cellWidth)
            $rectangles.Add([pscustomobject]@{
                    Item = $item.Item
                    X = $currentX
                    Y = $Y
                    Width = $cellWidth
                    Height = $rowHeight
                }) | Out-Null
            $currentX += $cellWidth
        }
        return [pscustomobject]@{
            Rectangles = @($rectangles.ToArray())
            NextX = $X
            NextY = $Y + $rowHeight
            NextWidth = $Width
            NextHeight = [Math]::Max(0.0, $Height - $rowHeight)
        }
    }

    $rowWidth = 0.0
    if ($Height -gt 0)
    {
        $rowWidth = $rowArea / $Height
    }
    $rowWidth = [Math]::Max(0.0, [Math]::Min($rowWidth, $Width))
    $currentY = $Y
    for ($index = 0
        $index -lt $items.Count
        $index++)
    {
        $item = $items[$index]
        $cellHeight = 0.0
        if ($rowWidth -gt 0)
        {
            $cellHeight = [double]$item.Area / $rowWidth
        }
        if ($index -eq ($items.Count - 1))
        {
            $cellHeight = ($Y + $Height) - $currentY
        }
        $cellHeight = [Math]::Max(0.0, $cellHeight)
        $rectangles.Add([pscustomobject]@{
                Item = $item.Item
                X = $X
                Y = $currentY
                Width = $rowWidth
                Height = $cellHeight
            }) | Out-Null
        $currentY += $cellHeight
    }
    return [pscustomobject]@{
        Rectangles = @($rectangles.ToArray())
        NextX = $X + $rowWidth
        NextY = $Y
        NextWidth = [Math]::Max(0.0, $Width - $rowWidth)
        NextHeight = $Height
    }
}
function Get-SquarifiedTreemapLayout
{
    <#
    .SYNOPSIS
        Squarified Treemap アルゴリズムで重み付き項目の矩形配置を計算する。
    #>
    param([double]$X, [double]$Y, [double]$Width, [double]$Height, [object[]]$Items)
    if ($Width -le 0 -or $Height -le 0)
    {
        return @()
    }

    $weighted = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Items))
    {
        if ($null -eq $item)
        {
            continue
        }
        $weightValue = 0.0
        try
        {
            $weightValue = [double]$item.Weight
        }
        catch
        {
            $weightValue = 0.0
        }
        $weightValue = [Math]::Max(1.0, $weightValue)
        $weighted.Add([pscustomobject]@{
                Item = $item
                Weight = $weightValue
            }) | Out-Null
    }

    if ($weighted.Count -eq 0)
    {
        return @()
    }

    $sortedItems = @($weighted.ToArray() | Sort-Object -Property @{Expression = 'Weight'
            Descending = $true
        })
    $totalWeight = 0.0
    foreach ($sortedItem in $sortedItems)
    {
        $totalWeight += [double]$sortedItem.Weight
    }

    $canvasArea = [Math]::Max(0.0, ($Width * $Height))
    $scaledItems = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sortedItem in $sortedItems)
    {
        $scaledArea = 0.0
        if ($totalWeight -gt 0)
        {
            $scaledArea = ([double]$sortedItem.Weight / $totalWeight) * $canvasArea
        }
        elseif ($sortedItems.Count -gt 0)
        {
            $scaledArea = $canvasArea / [double]$sortedItems.Count
        }
        $scaledItems.Add([pscustomobject]@{
                Item = $sortedItem.Item
                Area = $scaledArea
            }) | Out-Null
    }

    $result = New-Object 'System.Collections.Generic.List[object]'
    $row = New-Object 'System.Collections.Generic.List[object]'
    $remainingX = $X
    $remainingY = $Y
    $remainingWidth = $Width
    $remainingHeight = $Height
    $index = 0
    while ($index -lt $scaledItems.Count)
    {
        if ($remainingWidth -le 0 -or $remainingHeight -le 0)
        {
            break
        }

        $candidate = $scaledItems[$index]
        if ($row.Count -eq 0)
        {
            $row.Add($candidate) | Out-Null
            $index++
            continue
        }

        $shortSide = [Math]::Min($remainingWidth, $remainingHeight)
        $currentWorst = Get-TreemapWorstAspectRatio -RowItems @($row.ToArray()) -ShortSide $shortSide
        $trialRow = @($row.ToArray()) + $candidate
        $trialWorst = Get-TreemapWorstAspectRatio -RowItems $trialRow -ShortSide $shortSide
        if ($trialWorst -le $currentWorst)
        {
            $row.Add($candidate) | Out-Null
            $index++
            continue
        }

        $layout = Add-SquarifiedTreemapRow -RowItems @($row.ToArray()) -X $remainingX -Y $remainingY -Width $remainingWidth -Height $remainingHeight
        foreach ($rect in @($layout.Rectangles))
        {
            $result.Add($rect) | Out-Null
        }
        $remainingX = [double]$layout.NextX
        $remainingY = [double]$layout.NextY
        $remainingWidth = [double]$layout.NextWidth
        $remainingHeight = [double]$layout.NextHeight
        $row.Clear()
    }

    if ($row.Count -gt 0 -and $remainingWidth -gt 0 -and $remainingHeight -gt 0)
    {
        $layout = Add-SquarifiedTreemapRow -RowItems @($row.ToArray()) -X $remainingX -Y $remainingY -Width $remainingWidth -Height $remainingHeight
        foreach ($rect in @($layout.Rectangles))
        {
            $result.Add($rect) | Out-Null
        }
    }
    return @($result.ToArray())
}
function Write-FileTreeMap
{
    <#
    .SYNOPSIS
        ファイル別メトリクスをディレクトリ単位の SVG ツリーマップとして出力する。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Files
        Get-FileMetric の出力行を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
    param([string]$OutDirectory, [object[]]$Files, [string]$EncodingName)
    $svgWidth = 1200.0
    $svgHeight = 800.0
    $canvasMargin = 8.0
    $rootX = $canvasMargin
    $rootY = $canvasMargin
    $rootWidth = $svgWidth - ($canvasMargin * 2.0)
    $rootHeight = $svgHeight - ($canvasMargin * 2.0)
    $directoryPadding = 4.0
    $directoryHeaderHeight = 20.0
    $minFileLabelWidth = 70.0
    $minFileLabelHeight = 18.0

    $directoryMap = @{}
    $rankValues = New-Object 'System.Collections.Generic.List[double]'
    foreach ($row in @($Files))
    {
        if ($null -eq $row)
        {
            continue
        }

        $filePath = ConvertTo-PathKey -Path ([string]$row.'ファイルパス')
        if ([string]::IsNullOrWhiteSpace($filePath))
        {
            continue
        }

        $directoryPath = '(root)'
        $fileName = $filePath
        $lastSlash = $filePath.LastIndexOf('/')
        if ($lastSlash -ge 0)
        {
            $directoryPath = $filePath.Substring(0, $lastSlash)
            $fileName = $filePath.Substring($lastSlash + 1)
        }
        if ([string]::IsNullOrWhiteSpace($directoryPath))
        {
            $directoryPath = '(root)'
        }
        if ([string]::IsNullOrWhiteSpace($fileName))
        {
            $fileName = $filePath
        }

        $churnValue = 0.0
        try
        {
            $churnValue = [double]$row.'総チャーン'
        }
        catch
        {
            $churnValue = 0.0
        }
        $weight = [Math]::Max(1.0, $churnValue)

        $commitCount = 0
        try
        {
            $commitCount = [int]$row.'コミット数'
        }
        catch
        {
            $commitCount = 0
        }

        $authorCount = 0
        try
        {
            $authorCount = [int]$row.'作者数'
        }
        catch
        {
            $authorCount = 0
        }

        $rankValue = [double]($rankValues.Count + 1)
        try
        {
            $rankValue = [double]$row.'ホットスポット順位'
        }
        catch
        {
            $rankValue = [double]($rankValues.Count + 1)
        }
        if ($rankValue -le 0)
        {
            $rankValue = [double]($rankValues.Count + 1)
        }
        $rankValues.Add($rankValue) | Out-Null

        if (-not $directoryMap.ContainsKey($directoryPath))
        {
            $directoryMap[$directoryPath] = [pscustomobject]@{
                DirectoryPath = $directoryPath
                TotalWeight = 0.0
                Files = New-Object 'System.Collections.Generic.List[object]'
            }
        }
        $group = $directoryMap[$directoryPath]
        $group.TotalWeight = [double]$group.TotalWeight + $weight
        $group.Files.Add([pscustomobject]@{
                DirectoryPath = $directoryPath
                FilePath = $filePath
                FileName = $fileName
                Churn = $churnValue
                Weight = $weight
                CommitCount = $commitCount
                AuthorCount = $authorCount
                Rank = $rankValue
            }) | Out-Null
    }

    $minRank = 1.0
    $maxRank = 1.0
    if ($rankValues.Count -gt 0)
    {
        $minRank = [double](($rankValues | Measure-Object -Minimum).Minimum)
        $maxRank = [double](($rankValues | Measure-Object -Maximum).Maximum)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800" width="1200" height="800" role="img" aria-label="ファイル別ツリーマップ">')
    [void]$sb.AppendLine('  <style>')
    [void]$sb.AppendLine('    .dir-frame { fill: none; stroke: #334155; stroke-width: 1.5; }')
    [void]$sb.AppendLine('    .dir-label { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; font-size: 13px; font-weight: 700; fill: #0f172a; }')
    [void]$sb.AppendLine('    .file-label { font-family: "Segoe UI", "Yu Gothic UI", "Meiryo", sans-serif; font-size: 11px; fill: #0f172a; pointer-events: none; paint-order: stroke; stroke: #ffffff; stroke-width: 2; }')
    [void]$sb.AppendLine('  </style>')
    [void]$sb.AppendLine('  <rect x="0" y="0" width="1200" height="800" fill="#f8fafc" />')

    if ($directoryMap.Count -eq 0)
    {
        [void]$sb.AppendLine('  <text class="dir-label" x="20" y="40">No file metrics available.</text>')
        [void]$sb.AppendLine('</svg>')
        Write-TextFile -FilePath (Join-Path $OutDirectory 'file_treemap.svg') -Content $sb.ToString() -EncodingName $EncodingName
        return
    }

    $directoryItems = New-Object 'System.Collections.Generic.List[object]'
    foreach ($directoryPath in @($directoryMap.Keys))
    {
        $group = $directoryMap[$directoryPath]
        $directoryItems.Add([pscustomobject]@{
                Name = $directoryPath
                Weight = [double]$group.TotalWeight
                Group = $group
            }) | Out-Null
    }

    $directoryRects = @(Get-SquarifiedTreemapLayout -X $rootX -Y $rootY -Width $rootWidth -Height $rootHeight -Items @($directoryItems.ToArray()))
    foreach ($directoryRect in $directoryRects)
    {
        if ($null -eq $directoryRect -or $null -eq $directoryRect.Item -or $null -eq $directoryRect.Item.Group)
        {
            continue
        }

        $group = $directoryRect.Item.Group
        $dirX = [double]$directoryRect.X
        $dirY = [double]$directoryRect.Y
        $dirWidth = [double]$directoryRect.Width
        $dirHeight = [double]$directoryRect.Height
        if ($dirWidth -le 0 -or $dirHeight -le 0)
        {
            continue
        }

        $dirXText = ConvertTo-SvgNumberString -Value $dirX
        $dirYText = ConvertTo-SvgNumberString -Value $dirY
        $dirWidthText = ConvertTo-SvgNumberString -Value $dirWidth
        $dirHeightText = ConvertTo-SvgNumberString -Value $dirHeight
        [void]$sb.AppendLine(("  <rect class=""dir-frame"" x=""{0}"" y=""{1}"" width=""{2}"" height=""{3}"" />" -f $dirXText, $dirYText, $dirWidthText, $dirHeightText))
        if ($dirHeight -ge 18.0)
        {
            $headerXText = ConvertTo-SvgNumberString -Value ($dirX + 6.0)
            $headerYText = ConvertTo-SvgNumberString -Value ($dirY + 15.0)
            $dirLabelMaxWidth = [Math]::Max(20.0, $dirWidth - 12.0)
            $rawDirectoryLabel = Get-SvgCompactPathLabel -Path ([string]$group.DirectoryPath) -MaxWidth $dirLabelMaxWidth -FontSize 13.0
            $headerText = ConvertTo-SvgEscapedText -Text $rawDirectoryLabel
            if (-not [string]::IsNullOrWhiteSpace($headerText))
            {
                [void]$sb.AppendLine(("  <text class=""dir-label"" x=""{0}"" y=""{1}"">{2}</text>" -f $headerXText, $headerYText, $headerText))
            }
        }

        $innerX = $dirX + $directoryPadding
        $innerY = $dirY + $directoryHeaderHeight + $directoryPadding
        $innerWidth = $dirWidth - ($directoryPadding * 2.0)
        $innerHeight = $dirHeight - $directoryHeaderHeight - ($directoryPadding * 2.0)
        if ($innerWidth -le 0 -or $innerHeight -le 0)
        {
            continue
        }

        $fileItems = New-Object 'System.Collections.Generic.List[object]'
        foreach ($fileData in @($group.Files.ToArray()))
        {
            $fileItems.Add([pscustomobject]@{
                    Name = $fileData.FileName
                    Weight = [double]$fileData.Weight
                    Data = $fileData
                }) | Out-Null
        }
        $fileRects = @(Get-SquarifiedTreemapLayout -X $innerX -Y $innerY -Width $innerWidth -Height $innerHeight -Items @($fileItems.ToArray()))
        foreach ($fileRect in $fileRects)
        {
            if ($null -eq $fileRect -or $null -eq $fileRect.Item -or $null -eq $fileRect.Item.Data)
            {
                continue
            }

            $fileData = $fileRect.Item.Data
            $fileX = [double]$fileRect.X
            $fileY = [double]$fileRect.Y
            $fileWidth = [double]$fileRect.Width
            $fileHeight = [double]$fileRect.Height
            if ($fileWidth -le 0 -or $fileHeight -le 0)
            {
                continue
            }

            $fillColor = ConvertTo-SvgGradientColor -Score ([double]$fileData.Rank) -Min $minRank -Max $maxRank
            $fileXText = ConvertTo-SvgNumberString -Value $fileX
            $fileYText = ConvertTo-SvgNumberString -Value $fileY
            $fileWidthText = ConvertTo-SvgNumberString -Value $fileWidth
            $fileHeightText = ConvertTo-SvgNumberString -Value $fileHeight
            $churnText = ConvertTo-SvgNumberString -Value ([double]$fileData.Churn)
            $tooltip = '{0}: 総チャーン={1}, コミット数={2}, 作者数={3}' -f ([string]$fileData.FilePath), $churnText, ([int]$fileData.CommitCount), ([int]$fileData.AuthorCount)
            $tooltipText = ConvertTo-SvgEscapedText -Text $tooltip
            [void]$sb.AppendLine(("  <rect x=""{0}"" y=""{1}"" width=""{2}"" height=""{3}"" fill=""{4}"" stroke=""#ffffff"" stroke-width=""0.5""><title>{5}</title></rect>" -f $fileXText, $fileYText, $fileWidthText, $fileHeightText, $fillColor, $tooltipText))
            if ($fileWidth -ge $minFileLabelWidth -and $fileHeight -ge $minFileLabelHeight)
            {
                $fileLabelX = ConvertTo-SvgNumberString -Value ($fileX + 3.0)
                $fileLabelY = ConvertTo-SvgNumberString -Value ($fileY + 13.0)
                $fileLabelRaw = Get-SvgFittedText -Text ([string]$fileData.FileName) -MaxWidth ([Math]::Max(20.0, $fileWidth - 8.0)) -FontSize 11.0
                $fileLabel = ConvertTo-SvgEscapedText -Text $fileLabelRaw
                if (-not [string]::IsNullOrWhiteSpace($fileLabel))
                {
                    [void]$sb.AppendLine(("  <text class=""file-label"" x=""{0}"" y=""{1}"">{2}</text>" -f $fileLabelX, $fileLabelY, $fileLabel))
                }
            }
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'file_treemap.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
# endregion SVG 出力
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

        $otherChangeRate = if ($modifiedOthersCode -gt 0)
        {
            $modifiedOthersSurvived / [double]$modifiedOthersCode
        }
        else
        {
            0
        }
        $row.'他者コード変更生存率' = Format-MetricValue -Value $otherChangeRate

        $commitCount = [int]$row.'コミット数'
        $pingPongPerCommit = if ($commitCount -gt 0)
        {
            $pingPong / [double]$commitCount
        }
        else
        {
            0
        }
        $row.'ピンポン率' = Format-MetricValue -Value $pingPongPerCommit
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
        Committer = @('作者', 'コミット数', '活動日数', '変更ファイル数', '変更ディレクトリ数', '追加行数', '削除行数', '純増行数', '総チャーン', 'コミットあたりチャーン', '削除対追加比', 'チャーン対純増比', 'バイナリ変更回数', '追加アクション数', '変更アクション数', '削除アクション数', '置換アクション数', '生存行数', $script:ColDeadAdded, '所有行数', '所有割合', '自己相殺行数', '自己差戻行数', '他者差戻行数', '被他者削除行数', '同一箇所反復編集数', 'ピンポン回数', '内部移動行数', $script:ColSelfDead, $script:ColOtherDead, '他者コード変更行数', '他者コード変更生存行数', '他者コード変更生存率', 'ピンポン率', '変更エントロピー', '平均共同作者数', '最大共同作者数', 'メッセージ総文字数', 'メッセージ平均文字数', '課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
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
    .PARAMETER EmitCharts
        EmitCharts の値を指定する。
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
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
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
        [switch]$EmitCharts,
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
            EmitCharts = [bool]$EmitCharts
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
            FileBubbleSvg = if ($EmitCharts)
            {
                'file_bubble.svg'
            }
            else
            {
                $null
            }
            FileHeatMapSvg = if ($EmitCharts)
            {
                'file_heatmap.svg'
            }
            else
            {
                $null
            }
            CommitterRadarCharts = if ($EmitCharts)
            {
                'committer_radar_*.svg'
            }
            else
            {
                $null
            }
            CommitterRadarCombinedSvg = if ($EmitCharts)
            {
                'committer_radar_combined.svg'
            }
            else
            {
                $null
            }
            FileTreeMapSvg = if ($EmitCharts)
            {
                'file_treemap.svg'
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
# endregion Utility
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
    # --- ステップ 7: 可視化出力（指定時のみ） ---
    if ($EmitPlantUml)
    {
        Write-PlantUmlFile -OutDirectory $OutDir -Committers $committerRows -Files $fileRows -Couplings $couplingRows -TopNCount $TopN -EncodingName $Encoding
    }
    if ($EmitCharts)
    {
        Write-FileBubbleChart -OutDirectory $OutDir -Files $fileRows -TopNCount $TopN -EncodingName $Encoding
        Write-FileHeatMap -OutDirectory $OutDir -Files $fileRows -TopNCount $TopN -EncodingName $Encoding
        Write-CommitterRadarChart -OutDirectory $OutDir -Committers $committerRows -TopNCount $TopN -EncodingName $Encoding
        Write-CommitterRadarChartCombined -OutDirectory $OutDir -Committers $committerRows -TopNCount $TopN -EncodingName $Encoding
        Write-FileTreeMap -OutDirectory $OutDir -Files $fileRows -EncodingName $Encoding
    }

    # --- ステップ 8: 実行メタデータとサマリーの書き出し ---
    $finishedAt = Get-Date
    $meta = New-RunMetaData -StartTime $startedAt -EndTime $finishedAt -TargetUrl $targetUrl -FromRevision $FromRev -ToRevision $ToRev -AuthorFilter $Author -SvnVersion $svnVersion -NoBlame:$NoBlame -DeadDetailLevel $DeadDetailLevel -Parallel $Parallel -TopN $TopN -Encoding $Encoding -Commits $commits -FileRows $fileRows -OutDir $OutDir -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -EmitPlantUml:$EmitPlantUml -EmitCharts:$EmitCharts -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -IgnoreSpaceChange:$IgnoreSpaceChange -IgnoreAllSpace:$IgnoreAllSpace -IgnoreEolStyle:$IgnoreEolStyle -IncludeProperties:$IncludeProperties -ForceBinary:$ForceBinary
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
