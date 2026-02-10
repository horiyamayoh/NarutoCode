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

    出力は CSV レポートおよび PlantUML / SVG 可視化。
.PARAMETER RepoUrl
    解析対象の SVN リポジトリ URL。trunk やブランチのパスまで含めて指定する。
    例: https://svn.example.com/repos/myproject/trunk
.PARAMETER FromRevision
    解析範囲の開始リビジョン番号。この番号のコミットから解析を開始する。
.PARAMETER ToRevision
    解析範囲の終了リビジョン番号。この番号のコミットまでを解析対象とする。
.PARAMETER SvnExecutable
    使用する svn コマンドのパスまたは名前。デフォルトは 'svn'（PATH 上の svn を使用）。
    別バージョンの svn を使いたい場合はフルパスを指定する。
.PARAMETER OutDirectory
    解析結果（CSV / PlantUML / SVG / キャッシュ）の出力先ディレクトリ。
    未指定時はカレントディレクトリ直下に 'NarutoCode_out' を作成して使用する。
    同じディレクトリを再利用するとキャッシュが効き、再実行が高速になる。
.PARAMETER Username
    SVN リポジトリへの認証に使用するユーザー名。
    svn コマンドの --username オプションに渡される。
    認証不要なリポジトリでは省略可。
.PARAMETER Password
    SVN リポジトリへの認証に使用するパスワード（SecureString 型）。
    svn コマンドの --password オプションに渡される。
    平文ではなく SecureString で受け取るため、スクリプト内でのみ復号される。
.PARAMETER NonInteractive
    svn コマンドに --non-interactive を付与し、対話的な認証プロンプトを抑止する。
    CI/CD 環境など無人実行時に指定する。
.PARAMETER TrustServerCert
    svn コマンドに --trust-server-cert を付与し、SSL 証明書の検証をスキップする。
    自己署名証明書の SVN サーバーに接続する場合に使用する。
.PARAMETER Parallel
    並列実行するワーカー数の上限。デフォルトは CPU コア数。
    svn diff / blame の取得を並列化して高速化する。1 を指定すると逐次実行になる。
.PARAMETER IncludePaths
    解析対象に含めるパスパターンの配列（ワイルドカード対応）。
    指定するとパターンに一致するファイルのみが解析対象になる。
    例: @('src/*', 'lib/*')
.PARAMETER ExcludePaths
    解析対象から除外するパスパターンの配列（ワイルドカード対応）。
    例: @('test/*', 'vendor/*')
.PARAMETER IncludeExtensions
    解析対象に含める拡張子の配列。先頭のドットは省略可。
    指定するとこの拡張子のファイルのみが解析対象になる。
    例: @('cs', 'java', '.xml')
.PARAMETER ExcludeExtensions
    解析対象から除外する拡張子の配列。先頭のドットは省略可。
    例: @('dll', 'exe', 'png')
.PARAMETER TopNCount
    可視化（ホットスポット図・共変更ネットワーク等）に表示する上位件数。
    デフォルトは 50。CSV レポートには全件出力されるため、このパラメータは
    可視化の見やすさ制御のみに影響する。
.PARAMETER Encoding
    CSV や PlantUML など出力ファイルの文字エンコーディング。
    UTF8（BOM なし）/ UTF8BOM / Unicode / ASCII から選択。デフォルトは UTF8。
.PARAMETER IgnoreWhitespace
    svn diff 実行時に空白・改行コードの差異を無視する。
    指定すると --ignore-space-change および --ignore-eol-style が付与される。
    インデント変更のみのコミットをチャーンから除外したい場合に有用。
.PARAMETER NoProgress
    進捗バー（Write-Progress）の出力を抑止する。
    CI/CD のログやリダイレクト出力で余計な表示を避けたい場合に指定する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Alias('Path')][string]$RepoUrl,
    [Parameter(Mandatory = $true)][Alias('FromRev', 'Pre', 'Start', 'StartRevision', 'From')][int]$FromRevision,
    [Parameter(Mandatory = $true)][Alias('ToRev', 'Post', 'End', 'EndRevision', 'To')][int]$ToRevision,
    [string]$SvnExecutable = 'svn',
    [string]$OutDirectory = '',
    [string]$Username = '',
    [securestring]$Password = $null,
    [switch]$NonInteractive,
    [switch]$TrustServerCert,
    [ValidateRange(1, 128)][int]$Parallel = [Math]::Max(1, [Environment]::ProcessorCount),
    [string[]]$IncludePaths = @(),
    [string[]]$ExcludePaths = @(),
    [string[]]$IncludeExtensions = @(),
    [string[]]$ExcludeExtensions = @(),
    [ValidateRange(1, 5000)][int]$TopNCount = 50,
    [ValidateSet('UTF8', 'UTF8BOM', 'Unicode', 'ASCII')][string]$Encoding = 'UTF8',
    [switch]$IgnoreWhitespace,
    [switch]$NoProgress
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
# ディスクキャッシュ (blame XML / cat テキスト) の上位に配置するインメモリキャッシュ。
# 同一 (revision, path) への繰り返しアクセスでディスク I/O と XML パースを回避する。
# SvnBlameSummaryMemoryCache: 所有権分析フェーズで ToRevision の全ファイル分を保持 (Content 空文字のため軽量)。
# SvnBlameLineMemoryCache: Get-ExactDeathAttribution 内で使用。コミット境界で Clear() されるため
#   定常メモリは O(K×L) (K=1コミットあたり変更ファイル数, L=平均行数) に抑えられる。
$script:SvnBlameSummaryMemoryCache = @{}
$script:SvnBlameLineMemoryCache = @{}
$script:SharedSha1 = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
$script:DefaultColorPalette = @('#42a5f5', '#66bb6a', '#ffa726', '#ab47bc', '#ef5350', '#26c6da', '#8d6e63', '#78909c', '#d4e157', '#ec407a')

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
    $script:SvnBlameSummaryMemoryCache = @{}
    $script:SvnBlameLineMemoryCache = @{}
    if ($null -eq $script:SharedSha1)
    {
        $script:SharedSha1 = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
    }
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
            [void]$list.Add($x)
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
            [void]$list.Add($x)
        }
    }
    return $list.ToArray() | Select-Object -Unique
}
function Initialize-OutputDirectory
{
    <#
    .SYNOPSIS
        出力先ディレクトリが存在しない場合に作成する。
    .PARAMETER Path
        作成対象のディレクトリパスを指定する。
    .PARAMETER CallerName
        呼び出し元の関数名を指定する（エラーメッセージ用）。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [string]$CallerName = ''
    )
    if (-not (Test-Path -LiteralPath $Path))
    {
        try
        {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch
        {
            $context = if ($CallerName)
            {
                "${CallerName}: "
            }
            else
            {
                ''
            }
            Write-Warning "${context}ディレクトリ作成失敗: $_"
            return $false
        }
    }
    return $true
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
    $progressId = [Math]::Abs($ErrorContext.GetHashCode()) % 10000 + 10
    if ($effectiveParallel -le 1)
    {
        $sequentialResults = [System.Collections.Generic.List[object]]::new()
        for ($i = 0
            $i -lt $items.Count
            $i++)
        {
            $pct = [Math]::Min(100, [int](($i / $items.Count) * 100))
            Write-Progress -Id $progressId -Activity $ErrorContext -Status ('{0}/{1}' -f ($i + 1), $items.Count) -PercentComplete $pct
            try
            {
                [void]$sequentialResults.Add((& $WorkerScript -Item $items[$i] -Index $i))
            }
            catch
            {
                throw ("{0} failed at item index {1}: {2}" -f $ErrorContext, $i, $_.Exception.Message)
            }
        }
        Write-Progress -Id $progressId -Activity $ErrorContext -Completed
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
    [void]$pool.SetMinRunspaces(1)
    [void]$pool.SetMaxRunspaces($effectiveParallel)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $wrappedResults = [System.Collections.Generic.List[object]]::new()
    # 結果を元の入力順序で返すため、インデックスで管理する配列を事前確保する。
    $wrappedByIndex = New-Object 'object[]' $items.Count
    try
    {
        $pool.Open()
        $jobTotal = $items.Count
        $nextIndex = 0
        $jobDone = 0
        # 遅延投入 (lazy submission): 全ジョブを一括投入せず、同時実行数を
        # $effectiveParallel 以下に制限する。これにより PowerShell インスタンスの
        # メモリ消費を O(items.Count) → O(effectiveParallel) に抑える。
        # 完了したジョブから順にスロットを解放し、次のジョブを投入する。
        while ($nextIndex -lt $items.Count -or $jobs.Count -gt 0)
        {
            while ($nextIndex -lt $items.Count -and $jobs.Count -lt $effectiveParallel)
            {
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($invokeScript).AddArgument($workerText).AddArgument($items[$nextIndex]).AddArgument($nextIndex)
                $handle = $ps.BeginInvoke()
                [void]$jobs.Add([pscustomobject]@{
                        Index = $nextIndex
                        PowerShell = $ps
                        Handle = $handle
                    })
                $nextIndex++
            }

            $pct = [Math]::Min(100, [int](($jobDone / [Math]::Max(1, $jobTotal)) * 100))
            Write-Progress -Id $progressId -Activity $ErrorContext -Status ('{0}/{1}' -f ($jobDone + 1), $jobTotal) -PercentComplete $pct
            if ($jobs.Count -eq 0)
            {
                continue
            }

            $completedJobIndex = -1
            for ($scan = 0
                $scan -lt $jobs.Count
                $scan++)
            {
                if ($null -ne $jobs[$scan] -and $null -ne $jobs[$scan].Handle -and $jobs[$scan].Handle.IsCompleted)
                {
                    $completedJobIndex = $scan
                    break
                }
            }
            if ($completedJobIndex -lt 0)
            {
                Start-Sleep -Milliseconds 1
                continue
            }

            $job = $jobs[$completedJobIndex]
            $jobs.RemoveAt($completedJobIndex)
            if ($null -eq $job -or $null -eq $job.PowerShell)
            {
                $failedWrapped = [pscustomobject]@{
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
                }
                [void]$wrappedResults.Add($failedWrapped)
                if ($failedWrapped.Index -ge 0 -and $failedWrapped.Index -lt $wrappedByIndex.Length)
                {
                    $wrappedByIndex[$failedWrapped.Index] = $failedWrapped
                }
                $jobDone++
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
            if ($wrapped.Index -ge 0 -and $wrapped.Index -lt $wrappedByIndex.Length)
            {
                $wrappedByIndex[$wrapped.Index] = $wrapped
            }
            $jobDone++
        }
        Write-Progress -Id $progressId -Activity $ErrorContext -Completed
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
                    [void]$_
                }
            }
        }
        if ($pool)
        {
            $pool.Dispose()
        }
    }

    $orderedWrapped = [System.Collections.Generic.List[object]]::new()
    for ($orderedIndex = 0
        $orderedIndex -lt $wrappedByIndex.Length
        $orderedIndex++)
    {
        if ($null -ne $wrappedByIndex[$orderedIndex])
        {
            [void]$orderedWrapped.Add($wrappedByIndex[$orderedIndex])
        }
        else
        {
            [void]$orderedWrapped.Add([pscustomobject]@{
                    Index = $orderedIndex
                    Succeeded = $false
                    Result = $null
                    ErrorMessage = 'Worker result is missing.'
                    ErrorStack = $null
                })
        }
    }

    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($orderedWrapped.ToArray()))
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
    foreach ($entry in @($orderedWrapped.ToArray()))
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
    .DESCRIPTION
        メインスレッドでは SharedSha1 を再利用し、並列 runspace 内では
        SharedSha1 が注入されないため都度生成にフォールバックする。
        SHA1CryptoServiceProvider.ComputeHash はスレッドセーフでないため
        インスタンス共有は単一スレッド内に限定する。
    #>
    param([string]$Text)
    if ($null -eq $Text)
    {
        $Text = ''
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    # 並列 runspace では SharedSha1 が存在しないため都度生成する
    $sha = if ($script:SharedSha1)
    {
        $script:SharedSha1
    }
    else
    {
        New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
    }
    try
    {
        $hash = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        # 共有インスタンスは破棄せず、フォールバック生成分のみ Dispose する
        if ($sha -ne $script:SharedSha1)
        {
            $sha.Dispose()
        }
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
function Test-BlameCacheFileExistence
{
    <#
    .SYNOPSIS
        blame XML キャッシュファイルの存在有無を判定する。
    .DESCRIPTION
        Read-BlameCacheFile はファイル全体を読み込むため、存在確認のみが目的の場合は
        [System.IO.File]::Exists() で十分である。プリフェッチ対象スキャンでは
        N 件のファイルに対して呼ばれるため、不要なファイル読み込みを回避して高速化する。
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
        return $false
    }
    $path = Get-BlameCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    return [System.IO.File]::Exists($path)
}
function Test-CatCacheFileExistence
{
    <#
    .SYNOPSIS
        cat テキストキャッシュファイルの存在有無を判定する。
    .DESCRIPTION
        Read-CatCacheFile はファイル全体を読み込むため、存在確認のみが目的の場合は
        [System.IO.File]::Exists() で十分である。プリフェッチ対象スキャンでは
        N 件のファイルに対して呼ばれるため、不要なファイル読み込みを回避して高速化する。
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
        return $false
    }
    $path = Get-CatCachePath -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    return [System.IO.File]::Exists($path)
}
function Get-BlameMemoryCacheKey
{
    <#
    .SYNOPSIS
        blame 結果のメモリキャッシュ参照キーを生成する。
    .DESCRIPTION
        "リビジョン + Unit Separator (U+001F) + 正規化パス" の文字列をキーとする。
        Unit Separator はファイルパスに出現しない制御文字であり、キーの衝突を防ぐ。
        ハッシュテーブルのキーとして使用することで O(1) のキャッシュ参照を実現する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
    .PARAMETER FilePath
        処理対象のファイルパスを指定する。
    #>
    param([int]$Revision, [string]$FilePath)
    return ([string]$Revision + [char]31 + (ConvertTo-PathKey -Path $FilePath))
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
    if (-not [System.IO.File]::Exists($path))
    {
        return $null
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
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
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir))
    {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
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
    if (-not [System.IO.File]::Exists($path))
    {
        return $null
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
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
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir))
    {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
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
    if ([string]::IsNullOrWhiteSpace($DiffText))
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
    .PARAMETER TargetUrl
        対象 SVN リポジトリ URL を指定する。
    .PARAMETER Revision
        処理対象のリビジョン値を指定する。
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
    param([string]$TargetUrl, [int]$Revision, [string[]]$IncludeExtensions, [string[]]$ExcludeExtensions, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
    $xmlText = Invoke-SvnCommand -Arguments @('list', '-R', '--xml', '-r', [string]$Revision, $TargetUrl) -ErrorContext 'svn list'
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
        if (Test-ShouldCountFile -FilePath $path -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        {
            [void]$files.Add($path)
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
    [void]$OffsetEvents.Add([pscustomobject]@{ Threshold = $ThresholdLine; Delta = $ShiftDelta })
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
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePathPatterns
        対象を絞り込むための包含または除外条件を指定する。
    #>
    param([string]$FilePath, [string[]]$IncludeExtensions, [string[]]$ExcludeExtensions, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
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
    if ([string]::IsNullOrWhiteSpace($ext))
    {
        if ($IncludeExtensions -and $IncludeExtensions.Count -gt 0)
        {
            return $false
        }
        return $true
    }
    $ext = $ext.TrimStart('.').ToLowerInvariant()
    if ($IncludeExtensions -and $IncludeExtensions.Count -gt 0 -and -not ($IncludeExtensions -contains $ext))
    {
        return $false
    }
    if ($ExcludeExtensions -and $ExcludeExtensions.Count -gt 0 -and ($ExcludeExtensions -contains $ext))
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
            [void]$parts.Add('"' + $t.Replace('"', '\"') + '"')
        }
        else
        {
            [void]$parts.Add($t)
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
        [void]$all.Add([string]$a)
    }
    if ($script:SvnGlobalArguments)
    {
        foreach ($a in $script:SvnGlobalArguments)
        {
            [void]$all.Add([string]$a)
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
        [void]$process.Start()
        $errTask = $process.StandardError.ReadToEndAsync()
        $out = $process.StandardOutput.ReadToEnd()
        $errTask.Wait()
        $err = $errTask.Result
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
function Test-SvnMissingTargetError
{
    <#
    .SYNOPSIS
        SVN の対象不存在エラーかどうかを判定する。
    #>
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message))
    {
        return $false
    }
    if ($Message -match 'E200009')
    {
        return $true
    }
    if ($Message -match 'targets don''t exist')
    {
        return $true
    }
    return $false
}
function Invoke-SvnCommandAllowMissingTarget
{
    <#
    .SYNOPSIS
        対象不存在時に null を返す SVN コマンド実行。
    #>
    [CmdletBinding()]param([string[]]$Arguments, [string]$ErrorContext = 'SVN command')
    try
    {
        return (Invoke-SvnCommand -Arguments $Arguments -ErrorContext $ErrorContext)
    }
    catch
    {
        if (Test-SvnMissingTargetError -Message $_.Exception.Message)
        {
            return $null
        }
        throw
    }
}
function Get-EmptyBlameResult
{
    <#
    .SYNOPSIS
        blame 取得失敗時に返す空の集計結果を生成する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    return [pscustomobject]@{
        LineCountTotal = 0
        LineCountByRevision = @{}
        LineCountByAuthor = @{}
        Lines = @()
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
            [void]$_
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
                    [void]$_
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
                    [void]$_
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
            [void]$paths.Add([pscustomobject]@{ Path = $path
                    Action = [string]$p.action
                    CopyFromPath = $copyPath
                    CopyFromRev = $copyRev
                    IsDirectory = $isDirectory
                })
        }
        [void]$list.Add([pscustomobject]@{
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
            })
    }
    return $list.ToArray() | Sort-Object Revision
}
function ConvertTo-LineHash
{
    <#
    .SYNOPSIS
        行内容をファイル文脈付きの比較用ハッシュに変換する。
    .DESCRIPTION
        空白を正規化したうえでファイルパスと結合し、Get-Sha1Hex でハッシュ化する。
    #>
    param([string]$FilePath, [string]$Content)
    $norm = $Content -replace '\s+', ' '
    $norm = $norm.Trim()
    $raw = $FilePath + [char]0 + $norm
    return Get-Sha1Hex -Text $raw
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
    .DESCRIPTION
        先頭 K 行と末尾 K 行を結合して Get-Sha1Hex でハッシュ化する。
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
    return Get-Sha1Hex -Text $raw
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
    if ([string]::IsNullOrWhiteSpace($DiffText))
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
            [void]$current.Hunks.Add($hunkObj)
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
        # 最頻出文字を先にチェックして分岐を減らす。
        $ch = $line[0]
        if ($ch -eq '+')
        {
            if ($line.Length -ge 3 -and $line[1] -eq '+' -and $line[2] -eq '+')
            {
                continue
            }
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
        if ($ch -eq '-')
        {
            if ($line.Length -ge 3 -and $line[1] -eq '-' -and $line[2] -eq '-')
            {
                continue
            }
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
        if ($ch -eq ' ' -and $DetailLevel -ge 1 -and $null -ne $hunkContextLines)
        {
            $hunkContextLines.Add($line.Substring(1))
            continue
        }
        if ($ch -eq '\' -and $line -eq '\ No newline at end of file')
        {
            continue
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
            [void]$lineRows.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    Content = $content
                    Revision = $null
                    Author = '(unknown)'
                })
            continue
        }
        try
        {
            $rev = [int]$commit.revision
        }
        catch
        {
            [void]$_
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
        [void]$lineRows.Add([pscustomobject]@{
                LineNumber = $lineNumber
                Content = $content
                Revision = $rev
                Author = $author
            })
    }
    # blame XML の entry は line-number 昇順で出力されるため再ソート不要
    return [pscustomobject]@{
        LineCountTotal = $total
        LineCountByRevision = $byRev
        LineCountByAuthor = $byAuthor
        Lines = $lineRows.ToArray()
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
    # インメモリキャッシュにヒットすればディスク読み込み・XML パースを完全に回避する。
    # 所有権分析フェーズでは同一ファイルに複数回アクセスされるため効果が大きい。
    if ($null -eq $script:SvnBlameSummaryMemoryCache)
    {
        $script:SvnBlameSummaryMemoryCache = @{}
    }
    $cacheKey = Get-BlameMemoryCacheKey -Revision $ToRevision -FilePath $FilePath
    if ($script:SvnBlameSummaryMemoryCache.ContainsKey($cacheKey))
    {
        $script:StrictBlameCacheHits++
        return $script:SvnBlameSummaryMemoryCache[$cacheKey]
    }

    $url = $Repo.TrimEnd('/') + '/' + (ConvertTo-PathKey -Path $FilePath).TrimStart('/') + '@' + [string]$ToRevision
    $text = Read-BlameCacheFile -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath
    if ([string]::IsNullOrWhiteSpace($text))
    {
        $script:StrictBlameCacheMisses++
        $text = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', '--xml', '-r', [string]$ToRevision, $url) -ErrorContext ("svn blame $FilePath")
        if (-not [string]::IsNullOrWhiteSpace($text))
        {
            Write-BlameCacheFile -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath -Content $text
        }
    }
    else
    {
        $script:StrictBlameCacheHits++
    }
    if ([string]::IsNullOrWhiteSpace($text))
    {
        $empty = Get-EmptyBlameResult
        $script:SvnBlameSummaryMemoryCache[$cacheKey] = $empty
        return $empty
    }
    $parsed = ConvertFrom-SvnBlameXml -XmlText $text
    $script:SvnBlameSummaryMemoryCache[$cacheKey] = $parsed
    return $parsed
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
    # インメモリキャッシュにヒットすればディスク読み込み (blame XML + cat テキスト) と
    # XML パースを完全に回避する。同一コミット内で同じファイルが複数トランジションから
    # 参照されるケースで効果がある。コミット境界で Clear() されるため無制限には成長しない。
    if ($null -eq $script:SvnBlameLineMemoryCache)
    {
        $script:SvnBlameLineMemoryCache = @{}
    }
    $cacheKey = Get-BlameMemoryCacheKey -Revision $Revision -FilePath $FilePath
    if ($script:SvnBlameLineMemoryCache.ContainsKey($cacheKey))
    {
        $script:StrictBlameCacheHits++
        return $script:SvnBlameLineMemoryCache[$cacheKey]
    }

    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision

    $blameXml = Read-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ([string]::IsNullOrWhiteSpace($blameXml))
    {
        $script:StrictBlameCacheMisses++
        $blameXml = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        if (-not [string]::IsNullOrWhiteSpace($blameXml))
        {
            Write-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
        }
    }
    else
    {
        $script:StrictBlameCacheHits++
    }

    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ($null -eq $catText)
    {
        $catText = Invoke-SvnCommandAllowMissingTarget -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
        if ($null -ne $catText)
        {
            Write-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
        }
    }
    if ([string]::IsNullOrWhiteSpace($blameXml) -or $null -eq $catText)
    {
        $empty = Get-EmptyBlameResult
        $script:SvnBlameLineMemoryCache[$cacheKey] = $empty
        return $empty
    }
    $contentLines = ConvertTo-TextLine -Text $catText
    $parsed = ConvertFrom-SvnBlameXml -XmlText $blameXml -ContentLines $contentLines
    $script:SvnBlameLineMemoryCache[$cacheKey] = $parsed
    return $parsed
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
    if ([string]::IsNullOrWhiteSpace($blameXml))
    {
        $misses++
        $blameXml = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        if (-not [string]::IsNullOrWhiteSpace($blameXml))
        {
            Write-BlameCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
        }
    }
    else
    {
        $hits++
    }

    $catText = Read-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ($null -eq $catText)
    {
        $misses++
        $catText = Invoke-SvnCommandAllowMissingTarget -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
        if ($null -ne $catText)
        {
            Write-CatCacheFile -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
        }
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
            [void]$prevIdx.Add($i)
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
            [void]$currIdx.Add($j)
        }
    }

    $m = $prevIdx.Count
    $n = $currIdx.Count
    if ($m -eq 0 -or $n -eq 0)
    {
        return @()
    }

    # インデックスリストを配列化してインデクサアクセスを高速化する。
    $prevIdxArr = $prevIdx.ToArray()
    $currIdxArr = $currIdx.ToArray()

    # 未一致区間のみでDPを組み、既知一致を再計算しないため。
    # DP 値は2行ローリングで保持し、復元用に byte 型 direction テーブルを使う。
    # 空間計算量は direction テーブルにより O(mn) だが、int[,] → byte[,] で
    # メモリ使用量を約 1/4 に削減し、Sort-Object による復元も不要にしている。
    $dpPrev = New-Object 'int[]' ($n + 1)
    $dpCurr = New-Object 'int[]' ($n + 1)
    $dir = New-Object 'byte[,]' ($m + 1), ($n + 1)
    for ($i = 1
        $i -le $m
        $i++)
    {
        $leftPrev = $prevIdxArr[$i - 1]
        $prevKey = $prev[$leftPrev]
        for ($j = 1
            $j -le $n
            $j++)
        {
            $leftCurr = $currIdxArr[$j - 1]
            if ($prevKey -ceq $curr[$leftCurr])
            {
                $dpCurr[$j] = $dpPrev[$j - 1] + 1
                $dir[$i, $j] = 1 # diagonal match
            }
            else
            {
                $left = $dpCurr[$j - 1]
                $up = $dpPrev[$j]
                if ($up -ge $left)
                {
                    $dpCurr[$j] = $up
                    $dir[$i, $j] = 2 # up
                }
                else
                {
                    $dpCurr[$j] = $left
                    $dir[$i, $j] = 3 # left
                }
            }
        }
        # swap rows
        $tmp = $dpPrev
        $dpPrev = $dpCurr
        $dpCurr = $tmp
        for ($x = 0
            $x -le $n
            $x++)
        {
            $dpCurr[$x] = 0
        }
    }

    $lcsLen = $dpPrev[$n]
    if ($lcsLen -eq 0)
    {
        return @()
    }
    $pairs = New-Object 'object[]' $lcsLen
    $writePos = $lcsLen - 1
    $i = $m
    $j = $n
    # direction テーブルで逆順復元し Sort-Object を不要にする。
    while ($i -gt 0 -and $j -gt 0)
    {
        $d = $dir[$i, $j]
        if ($d -eq 1)
        {
            $pairs[$writePos] = [pscustomobject]@{
                PrevIndex = [int]$prevIdxArr[$i - 1]
                CurrIndex = [int]$currIdxArr[$j - 1]
            }
            $writePos--
            $i--
            $j--
        }
        elseif ($d -eq 2)
        {
            $i--
        }
        else
        {
            $j--
        }
    }
    return $pairs
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

    # 前後一致の prefix/suffix は LCS せずに固定し、中央差分区間だけを探索する。
    $prefix = 0
    while ($prefix -lt $m -and $prefix -lt $n -and $prevIdentity[$prefix] -ceq $currIdentity[$prefix])
    {
        $prevMatched[$prefix] = $true
        $currMatched[$prefix] = $true
        [void]$matchedPairs.Add([pscustomobject]@{
                PrevIndex = $prefix
                CurrIndex = $prefix
                PrevLine = $prev[$prefix]
                CurrLine = $curr[$prefix]
                MatchType = 'LcsIdentity'
            })
        $prefix++
    }

    $suffixPrev = $m - 1
    $suffixCurr = $n - 1
    $suffixPairs = New-Object 'System.Collections.Generic.List[object]'
    while ($suffixPrev -ge $prefix -and $suffixCurr -ge $prefix -and $prevIdentity[$suffixPrev] -ceq $currIdentity[$suffixCurr])
    {
        $prevMatched[$suffixPrev] = $true
        $currMatched[$suffixCurr] = $true
        [void]$suffixPairs.Add([pscustomobject]@{
                PrevIndex = $suffixPrev
                CurrIndex = $suffixCurr
                PrevLine = $prev[$suffixPrev]
                CurrLine = $curr[$suffixCurr]
                MatchType = 'LcsIdentity'
            })
        $suffixPrev--
        $suffixCurr--
    }
    for ($suffixIdx = $suffixPairs.Count - 1
        $suffixIdx -ge 0
        $suffixIdx--)
    {
        [void]$matchedPairs.Add($suffixPairs[$suffixIdx])
    }

    # まず identity LCS で帰属が同じ行を優先一致させる。
    foreach ($pair in @(Get-LcsMatchedPair -PreviousKeys $prevIdentity -CurrentKeys $currIdentity -PreviousLocked $prevMatched -CurrentLocked $currMatched))
    {
        $prevIdx = [int]$pair.PrevIndex
        $currIdx = [int]$pair.CurrIndex
        $prevMatched[$prevIdx] = $true
        $currMatched[$currIdx] = $true
        [void]$matchedPairs.Add([pscustomobject]@{
                PrevIndex = $prevIdx
                CurrIndex = $currIdx
                PrevLine = $prev[$prevIdx]
                CurrLine = $curr[$currIdx]
                MatchType = 'LcsIdentity'
            })
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
        $key = $prevIdentity[$pi]
        if (-not $unmatchedPrevByKey.ContainsKey($key))
        {
            $unmatchedPrevByKey[$key] = New-Object 'System.Collections.Generic.List[int]'
        }
        [void]$unmatchedPrevByKey[$key].Add($pi)
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
        $key = $currIdentity[$ci]
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
        [void]$matchedPairs.Add($pair)
        [void]$movedPairs.Add($pair)
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
        [void]$matchedPairs.Add([pscustomobject]@{
                PrevIndex = $prevIdx
                CurrIndex = $currIdx
                PrevLine = $prev[$prevIdx]
                CurrLine = $curr[$currIdx]
                MatchType = 'LcsContent'
            })
    }

    # 最後に未一致残余を born/dead として確定する。
    $killed = New-Object 'System.Collections.Generic.List[object]'
    for ($pi = 0
        $pi -lt $m
        $pi++)
    {
        if (-not $prevMatched[$pi])
        {
            [void]$killed.Add([pscustomobject]@{
                    Index = $pi
                    Line = $prev[$pi]
                })
        }
    }
    $born = New-Object 'System.Collections.Generic.List[object]'
    for ($ci = 0
        $ci -lt $n
        $ci++)
    {
        if (-not $currMatched[$ci])
        {
            [void]$born.Add([pscustomobject]@{
                    Index = $ci
                    Line = $curr[$ci]
                })
        }
    }

    $reattributed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in @($matchedPairs.ToArray()))
    {
        $prevLine = $pair.PrevLine
        $currLine = $pair.CurrLine
        if ([string]$prevLine.Content -ceq [string]$currLine.Content -and (([string]$prevLine.Revision -ne [string]$currLine.Revision) -or ((Get-NormalizedAuthorName -Author ([string]$prevLine.Author)) -ne (Get-NormalizedAuthorName -Author ([string]$currLine.Author)))))
        {
            [void]$reattributed.Add($pair)
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
        [void]$pathMap[$path].Add($p)
        if (([string]$p.Action).ToUpperInvariant() -eq 'D')
        {
            [void]$deleted.Add($path)
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
            [void]$consumedOld.Add($oldPath)
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
            [void]$result.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $newPath
                })
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
            [void]$result.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $null
                })
        }
    }

    $candidates = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in @($Commit.FilesChanged))
    {
        [void]$candidates.Add((ConvertTo-PathKey -Path ([string]$f)))
    }
    foreach ($path in $pathMap.Keys)
    {
        [void]$candidates.Add($path)
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
            [void]$result.Add([pscustomobject]@{
                    BeforePath = $beforePath
                    AfterPath = $afterPath
                })
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
                    [void]$hunks.Add($hx)
                }
            }
            else
            {
                [void]$hunks.Add($hunksRaw)
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
                [void]$eventsByFile[$resolved].Add([pscustomobject]@{
                        Revision = $rev
                        Author = $author
                        Start = $start
                        End = $end
                    })

                $shift = $newCount - $oldCount
                if ($shift -ne 0)
                {
                    $threshold = $oldStart + $oldCount
                    if ($oldCount -eq 0)
                    {
                        $threshold = $oldStart
                    }
                    [void]$pending.Add([pscustomobject]@{
                            Threshold = $threshold
                            Delta = $shift
                        })
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
        $evtCount = $events.Count
        # 属性を配列にバラしてプロパティアクセスを減らす。
        $evtAuthor = New-Object 'string[]' $evtCount
        $evtStart = New-Object 'int[]' $evtCount
        $evtEnd = New-Object 'int[]' $evtCount
        for ($x = 0
            $x -lt $evtCount
            $x++)
        {
            $evtAuthor[$x] = [string]$events[$x].Author
            $evtStart[$x] = [int]$events[$x].Start
            $evtEnd[$x] = [int]$events[$x].End
        }
        # 同一作者の重なりを数え、反復編集の密度を可視化するため。
        for ($i = 0
            $i -lt $evtCount
            $i++)
        {
            $a1 = $evtAuthor[$i]
            $s1 = $evtStart[$i]
            $e1 = $evtEnd[$i]
            for ($j = $i + 1
                $j -lt $evtCount
                $j++)
            {
                if ($a1 -ne $evtAuthor[$j])
                {
                    continue
                }
                # 範囲重複判定: [s1,e1] ∩ [sj,ej] ≠ ∅ ⇔ s1≤ej ∧ sj≤e1
                if ($s1 -le $evtEnd[$j] -and $evtStart[$j] -le $e1)
                {
                    Add-Count -Table $authorRepeated -Key $a1
                    Add-Count -Table $fileRepeated -Key $file
                }
            }
        }
        # A→B→A の往復を重なり範囲で絞り、偶然一致を減らすため。
        for ($i = 0
            $i -lt ($evtCount - 2)
            $i++)
        {
            $a1 = $evtAuthor[$i]
            $s1 = $evtStart[$i]
            $e1 = $evtEnd[$i]
            for ($j = $i + 1
                $j -lt ($evtCount - 1)
                $j++)
            {
                if ($a1 -eq $evtAuthor[$j])
                {
                    continue
                }
                $sj = $evtStart[$j]
                $ej = $evtEnd[$j]
                # 2者重複判定: [s1,e1] ∩ [sj,ej] = ∅ ⇔ s1>ej ∨ sj>e1
                if ($s1 -gt $ej -or $sj -gt $e1)
                {
                    continue
                }
                # i-j の重複区間 [abMax, abMin] を求め、k との3者重複を判定する
                $abMax = if ($s1 -gt $sj)
                {
                    $s1
                }
                else
                {
                    $sj
                }
                $abMin = if ($e1 -lt $ej)
                {
                    $e1
                }
                else
                {
                    $ej
                }
                for ($k = $j + 1
                    $k -lt $evtCount
                    $k++)
                {
                    if ($evtAuthor[$k] -ne $a1)
                    {
                        continue
                    }
                    # 3者重複判定: [abMax,abMin] ∩ [sk,ek] ≠ ∅
                    if ($abMax -le $evtEnd[$k] -and $evtStart[$k] -le $abMin)
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
                    $hasBlameCache = Test-BlameCacheFileExistence -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath
                    $hasCatCache = Test-CatCacheFileExistence -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath
                    if ((-not $hasBlameCache) -or (-not $hasCatCache))
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
                    $hasBlameCache = Test-BlameCacheFileExistence -CacheDir $CacheDir -Revision $rev -FilePath $afterPath
                    $hasCatCache = Test-CatCacheFileExistence -CacheDir $CacheDir -Revision $rev -FilePath $afterPath
                    if ((-not $hasBlameCache) -or (-not $hasCatCache))
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
        $prefetchTotal = $items.Count
        $prefetchIdx = 0
        foreach ($item in $items)
        {
            $pct = [Math]::Min(100, [int](($prefetchIdx / [Math]::Max(1, $prefetchTotal)) * 100))
            Write-Progress -Id 4 -Activity 'blame キャッシュ構築' -Status ('{0}/{1}' -f ($prefetchIdx + 1), $prefetchTotal) -PercentComplete $pct
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
            $prefetchIdx++
        }
        Write-Progress -Id 4 -Activity 'blame キャッシュ構築' -Completed
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
        [void]$Index # Required by Invoke-ParallelWork contract
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
            'Test-SvnMissingTargetError',
            'Invoke-SvnCommandAllowMissingTarget',
            'Get-EmptyBlameResult',
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
    $killMatrix = @{}

    $prefetchTargets = @(Get-StrictBlamePrefetchTarget -Commits $Commits -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir)
    Invoke-StrictBlameCachePrefetch -Targets $prefetchTargets -TargetUrl $TargetUrl -CacheDir $CacheDir -Parallel $Parallel

    $sortedCommits = @($Commits | Sort-Object Revision)
    $deathTotal = $sortedCommits.Count
    $deathIdx = 0
    foreach ($c in $sortedCommits)
    {
        $pct = [Math]::Min(100, [int](($deathIdx / [Math]::Max(1, $deathTotal)) * 100))
        Write-Progress -Id 3 -Activity '行単位の帰属解析' -Status ('r{0} ({1}/{2})' -f [int]$c.Revision, ($deathIdx + 1), $deathTotal) -PercentComplete $pct
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

                # --- Fast Path 分岐 ---
                # diff 統計 (追加行数・削除行数) を事前に取得し、blame 比較の必要性を判定する。
                # 典型的なコミットではファイルの大半が add-only や zero-change であり、
                # 高コストな LCS (O(mn)) を回避できるケースが多い。
                $transitionAdded = 0
                $transitionDeleted = 0
                $transitionStat = $null
                if ($afterPath -and $c.FileDiffStats.ContainsKey($afterPath))
                {
                    $transitionStat = $c.FileDiffStats[$afterPath]
                }
                elseif ($beforePath -and $c.FileDiffStats.ContainsKey($beforePath))
                {
                    $transitionStat = $c.FileDiffStats[$beforePath]
                }
                if ($null -ne $transitionStat)
                {
                    $transitionAdded = [int]$transitionStat.AddedLines
                    $transitionDeleted = [int]$transitionStat.DeletedLines
                }
                $hasTransitionStat = ($null -ne $transitionStat)

                # Fast Path 1: zero-change — プロパティ変更のみ等。blame 取得自体を省略する。
                if ($hasTransitionStat -and $transitionAdded -eq 0 -and $transitionDeleted -eq 0)
                {
                    continue
                }

                $cmp = $null
                # Fast Path 2: add-only — 削除行なし。前リビジョンの blame 取得と LCS を省略し、
                # 現リビジョンの blame から当該リビジョンで born された行だけを抽出する。
                if ($hasTransitionStat -and $transitionAdded -gt 0 -and $transitionDeleted -eq 0 -and $afterPath)
                {
                    $currBlame = Get-SvnBlameLine -Repo $TargetUrl -FilePath $afterPath -Revision $rev -CacheDir $CacheDir
                    $currLines = @($currBlame.Lines)
                    $bornOnly = New-Object 'System.Collections.Generic.List[object]'
                    for ($currIdx = 0
                        $currIdx -lt $currLines.Count
                        $currIdx++)
                    {
                        $line = $currLines[$currIdx]
                        $lineRevision = $null
                        try
                        {
                            $lineRevision = [int]$line.Revision
                        }
                        catch
                        {
                            $lineRevision = $null
                        }
                        if ($lineRevision -eq $rev)
                        {
                            [void]$bornOnly.Add([pscustomobject]@{
                                    Index = $currIdx
                                    Line = $line
                                })
                        }
                    }
                    $cmp = [pscustomobject]@{
                        KilledLines = @()
                        BornLines = @($bornOnly.ToArray())
                        MatchedPairs = @()
                        MovedPairs = @()
                        ReattributedPairs = @()
                    }
                }
                # Fast Path 3: delete-file — ファイル削除。現リビジョンの blame 取得と LCS を省略し、
                # 前リビジョンの全行を killed として扱う。afterPath が null であることが条件。
                elseif ($hasTransitionStat -and $transitionDeleted -gt 0 -and $transitionAdded -eq 0 -and $beforePath -and (-not $afterPath))
                {
                    $prevBlame = Get-SvnBlameLine -Repo $TargetUrl -FilePath $beforePath -Revision ($rev - 1) -CacheDir $CacheDir
                    $prevLines = @($prevBlame.Lines)
                    $killedOnly = New-Object 'System.Collections.Generic.List[object]'
                    for ($prevIdx = 0
                        $prevIdx -lt $prevLines.Count
                        $prevIdx++)
                    {
                        [void]$killedOnly.Add([pscustomobject]@{
                                Index = $prevIdx
                                Line = $prevLines[$prevIdx]
                            })
                    }
                    $cmp = [pscustomobject]@{
                        KilledLines = @($killedOnly.ToArray())
                        BornLines = @()
                        MatchedPairs = @()
                        MovedPairs = @()
                        ReattributedPairs = @()
                    }
                }
                else
                {
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
                }

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
                        [void]$revsWhereKilledOthers.Add(([string]$rev + [char]31 + $killer))
                        if (-not $killMatrix.ContainsKey($killer))
                        {
                            $killMatrix[$killer] = @{}
                        }
                        Add-Count -Table $killMatrix[$killer] -Key $bornAuthor
                    }
                }
            }
            catch
            {
                throw ("Strict blame attribution failed at r{0} (before='{1}', after='{2}'): {3}" -f $rev, [string]$t.BeforePath, [string]$t.AfterPath, $_.Exception.Message)
            }
        }
        $deathIdx++
        # コミット間でキャッシュキーの再利用はないため、コミット境界で安全にクリア可能。
        # これによりメモリ使用量を O(N×K×L) から O(K×L) に削減する。
        $script:SvnBlameLineMemoryCache.Clear()
    }
    Write-Progress -Id 3 -Activity '行単位の帰属解析' -Completed

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
        KillMatrix = $killMatrix
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
    param([object[]]$Commits, [hashtable]$RenameMap = @{})
    $states = @{}
    $fileAuthors = @{}
    foreach ($c in $Commits)
    {
        $a = [string]$c.Author
        foreach ($f in @($c.FilesChanged))
        {
            $resolvedF = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
            if (-not $fileAuthors.ContainsKey($resolvedF))
            {
                $fileAuthors[$resolvedF] = New-Object 'System.Collections.Generic.HashSet[string]'
            }
            [void]$fileAuthors[$resolvedF].Add($a)
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
            [void]$s.ActiveDays.Add(([datetime]$c.Date).ToString('yyyy-MM-dd'))
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
            $resolvedF = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
            [void]$s.Files.Add($resolvedF)
            $idx = $resolvedF.LastIndexOf('/')
            $dir = if ($idx -lt 0)
            {
                '.'
            }
            else
            {
                $resolvedF.Substring(0, $idx)
            }
            if ($dir)
            {
                [void]$s.Dirs.Add($dir)
            }
            $d = $c.FileDiffStats[$f]
            $ch = [int]$d.AddedLines + [int]$d.DeletedLines
            if (-not $s.FileChurn.ContainsKey($resolvedF))
            {
                $s.FileChurn[$resolvedF] = 0
            }
            $s.FileChurn[$resolvedF] += $ch
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
        [void]$rows.Add([pscustomobject][ordered]@{
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
                'リワーク率' = if ($ch -gt 0)
                {
                    Format-MetricValue -Value (1 - [Math]::Abs($net) / [double]$ch)
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
            })
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
    [CmdletBinding()]param([object[]]$Commits, [hashtable]$RenameMap = @{})
    $states = @{}
    foreach ($c in $Commits)
    {
        $author = [string]$c.Author
        $files = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in @($c.FilesChanged))
        {
            $resolved = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
            [void]$files.Add($resolved)
        }
        foreach ($p in @($c.ChangedPathsFiltered))
        {
            $resolved = Resolve-PathByRenameMap -FilePath ([string]$p.Path) -RenameMap $RenameMap
            [void]$files.Add($resolved)
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
                [void]$s.Dates.Add([datetime]$c.Date)
            }
            [void]$s.Authors.Add($author)
        }
        foreach ($f in @($c.FilesChanged))
        {
            $resolvedF = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
            $s = $states[$resolvedF]
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
            $resolvedP = Resolve-PathByRenameMap -FilePath ([string]$p.Path) -RenameMap $RenameMap
            $s = $states[$resolvedP]
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
        $spanDays = 0.0
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
            $spanDays = (New-TimeSpan -Start $dates[0] -End $dates[-1]).TotalDays
        }
        $topShare = 0.0
        if ($ch -gt 0 -and $s.AuthorChurn.Count -gt 0)
        {
            $mx = ($s.AuthorChurn.Values | Measure-Object -Maximum).Maximum
            $topShare = $mx / [double]$ch
        }
        $authorCount = [int]$s.Authors.Count
        $frequency = [double]$cc / [Math]::Max($spanDays, 1.0)
        $hotspotScore = [double]$cc * [double]$authorCount * [double]$ch * $frequency
        [void]$rows.Add([pscustomobject][ordered]@{
                'ファイルパス' = [string]$s.FilePath
                'コミット数' = $cc
                '作者数' = $authorCount
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
                '活動期間日数' = Format-MetricValue -Value $spanDays
                '生存行数 (範囲指定)' = $null
                $script:ColDeadAdded = $null
                '最多作者チャーン占有率' = Format-MetricValue -Value $topShare
                '最多作者blame占有率' = $null
                '自己相殺行数 (合計)' = $null
                '他者差戻行数 (合計)' = $null
                '同一箇所反復編集数 (合計)' = $null
                'ピンポン回数 (合計)' = $null
                '内部移動行数 (合計)' = $null
                'ホットスポットスコア' = Format-MetricValue -Value $hotspotScore
                'ホットスポット順位' = 0
            })
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
    .PARAMETER Commits
        集計対象のコミット配列を指定する。
    .PARAMETER TopNCount
        戻り値の上限件数。0 以下を指定すると全件を返す。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Commits, [int]$TopNCount = 50, [hashtable]$RenameMap = @{})
    $pair = @{}
    $fileCount = @{}
    $commitTotal = 0
    foreach ($c in $Commits)
    {
        $files = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in @($c.FilesChanged))
        {
            $resolved = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
            [void]$files.Add($resolved)
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
        [void]$rows.Add([pscustomobject][ordered]@{ 'ファイルA' = $a
                'ファイルB' = $b
                '共変更回数' = $co
                'Jaccard' = Format-MetricValue -Value $j
                'リフト値' = Format-MetricValue -Value $lift
            })
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
    [void]$sb1.AppendLine('+ 作者 | コミット数 | 活動日数 | 総チャーン | 所有割合 | 他者コード変更行数 | 他者変更生存率 | 変更エントロピー | 平均共同作者数')
    foreach ($r in $topCommitters)
    {
        $escAuthor = ([string]$r.'作者').Replace('|', '\|')
        $commitCount = if ($null -ne $r.'コミット数')
        {
            $r.'コミット数'
        }
        else
        {
            ''
        }
        $activeDays = if ($null -ne $r.'活動日数')
        {
            $r.'活動日数'
        }
        else
        {
            ''
        }
        $totalChurn = if ($null -ne $r.'総チャーン')
        {
            $r.'総チャーン'
        }
        else
        {
            ''
        }
        $ownerShare = if ($null -ne $r.'所有割合')
        {
            '{0:P1}' -f [double]$r.'所有割合'
        }
        else
        {
            '-'
        }
        $modOthers = if ($null -ne $r.'他者コード変更行数')
        {
            $r.'他者コード変更行数'
        }
        else
        {
            '-'
        }
        $modOthersSurv = if ($null -ne $r.'他者コード変更生存率')
        {
            '{0:P1}' -f [double]$r.'他者コード変更生存率'
        }
        else
        {
            '-'
        }
        $entropy = if ($null -ne $r.'変更エントロピー')
        {
            '{0:F2}' -f [double]$r.'変更エントロピー'
        }
        else
        {
            '-'
        }
        $avgCoAuth = if ($null -ne $r.'平均共同作者数')
        {
            '{0:F1}' -f [double]$r.'平均共同作者数'
        }
        else
        {
            '-'
        }
        [void]$sb1.AppendLine(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8}" -f $escAuthor, $commitCount, $activeDays, $totalChurn, $ownerShare, $modOthers, $modOthersSurv, $entropy, $avgCoAuth))
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
        ファイルホットスポット分析をバブルチャート SVG として出力する。
    .DESCRIPTION
        TopN のファイルをホットスポット順位順で選び、ホットスポットスコアと最多作者blame占有率を軸に配置する。
        バブル面積は総チャーンに比例させ、色はホットスポット順位を赤から緑で表現する。
        X軸: ホットスポットスコア、Y軸: 最多作者blame占有率、バブルサイズ: 総チャーン、色: ホットスポット順位
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
                $null -ne $_ -and $null -ne $_.'最多作者blame占有率'
            } |
            Sort-Object -Property 'ホットスポット順位', 'ファイルパス'
    )
    if ($topFiles.Count -eq 0)
    {
        Write-Verbose 'Write-FileBubbleChart: blame占有率を持つファイルがありません。SVG を生成しません。'
        return
    }
    if ($TopNCount -gt 0)
    {
        $topFiles = @($topFiles | Select-Object -First $TopNCount)
    }

    $svgWidth = 640.0
    $svgHeight = 592.0
    $plotLeft = 80.0
    $plotTop = 72.0
    $plotWidth = 480.0
    $plotHeight = 440.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $tickCount = 6

    $maxScore = 0.0
    $maxBlameShare = 0.0
    $maxChurn = 0.0
    $maxRank = 1
    foreach ($f in $topFiles)
    {
        $scoreCount = [double]$f.'ホットスポットスコア'
        $blameShare = [double]$f.'最多作者blame占有率'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'
        if ($scoreCount -gt $maxScore)
        {
            $maxScore = $scoreCount
        }
        if ($blameShare -gt $maxBlameShare)
        {
            $maxBlameShare = $blameShare
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
    if ($maxScore -le 0.0)
    {
        $maxScore = 1.0
    }
    if ($maxBlameShare -le 0.0)
    {
        $maxBlameShare = 1.0
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

    # XML 宣言の encoding を、実際の書き込みエンコーディングと一致させる
    $xmlEncoding = if ($null -ne $EncodingName -and $EncodingName -ne '')
    {
        $EncodingName
    }
    else
    {
        'UTF-8'
    }

    # SVG 構築開始
    $sb = New-Object System.Text.StringBuilder

    # XML 宣言と SVG ルート要素
    [void]$sb.AppendLine(('<?xml version="1.0" encoding="{0}"?>' -f $xmlEncoding))
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f [int]$svgWidth, [int]$svgHeight))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .file-label { font-size: 9px; fill: #333; text-anchor: middle; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">ファイルホットスポット分析</text>')
    [void]$sb.AppendLine(('<text class="subtitle" x="20" y="44">X: ホットスポットスコア（コミット数{0}×作者数×総チャーン÷max(活動期間日数,1)） / Y: 最多作者blame占有率（max(作者別生存行数)÷生存行数合計）</text>' -f [char]0x00B2))
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="58">円: 総チャーン / 色: ホットスポット順位（＝スコア降順）</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))

    # X軸グリッド線とラベル（ホットスポットスコア）
    for ($i = 0
        $i -le $tickCount
        $i++)
    {
        $xValue = ($maxScore * $i) / [double]$tickCount
        $x = $plotLeft + (($plotWidth * $i) / [double]$tickCount)
        $xRounded = [Math]::Round($x, 2)
        $xLabel = [int][Math]::Round($xValue)
        [void]$sb.AppendLine(('<line class="grid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f $xRounded, [int]$plotTop, [int]$plotBottom))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1}" text-anchor="middle">{2}</text>' -f $xRounded, [int]($plotBottom + 16), $xLabel))
    }
    # Y軸グリッド線とラベル（最多作者blame占有率）
    for ($i = 0
        $i -le $tickCount
        $i++)
    {
        $yValue = ($maxBlameShare * $i) / [double]$tickCount
        $y = $plotBottom - (($plotHeight * $i) / [double]$tickCount)
        $yRounded = [Math]::Round($y, 2)
        $yLabel = [Math]::Round($yValue * 100.0, 0)
        [void]$sb.AppendLine(('<line class="grid-line" x1="{0}" y1="{2}" x2="{1}" y2="{2}"/>' -f [int]$plotLeft, [int]$plotRight, $yRounded))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1}" text-anchor="end">{2}%</text>' -f [int]($plotLeft - 6), ($yRounded + 4.0), [int]$yLabel))
    }

    # 軸線
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$plotBottom, [int]$plotRight))
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotBottom))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">ホットスポットスコア</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">最多作者blame占有率</text>' -f [int]($plotTop + $plotHeight / 2.0)))

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
        $scoreCount = [double]$f.'ホットスポットスコア'
        $blameShare = [double]$f.'最多作者blame占有率'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'

        $radius = & $radiusCalculator -ChurnValue $churnCount
        $x = $plotLeft + (($scoreCount / $maxScore) * $plotWidth)
        $y = $plotBottom - (($blameShare / $maxBlameShare) * $plotHeight)
        $x = [Math]::Min($plotRight - $radius - 1.0, [Math]::Max($plotLeft + $radius + 1.0, $x))
        $y = [Math]::Min($plotBottom - $radius - 1.0, [Math]::Max($plotTop + $radius + 1.0, $y))
        $bubbleColor = ConvertTo-SvgColor -Rank $rank -MaxRank $maxRank
        $label = Split-Path -Path $filePath -Leaf
        if ([string]::IsNullOrWhiteSpace($label))
        {
            $label = $filePath
        }
        $safePath = ConvertTo-SvgEscapedText -Text $filePath
        if ([string]::IsNullOrWhiteSpace($safePath))
        {
            $safePath = ''
        }
        $blamePct = [Math]::Round($blameShare * 100.0, 1)
        $tooltip = ('{0}&#10;スコア={1}, blame占有率={2}%, 総チャーン={3}, 順位={4}' -f $safePath, [Math]::Round($scoreCount, 2), $blamePct, [int][Math]::Round($churnCount), $rank)

        $xRounded = [Math]::Round($x, 2)
        $yRounded = [Math]::Round($y, 2)
        $radiusRounded = [Math]::Round($radius, 2)
        [void]$sb.AppendLine(('<circle cx="{0}" cy="{1}" r="{2}" fill="{3}" fill-opacity="0.65" stroke="#333" stroke-width="0.8"><title>{4}</title></circle>' -f $xRounded, $yRounded, $radiusRounded, $bubbleColor, $tooltip))

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
            if ([string]::IsNullOrWhiteSpace($safeLabel))
            {
                $safeLabel = ''
            }
            [void]$sb.AppendLine(('<text class="file-label" x="{0}" y="{1}" text-anchor="{2}">{3}</text>' -f $labelX, $labelY, $labelAnchor, $safeLabel))
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'file_hotspot.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Write-FileQualityScatterChart
{
    <#
    .SYNOPSIS
        ファイル品質の散布図 SVG を出力する。
    .DESCRIPTION
        X 軸にコード消滅率（消滅追加行数÷追加行数）、Y 軸に無駄チャーン率
        （(自己相殺+他者差戻+ピンポン)÷総チャーン）を取り、バブルサイズに総チャーンを
        反映した散布図を生成する。色はホットスポット順位のグラデーション。
        4 象限の解釈:
        - 左上: 過剰修正型（追加コードは残るが、修正の手戻りが多い）
        - 右上: 高リスク（追加しても消え、修正も無駄が多い）
        - 左下: 安定型（追加が定着し、手戻りも少ない）
        - 右下: 自然淘汰型（追加コードは消えるが、修正の無駄は少ない）
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Files
        Get-FileMetric が返すファイル行配列を指定する。
    .PARAMETER TopNCount
        可視化対象とする上位件数を指定する（0以下の場合は全件）。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-FileQualityScatterChart -OutDirectory '.\output' -Files $fileRows -TopNCount 50 -EncodingName 'UTF8'
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
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-FileQualityScatterChart: OutDirectory が空です。'
        return
    }
    if (-not $Files -or @($Files).Count -eq 0)
    {
        Write-Verbose 'Write-FileQualityScatterChart: Files が空です。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-FileQualityScatterChart'))
    {
        return
    }

    $topFiles = @(
        $Files |
            Where-Object { $null -ne $_ } |
            Sort-Object -Property 'ホットスポット順位', 'ファイルパス'
    )
    if ($TopNCount -gt 0)
    {
        $topFiles = @($topFiles | Select-Object -First $TopNCount)
    }

    # 散布データの構築
    $scatterData = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $topFiles)
    {
        $addedLines = 0.0
        $prop = $f.PSObject.Properties['追加行数']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $addedLines = [double]$prop.Value
        }
        if ($addedLines -le 0)
        {
            continue
        }
        $deadAdded = 0.0
        $prop = $f.PSObject.Properties[$script:ColDeadAdded]
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $deadAdded = [double]$prop.Value
        }
        $totalChurn = 0.0
        $prop = $f.PSObject.Properties['総チャーン']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $totalChurn = [double]$prop.Value
        }
        if ($totalChurn -le 0)
        {
            continue
        }
        $selfCancel = 0.0
        $prop = $f.PSObject.Properties['自己相殺行数 (合計)']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $selfCancel = [double]$prop.Value
        }
        $otherRevert = 0.0
        $prop = $f.PSObject.Properties['他者差戻行数 (合計)']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $otherRevert = [double]$prop.Value
        }
        $pingPong = 0.0
        $prop = $f.PSObject.Properties['ピンポン回数 (合計)']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $pingPong = [double]$prop.Value
        }

        $rawDeadRate = $deadAdded / $addedLines
        if ($rawDeadRate -gt 1.0)
        {
            Write-Warning ("消滅率が1.0を超過: {0} (dead={1}, added={2})" -f [string]$f.'ファイルパス', $deadAdded, $addedLines)
        }
        $deadRate = [Math]::Min(1.0, $rawDeadRate)
        $rawWasteChurn = ($selfCancel + $otherRevert + $pingPong) / $totalChurn
        if ($rawWasteChurn -gt 1.0)
        {
            Write-Warning ("無駄チャーン率が1.0を超過: {0}" -f [string]$f.'ファイルパス')
        }
        $wasteChurn = [Math]::Min(1.0, $rawWasteChurn)

        $rank = 1
        $prop = $f.PSObject.Properties['ホットスポット順位']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $rank = [int]$prop.Value
        }

        [void]$scatterData.Add([pscustomobject]@{
                FilePath = [string]$f.'ファイルパス'
                DeadRate = $deadRate
                WasteChurnRate = $wasteChurn
                TotalChurn = $totalChurn
                Rank = $rank
            })
    }
    if ($scatterData.Count -eq 0)
    {
        return
    }

    # 描画定数
    $plotLeft = 80.0
    $plotTop = 72.0
    $plotWidth = 400.0
    $plotHeight = 400.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $midX = $plotLeft + $plotWidth / 2.0
    $midY = $plotTop + $plotHeight / 2.0

    $maxChurn = ($scatterData | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $maxRank = ($scatterData | Measure-Object -Property Rank -Maximum).Maximum
    if ($maxRank -le 0)
    {
        $maxRank = 1
    }
    $minBubble = 8.0
    $maxBubble = 36.0

    $quadrants = @(
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.2; Label = '⚠️ 過剰修正型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.2; Label = '🔥 高リスク' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.8; Label = '✅ 安定型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.8; Label = '🍂 自然淘汰型' }
    )

    $svgW = 640
    $svgH = 592
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .quadrant-label { font-size: 13px; fill: #aaa; text-anchor: middle; }
  .file-label { font-size: 9px; fill: #333; text-anchor: middle; }
  .mid-line { stroke: #bdbdbd; stroke-width: 1; stroke-dasharray: 6,4; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">ファイル手戻り分析</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="44">X: コード消滅率（消滅追加行数÷追加行数） / Y: 無駄チャーン率（(自己相殺+他者差戻+ピンポン)÷総チャーン）</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="58">円: 総チャーン / 色: ホットスポット順位（コミット数²×作者数×総チャーン÷max(活動期間日数,1)）</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">コード消滅率</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">無駄チャーン率</text>' -f [int]($plotTop + $plotHeight / 2.0)))
    # 目盛り
    for ($tick = 0.0; $tick -le 1.01; $tick += 0.25)
    {
        $tx = $plotLeft + $tick * $plotWidth
        $ty = $plotBottom - $tick * $plotHeight
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
    }
    # 象限ラベル
    foreach ($q in $quadrants)
    {
        [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Label)))
    }
    # バブル描画（大きい順に描画して小さい方が前面に来る）
    $sortedByChurn = @($scatterData | Sort-Object -Property TotalChurn -Descending)
    for ($ci = 0; $ci -lt $sortedByChurn.Count; $ci++)
    {
        $d = $sortedByChurn[$ci]
        $bx = $plotLeft + $d.DeadRate * $plotWidth
        $by = $plotBottom - $d.WasteChurnRate * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.TotalChurn / $maxChurn)
        $bColor = ConvertTo-SvgColor -Rank $d.Rank -MaxRank $maxRank
        $fileLabel = Split-Path -Path $d.FilePath -Leaf
        if ([string]::IsNullOrWhiteSpace($fileLabel))
        {
            $fileLabel = $d.FilePath
        }
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.65" stroke="#333" stroke-width="0.8"><title>{4} (消滅率:{5:F1}%, 無駄率:{6:F1}%, チャーン:{7})</title></circle>' -f $bx, $by, $br, $bColor, (ConvertTo-SvgEscapedText -Text $d.FilePath), ($d.DeadRate * 100), ($d.WasteChurnRate * 100), [int]$d.TotalChurn))
        [void]$sb.AppendLine(('<text class="file-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f $bx, ($by - $br - 3.0), (ConvertTo-SvgEscapedText -Text $fileLabel)))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'file_quality_scatter.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Write-CommitTimelineChart
{
    <#
    .SYNOPSIS
        コミットタイムラインの棒グラフ SVG を出力する。
    .DESCRIPTION
        X 軸に日時、Y 軸にチャーン量を取り、各コミットを棒グラフで描画する。
        棒の色は作者別に割り当て、凡例を右側に表示する。
        時系列でのコミット活動パターンを一目で把握できる。
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Commits
        commits.csv 相当のコミット行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitTimelineChart -OutDirectory '.\output' -Commits $commitRows -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Commits,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-CommitTimelineChart: OutDirectory が空です。'
        return
    }
    if (-not $Commits -or @($Commits).Count -eq 0)
    {
        Write-Verbose 'Write-CommitTimelineChart: Commits が空です。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-CommitTimelineChart'))
    {
        return
    }

    # コミットデータの解析
    $commitData = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Commits))
    {
        if ($null -eq $c)
        {
            continue
        }
        $dateStr = ''
        $prop = $c.PSObject.Properties['日時']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $dateStr = [string]$prop.Value
        }
        $parsedDate = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($dateStr))
        {
            if (-not [datetime]::TryParse($dateStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate))
            {
                [void][datetime]::TryParse($dateStr, [ref]$parsedDate)
            }
        }
        if ($parsedDate -eq [datetime]::MinValue)
        {
            continue
        }
        $churn = 0.0
        $prop = $c.PSObject.Properties['チャーン']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $churn = [double]$prop.Value
        }
        $author = ''
        $prop = $c.PSObject.Properties['作者']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $author = [string]$prop.Value
        }
        $rev = ''
        $prop = $c.PSObject.Properties['リビジョン']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $rev = [string]$prop.Value
        }
        [void]$commitData.Add([pscustomobject]@{
                DateTime = $parsedDate
                Churn = $churn
                Author = $author
                Revision = $rev
            })
    }
    if ($commitData.Count -eq 0)
    {
        return
    }
    $sorted = @($commitData | Sort-Object -Property DateTime)

    # 作者→色マッピング
    $colorPalette = $script:DefaultColorPalette
    $authorColors = @{}
    $authorIndex = 0
    foreach ($d in $sorted)
    {
        if (-not $authorColors.ContainsKey($d.Author))
        {
            $authorColors[$d.Author] = $colorPalette[$authorIndex % $colorPalette.Count]
            $authorIndex++
        }
    }

    # 描画定数
    $plotLeft = 100.0
    $plotTop = 60.0
    $plotWidth = 560.0
    $plotHeight = 340.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $legendX = $plotRight + 20.0

    $minDate = $sorted[0].DateTime
    $maxDate = $sorted[$sorted.Count - 1].DateTime
    $dateRange = ($maxDate - $minDate).TotalSeconds
    if ($dateRange -le 0)
    {
        $dateRange = 1.0
    }
    $maxChurn = ($sorted | Measure-Object -Property Churn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }

    $barWidth = [Math]::Max(2.0, [Math]::Min(16.0, $plotWidth / [Math]::Max(1, $sorted.Count) * 0.8))

    $svgW = [int]($legendX + 160)
    $svgH = [int]($plotBottom + 80)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .legend-text { font-size: 11px; fill: #333; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">コミットタイムライン</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: 日時 / Y: チャーン（追加行数+削除行数） / 色: 作者</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))

    # Y軸グリッド＆目盛り
    $yTickCount = 5
    for ($i = 0; $i -le $yTickCount; $i++)
    {
        $yValue = ($maxChurn * $i) / [double]$yTickCount
        $yPos = $plotBottom - (($plotHeight * $i) / [double]$yTickCount)
        [void]$sb.AppendLine(('<line class="grid-line" x1="{0}" y1="{1:F0}" x2="{2}" y2="{1:F0}"/>' -f [int]$plotLeft, $yPos, [int]$plotRight))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2}</text>' -f [int]($plotLeft - 8), ($yPos + 4), [int][Math]::Round($yValue)))
    }

    # X軸の日付目盛り（最大6個）
    $xTickCount = [Math]::Min(6, $sorted.Count)
    for ($i = 0; $i -lt $xTickCount; $i++)
    {
        $tickIndex = [int][Math]::Round(($sorted.Count - 1) * $i / [Math]::Max(1, $xTickCount - 1))
        $tickDate = $sorted[$tickIndex].DateTime
        $tickSeconds = ($tickDate - $minDate).TotalSeconds
        $tx = $plotLeft + ($tickSeconds / $dateRange) * $plotWidth
        $dateLabel = $tickDate.ToString('yyyy/MM/dd')
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle" transform="rotate(-30,{0:F0},{1})">{2}</text>' -f $tx, [int]($plotBottom + 18), (ConvertTo-SvgEscapedText -Text $dateLabel)))
    }

    # 軸線
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$plotBottom, [int]$plotRight))
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotBottom))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">日時</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 60)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">チャーン</text>' -f [int]($plotTop + $plotHeight / 2.0)))

    # バー描画
    foreach ($d in $sorted)
    {
        $xPos = $plotLeft + (($d.DateTime - $minDate).TotalSeconds / $dateRange) * $plotWidth
        $barH = ($d.Churn / $maxChurn) * $plotHeight
        $yPos = $plotBottom - $barH
        $bColor = $authorColors[$d.Author]
        [void]$sb.AppendLine(('<rect x="{0:F1}" y="{1:F1}" width="{2:F1}" height="{3:F1}" fill="{4}" fill-opacity="0.75" stroke="{4}" stroke-width="0.5"><title>r{5} {6} ({7}) チャーン:{8}</title></rect>' -f ($xPos - $barWidth / 2.0), $yPos, $barWidth, [Math]::Max(1.0, $barH), $bColor, (ConvertTo-SvgEscapedText -Text $d.Revision), (ConvertTo-SvgEscapedText -Text $d.Author), $d.DateTime.ToString('yyyy/MM/dd HH:mm'), [int]$d.Churn))
    }

    # 凡例
    $legendY = $plotTop + 10.0
    $legendIdx = 0
    foreach ($authorName in $authorColors.Keys)
    {
        $ly = $legendY + ($legendIdx * 20.0)
        $lColor = $authorColors[$authorName]
        [void]$sb.AppendLine(('<rect x="{0}" y="{1:F0}" width="12" height="12" fill="{2}"/>' -f [int]$legendX, $ly, $lColor))
        [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1:F0}">{2}</text>' -f [int]($legendX + 18), ($ly + 11), (ConvertTo-SvgEscapedText -Text $authorName)))
        $legendIdx++
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'commit_timeline.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Write-CommitScatterChart
{
    <#
    .SYNOPSIS
        コミット特性の散布図 SVG を出力する。
    .DESCRIPTION
        X 軸に変更ファイル数、Y 軸にエントロピーを取り、バブルサイズにチャーンを
        反映した散布図を生成する。色は作者別に割り当て、コミットの特性を可視化する。
        右上の大きなバブル = 多数ファイルに分散した大規模変更（リスクが高い）。
        左下の小さなバブル = 単一ファイルの小さな変更（安全）。
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Commits
        commits.csv 相当のコミット行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitScatterChart -OutDirectory '.\output' -Commits $commitRows -EncodingName 'UTF8'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Commits,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-CommitScatterChart: OutDirectory が空です。'
        return
    }
    if (-not $Commits -or @($Commits).Count -eq 0)
    {
        Write-Verbose 'Write-CommitScatterChart: Commits が空です。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-CommitScatterChart'))
    {
        return
    }

    # データ構築
    $scatterData = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Commits))
    {
        if ($null -eq $c)
        {
            continue
        }
        $fileCount = 0.0
        $prop = $c.PSObject.Properties['変更ファイル数']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $fileCount = [double]$prop.Value
        }
        $entropy = 0.0
        $prop = $c.PSObject.Properties['エントロピー']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $entropy = [double]$prop.Value
        }
        $churn = 0.0
        $prop = $c.PSObject.Properties['チャーン']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $churn = [double]$prop.Value
        }
        $author = ''
        $prop = $c.PSObject.Properties['作者']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $author = [string]$prop.Value
        }
        $rev = ''
        $prop = $c.PSObject.Properties['リビジョン']
        if ($null -ne $prop -and $null -ne $prop.Value)
        {
            $rev = [string]$prop.Value
        }
        if ($fileCount -le 0 -and $churn -le 0)
        {
            continue
        }
        [void]$scatterData.Add([pscustomobject]@{
                FileCount = $fileCount
                Entropy = $entropy
                Churn = $churn
                Author = $author
                Revision = $rev
            })
    }
    if ($scatterData.Count -eq 0)
    {
        return
    }

    # 作者→色マッピング
    $colorPalette = $script:DefaultColorPalette
    $authorColors = @{}
    $authorIndex = 0
    foreach ($d in $scatterData)
    {
        if (-not $authorColors.ContainsKey($d.Author))
        {
            $authorColors[$d.Author] = $colorPalette[$authorIndex % $colorPalette.Count]
            $authorIndex++
        }
    }

    # 描画定数
    $plotLeft = 80.0
    $plotTop = 60.0
    $plotWidth = 400.0
    $plotHeight = 400.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $legendX = $plotRight + 20.0

    $maxFileCount = ($scatterData | Measure-Object -Property FileCount -Maximum).Maximum
    if ($maxFileCount -le 0)
    {
        $maxFileCount = 1.0
    }
    $maxEntropy = ($scatterData | Measure-Object -Property Entropy -Maximum).Maximum
    if ($maxEntropy -le 0)
    {
        $maxEntropy = 1.0
    }
    $maxChurn = ($scatterData | Measure-Object -Property Churn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = 6.0
    $maxBubble = 30.0

    $svgW = [int]($legendX + 160)
    $svgH = 580

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .legend-text { font-size: 11px; fill: #333; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">コミット特性マップ</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: 変更ファイル数 / Y: エントロピー（変更の分散度） / 円: チャーン（追加+削除） / 色: 作者</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">変更ファイル数</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">エントロピー</text>' -f [int]($plotTop + $plotHeight / 2.0)))

    # X軸目盛り
    $xTickCount = 5
    for ($i = 0; $i -le $xTickCount; $i++)
    {
        $xValue = ($maxFileCount * $i) / [double]$xTickCount
        $xPos = $plotLeft + ($plotWidth * $i) / [double]$xTickCount
        [void]$sb.AppendLine(('<line class="grid-line" x1="{0:F0}" y1="{1}" x2="{0:F0}" y2="{2}"/>' -f $xPos, [int]$plotTop, [int]$plotBottom))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2}</text>' -f $xPos, [int]($plotBottom + 16), [int][Math]::Round($xValue)))
    }
    # Y軸目盛り
    $yTickCount = 5
    for ($i = 0; $i -le $yTickCount; $i++)
    {
        $yValue = ($maxEntropy * $i) / [double]$yTickCount
        $yPos = $plotBottom - ($plotHeight * $i) / [double]$yTickCount
        [void]$sb.AppendLine(('<line class="grid-line" x1="{0}" y1="{1:F0}" x2="{2}" y2="{1:F0}"/>' -f [int]$plotLeft, $yPos, [int]$plotRight))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F2}</text>' -f [int]($plotLeft - 6), ($yPos + 4), $yValue))
    }

    # 軸線
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$plotBottom, [int]$plotRight))
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotBottom))

    # バブル描画（大きい順に描画して小さい方が前面に来る）
    $sortedByChurn = @($scatterData | Sort-Object -Property Churn -Descending)
    foreach ($d in $sortedByChurn)
    {
        $bx = $plotLeft + ($d.FileCount / $maxFileCount) * $plotWidth
        $by = $plotBottom - ($d.Entropy / $maxEntropy) * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.Churn / $maxChurn)
        $bColor = $authorColors[$d.Author]
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.55" stroke="{3}" stroke-width="1.2"><title>r{4} {5} (ファイル数:{6}, エントロピー:{7:F2}, チャーン:{8})</title></circle>' -f $bx, $by, $br, $bColor, (ConvertTo-SvgEscapedText -Text $d.Revision), (ConvertTo-SvgEscapedText -Text $d.Author), [int]$d.FileCount, $d.Entropy, [int]$d.Churn))
    }

    # 凡例
    $legendY = $plotTop + 10.0
    $legendIdx = 0
    foreach ($authorName in $authorColors.Keys)
    {
        $ly = $legendY + ($legendIdx * 20.0)
        $lColor = $authorColors[$authorName]
        [void]$sb.AppendLine(('<rect x="{0}" y="{1:F0}" width="12" height="12" fill="{2}"/>' -f [int]$legendX, $ly, $lColor))
        [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1:F0}">{2}</text>' -f [int]($legendX + 18), ($ly + 11), (ConvertTo-SvgEscapedText -Text $authorName)))
        $legendIdx++
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'commit_scatter.svg') -Content $sb.ToString() -EncodingName $EncodingName
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
function Get-CommitterOutcomeData
{
    <#
    .SYNOPSIS
        コミッター行データからコード帰結チャート用のデータを抽出する。
    .DESCRIPTION
        追加行数が 0 を超えるコミッターを対象に、生存・自己相殺・被他者削除・
        その他の内訳データとピンポン率を算出する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として抽出する件数を指定する。0 で全件。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [int]$TopNCount = 0
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        $added = 0.0
        if ($null -ne $c.'追加行数')
        {
            $added = [double]$c.'追加行数'
        }
        if ($added -le 0)
        {
            continue
        }
        $survived = 0.0
        if ($null -ne $c.'生存行数')
        {
            $survived = [double]$c.'生存行数'
        }
        $selfCancel = 0.0
        if ($null -ne $c.'自己相殺行数')
        {
            $selfCancel = [double]$c.'自己相殺行数'
        }
        $removedByOthers = 0.0
        if ($null -ne $c.'被他者削除行数')
        {
            $removedByOthers = [double]$c.'被他者削除行数'
        }
        $other = $added - ($survived + $selfCancel + $removedByOthers)
        if ($other -lt 0)
        {
            Write-Warning ("Outcome 'その他' が負の値: 作者={0} (added={1}, survived={2}, selfCancel={3}, removedByOthers={4})" -f [string]$c.'作者', $added, $survived, $selfCancel, $removedByOthers)
            $other = 0.0
        }
        $pingPongRate = 0.0
        if ($null -ne $c.'ピンポン率')
        {
            $pingPongRate = [double]$c.'ピンポン率'
        }
        $totalChurn = 0.0
        if ($null -ne $c.'総チャーン')
        {
            $totalChurn = [double]$c.'総チャーン'
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$c.'作者'))
                AddedLines = $added
                Survived = $survived
                SelfCancel = $selfCancel
                RemovedByOthers = $removedByOthers
                Other = $other
                SurvivedRate = $survived / $added
                SelfCancelRate = $selfCancel / $added
                RemovedByOthersRate = $removedByOthers / $added
                OtherRate = $other / $added
                PingPongRate = $pingPongRate
                TotalChurn = $totalChurn
            })
    }
    if ($rows.Count -eq 0)
    {
        return @()
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'
            Descending = $true
        }, 'Author')
    if ($TopNCount -gt 0 -and $sorted.Count -gt $TopNCount)
    {
        return @($sorted | Select-Object -First $TopNCount)
    }
    return $sorted
}
function Write-CommitterOutcomeChart
{
    <#
    .SYNOPSIS
        コミッター別コード帰結を積み上げ横棒グラフ SVG として出力する。
    .DESCRIPTION
        追加行数を 100% として、生存・自己相殺・被他者削除・その他の内訳を
        積み上げ横棒グラフで表示する。個人用 SVG（自分のデータのみ）を
        コミッター数分、およびリーダー用 SVG（全員比較）を 1 枚出力する。
        各セグメントの色:
        - 生存: 緑 — 最終時点で生き残っているコード
        - 自己相殺: 黄 — 自分で追加した後に自分で削除したコード
        - 被他者削除: 赤 — 自分が追加した後に他者に削除されたコード
        - その他: グレー — 上記に分類できない消滅分
        ピンポン率を棒の右側にマーカーで表示する。
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として SVG を生成する件数を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitterOutcomeChart -OutDirectory '.\output' -Committers $committers -TopNCount 10 -EncodingName 'UTF8'
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
        Write-Warning 'Write-CommitterOutcomeChart: OutDirectory が空です。'
        return
    }
    if ($TopNCount -le 0)
    {
        Write-Verbose 'Write-CommitterOutcomeChart: TopNCount が 0 以下のため、出力しません。'
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        Write-Verbose 'Write-CommitterOutcomeChart: Committers が空です。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-CommitterOutcomeChart'))
    {
        return
    }

    $chartData = @(Get-CommitterOutcomeData -Committers $Committers -TopNCount $TopNCount)
    if ($chartData.Count -eq 0)
    {
        return
    }

    # --- 色定義 ---
    $colorSurvived = '#4caf50'
    $colorSelfCancel = '#ffc107'
    $colorRemovedByOthers = '#f44336'
    $colorOther = '#bdbdbd'

    # --- 個人用 SVG（1人分のみ表示） ---
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $chartData)
    {
        $authorDisplay = [string]$row.Author
        $baseName = 'committer_outcome_' + $authorDisplay
        $fileName = Get-SafeFileName -BaseName $baseName -Extension '.svg'
        while (-not $usedNames.Add($fileName))
        {
            $baseName = $baseName + '_dup'
            $fileName = Get-SafeFileName -BaseName $baseName -Extension '.svg'
        }

        $barWidth = 500.0
        $barHeight = 40.0
        $barX = 160.0
        $barY = 70.0
        $svgWidth = 820.0
        $svgHeight = 200.0
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(('<?xml version="1.0" encoding="UTF-8"?>'))
        [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f [int]$svgWidth, [int]$svgHeight))
        [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .bar-label { font-size: 12px; fill: #333; }
  .pct-label { font-size: 11px; fill: #fff; font-weight: bold; }
  .pct-label-dark { font-size: 11px; fill: #333; font-weight: bold; }
  .legend-text { font-size: 11px; fill: #555; }
  .ping-pong { font-size: 11px; fill: #666; }
'@))
        [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
        $titleText = ConvertTo-SvgEscapedText -Text ('{0} — コード帰結チャート' -f $authorDisplay)
        [void]$sb.AppendLine(('<text class="title" x="20" y="30">{0}</text>' -f $titleText))
        [void]$sb.AppendLine(('<text class="bar-label" x="20" y="60" style="font-size:11px;fill:#888;">追加行数: {0} 行</text>' -f [int]$row.AddedLines))

        # 棒グラフ描画
        $segments = @(
            [pscustomobject]@{ Rate = $row.SurvivedRate; Color = $colorSurvived; Label = '生存' }
            [pscustomobject]@{ Rate = $row.SelfCancelRate; Color = $colorSelfCancel; Label = '自己相殺' }
            [pscustomobject]@{ Rate = $row.RemovedByOthersRate; Color = $colorRemovedByOthers; Label = '被他者削除' }
            [pscustomobject]@{ Rate = $row.OtherRate; Color = $colorOther; Label = 'その他' }
        )
        $offsetX = $barX
        foreach ($seg in $segments)
        {
            $segWidth = $seg.Rate * $barWidth
            if ($segWidth -gt 0.5)
            {
                [void]$sb.AppendLine(('<rect x="{0:F1}" y="{1}" width="{2:F1}" height="{3}" fill="{4}" rx="2"/>' -f $offsetX, [int]$barY, $segWidth, [int]$barHeight, $seg.Color))
                if ($segWidth -gt 35)
                {
                    $pctText = '{0:F0}%' -f ($seg.Rate * 100)
                    $textX = $offsetX + ($segWidth / 2.0)
                    $textY = $barY + ($barHeight / 2.0) + 4.0
                    $textClass = if ($seg.Color -eq $colorSelfCancel -or $seg.Color -eq $colorOther)
                    {
                        'pct-label-dark'
                    }
                    else
                    {
                        'pct-label'
                    }
                    [void]$sb.AppendLine(('<text class="{0}" x="{1:F1}" y="{2:F1}" text-anchor="middle">{3}</text>' -f $textClass, $textX, $textY, (ConvertTo-SvgEscapedText -Text $pctText)))
                }
            }
            $offsetX += $segWidth
        }
        # ピンポン率マーカー
        $ppText = '🔄 ピンポン率: {0:F1}%' -f ($row.PingPongRate * 100)
        [void]$sb.AppendLine(('<text class="ping-pong" x="{0}" y="{1}">{2}</text>' -f [int]($barX), [int]($barY + $barHeight + 20), (ConvertTo-SvgEscapedText -Text $ppText)))

        # 凡例
        $legendY = $barY + $barHeight + 44
        $legendItems = @(
            [pscustomobject]@{ Color = $colorSurvived; Label = '生存' }
            [pscustomobject]@{ Color = $colorSelfCancel; Label = '自己相殺' }
            [pscustomobject]@{ Color = $colorRemovedByOthers; Label = '被他者削除' }
            [pscustomobject]@{ Color = $colorOther; Label = 'その他' }
        )
        $legendX = $barX
        foreach ($item in $legendItems)
        {
            [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="12" height="12" fill="{2}" rx="2"/>' -f [int]$legendX, [int]$legendY, $item.Color))
            [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">{2}</text>' -f [int]($legendX + 16), [int]($legendY + 11), (ConvertTo-SvgEscapedText -Text $item.Label)))
            $legendX += 90
        }

        [void]$sb.AppendLine('</svg>')
        Write-TextFile -FilePath (Join-Path $OutDirectory $fileName) -Content $sb.ToString() -EncodingName $EncodingName
    }

    # --- リーダー用 SVG（全員比較） ---
    $rowHeight = 36.0
    $labelWidth = 140.0
    $barAreaWidth = 460.0
    $addedLabelWidth = 80.0
    $ppLabelWidth = 100.0
    $svgWidthAll = $labelWidth + $barAreaWidth + $addedLabelWidth + $ppLabelWidth + 40.0
    $headerHeight = 60.0
    $legendHeight = 50.0
    $svgHeightAll = $headerHeight + ($chartData.Count * $rowHeight) + $legendHeight + 20.0

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f [int]$svgWidthAll, [int]$svgHeightAll))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .title { font-size: 18px; font-weight: bold; fill: #333; }
  .author-label { font-size: 12px; fill: #333; }
  .added-label { font-size: 11px; fill: #666; }
  .pct-label { font-size: 10px; fill: #fff; font-weight: bold; }
  .pct-label-dark { font-size: 10px; fill: #333; font-weight: bold; }
  .pp-label { font-size: 10px; fill: #666; }
  .legend-text { font-size: 11px; fill: #555; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">コード帰結チャート（チーム比較）</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">追加行数に対する生存・消滅の内訳</text>')

    for ($i = 0; $i -lt $chartData.Count; $i++)
    {
        $d = $chartData[$i]
        $rowY = $headerHeight + ($i * $rowHeight)
        $barY2 = $rowY + 6.0
        $barH = $rowHeight - 12.0
        $authorEscaped = ConvertTo-SvgEscapedText -Text ([string]$d.Author)
        [void]$sb.AppendLine(('<text class="author-label" x="20" y="{0:F1}">{1}</text>' -f ($barY2 + $barH / 2.0 + 4.0), $authorEscaped))
        $segments = @(
            [pscustomobject]@{ Rate = $d.SurvivedRate; Color = $colorSurvived; Label = '生存' }
            [pscustomobject]@{ Rate = $d.SelfCancelRate; Color = $colorSelfCancel; Label = '自己相殺' }
            [pscustomobject]@{ Rate = $d.RemovedByOthersRate; Color = $colorRemovedByOthers; Label = '被他者削除' }
            [pscustomobject]@{ Rate = $d.OtherRate; Color = $colorOther; Label = 'その他' }
        )
        $ox = $labelWidth
        foreach ($seg in $segments)
        {
            $sw = $seg.Rate * $barAreaWidth
            if ($sw -gt 0.5)
            {
                [void]$sb.AppendLine(('<rect x="{0:F1}" y="{1:F1}" width="{2:F1}" height="{3:F1}" fill="{4}" rx="1"/>' -f $ox, $barY2, $sw, $barH, $seg.Color))
                if ($sw -gt 30)
                {
                    $ptxt = '{0:F0}%' -f ($seg.Rate * 100)
                    $txC = if ($seg.Color -eq $colorSelfCancel -or $seg.Color -eq $colorOther)
                    {
                        'pct-label-dark'
                    }
                    else
                    {
                        'pct-label'
                    }
                    [void]$sb.AppendLine(('<text class="{0}" x="{1:F1}" y="{2:F1}" text-anchor="middle">{3}</text>' -f $txC, ($ox + $sw / 2.0), ($barY2 + $barH / 2.0 + 3.5), (ConvertTo-SvgEscapedText -Text $ptxt)))
                }
            }
            $ox += $sw
        }
        # 追加行数ラベル
        [void]$sb.AppendLine(('<text class="added-label" x="{0:F1}" y="{1:F1}">{2} 行</text>' -f ($labelWidth + $barAreaWidth + 8.0), ($barY2 + $barH / 2.0 + 4.0), [int]$d.AddedLines))
        # ピンポン率
        $ppVal = '🔄 {0:F1}%' -f ($d.PingPongRate * 100)
        [void]$sb.AppendLine(('<text class="pp-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f ($labelWidth + $barAreaWidth + $addedLabelWidth + 8.0), ($barY2 + $barH / 2.0 + 4.0), (ConvertTo-SvgEscapedText -Text $ppVal)))
    }

    # 凡例
    $legY = $headerHeight + ($chartData.Count * $rowHeight) + 12.0
    $legItems = @(
        [pscustomobject]@{ Color = $colorSurvived; Label = '生存' }
        [pscustomobject]@{ Color = $colorSelfCancel; Label = '自己相殺' }
        [pscustomobject]@{ Color = $colorRemovedByOthers; Label = '被他者削除' }
        [pscustomobject]@{ Color = $colorOther; Label = 'その他' }
    )
    $legX = $labelWidth
    foreach ($item in $legItems)
    {
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="12" height="12" fill="{2}" rx="2"/>' -f [int]$legX, [int]$legY, $item.Color))
        [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">{2}</text>' -f [int]($legX + 16), [int]($legY + 11), (ConvertTo-SvgEscapedText -Text $item.Label)))
        $legX += 90
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'committer_outcome_combined.svg') -Content $sb.ToString() -EncodingName $EncodingName
}
function Get-CommitterScatterData
{
    <#
    .SYNOPSIS
        コミッター行データからリワーク特性マップ用のデータを抽出する。
    .DESCRIPTION
        リワーク率とコード生存率を持つコミッターを抽出し、
        散布図描画用のデータオブジェクトを返す。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として抽出する件数を指定する。0 で全件。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [int]$TopNCount = 0
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        $added = 0.0
        if ($null -ne $c.'追加行数')
        {
            $added = [double]$c.'追加行数'
        }
        if ($added -le 0)
        {
            continue
        }
        if ($null -eq $c.'リワーク率' -or $null -eq $c.'生存行数')
        {
            continue
        }
        $reworkRate = [double]$c.'リワーク率'
        $survivalRate = [double]$c.'生存行数' / $added
        $totalChurn = 0.0
        if ($null -ne $c.'総チャーン')
        {
            $totalChurn = [double]$c.'総チャーン'
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$c.'作者'))
                ReworkRate = $reworkRate
                SurvivalRate = $survivalRate
                TotalChurn = $totalChurn
            })
    }
    if ($rows.Count -eq 0)
    {
        return @()
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'
            Descending = $true
        }, 'Author')
    if ($TopNCount -gt 0 -and $sorted.Count -gt $TopNCount)
    {
        return @($sorted | Select-Object -First $TopNCount)
    }
    return $sorted
}
function Write-CommitterScatterChart
{
    <#
    .SYNOPSIS
        リワーク率 × コード生存率の散布図 SVG を出力する。
    .DESCRIPTION
        X 軸にリワーク率、Y 軸にコード生存率を取り、バブルサイズに総チャーンを
        反映した散布図を生成する。個人用 SVG（自分のデータのみ＋象限ラベル）を
        コミッター数分、およびリーダー用 SVG（全員プロット）を 1 枚出力する。
        4 象限の解釈:
        - 左上: 積み上げ型（新規追加中心で定着）
        - 右上: 耕し型（書き換え多いが結果が定着）
        - 左下: 使い捨て型（追加中心だが消されている）
        - 右下: 手戻り型（書いては消すの繰り返し）
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として SVG を生成する件数を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
    .EXAMPLE
        Write-CommitterScatterChart -OutDirectory '.\output' -Committers $committers -TopNCount 10 -EncodingName 'UTF8'
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
        Write-Warning 'Write-CommitterScatterChart: OutDirectory が空です。'
        return
    }
    if ($TopNCount -le 0)
    {
        Write-Verbose 'Write-CommitterScatterChart: TopNCount が 0 以下のため、出力しません。'
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        Write-Verbose 'Write-CommitterScatterChart: Committers が空です。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-CommitterScatterChart'))
    {
        return
    }

    $scatterData = @(Get-CommitterScatterData -Committers $Committers -TopNCount $TopNCount)
    if ($scatterData.Count -eq 0)
    {
        return
    }

    # 描画定数
    $plotLeft = 80.0
    $plotTop = 60.0
    $plotWidth = 400.0
    $plotHeight = 400.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $midX = $plotLeft + $plotWidth / 2.0
    $midY = $plotTop + $plotHeight / 2.0

    # バブルサイズ
    $maxChurn = ($scatterData | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = 8.0
    $maxBubble = 36.0

    # 象限ラベル
    $quadrants = @(
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.2; Label = '🧱 積み上げ型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.2; Label = '🌱 耕し型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.8; Label = '🪦 使い捨て型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.8; Label = '🔥 手戻り型' }
    )

    # SVG CSS 共通
    $cssBlock = Get-SvgCommonStyle -AdditionalStyles @'
  .quadrant-label { font-size: 13px; fill: #aaa; text-anchor: middle; }
  .author-label { font-size: 11px; fill: #333; text-anchor: middle; }
  .bubble { fill: #42a5f5; fill-opacity: 0.55; stroke: #1e88e5; stroke-width: 1.2; }
  .bubble-self { fill: #ef5350; fill-opacity: 0.6; stroke: #c62828; stroke-width: 1.8; }
  .mid-line { stroke: #bdbdbd; stroke-width: 1; stroke-dasharray: 6,4; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@

    # --- 個人用 SVG ---
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $scatterData)
    {
        $authorDisplay = [string]$row.Author
        $baseName = 'committer_scatter_' + $authorDisplay
        $fileName = Get-SafeFileName -BaseName $baseName -Extension '.svg'
        while (-not $usedNames.Add($fileName))
        {
            $baseName = $baseName + '_dup'
            $fileName = Get-SafeFileName -BaseName $baseName -Extension '.svg'
        }

        $svgW = 600
        $svgH = 560
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
        [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
        [void]$sb.Append($cssBlock)
        [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
        $titleEscaped = ConvertTo-SvgEscapedText -Text ('{0} — リワーク特性マップ' -f $authorDisplay)
        [void]$sb.AppendLine(('<text class="title" x="20" y="28">{0}</text>' -f $titleEscaped))
        [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: リワーク率 / Y: コード生存率 / 円の大きさ: 総チャーン</text>')

        # プロットエリア
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
        # 中央線（0.5）
        [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
        [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
        # 軸ラベル
        [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">リワーク率</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
        [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">コード生存率</text>' -f [int]($plotTop + $plotHeight / 2.0)))
        # 目盛り
        for ($tick = 0.0; $tick -le 1.01; $tick += 0.25)
        {
            $tx = $plotLeft + $tick * $plotWidth
            $ty = $plotBottom - $tick * $plotHeight
            [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
            [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
        }
        # 象限ラベル
        foreach ($q in $quadrants)
        {
            [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Label)))
        }
        # 自分のバブル
        $bx = $plotLeft + $row.ReworkRate * $plotWidth
        $by = $plotBottom - $row.SurvivalRate * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($row.TotalChurn / $maxChurn)
        [void]$sb.AppendLine(('<circle class="bubble-self" cx="{0:F1}" cy="{1:F1}" r="{2:F1}"><title>{3} (リワーク率:{4:F1}%, 生存率:{5:F1}%, チャーン:{6})</title></circle>' -f $bx, $by, $br, (ConvertTo-SvgEscapedText -Text $authorDisplay), ($row.ReworkRate * 100), ($row.SurvivalRate * 100), [int]$row.TotalChurn))
        [void]$sb.AppendLine(('<text class="author-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f $bx, ($by - $br - 4.0), (ConvertTo-SvgEscapedText -Text $authorDisplay)))

        [void]$sb.AppendLine('</svg>')
        Write-TextFile -FilePath (Join-Path $OutDirectory $fileName) -Content $sb.ToString() -EncodingName $EncodingName
    }

    # --- リーダー用 SVG（全員プロット） ---
    $svgW2 = 640
    $svgH2 = 580
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW2, $svgH2))
    [void]$sb.Append($cssBlock)
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">リワーク特性マップ（チーム比較）</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: リワーク率 / Y: コード生存率 / 円の大きさ: 総チャーン</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">リワーク率</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">コード生存率</text>' -f [int]($plotTop + $plotHeight / 2.0)))
    # 目盛り
    for ($tick = 0.0; $tick -le 1.01; $tick += 0.25)
    {
        $tx = $plotLeft + $tick * $plotWidth
        $ty = $plotBottom - $tick * $plotHeight
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
    }
    # 象限ラベル
    foreach ($q in $quadrants)
    {
        [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Label)))
    }
    # 全員のバブル（大きい順に描画して小さい方が前面に来る）
    $sortedByChurn = @($scatterData | Sort-Object -Property TotalChurn -Descending)
    $colorPalette = $script:DefaultColorPalette
    for ($ci = 0; $ci -lt $sortedByChurn.Count; $ci++)
    {
        $d = $sortedByChurn[$ci]
        $bx = $plotLeft + $d.ReworkRate * $plotWidth
        $by = $plotBottom - $d.SurvivalRate * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.TotalChurn / $maxChurn)
        $cIdx = $ci % $colorPalette.Count
        $bColor = $colorPalette[$cIdx]
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.55" stroke="{3}" stroke-width="1.2"><title>{4} (リワーク率:{5:F1}%, 生存率:{6:F1}%, チャーン:{7})</title></circle>' -f $bx, $by, $br, $bColor, (ConvertTo-SvgEscapedText -Text $d.Author), ($d.ReworkRate * 100), ($d.SurvivalRate * 100), [int]$d.TotalChurn))
        [void]$sb.AppendLine(('<text class="author-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f $bx, ($by - $br - 4.0), (ConvertTo-SvgEscapedText -Text $d.Author)))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'committer_scatter_combined.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Write-KillMatrixCsv
{
    <#
    .SYNOPSIS
        Kill Matrix（誰が誰のコードを何行消したか）を CSV ファイルに出力する。
    .DESCRIPTION
        Kill Matrix の pairwise データを CSV 形式で出力する。
        行 = killer（消した人）、列 = victim（消された人）のクロス集計表。
        対角線には自己相殺行数を配置する。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER KillMatrix
        killer → victim → lineCount のネストハッシュテーブルを指定する。
    .PARAMETER AuthorSelfDead
        作者 → 自己相殺行数のハッシュテーブルを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$KillMatrix,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$AuthorSelfDead,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ($null -eq $KillMatrix -or $null -eq $AuthorSelfDead)
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }
    $authors = @($Committers | ForEach-Object { Get-NormalizedAuthorName -Author ([string]$_.'作者') } | Sort-Object)
    if ($authors.Count -eq 0)
    {
        return
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($killer in $authors)
    {
        $row = [ordered]@{
            '削除者＼被削除者' = $killer
        }
        foreach ($victim in $authors)
        {
            $count = 0
            if ($killer -eq $victim)
            {
                $count = Get-HashtableIntValue -Table $AuthorSelfDead -Key $killer
            }
            elseif ($KillMatrix.ContainsKey($killer) -and $KillMatrix[$killer].ContainsKey($victim))
            {
                $count = [int]$KillMatrix[$killer][$victim]
            }
            $row[$victim] = $count
        }
        [void]$rows.Add([pscustomobject]$row)
    }
    $headers = @('削除者＼被削除者') + $authors
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'kill_matrix.csv') -Rows $rows.ToArray() -Headers $headers -EncodingName $EncodingName
}

function Write-SurvivedShareDonutChart
{
    <#
    .SYNOPSIS
        チーム全体の生存行数を作者別割合でドーナツチャートに描画する。
    .DESCRIPTION
        各コミッターの生存行数をドーナツチャートとして可視化する。
        チームの最終的なコード資産が誰の手によるものかを一目で把握できる。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
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
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }
    $data = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        $survived = 0.0
        if ($null -ne $c.'生存行数')
        {
            $survived = [double]$c.'生存行数'
        }
        if ($survived -le 0)
        {
            continue
        }
        [void]$data.Add([pscustomobject]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$c.'作者'))
                Survived = $survived
            })
    }
    if ($data.Count -eq 0)
    {
        return
    }
    $sorted = @($data.ToArray() | Sort-Object -Property @{Expression = 'Survived'; Descending = $true }, 'Author')
    $total = ($sorted | Measure-Object -Property Survived -Sum).Sum
    if ($total -le 0)
    {
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    $colorPalette = $script:DefaultColorPalette
    $svgW = 640
    $svgH = 420
    $cx = 240.0
    $cy = 220.0
    $outerR = 140.0
    $innerR = 80.0
    $legendX = 420.0
    $legendY = 80.0

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .center-label { font-size: 14px; fill: #555; text-anchor: middle; }
  .center-value { font-size: 22px; font-weight: bold; fill: #333; text-anchor: middle; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">コード資産の帰属分布（生存行数）</text>')
    [void]$sb.AppendLine(('<text class="subtitle" x="20" y="46">チーム全体の生存コード {0} 行の作者別内訳</text>' -f [int]$total))

    # ドーナツ描画
    $startAngle = -90.0
    for ($i = 0; $i -lt $sorted.Count; $i++)
    {
        $d = $sorted[$i]
        $share = $d.Survived / $total
        $sweepAngle = $share * 360.0
        if ($sweepAngle -lt 0.1)
        {
            continue
        }
        $cIdx = $i % $colorPalette.Count
        $color = $colorPalette[$cIdx]

        $startRad = $startAngle * [Math]::PI / 180.0
        $endRad = ($startAngle + $sweepAngle) * [Math]::PI / 180.0
        $largeArc = if ($sweepAngle -gt 180.0)
        {
            1
        }
        else
        {
            0
        }

        $ox1 = $cx + $outerR * [Math]::Cos($startRad)
        $oy1 = $cy + $outerR * [Math]::Sin($startRad)
        $ox2 = $cx + $outerR * [Math]::Cos($endRad)
        $oy2 = $cy + $outerR * [Math]::Sin($endRad)
        $ix1 = $cx + $innerR * [Math]::Cos($endRad)
        $iy1 = $cy + $innerR * [Math]::Sin($endRad)
        $ix2 = $cx + $innerR * [Math]::Cos($startRad)
        $iy2 = $cy + $innerR * [Math]::Sin($startRad)

        $pathD = ('M {0:F1} {1:F1} A {2:F1} {2:F1} 0 {3} 1 {4:F1} {5:F1} L {6:F1} {7:F1} A {8:F1} {8:F1} 0 {3} 0 {9:F1} {10:F1} Z' -f $ox1, $oy1, $outerR, $largeArc, $ox2, $oy2, $ix1, $iy1, $innerR, $ix2, $iy2)
        $tooltipText = ('{0}: {1} 行 ({2:F1}%)' -f (ConvertTo-SvgEscapedText -Text $d.Author), [int]$d.Survived, ($share * 100))
        [void]$sb.AppendLine(('<path d="{0}" fill="{1}" stroke="#fff" stroke-width="2"><title>{2}</title></path>' -f $pathD, $color, $tooltipText))

        $startAngle += $sweepAngle
    }

    # 中央テキスト
    [void]$sb.AppendLine(('<text class="center-value" x="{0}" y="{1}">{2}</text>' -f [int]$cx, [int]($cy + 4), [int]$total))
    [void]$sb.AppendLine(('<text class="center-label" x="{0}" y="{1}">生存行数</text>' -f [int]$cx, [int]($cy + 24)))

    # 凡例
    for ($i = 0; $i -lt $sorted.Count; $i++)
    {
        $d = $sorted[$i]
        $cIdx = $i % $colorPalette.Count
        $color = $colorPalette[$cIdx]
        $ly = $legendY + $i * 28
        $share = $d.Survived / $total
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="16" height="16" rx="3" fill="{2}"/>' -f [int]$legendX, [int]$ly, $color))
        $legendLabel = ('{0}: {1} 行 ({2:F1}%)' -f (ConvertTo-SvgEscapedText -Text $d.Author), [int]$d.Survived, ($share * 100))
        [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">{2}</text>' -f [int]($legendX + 22), [int]($ly + 13), $legendLabel))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'team_survived_share.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Write-TeamInteractionHeatMap
{
    <#
    .SYNOPSIS
        チーム内のコード削除関係をヒートマップで可視化する。
    .DESCRIPTION
        Kill Matrix（誰が誰のコードを何行消したか）をヒートマップとして描画する。
        行 = 削除者（killer）、列 = 被削除者（victim）。
        対角線には自己相殺行数を配置し、チーム内の相互作用パターンを可視化する。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER KillMatrix
        killer → victim → lineCount のネストハッシュテーブルを指定する。
    .PARAMETER AuthorSelfDead
        作者 → 自己相殺行数のハッシュテーブルを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$KillMatrix,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$AuthorSelfDead,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if ($null -eq $KillMatrix -or $null -eq $AuthorSelfDead)
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }
    $authors = @($Committers | ForEach-Object { Get-NormalizedAuthorName -Author ([string]$_.'作者') } | Sort-Object)
    if ($authors.Count -lt 2)
    {
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    # 値マトリクスの構築と最大値の取得
    $matrix = @{}
    $maxVal = 0
    foreach ($killer in $authors)
    {
        $matrix[$killer] = @{}
        foreach ($victim in $authors)
        {
            $val = 0
            if ($killer -eq $victim)
            {
                $val = Get-HashtableIntValue -Table $AuthorSelfDead -Key $killer
            }
            elseif ($KillMatrix.ContainsKey($killer) -and $KillMatrix[$killer].ContainsKey($victim))
            {
                $val = [int]$KillMatrix[$killer][$victim]
            }
            $matrix[$killer][$victim] = $val
            if ($val -gt $maxVal)
            {
                $maxVal = $val
            }
        }
    }
    if ($maxVal -le 0)
    {
        return
    }

    # レイアウト定数
    $cellSize = 80
    $headerSize = 100
    $marginLeft = 30
    $marginTop = 70
    $n = $authors.Count
    $gridLeft = $marginLeft + $headerSize
    $gridTop = $marginTop + $headerSize
    $svgW = $gridLeft + $n * $cellSize + 40
    $svgH = $gridTop + $n * $cellSize + 40

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .header-label { font-size: 12px; fill: #333; }
  .cell-value { font-size: 13px; fill: #333; text-anchor: middle; dominant-baseline: central; }
  .cell-value-light { font-size: 13px; fill: #fff; text-anchor: middle; dominant-baseline: central; }
  .axis-title { font-size: 12px; fill: #666; font-weight: bold; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">チーム相互作用ヒートマップ（コード削除関係）</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">行 = 削除者 / 列 = 被削除者（対角線 = 自己相殺）</text>')

    # 軸タイトル
    [void]$sb.AppendLine(('<text class="axis-title" x="{0}" y="{1}" text-anchor="middle">被削除者 →</text>' -f [int]($gridLeft + $n * $cellSize / 2), [int]($marginTop + $headerSize - 60)))
    $rotateY = $gridTop + $n * $cellSize / 2
    [void]$sb.AppendLine(('<text class="axis-title" x="{0}" y="{1}" text-anchor="middle" transform="rotate(-90,{0},{1})">削除者 →</text>' -f [int]($marginLeft + 10), [int]$rotateY))

    # 列ヘッダー（被削除者）
    for ($ci = 0; $ci -lt $n; $ci++)
    {
        $hx = $gridLeft + $ci * $cellSize + $cellSize / 2
        $hy = $marginTop + $headerSize - 10
        [void]$sb.AppendLine(('<text class="header-label" x="{0}" y="{1}" text-anchor="middle">{2}</text>' -f [int]$hx, [int]$hy, (ConvertTo-SvgEscapedText -Text $authors[$ci])))
    }

    # 行ヘッダーとセル
    for ($ri = 0; $ri -lt $n; $ri++)
    {
        $killer = $authors[$ri]
        $ry = $gridTop + $ri * $cellSize + $cellSize / 2
        [void]$sb.AppendLine(('<text class="header-label" x="{0}" y="{1}" text-anchor="end" dominant-baseline="central">{2}</text>' -f [int]($gridLeft - 8), [int]$ry, (ConvertTo-SvgEscapedText -Text $killer)))

        for ($ci = 0; $ci -lt $n; $ci++)
        {
            $victim = $authors[$ci]
            $val = $matrix[$killer][$victim]
            $cellX = $gridLeft + $ci * $cellSize
            $cellY = $gridTop + $ri * $cellSize
            $centerX = $cellX + $cellSize / 2
            $centerY = $cellY + $cellSize / 2

            # 色計算（白→赤グラデーション）
            $t = 0.0
            if ($maxVal -gt 0)
            {
                $t = [double]$val / [double]$maxVal
            }
            $rVal = 255
            $gVal = [int][Math]::Round(255 * (1.0 - $t))
            $bVal = [int][Math]::Round(255 * (1.0 - $t))
            $cellColor = ('#{0}{1}{2}' -f $rVal.ToString('X2'), $gVal.ToString('X2'), $bVal.ToString('X2')).ToLowerInvariant()

            # 対角線は青系統で区別
            if ($ri -eq $ci)
            {
                $rVal = [int][Math]::Round(255 * (1.0 - $t * 0.6))
                $gVal = [int][Math]::Round(255 * (1.0 - $t * 0.3))
                $bVal = 255
                $cellColor = ('#{0}{1}{2}' -f $rVal.ToString('X2'), $gVal.ToString('X2'), $bVal.ToString('X2')).ToLowerInvariant()
            }

            $textClass = if ($t -gt 0.6)
            {
                'cell-value-light'
            }
            else
            {
                'cell-value'
            }
            $tooltipText = ('{0} → {1}: {2} 行' -f (ConvertTo-SvgEscapedText -Text $killer), (ConvertTo-SvgEscapedText -Text $victim), $val)
            [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{2}" fill="{3}" stroke="#e0e0e0" stroke-width="1"><title>{4}</title></rect>' -f [int]$cellX, [int]$cellY, $cellSize, $cellColor, $tooltipText))
            if ($val -gt 0)
            {
                [void]$sb.AppendLine(('<text class="{0}" x="{1}" y="{2}"><title>{3}</title>{4}</text>' -f $textClass, [int]$centerX, [int]$centerY, $tooltipText, $val))
            }
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'team_interaction_heatmap.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Get-TeamActivityProfileData
{
    <#
    .SYNOPSIS
        チーム活動プロファイル散布図用のデータを抽出する。
    .DESCRIPTION
        X 軸: 他者コード削除介入度（他者コード変更行数 / 削除行数）
        Y 軸: 他者コード変更生存率
        バブルサイズ: 総チャーン
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Committers
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        $deleted = 0.0
        if ($null -ne $c.'削除行数')
        {
            $deleted = [double]$c.'削除行数'
        }
        $othersModified = 0.0
        if ($null -ne $c.'他者コード変更行数')
        {
            $othersModified = [double]$c.'他者コード変更行数'
        }
        $othersSurvivalRate = 0.0
        if ($null -ne $c.'他者コード変更生存率')
        {
            $othersSurvivalRate = [double]$c.'他者コード変更生存率'
        }
        $totalChurn = 0.0
        if ($null -ne $c.'総チャーン')
        {
            $totalChurn = [double]$c.'総チャーン'
        }
        # 削除行数が 0 の場合は介入度を 0 とする
        $interventionRate = 0.0
        if ($deleted -gt 0)
        {
            $interventionRate = $othersModified / $deleted
            if ($interventionRate -gt 1.0)
            {
                $interventionRate = 1.0
            }
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$c.'作者'))
                InterventionRate = $interventionRate
                OthersSurvivalRate = $othersSurvivalRate
                TotalChurn = $totalChurn
            })
    }
    if ($rows.Count -eq 0)
    {
        return @()
    }
    return @($rows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'; Descending = $true }, 'Author')
}

function Write-TeamActivityProfileChart
{
    <#
    .SYNOPSIS
        チーム活動プロファイルの散布図 SVG を出力する。
    .DESCRIPTION
        X 軸に他者コード削除介入度（他者コード変更行数 / 削除行数）、
        Y 軸に他者コード変更生存率を取り、バブルサイズに総チャーンを反映した
        散布図を生成する。4 象限の解釈:
        - 左上: 独立型（他者コードをあまり触らない）
        - 右上: 改善者（他者コードを積極的に改善し、結果が定着）
        - 左下: 孤立型（活動が少なく他者との接点も少ない）
        - 右下: 破壊者（他者コードを積極的に消すが定着しない）
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
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
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    $profileData = @(Get-TeamActivityProfileData -Committers $Committers)
    if ($profileData.Count -eq 0)
    {
        return
    }

    # 描画定数
    $plotLeft = 80.0
    $plotTop = 60.0
    $plotWidth = 400.0
    $plotHeight = 400.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $midX = $plotLeft + $plotWidth / 2.0
    $midY = $plotTop + $plotHeight / 2.0

    $maxChurn = ($profileData | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = 8.0
    $maxBubble = 36.0

    # 象限ラベル
    $quadrants = @(
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.2; Label = '🏠 独立型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.2; Label = '🌟 改善者' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.8; Label = '🏝️ 孤立型' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.8; Label = '💥 破壊者' }
    )

    $svgW = 640
    $svgH = 580
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .quadrant-label { font-size: 13px; fill: #aaa; text-anchor: middle; }
  .author-label { font-size: 11px; fill: #333; text-anchor: middle; }
  .mid-line { stroke: #bdbdbd; stroke-width: 1; stroke-dasharray: 6,4; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">チーム活動プロファイル</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: 他者コード削除介入度（他者変更行数÷削除行数） / Y: 他者コード変更生存率 / 円: 総チャーン</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">他者コード削除介入度</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">他者コード変更生存率</text>' -f [int]($plotTop + $plotHeight / 2.0)))
    # 目盛り
    for ($tick = 0.0; $tick -le 1.01; $tick += 0.25)
    {
        $tx = $plotLeft + $tick * $plotWidth
        $ty = $plotBottom - $tick * $plotHeight
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
    }
    # 象限ラベル
    foreach ($q in $quadrants)
    {
        [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Label)))
    }
    # 全員のバブル
    $colorPalette = $script:DefaultColorPalette
    $sortedByChurn = @($profileData | Sort-Object -Property TotalChurn -Descending)
    for ($ci = 0; $ci -lt $sortedByChurn.Count; $ci++)
    {
        $d = $sortedByChurn[$ci]
        $bx = $plotLeft + $d.InterventionRate * $plotWidth
        $by = $plotBottom - $d.OthersSurvivalRate * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.TotalChurn / $maxChurn)
        $cIdx = $ci % $colorPalette.Count
        $bColor = $colorPalette[$cIdx]
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.55" stroke="{3}" stroke-width="1.2"><title>{4} (介入度:{5:F1}%, 生存率:{6:F1}%, チャーン:{7})</title></circle>' -f $bx, $by, $br, $bColor, (ConvertTo-SvgEscapedText -Text $d.Author), ($d.InterventionRate * 100), ($d.OthersSurvivalRate * 100), [int]$d.TotalChurn))
        [void]$sb.AppendLine(('<text class="author-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f $bx, ($by - $br - 4.0), (ConvertTo-SvgEscapedText -Text $d.Author)))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'team_activity_profile.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Write-ProjectCodeFateChart
{
    <#
    .SYNOPSIS
        プロジェクト全体の追加行数の帰結をドーナッツチャートで可視化する。
    .DESCRIPTION
        全コミッターの追加行数を合算し、その帰結（生存・自己相殺・被他者削除・
        その他消滅）をドーナッツチャートとして描画する。
        既存の team_survived_share.svg が「誰のコードが残ったか」を示すのに対し、
        本チャートは「追加されたコード全体がどこへ行ったか」を示す対のチャート。
        開発完了後の成果物評価として、コードの歩留まりを一目で把握できる。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
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
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }

    # 全作者合計を集計
    $totalAdded = 0.0
    $totalSurvived = 0.0
    $totalSelfCancel = 0.0
    $totalRemovedByOthers = 0.0
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        if ($null -ne $c.'追加行数')
        {
            $totalAdded += [double]$c.'追加行数'
        }
        if ($null -ne $c.'生存行数')
        {
            $totalSurvived += [double]$c.'生存行数'
        }
        if ($null -ne $c.'自己相殺行数')
        {
            $totalSelfCancel += [double]$c.'自己相殺行数'
        }
        if ($null -ne $c.'被他者削除行数')
        {
            $totalRemovedByOthers += [double]$c.'被他者削除行数'
        }
    }
    if ($totalAdded -le 0)
    {
        return
    }
    $totalOther = $totalAdded - ($totalSurvived + $totalSelfCancel + $totalRemovedByOthers)
    if ($totalOther -lt 0)
    {
        Write-Warning ("CodeFate 'その他消滅' が負の値: totalAdded={0}, survived={1}, selfCancel={2}, removedByOthers={3}" -f $totalAdded, $totalSurvived, $totalSelfCancel, $totalRemovedByOthers)
        $totalOther = 0.0
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    $segments = @(
        [pscustomobject]@{ Label = '生存'; Value = $totalSurvived; Color = '#4caf50' }
        [pscustomobject]@{ Label = '自己相殺'; Value = $totalSelfCancel; Color = '#ffc107' }
        [pscustomobject]@{ Label = '被他者削除'; Value = $totalRemovedByOthers; Color = '#f44336' }
        [pscustomobject]@{ Label = 'その他消滅'; Value = $totalOther; Color = '#bdbdbd' }
    )
    # 値が 0 のセグメントを除外
    $segments = @($segments | Where-Object { $_.Value -gt 0 })
    if ($segments.Count -eq 0)
    {
        return
    }

    $svgW = 640
    $svgH = 460
    $cx = 240.0
    $cy = 240.0
    $outerR = 150.0
    $innerR = 90.0
    $legendX = 430.0
    $legendY = 140.0

    $survivalRate = $totalSurvived / $totalAdded

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .center-label { font-size: 13px; fill: #555; text-anchor: middle; }
  .center-value { font-size: 26px; font-weight: bold; fill: #333; text-anchor: middle; }
  .center-sub { font-size: 11px; fill: #888; text-anchor: middle; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">コード帰結サマリー（プロジェクト全体）</text>')
    [void]$sb.AppendLine(('<text class="subtitle" x="20" y="46">追加された {0} 行のうち、最終的にどこへ行ったか</text>' -f [int]$totalAdded))

    # ドーナッツ描画
    $startAngle = -90.0
    for ($i = 0; $i -lt $segments.Count; $i++)
    {
        $seg = $segments[$i]
        $share = $seg.Value / $totalAdded
        $sweepAngle = $share * 360.0
        if ($sweepAngle -lt 0.1)
        {
            continue
        }
        $color = $seg.Color

        $startRad = $startAngle * [Math]::PI / 180.0
        $endRad = ($startAngle + $sweepAngle) * [Math]::PI / 180.0
        $largeArc = if ($sweepAngle -gt 180.0)
        {
            1
        }
        else
        {
            0
        }

        $ox1 = $cx + $outerR * [Math]::Cos($startRad)
        $oy1 = $cy + $outerR * [Math]::Sin($startRad)
        $ox2 = $cx + $outerR * [Math]::Cos($endRad)
        $oy2 = $cy + $outerR * [Math]::Sin($endRad)
        $ix1 = $cx + $innerR * [Math]::Cos($endRad)
        $iy1 = $cy + $innerR * [Math]::Sin($endRad)
        $ix2 = $cx + $innerR * [Math]::Cos($startRad)
        $iy2 = $cy + $innerR * [Math]::Sin($startRad)

        $pathD = ('M {0:F1} {1:F1} A {2:F1} {2:F1} 0 {3} 1 {4:F1} {5:F1} L {6:F1} {7:F1} A {8:F1} {8:F1} 0 {3} 0 {9:F1} {10:F1} Z' -f $ox1, $oy1, $outerR, $largeArc, $ox2, $oy2, $ix1, $iy1, $innerR, $ix2, $iy2)
        $tooltipText = ('{0}: {1} 行 ({2:F1}%)' -f (ConvertTo-SvgEscapedText -Text $seg.Label), [int]$seg.Value, ($share * 100))
        [void]$sb.AppendLine(('<path d="{0}" fill="{1}" stroke="#fff" stroke-width="2"><title>{2}</title></path>' -f $pathD, $color, $tooltipText))

        $startAngle += $sweepAngle
    }

    # 中央テキスト: 生存率
    [void]$sb.AppendLine(('<text class="center-value" x="{0}" y="{1}">{2:F1}%</text>' -f [int]$cx, [int]($cy - 2), ($survivalRate * 100)))
    [void]$sb.AppendLine(('<text class="center-label" x="{0}" y="{1}">コード生存率</text>' -f [int]$cx, [int]($cy + 18)))
    [void]$sb.AppendLine(('<text class="center-sub" x="{0}" y="{1}">{2} / {3} 行</text>' -f [int]$cx, [int]($cy + 34), [int]$totalSurvived, [int]$totalAdded))

    # 凡例
    for ($i = 0; $i -lt $segments.Count; $i++)
    {
        $seg = $segments[$i]
        $ly = $legendY + $i * 40
        $share = $seg.Value / $totalAdded
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="16" height="16" rx="3" fill="{2}"/>' -f [int]$legendX, [int]$ly, $seg.Color))
        $legendLabel = ('{0}: {1} 行 ({2:F1}%)' -f (ConvertTo-SvgEscapedText -Text $seg.Label), [int]$seg.Value, ($share * 100))
        [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">{2}</text>' -f [int]($legendX + 22), [int]($ly + 13), $legendLabel))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'project_code_fate.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Get-ProjectEfficiencyData
{
    <#
    .SYNOPSIS
        ファイル単位のコード効率データを4象限散布図用に抽出する。
    .DESCRIPTION
        X 軸: コード生存率（生存行数 ÷ 追加行数）
        Y 軸: チャーン効率（|純増行数| ÷ 総チャーン）
        バブルサイズ: 総チャーン
        追加行数が 0 または総チャーンが 0 のファイルは除外する。
    .PARAMETER Files
        Get-FileMetric が返すファイル行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として抽出する件数を指定する。0 で全件。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Files,
        [int]$TopNCount = 0
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in @($Files))
    {
        if ($null -eq $f)
        {
            continue
        }
        $added = 0.0
        if ($null -ne $f.'追加行数')
        {
            $added = [double]$f.'追加行数'
        }
        if ($added -le 0)
        {
            continue
        }
        $churn = 0.0
        if ($null -ne $f.'総チャーン')
        {
            $churn = [double]$f.'総チャーン'
        }
        if ($churn -le 0)
        {
            continue
        }
        $survived = 0.0
        if ($null -ne $f.'生存行数 (範囲指定)')
        {
            $survived = [double]$f.'生存行数 (範囲指定)'
        }
        $net = 0.0
        if ($null -ne $f.'純増行数')
        {
            $net = [double]$f.'純増行数'
        }
        $survivalRate = $survived / $added
        if ($survivalRate -gt 1.0)
        {
            Write-Warning ("生存率が1.0を超過: {0} (survived={1}, added={2})" -f [string]$f.'ファイルパス', $survived, $added)
            $survivalRate = 1.0
        }
        $churnEfficiency = [Math]::Abs($net) / $churn
        if ($churnEfficiency -gt 1.0)
        {
            $churnEfficiency = 1.0
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                FilePath = [string]$f.'ファイルパス'
                SurvivalRate = $survivalRate
                ChurnEfficiency = $churnEfficiency
                TotalChurn = $churn
            })
    }
    if ($rows.Count -eq 0)
    {
        return @()
    }
    $sorted = @($rows.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'
            Descending = $true
        }, 'FilePath')
    if ($TopNCount -gt 0 -and $sorted.Count -gt $TopNCount)
    {
        return @($sorted | Select-Object -First $TopNCount)
    }
    return $sorted
}

function Write-ProjectEfficiencyQuadrantChart
{
    <#
    .SYNOPSIS
        ファイル別のコード効率を4象限散布図 SVG として出力する。
    .DESCRIPTION
        X 軸にコード生存率（生存行数÷追加行数）、Y 軸にチャーン効率
        （|純増行数|÷総チャーン）を取り、バブルサイズに総チャーンを反映した
        散布図を生成する。
        右上 = 高効率安定（生存率もチャーン効率も高い理想的なファイル）
        左上 = 無駄な変動（効率は高いが最終的にコードが残らない）
        右下 = 過修正安定（コードは残るが手戻りが多い）
        左下 = 高リスク不安定（生存率もチャーン効率も低い問題ファイル）
    .PARAMETER OutDirectory
        SVG ファイルを保存する出力先ディレクトリを指定する。
    .PARAMETER Files
        Get-FileMetric が返すファイル行配列を指定する。
    .PARAMETER TopNCount
        表示するファイル数の上限を指定する。0 で全件。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディング名を指定する。
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
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        Write-Warning 'Write-ProjectEfficiencyQuadrantChart: OutDirectory が空です。'
        return
    }
    $data = @(Get-ProjectEfficiencyData -Files $Files -TopNCount $TopNCount)
    if ($data.Count -eq 0)
    {
        Write-Verbose 'Write-ProjectEfficiencyQuadrantChart: 有効なファイルデータがありません。'
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory -CallerName 'Write-ProjectEfficiencyQuadrantChart'))
    {
        return
    }

    $plotLeft = 80.0
    $plotTop = 72.0
    $plotWidth = 400.0
    $plotHeight = 400.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $svgW = 600
    $svgH = 560

    $maxChurn = ($data | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = 8.0
    $maxBubble = 36.0

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .quadrant-label { font-size: 13px; fill: #aaa; text-anchor: middle; }
  .file-label { font-size: 9px; fill: #333; text-anchor: middle; }
  .mid-line { stroke: #bdbdbd; stroke-width: 1; stroke-dasharray: 6,4; }
  .axis-line { stroke: #999; stroke-width: 1.2; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">ファイル効率マップ（成果 × 生産性）</text>')
    [void]$sb.AppendLine(('<text class="subtitle" x="20" y="46">X: コード生存率 / Y: チャーン効率（|純増|÷チャーン） / バブル: 総チャーン / 上位{0}件</text>' -f $data.Count))

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))

    # 中央線（50%）
    $midX = $plotLeft + $plotWidth * 0.5
    $midY = $plotTop + $plotHeight * 0.5
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
    # 目盛りラベル
    for ($tick = 0.0; $tick -le 1.01; $tick += 0.25)
    {
        $tx = $plotLeft + $tick * $plotWidth
        $ty = $plotBottom - $tick * $plotHeight
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
    }

    # 軸線
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$plotBottom, [int]$plotRight))
    [void]$sb.AppendLine(('<line class="axis-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotBottom))

    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">コード生存率</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 40)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">チャーン効率</text>' -f [int]($plotTop + $plotHeight / 2.0)))

    # 4象限ラベル
    $quadrants = @(
        @{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.15; Text = '🔥 無駄な変動' }
        @{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.15; Text = '✅ 高効率安定' }
        @{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.85; Text = '💀 高リスク不安定' }
        @{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.85; Text = '⚠️ 過修正安定' }
    )
    foreach ($q in $quadrants)
    {
        [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Text)))
    }

    # バブル描画
    foreach ($d in $data)
    {
        $bx = $plotLeft + $d.SurvivalRate * $plotWidth
        $by = $plotBottom - $d.ChurnEfficiency * $plotHeight
        $r = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.TotalChurn / $maxChurn)
        $color = ConvertTo-SvgColor -Rank ([Math]::Max(1, [int]($data.Count * (1.0 - $d.SurvivalRate)))) -MaxRank ([Math]::Max(1, $data.Count))

        $shortName = $d.FilePath
        $slashIdx = $shortName.LastIndexOf('/')
        if ($slashIdx -ge 0)
        {
            $shortName = $shortName.Substring($slashIdx + 1)
        }
        $tooltipText = ('{0} 生存率:{1:F0}% 効率:{2:F0}% チャーン:{3}' -f (ConvertTo-SvgEscapedText -Text $d.FilePath), ($d.SurvivalRate * 100), ($d.ChurnEfficiency * 100), [int]$d.TotalChurn)
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.6" stroke="{3}" stroke-width="1"><title>{4}</title></circle>' -f $bx, $by, $r, $color, $tooltipText))
        $labelText = Get-SvgFittedText -Text $shortName -MaxWidth ($r * 3.0) -FontSize 9.0
        if ($labelText)
        {
            [void]$sb.AppendLine(('<text class="file-label" x="{0:F1}" y="{1:F1}"><title>{2}</title>{3}</text>' -f $bx, ($by + $r + 12.0), $tooltipText, (ConvertTo-SvgEscapedText -Text $labelText)))
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'project_efficiency_quadrant.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Write-ProjectSummaryDashboard
{
    <#
    .SYNOPSIS
        プロジェクト全体の KPI をダッシュボード SVG として描画する。
    .DESCRIPTION
        コミッター・ファイル・コミットの全データを集約し、プロジェクトの全体像を
        カード型レイアウトで1枚の SVG にまとめる。開発完了後の成果報告やレビューで
        「この開発はこうでした」と説明するための一覧ダッシュボード。
        表示項目:
        - 基本数値（コミット数、作者数、ファイル数）
        - 量の概要（追加・削除・純増・総チャーン）
        - コード生存率（ゲージ表示）
        - リワーク率（プロジェクト全体の手戻り度）
        - 所有権集中度（HHI）
        - 平均変更ファイル数/コミット、平均エントロピー
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER FileRows
        Get-FileMetric が返すファイル行配列を指定する。
    .PARAMETER CommitRows
        New-CommitRowFromCommit が返すコミット行配列を指定する。
    .PARAMETER AuthorBorn
        blame ベースの作者別 Born 行数ハッシュテーブルを指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
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
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$FileRows,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$CommitRows,
        [Parameter(Mandatory = $false)]
        [hashtable]$AuthorBorn,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if ((-not $Committers -or @($Committers).Count -eq 0) -and (-not $CommitRows -or @($CommitRows).Count -eq 0))
    {
        return
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    # 集計
    $commitCount = @($CommitRows).Count
    $authorCount = @($Committers).Count
    $fileCount = @($FileRows).Count

    $totalAdded = 0.0
    $totalDeleted = 0.0
    $totalSurvived = 0.0
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        if ($null -ne $c.'追加行数')
        {
            $totalAdded += [double]$c.'追加行数'
        }
        if ($null -ne $c.'削除行数')
        {
            $totalDeleted += [double]$c.'削除行数'
        }
        if ($null -ne $c.'生存行数')
        {
            $totalSurvived += [double]$c.'生存行数'
        }
    }
    $totalNet = $totalAdded - $totalDeleted
    $totalChurn = $totalAdded + $totalDeleted

    # Born 行数（blame ベース）を分母とする
    $totalBorn = 0.0
    if ($null -ne $AuthorBorn)
    {
        foreach ($bv in $AuthorBorn.Values)
        {
            $totalBorn += [double]$bv
        }
    }
    $survivalRate = 0.0
    if ($totalBorn -gt 0)
    {
        $survivalRate = $totalSurvived / $totalBorn
    }
    $reworkRate = 0.0
    if ($totalChurn -gt 0)
    {
        $reworkRate = 1.0 - ([Math]::Abs($totalNet) / $totalChurn)
    }

    # 所有権集中度 (HHI)
    $hhi = 0.0
    $validOwnerCount = 0
    foreach ($c in @($Committers))
    {
        if ($null -eq $c -or $null -eq $c.'所有割合')
        {
            continue
        }
        $ownerShare = [double]$c.'所有割合'
        if ($ownerShare -gt 0)
        {
            $hhi += $ownerShare * $ownerShare
            $validOwnerCount++
        }
    }
    if ($validOwnerCount -le 1)
    {
        $hhi = 1.0
    }

    # コミット平均指標
    $avgFilesPerCommit = 0.0
    $avgEntropy = 0.0
    if ($commitCount -gt 0)
    {
        $sumFiles = 0.0
        $sumEntropy = 0.0
        foreach ($cr in @($CommitRows))
        {
            if ($null -eq $cr)
            {
                continue
            }
            if ($null -ne $cr.'変更ファイル数')
            {
                $sumFiles += [double]$cr.'変更ファイル数'
            }
            if ($null -ne $cr.'エントロピー')
            {
                $sumEntropy += [double]$cr.'エントロピー'
            }
        }
        $avgFilesPerCommit = $sumFiles / [double]$commitCount
        $avgEntropy = $sumEntropy / [double]$commitCount
    }

    # SVG レイアウト
    $svgW = 720
    $svgH = 520
    $cardW = 200
    $cardH = 100
    $gapX = 20
    $gapY = 16
    $startX = 30
    $startY = 70

    # KPI カード定義（3列×3行）
    $cards = @(
        @{ Label = 'コミット数'; Value = [string]$commitCount; Sub = 'FromRev〜ToRev のコミット総数' }
        @{ Label = '作者数'; Value = [string]$authorCount; Sub = 'コミットした開発者のユニーク数' }
        @{ Label = 'ファイル数'; Value = [string]$fileCount; Sub = '変更されたファイルのユニーク数' }
        @{ Label = '追加行数 (diff)'; Value = ('{0:N0}' -f [int]$totalAdded); Sub = '全 diff の + 行合計' }
        @{ Label = '削除行数 (diff)'; Value = ('{0:N0}' -f [int]$totalDeleted); Sub = '全 diff の - 行合計（既存コード削除含む）' }
        @{ Label = '純増行数'; Value = ('{0:N0}' -f [int]$totalNet); Sub = ('diff 追加 - diff 削除 / チャーン: {0:N0}' -f [int]$totalChurn) }
        @{ Label = 'コード生存率'; Value = ('{0:F1}%' -f ($survivalRate * 100)); Sub = ('blame 追跡: 生存/誕生 = {0:N0}/{1:N0}' -f [int]$totalSurvived, [int]$totalBorn) }
        @{ Label = 'リワーク率'; Value = ('{0:F1}%' -f ($reworkRate * 100)); Sub = '1 - |純増| / チャーン（低いほど効率的）' }
        @{ Label = '所有権集中度 (HHI)'; Value = ('{0:F3}' -f $hhi); Sub = ('Σ(所有割合²) / 平均F/C: {0:F1} / エントロピー: {1:F2}' -f $avgFilesPerCommit, $avgEntropy) }
    )

    # 色割り当て
    $cardColors = @('#42a5f5', '#42a5f5', '#42a5f5', '#66bb6a', '#ef5350', '#ffa726', '#4caf50', '#ff7043', '#ab47bc')

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .card-label { font-size: 11px; fill: #fff; font-weight: bold; }
  .card-value { font-size: 28px; font-weight: bold; fill: #333; }
  .card-sub { font-size: 10px; fill: #888; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">プロジェクトサマリーダッシュボード</text>')

    for ($i = 0; $i -lt $cards.Count; $i++)
    {
        $col = $i % 3
        $row = [Math]::Floor($i / 3)
        $cx = $startX + $col * ($cardW + $gapX)
        $cy = $startY + $row * ($cardH + $gapY)
        $card = $cards[$i]
        $color = $cardColors[$i % $cardColors.Count]

        # カード背景
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="8" fill="#fff" stroke="#e0e0e0" stroke-width="1"/>' -f [int]$cx, [int]$cy, $cardW, $cardH))
        # ヘッダーバー
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="24" rx="8" fill="{3}"/>' -f [int]$cx, [int]$cy, $cardW, $color))
        [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="12" fill="{3}"/>' -f [int]$cx, [int]($cy + 12), $cardW, $color))
        # ラベル
        [void]$sb.AppendLine(('<text class="card-label" x="{0}" y="{1}">{2}</text>' -f [int]($cx + 10), [int]($cy + 17), (ConvertTo-SvgEscapedText -Text $card.Label)))
        # 値
        [void]$sb.AppendLine(('<text class="card-value" x="{0}" y="{1}">{2}</text>' -f [int]($cx + 10), [int]($cy + 62), (ConvertTo-SvgEscapedText -Text $card.Value)))
        # サブ情報
        if ($card.Sub)
        {
            [void]$sb.AppendLine(('<text class="card-sub" x="{0}" y="{1}">{2}</text>' -f [int]($cx + 10), [int]($cy + 80), (ConvertTo-SvgEscapedText -Text $card.Sub)))
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'project_summary_dashboard.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

function Write-ContributorBalanceChart
{
    <#
    .SYNOPSIS
        コミッター別の投入量と最終成果を左右対称バタフライチャートで描画する。
    .DESCRIPTION
        左側に総チャーン（投入量）、右側に生存行数（最終成果）を横棒で描画し、
        中央に作者名を配置する。投入に対して成果が少ない作者は視覚的に非対称になり、
        チームの貢献バランスを一目で把握できる。
        開発完了後の「誰がどれだけ投入し、どれだけ成果として残ったか」を示す。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER TopNCount
        総チャーン上位として表示する件数を指定する。0 で全件。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
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
        [int]$TopNCount = 0,
        [Parameter(Mandatory = $false)]
        [string]$EncodingName = 'UTF-8'
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return
    }

    # データ抽出
    $data = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Committers))
    {
        if ($null -eq $c)
        {
            continue
        }
        $churn = 0.0
        if ($null -ne $c.'総チャーン')
        {
            $churn = [double]$c.'総チャーン'
        }
        $survived = 0.0
        if ($null -ne $c.'生存行数')
        {
            $survived = [double]$c.'生存行数'
        }
        if ($churn -le 0 -and $survived -le 0)
        {
            continue
        }
        [void]$data.Add([pscustomobject][ordered]@{
                Author = (Get-NormalizedAuthorName -Author ([string]$c.'作者'))
                TotalChurn = $churn
                Survived = $survived
            })
    }
    if ($data.Count -eq 0)
    {
        return
    }
    $sorted = @($data.ToArray() | Sort-Object -Property @{Expression = 'TotalChurn'; Descending = $true }, 'Author')
    if ($TopNCount -gt 0 -and $sorted.Count -gt $TopNCount)
    {
        $sorted = @($sorted | Select-Object -First $TopNCount)
    }
    if (-not (Initialize-OutputDirectory -Path $OutDirectory))
    {
        return
    }

    $n = $sorted.Count
    $barHeight = 28
    $barGap = 8
    $centerX = 340.0
    $barMaxW = 240.0
    $marginTop = 80
    $marginBottom = 40

    $maxVal = 1.0
    foreach ($d in $sorted)
    {
        if ($d.TotalChurn -gt $maxVal)
        {
            $maxVal = $d.TotalChurn
        }
        if ($d.Survived -gt $maxVal)
        {
            $maxVal = $d.Survived
        }
    }

    $svgW = 720
    $svgH = $marginTop + $n * ($barHeight + $barGap) + $marginBottom + 20

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $svgW, $svgH))
    [void]$sb.Append((Get-SvgCommonStyle -AdditionalStyles @'
  .author-label { font-size: 12px; fill: #333; text-anchor: middle; dominant-baseline: central; }
  .bar-value { font-size: 10px; fill: #555; dominant-baseline: central; }
  .header-label { font-size: 11px; fill: #666; font-weight: bold; text-anchor: middle; }
  .legend-text { font-size: 11px; fill: #333; }
'@))
    [void]$sb.AppendLine('<rect width="100%" height="100%" fill="#fafafa"/>')
    [void]$sb.AppendLine('<text class="title" x="20" y="28">投入量 vs 最終成果（コミッター別バランス）</text>')
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">左: 総チャーン（投入量） / 右: 生存行数（最終成果） / 非対称 = 歩留まり差</text>')

    # ヘッダー
    $headerY = $marginTop - 16
    [void]$sb.AppendLine(('<text class="header-label" x="{0}" y="{1}">← 総チャーン（投入）</text>' -f [int]($centerX - $barMaxW / 2.0), [int]$headerY))
    [void]$sb.AppendLine(('<text class="header-label" x="{0}" y="{1}">生存行数（成果）→</text>' -f [int]($centerX + $barMaxW / 2.0), [int]$headerY))

    # 中央線
    [void]$sb.AppendLine(('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#bdbdbd" stroke-width="1" stroke-dasharray="4,3"/>' -f [int]$centerX, [int]($marginTop - 6), [int]($marginTop + $n * ($barHeight + $barGap))))

    $churnColor = '#ff7043'
    $survivedColor = '#4caf50'

    for ($i = 0; $i -lt $n; $i++)
    {
        $d = $sorted[$i]
        $yBase = $marginTop + $i * ($barHeight + $barGap)
        $yCtr = $yBase + $barHeight / 2.0

        # 左バー (チャーン) — 右から左へ伸びる
        $churnW = 0.0
        if ($maxVal -gt 0)
        {
            $churnW = ($d.TotalChurn / $maxVal) * $barMaxW
        }
        $churnX = $centerX - 4 - $churnW
        if ($churnW -gt 0)
        {
            $tooltip = ('総チャーン: {0:N0}' -f [int]$d.TotalChurn)
            [void]$sb.AppendLine(('<rect x="{0:F1}" y="{1}" width="{2:F1}" height="{3}" rx="4" fill="{4}" fill-opacity="0.8"><title>{5}</title></rect>' -f $churnX, [int]$yBase, $churnW, $barHeight, $churnColor, (ConvertTo-SvgEscapedText -Text $tooltip)))
            [void]$sb.AppendLine(('<text class="bar-value" x="{0:F1}" y="{1:F0}" text-anchor="end">{2:N0}</text>' -f ($churnX - 4), $yCtr, [int]$d.TotalChurn))
        }

        # 右バー (生存行数) — 左から右へ伸びる
        $survW = 0.0
        if ($maxVal -gt 0)
        {
            $survW = ($d.Survived / $maxVal) * $barMaxW
        }
        $survX = $centerX + 4
        if ($survW -gt 0)
        {
            $tooltip = ('生存行数: {0:N0}' -f [int]$d.Survived)
            [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2:F1}" height="{3}" rx="4" fill="{4}" fill-opacity="0.8"><title>{5}</title></rect>' -f [int]$survX, [int]$yBase, $survW, $barHeight, $survivedColor, (ConvertTo-SvgEscapedText -Text $tooltip)))
            [void]$sb.AppendLine(('<text class="bar-value" x="{0:F1}" y="{1:F0}">{2:N0}</text>' -f ($survX + $survW + 4), $yCtr, [int]$d.Survived))
        }

        # 中央: 作者名
        [void]$sb.AppendLine(('<text class="author-label" x="{0}" y="{1:F0}">{2}</text>' -f [int]$centerX, $yCtr, (ConvertTo-SvgEscapedText -Text $d.Author)))
    }

    # 凡例
    $legendY = $marginTop + $n * ($barHeight + $barGap) + 16
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="14" height="14" rx="3" fill="{2}"/>' -f [int]($centerX - 120), [int]$legendY, $churnColor))
    [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">総チャーン（投入量）</text>' -f [int]($centerX - 102), [int]($legendY + 12)))
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="14" height="14" rx="3" fill="{2}"/>' -f [int]($centerX + 30), [int]$legendY, $survivedColor))
    [void]$sb.AppendLine(('<text class="legend-text" x="{0}" y="{1}">生存行数（最終成果）</text>' -f [int]($centerX + 48), [int]($legendY + 12)))

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'contributor_balance.svg') -Content $sb.ToString() -EncodingName $EncodingName
}

# endregion PlantUML 出力
# region SVG 出力
function Get-SvgCommonStyle
{
    <#
    .SYNOPSIS
        SVG チャートで共通利用するスタイルブロックを返す。
    .DESCRIPTION
        各チャート関数で重複していた CSS ブロックを共通化する。
        AdditionalStyles パラメータで追加 CSS ルールを差し込める。
    .PARAMETER AdditionalStyles
        共通スタイルに追加する CSS ルール文字列を指定する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AdditionalStyles = ''
    )
    $base = @'
  text { font-family: "Segoe UI", "Meiryo UI", sans-serif; }
  .title { font-size: 16px; font-weight: bold; fill: #333; }
  .subtitle { font-size: 11px; fill: #888; }
  .axis-label { font-size: 12px; fill: #555; }
  .tick-label { font-size: 10px; fill: #888; }
  .grid-line { stroke: #e0e0e0; stroke-width: 0.6; }
  .legend-text { font-size: 12px; fill: #333; }
'@
    if ([string]::IsNullOrWhiteSpace($AdditionalStyles))
    {
        return "<defs><style>`n${base}`n</style></defs>`n"
    }
    return "<defs><style>`n${base}`n${AdditionalStyles}`n</style></defs>`n"
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

    if ([string]::IsNullOrWhiteSpace($Text))
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

    if ([string]::IsNullOrWhiteSpace($Text))
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
    if ([string]::IsNullOrWhiteSpace($ellipsisText))
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
        [void]$buffer.Add($character)
        $currentWidth += $charWidth
    }

    if ($buffer.Count -eq 0)
    {
        return $ellipsisText
    }

    return ((-join $buffer.ToArray()) + $ellipsisText)
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
            $resolvedFile = Resolve-PathByRenameMap -FilePath ([string]$f) -RenameMap $RenameMap
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
        [void]$ga.Add('--username')
        [void]$ga.Add($Username)
    }
    if ($Password)
    {
        $plain = ConvertTo-PlainText -SecureValue $Password
        if ($plain)
        {
            [void]$ga.Add('--password')
            [void]$ga.Add($plain)
        }
    }
    if ($NonInteractive)
    {
        [void]$ga.Add('--non-interactive')
    }
    if ($TrustServerCert)
    {
        [void]$ga.Add('--trust-server-cert')
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
    .PARAMETER IgnoreWhitespace
        指定時は空白・改行コード差分を無視する。
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$IgnoreWhitespace)
    $diffArgs = New-Object 'System.Collections.Generic.List[string]'
    [void]$diffArgs.Add('diff')
    [void]$diffArgs.Add('--internal-diff')
    [void]$diffArgs.Add('--ignore-properties')
    if ($IgnoreWhitespace)
    {
        [void]$diffArgs.Add('--extensions')
        [void]$diffArgs.Add('--ignore-space-change --ignore-eol-style')
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
    if ([System.IO.File]::Exists($cacheFile))
    {
        return [System.IO.File]::ReadAllText($cacheFile, [System.Text.Encoding]::UTF8)
    }

    $fetchArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $DiffArguments)
    {
        [void]$fetchArgs.Add([string]$item)
    }
    [void]$fetchArgs.Add('-c')
    [void]$fetchArgs.Add([string]$Revision)
    [void]$fetchArgs.Add($TargetUrl)
    $diffText = Invoke-SvnCommand -Arguments $fetchArgs.ToArray() -ErrorContext ("svn diff -c {0}" -f $Revision)
    [System.IO.File]::WriteAllText($cacheFile, $diffText, [System.Text.Encoding]::UTF8)
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
        if (Test-ShouldCountFile -FilePath $path -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        {
            [void]$filtered.Add([pscustomobject]@{
                    Path = $path
                    Action = [string]$pathEntry.Action
                    CopyFromPath = [string]$pathEntry.CopyFromPath
                    CopyFromRev = $pathEntry.CopyFromRev
                    IsDirectory = $false
                })
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
                    [void]$sourceItems.Add([string]$item)
                }
                else
                {
                    [void]$sourceItems.Add($item)
                }
            }
        }
        else
        {
            if ($AsString)
            {
                [void]$sourceItems.Add([string]$sourceValue)
            }
            else
            {
                [void]$sourceItems.Add($sourceValue)
            }
        }
    }

    $targetValue = $TargetStat.$PropertyName
    if ($targetValue -is [System.Collections.IList])
    {
        $targetValue.Clear()
        foreach ($item in $sourceItems.ToArray())
        {
            [void]$targetValue.Add($item)
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
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$Commit, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
    $deletedSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        if (([string]$pathEntry.Action).ToUpperInvariant() -eq 'D')
        {
            [void]$deletedSet.Add((ConvertTo-PathKey -Path ([string]$pathEntry.Path)))
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
            [void]$compareArguments.Add([string]$item)
        }
        [void]$compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $oldPath + '@' + [string]$copyRev))
        [void]$compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $newPath + '@' + [string]$Revision))

        $realDiff = Invoke-SvnCommand -Arguments $compareArguments.ToArray() -ErrorContext ("svn diff rename pair r{0} {1}->{2}" -f $Revision, $oldPath, $newPath)
        $realParsed = ConvertFrom-SvnUnifiedDiff -DiffText $realDiff -DetailLevel 2

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
        # 早期フィルタスキップ: 拡張子・パスフィルタを diff 取得前に適用し、
        # 対象ファイルが0件のコミットは svn diff の並列取得キューに入れない。
        # ドキュメントのみ変更等、対象外コミットが多いリポジトリでネットワーク往復を大幅に削減する。
        $filteredChangedPaths = @(Get-FilteredChangedPathEntry -ChangedPaths @($commit.ChangedPaths) -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        $commit.ChangedPathsFiltered = $filteredChangedPaths
        if ($filteredChangedPaths.Count -le 0)
        {
            continue
        }
        [void]$phaseAItems.Add([pscustomobject]@{
                Revision = $revision
                CacheDir = $CacheDir
                TargetUrl = $TargetUrl
                DiffArguments = @($DiffArguments)
            })
    }

    $phaseAResults = @()
    if ($phaseAItems.Count -gt 0)
    {
        $phaseAWorker = {
            param($Item, $Index)
            [void]$Index # Required by Invoke-ParallelWork contract
            $diffText = Get-CachedOrFetchDiffText -CacheDir $Item.CacheDir -Revision ([int]$Item.Revision) -TargetUrl $Item.TargetUrl -DiffArguments @($Item.DiffArguments)
            $rawDiffByPath = ConvertFrom-SvnUnifiedDiff -DiffText $diffText -DetailLevel 2
            [pscustomobject]@{
                Revision = [int]$Item.Revision
                RawDiffByPath = $rawDiffByPath
            }
        }
        $phaseAResults = @(Invoke-ParallelWork -InputItems $phaseAItems.ToArray() -WorkerScript $phaseAWorker -MaxParallel $Parallel -RequiredFunctions @(
                'ConvertTo-PathKey',
                'Get-Sha1Hex',
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

    $commitTotal = @($Commits).Count
    $commitIdx = 0
    foreach ($commit in @($Commits))
    {
        $pct = [Math]::Min(100, [int](($commitIdx / [Math]::Max(1, $commitTotal)) * 100))
        Write-Progress -Id 2 -Activity 'コミット差分の統合' -Status ('{0}/{1}' -f ($commitIdx + 1), $commitTotal) -PercentComplete $pct
        $revision = [int]$commit.Revision
        $rawDiffByPath = @{}
        if ($rawDiffByRevision.ContainsKey($revision))
        {
            $rawDiffByPath = $rawDiffByRevision[$revision]
        }
        $filteredDiffByPath = @{}
        foreach ($path in $rawDiffByPath.Keys)
        {
            if (Test-ShouldCountFile -FilePath $path -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
            {
                $filteredDiffByPath[$path] = $rawDiffByPath[$path]
            }
        }
        $commit.FileDiffStats = $filteredDiffByPath

        if ($null -eq $commit.ChangedPathsFiltered)
        {
            $commit.ChangedPathsFiltered = Get-FilteredChangedPathEntry -ChangedPaths @($commit.ChangedPaths) -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns
        }

        $allowedFilePathSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($pathEntry in @($commit.ChangedPathsFiltered))
        {
            $path = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
            if ($path)
            {
                [void]$allowedFilePathSet.Add($path)
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

        Update-RenamePairDiffStat -Commit $commit -Revision $revision -TargetUrl $TargetUrl -DiffArguments $DiffArguments
        Set-CommitDerivedMetric -Commit $commit
        $commitIdx++
    }
    Write-Progress -Id 2 -Activity 'コミット差分の統合' -Completed
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
                [void]$lookupErrors.Add(([string]$lookup + ': ' + $_.Exception.Message))
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
        [int]$Parallel = 1,
        [hashtable]$RenameMap = @{}
    )
    if (@($FileRows).Count -le 0)
    {
        return
    }

    $renameMap = if ($RenameMap.Count -gt 0)
    {
        $RenameMap
    }
    else
    {
        Get-RenameMap -Commits $Commits
    }
    $strictDetail = Get-ExactDeathAttribution -Commits $Commits -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -RenameMap $renameMap -Parallel $Parallel
    if ($null -eq $strictDetail)
    {
        throw "Strict death attribution returned null."
    }

    $authorSurvived = $strictDetail.AuthorSurvived
    $authorOwned = @{}
    $ownedTotal = 0
    $blameByFile = @{}
    $ownershipTargets = @(Get-AllRepositoryFile -TargetUrl $TargetUrl -Revision $ToRevision -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
    $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($file in $ownershipTargets)
    {
        [void]$existingFileSet.Add([string]$file)
    }
    if ($Parallel -le 1)
    {
        $ownerTotal = $ownershipTargets.Count
        $ownerIdx = 0
        foreach ($file in $ownershipTargets)
        {
            $pct = [Math]::Min(100, [int](($ownerIdx / [Math]::Max(1, $ownerTotal)) * 100))
            Write-Progress -Id 5 -Activity '所有権 blame 解析' -Status ('{0}/{1}' -f ($ownerIdx + 1), $ownerTotal) -PercentComplete $pct
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
            $ownerIdx++
        }
        Write-Progress -Id 5 -Activity '所有権 blame 解析' -Completed
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
            [void]$Index # Required by Invoke-ParallelWork contract
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
                'Test-SvnMissingTargetError',
                'Invoke-SvnCommandAllowMissingTarget',
                'Get-EmptyBlameResult',
                'Get-BlameMemoryCacheKey',
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

    return [pscustomobject]@{
        KillMatrix = $strictDetail.KillMatrix
        AuthorSelfDead = $strictDetail.AuthorSelfDead
        AuthorBorn = $strictDetail.AuthorBorn
    }
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
        Committer = @('作者', 'コミット数', '活動日数', '変更ファイル数', '変更ディレクトリ数', '追加行数', '削除行数', '純増行数', '総チャーン', 'コミットあたりチャーン', '削除対追加比', 'チャーン対純増比', 'リワーク率', 'バイナリ変更回数', '追加アクション数', '変更アクション数', '削除アクション数', '置換アクション数', '生存行数', $script:ColDeadAdded, '所有行数', '所有割合', '自己相殺行数', '自己差戻行数', '他者差戻行数', '被他者削除行数', '同一箇所反復編集数', 'ピンポン回数', '内部移動行数', $script:ColSelfDead, $script:ColOtherDead, '他者コード変更行数', '他者コード変更生存行数', '他者コード変更生存率', 'ピンポン率', '変更エントロピー', '平均共同作者数', '最大共同作者数', 'メッセージ総文字数', 'メッセージ平均文字数', '課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
        File = @('ファイルパス', 'コミット数', '作者数', '追加行数', '削除行数', '純増行数', '総チャーン', 'バイナリ変更回数', '作成回数', '削除回数', '置換回数', '初回変更リビジョン', '最終変更リビジョン', '平均変更間隔日数', '活動期間日数', '生存行数 (範囲指定)', $script:ColDeadAdded, '最多作者チャーン占有率', '最多作者blame占有率', '自己相殺行数 (合計)', '他者差戻行数 (合計)', '同一箇所反復編集数 (合計)', 'ピンポン回数 (合計)', '内部移動行数 (合計)', 'ホットスポットスコア', 'ホットスポット順位')
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
    .PARAMETER SvnVersion
        SvnVersion の値を指定する。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    .PARAMETER TopNCount
        上位抽出件数を指定する。
    .PARAMETER Encoding
        出力時に使用する文字エンコーディングを指定する。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER FileRows
        更新対象となる出力行オブジェクト配列を指定する。
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER IncludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludePaths
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER IncludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER ExcludeExtensions
        対象を絞り込むための包含または除外条件を指定する。
    .PARAMETER NonInteractive
        NonInteractive の値を指定する。
    .PARAMETER TrustServerCert
        TrustServerCert の値を指定する。
    .PARAMETER IgnoreWhitespace
        指定時は空白・改行コード差分を無視する。
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
        [string]$SvnVersion,
        [int]$Parallel,
        [int]$TopNCount,
        [string]$Encoding,
        [object[]]$Commits,
        [object[]]$FileRows,
        [string]$OutDirectory,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [switch]$NonInteractive,
        [switch]$TrustServerCert,
        [switch]$IgnoreWhitespace
    )
    return [ordered]@{
        StartTime = $StartTime.ToString('o')
        EndTime = $EndTime.ToString('o')
        DurationSeconds = Format-MetricValue -Value ((New-TimeSpan -Start $StartTime -End $EndTime).TotalSeconds)
        RepoUrl = $TargetUrl
        FromRev = $FromRevision
        ToRev = $ToRevision
        SvnExecutable = $script:SvnExecutable
        SvnVersion = $SvnVersion
        StrictMode = $true
        Parallel = $Parallel
        TopNCount = $TopNCount
        Encoding = $Encoding
        CommitCount = @($Commits).Count
        FileCount = @($FileRows).Count
        OutputDirectory = (Resolve-Path $OutDirectory).Path
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
            NonInteractive = [bool]$NonInteractive
            TrustServerCert = [bool]$TrustServerCert
            IgnoreWhitespace = [bool]$IgnoreWhitespace
        }
        Outputs = [ordered]@{
            CommittersCsv = 'committers.csv'
            FilesCsv = 'files.csv'
            CommitsCsv = 'commits.csv'
            CouplingsCsv = 'couplings.csv'
            KillMatrixCsv = 'kill_matrix.csv'
            RunMetaJson = 'run_meta.json'
            ContributorsPlantUml = 'contributors_summary.puml'
            HotspotsPlantUml = 'hotspots.puml'
            CoChangePlantUml = 'cochange_network.puml'
            FileHotspotSvg = 'file_hotspot.svg'
            FileQualityScatterSvg = 'file_quality_scatter.svg'
            CommitterOutcomeCharts = 'committer_outcome_*.svg'
            CommitterOutcomeCombinedSvg = 'committer_outcome_combined.svg'
            CommitterScatterCharts = 'committer_scatter_*.svg'
            CommitterScatterCombinedSvg = 'committer_scatter_combined.svg'
            SurvivedShareDonutSvg = 'team_survived_share.svg'
            TeamInteractionHeatmapSvg = 'team_interaction_heatmap.svg'
            TeamActivityProfileSvg = 'team_activity_profile.svg'
            CommitTimelineSvg = 'commit_timeline.svg'
            CommitScatterSvg = 'commit_scatter.svg'
            ProjectCodeFateSvg = 'project_code_fate.svg'
            ProjectEfficiencyQuadrantSvg = 'project_efficiency_quadrant.svg'
            ProjectSummaryDashboardSvg = 'project_summary_dashboard.svg'
            ContributorBalanceSvg = 'contributor_balance.svg'
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
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    #>
    [CmdletBinding()]
    param([string]$TargetUrl, [int]$FromRevision, [int]$ToRevision, [object[]]$Commits, [object[]]$FileRows, [string]$OutDirectory)
    $phaseLabel = 'StrictMode'
    Write-Host ''
    Write-Host ("===== NarutoCode {0} =====" -f $phaseLabel)
    Write-Host ("Repo         : {0}" -f $TargetUrl)
    Write-Host ("Range        : r{0} -> r{1}" -f $FromRevision, $ToRevision)
    Write-Host ("Commits      : {0}" -f @($Commits).Count)
    Write-Host ("Files        : {0}" -f @($FileRows).Count)
    Write-Host ("OutDir       : {0}" -f (Resolve-Path $OutDirectory).Path)
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
    if ($FromRevision -gt $ToRevision)
    {
        $tmp = $FromRevision
        $FromRevision = $ToRevision
        $ToRevision = $tmp
    }
    if (-not $OutDirectory)
    {
        $OutDirectory = Join-Path (Get-Location) 'NarutoCode_out'
    }

    # Resolve relative OutDirectory to absolute path based on PowerShell $PWD
    $OutDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDirectory)
    $cacheDir = Join-Path $OutDirectory 'cache'
    New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null

    $IncludeExtensions = ConvertTo-NormalizedExtension -Extensions $IncludeExtensions
    $ExcludeExtensions = ConvertTo-NormalizedExtension -Extensions $ExcludeExtensions
    $IncludePaths = ConvertTo-NormalizedPatternList -Patterns $IncludePaths
    $ExcludePaths = ConvertTo-NormalizedPatternList -Patterns $ExcludePaths

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
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 2/8: SVN ログの取得' -PercentComplete 5
    $logText = Invoke-SvnCommand -Arguments @('log', '--xml', '--verbose', '-r', "$FromRevision`:$ToRevision", $targetUrl) -ErrorContext 'svn log'
    $commits = @(ConvertFrom-SvnLogXml -XmlText $logText)

    # --- ステップ 3: 差分の取得とコミット単位の差分統計構築 ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 3/8: 差分の取得と統計構築' -PercentComplete 15
    $diffArgs = Get-SvnDiffArgumentList -IgnoreWhitespace:$IgnoreWhitespace
    $revToAuthor = Initialize-CommitDiffData -Commits $commits -CacheDir $cacheDir -TargetUrl $targetUrl -DiffArguments $diffArgs -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths -Parallel $Parallel

    # --- ステップ 3.5: リネームマップの構築（基本メトリクスと strict 帰属の両方で使用） ---
    $renameMap = Get-RenameMap -Commits $commits

    # --- ステップ 4: 基本メトリクス算出（コミッター / ファイル / カップリング / コミット） ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 4/8: 基本メトリクス算出' -PercentComplete 35
    $committerRows = @(Get-CommitterMetric -Commits $commits -RenameMap $renameMap)
    $fileRows = @(Get-FileMetric -Commits $commits -RenameMap $renameMap)
    # couplings.csv は常に全件を出力し、TopN は可視化側でのみ適用する。
    $couplingRows = @(Get-CoChangeMetric -Commits $commits -TopNCount 0 -RenameMap $renameMap)
    $commitRows = @(New-CommitRowFromCommit -Commits $commits)

    # --- ステップ 5: Strict 死亡帰属（blame ベースの行追跡） ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 5/8: Strict 帰属解析' -PercentComplete 45
    $strictResult = Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl $targetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $cacheDir -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -FileRows $fileRows -CommitterRows $committerRows -Parallel $Parallel -RenameMap $renameMap

    # --- ステップ 6: CSV レポート出力 ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 6/8: CSV レポート出力' -PercentComplete 80
    $headers = Get-MetricHeader
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'committers.csv') -Rows $committerRows -Headers $headers.Committer -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'files.csv') -Rows $fileRows -Headers $headers.File -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'commits.csv') -Rows $commitRows -Headers $headers.Commit -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'couplings.csv') -Rows $couplingRows -Headers $headers.Coupling -EncodingName $Encoding
    if ($null -ne $strictResult)
    {
        Write-KillMatrixCsv -OutDirectory $OutDirectory -KillMatrix $strictResult.KillMatrix -AuthorSelfDead $strictResult.AuthorSelfDead -Committers $committerRows -EncodingName $Encoding
    }
    # --- ステップ 7: 可視化出力 ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 7/8: 可視化出力' -PercentComplete 88
    Write-PlantUmlFile -OutDirectory $OutDirectory -Committers $committerRows -Files $fileRows -Couplings $couplingRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-FileBubbleChart -OutDirectory $OutDirectory -Files $fileRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-CommitterOutcomeChart -OutDirectory $OutDirectory -Committers $committerRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-CommitterScatterChart -OutDirectory $OutDirectory -Committers $committerRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-SurvivedShareDonutChart -OutDirectory $OutDirectory -Committers $committerRows -EncodingName $Encoding
    if ($null -ne $strictResult)
    {
        Write-TeamInteractionHeatMap -OutDirectory $OutDirectory -KillMatrix $strictResult.KillMatrix -AuthorSelfDead $strictResult.AuthorSelfDead -Committers $committerRows -EncodingName $Encoding
    }
    Write-TeamActivityProfileChart -OutDirectory $OutDirectory -Committers $committerRows -EncodingName $Encoding
    Write-FileQualityScatterChart -OutDirectory $OutDirectory -Files $fileRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-CommitTimelineChart -OutDirectory $OutDirectory -Commits $commitRows -EncodingName $Encoding
    Write-CommitScatterChart -OutDirectory $OutDirectory -Commits $commitRows -EncodingName $Encoding
    Write-ProjectCodeFateChart -OutDirectory $OutDirectory -Committers $committerRows -EncodingName $Encoding
    Write-ProjectEfficiencyQuadrantChart -OutDirectory $OutDirectory -Files $fileRows -TopNCount $TopNCount -EncodingName $Encoding
    Write-ProjectSummaryDashboard -OutDirectory $OutDirectory -Committers $committerRows -FileRows $fileRows -CommitRows $commitRows -AuthorBorn $strictResult.AuthorBorn -EncodingName $Encoding
    Write-ContributorBalanceChart -OutDirectory $OutDirectory -Committers $committerRows -TopNCount $TopNCount -EncodingName $Encoding

    # --- ステップ 8: 実行メタデータとサマリーの書き出し ---
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 8/8: メタデータ出力' -PercentComplete 95
    $finishedAt = Get-Date
    $meta = New-RunMetaData -StartTime $startedAt -EndTime $finishedAt -TargetUrl $targetUrl -FromRevision $FromRevision -ToRevision $ToRevision -SvnVersion $svnVersion -Parallel $Parallel -TopNCount $TopNCount -Encoding $Encoding -Commits $commits -FileRows $fileRows -OutDirectory $OutDirectory -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -IgnoreWhitespace:$IgnoreWhitespace
    Write-JsonFile -Data $meta -FilePath (Join-Path $OutDirectory 'run_meta.json') -Depth 12 -EncodingName $Encoding

    Write-Progress -Id 0 -Activity 'NarutoCode' -Completed
    Write-RunSummary -TargetUrl $targetUrl -FromRevision $FromRevision -ToRevision $ToRevision -Commits $commits -FileRows $fileRows -OutDirectory $OutDirectory

    [pscustomobject]@{
        OutDirectory = (Resolve-Path $OutDirectory).Path
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
