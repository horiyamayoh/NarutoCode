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
.PARAMETER ExcludeCommentOnlyLines
    指定時はコメント専用行（コメント以外のコードを含まない行）を集計対象から除外する。
    拡張子ごとに組み込みのコメント記法プロファイルを適用し、全メトリクス（strict/hunk 含む）へ反映する。
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
    [switch]$ExcludeCommentOnlyLines,
    [switch]$NoProgress
)

# Suppress progress output when -NoProgress is specified
if ($NoProgress)
{
    $ProgressPreference = 'SilentlyContinue'
}

# region Error and Diagnostics
function New-NarutoResultSuccess
{
    <#
    .SYNOPSIS
        成功状態の NarutoResult DTO を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $Data = $null,
        [string]$Message = '',
        [string]$ErrorCode = 'OK',
        [hashtable]$Context = @{}
    )
    return [pscustomobject]@{
        IsSuccess = $true
        Status = 'Success'
        ErrorCode = $ErrorCode
        Message = $Message
        Data = $Data
        Context = if ($null -eq $Context)
        {
            @{}
        }
        else
        {
            $Context
        }
    }
}
function New-NarutoResultSkipped
{
    <#
    .SYNOPSIS
        スキップ状態の NarutoResult DTO を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $Data = $null,
        [string]$Message,
        [string]$ErrorCode,
        [hashtable]$Context = @{}
    )
    return [pscustomobject]@{
        IsSuccess = $false
        Status = 'Skipped'
        ErrorCode = $ErrorCode
        Message = $Message
        Data = $Data
        Context = if ($null -eq $Context)
        {
            @{}
        }
        else
        {
            $Context
        }
    }
}
function New-NarutoResultFailure
{
    <#
    .SYNOPSIS
        失敗状態の NarutoResult DTO を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $Data = $null,
        [string]$Message,
        [string]$ErrorCode,
        [hashtable]$Context = @{}
    )
    return [pscustomobject]@{
        IsSuccess = $false
        Status = 'Failure'
        ErrorCode = $ErrorCode
        Message = $Message
        Data = $Data
        Context = if ($null -eq $Context)
        {
            @{}
        }
        else
        {
            $Context
        }
    }
}
function Test-NarutoResultSuccess
{
    <#
    .SYNOPSIS
        NarutoResult が成功扱い可能かを判定する。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [object]$Result,
        [switch]$AllowSkipped
    )
    if ($null -eq $Result)
    {
        return $false
    }
    $status = [string]$Result.Status
    if ($status -eq 'Success')
    {
        return $true
    }
    if ($AllowSkipped -and $status -eq 'Skipped')
    {
        return $true
    }
    return $false
}
function ConvertTo-NarutoResultAdapter
{
    <#
    .SYNOPSIS
        旧戻り値契約を NarutoResult へ段階変換する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [object]$InputObject,
        [string]$SuccessCode = 'OK',
        [string]$SkippedCode = 'SKIPPED'
    )
    if ($null -eq $InputObject)
    {
        return (New-NarutoResultSkipped -ErrorCode $SkippedCode -Message '結果が null のためスキップ扱いとしました。')
    }
    if ($InputObject.PSObject.Properties.Match('Status').Count -gt 0 -and $InputObject.PSObject.Properties.Match('ErrorCode').Count -gt 0)
    {
        return $InputObject
    }
    return (New-NarutoResultSuccess -Data $InputObject -ErrorCode $SuccessCode)
}
function Throw-NarutoError
{
    <#
    .SYNOPSIS
        ErrorCode/Category/Context を付与した例外を送出する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param(
        [ValidateSet('INPUT', 'ENV', 'SVN', 'PARSE', 'STRICT', 'OUTPUT', 'INTERNAL')]
        [string]$Category = 'INTERNAL',
        [string]$ErrorCode = 'INTERNAL_UNEXPECTED_ERROR',
        [string]$Message = 'エラーが発生しました。',
        [hashtable]$Context = @{},
        [System.Exception]$InnerException = $null
    )
    $resolvedMessage = if ([string]::IsNullOrWhiteSpace($Message))
    {
        'エラーが発生しました。'
    }
    else
    {
        $Message
    }
    $exception = if ($null -ne $InnerException)
    {
        New-Object System.Exception($resolvedMessage, $InnerException)
    }
    else
    {
        New-Object System.Exception($resolvedMessage)
    }
    $exception.Data['ErrorCode'] = $ErrorCode
    $exception.Data['Category'] = $Category
    $exception.Data['Context'] = if ($null -eq $Context)
    {
        @{}
    }
    else
    {
        $Context
    }
    throw $exception
}
function Get-NarutoErrorInfo
{
    <#
    .SYNOPSIS
        ErrorRecord または Exception から標準化したエラー情報を抽出する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        [Parameter(Mandatory = $true)]
        [object]$ErrorInput
    )
    $errorRecord = $null
    $exception = $null
    if ($ErrorInput -is [System.Management.Automation.ErrorRecord])
    {
        $errorRecord = $ErrorInput
        $exception = $errorRecord.Exception
    }
    elseif ($ErrorInput -is [System.Exception])
    {
        $exception = $ErrorInput
    }
    else
    {
        $exception = New-Object System.Exception([string]$ErrorInput)
    }
    $errorCode = 'INTERNAL_UNEXPECTED_ERROR'
    $category = 'INTERNAL'
    $contextData = @{}
    if ($null -ne $exception -and $null -ne $exception.Data)
    {
        if ($exception.Data.Contains('ErrorCode'))
        {
            $candidate = [string]$exception.Data['ErrorCode']
            if (-not [string]::IsNullOrWhiteSpace($candidate))
            {
                $errorCode = $candidate
            }
        }
        if ($exception.Data.Contains('Category'))
        {
            $candidate = [string]$exception.Data['Category']
            if (-not [string]::IsNullOrWhiteSpace($candidate))
            {
                $category = $candidate
            }
        }
        if ($exception.Data.Contains('Context'))
        {
            $rawContext = $exception.Data['Context']
            if ($rawContext -is [hashtable])
            {
                $contextData = $rawContext
            }
        }
    }
    $scriptStack = ''
    if ($null -ne $errorRecord -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord.ScriptStackTrace))
    {
        $scriptStack = [string]$errorRecord.ScriptStackTrace
    }
    elseif ($null -ne $exception -and $exception.PSObject.Properties.Match('ScriptStackTrace').Count -gt 0)
    {
        $scriptStack = [string]$exception.ScriptStackTrace
    }
    if ($category -eq 'INTERNAL' -and -not [string]::IsNullOrWhiteSpace($errorCode))
    {
        if ($null -ne $Context -and $Context.ContainsKey('ErrorCatalog') -and $Context.ErrorCatalog.ContainsKey($errorCode))
        {
            $category = [string]$Context.ErrorCatalog[$errorCode]
        }
    }
    return [pscustomobject]@{
        ErrorCode = $errorCode
        Category = $category
        Message = if ($null -ne $exception)
        {
            [string]$exception.Message
        }
        else
        {
            ''
        }
        Context = $contextData
        ScriptStackTrace = $scriptStack
        Exception = $exception
    }
}
function Resolve-NarutoExitCode
{
    <#
    .SYNOPSIS
        エラーカテゴリから CLI 終了コードを解決する。
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Category)
    $resolvedCategory = ''
    if ($null -ne $Category)
    {
        $resolvedCategory = [string]$Category
    }
    switch ($resolvedCategory.ToUpperInvariant())
    {
        'INPUT'
        {
            return 10
        }
        'ENV'
        {
            return 20
        }
        'SVN'
        {
            return 30
        }
        'PARSE'
        {
            return 40
        }
        'STRICT'
        {
            return 50
        }
        'OUTPUT'
        {
            return 60
        }
        'INTERNAL'
        {
            return 70
        }
        default
        {
            return 70
        }
    }
}
function Write-NarutoDiagnostic
{
    <#
    .SYNOPSIS
        Warning/Verbose を標準化し Diagnostics 集計を更新する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [ValidateSet('Warning', 'Verbose', 'Information')]
        [string]$Level,
        [string]$ErrorCode = '',
        [string]$Message = '',
        [string]$OutputName = '',
        [hashtable]$Data = @{}
    )
    $prefix = ''
    if (-not [string]::IsNullOrWhiteSpace($ErrorCode))
    {
        $prefix = "[{0}] " -f $ErrorCode
    }
    $text = $prefix + $Message
    if ($Level -eq 'Warning')
    {
        Write-Warning $text
    }
    elseif ($Level -eq 'Verbose')
    {
        Write-Verbose $text
    }
    else
    {
        Write-Host $text
    }
    if ($null -eq $Context -or -not $Context.ContainsKey('Diagnostics'))
    {
        return
    }
    if ($Level -eq 'Warning')
    {
        $Context.Diagnostics.WarningCount = [int]$Context.Diagnostics.WarningCount + 1
        if (-not [string]::IsNullOrWhiteSpace($ErrorCode))
        {
            if (-not $Context.Diagnostics.WarningCodes.ContainsKey($ErrorCode))
            {
                $Context.Diagnostics.WarningCodes[$ErrorCode] = 0
            }
            $Context.Diagnostics.WarningCodes[$ErrorCode] = [int]$Context.Diagnostics.WarningCodes[$ErrorCode] + 1
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputName))
    {
        [void]$Context.Diagnostics.SkippedOutputs.Add([pscustomobject]@{
                Output = $OutputName
                ErrorCode = $ErrorCode
                Message = $Message
                Data = if ($null -eq $Data)
                {
                    @{}
                }
                else
                {
                    $Data
                }
            })
    }
}
function Write-NarutoErrorReport
{
    <#
    .SYNOPSIS
        失敗時の診断情報を error_report.json として保存する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string]$OutDirectory,
        [object]$ErrorInfo,
        [int]$ExitCode
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return (New-NarutoResultSkipped -ErrorCode 'ERROR_REPORT_SKIPPED_NO_OUTDIR' -Message 'OutDirectory が未確定のため error_report.json を出力できません。')
    }
    try
    {
        if (-not (Test-Path -LiteralPath $OutDirectory))
        {
            New-Item -Path $OutDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $reportPath = Join-Path $OutDirectory 'error_report.json'
        $report = [ordered]@{
            Timestamp = (Get-Date).ToString('o')
            ErrorCode = [string]$ErrorInfo.ErrorCode
            Category = [string]$ErrorInfo.Category
            Message = [string]$ErrorInfo.Message
            Context = $ErrorInfo.Context
            ExitCode = [int]$ExitCode
            ScriptStackTrace = [string]$ErrorInfo.ScriptStackTrace
        }
        $json = $report | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($reportPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        return (New-NarutoResultSuccess -Data $reportPath -ErrorCode 'ERROR_REPORT_WRITTEN' -Message 'error_report.json を出力しました。')
    }
    catch
    {
        return (New-NarutoResultFailure -ErrorCode 'ERROR_REPORT_WRITE_FAILED' -Message ("error_report.json の出力に失敗しました: {0}" -f $_.Exception.Message) -Context @{
                OutDirectory = $OutDirectory
            })
    }
}
# endregion Error and Diagnostics

# region Utility
function New-NarutoContext
{
    <#
    .SYNOPSIS
        NarutoCode のスクリプト状態を保持する Context を初期化する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$SvnExecutable = 'svn',
        [string[]]$SvnGlobalArguments = @()
    )

    return @{
        Runtime = @{
            StrictModeEnabled = $true
            SvnExecutable = $SvnExecutable
            SvnGlobalArguments = @($SvnGlobalArguments)
            ExcludeCommentOnlyLines = $false
        }
        Diagnostics = @{
            WarningCount = 0
            WarningCodes = @{}
            SkippedOutputs = (New-Object 'System.Collections.Generic.List[object]')
            Performance = [ordered]@{
                StageSeconds = [ordered]@{}
                StrictBreakdown = [ordered]@{}
                StrictTargetStats = [ordered]@{}
                SvnCommandStats = [ordered]@{}
                PerfGate = [ordered]@{}
            }
        }
        ErrorCatalog = @{
            INPUT_INVALID_ARGUMENT = 'INPUT'
            INPUT_REQUIRED_VALUE_MISSING = 'INPUT'
            INPUT_INVALID_REPO_URL = 'INPUT'
            INPUT_UNSUPPORTED_ENCODING = 'INPUT'
            ENV_SVN_EXECUTABLE_NOT_FOUND = 'ENV'
            SVN_COMMAND_FAILED = 'SVN'
            SVN_TARGET_MISSING = 'SVN'
            SVN_REPOSITORY_VALIDATION_FAILED = 'SVN'
            SVN_VERSION_UNAVAILABLE = 'SVN'
            PARSE_XML_FAILED = 'PARSE'
            PARSE_SVN_LOG_FAILED = 'PARSE'
            STRICT_ANALYSIS_FAILED = 'STRICT'
            STRICT_BLAME_LOOKUP_FAILED = 'STRICT'
            STRICT_BLAME_ATTRIBUTION_FAILED = 'STRICT'
            STRICT_HUNK_ANALYSIS_FAILED = 'STRICT'
            STRICT_OWNERSHIP_BLAME_FAILED = 'STRICT'
            STRICT_OWNERSHIP_BLAME_SKIPPED = 'STRICT'
            STRICT_DEATH_ATTRIBUTION_NULL = 'STRICT'
            STRICT_BLAME_PREFETCH_FAILED = 'STRICT'
            OUTPUT_DIRECTORY_EMPTY = 'OUTPUT'
            OUTPUT_DIRECTORY_CREATE_FAILED = 'OUTPUT'
            OUTPUT_OUT_DIRECTORY_EMPTY = 'OUTPUT'
            OUTPUT_PLANTUML_NO_DATA = 'OUTPUT'
            OUTPUT_VISUALIZATION_SKIPPED = 'OUTPUT'
            OUTPUT_VISUALIZATION_WRITTEN = 'OUTPUT'
            OUTPUT_TEAM_ACTIVITY_INTERVENTION_RATE_OVERFLOW = 'OUTPUT'
            OUTPUT_METRIC_BREAKDOWN_OVERFLOW = 'OUTPUT'
            OUTPUT_NO_DATA = 'OUTPUT'
            INTERNAL_UNEXPECTED_ERROR = 'INTERNAL'
        }
        Metrics = @{
            ColDeadAdded = '消滅追加行数'  # 追加されたが ToRev 時点で生存していない行数
        }
        Caches = @{
            StrictBlameCacheHits = 0
            StrictBlameCacheMisses = 0
            SvnCommandStatsLock = New-Object object
            # ディスクキャッシュ (blame XML / cat テキスト) の上位に配置するインメモリキャッシュ。
            # 同一 (revision, path) への繰り返しアクセスでディスク I/O と XML パースを回避する。
            # SvnBlameSummaryMemoryCache: 所有権分析フェーズで ToRevision の全ファイル分を保持 (Content 空文字のため軽量)。
            # SvnBlameLineMemoryCache: Get-ExactDeathAttribution 内で使用。コミット境界で Clear() されるため
            #   定常メモリは O(K×L) (K=1コミットあたり変更ファイル数, L=平均行数) に抑えられる。
            SvnBlameSummaryMemoryCache = @{}
            SvnBlameLineMemoryCache = @{}
            SharedSha1 = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
        }
        Constants = @{
            DefaultColorPalette = @('#42a5f5', '#66bb6a', '#ffa726', '#ab47bc', '#ef5350', '#26c6da', '#8d6e63', '#78909c', '#d4e157', '#ec407a')

            # SVG チャート共通レイアウト定数
            SvgPlotLeft = 80.0
            SvgPlotTop = 60.0
            SvgPlotTopLarge = 72.0
            SvgPlotWidth = 400.0
            SvgPlotHeight = 400.0
            SvgBubbleMin = 8.0
            SvgBubbleMax = 36.0
            SvgQuadrantTickStep = 0.25

            # セマンティックカラー（コード運命の意味的な色）
            ColorSurvived = '#4caf50'
            ColorSelfCancel = '#ffc107'
            ColorRemovedByOthers = '#f44336'
            ColorOtherDead = '#bdbdbd'
            ColorChurn = '#ff7043'

            # アルゴリズム閾値
            RenameChainMaxDepth = 4096
            TrivialLineMaxLength = 3
            ContextHashNeighborK = 3
            CommitMessageMaxLength = 140
            HashTruncateLength = 8
            HeatmapLightTextThreshold = 0.6

            # コメント記法プロファイル（組み込み固定）
            # Extensions は小文字比較。LineCommentTokens/BlockCommentPairs/StringLiteralMarkers は字句走査で使用する。
            CommentSyntaxProfiles = @(
                [pscustomobject]@{
                    Name = 'CStyle'
                    Extensions = @('c', 'cc', 'cpp', 'cxx', 'h', 'hh', 'hpp', 'hxx', 'java', 'go', 'php', 'swift', 'kt', 'kts', 'scala')
                    LineCommentTokens = @('//')
                    BlockCommentPairs = @(
                        [pscustomobject]@{
                            Start = '/*'
                            End = '*/'
                        }
                    )
                    StringLiteralMarkers = @(
                        [pscustomobject]@{
                            Start = '"'
                            End = '"'
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = [string][char]39
                            End = [string][char]39
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        }
                    )
                },
                [pscustomobject]@{
                    Name = 'CSharpStyle'
                    Extensions = @('cs')
                    LineCommentTokens = @('//')
                    BlockCommentPairs = @(
                        [pscustomobject]@{
                            Start = '/*'
                            End = '*/'
                        }
                    )
                    StringLiteralMarkers = @(
                        [pscustomobject]@{
                            Start = '"""'
                            End = '"""'
                            CanSpanLines = $true
                            EscapeMode = 'None'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = '@"'
                            End = '"'
                            CanSpanLines = $true
                            EscapeMode = 'None'
                            AllowDoubleEnd = $true
                        },
                        [pscustomobject]@{
                            Start = '"'
                            End = '"'
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = [string][char]39
                            End = [string][char]39
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        }
                    )
                },
                [pscustomobject]@{
                    Name = 'JsTsStyle'
                    Extensions = @('js', 'jsx', 'ts', 'tsx')
                    LineCommentTokens = @('//')
                    BlockCommentPairs = @(
                        [pscustomobject]@{
                            Start = '/*'
                            End = '*/'
                        }
                    )
                    StringLiteralMarkers = @(
                        [pscustomobject]@{
                            Start = [string][char]96
                            End = [string][char]96
                            CanSpanLines = $true
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = '"'
                            End = '"'
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = [string][char]39
                            End = [string][char]39
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        }
                    )
                },
                [pscustomobject]@{
                    Name = 'PowerShellStyle'
                    Extensions = @('ps1', 'psm1', 'psd1')
                    LineCommentTokens = @('#')
                    BlockCommentPairs = @(
                        [pscustomobject]@{
                            Start = '<#'
                            End = '#>'
                        }
                    )
                    StringLiteralMarkers = @(
                        [pscustomobject]@{
                            Start = '@"'
                            End = '"@'
                            CanSpanLines = $true
                            EscapeMode = 'None'
                            AllowDoubleEnd = $false
                            EndMustBeAtLineStart = $true
                        },
                        [pscustomobject]@{
                            Start = "@'"
                            End = "'@"
                            CanSpanLines = $true
                            EscapeMode = 'None'
                            AllowDoubleEnd = $false
                            EndMustBeAtLineStart = $true
                        },
                        [pscustomobject]@{
                            Start = '"'
                            End = '"'
                            CanSpanLines = $false
                            EscapeMode = 'Backtick'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = [string][char]39
                            End = [string][char]39
                            CanSpanLines = $false
                            EscapeMode = 'None'
                            AllowDoubleEnd = $true
                        }
                    )
                },
                [pscustomobject]@{
                    Name = 'IniStyle'
                    Extensions = @('ini', 'cfg', 'conf', 'properties', 'toml', 'yaml', 'yml')
                    LineCommentTokens = @('#', ';')
                    BlockCommentPairs = @()
                    StringLiteralMarkers = @(
                        [pscustomobject]@{
                            Start = '"""'
                            End = '"""'
                            CanSpanLines = $true
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = '"'
                            End = '"'
                            CanSpanLines = $false
                            EscapeMode = 'Backslash'
                            AllowDoubleEnd = $false
                        },
                        [pscustomobject]@{
                            Start = [string][char]39
                            End = [string][char]39
                            CanSpanLines = $false
                            EscapeMode = 'None'
                            AllowDoubleEnd = $true
                        }
                    )
                }
            )

            # SVG 文字幅推定比率
            SvgCharWidthDefault = 0.56
            SvgCharWidthSpace = 0.33
            SvgCharWidthCjk = 1.00
            SvgCharWidthNarrow = 0.34
            SvgCharWidthWide = 0.82

            # Runspace 並列実行で転送する関数名リスト
            # 共通: SVN I/O とパスユーティリティ
            RunspaceSvnCoreFunctions = @(
                'ConvertTo-PathKey',
                'Join-CommandArgument',
                'Add-NarutoSvnCommandStat',
                'Invoke-SvnCommand'
            )
            # Diff パーサ: ConvertFrom-SvnUnifiedDiff とその依存関数
            RunspaceDiffParserFunctions = @(
                'Get-Sha1Hex',
                'ConvertTo-LineHash',
                'ConvertTo-ContextHash',
                'ConvertFrom-SvnUnifiedDiffPathHeader',
                'Get-SvnUnifiedDiffHeaderSectionList',
                'New-SvnUnifiedDiffParseState',
                'New-SvnUnifiedDiffFileStat',
                'Complete-SvnUnifiedDiffCurrentHunk',
                'Reset-SvnUnifiedDiffCurrentHunkState',
                'Start-SvnUnifiedDiffFileSection',
                'Start-SvnUnifiedDiffHunkSection',
                'Test-SvnUnifiedDiffBinaryMarker',
                'Update-SvnUnifiedDiffLineStat',
                'ConvertFrom-SvnUnifiedDiff'
            )
            # Blame キャッシュ I/O: ディスクキャッシュ読み書き
            RunspaceBlameCacheFunctions = @(
                'Get-Sha1Hex',
                'Get-PathCacheHash',
                'Get-BlameCachePath',
                'Read-BlameCacheFile',
                'Write-BlameCacheFile',
                'Test-SvnMissingTargetError',
                'Invoke-SvnCommandAllowMissingTarget',
                'Get-EmptyBlameResult',
                'New-NarutoResultSuccess',
                'New-NarutoResultSkipped',
                'New-NarutoResultFailure',
                'Test-NarutoResultSuccess',
                'ConvertTo-NarutoResultAdapter',
                'Throw-NarutoError'
            )
            # コメント除外判定: 拡張子プロファイル判定と字句走査
            RunspaceCommentFilterFunctions = @(
                'Get-ContextRuntimeSwitchValue',
                'Get-CommentSyntaxProfileByPath',
                'ConvertTo-CommentOnlyLineMask',
                'Get-NonCommentLineEntry',
                'Get-CachedOrFetchCatText',
                'Get-CatCachePath',
                'Read-CatCacheFile',
                'Write-CatCacheFile',
                'ConvertTo-TextLine',
                'Invoke-SvnCommandAllowMissingTarget',
                'ConvertTo-NarutoResultAdapter',
                'Test-NarutoResultSuccess',
                'Throw-NarutoError'
            )
        }
    }
}
function Get-RunspaceNarutoContext
{
    <#
    .SYNOPSIS
        並列 runspace 用に分離した NarutoContext を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $runtimeState = Get-NarutoContextRuntimeState -Context $Context
    $runspaceContext = New-NarutoContext -SvnExecutable $runtimeState.SvnExecutable -SvnGlobalArguments $runtimeState.SvnGlobalArguments
    $runspaceContext.Runtime.ExcludeCommentOnlyLines = [bool]$runtimeState.ExcludeCommentOnlyLines
    Copy-NarutoContextSection -SourceContext $Context -TargetContext $runspaceContext -SectionName 'Constants'
    Copy-NarutoContextSection -SourceContext $Context -TargetContext $runspaceContext -SectionName 'Metrics'
    # SHA1 インスタンスは runspace 間共有しない
    $runspaceContext.Caches.SharedSha1 = $null
    return $runspaceContext
}
function Get-NarutoContextRuntimeState
{
    <#
    .SYNOPSIS
        NarutoContext から実行時設定を抽出する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $runtimeSvnExecutable = 'svn'
    $runtimeSvnGlobalArguments = @()
    $runtimeExcludeCommentOnlyLines = $false
    if ($null -ne $Context -and $null -ne $Context.Runtime)
    {
        if (-not [string]::IsNullOrWhiteSpace([string]$Context.Runtime.SvnExecutable))
        {
            $runtimeSvnExecutable = [string]$Context.Runtime.SvnExecutable
        }
        if ($Context.Runtime.SvnGlobalArguments)
        {
            $runtimeSvnGlobalArguments = @($Context.Runtime.SvnGlobalArguments)
        }
        if ($Context.Runtime.ContainsKey('ExcludeCommentOnlyLines'))
        {
            $runtimeExcludeCommentOnlyLines = [bool]$Context.Runtime.ExcludeCommentOnlyLines
        }
    }
    return [pscustomobject]@{
        SvnExecutable = $runtimeSvnExecutable
        SvnGlobalArguments = @($runtimeSvnGlobalArguments)
        ExcludeCommentOnlyLines = [bool]$runtimeExcludeCommentOnlyLines
    }
}
function Copy-NarutoContextSection
{
    <#
    .SYNOPSIS
        NarutoContext のセクション値を別コンテキストへコピーする。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$SourceContext,
        [hashtable]$TargetContext,
        [string]$SectionName
    )
    if ($null -eq $SourceContext -or $null -eq $TargetContext -or [string]::IsNullOrWhiteSpace($SectionName))
    {
        return
    }
    if (-not $SourceContext.ContainsKey($SectionName) -or -not $TargetContext.ContainsKey($SectionName))
    {
        return
    }
    $sourceSection = $SourceContext[$SectionName]
    $targetSection = $TargetContext[$SectionName]
    if ($null -eq $sourceSection -or $null -eq $targetSection)
    {
        return
    }
    foreach ($key in @($sourceSection.Keys))
    {
        $value = $sourceSection[$key]
        if ($value -is [System.Array])
        {
            $targetSection[$key] = @($value)
            continue
        }
        $targetSection[$key] = $value
    }
}
# region 初期化
function Initialize-StrictModeContext
{
    <#
    .SYNOPSIS
        Strict モード実行に必要なスクリプト状態を初期化する。
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $runtimeState = Get-NarutoContextRuntimeState -Context $Context
    $normalizedContext = New-NarutoContext -SvnExecutable $runtimeState.SvnExecutable -SvnGlobalArguments $runtimeState.SvnGlobalArguments
    $normalizedContext.Runtime.ExcludeCommentOnlyLines = [bool]$runtimeState.ExcludeCommentOnlyLines
    return $normalizedContext
}
function Get-ContextRuntimeSwitchValue
{
    <#
    .SYNOPSIS
        Context.Runtime 配下のスイッチ値を安全に取得する。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$PropertyName,
        [bool]$Default = $false
    )
    if ([string]::IsNullOrWhiteSpace($PropertyName))
    {
        return [bool]$Default
    }
    if ($null -eq $Context -or $null -eq $Context.Runtime)
    {
        return [bool]$Default
    }
    if (-not $Context.Runtime.ContainsKey($PropertyName))
    {
        return [bool]$Default
    }
    return [bool]$Context.Runtime[$PropertyName]
}
function Set-NarutoPerformanceValue
{
    <#
    .SYNOPSIS
        計測メタデータのセクション/キー値を Context.Diagnostics へ設定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$SectionName,
        [string]$Key,
        $Value
    )
    if ([string]::IsNullOrWhiteSpace($SectionName) -or [string]::IsNullOrWhiteSpace($Key))
    {
        return
    }
    if ($null -eq $Context.Diagnostics)
    {
        $Context.Diagnostics = @{}
    }
    if (-not $Context.Diagnostics.ContainsKey('Performance') -or $null -eq $Context.Diagnostics.Performance)
    {
        $Context.Diagnostics.Performance = [ordered]@{
            StageSeconds = [ordered]@{}
            StrictBreakdown = [ordered]@{}
            StrictTargetStats = [ordered]@{}
            SvnCommandStats = [ordered]@{}
            PerfGate = [ordered]@{}
        }
    }
    if (-not $Context.Diagnostics.Performance.Contains($SectionName) -or $null -eq $Context.Diagnostics.Performance[$SectionName])
    {
        $Context.Diagnostics.Performance[$SectionName] = [ordered]@{}
    }
    $Context.Diagnostics.Performance[$SectionName][$Key] = $Value
}
function Add-NarutoSvnCommandStat
{
    <#
    .SYNOPSIS
        実行した svn サブコマンド回数を計測メタデータへ加算する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string[]]$Arguments
    )
    if (-not $Arguments -or $Arguments.Count -le 0)
    {
        return
    }
    $commandName = [string]$Arguments[0]
    if ([string]::IsNullOrWhiteSpace($commandName))
    {
        $commandName = '(unknown)'
    }
    $commandName = $commandName.ToLowerInvariant()

    if ($null -eq $Context.Caches)
    {
        $Context.Caches = @{}
    }
    if (-not $Context.Caches.ContainsKey('SvnCommandStatsLock') -or $null -eq $Context.Caches.SvnCommandStatsLock)
    {
        $Context.Caches.SvnCommandStatsLock = New-Object object
    }

    $syncRoot = $Context.Caches.SvnCommandStatsLock
    $lockTaken = $false
    try
    {
        [System.Threading.Monitor]::Enter($syncRoot, [ref]$lockTaken)
        if ($null -eq $Context.Diagnostics)
        {
            $Context.Diagnostics = @{}
        }
        if (-not $Context.Diagnostics.ContainsKey('Performance') -or $null -eq $Context.Diagnostics.Performance)
        {
            $Context.Diagnostics.Performance = [ordered]@{
                StageSeconds = [ordered]@{}
                StrictBreakdown = [ordered]@{}
                StrictTargetStats = [ordered]@{}
                SvnCommandStats = [ordered]@{}
                PerfGate = [ordered]@{}
            }
        }
        if (-not $Context.Diagnostics.Performance.Contains('SvnCommandStats') -or $null -eq $Context.Diagnostics.Performance.SvnCommandStats)
        {
            $Context.Diagnostics.Performance.SvnCommandStats = [ordered]@{}
        }
        if (-not $Context.Diagnostics.Performance.SvnCommandStats.Contains($commandName))
        {
            $Context.Diagnostics.Performance.SvnCommandStats[$commandName] = 0
        }
        $Context.Diagnostics.Performance.SvnCommandStats[$commandName] = [int]$Context.Diagnostics.Performance.SvnCommandStats[$commandName] + 1
    }
    finally
    {
        if ($lockTaken)
        {
            [System.Threading.Monitor]::Exit($syncRoot)
        }
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
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [string]$CallerName = ''
    )
    if ([string]::IsNullOrWhiteSpace($Path))
    {
        return (New-NarutoResultFailure -ErrorCode 'OUTPUT_DIRECTORY_EMPTY' -Message 'OutDirectory が空です。' -Context @{
                CallerName = $CallerName
            })
    }
    if (-not (Test-Path -LiteralPath $Path))
    {
        try
        {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch
        {
            $contextText = if ($CallerName)
            {
                "${CallerName}: "
            }
            else
            {
                ''
            }
            return (New-NarutoResultFailure -ErrorCode 'OUTPUT_DIRECTORY_CREATE_FAILED' -Message ("{0}ディレクトリ作成失敗: {1}" -f $contextText, $_.Exception.Message) -Context @{
                    CallerName = $CallerName
                    Path = $Path
                })
        }
    }
    return (New-NarutoResultSuccess -Data $Path -ErrorCode 'OUTPUT_DIRECTORY_READY')
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
            Throw-NarutoError -Category 'INPUT' -ErrorCode 'INPUT_UNSUPPORTED_ENCODING' -Message ("未対応のエンコーディングです: {0}" -f $Name) -Context @{
                Encoding = $Name
            }
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
function Invoke-ParallelWorkSequentialCore
{
    <#
    .SYNOPSIS
        Invoke-ParallelWork の逐次実行経路を実行する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Items,
        [scriptblock]$WorkerScript,
        [string]$ErrorContext,
        [int]$ProgressId
    )
    $sequentialResults = [System.Collections.Generic.List[object]]::new()
    for ($i = 0
        $i -lt $Items.Count
        $i++)
    {
        $pct = [Math]::Min(100, [int](($i / $Items.Count) * 100))
        Write-Progress -Id $ProgressId -Activity $ErrorContext -Status ('{0}/{1}' -f ($i + 1), $Items.Count) -PercentComplete $pct
        try
        {
            [void]$sequentialResults.Add((& $WorkerScript -Item $Items[$i] -Index $i))
        }
        catch
        {
            Throw-NarutoError -Category 'INTERNAL' -ErrorCode 'INTERNAL_PARALLEL_ITEM_FAILED' -Message ("{0} failed at item index {1}: {2}" -f $ErrorContext, $i, $_.Exception.Message) -Context @{
                ErrorContext = $ErrorContext
                ItemIndex = $i
            } -InnerException $_.Exception
        }
    }
    Write-Progress -Id $ProgressId -Activity $ErrorContext -Completed
    return @($sequentialResults.ToArray())
}
function Invoke-ParallelWorkRunspaceCore
{
    <#
    .SYNOPSIS
        Invoke-ParallelWork の Runspace 実行経路を実行する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Items,
        [string]$WorkerText,
        [string]$InvokeScript,
        [int]$EffectiveParallel,
        [string]$ErrorContext,
        [int]$ProgressId,
        [System.Management.Automation.Runspaces.InitialSessionState]$InitialSessionState
    )
    $pool = [runspacefactory]::CreateRunspacePool($InitialSessionState)
    [void]$pool.SetMinRunspaces(1)
    [void]$pool.SetMaxRunspaces($EffectiveParallel)
    $jobs = [System.Collections.Generic.List[object]]::new()
    # 結果を元の入力順序で返すため、インデックスで管理する配列を事前確保する。
    $wrappedByIndex = New-Object 'object[]' $Items.Count
    try
    {
        $pool.Open()
        $jobTotal = $Items.Count
        $nextIndex = 0
        $jobDone = 0
        # 遅延投入 (lazy submission): 全ジョブを一括投入せず、同時実行数を
        # $effectiveParallel 以下に制限する。これにより PowerShell インスタンスの
        # メモリ消費を O(items.Count) → O(effectiveParallel) に抑える。
        # 完了したジョブから順にスロットを解放し、次のジョブを投入する。
        while ($nextIndex -lt $Items.Count -or $jobs.Count -gt 0)
        {
            while ($nextIndex -lt $Items.Count -and $jobs.Count -lt $EffectiveParallel)
            {
                Add-RunspaceParallelJob -Jobs $jobs -Pool $pool -InvokeScript $InvokeScript -WorkerText $WorkerText -Item $Items[$nextIndex] -Index $nextIndex
                $nextIndex++
            }

            $pct = [Math]::Min(100, [int](($jobDone / [Math]::Max(1, $jobTotal)) * 100))
            Write-Progress -Id $ProgressId -Activity $ErrorContext -Status ('{0}/{1}' -f ($jobDone + 1), $jobTotal) -PercentComplete $pct
            if ($jobs.Count -eq 0)
            {
                continue
            }

            $completedJobIndex = Get-CompletedRunspaceParallelJobIndex -Jobs $jobs
            if ($completedJobIndex -lt 0)
            {
                Start-Sleep -Milliseconds 1
                continue
            }

            $job = $jobs[$completedJobIndex]
            $jobs.RemoveAt($completedJobIndex)
            $wrapped = Receive-RunspaceParallelJobResult -Job $job
            if ($wrapped.Index -ge 0 -and $wrapped.Index -lt $wrappedByIndex.Length)
            {
                $wrappedByIndex[$wrapped.Index] = $wrapped
            }
            $jobDone++
        }
        Write-Progress -Id $ProgressId -Activity $ErrorContext -Completed
    }
    catch
    {
        Throw-NarutoError -Category 'INTERNAL' -ErrorCode 'INTERNAL_PARALLEL_INFRASTRUCTURE_FAILED' -Message ("{0} infrastructure failure: {1}" -f $ErrorContext, $_.Exception.Message) -Context @{
            ErrorContext = $ErrorContext
        } -InnerException $_.Exception
    }
    finally
    {
        foreach ($job in @($jobs.ToArray()))
        {
            Clear-RunspaceParallelJob -Job $job
        }
        if ($pool)
        {
            $pool.Dispose()
        }
    }

    return @(ConvertTo-OrderedRunspaceWrappedResult -WrappedByIndex $wrappedByIndex)
}
function New-ParallelWorkerFailureResult
{
    <#
    .SYNOPSIS
        並列ワーカー失敗時の共通ラッパー結果を生成する。
    .PARAMETER Index
        失敗したワーカーのインデックス。
    .PARAMETER ErrorMessage
        エラーメッセージ文字列。
    .PARAMETER ErrorStack
        エラー発生時のスタックトレース文字列。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [int]$Index = -1,
        [string]$ErrorMessage = 'Unknown worker failure.',
        [string]$ErrorStack = $null
    )
    return [pscustomobject]@{
        Index = [int]$Index
        Succeeded = $false
        Result = $null
        ErrorMessage = $ErrorMessage
        ErrorStack = $ErrorStack
    }
}
function Add-RunspaceParallelJob
{
    <#
    .SYNOPSIS
        Runspace ジョブを作成してジョブ一覧へ登録する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[object]]$Jobs,
        [System.Management.Automation.Runspaces.RunspacePool]$Pool,
        [string]$InvokeScript,
        [string]$WorkerText,
        [object]$Item,
        [int]$Index
    )
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($InvokeScript).AddArgument($WorkerText).AddArgument($Item).AddArgument($Index)
    $handle = $ps.BeginInvoke()
    [void]$Jobs.Add([pscustomobject]@{
            Index = [int]$Index
            PowerShell = $ps
            Handle = $handle
        })
}
function Get-CompletedRunspaceParallelJobIndex
{
    <#
    .SYNOPSIS
        完了済み Runspace ジョブの配列インデックスを返す。
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([System.Collections.Generic.List[object]]$Jobs)
    for ($scan = 0
        $scan -lt $Jobs.Count
        $scan++)
    {
        if ($null -ne $Jobs[$scan] -and $null -ne $Jobs[$scan].Handle -and $Jobs[$scan].Handle.IsCompleted)
        {
            return $scan
        }
    }
    return -1
}
function Clear-RunspaceParallelJob
{
    <#
    .SYNOPSIS
        Runspace ジョブの PowerShell インスタンスを安全に破棄する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([object]$Job)
    if ($null -eq $Job -or $null -eq $Job.PowerShell)
    {
        return
    }
    try
    {
        $Job.PowerShell.Dispose()
    }
    catch
    {
        [void]$_
    }
    $Job.PowerShell = $null
}
function Receive-RunspaceParallelJobResult
{
    <#
    .SYNOPSIS
        完了した Runspace ジョブからラップ済み結果を回収する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([object]$Job)
    if ($null -eq $Job -or $null -eq $Job.PowerShell)
    {
        $failedIndex = if ($null -ne $Job)
        {
            [int]$Job.Index
        }
        else
        {
            -1
        }
        return (New-ParallelWorkerFailureResult -Index $failedIndex -ErrorMessage 'Worker handle was not initialized.')
    }

    try
    {
        $resultSet = $Job.PowerShell.EndInvoke($Job.Handle)
        if ($resultSet -and $resultSet.Count -gt 0)
        {
            return $resultSet[0]
        }
        return (New-ParallelWorkerFailureResult -Index ([int]$Job.Index) -ErrorMessage 'Worker returned no result.')
    }
    catch
    {
        return (New-ParallelWorkerFailureResult -Index ([int]$Job.Index) -ErrorMessage $_.Exception.Message -ErrorStack $_.ScriptStackTrace)
    }
    finally
    {
        Clear-RunspaceParallelJob -Job $Job
    }
}
function ConvertTo-OrderedRunspaceWrappedResult
{
    <#
    .SYNOPSIS
        収集済みワーカー結果を入力順序へ整列して返す。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$WrappedByIndex)
    $orderedWrapped = [System.Collections.Generic.List[object]]::new()
    for ($orderedIndex = 0
        $orderedIndex -lt $WrappedByIndex.Length
        $orderedIndex++)
    {
        if ($null -ne $WrappedByIndex[$orderedIndex])
        {
            [void]$orderedWrapped.Add($WrappedByIndex[$orderedIndex])
            continue
        }
        [void]$orderedWrapped.Add((New-ParallelWorkerFailureResult -Index $orderedIndex -ErrorMessage 'Worker result is missing.'))
    }
    return @($orderedWrapped.ToArray())
}
function Get-ParallelFailureSummaryText
{
    <#
    .SYNOPSIS
        並列実行失敗エントリ一覧を例外メッセージ文字列へ整形する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$FailedEntries)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($FailedEntries))
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
    return ($lines.ToArray() -join "`n")
}
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
        Throw-NarutoError -Category 'INPUT' -ErrorCode 'INPUT_WORKER_SCRIPT_REQUIRED' -Message ("WorkerScript is required for {0}." -f $ErrorContext) -Context @{
            ErrorContext = $ErrorContext
        }
    }

    $effectiveParallel = [Math]::Max(1, [Math]::Min([int]$MaxParallel, $items.Count))
    $progressId = [Math]::Abs($ErrorContext.GetHashCode()) % 10000 + 10
    if ($effectiveParallel -le 1)
    {
        return @(Invoke-ParallelWorkSequentialCore -Items $items -WorkerScript $WorkerScript -ErrorContext $ErrorContext -ProgressId $progressId)
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
            Throw-NarutoError -Category 'INPUT' -ErrorCode 'INPUT_REQUIRED_FUNCTION_NOT_FOUND' -Message ("Required function '{0}' was not found for {1}." -f $name, $ErrorContext) -Context @{
                FunctionName = $name
                ErrorContext = $ErrorContext
            } -InnerException $_.Exception
        }
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $definition)))
    }
    foreach ($key in @($SessionVariables.Keys))
    {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry([string]$key, $SessionVariables[$key], ("Injected for {0}" -f $ErrorContext))))
    }
    # Context が SessionVariables に含まれている場合、Runspace 内で Mandatory な -Context パラメータが
    # 対話的プロンプトでハングすることを防止するため $PSDefaultParameterValues を注入する。
    if ($SessionVariables.ContainsKey('Context'))
    {
        $contextDefaultParams = @{ '*:Context' = $SessionVariables['Context'] }
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('PSDefaultParameterValues', $contextDefaultParams, ("Default Context for {0}" -f $ErrorContext))))
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

    $orderedWrapped = @(Invoke-ParallelWorkRunspaceCore -Items $items -WorkerText $workerText -InvokeScript $invokeScript -EffectiveParallel $effectiveParallel -ErrorContext $ErrorContext -ProgressId $progressId -InitialSessionState $iss)

    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($orderedWrapped))
    {
        if ($null -eq $entry -or -not [bool]$entry.Succeeded)
        {
            [void]$failed.Add($entry)
        }
    }
    if ($failed.Count -gt 0)
    {
        $failureSummary = Get-ParallelFailureSummaryText -FailedEntries @($failed.ToArray())
        Throw-NarutoError -Category 'INTERNAL' -ErrorCode 'INTERNAL_PARALLEL_WORK_FAILED' -Message ("{0} failed for {1} item(s).`n{2}" -f $ErrorContext, $failed.Count, $failureSummary) -Context @{
            ErrorContext = $ErrorContext
            FailedCount = $failed.Count
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($orderedWrapped))
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [string]$Text)
    if ($null -eq $Text)
    {
        $Text = ''
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    # 並列 runspace では SharedSha1 が存在しないため都度生成する
    $shared = $null
    if ($null -ne $Context -and $null -ne $Context.Caches)
    {
        $shared = $Context.Caches.SharedSha1
    }
    $sha = if ($shared)
    {
        $shared
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
        if ($sha -ne $shared)
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
    param([Parameter(Mandatory = $true)][hashtable]$Context, [string]$FilePath)
    return Get-Sha1Hex -Context $Context -Text (ConvertTo-PathKey -Path $FilePath)
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    $dir = Join-Path (Join-Path $CacheDir 'blame') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -Context $Context -FilePath $FilePath) + '.xml')
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    $dir = Join-Path (Join-Path $CacheDir 'cat') ("r{0}" -f $Revision)
    return Join-Path $dir ((Get-PathCacheHash -Context $Context -FilePath $FilePath) + '.txt')
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $false
    }
    $path = Get-BlameCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $false
    }
    $path = Get-CatCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
    .PARAMETER Variant
        同一 revision/path で用途別キャッシュを分離する識別子を指定する。
    #>
    param([int]$Revision, [string]$FilePath, [string]$Variant = '')
    return ([string]$Revision + [char]31 + (ConvertTo-PathKey -Path $FilePath) + [char]31 + [string]$Variant)
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $null
    }
    $path = Get-BlameCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath,
        [string]$Content
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return
    }
    $path = Get-BlameCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return $null
    }
    $path = Get-CatCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath,
        [string]$Content
    )
    if ([string]::IsNullOrWhiteSpace($CacheDir))
    {
        return
    }
    $path = Get-CatCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
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
function Get-CommentSyntaxProfileByPath
{
    <#
    .SYNOPSIS
        ファイル拡張子に対応するコメント記法プロファイルを返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$FilePath
    )
    $pathKey = ConvertTo-PathKey -Path $FilePath
    if ([string]::IsNullOrWhiteSpace($pathKey))
    {
        return $null
    }
    $extension = [System.IO.Path]::GetExtension($pathKey)
    if ([string]::IsNullOrWhiteSpace($extension))
    {
        return $null
    }
    $normalizedExtension = $extension.TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedExtension))
    {
        return $null
    }
    $profiles = @()
    if ($null -ne $Context -and $null -ne $Context.Constants -and $Context.Constants.ContainsKey('CommentSyntaxProfiles'))
    {
        $profiles = @($Context.Constants.CommentSyntaxProfiles)
    }
    foreach ($commentSyntaxProfile in $profiles)
    {
        if ($null -eq $commentSyntaxProfile)
        {
            continue
        }
        $extensions = @()
        if ($commentSyntaxProfile.PSObject.Properties.Match('Extensions').Count -gt 0 -and $null -ne $commentSyntaxProfile.Extensions)
        {
            $extensions = @($commentSyntaxProfile.Extensions | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
        }
        if ($extensions -contains $normalizedExtension)
        {
            return $commentSyntaxProfile
        }
    }
    return $null
}
function ConvertTo-CommentOnlyLineMask
{
    <#
    .SYNOPSIS
        行配列から「コメント専用行」判定マスクを生成する。
    .DESCRIPTION
        行コメントとブロックコメントの字句走査を行い、コメント専用行のみを true とする。
        拡張子プロファイル定義の StringLiteralMarkers を用いて文字列境界を厳密判定し、
        複数行文字列中のコメントトークン誤検出を抑止する。ブロックコメントのネストは未対応。
    #>
    [CmdletBinding()]
    [OutputType([bool[]])]
    param(
        [string[]]$Lines,
        [object]$CommentSyntaxProfile
    )
    if ($null -eq $Lines -or @($Lines).Count -eq 0 -or $null -eq $CommentSyntaxProfile)
    {
        return (New-Object 'bool[]' 0)
    }

    $lineCommentTokens = @()
    if ($CommentSyntaxProfile.PSObject.Properties.Match('LineCommentTokens').Count -gt 0 -and $null -ne $CommentSyntaxProfile.LineCommentTokens)
    {
        $lineCommentTokens = @(
            $CommentSyntaxProfile.LineCommentTokens |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object Length -Descending
        )
    }

    $blockCommentPairs = @()
    if ($CommentSyntaxProfile.PSObject.Properties.Match('BlockCommentPairs').Count -gt 0 -and $null -ne $CommentSyntaxProfile.BlockCommentPairs)
    {
        $blockCommentPairs = @(
            $CommentSyntaxProfile.BlockCommentPairs |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Start) -and -not [string]::IsNullOrWhiteSpace([string]$_.End) } |
                Sort-Object { ([string]$_.Start).Length } -Descending
        )
    }

    $stringLiteralMarkers = @()
    if ($CommentSyntaxProfile.PSObject.Properties.Match('StringLiteralMarkers').Count -gt 0 -and $null -ne $CommentSyntaxProfile.StringLiteralMarkers)
    {
        $normalizedMarkers = [System.Collections.Generic.List[object]]::new()
        foreach ($marker in @($CommentSyntaxProfile.StringLiteralMarkers))
        {
            if ($null -eq $marker)
            {
                continue
            }
            $startToken = [string]$marker.Start
            $endToken = [string]$marker.End
            if ([string]::IsNullOrWhiteSpace($startToken) -or [string]::IsNullOrWhiteSpace($endToken))
            {
                continue
            }
            $escapeMode = 'None'
            if ($marker.PSObject.Properties.Match('EscapeMode').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$marker.EscapeMode))
            {
                $candidateEscapeMode = [string]$marker.EscapeMode
                if ([string]::Equals($candidateEscapeMode, 'Backslash', [System.StringComparison]::OrdinalIgnoreCase))
                {
                    $escapeMode = 'Backslash'
                }
                elseif ([string]::Equals($candidateEscapeMode, 'Backtick', [System.StringComparison]::OrdinalIgnoreCase))
                {
                    $escapeMode = 'Backtick'
                }
            }
            [void]$normalizedMarkers.Add([pscustomobject]@{
                    Start = $startToken
                    End = $endToken
                    CanSpanLines = if ($marker.PSObject.Properties.Match('CanSpanLines').Count -gt 0)
                    {
                        [bool]$marker.CanSpanLines
                    }
                    else
                    {
                        $false
                    }
                    EscapeMode = $escapeMode
                    AllowDoubleEnd = if ($marker.PSObject.Properties.Match('AllowDoubleEnd').Count -gt 0)
                    {
                        [bool]$marker.AllowDoubleEnd
                    }
                    else
                    {
                        $false
                    }
                    EndMustBeAtLineStart = if ($marker.PSObject.Properties.Match('EndMustBeAtLineStart').Count -gt 0)
                    {
                        [bool]$marker.EndMustBeAtLineStart
                    }
                    else
                    {
                        $false
                    }
                })
        }
        $stringLiteralMarkers = @($normalizedMarkers.ToArray() | Sort-Object { ([string]$_.Start).Length } -Descending)
    }

    $mask = New-Object 'bool[]' @($Lines).Count
    $inBlockComment = $false
    $activeBlockEndToken = ''
    $inString = $false
    $activeStringMarker = $null
    $stringEscapePending = $false
    for ($lineIndex = 0
        $lineIndex -lt @($Lines).Count
        $lineIndex++)
    {
        $line = [string]$Lines[$lineIndex]
        if ($null -eq $line)
        {
            $line = ''
        }

        $charIndex = 0
        $lineHasCode = $false
        $lineHasComment = $false

        while ($charIndex -lt $line.Length)
        {
            if ($inBlockComment)
            {
                $lineHasComment = $true
                $endPos = $line.IndexOf($activeBlockEndToken, $charIndex, [System.StringComparison]::Ordinal)
                if ($endPos -lt 0)
                {
                    $charIndex = $line.Length
                    break
                }
                $charIndex = $endPos + $activeBlockEndToken.Length
                $inBlockComment = $false
                $activeBlockEndToken = ''
                continue
            }

            if ($inString)
            {
                $lineHasCode = $true
                $activeEndToken = [string]$activeStringMarker.End
                $activeEscapeMode = [string]$activeStringMarker.EscapeMode
                $allowDoubleEnd = [bool]$activeStringMarker.AllowDoubleEnd

                if ($stringEscapePending)
                {
                    $stringEscapePending = $false
                    $charIndex++
                    continue
                }

                $activeChar = $line[$charIndex]
                # 行末がエスケープ文字の場合は stringEscapePending を設定しない。
                # ECMAScript の行継続（\+改行）は次行冒頭文字をスキップしないため、
                # CanSpanLines=true でも次行冒頭をエスケープしない現在の動作が正しい。
                if ($activeEscapeMode -eq 'Backslash' -and $activeChar -eq '\')
                {
                    if (($charIndex + 1) -lt $line.Length)
                    {
                        $stringEscapePending = $true
                    }
                    $charIndex++
                    continue
                }
                if ($activeEscapeMode -eq 'Backtick' -and $activeChar -eq '`')
                {
                    if (($charIndex + 1) -lt $line.Length)
                    {
                        $stringEscapePending = $true
                    }
                    $charIndex++
                    continue
                }

                $matchedEndToken = $false
                if (($charIndex + $activeEndToken.Length) -le $line.Length -and [string]::Compare($line, $charIndex, $activeEndToken, 0, $activeEndToken.Length, [System.StringComparison]::Ordinal) -eq 0)
                {
                    if ([bool]$activeStringMarker.EndMustBeAtLineStart)
                    {
                        $prefixIsWhitespace = $true
                        for ($pi = 0; $pi -lt $charIndex; $pi++)
                        {
                            if (-not [char]::IsWhiteSpace($line[$pi]))
                            {
                                $prefixIsWhitespace = $false
                                break
                            }
                        }
                        if ($prefixIsWhitespace)
                        {
                            $matchedEndToken = $true
                        }
                    }
                    else
                    {
                        $matchedEndToken = $true
                    }
                }
                if ($matchedEndToken)
                {
                    if ($allowDoubleEnd)
                    {
                        $nextStart = $charIndex + $activeEndToken.Length
                        if (($nextStart + $activeEndToken.Length) -le $line.Length -and [string]::Compare($line, $nextStart, $activeEndToken, 0, $activeEndToken.Length, [System.StringComparison]::Ordinal) -eq 0)
                        {
                            $charIndex += ($activeEndToken.Length * 2)
                            continue
                        }
                    }
                    $inString = $false
                    $activeStringMarker = $null
                    $stringEscapePending = $false
                    $charIndex += $activeEndToken.Length
                    continue
                }

                $charIndex++
                continue
            }

            if ([char]::IsWhiteSpace($line[$charIndex]))
            {
                $charIndex++
                continue
            }

            $matchedLineComment = $false
            foreach ($token in $lineCommentTokens)
            {
                if (($charIndex + $token.Length) -le $line.Length -and [string]::Compare($line, $charIndex, $token, 0, $token.Length, [System.StringComparison]::Ordinal) -eq 0)
                {
                    $lineHasComment = $true
                    $charIndex = $line.Length
                    $matchedLineComment = $true
                    break
                }
            }
            if ($matchedLineComment)
            {
                break
            }

            $matchedBlockComment = $false
            foreach ($pair in $blockCommentPairs)
            {
                $startToken = [string]$pair.Start
                if (($charIndex + $startToken.Length) -le $line.Length -and [string]::Compare($line, $charIndex, $startToken, 0, $startToken.Length, [System.StringComparison]::Ordinal) -eq 0)
                {
                    $lineHasComment = $true
                    $inBlockComment = $true
                    $activeBlockEndToken = [string]$pair.End
                    $charIndex += $startToken.Length
                    $matchedBlockComment = $true
                    break
                }
            }
            if ($matchedBlockComment)
            {
                continue
            }

            $matchedStringMarker = $null
            foreach ($marker in $stringLiteralMarkers)
            {
                $startToken = [string]$marker.Start
                if (($charIndex + $startToken.Length) -le $line.Length -and [string]::Compare($line, $charIndex, $startToken, 0, $startToken.Length, [System.StringComparison]::Ordinal) -eq 0)
                {
                    $matchedStringMarker = $marker
                    break
                }
            }
            if ($null -ne $matchedStringMarker)
            {
                $lineHasCode = $true
                $inString = $true
                $activeStringMarker = $matchedStringMarker
                $stringEscapePending = $false
                $charIndex += ([string]$matchedStringMarker.Start).Length
                continue
            }

            $lineHasCode = $true
            $charIndex++
        }

        if ($inString -and $null -ne $activeStringMarker -and -not [bool]$activeStringMarker.CanSpanLines)
        {
            $inString = $false
            $activeStringMarker = $null
            $stringEscapePending = $false
        }

        $mask[$lineIndex] = (-not $lineHasCode -and $lineHasComment)
    }

    return $mask
}
function Get-NonCommentLineEntry
{
    <#
    .SYNOPSIS
        blame 行配列からコメント専用行を除外した配列を返す。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Lines,
        [bool[]]$CommentOnlyLineMask
    )
    if ($null -eq $Lines)
    {
        return @()
    }
    if ($null -eq $CommentOnlyLineMask -or $CommentOnlyLineMask.Length -eq 0)
    {
        return @($Lines)
    }
    $filtered = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0
        $index -lt @($Lines).Count
        $index++)
    {
        $lineEntry = $Lines[$index]
        $lineNumber = $index + 1
        if ($null -ne $lineEntry -and $lineEntry.PSObject.Properties.Match('LineNumber').Count -gt 0)
        {
            try
            {
                $lineNumber = [int]$lineEntry.LineNumber
            }
            catch
            {
                $lineNumber = $index + 1
            }
        }
        $isCommentOnly = $false
        if ($lineNumber -gt 0 -and ($lineNumber - 1) -lt $CommentOnlyLineMask.Length)
        {
            $isCommentOnly = [bool]$CommentOnlyLineMask[$lineNumber - 1]
        }
        elseif ($index -lt $CommentOnlyLineMask.Length)
        {
            $isCommentOnly = [bool]$CommentOnlyLineMask[$index]
        }
        if (-not $isCommentOnly)
        {
            [void]$filtered.Add($lineEntry)
        }
    }
    return @($filtered.ToArray())
}
function Get-CachedOrFetchCatText
{
    <#
    .SYNOPSIS
        cat キャッシュを優先して必要時のみ svn cat を取得する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Repo,
        [string]$FilePath,
        [int]$Revision,
        [string]$CacheDir
    )
    if ($Revision -le 0 -or [string]::IsNullOrWhiteSpace($Repo) -or [string]::IsNullOrWhiteSpace($FilePath))
    {
        return $null
    }
    $catText = Read-CatCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    if ($null -ne $catText)
    {
        return $catText
    }

    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision
    $catFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat {0}@{1}" -f $FilePath, $Revision)
    $catFetchResult = ConvertTo-NarutoResultAdapter -InputObject $catFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
    if (-not (Test-NarutoResultSuccess -Result $catFetchResult))
    {
        if ([string]$catFetchResult.Status -eq 'Skipped')
        {
            return $null
        }
        Throw-NarutoError -Category 'SVN' -ErrorCode ([string]$catFetchResult.ErrorCode) -Message ("svn cat failed for '{0}' at r{1}: {2}" -f $FilePath, $Revision, [string]$catFetchResult.Message) -Context @{
            FilePath = $FilePath
            Revision = [int]$Revision
        }
    }

    $catText = [string]$catFetchResult.Data
    if ($null -ne $catText)
    {
        Write-CatCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
    }
    return $catText
}
function Resolve-PathByRenameMap
{
    <#
    .SYNOPSIS
        リネーム履歴をたどって最新側の論理パスへ解決する。
    #>
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [string]$FilePath, [hashtable]$RenameMap)
    $resolved = ConvertTo-PathKey -Path $FilePath
    if ($null -eq $RenameMap -or -not $resolved)
    {
        return $resolved
    }
    $guard = 0
    while ($RenameMap.ContainsKey($resolved) -and $guard -lt $Context.Constants.RenameChainMaxDepth)
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$TargetUrl,
        [int]$Revision,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePathPatterns,
        [string[]]$ExcludePathPatterns
    )
    $xmlText = Invoke-SvnCommand -Context $Context -Arguments @('list', '-R', '--xml', '-r', [string]$Revision, $TargetUrl) -ErrorContext 'svn list'
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
    [CmdletBinding()]param( [Parameter(Mandatory = $true)][hashtable]$Context, [string[]]$Arguments, [string]$ErrorContext = 'SVN command')
    $all = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $Arguments)
    {
        [void]$all.Add([string]$a)
    }
    if ($Context.Runtime.SvnGlobalArguments)
    {
        foreach ($a in $Context.Runtime.SvnGlobalArguments)
        {
            [void]$all.Add([string]$a)
        }
    }
    Add-NarutoSvnCommandStat -Context $Context -Arguments @($Arguments)
    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Context.Runtime.SvnExecutable
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
            Throw-NarutoError -Category 'SVN' -ErrorCode 'SVN_COMMAND_FAILED' -Message ("{0} failed (exit code {1}).`nSTDERR: {2}`nSTDOUT: {3}" -f $ErrorContext, $process.ExitCode, $err, $out) -Context @{
                ErrorContext = $ErrorContext
                ExitCode = [int]$process.ExitCode
                Arguments = @($Arguments)
            }
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
        対象不存在を Skipped として返す SVN コマンド実行。
    #>
    [CmdletBinding()]param([Parameter(Mandatory = $true)][hashtable]$Context, [string[]]$Arguments, [string]$ErrorContext = 'SVN command')
    try
    {
        $out = Invoke-SvnCommand -Context $Context -Arguments $Arguments -ErrorContext $ErrorContext
        return (New-NarutoResultSuccess -Data $out -ErrorCode 'SVN_COMMAND_SUCCEEDED' -Message ("{0} succeeded." -f $ErrorContext))
    }
    catch
    {
        if (Test-SvnMissingTargetError -Message $_.Exception.Message)
        {
            return (New-NarutoResultSkipped -ErrorCode 'SVN_TARGET_MISSING' -Message ("{0}: 対象が存在しないためスキップしました。" -f $ErrorContext) -Context @{
                    ErrorContext = $ErrorContext
                    Arguments = @($Arguments)
                })
        }
        Throw-NarutoError -Category 'SVN' -ErrorCode 'SVN_COMMAND_FAILED' -Message ("{0} failed: {1}" -f $ErrorContext, $_.Exception.Message) -Context @{
            ErrorContext = $ErrorContext
            Arguments = @($Arguments)
        } -InnerException $_.Exception
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
        LineCountByRevisionAuthor = @{}
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
        Throw-NarutoError -Category 'PARSE' -ErrorCode 'PARSE_XML_FAILED' -Message ("{0} の XML パースに失敗しました: {1}" -f $ContextLabel, $_.Exception.Message) -Context @{
            ContextLabel = $ContextLabel
        } -InnerException $_.Exception
    }
}
function Resolve-SvnTargetUrl
{
    <#
    .SYNOPSIS
        入力 URL を SVN 実行用の正規化ターゲットに確定する。
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [string]$Target)
    if (-not ($Target -match '^(https?|svn|file)://'))
    {
        Throw-NarutoError -Category 'INPUT' -ErrorCode 'INPUT_INVALID_REPO_URL' -Message ("RepoUrl は svn URL 形式で指定してください: '{0}'" -f $Target) -Context @{
            RepoUrl = $Target
        }
    }
    $xml = ConvertFrom-SvnXmlText -Text (Invoke-SvnCommand -Context $Context -Arguments @('info', '--xml', $Target) -ErrorContext 'svn info') -ContextLabel 'svn info'
    $url = [string]$xml.info.entry.url
    if ([string]::IsNullOrWhiteSpace($url))
    {
        Throw-NarutoError -Category 'SVN' -ErrorCode 'SVN_REPOSITORY_VALIDATION_FAILED' -Message ("リポジトリ URL を検証できませんでした: {0}" -f $Target) -Context @{
            RepoUrl = $Target
        }
    }
    return $url.TrimEnd('/')
}
function Get-SvnLogPathPrefix
{
    <#
    .SYNOPSIS
        svn info の URL と root から svn log パスのプレフィックスを算出する。
    .DESCRIPTION
        svn log --verbose が返す path 要素はリポジトリルート相対パスである。
        一方 svn diff -c N <TargetUrl> の Index 行は TargetUrl 相対パスである。
        TargetUrl がリポジトリルートのサブパス (例: trunk/) を指す場合、
        両者にプレフィックス差が生じるため、この関数でプレフィックスを算出する。
    .PARAMETER Context
        NarutoCode コンテキストハッシュテーブル。
    .PARAMETER TargetUrl
        Resolve-SvnTargetUrl で確定したターゲット URL。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [string]$TargetUrl)
    $xml = ConvertFrom-SvnXmlText -Text (Invoke-SvnCommand -Context $Context -Arguments @('info', '--xml', $TargetUrl) -ErrorContext 'svn info (prefix)') -ContextLabel 'svn info (prefix)'
    $url = [string]$xml.info.entry.url
    $rootNode = $xml.info.entry.SelectSingleNode('repository/root')
    if ($null -eq $rootNode)
    {
        return ''
    }
    $root = [string]$rootNode.InnerText
    if ([string]::IsNullOrWhiteSpace($root) -or [string]::IsNullOrWhiteSpace($url))
    {
        return ''
    }
    $root = $root.TrimEnd('/')
    $url = $url.TrimEnd('/')
    if ($url.Length -le $root.Length)
    {
        return ''
    }
    $prefix = $url.Substring($root.Length).TrimStart('/')
    if ($prefix)
    {
        return $prefix + '/'
    }
    return ''
}
function ConvertTo-DiffRelativePath
{
    <#
    .SYNOPSIS
        svn log パスからリポジトリ相対プレフィックスを除去し diff 相対パスへ変換する。
    .DESCRIPTION
        TargetUrl がリポジトリルートのサブパスを指す場合に、
        svn log の path 要素から該当プレフィックスを除去して
        svn diff の Index 行パスと一致させる。
        プレフィックスが空か一致しない場合はパスをそのまま返す。
    .PARAMETER Path
        ConvertTo-PathKey 適用済みのログパス。
    .PARAMETER LogPathPrefix
        Get-SvnLogPathPrefix で算出したプレフィックス文字列。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path, [string]$LogPathPrefix)
    if ([string]::IsNullOrWhiteSpace($LogPathPrefix))
    {
        return $Path
    }
    if ($Path.StartsWith($LogPathPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    {
        return $Path.Substring($LogPathPrefix.Length)
    }
    return $Path
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
    param([Parameter(Mandatory = $true)][hashtable]$Context, [string]$FilePath, [string]$Content)
    $norm = $Content -replace '\s+', ' '
    $norm = $norm.Trim()
    $raw = $FilePath + [char]0 + $norm
    return Get-Sha1Hex -Context $Context -Text $raw
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [string]$FilePath, [string[]]$ContextLines, [int]$K = $Context.Constants.ContextHashNeighborK)
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
    return Get-Sha1Hex -Context $Context -Text $raw
}
function ConvertFrom-SvnUnifiedDiffPathHeader
{
    <#
    .SYNOPSIS
        Unified diff の --- / +++ ヘッダー行から path/revision を抽出する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line))
    {
        return $null
    }
    if (-not ($Line -like '--- *' -or $Line -like '+++ *'))
    {
        return $null
    }

    $payload = $Line.Substring(4).TrimStart()
    if ([string]::IsNullOrWhiteSpace($payload))
    {
        return [pscustomobject]@{
            Path = $null
            Revision = $null
        }
    }

    $pathPart = $payload.Trim()
    $metadata = $null
    $metadataStart = $payload.LastIndexOf('(')
    if ($metadataStart -gt 0 -and $payload.EndsWith(')') -and [char]::IsWhiteSpace($payload[$metadataStart - 1]))
    {
        $pathPart = $payload.Substring(0, $metadataStart).TrimEnd()
        $metadata = $payload.Substring($metadataStart + 1, $payload.Length - $metadataStart - 2).Trim()
    }

    $revision = $null
    if (-not [string]::IsNullOrWhiteSpace($metadata))
    {
        if ($metadata -match '^revision\s+(\d+)$')
        {
            try
            {
                $revision = [int]$Matches[1]
            }
            catch
            {
                $revision = $null
            }
        }
        elseif ([string]::Equals($metadata, 'nonexistent', [System.StringComparison]::OrdinalIgnoreCase))
        {
            $pathPart = $null
        }
    }

    $path = $null
    if (-not [string]::IsNullOrWhiteSpace($pathPart))
    {
        $path = ConvertTo-PathKey -Path $pathPart
    }
    return [pscustomobject]@{
        Path = $path
        Revision = $revision
    }
}
function Get-SvnUnifiedDiffHeaderSectionList
{
    <#
    .SYNOPSIS
        Unified diff テキストから Index 単位の old/new path+revision を抽出する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$DiffText)
    if ([string]::IsNullOrWhiteSpace($DiffText))
    {
        return @()
    }

    $sections = [System.Collections.Generic.List[object]]::new()
    $currentSection = $null
    $lines = $DiffText -split "`r?`n"
    foreach ($line in $lines)
    {
        if ($line -like 'Index: *')
        {
            if ($null -ne $currentSection)
            {
                [void]$sections.Add($currentSection)
            }
            $indexPath = ConvertTo-PathKey -Path $line.Substring(7).Trim()
            if ([string]::IsNullOrWhiteSpace($indexPath))
            {
                $currentSection = $null
                continue
            }
            $currentSection = [pscustomobject]@{
                IndexPath = $indexPath
                OldPath = $null
                OldRevision = $null
                NewPath = $null
                NewRevision = $null
            }
            continue
        }
        if ($null -eq $currentSection)
        {
            continue
        }
        if ($line -like '--- *')
        {
            $oldHeader = ConvertFrom-SvnUnifiedDiffPathHeader -Line $line
            if ($null -ne $oldHeader)
            {
                $currentSection.OldPath = $oldHeader.Path
                $currentSection.OldRevision = $oldHeader.Revision
            }
            continue
        }
        if ($line -like '+++ *')
        {
            $newHeader = ConvertFrom-SvnUnifiedDiffPathHeader -Line $line
            if ($null -ne $newHeader)
            {
                $currentSection.NewPath = $newHeader.Path
                $currentSection.NewRevision = $newHeader.Revision
            }
            continue
        }
    }
    if ($null -ne $currentSection)
    {
        [void]$sections.Add($currentSection)
    }
    return @($sections.ToArray())
}
function New-SvnUnifiedDiffParseState
{
    <#
    .SYNOPSIS
        Unified diff パース処理の内部状態を初期化する。
    .PARAMETER DetailLevel
        差分の詳細レベル。0 = サマリのみ、1 以上で hunk 詳細を含む。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [int]$DetailLevel = 0,
        [switch]$ExcludeCommentOnlyLines,
        [hashtable]$LineMaskByPath = @{}
    )
    return @{
        Context = $Context
        Result = @{}
        DetailLevel = $DetailLevel
        ExcludeCommentOnlyLines = [bool]$ExcludeCommentOnlyLines
        LineMaskByPath = if ($null -eq $LineMaskByPath)
        {
            @{}
        }
        else
        {
            $LineMaskByPath
        }
        Current = $null
        CurrentFile = $null
        CurrentOldLineMask = $null
        CurrentNewLineMask = $null
        CurrentOldCursor = 0
        CurrentNewCursor = 0
        CurrentHunk = $null
        HunkContextLines = $null
        HunkAddedHashes = $null
        HunkDeletedHashes = $null
        HunkEffectiveSegments = $null
        CurrentHunkActiveSegment = $null
    }
}
function New-SvnUnifiedDiffFileStat
{
    <#
    .SYNOPSIS
        1ファイル分の差分統計オブジェクトを生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param()
    return [pscustomobject]@{
        AddedLines = 0
        DeletedLines = 0
        Hunks = (New-Object 'System.Collections.Generic.List[object]')
        IsBinary = $false
        AddedLineHashes = (New-Object 'System.Collections.Generic.List[string]')
        DeletedLineHashes = (New-Object 'System.Collections.Generic.List[string]')
    }
}
function Complete-SvnUnifiedDiffCurrentHunk
{
    <#
    .SYNOPSIS
        進行中 hunk のコンテキストハッシュと行ハッシュを確定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([hashtable]$ParseState)
    if ($null -eq $ParseState.CurrentHunk -or $null -eq $ParseState.CurrentFile)
    {
        return
    }

    if ([bool]$ParseState.ExcludeCommentOnlyLines)
    {
        if ($null -ne $ParseState.CurrentHunkActiveSegment)
        {
            $active = $ParseState.CurrentHunkActiveSegment
            if ([int]$active.OldCount -gt 0 -or [int]$active.NewCount -gt 0)
            {
                [void]$ParseState.HunkEffectiveSegments.Add([pscustomobject]@{
                        OldStart = [int]$active.OldStart
                        OldCount = [int]$active.OldCount
                        NewStart = [int]$active.NewStart
                        NewCount = [int]$active.NewCount
                    })
            }
            $ParseState.CurrentHunkActiveSegment = $null
        }
        $effectiveSegments = @()
        if ($null -ne $ParseState.HunkEffectiveSegments)
        {
            $effectiveSegments = @($ParseState.HunkEffectiveSegments.ToArray())
        }
        $ParseState.CurrentHunk.EffectiveSegments = $effectiveSegments
    }

    if ($ParseState.DetailLevel -lt 1)
    {
        return
    }
    $contextLines = @()
    if ($null -ne $ParseState.HunkContextLines)
    {
        $contextLines = @($ParseState.HunkContextLines.ToArray())
    }
    $addedHashes = @()
    if ($null -ne $ParseState.HunkAddedHashes)
    {
        $addedHashes = @($ParseState.HunkAddedHashes.ToArray())
    }
    $deletedHashes = @()
    if ($null -ne $ParseState.HunkDeletedHashes)
    {
        $deletedHashes = @($ParseState.HunkDeletedHashes.ToArray())
    }
    $ParseState.CurrentHunk.ContextHash = ConvertTo-ContextHash -Context $ParseState.Context -FilePath $ParseState.CurrentFile -ContextLines $contextLines
    $ParseState.CurrentHunk.AddedLineHashes = $addedHashes
    $ParseState.CurrentHunk.DeletedLineHashes = $deletedHashes
}
function Reset-SvnUnifiedDiffCurrentHunkState
{
    <#
    .SYNOPSIS
        パース中の hunk 追跡状態を初期化する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([hashtable]$ParseState)
    $ParseState.CurrentHunk = $null
    $ParseState.CurrentOldCursor = 0
    $ParseState.CurrentNewCursor = 0
    $ParseState.HunkContextLines = $null
    $ParseState.HunkAddedHashes = $null
    $ParseState.HunkDeletedHashes = $null
    $ParseState.HunkEffectiveSegments = $null
    $ParseState.CurrentHunkActiveSegment = $null
}
function Start-SvnUnifiedDiffFileSection
{
    <#
    .SYNOPSIS
        Index 行を処理してファイル境界を切り替える。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([hashtable]$ParseState, [string]$Line)
    Complete-SvnUnifiedDiffCurrentHunk -ParseState $ParseState
    $file = ConvertTo-PathKey -Path $Line.Substring(7).Trim()
    if ($file)
    {
        if (-not $ParseState.Result.ContainsKey($file))
        {
            $ParseState.Result[$file] = New-SvnUnifiedDiffFileStat
        }
        $ParseState.Current = $ParseState.Result[$file]
        $ParseState.CurrentFile = $file
        $ParseState.CurrentOldLineMask = $null
        $ParseState.CurrentNewLineMask = $null
        if ([bool]$ParseState.ExcludeCommentOnlyLines -and $null -ne $ParseState.LineMaskByPath -and $ParseState.LineMaskByPath.ContainsKey($file))
        {
            $maskEntry = $ParseState.LineMaskByPath[$file]
            if ($null -ne $maskEntry)
            {
                if ($maskEntry.PSObject.Properties.Match('OldMask').Count -gt 0)
                {
                    $ParseState.CurrentOldLineMask = $maskEntry.OldMask
                }
                if ($maskEntry.PSObject.Properties.Match('NewMask').Count -gt 0)
                {
                    $ParseState.CurrentNewLineMask = $maskEntry.NewMask
                }
            }
        }
    }
    else
    {
        $ParseState.Current = $null
        $ParseState.CurrentFile = $null
        $ParseState.CurrentOldLineMask = $null
        $ParseState.CurrentNewLineMask = $null
    }
    Reset-SvnUnifiedDiffCurrentHunkState -ParseState $ParseState
}
function Start-SvnUnifiedDiffHunkSection
{
    <#
    .SYNOPSIS
        hunk ヘッダー行を処理して hunk 状態を開始する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$ParseState,
        [int]$OldStart,
        [int]$OldCount,
        [int]$NewStart,
        [int]$NewCount
    )
    Complete-SvnUnifiedDiffCurrentHunk -ParseState $ParseState
    $hunkObj = [pscustomobject]@{
        OldStart = $OldStart
        OldCount = $OldCount
        NewStart = $NewStart
        NewCount = $NewCount
        ContextHash = $null
        AddedLineHashes = @()
        DeletedLineHashes = @()
        EffectiveSegments = $null
    }
    [void]$ParseState.Current.Hunks.Add($hunkObj)
    $ParseState.CurrentHunk = $hunkObj
    $ParseState.CurrentOldCursor = [int]$OldStart
    $ParseState.CurrentNewCursor = [int]$NewStart
    $ParseState.CurrentHunkActiveSegment = $null
    if ([bool]$ParseState.ExcludeCommentOnlyLines)
    {
        $ParseState.HunkEffectiveSegments = New-Object 'System.Collections.Generic.List[object]'
    }
    else
    {
        $ParseState.HunkEffectiveSegments = $null
    }
    if ($ParseState.DetailLevel -ge 1)
    {
        $ParseState.HunkContextLines = New-Object 'System.Collections.Generic.List[string]'
        $ParseState.HunkAddedHashes = New-Object 'System.Collections.Generic.List[string]'
        $ParseState.HunkDeletedHashes = New-Object 'System.Collections.Generic.List[string]'
    }
    else
    {
        $ParseState.HunkContextLines = $null
        $ParseState.HunkAddedHashes = $null
        $ParseState.HunkDeletedHashes = $null
    }
}
function Test-SvnUnifiedDiffBinaryMarker
{
    <#
    .SYNOPSIS
        差分行がバイナリ変更マーカーかを判定する。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Line)
    if ($Line -match '^Cannot display: file marked as a binary type\.' -or $Line -match '^Binary files .* differ' -or $Line -match '(?i)mime-type\s*=\s*application/octet-stream')
    {
        return $true
    }
    return $false
}
function Update-SvnUnifiedDiffLineStat
{
    <#
    .SYNOPSIS
        差分1行から行統計とハッシュ情報を更新する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([hashtable]$ParseState, [string]$Line)
    if (-not $Line)
    {
        return
    }
    # 最頻出文字を先にチェックして分岐を減らす。
    $ch = $Line[0]
    if ($ch -eq '+')
    {
        if ($Line.Length -ge 3 -and $Line[1] -eq '+' -and $Line[2] -eq '+')
        {
            return
        }
        $isCommentOnly = $false
        if ([bool]$ParseState.ExcludeCommentOnlyLines -and $null -ne $ParseState.CurrentNewLineMask)
        {
            $newLineIndex = [int]$ParseState.CurrentNewCursor - 1
            if ($newLineIndex -ge 0 -and $newLineIndex -lt $ParseState.CurrentNewLineMask.Length)
            {
                $isCommentOnly = [bool]$ParseState.CurrentNewLineMask[$newLineIndex]
            }
        }
        if (-not $isCommentOnly)
        {
            $ParseState.Current.AddedLines++
            if ($ParseState.DetailLevel -ge 1 -and $null -ne $ParseState.CurrentFile)
            {
                $content = $Line.Substring(1)
                $hashValue = ConvertTo-LineHash -Context $ParseState.Context -FilePath $ParseState.CurrentFile -Content $content
                $ParseState.Current.AddedLineHashes.Add($hashValue)
                if ($null -ne $ParseState.HunkAddedHashes)
                {
                    $ParseState.HunkAddedHashes.Add($hashValue)
                }
            }
            if ([bool]$ParseState.ExcludeCommentOnlyLines)
            {
                if ($null -eq $ParseState.CurrentHunkActiveSegment)
                {
                    $ParseState.CurrentHunkActiveSegment = [pscustomobject]@{
                        OldStart = [int]$ParseState.CurrentOldCursor
                        OldCount = 0
                        NewStart = [int]$ParseState.CurrentNewCursor
                        NewCount = 0
                    }
                }
                $ParseState.CurrentHunkActiveSegment.NewCount = [int]$ParseState.CurrentHunkActiveSegment.NewCount + 1
            }
        }
        $ParseState.CurrentNewCursor++
        return
    }
    if ($ch -eq '-')
    {
        if ($Line.Length -ge 3 -and $Line[1] -eq '-' -and $Line[2] -eq '-')
        {
            return
        }
        $isCommentOnly = $false
        if ([bool]$ParseState.ExcludeCommentOnlyLines -and $null -ne $ParseState.CurrentOldLineMask)
        {
            $oldLineIndex = [int]$ParseState.CurrentOldCursor - 1
            if ($oldLineIndex -ge 0 -and $oldLineIndex -lt $ParseState.CurrentOldLineMask.Length)
            {
                $isCommentOnly = [bool]$ParseState.CurrentOldLineMask[$oldLineIndex]
            }
        }
        if (-not $isCommentOnly)
        {
            $ParseState.Current.DeletedLines++
            if ($ParseState.DetailLevel -ge 1 -and $null -ne $ParseState.CurrentFile)
            {
                $content = $Line.Substring(1)
                $hashValue = ConvertTo-LineHash -Context $ParseState.Context -FilePath $ParseState.CurrentFile -Content $content
                $ParseState.Current.DeletedLineHashes.Add($hashValue)
                if ($null -ne $ParseState.HunkDeletedHashes)
                {
                    $ParseState.HunkDeletedHashes.Add($hashValue)
                }
            }
            if ([bool]$ParseState.ExcludeCommentOnlyLines)
            {
                if ($null -eq $ParseState.CurrentHunkActiveSegment)
                {
                    $ParseState.CurrentHunkActiveSegment = [pscustomobject]@{
                        OldStart = [int]$ParseState.CurrentOldCursor
                        OldCount = 0
                        NewStart = [int]$ParseState.CurrentNewCursor
                        NewCount = 0
                    }
                }
                $ParseState.CurrentHunkActiveSegment.OldCount = [int]$ParseState.CurrentHunkActiveSegment.OldCount + 1
            }
        }
        $ParseState.CurrentOldCursor++
        return
    }
    if ($ch -eq ' ' -and $ParseState.DetailLevel -ge 1 -and $null -ne $ParseState.HunkContextLines)
    {
        if ([bool]$ParseState.ExcludeCommentOnlyLines -and $null -ne $ParseState.CurrentHunkActiveSegment)
        {
            $activeSegment = $ParseState.CurrentHunkActiveSegment
            if ([int]$activeSegment.OldCount -gt 0 -or [int]$activeSegment.NewCount -gt 0)
            {
                [void]$ParseState.HunkEffectiveSegments.Add([pscustomobject]@{
                        OldStart = [int]$activeSegment.OldStart
                        OldCount = [int]$activeSegment.OldCount
                        NewStart = [int]$activeSegment.NewStart
                        NewCount = [int]$activeSegment.NewCount
                    })
            }
            $ParseState.CurrentHunkActiveSegment = $null
        }
        $ParseState.HunkContextLines.Add($Line.Substring(1))
        $ParseState.CurrentOldCursor++
        $ParseState.CurrentNewCursor++
        return
    }
    if ($ch -eq ' ')
    {
        if ([bool]$ParseState.ExcludeCommentOnlyLines -and $null -ne $ParseState.CurrentHunkActiveSegment)
        {
            $activeSegment = $ParseState.CurrentHunkActiveSegment
            if ([int]$activeSegment.OldCount -gt 0 -or [int]$activeSegment.NewCount -gt 0)
            {
                [void]$ParseState.HunkEffectiveSegments.Add([pscustomobject]@{
                        OldStart = [int]$activeSegment.OldStart
                        OldCount = [int]$activeSegment.OldCount
                        NewStart = [int]$activeSegment.NewStart
                        NewCount = [int]$activeSegment.NewCount
                    })
            }
            $ParseState.CurrentHunkActiveSegment = $null
        }
        $ParseState.CurrentOldCursor++
        $ParseState.CurrentNewCursor++
        return
    }
    if ($ch -eq '\' -and $Line -eq '\ No newline at end of file')
    {
        return
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
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$DiffText,
        [int]$DetailLevel = 0,
        [switch]$ExcludeCommentOnlyLines,
        [hashtable]$LineMaskByPath = @{}
    )
    if ([string]::IsNullOrWhiteSpace($DiffText))
    {
        return @{}
    }
    $parseState = New-SvnUnifiedDiffParseState -Context $Context -DetailLevel $DetailLevel -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines -LineMaskByPath $LineMaskByPath
    $lines = $DiffText -split "`r?`n"
    foreach ($line in $lines)
    {
        # ファイル境界を先に確定し、前hunkの確定漏れを防ぐ。
        if ($line -like 'Index: *')
        {
            Start-SvnUnifiedDiffFileSection -ParseState $parseState -Line $line
            continue
        }
        if ($null -eq $parseState.Current)
        {
            continue
        }
        # hunk単位で位置情報を持ち、後段の行追跡精度を担保する。
        if ($line -match '^@@\s*-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s*@@')
        {
            $oldCount = if ($Matches[2])
            {
                [int]$Matches[2]
            }
            else
            {
                1
            }
            $newCount = if ($Matches[4])
            {
                [int]$Matches[4]
            }
            else
            {
                1
            }
            Start-SvnUnifiedDiffHunkSection -ParseState $parseState -OldStart ([int]$Matches[1]) -OldCount $oldCount -NewStart ([int]$Matches[3]) -NewCount $newCount
            continue
        }
        # バイナリは行追跡不能なため早期にテキスト解析対象から外す。
        if (Test-SvnUnifiedDiffBinaryMarker -Line $line)
        {
            $parseState.Current.IsBinary = $true
            continue
        }
        Update-SvnUnifiedDiffLineStat -ParseState $parseState -Line $line
    }
    Complete-SvnUnifiedDiffCurrentHunk -ParseState $parseState
    return $parseState.Result
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
    [CmdletBinding()]
    param(
        [string]$XmlText,
        [string[]]$ContentLines,
        [bool]$NeedLines = $true
    )
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
    $byRevAuthor = @{}
    $lineRows = if ($NeedLines)
    {
        New-Object 'System.Collections.Generic.List[object]'
    }
    else
    {
        $null
    }
    $total = 0
    foreach ($entry in $entries)
    {
        $total++
        $commit = $entry.commit
        $lineNumber = $total
        if ($NeedLines)
        {
            try
            {
                $lineNumber = [int]$entry.'line-number'
            }
            catch
            {
                $lineNumber = $total
            }
        }
        $rev = $null
        $author = '(unknown)'
        if ($null -eq $commit)
        {
            if ($NeedLines)
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
            }
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
            if (-not $byRevAuthor.ContainsKey($rev))
            {
                $byRevAuthor[$rev] = @{}
            }
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
        if ($null -ne $rev)
        {
            if (-not $byRevAuthor[$rev].ContainsKey($author))
            {
                $byRevAuthor[$rev][$author] = 0
            }
            $byRevAuthor[$rev][$author]++
        }
        if (-not $byAuthor.ContainsKey($author))
        {
            $byAuthor[$author] = 0
        }
        $byAuthor[$author]++

        if ($NeedLines)
        {
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
    }
    $lines = @()
    if ($NeedLines -and $null -ne $lineRows)
    {
        $lines = @($lineRows.ToArray())
    }
    # blame XML の entry は line-number 昇順で出力されるため再ソート不要
    return [pscustomobject]@{
        LineCountTotal = $total
        LineCountByRevision = $byRev
        LineCountByAuthor = $byAuthor
        LineCountByRevisionAuthor = $byRevAuthor
        Lines = $lines
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
    [CmdletBinding()]
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [string]$Repo, [string]$FilePath, [int]$ToRevision, [string]$CacheDir)
    # インメモリキャッシュにヒットすればディスク読み込み・XML パースを完全に回避する。
    # 所有権分析フェーズでは同一ファイルに複数回アクセスされるため効果が大きい。
    if ($null -eq $Context.Caches.SvnBlameSummaryMemoryCache)
    {
        $Context.Caches.SvnBlameSummaryMemoryCache = @{}
    }
    $excludeCommentOnlyLines = Get-ContextRuntimeSwitchValue -Context $Context -PropertyName 'ExcludeCommentOnlyLines'
    $summaryCacheVariant = if ($excludeCommentOnlyLines)
    {
        'summary.excludecomment.1'
    }
    else
    {
        'summary.excludecomment.0'
    }
    $cacheKey = Get-BlameMemoryCacheKey -Revision $ToRevision -FilePath $FilePath -Variant $summaryCacheVariant
    if ($Context.Caches.SvnBlameSummaryMemoryCache.ContainsKey($cacheKey))
    {
        $Context.Caches.StrictBlameCacheHits++
        return (New-NarutoResultSuccess -Data $Context.Caches.SvnBlameSummaryMemoryCache[$cacheKey] -ErrorCode 'SVN_BLAME_SUMMARY_CACHE_HIT')
    }

    $url = $Repo.TrimEnd('/') + '/' + (ConvertTo-PathKey -Path $FilePath).TrimStart('/') + '@' + [string]$ToRevision
    $text = Read-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath
    $fetchResult = $null
    if ([string]::IsNullOrWhiteSpace($text))
    {
        $Context.Caches.StrictBlameCacheMisses++
        $fetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('blame', '--xml', '-r', [string]$ToRevision, $url) -ErrorContext ("svn blame $FilePath")
        $fetchResult = ConvertTo-NarutoResultAdapter -InputObject $fetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
        if (Test-NarutoResultSuccess -Result $fetchResult)
        {
            $text = [string]$fetchResult.Data
        }
        else
        {
            $text = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($text))
        {
            Write-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $ToRevision -FilePath $FilePath -Content $text
        }
    }
    else
    {
        $Context.Caches.StrictBlameCacheHits++
    }
    if ([string]::IsNullOrWhiteSpace($text))
    {
        $empty = Get-EmptyBlameResult
        $Context.Caches.SvnBlameSummaryMemoryCache[$cacheKey] = $empty
        $skipCode = 'SVN_BLAME_SUMMARY_EMPTY'
        $skipMessage = ("svn blame summary is empty for '{0}' at r{1}." -f $FilePath, $ToRevision)
        if ($null -ne $fetchResult -and [string]$fetchResult.Status -eq 'Skipped')
        {
            $skipCode = [string]$fetchResult.ErrorCode
            $skipMessage = [string]$fetchResult.Message
        }
        return (New-NarutoResultSkipped -Data $empty -ErrorCode $skipCode -Message $skipMessage -Context @{
                FilePath = $FilePath
                Revision = [int]$ToRevision
            })
    }
    $commentProfile = $null
    $contentLines = $null
    if ($excludeCommentOnlyLines)
    {
        $commentProfile = Get-CommentSyntaxProfileByPath -Context $Context -FilePath $FilePath
        if ($null -ne $commentProfile)
        {
            $catText = Get-CachedOrFetchCatText -Context $Context -Repo $Repo -FilePath $FilePath -Revision $ToRevision -CacheDir $CacheDir
            if ($null -ne $catText)
            {
                $contentLines = ConvertTo-TextLine -Text $catText
            }
        }
    }
    if ($null -ne $contentLines)
    {
        $parsed = ConvertFrom-SvnBlameXml -XmlText $text -ContentLines $contentLines
    }
    else
    {
        $parsed = ConvertFrom-SvnBlameXml -XmlText $text
    }
    if ($excludeCommentOnlyLines -and $null -ne $commentProfile -and $null -ne $contentLines)
    {
        $commentMask = ConvertTo-CommentOnlyLineMask -Lines $contentLines -CommentSyntaxProfile $commentProfile
        $filteredLines = @(Get-NonCommentLineEntry -Lines @($parsed.Lines) -CommentOnlyLineMask $commentMask)
        $lineCountByRevision = @{}
        $lineCountByAuthor = @{}
        foreach ($lineEntry in @($filteredLines))
        {
            $lineRevision = $null
            try
            {
                $lineRevision = [int]$lineEntry.Revision
            }
            catch
            {
                $lineRevision = $null
            }
            if ($null -ne $lineRevision)
            {
                if (-not $lineCountByRevision.ContainsKey($lineRevision))
                {
                    $lineCountByRevision[$lineRevision] = 0
                }
                $lineCountByRevision[$lineRevision]++
            }
            $lineAuthor = [string]$lineEntry.Author
            if ([string]::IsNullOrWhiteSpace($lineAuthor))
            {
                $lineAuthor = '(unknown)'
            }
            if (-not $lineCountByAuthor.ContainsKey($lineAuthor))
            {
                $lineCountByAuthor[$lineAuthor] = 0
            }
            $lineCountByAuthor[$lineAuthor]++
        }
        $parsed = [pscustomobject]@{
            LineCountTotal = @($filteredLines).Count
            LineCountByRevision = $lineCountByRevision
            LineCountByAuthor = $lineCountByAuthor
            Lines = @($filteredLines)
        }
    }
    $Context.Caches.SvnBlameSummaryMemoryCache[$cacheKey] = $parsed
    return (New-NarutoResultSuccess -Data $parsed -ErrorCode 'SVN_BLAME_SUMMARY_READY')
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
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Repo,
        [string]$FilePath,
        [int]$Revision,
        [string]$CacheDir,
        [bool]$NeedContent = $true,
        [bool]$NeedLines = $true
    )
    # インメモリキャッシュにヒットすればディスク読み込み (blame XML + cat テキスト) と
    # XML パースを完全に回避する。同一コミット内で同じファイルが複数トランジションから
    # 参照されるケースで効果がある。コミット境界で Clear() されるため無制限には成長しない。
    if ($null -eq $Context.Caches.SvnBlameLineMemoryCache)
    {
        $Context.Caches.SvnBlameLineMemoryCache = @{}
    }
    $needContentFlag = [bool]$NeedContent
    $needLinesFlag = [bool]$NeedLines
    $effectiveNeedContent = $needContentFlag -and $needLinesFlag
    $cacheVariant = "line.withcontent.{0}.withlines.{1}" -f ([int]$needContentFlag), ([int]$needLinesFlag)
    $cacheKey = Get-BlameMemoryCacheKey -Revision $Revision -FilePath $FilePath -Variant $cacheVariant
    if ($Context.Caches.SvnBlameLineMemoryCache.ContainsKey($cacheKey))
    {
        $Context.Caches.StrictBlameCacheHits++
        return (New-NarutoResultSuccess -Data $Context.Caches.SvnBlameLineMemoryCache[$cacheKey] -ErrorCode 'SVN_BLAME_LINE_CACHE_HIT')
    }

    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision

    $blameXml = Read-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    $blameFetchResult = $null
    if ([string]::IsNullOrWhiteSpace($blameXml))
    {
        $Context.Caches.StrictBlameCacheMisses++
        $blameFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        $blameFetchResult = ConvertTo-NarutoResultAdapter -InputObject $blameFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
        if (Test-NarutoResultSuccess -Result $blameFetchResult)
        {
            $blameXml = [string]$blameFetchResult.Data
        }
        else
        {
            $blameXml = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($blameXml))
        {
            Write-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
        }
    }
    else
    {
        $Context.Caches.StrictBlameCacheHits++
    }

    $catText = $null
    $catFetchResult = $null
    if ($effectiveNeedContent)
    {
        $catText = Read-CatCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
        if ($null -eq $catText)
        {
            $catFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
            $catFetchResult = ConvertTo-NarutoResultAdapter -InputObject $catFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
            if (Test-NarutoResultSuccess -Result $catFetchResult)
            {
                $catText = [string]$catFetchResult.Data
            }
            else
            {
                $catText = $null
            }
            if ($null -ne $catText)
            {
                Write-CatCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($blameXml) -or ($effectiveNeedContent -and $null -eq $catText))
    {
        $empty = Get-EmptyBlameResult
        $Context.Caches.SvnBlameLineMemoryCache[$cacheKey] = $empty
        $skipCode = 'SVN_BLAME_LINE_EMPTY'
        $skipMessage = ("svn blame line is empty for '{0}' at r{1}." -f $FilePath, $Revision)
        if ($null -ne $blameFetchResult -and [string]$blameFetchResult.Status -eq 'Skipped')
        {
            $skipCode = [string]$blameFetchResult.ErrorCode
            $skipMessage = [string]$blameFetchResult.Message
        }
        elseif ($effectiveNeedContent -and $null -ne $catFetchResult -and [string]$catFetchResult.Status -eq 'Skipped')
        {
            $skipCode = [string]$catFetchResult.ErrorCode
            $skipMessage = [string]$catFetchResult.Message
        }
        return (New-NarutoResultSkipped -Data $empty -ErrorCode $skipCode -Message $skipMessage -Context @{
                FilePath = $FilePath
                Revision = [int]$Revision
            })
    }
    if ($effectiveNeedContent)
    {
        $contentLines = ConvertTo-TextLine -Text $catText
        $parsed = ConvertFrom-SvnBlameXml -XmlText $blameXml -ContentLines $contentLines -NeedLines:$needLinesFlag
    }
    else
    {
        $parsed = ConvertFrom-SvnBlameXml -XmlText $blameXml -NeedLines:$needLinesFlag
    }
    $Context.Caches.SvnBlameLineMemoryCache[$cacheKey] = $parsed
    return (New-NarutoResultSuccess -Data $parsed -ErrorCode 'SVN_BLAME_LINE_READY')
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Repo,
        [string]$FilePath,
        [int]$Revision,
        [string]$CacheDir,
        [bool]$NeedContent = $true
    )
    if ($Revision -le 0 -or [string]::IsNullOrWhiteSpace($FilePath))
    {
        return (New-NarutoResultSkipped -Data ([pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                }) -ErrorCode 'SVN_BLAME_CACHE_INVALID_ARGUMENT' -Message 'blame キャッシュ対象の引数が無効なためスキップしました。' -Context @{
                FilePath = $FilePath
                Revision = [int]$Revision
            })
    }

    $path = (ConvertTo-PathKey -Path $FilePath).TrimStart('/')
    $url = $Repo.TrimEnd('/') + '/' + $path + '@' + [string]$Revision

    $hits = 0
    $misses = 0
    $skipReason = $null

    $blameCachePath = Get-BlameCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
    $hasBlameCache = [System.IO.File]::Exists($blameCachePath)
    if ($hasBlameCache)
    {
        try
        {
            if (([System.IO.FileInfo]$blameCachePath).Length -le 0)
            {
                $hasBlameCache = $false
            }
        }
        catch
        {
            $hasBlameCache = $false
        }
    }
    if (-not $hasBlameCache)
    {
        $misses++
        $blameFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('blame', '--xml', '-r', [string]$Revision, $url) -ErrorContext ("svn blame $FilePath@$Revision")
        $blameFetchResult = ConvertTo-NarutoResultAdapter -InputObject $blameFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
        if (Test-NarutoResultSuccess -Result $blameFetchResult)
        {
            $blameXml = [string]$blameFetchResult.Data
            if (-not [string]::IsNullOrWhiteSpace($blameXml))
            {
                Write-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $blameXml
                $hasBlameCache = $true
            }
        }
        else
        {
            $skipReason = $blameFetchResult
        }
    }
    else
    {
        $hits++
    }

    $hasCatCache = $true
    if ($NeedContent)
    {
        $catCachePath = Get-CatCachePath -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath
        $hasCatCache = [System.IO.File]::Exists($catCachePath)
        if (-not $hasCatCache)
        {
            $misses++
            $catFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments @('cat', '-r', [string]$Revision, $url) -ErrorContext ("svn cat $FilePath@$Revision")
            $catFetchResult = ConvertTo-NarutoResultAdapter -InputObject $catFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
            if (Test-NarutoResultSuccess -Result $catFetchResult)
            {
                $catText = [string]$catFetchResult.Data
                Write-CatCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $FilePath -Content $catText
                $hasCatCache = $true
            }
            else
            {
                if ($null -eq $skipReason)
                {
                    $skipReason = $catFetchResult
                }
            }
        }
        else
        {
            $hits++
        }
    }

    $cacheStat = [pscustomobject]@{
        CacheHits = $hits
        CacheMisses = $misses
    }
    if (-not $hasBlameCache -or ($NeedContent -and -not $hasCatCache))
    {
        if ($null -eq $skipReason)
        {
            $skipReason = New-NarutoResultSkipped -ErrorCode 'SVN_BLAME_LINE_EMPTY' -Message ("svn blame line cache is empty for '{0}' at r{1}." -f $FilePath, $Revision)
        }
    }
    if ($null -ne $skipReason -and [string]$skipReason.Status -eq 'Skipped')
    {
        return (New-NarutoResultSkipped -Data $cacheStat -ErrorCode ([string]$skipReason.ErrorCode) -Message ([string]$skipReason.Message) -Context @{
                FilePath = $FilePath
                Revision = [int]$Revision
            })
    }
    return (New-NarutoResultSuccess -Data $cacheStat -ErrorCode 'SVN_BLAME_CACHE_READY')
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
        $dpCurr[0] = 0
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
function Get-BlamePrelockedPairPlan
{
    <#
    .SYNOPSIS
        diff hunk から不変区間の対応インデックスを生成する。
    .DESCRIPTION
        hunk の旧/新開始位置からギャップ区間を算出し、変更されていない範囲を
        1対1対応として返す。これにより LCS の探索対象を変更区間へ絞る。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [int]$PreviousLineCount,
        [int]$CurrentLineCount,
        [object[]]$Hunks
    )
    if ($PreviousLineCount -le 0 -or $CurrentLineCount -le 0)
    {
        return @()
    }
    $normalizedHunks = @(ConvertTo-StrictHunkList -HunksRaw $Hunks | Sort-Object OldStart, NewStart)
    if ($normalizedHunks.Count -eq 0)
    {
        return @()
    }

    $pairs = New-Object 'System.Collections.Generic.List[object]'
    $oldCursor = 1
    $newCursor = 1
    foreach ($hunk in @($normalizedHunks))
    {
        $oldStart = [Math]::Max(1, [int]$hunk.OldStart)
        $newStart = [Math]::Max(1, [int]$hunk.NewStart)
        $oldGap = [Math]::Max(0, $oldStart - $oldCursor)
        $newGap = [Math]::Max(0, $newStart - $newCursor)
        $lockCount = [Math]::Min($oldGap, $newGap)
        for ($i = 0
            $i -lt $lockCount
            $i++)
        {
            $prevIndex = $oldCursor + $i - 1
            $currIndex = $newCursor + $i - 1
            if ($prevIndex -lt 0 -or $currIndex -lt 0 -or $prevIndex -ge $PreviousLineCount -or $currIndex -ge $CurrentLineCount)
            {
                continue
            }
            [void]$pairs.Add([pscustomobject]@{
                    PrevIndex = [int]$prevIndex
                    CurrIndex = [int]$currIndex
                })
        }
        $oldCount = [Math]::Max(0, [int]$hunk.OldCount)
        $newCount = [Math]::Max(0, [int]$hunk.NewCount)
        $oldCursor = [Math]::Max($oldCursor, $oldStart + $oldCount)
        $newCursor = [Math]::Max($newCursor, $newStart + $newCount)
    }

    $oldTail = [Math]::Max(0, $PreviousLineCount - $oldCursor + 1)
    $newTail = [Math]::Max(0, $CurrentLineCount - $newCursor + 1)
    $tailCount = [Math]::Min($oldTail, $newTail)
    for ($i = 0
        $i -lt $tailCount
        $i++)
    {
        $prevIndex = $oldCursor + $i - 1
        $currIndex = $newCursor + $i - 1
        if ($prevIndex -lt 0 -or $currIndex -lt 0 -or $prevIndex -ge $PreviousLineCount -or $currIndex -ge $CurrentLineCount)
        {
            continue
        }
        [void]$pairs.Add([pscustomobject]@{
                PrevIndex = [int]$prevIndex
                CurrIndex = [int]$currIndex
            })
    }
    return @($pairs.ToArray())
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
    param(
        [object[]]$PreviousLines,
        [object[]]$CurrentLines,
        [object[]]$PrelockedPairs = @(),
        [switch]$MinimalOutput
    )

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

    $state = New-BlameCompareState -PreviousLines $prev -CurrentLines $curr -TrackMatchedPairs:$(-not $MinimalOutput)

    # diff hunk 由来の不変区間を先に固定し、LCS の探索対象を変更区間へ限定する。
    foreach ($prelockedPair in @($PrelockedPairs))
    {
        $prevIdx = [int]$prelockedPair.PrevIndex
        $currIdx = [int]$prelockedPair.CurrIndex
        if ($prevIdx -lt 0 -or $currIdx -lt 0 -or $prevIdx -ge $m -or $currIdx -ge $n)
        {
            continue
        }
        if ($state.PreviousMatched[$prevIdx] -or $state.CurrentMatched[$currIdx])
        {
            continue
        }
        if ($prevIdentity[$prevIdx] -ceq $currIdentity[$currIdx])
        {
            $state.PreviousMatched[$prevIdx] = $true
            $state.CurrentMatched[$currIdx] = $true
        }
    }

    Lock-BlamePrefixSuffixMatch -State $state -PreviousIdentity $prevIdentity -CurrentIdentity $currIdentity
    # まず identity LCS で帰属が同じ行を優先一致させる。
    Add-BlameLcsMatch -State $state -PreviousKeys $prevIdentity -CurrentKeys $currIdentity -MatchType 'LcsIdentity'
    $movedPairs = @(Get-BlameMovedPairList -State $state -PreviousIdentity $prevIdentity -CurrentIdentity $currIdentity)
    # 次に content LCS で帰属変更行を救済し誤検出を減らす。
    if (Test-BlameHasUnmatchedSharedKey -PreviousKeys $prevContent -CurrentKeys $currContent -PreviousMatched $state.PreviousMatched -CurrentMatched $state.CurrentMatched)
    {
        Add-BlameLcsMatch -State $state -PreviousKeys $prevContent -CurrentKeys $currContent -MatchType 'LcsContent'
    }

    # 最後に未一致残余を born/dead として確定する。
    $killed = @(Get-BlameUnmatchedLineList -Lines $prev -MatchedFlags $state.PreviousMatched)
    $born = @(Get-BlameUnmatchedLineList -Lines $curr -MatchedFlags $state.CurrentMatched)
    $matchedPairs = @()
    $reattributed = @()
    if (-not $MinimalOutput)
    {
        $matchedPairs = @($state.MatchedPairs.ToArray() | Sort-Object PrevIndex, CurrIndex)
        $reattributed = @(Get-BlameReattributedPairList -MatchedPairs @($matchedPairs))
    }

    return [pscustomobject]@{
        KilledLines = $killed
        BornLines = $born
        MatchedPairs = $matchedPairs
        MovedPairs = $movedPairs
        ReattributedPairs = $reattributed
    }
}
function New-BlameCompareState
{
    <#
    .SYNOPSIS
        Blame 比較処理の共有状態 DTO を生成する。
    .PARAMETER PreviousLines
        比較元の blame 行配列。
    .PARAMETER CurrentLines
        比較先の blame 行配列。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object[]]$PreviousLines,
        [object[]]$CurrentLines,
        [switch]$TrackMatchedPairs
    )
    $m = $PreviousLines.Count
    $n = $CurrentLines.Count
    return @{
        PreviousLines = $PreviousLines
        CurrentLines = $CurrentLines
        TrackMatchedPairs = [bool]$TrackMatchedPairs
        PreviousMatched = (New-Object 'bool[]' $m)
        CurrentMatched = (New-Object 'bool[]' $n)
        MatchedPairs = (New-Object 'System.Collections.Generic.List[object]')
    }
}
function Add-BlameMatchedPair
{
    <#
    .SYNOPSIS
        blame 比較の一致ペアを追加し一致フラグを更新する。
    .PARAMETER State
        New-BlameCompareState で生成した共有状態 DTO。
    .PARAMETER PrevIndex
        一致した Previous 側の行インデックス。
    .PARAMETER CurrIndex
        一致した Current 側の行インデックス。
    .PARAMETER MatchType
        一致分類ラベル（LcsIdentity / Move / LcsContent）。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [int]$PrevIndex,
        [int]$CurrIndex,
        [string]$MatchType
    )
    $State.PreviousMatched[$PrevIndex] = $true
    $State.CurrentMatched[$CurrIndex] = $true
    if ([bool]$State.TrackMatchedPairs)
    {
        [void]$State.MatchedPairs.Add([pscustomobject]@{
                PrevIndex = [int]$PrevIndex
                CurrIndex = [int]$CurrIndex
                PrevLine = $State.PreviousLines[$PrevIndex]
                CurrLine = $State.CurrentLines[$CurrIndex]
                MatchType = $MatchType
            })
    }
}
function Lock-BlamePrefixSuffixMatch
{
    <#
    .SYNOPSIS
        blame 前後配列の prefix/suffix 一致を固定する。
    .PARAMETER State
        New-BlameCompareState で生成した共有状態 DTO。
    .PARAMETER PreviousIdentity
        Previous 側の identity キー配列。
    .PARAMETER CurrentIdentity
        Current 側の identity キー配列。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [string[]]$PreviousIdentity,
        [string[]]$CurrentIdentity
    )
    $m = $PreviousIdentity.Count
    $n = $CurrentIdentity.Count
    $prefix = 0
    while ($prefix -lt $m -and $prefix -lt $n -and $PreviousIdentity[$prefix] -ceq $CurrentIdentity[$prefix])
    {
        Add-BlameMatchedPair -State $State -PrevIndex $prefix -CurrIndex $prefix -MatchType 'LcsIdentity'
        $prefix++
    }

    $suffixPrev = $m - 1
    $suffixCurr = $n - 1
    $suffixPairs = New-Object 'System.Collections.Generic.List[object]'
    while ($suffixPrev -ge $prefix -and $suffixCurr -ge $prefix -and $PreviousIdentity[$suffixPrev] -ceq $CurrentIdentity[$suffixCurr])
    {
        [void]$suffixPairs.Add([pscustomobject]@{
                PrevIndex = [int]$suffixPrev
                CurrIndex = [int]$suffixCurr
            })
        $suffixPrev--
        $suffixCurr--
    }
    for ($suffixIdx = $suffixPairs.Count - 1
        $suffixIdx -ge 0
        $suffixIdx--)
    {
        $suffixPair = $suffixPairs[$suffixIdx]
        Add-BlameMatchedPair -State $State -PrevIndex ([int]$suffixPair.PrevIndex) -CurrIndex ([int]$suffixPair.CurrIndex) -MatchType 'LcsIdentity'
    }
}
function Add-BlameLcsMatch
{
    <#
    .SYNOPSIS
        指定キーで LCS 一致を適用する。
    .PARAMETER State
        New-BlameCompareState で生成した共有状態 DTO。
    .PARAMETER PreviousKeys
        Previous 側の比較キー配列。
    .PARAMETER CurrentKeys
        Current 側の比較キー配列。
    .PARAMETER MatchType
        一致分類ラベル。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [string[]]$PreviousKeys,
        [string[]]$CurrentKeys,
        [string]$MatchType
    )
    foreach ($pair in @(Get-LcsMatchedPair -PreviousKeys $PreviousKeys -CurrentKeys $CurrentKeys -PreviousLocked $State.PreviousMatched -CurrentLocked $State.CurrentMatched))
    {
        $prevIdx = [int]$pair.PrevIndex
        $currIdx = [int]$pair.CurrIndex
        if ($State.PreviousMatched[$prevIdx] -or $State.CurrentMatched[$currIdx])
        {
            continue
        }
        Add-BlameMatchedPair -State $State -PrevIndex $prevIdx -CurrIndex $currIdx -MatchType $MatchType
    }
}
function Test-BlameHasUnmatchedSharedKey
{
    <#
    .SYNOPSIS
        未一致要素に共通キーが存在するかを判定する。
    .PARAMETER PreviousKeys
        Previous 側の比較キー配列。
    .PARAMETER CurrentKeys
        Current 側の比較キー配列。
    .PARAMETER PreviousMatched
        Previous 側の一致済みフラグ配列。
    .PARAMETER CurrentMatched
        Current 側の一致済みフラグ配列。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$PreviousKeys,
        [string[]]$CurrentKeys,
        [bool[]]$PreviousMatched,
        [bool[]]$CurrentMatched
    )
    $candidateKeys = @{}
    for ($pi = 0
        $pi -lt $PreviousKeys.Count
        $pi++)
    {
        if ($PreviousMatched[$pi])
        {
            continue
        }
        $candidateKeys[$PreviousKeys[$pi]] = $true
    }
    if ($candidateKeys.Count -eq 0)
    {
        return $false
    }
    for ($ci = 0
        $ci -lt $CurrentKeys.Count
        $ci++)
    {
        if ($CurrentMatched[$ci])
        {
            continue
        }
        if ($candidateKeys.ContainsKey($CurrentKeys[$ci]))
        {
            return $true
        }
    }
    return $false
}
function Get-BlameMovedPairList
{
    <#
    .SYNOPSIS
        identity キー一致で移動行ペアを抽出する。
    .PARAMETER State
        New-BlameCompareState で生成した共有状態 DTO。
    .PARAMETER PreviousIdentity
        Previous 側の identity キー配列。
    .PARAMETER CurrentIdentity
        Current 側の identity キー配列。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [hashtable]$State,
        [string[]]$PreviousIdentity,
        [string[]]$CurrentIdentity
    )
    $unmatchedPrevByKey = @{}
    for ($pi = 0
        $pi -lt $PreviousIdentity.Count
        $pi++)
    {
        if ($State.PreviousMatched[$pi])
        {
            continue
        }
        $key = $PreviousIdentity[$pi]
        if (-not $unmatchedPrevByKey.ContainsKey($key))
        {
            $unmatchedPrevByKey[$key] = New-Object 'System.Collections.Generic.Queue[int]'
        }
        [void]$unmatchedPrevByKey[$key].Enqueue($pi)
    }

    $movedPairs = New-Object 'System.Collections.Generic.List[object]'
    for ($ci = 0
        $ci -lt $CurrentIdentity.Count
        $ci++)
    {
        if ($State.CurrentMatched[$ci])
        {
            continue
        }
        $key = $CurrentIdentity[$ci]
        if (-not $unmatchedPrevByKey.ContainsKey($key))
        {
            continue
        }
        $queue = $unmatchedPrevByKey[$key]
        if ($queue.Count -le 0)
        {
            continue
        }
        $prevIdx = [int]$queue.Dequeue()
        $movePair = [pscustomobject]@{
            PrevIndex = [int]$prevIdx
            CurrIndex = [int]$ci
            PrevLine = $State.PreviousLines[$prevIdx]
            CurrLine = $State.CurrentLines[$ci]
            MatchType = 'Move'
        }
        Add-BlameMatchedPair -State $State -PrevIndex $prevIdx -CurrIndex $ci -MatchType 'Move'
        [void]$movedPairs.Add($movePair)
    }
    return @($movedPairs.ToArray())
}
function Get-BlameUnmatchedLineList
{
    <#
    .SYNOPSIS
        一致していない blame 行を Index/Line 形式で返す。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Lines, [bool[]]$MatchedFlags)
    $unmatched = New-Object 'System.Collections.Generic.List[object]'
    for ($idx = 0
        $idx -lt $Lines.Count
        $idx++)
    {
        if ($MatchedFlags[$idx])
        {
            continue
        }
        [void]$unmatched.Add([pscustomobject]@{
                Index = [int]$idx
                Line = $Lines[$idx]
            })
    }
    return @($unmatched.ToArray())
}
function Get-BlameReattributedPairList
{
    <#
    .SYNOPSIS
        同一 content で帰属が変化した一致ペアを抽出する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$MatchedPairs)
    $reattributed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in @($MatchedPairs))
    {
        $prevLine = $pair.PrevLine
        $currLine = $pair.CurrLine
        $isSameContent = [string]$prevLine.Content -ceq [string]$currLine.Content
        $isRevisionChanged = [string]$prevLine.Revision -ne [string]$currLine.Revision
        $isAuthorChanged = (Get-NormalizedAuthorName -Author ([string]$prevLine.Author)) -ne (Get-NormalizedAuthorName -Author ([string]$currLine.Author))
        if ($isSameContent -and ($isRevisionChanged -or $isAuthorChanged))
        {
            [void]$reattributed.Add($pair)
        }
    }
    return @($reattributed.ToArray())
}
# endregion LCS・Blame 比較
# region Strict 帰属
function Get-CommitTransitionRenameContext
{
    <#
    .SYNOPSIS
        コミット内パスから rename 判定に必要な中間状態を構築する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([object[]]$Paths)
    $pathMap = @{}
    $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pathEntry in @($Paths))
    {
        $pathKey = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
        if (-not $pathKey)
        {
            continue
        }
        if (-not $pathMap.ContainsKey($pathKey))
        {
            $pathMap[$pathKey] = New-Object 'System.Collections.Generic.List[object]'
        }
        [void]$pathMap[$pathKey].Add($pathEntry)
        if (([string]$pathEntry.Action).ToUpperInvariant() -eq 'D')
        {
            [void]$deleted.Add($pathKey)
        }
    }

    $renameNewToOld = @{}
    $consumedOld = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pathEntry in @($Paths))
    {
        $action = ([string]$pathEntry.Action).ToUpperInvariant()
        if (($action -ne 'A' -and $action -ne 'R') -or [string]::IsNullOrWhiteSpace([string]$pathEntry.CopyFromPath))
        {
            continue
        }
        $newPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
        $oldPath = ConvertTo-PathKey -Path ([string]$pathEntry.CopyFromPath)
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
    return [pscustomobject]@{
        PathMap = $pathMap
        Deleted = $deleted
        RenameNewToOld = $renameNewToOld
        ConsumedOld = $consumedOld
    }
}
function ConvertTo-CommitRenameTransitions
{
    <#
    .SYNOPSIS
        rename 判定結果から before/after 遷移行を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [hashtable]$RenameNewToOld,
        [System.Collections.Generic.HashSet[string]]$Dedup
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($newPath in @($RenameNewToOld.Keys | Sort-Object))
    {
        $oldPath = [string]$RenameNewToOld[$newPath]
        $key = $oldPath + [char]31 + $newPath
        if ($Dedup.Add($key))
        {
            [void]$rows.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $newPath
                })
        }
    }
    return @($rows.ToArray())
}
function ConvertTo-CommitNonRenameTransitions
{
    <#
    .SYNOPSIS
        rename 以外の before/after 遷移行を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object]$Commit,
        [hashtable]$PathMap,
        [hashtable]$RenameNewToOld,
        [System.Collections.Generic.HashSet[string]]$Deleted,
        [System.Collections.Generic.HashSet[string]]$ConsumedOld,
        [System.Collections.Generic.HashSet[string]]$Dedup
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($oldPath in $Deleted)
    {
        if ($ConsumedOld.Contains($oldPath))
        {
            continue
        }
        $key = $oldPath + [char]31
        if ($Dedup.Add($key))
        {
            [void]$rows.Add([pscustomobject]@{
                    BeforePath = $oldPath
                    AfterPath = $null
                })
        }
    }

    $candidates = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($filePath in @($Commit.FilesChanged))
    {
        [void]$candidates.Add((ConvertTo-PathKey -Path ([string]$filePath)))
    }
    foreach ($path in $PathMap.Keys)
    {
        [void]$candidates.Add($path)
    }

    foreach ($path in $candidates)
    {
        if (-not $path)
        {
            continue
        }
        if ($RenameNewToOld.ContainsKey($path) -or $ConsumedOld.Contains($path) -or $Deleted.Contains($path))
        {
            continue
        }
        $beforePath = $path
        $afterPath = $path
        if ($PathMap.ContainsKey($path))
        {
            $entries = $PathMap[$path]
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
        if ($Dedup.Add($key))
        {
            [void]$rows.Add([pscustomobject]@{
                    BeforePath = $beforePath
                    AfterPath = $afterPath
                })
        }
    }
    return @($rows.ToArray())
}
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
    $renameContext = Get-CommitTransitionRenameContext -Paths $paths
    $dedup = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($transition in @(ConvertTo-CommitRenameTransitions -RenameNewToOld $renameContext.RenameNewToOld -Dedup $dedup))
    {
        [void]$result.Add($transition)
    }
    foreach ($transition in @(ConvertTo-CommitNonRenameTransitions -Commit $Commit -PathMap $renameContext.PathMap -RenameNewToOld $renameContext.RenameNewToOld -Deleted $renameContext.Deleted -ConsumedOld $renameContext.ConsumedOld -Dedup $dedup))
    {
        [void]$result.Add($transition)
    }
    return @($result.ToArray())
}
function ConvertTo-StrictHunkList
{
    <#
    .SYNOPSIS
        hunk 入力を列挙可能な配列へ正規化する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object]$HunksRaw)
    if ($null -eq $HunksRaw)
    {
        return @()
    }
    $hunks = New-Object 'System.Collections.Generic.List[object]'
    if ($HunksRaw -is [System.Collections.IEnumerable] -and -not ($HunksRaw -is [string]))
    {
        foreach ($hunk in $HunksRaw)
        {
            [void]$hunks.Add($hunk)
        }
    }
    else
    {
        [void]$hunks.Add($HunksRaw)
    }
    return @($hunks.ToArray())
}
function Get-StrictCanonicalHunkEvents
{
    <#
    .SYNOPSIS
        hunk 配列から正準行番号ベースのイベント群を生成する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Hunks,
        [int]$Revision,
        [string]$Author,
        [object]$OffsetEvents
    )
    $events = New-Object 'System.Collections.Generic.List[object]'
    $pending = New-Object 'System.Collections.Generic.List[object]'
    # 行番号ずれを吸収するため、先に正準範囲へ写像して記録する。
    foreach ($hunk in @($Hunks | Sort-Object OldStart, NewStart))
    {
        $segments = @()
        $useEffectiveSegments = ($hunk.PSObject.Properties.Match('EffectiveSegments').Count -gt 0 -and $null -ne $hunk.EffectiveSegments)
        if ($useEffectiveSegments)
        {
            $segments = @($hunk.EffectiveSegments)
        }
        else
        {
            $segments = @([pscustomobject]@{
                    OldStart = [int]$hunk.OldStart
                    OldCount = [int]$hunk.OldCount
                    NewStart = [int]$hunk.NewStart
                    NewCount = [int]$hunk.NewCount
                })
        }
        foreach ($segment in @($segments | Sort-Object OldStart, NewStart))
        {
            $oldStart = [int]$segment.OldStart
            $oldCount = [int]$segment.OldCount
            $newCount = [int]$segment.NewCount
            if ($oldStart -lt 1)
            {
                continue
            }
            $start = Get-CanonicalLineNumber -OffsetEvents $OffsetEvents -LineNumber $oldStart
            $end = $start
            if ($oldCount -gt 0)
            {
                $end = Get-CanonicalLineNumber -OffsetEvents $OffsetEvents -LineNumber ($oldStart + $oldCount - 1)
            }
            if ($end -lt $start)
            {
                $tmp = $start
                $start = $end
                $end = $tmp
            }
            [void]$events.Add([pscustomobject]@{
                    Revision = $Revision
                    Author = $Author
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
    }
    foreach ($shiftEvent in @($pending.ToArray() | Sort-Object Threshold))
    {
        Add-CanonicalOffsetEvent -OffsetEvents $OffsetEvents -ThresholdLine ([int]$shiftEvent.Threshold) -ShiftDelta ([int]$shiftEvent.Delta)
    }
    return @($events.ToArray())
}
function Get-StrictHunkEventsByFile
{
    <#
    .SYNOPSIS
        Strict hunk 集計に使うファイル別イベント配列を構築する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [hashtable]$RenameMap
    )
    $offsetByFile = @{}
    $eventsByFile = @{}
    foreach ($commit in @($Commits | Sort-Object Revision))
    {
        $revision = [int]$commit.Revision
        $author = if ($RevToAuthor.ContainsKey($revision))
        {
            Get-NormalizedAuthorName -Author ([string]$RevToAuthor[$revision])
        }
        else
        {
            Get-NormalizedAuthorName -Author ([string]$commit.Author)
        }
        foreach ($filePath in @($commit.FilesChanged))
        {
            if (-not $commit.FileDiffStats.ContainsKey($filePath))
            {
                continue
            }
            $diffStat = $commit.FileDiffStats[$filePath]
            if ($null -eq $diffStat -or -not ($diffStat.PSObject.Properties.Name -contains 'Hunks'))
            {
                continue
            }
            $hunks = @(ConvertTo-StrictHunkList -HunksRaw $diffStat.Hunks)
            if ($hunks.Count -eq 0)
            {
                continue
            }
            $resolvedPath = Resolve-PathByRenameMap -Context $Context -FilePath $filePath -RenameMap $RenameMap
            if ([string]::IsNullOrWhiteSpace($resolvedPath))
            {
                continue
            }
            if (-not $offsetByFile.ContainsKey($resolvedPath))
            {
                $offsetByFile[$resolvedPath] = Initialize-CanonicalOffsetMap
            }
            if (-not $eventsByFile.ContainsKey($resolvedPath))
            {
                $eventsByFile[$resolvedPath] = New-Object 'System.Collections.Generic.List[object]'
            }
            $canonicalEvents = @(Get-StrictCanonicalHunkEvents -Hunks $hunks -Revision $revision -Author $author -OffsetEvents $offsetByFile[$resolvedPath])
            foreach ($canonicalEvent in $canonicalEvents)
            {
                [void]$eventsByFile[$resolvedPath].Add($canonicalEvent)
            }
        }
    }
    return $eventsByFile
}
function Test-StrictHunkRangeOverlap
{
    <#
    .SYNOPSIS
        2つの行範囲が重なっているかを判定する。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [int]$StartA,
        [int]$EndA,
        [int]$StartB,
        [int]$EndB
    )
    return ($StartA -le $EndB -and $StartB -le $EndA)
}
function Get-StrictHunkOverlapSummary
{
    <#
    .SYNOPSIS
        ファイル別 hunk イベントから反復編集とピンポンを集計する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([hashtable]$EventsByFile)
    $authorRepeated = @{}
    $fileRepeated = @{}
    $authorPingPong = @{}
    $filePingPong = @{}
    foreach ($file in $EventsByFile.Keys)
    {
        $events = @($EventsByFile[$file].ToArray() | Sort-Object Revision)
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
                if (-not ($s1 -le $ej -and $sj -le $e1))
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
function Get-StrictHunkDetail
{
    <#
    .SYNOPSIS
        hunk の正準行範囲を追跡して反復編集とピンポンを集計する。
    .DESCRIPTION
        イベント化と重なり集計を段階的に実行し、Strict hunk 指標を返す。
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER RevToAuthor
        リビジョン番号と作者の対応表を指定する。
    .PARAMETER RenameMap
        RenameMap の値を指定する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [hashtable]$RenameMap
    )
    $eventsByFile = Get-StrictHunkEventsByFile -Context $Context -Commits $Commits -RevToAuthor $RevToAuthor -RenameMap $RenameMap
    return (Get-StrictHunkOverlapSummary -EventsByFile $eventsByFile)
}
function Add-StrictBlamePrefetchTargetCandidate
{
    <#
    .SYNOPSIS
        Strict blame prefetch の候補を重複排除しつつ追加する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Targets,
        [Parameter(Mandatory = $true)][hashtable]$TargetByKey,
        [string]$CacheDir,
        [int]$Revision,
        [string]$FilePath,
        [switch]$NeedContent,
        [switch]$SkipCacheExistenceCheck
    )
    if ($Revision -le 0 -or [string]::IsNullOrWhiteSpace($FilePath))
    {
        return
    }
    $normalizedPath = ConvertTo-PathKey -Path $FilePath
    if ([string]::IsNullOrWhiteSpace($normalizedPath))
    {
        return
    }

    $key = [string]$Revision + [char]31 + $normalizedPath
    if ($TargetByKey.ContainsKey($key))
    {
        if ($NeedContent -and -not [bool]$TargetByKey[$key].NeedContent)
        {
            $TargetByKey[$key].NeedContent = $true
        }
        return
    }

    if (-not $SkipCacheExistenceCheck)
    {
        $hasBlameCache = Test-BlameCacheFileExistence -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $normalizedPath
        $hasCatCache = $true
        if ($NeedContent)
        {
            $hasCatCache = Test-CatCacheFileExistence -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $normalizedPath
        }
        if ($hasBlameCache -and $hasCatCache)
        {
            return
        }
    }

    $target = [pscustomobject]@{
        FilePath = $normalizedPath
        Revision = [int]$Revision
        NeedContent = [bool]$NeedContent
    }
    $TargetByKey[$key] = $target
    [void]$Targets.Add($target)
}
function ConvertTo-SvnBlameTargetPathComparisonKey
{
    <#
    .SYNOPSIS
        svn blame XML target path の比較用正規化キーを返す。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path))
    {
        return ''
    }
    $normalized = [string]$Path
    if ($normalized -match '@\d+$')
    {
        $normalized = $normalized.Substring(0, $normalized.LastIndexOf('@'))
    }
    $normalized = $normalized.TrimEnd('/')
    try
    {
        return ([System.Uri]$normalized).AbsoluteUri.TrimEnd('/').ToLowerInvariant()
    }
    catch
    {
        return $normalized.ToLowerInvariant()
    }
}
function ConvertTo-SvnBlameSingleTargetXmlText
{
    <#
    .SYNOPSIS
        複数 target を含む blame XML から 1 target 分の XML を生成する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][System.Xml.XmlNode]$TargetNode)
    $xmlDoc = New-Object System.Xml.XmlDocument
    $declaration = $xmlDoc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    [void]$xmlDoc.AppendChild($declaration)
    $rootNode = $xmlDoc.CreateElement('blame')
    [void]$xmlDoc.AppendChild($rootNode)
    $targetClone = $xmlDoc.ImportNode($TargetNode, $true)
    [void]$rootNode.AppendChild($targetClone)
    return $xmlDoc.OuterXml
}
function Get-StrictBlameOnlyPrefetchBatchPlan
{
    <#
    .SYNOPSIS
        blame-only prefetch 対象を revision 単位でチャンク化する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()][object[]]$Targets = @(),
        [ValidateRange(1, 4096)][int]$MaxTargetsPerBatch = 64
    )
    $targetsByRevision = @{}
    foreach ($item in @($Targets))
    {
        $revision = [int]$item.Revision
        $normalizedPath = ConvertTo-PathKey -Path ([string]$item.FilePath)
        if ($revision -le 0 -or [string]::IsNullOrWhiteSpace($normalizedPath))
        {
            continue
        }
        if (-not $targetsByRevision.ContainsKey($revision))
        {
            $targetsByRevision[$revision] = @{}
        }
        $targetsByRevision[$revision][$normalizedPath] = $true
    }

    $chunks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($revision in @($targetsByRevision.Keys | Sort-Object))
    {
        $paths = @($targetsByRevision[$revision].Keys | Sort-Object)
        if ($paths.Count -eq 0)
        {
            continue
        }
        $cursor = 0
        while ($cursor -lt $paths.Count)
        {
            $batchPaths = New-Object 'System.Collections.Generic.List[string]'
            $addedCount = 0
            while ($cursor -lt $paths.Count -and $addedCount -lt $MaxTargetsPerBatch)
            {
                [void]$batchPaths.Add([string]$paths[$cursor])
                $cursor++
                $addedCount++
            }
            [void]$chunks.Add([pscustomobject]@{
                    Revision = [int]$revision
                    FilePaths = @($batchPaths.ToArray())
                })
        }
    }
    return @($chunks.ToArray())
}
function Initialize-StrictBlameOnlyBatchChunk
{
    <#
    .SYNOPSIS
        blame-only prefetch の 1 チャンクを実行し、結果を個別キャッシュへ展開する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$TargetUrl,
        [string]$CacheDir,
        [int]$Revision,
        [AllowEmptyCollection()][string[]]$FilePaths = @()
    )
    if ($Revision -le 0 -or [string]::IsNullOrWhiteSpace($TargetUrl))
    {
        return (New-NarutoResultSkipped -Data ([pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                    BatchTargets = 0
                    FallbackTargets = 0
                }) -ErrorCode 'SVN_BLAME_BATCH_INVALID_ARGUMENT' -Message 'blame バッチ取得対象の引数が無効なためスキップしました。' -Context @{
                Revision = [int]$Revision
            })
    }

    $normalizedFilePaths = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($filePath in @($FilePaths))
    {
        $normalizedPath = ConvertTo-PathKey -Path $filePath
        if ([string]::IsNullOrWhiteSpace($normalizedPath))
        {
            continue
        }
        if ($seen.ContainsKey($normalizedPath))
        {
            continue
        }
        $seen[$normalizedPath] = $true
        [void]$normalizedFilePaths.Add($normalizedPath)
    }
    if ($normalizedFilePaths.Count -eq 0)
    {
        return (New-NarutoResultSuccess -Data ([pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                    BatchTargets = 0
                    FallbackTargets = 0
                }) -ErrorCode 'SVN_BLAME_BATCH_EMPTY')
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    [void]$arguments.Add('blame')
    [void]$arguments.Add('--xml')
    [void]$arguments.Add('-r')
    [void]$arguments.Add([string]$Revision)
    $expectedPathByKey = @{}
    foreach ($normalizedFilePath in @($normalizedFilePaths.ToArray()))
    {
        $urlWithoutPeg = $TargetUrl.TrimEnd('/') + '/' + $normalizedFilePath.TrimStart('/')
        $urlWithPeg = $urlWithoutPeg + '@' + [string]$Revision
        [void]$arguments.Add($urlWithPeg)
        $comparisonKey = ConvertTo-SvnBlameTargetPathComparisonKey -Path $urlWithoutPeg
        $expectedPathByKey[$comparisonKey] = $normalizedFilePath
    }

    $cacheHits = 0
    $cacheMisses = 0
    $fallbackPaths = New-Object 'System.Collections.Generic.List[string]'

    $batchFetchResult = Invoke-SvnCommandAllowMissingTarget -Context $Context -Arguments $arguments.ToArray() -ErrorContext ("svn blame batch r{0}" -f [int]$Revision)
    $batchFetchResult = ConvertTo-NarutoResultAdapter -InputObject $batchFetchResult -SuccessCode 'SVN_COMMAND_SUCCEEDED' -SkippedCode 'SVN_TARGET_MISSING'
    if (Test-NarutoResultSuccess -Result $batchFetchResult)
    {
        $xmlDoc = ConvertFrom-SvnXmlText -Text ([string]$batchFetchResult.Data) -ContextLabel ("svn blame batch r{0}" -f [int]$Revision)
        $targetNodeByKey = @{}
        if ($null -ne $xmlDoc)
        {
            $targetNodes = $xmlDoc.SelectNodes('blame/target')
            foreach ($targetNode in @($targetNodes))
            {
                if ($null -eq $targetNode)
                {
                    continue
                }
                $targetPath = ''
                if ($null -ne $targetNode.Attributes -and $null -ne $targetNode.Attributes['path'])
                {
                    $targetPath = [string]$targetNode.Attributes['path'].Value
                }
                if ([string]::IsNullOrWhiteSpace($targetPath))
                {
                    continue
                }
                $targetKey = ConvertTo-SvnBlameTargetPathComparisonKey -Path $targetPath
                if (-not $targetNodeByKey.ContainsKey($targetKey))
                {
                    $targetNodeByKey[$targetKey] = $targetNode
                }
            }
        }

        foreach ($normalizedFilePath in @($normalizedFilePaths.ToArray()))
        {
            $expectedUrlWithoutPeg = $TargetUrl.TrimEnd('/') + '/' + $normalizedFilePath.TrimStart('/')
            $expectedKey = ConvertTo-SvnBlameTargetPathComparisonKey -Path $expectedUrlWithoutPeg
            if ($targetNodeByKey.ContainsKey($expectedKey))
            {
                $singleTargetXml = ConvertTo-SvnBlameSingleTargetXmlText -TargetNode $targetNodeByKey[$expectedKey]
                Write-BlameCacheFile -Context $Context -CacheDir $CacheDir -Revision $Revision -FilePath $normalizedFilePath -Content $singleTargetXml
                $cacheMisses++
                continue
            }
            [void]$fallbackPaths.Add($normalizedFilePath)
        }
    }
    else
    {
        foreach ($normalizedFilePath in @($normalizedFilePaths.ToArray()))
        {
            [void]$fallbackPaths.Add($normalizedFilePath)
        }
    }

    foreach ($fallbackPath in @($fallbackPaths.ToArray()))
    {
        $fallbackResult = Initialize-SvnBlameLineCache -Context $Context -Repo $TargetUrl -FilePath $fallbackPath -Revision $Revision -CacheDir $CacheDir -NeedContent:$false
        $fallbackResult = ConvertTo-NarutoResultAdapter -InputObject $fallbackResult -SuccessCode 'SVN_BLAME_CACHE_READY' -SkippedCode 'SVN_TARGET_MISSING'
        $fallbackStats = $fallbackResult.Data
        if ($null -eq $fallbackStats)
        {
            $fallbackStats = [pscustomobject]@{
                CacheHits = 0
                CacheMisses = 0
            }
        }
        $cacheHits += [int]$fallbackStats.CacheHits
        $cacheMisses += [int]$fallbackStats.CacheMisses
    }

    return (New-NarutoResultSuccess -Data ([pscustomobject]@{
                CacheHits = [int]$cacheHits
                CacheMisses = [int]$cacheMisses
                BatchTargets = [int]$normalizedFilePaths.Count
                FallbackTargets = [int]$fallbackPaths.Count
            }) -ErrorCode 'SVN_BLAME_BATCH_READY')
}
function Invoke-StrictBlameOnlyBatchPrefetch
{
    <#
    .SYNOPSIS
        NeedContent=false の Strict prefetch を revision バッチで実行する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [AllowEmptyCollection()][object[]]$Targets = @(),
        [string]$TargetUrl,
        [string]$CacheDir,
        [int]$Parallel = 1
    )
    $chunks = @(Get-StrictBlameOnlyPrefetchBatchPlan -Targets $Targets)
    if ($chunks.Count -eq 0)
    {
        return [pscustomobject]@{
            CacheHits = 0
            CacheMisses = 0
            BatchTargets = 0
            FallbackTargets = 0
            ChunkCount = 0
        }
    }
    $cacheHits = 0
    $cacheMisses = 0
    $batchTargets = 0
    $fallbackTargets = 0
    if ($Parallel -le 1 -or $chunks.Count -eq 1)
    {
        $batchTotal = $chunks.Count
        $batchIndex = 0
        foreach ($chunk in @($chunks))
        {
            $pct = [Math]::Min(100, [int](($batchIndex / [Math]::Max(1, $batchTotal)) * 100))
            Write-Progress -Id 5 -Activity 'blame-only バッチキャッシュ構築' -Status ('{0}/{1} (r{2})' -f ($batchIndex + 1), $batchTotal, [int]$chunk.Revision) -PercentComplete $pct
            $batchResult = Initialize-StrictBlameOnlyBatchChunk -Context $Context -TargetUrl $TargetUrl -CacheDir $CacheDir -Revision ([int]$chunk.Revision) -FilePaths @([string[]]$chunk.FilePaths)
            $batchResult = ConvertTo-NarutoResultAdapter -InputObject $batchResult -SuccessCode 'SVN_BLAME_BATCH_READY' -SkippedCode 'SVN_BLAME_BATCH_INVALID_ARGUMENT'
            $batchStats = $batchResult.Data
            if ($null -eq $batchStats)
            {
                $batchStats = [pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                    BatchTargets = 0
                    FallbackTargets = 0
                }
            }
            $cacheHits += [int]$batchStats.CacheHits
            $cacheMisses += [int]$batchStats.CacheMisses
            $batchTargets += [int]$batchStats.BatchTargets
            $fallbackTargets += [int]$batchStats.FallbackTargets
            $batchIndex++
        }
        Write-Progress -Id 5 -Activity 'blame-only バッチキャッシュ構築' -Completed
    }
    else
    {
        $workItems = New-Object 'System.Collections.Generic.List[object]'
        foreach ($chunk in @($chunks))
        {
            [void]$workItems.Add([pscustomobject]@{
                    TargetUrl = $TargetUrl
                    CacheDir = $CacheDir
                    Revision = [int]$chunk.Revision
                    FilePaths = @([string[]]$chunk.FilePaths)
                })
        }
        $worker = {
            param($Item, $Index)
            [void]$Index # Required by Invoke-ParallelWork contract
            $result = Initialize-StrictBlameOnlyBatchChunk -Context $Context -TargetUrl $Item.TargetUrl -CacheDir $Item.CacheDir -Revision ([int]$Item.Revision) -FilePaths @([string[]]$Item.FilePaths)
            $result = ConvertTo-NarutoResultAdapter -InputObject $result -SuccessCode 'SVN_BLAME_BATCH_READY' -SkippedCode 'SVN_BLAME_BATCH_INVALID_ARGUMENT'
            $stats = $result.Data
            if ($null -eq $stats)
            {
                $stats = [pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                    BatchTargets = 0
                    FallbackTargets = 0
                }
            }
            [pscustomobject]@{
                CacheHits = [int]$stats.CacheHits
                CacheMisses = [int]$stats.CacheMisses
                BatchTargets = [int]$stats.BatchTargets
                FallbackTargets = [int]$stats.FallbackTargets
                Status = [string]$result.Status
                ErrorCode = [string]$result.ErrorCode
            }
        }
        $results = @(Invoke-ParallelWork -InputItems $workItems.ToArray() -WorkerScript $worker -MaxParallel $Parallel -RequiredFunctions @(
                $Context.Constants.RunspaceSvnCoreFunctions +
                $Context.Constants.RunspaceBlameCacheFunctions +
                @(
                    'ConvertFrom-SvnXmlText',
                    'ConvertTo-SvnBlameTargetPathComparisonKey',
                    'ConvertTo-SvnBlameSingleTargetXmlText',
                    'Initialize-SvnBlameLineCache',
                    'Initialize-StrictBlameOnlyBatchChunk'
                )
            ) -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $Context)
                SvnExecutable = $Context.Runtime.SvnExecutable
                SvnGlobalArguments = @($Context.Runtime.SvnGlobalArguments)
            } -ErrorContext 'strict blame-only batch prefetch')

        foreach ($entry in @($results))
        {
            $cacheHits += [int]$entry.CacheHits
            $cacheMisses += [int]$entry.CacheMisses
            $batchTargets += [int]$entry.BatchTargets
            $fallbackTargets += [int]$entry.FallbackTargets
        }
    }
    return [pscustomobject]@{
        CacheHits = [int]$cacheHits
        CacheMisses = [int]$cacheMisses
        BatchTargets = [int]$batchTargets
        FallbackTargets = [int]$fallbackTargets
        ChunkCount = [int]$chunks.Count
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
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir
    )

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $targetByKey = @{}
    $transitionCount = 0
    $fastAddOnlyCount = 0
    $fastAddOnlyNoBlameCount = 0
    $fastDeleteOnlyCount = 0
    $generalCount = 0
    $skippedZeroCount = 0
    $excludeCommentOnlyLines = Get-ContextRuntimeSwitchValue -Context $Context -PropertyName 'ExcludeCommentOnlyLines'
    $skipCacheExistenceCheck = $false
    if (-not [string]::IsNullOrWhiteSpace($CacheDir))
    {
        $blameCacheRoot = Join-Path $CacheDir 'blame'
        $catCacheRoot = Join-Path $CacheDir 'cat'
        if (-not [System.IO.Directory]::Exists($blameCacheRoot) -and -not [System.IO.Directory]::Exists($catCacheRoot))
        {
            $skipCacheExistenceCheck = $true
        }
    }

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
            $transitionContext = Resolve-StrictTransitionContext -Context $Context -Commit $c -Transition $t -RenameMap @{}
            if ($null -eq $transitionContext)
            {
                continue
            }
            $transitionCount++
            $beforePath = [string]$transitionContext.BeforePath
            $afterPath = [string]$transitionContext.AfterPath
            $hasTransitionStat = [bool]$transitionContext.HasTransitionStat
            $transitionAdded = [int]$transitionContext.TransitionAdded
            $transitionDeleted = [int]$transitionContext.TransitionDeleted

            if ($hasTransitionStat -and $transitionAdded -eq 0 -and $transitionDeleted -eq 0)
            {
                $skippedZeroCount++
                continue
            }

            if ($hasTransitionStat -and $transitionAdded -gt 0 -and $transitionDeleted -eq 0 -and $afterPath)
            {
                $fastAddOnlyCount++
                if (-not $excludeCommentOnlyLines -and $beforePath -and $beforePath -ceq $afterPath)
                {
                    $fastAddOnlyNoBlameCount++
                    continue
                }
                Add-StrictBlamePrefetchTargetCandidate -Context $Context -Targets $targets -TargetByKey $targetByKey -CacheDir $CacheDir -Revision $rev -FilePath $afterPath -NeedContent:$false -SkipCacheExistenceCheck:$skipCacheExistenceCheck
                continue
            }

            if ($hasTransitionStat -and $transitionDeleted -gt 0 -and $transitionAdded -eq 0 -and $beforePath -and (-not $afterPath))
            {
                $fastDeleteOnlyCount++
                Add-StrictBlamePrefetchTargetCandidate -Context $Context -Targets $targets -TargetByKey $targetByKey -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath -NeedContent:$false -SkipCacheExistenceCheck:$skipCacheExistenceCheck
                continue
            }

            $generalCount++
            if ($beforePath -and ($rev - 1) -gt 0)
            {
                Add-StrictBlamePrefetchTargetCandidate -Context $Context -Targets $targets -TargetByKey $targetByKey -CacheDir $CacheDir -Revision ($rev - 1) -FilePath $beforePath -NeedContent:$true -SkipCacheExistenceCheck:$skipCacheExistenceCheck
            }
            if ($afterPath -and $rev -gt 0)
            {
                Add-StrictBlamePrefetchTargetCandidate -Context $Context -Targets $targets -TargetByKey $targetByKey -CacheDir $CacheDir -Revision $rev -FilePath $afterPath -NeedContent:$true -SkipCacheExistenceCheck:$skipCacheExistenceCheck
            }
        }
    }

    $needContentCount = 0
    foreach ($target in @($targets.ToArray()))
    {
        if ([bool]$target.NeedContent)
        {
            $needContentCount++
        }
    }
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'CandidateTransitions' -Value ([int]$transitionCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'ZeroChangeTransitions' -Value ([int]$skippedZeroCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'FastAddOnlyTransitions' -Value ([int]$fastAddOnlyCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'FastAddOnlyNoBlameTransitions' -Value ([int]$fastAddOnlyNoBlameCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'FastDeleteOnlyTransitions' -Value ([int]$fastDeleteOnlyCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'GeneralTransitions' -Value ([int]$generalCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'PrefetchTargets' -Value ([int]$targets.Count)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'PrefetchTargetsNeedContent' -Value ([int]$needContentCount)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'PrefetchTargetsBlameOnly' -Value ([int]($targets.Count - $needContentCount))

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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
        [AllowEmptyCollection()][object[]]$Targets = @(),
        [string]$TargetUrl,
        [string]$CacheDir,
        [int]$Parallel = 1
    )
    $items = @($Targets)
    if ($items.Count -eq 0)
    {
        return
    }

    $blameBatchTargets = New-Object 'System.Collections.Generic.List[object]'
    $needContentTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $items)
    {
        $needContent = $true
        $hasNeedContentProperty = ($item.PSObject.Properties.Match('NeedContent').Count -gt 0)
        if ($hasNeedContentProperty)
        {
            $needContent = [bool]$item.NeedContent
            [void]$blameBatchTargets.Add([pscustomobject]@{
                    FilePath = [string]$item.FilePath
                    Revision = [int]$item.Revision
                })
        }
        if ($needContent)
        {
            [void]$needContentTargets.Add([pscustomobject]@{
                    FilePath = [string]$item.FilePath
                    Revision = [int]$item.Revision
                    NeedContent = $true
                })
        }
    }

    if ($blameBatchTargets.Count -gt 0)
    {
        $blameBatchStats = Invoke-StrictBlameOnlyBatchPrefetch -Context $Context -Targets @($blameBatchTargets.ToArray()) -TargetUrl $TargetUrl -CacheDir $CacheDir -Parallel $Parallel
        $Context.Caches.StrictBlameCacheHits += [int]$blameBatchStats.CacheHits
        $Context.Caches.StrictBlameCacheMisses += [int]$blameBatchStats.CacheMisses
        Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'PrefetchBlameBatchChunks' -Value ([int]$blameBatchStats.ChunkCount)
        Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictTargetStats' -Key 'PrefetchBlameBatchFallbackTargets' -Value ([int]$blameBatchStats.FallbackTargets)
    }

    $items = @($needContentTargets.ToArray())
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
                $prefetchStatsResult = Initialize-SvnBlameLineCache -Context $Context -Repo $TargetUrl -FilePath ([string]$item.FilePath) -Revision ([int]$item.Revision) -CacheDir $CacheDir -NeedContent:$true
                $prefetchStatsResult = ConvertTo-NarutoResultAdapter -InputObject $prefetchStatsResult -SuccessCode 'SVN_BLAME_CACHE_READY' -SkippedCode 'SVN_BLAME_CACHE_INVALID_ARGUMENT'
                $prefetchStats = $prefetchStatsResult.Data
                if ($null -eq $prefetchStats)
                {
                    $prefetchStats = [pscustomobject]@{
                        CacheHits = 0
                        CacheMisses = 0
                    }
                }
                $Context.Caches.StrictBlameCacheHits += [int]$prefetchStats.CacheHits
                $Context.Caches.StrictBlameCacheMisses += [int]$prefetchStats.CacheMisses
            }
            catch
            {
                Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_BLAME_PREFETCH_FAILED' -Message ("Strict blame prefetch failed for '{0}' at r{1}: {2}" -f [string]$item.FilePath, [int]$item.Revision, $_.Exception.Message) -Context @{
                    FilePath = [string]$item.FilePath
                    Revision = [int]$item.Revision
                } -InnerException $_.Exception
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
                NeedContent = $true
            })
    }

    $worker = {
        param($Item, $Index)
        [void]$Index # Required by Invoke-ParallelWork contract
        try
        {
            $statsResult = Initialize-SvnBlameLineCache -Context $Context -Repo $Item.TargetUrl -FilePath ([string]$Item.FilePath) -Revision ([int]$Item.Revision) -CacheDir $Item.CacheDir -NeedContent:$([bool]$Item.NeedContent)
            $statsResult = ConvertTo-NarutoResultAdapter -InputObject $statsResult -SuccessCode 'SVN_BLAME_CACHE_READY' -SkippedCode 'SVN_BLAME_CACHE_INVALID_ARGUMENT'
            $stats = $statsResult.Data
            if ($null -eq $stats)
            {
                $stats = [pscustomobject]@{
                    CacheHits = 0
                    CacheMisses = 0
                }
            }
            [pscustomobject]@{
                CacheHits = [int]$stats.CacheHits
                CacheMisses = [int]$stats.CacheMisses
                Status = [string]$statsResult.Status
                ErrorCode = [string]$statsResult.ErrorCode
            }
        }
        catch
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_BLAME_PREFETCH_FAILED' -Message ("Strict blame prefetch failed for '{0}' at r{1}: {2}" -f [string]$Item.FilePath, [int]$Item.Revision, $_.Exception.Message) -Context @{
                FilePath = [string]$Item.FilePath
                Revision = [int]$Item.Revision
            } -InnerException $_.Exception
        }
    }
    $results = @(Invoke-ParallelWork -InputItems $prefetchItems.ToArray() -WorkerScript $worker -MaxParallel $Parallel -RequiredFunctions @(
            $Context.Constants.RunspaceSvnCoreFunctions +
            $Context.Constants.RunspaceBlameCacheFunctions +
            @(
                'Get-CatCachePath',
                'Read-CatCacheFile',
                'Write-CatCacheFile',
                'Initialize-SvnBlameLineCache'
            )
        ) -SessionVariables @{
            Context = (Get-RunspaceNarutoContext -Context $Context)
            SvnExecutable = $Context.Runtime.SvnExecutable
            SvnGlobalArguments = @($Context.Runtime.SvnGlobalArguments)
        } -ErrorContext 'strict blame prefetch')

    foreach ($entry in @($results))
    {
        $Context.Caches.StrictBlameCacheHits += [int]$entry.CacheHits
        $Context.Caches.StrictBlameCacheMisses += [int]$entry.CacheMisses
    }
}
function New-StrictAttributionAccumulator
{
    <#
    .SYNOPSIS
        Strict 帰属集計で使う可変カウンター群を初期化する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param()
    return [pscustomobject]@{
        AuthorBorn = @{}
        AuthorDead = @{}
        AuthorSelfDead = @{}
        AuthorOtherDead = @{}
        AuthorSurvived = @{}
        AuthorCrossRevert = @{}
        AuthorRemovedByOthers = @{}
        FileBorn = @{}
        FileDead = @{}
        FileSurvived = @{}
        FileSelfCancel = @{}
        FileCrossRevert = @{}
        AuthorInternalMove = @{}
        FileInternalMove = @{}
        AuthorModifiedOthersCode = @{}
        RevsWhereKilledOthers = New-Object 'System.Collections.Generic.HashSet[string]'
        KillMatrix = @{}
    }
}
function Resolve-StrictTransitionContext
{
    <#
    .SYNOPSIS
        Strict 遷移1件分の比較コンテキストを正規化して返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$Commit,
        [object]$Transition,
        [hashtable]$RenameMap
    )
    $beforePath = if ($null -ne $Transition.BeforePath)
    {
        ConvertTo-PathKey -Path ([string]$Transition.BeforePath)
    }
    else
    {
        $null
    }
    $afterPath = if ($null -ne $Transition.AfterPath)
    {
        ConvertTo-PathKey -Path ([string]$Transition.AfterPath)
    }
    else
    {
        $null
    }
    if ([string]::IsNullOrWhiteSpace($beforePath) -and [string]::IsNullOrWhiteSpace($afterPath))
    {
        return $null
    }

    $isBinary = $false
    foreach ($bp in @($beforePath, $afterPath))
    {
        if (-not $bp)
        {
            continue
        }
        if ($Commit.FileDiffStats.ContainsKey($bp))
        {
            $d = $Commit.FileDiffStats[$bp]
            if ($null -ne $d -and $d.PSObject.Properties.Match('IsBinary') -and [bool]$d.IsBinary)
            {
                $isBinary = $true
            }
        }
    }
    if ($isBinary)
    {
        return $null
    }

    $transitionAdded = 0
    $transitionDeleted = 0
    $transitionStat = $null
    $transitionHunks = @()
    if ($afterPath -and $Commit.FileDiffStats.ContainsKey($afterPath))
    {
        $transitionStat = $Commit.FileDiffStats[$afterPath]
    }
    elseif ($beforePath -and $Commit.FileDiffStats.ContainsKey($beforePath))
    {
        $transitionStat = $Commit.FileDiffStats[$beforePath]
    }
    if ($null -ne $transitionStat)
    {
        $transitionAdded = [int]$transitionStat.AddedLines
        $transitionDeleted = [int]$transitionStat.DeletedLines
        if ($transitionStat.PSObject.Properties.Match('Hunks').Count -gt 0)
        {
            $transitionHunks = @(ConvertTo-StrictHunkList -HunksRaw $transitionStat.Hunks)
        }
    }

    $metricFile = if ($afterPath)
    {
        Resolve-PathByRenameMap -Context $Context -FilePath $afterPath -RenameMap $RenameMap
    }
    else
    {
        Resolve-PathByRenameMap -Context $Context -FilePath $beforePath -RenameMap $RenameMap
    }

    return [pscustomobject]@{
        BeforePath = $beforePath
        AfterPath = $afterPath
        MetricFile = $metricFile
        HasTransitionStat = ($null -ne $transitionStat)
        TransitionAdded = $transitionAdded
        TransitionDeleted = $transitionDeleted
        TransitionHunks = @($transitionHunks)
    }
}
function Get-StrictTransitionLineFilterResult
{
    <#
    .SYNOPSIS
        Strict 遷移比較用の行配列からコメント専用行を除外する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Lines,
        [string]$TargetUrl,
        [string]$FilePath,
        [int]$Revision,
        [string]$CacheDir
    )
    if (@($Lines).Count -eq 0)
    {
        return @()
    }
    if (-not (Get-ContextRuntimeSwitchValue -Context $Context -PropertyName 'ExcludeCommentOnlyLines'))
    {
        return @($Lines)
    }
    $commentProfile = Get-CommentSyntaxProfileByPath -Context $Context -FilePath $FilePath
    if ($null -eq $commentProfile)
    {
        return @($Lines)
    }
    $catText = Get-CachedOrFetchCatText -Context $Context -Repo $TargetUrl -FilePath $FilePath -Revision $Revision -CacheDir $CacheDir
    if ($null -eq $catText)
    {
        return @($Lines)
    }
    $contentLines = ConvertTo-TextLine -Text $catText
    $commentMask = ConvertTo-CommentOnlyLineMask -Lines $contentLines -CommentSyntaxProfile $commentProfile
    return @(Get-NonCommentLineEntry -Lines @($Lines) -CommentOnlyLineMask $commentMask)
}
function Get-StrictTransitionComparison
{
    <#
    .SYNOPSIS
        Strict 遷移コンテキスト1件に対する blame 比較結果を返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$TransitionContext,
        [string]$TargetUrl,
        [int]$Revision,
        [string]$CacheDir
    )
    $beforePath = [string]$TransitionContext.BeforePath
    $afterPath = [string]$TransitionContext.AfterPath
    $hasTransitionStat = [bool]$TransitionContext.HasTransitionStat
    $transitionAdded = [int]$TransitionContext.TransitionAdded
    $transitionDeleted = [int]$TransitionContext.TransitionDeleted
    $excludeCommentOnlyLines = Get-ContextRuntimeSwitchValue -Context $Context -PropertyName 'ExcludeCommentOnlyLines'

    # Fast Path 1: zero-change — プロパティ変更のみ等。blame 取得自体を省略する。
    if ($hasTransitionStat -and $transitionAdded -eq 0 -and $transitionDeleted -eq 0)
    {
        return $null
    }

    # Fast Path 2: add-only — 削除行なし。前リビジョンの blame 取得と LCS を省略し、
    # 現リビジョンの blame から当該リビジョンで born された行だけを抽出する。
    if ($hasTransitionStat -and $transitionAdded -gt 0 -and $transitionDeleted -eq 0 -and $afterPath)
    {
        # before/after が同一パスの add-only は diff の AddedLines が born 行数と一致するため、
        # blame 取得を省略してカウントを直接反映できる。
        if (-not $excludeCommentOnlyLines -and $beforePath -and $beforePath -ceq $afterPath)
        {
            return [pscustomobject]@{
                KilledLines = @()
                BornLines = @()
                BornCountCurrentRevision = [int]$transitionAdded
                MatchedPairs = @()
                MovedPairs = @()
                ReattributedPairs = @()
            }
        }
        $currBlameResult = if ($excludeCommentOnlyLines)
        {
            Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $afterPath -Revision $Revision -CacheDir $CacheDir -NeedContent:$false
        }
        else
        {
            Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $afterPath -Revision $Revision -CacheDir $CacheDir -NeedContent:$false -NeedLines:$false
        }
        $currBlameResult = ConvertTo-NarutoResultAdapter -InputObject $currBlameResult -SuccessCode 'SVN_BLAME_LINE_READY' -SkippedCode 'SVN_BLAME_LINE_EMPTY'
        if (-not (Test-NarutoResultSuccess -Result $currBlameResult))
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode ([string]$currBlameResult.ErrorCode) -Message ("Strict transition blame lookup failed for '{0}' at r{1}: {2}" -f $afterPath, $Revision, [string]$currBlameResult.Message) -Context @{
                FilePath = $afterPath
                Revision = [int]$Revision
            }
        }
        $currBlame = $currBlameResult.Data
        if (-not $excludeCommentOnlyLines)
        {
            $bornCountByAuthor = @{}
            $revisionAuthorTable = $null
            if ($currBlame.PSObject.Properties.Match('LineCountByRevisionAuthor').Count -gt 0 -and $null -ne $currBlame.LineCountByRevisionAuthor)
            {
                $lineCountByRevisionAuthor = $currBlame.LineCountByRevisionAuthor
                if ($lineCountByRevisionAuthor.ContainsKey($Revision))
                {
                    $revisionAuthorTable = $lineCountByRevisionAuthor[$Revision]
                }
                elseif ($lineCountByRevisionAuthor.ContainsKey([string]$Revision))
                {
                    $revisionAuthorTable = $lineCountByRevisionAuthor[[string]$Revision]
                }
            }
            if ($revisionAuthorTable -is [hashtable])
            {
                foreach ($authorKey in @($revisionAuthorTable.Keys))
                {
                    $bornCountByAuthor[[string]$authorKey] = [int]$revisionAuthorTable[$authorKey]
                }
            }
            elseif ($currBlame.PSObject.Properties.Match('Lines').Count -gt 0)
            {
                foreach ($line in @($currBlame.Lines))
                {
                    $lineRevision = $null
                    try
                    {
                        $lineRevision = [int]$line.Revision
                    }
                    catch
                    {
                        $lineRevision = $null
                    }
                    if ($lineRevision -ne $Revision)
                    {
                        continue
                    }
                    $lineAuthor = Get-NormalizedAuthorName -Author ([string]$line.Author)
                    if (-not $bornCountByAuthor.ContainsKey($lineAuthor))
                    {
                        $bornCountByAuthor[$lineAuthor] = 0
                    }
                    $bornCountByAuthor[$lineAuthor]++
                }
            }
            return [pscustomobject]@{
                KilledLines = @()
                BornLines = @()
                BornCountByAuthor = $bornCountByAuthor
                MatchedPairs = @()
                MovedPairs = @()
                ReattributedPairs = @()
            }
        }
        $currLines = @(Get-StrictTransitionLineFilterResult -Context $Context -Lines @($currBlame.Lines) -TargetUrl $TargetUrl -FilePath $afterPath -Revision $Revision -CacheDir $CacheDir)
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
            if ($lineRevision -eq $Revision)
            {
                [void]$bornOnly.Add([pscustomobject]@{
                        Index = $currIdx
                        Line = $line
                    })
            }
        }
        return [pscustomobject]@{
            KilledLines = @()
            BornLines = @($bornOnly.ToArray())
            MatchedPairs = @()
            MovedPairs = @()
            ReattributedPairs = @()
        }
    }

    # Fast Path 3: delete-file — ファイル削除。現リビジョンの blame 取得と LCS を省略し、
    # 前リビジョンの全行を killed として扱う。afterPath が null であることが条件。
    if ($hasTransitionStat -and $transitionDeleted -gt 0 -and $transitionAdded -eq 0 -and $beforePath -and (-not $afterPath))
    {
        $prevBlameResult = if ($excludeCommentOnlyLines)
        {
            Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $beforePath -Revision ($Revision - 1) -CacheDir $CacheDir -NeedContent:$false
        }
        else
        {
            Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $beforePath -Revision ($Revision - 1) -CacheDir $CacheDir -NeedContent:$false -NeedLines:$false
        }
        $prevBlameResult = ConvertTo-NarutoResultAdapter -InputObject $prevBlameResult -SuccessCode 'SVN_BLAME_LINE_READY' -SkippedCode 'SVN_BLAME_LINE_EMPTY'
        if (-not (Test-NarutoResultSuccess -Result $prevBlameResult))
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode ([string]$prevBlameResult.ErrorCode) -Message ("Strict transition blame lookup failed for '{0}' at r{1}: {2}" -f $beforePath, ($Revision - 1), [string]$prevBlameResult.Message) -Context @{
                FilePath = $beforePath
                Revision = [int]($Revision - 1)
            }
        }
        $prevBlame = $prevBlameResult.Data
        if (-not $excludeCommentOnlyLines)
        {
            $killedCountByRevisionAuthor = @{}
            if ($prevBlame.PSObject.Properties.Match('LineCountByRevisionAuthor').Count -gt 0 -and $null -ne $prevBlame.LineCountByRevisionAuthor)
            {
                foreach ($revKey in @($prevBlame.LineCountByRevisionAuthor.Keys))
                {
                    $authorTable = $prevBlame.LineCountByRevisionAuthor[$revKey]
                    if ($authorTable -isnot [hashtable])
                    {
                        continue
                    }
                    $copiedTable = @{}
                    foreach ($authorKey in @($authorTable.Keys))
                    {
                        $copiedTable[[string]$authorKey] = [int]$authorTable[$authorKey]
                    }
                    $killedCountByRevisionAuthor[[string]$revKey] = $copiedTable
                }
            }
            elseif ($prevBlame.PSObject.Properties.Match('Lines').Count -gt 0)
            {
                foreach ($line in @($prevBlame.Lines))
                {
                    $bornRev = $null
                    try
                    {
                        $bornRev = [int]$line.Revision
                    }
                    catch
                    {
                        $bornRev = $null
                    }
                    if ($null -eq $bornRev)
                    {
                        continue
                    }
                    $revKey = [string]$bornRev
                    if (-not $killedCountByRevisionAuthor.ContainsKey($revKey))
                    {
                        $killedCountByRevisionAuthor[$revKey] = @{}
                    }
                    $bornAuthor = Get-NormalizedAuthorName -Author ([string]$line.Author)
                    if (-not $killedCountByRevisionAuthor[$revKey].ContainsKey($bornAuthor))
                    {
                        $killedCountByRevisionAuthor[$revKey][$bornAuthor] = 0
                    }
                    $killedCountByRevisionAuthor[$revKey][$bornAuthor]++
                }
            }
            return [pscustomobject]@{
                KilledLines = @()
                KilledCountByRevisionAuthor = $killedCountByRevisionAuthor
                BornLines = @()
                MatchedPairs = @()
                MovedPairs = @()
                ReattributedPairs = @()
            }
        }
        $prevLines = @(Get-StrictTransitionLineFilterResult -Context $Context -Lines @($prevBlame.Lines) -TargetUrl $TargetUrl -FilePath $beforePath -Revision ($Revision - 1) -CacheDir $CacheDir)
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
        return [pscustomobject]@{
            KilledLines = @($killedOnly.ToArray())
            BornLines = @()
            MatchedPairs = @()
            MovedPairs = @()
            ReattributedPairs = @()
        }
    }

    $prevLines = @()
    if ($beforePath)
    {
        $prevBlameResult = Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $beforePath -Revision ($Revision - 1) -CacheDir $CacheDir -NeedContent:$true
        $prevBlameResult = ConvertTo-NarutoResultAdapter -InputObject $prevBlameResult -SuccessCode 'SVN_BLAME_LINE_READY' -SkippedCode 'SVN_BLAME_LINE_EMPTY'
        if (-not (Test-NarutoResultSuccess -Result $prevBlameResult))
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode ([string]$prevBlameResult.ErrorCode) -Message ("Strict transition blame lookup failed for '{0}' at r{1}: {2}" -f $beforePath, ($Revision - 1), [string]$prevBlameResult.Message) -Context @{
                FilePath = $beforePath
                Revision = [int]($Revision - 1)
            }
        }
        $prevBlame = $prevBlameResult.Data
        $prevLines = @(Get-StrictTransitionLineFilterResult -Context $Context -Lines @($prevBlame.Lines) -TargetUrl $TargetUrl -FilePath $beforePath -Revision ($Revision - 1) -CacheDir $CacheDir)
    }
    $currLines = @()
    if ($afterPath)
    {
        $currBlameResult = Get-SvnBlameLine -Context $Context -Repo $TargetUrl -FilePath $afterPath -Revision $Revision -CacheDir $CacheDir -NeedContent:$true
        $currBlameResult = ConvertTo-NarutoResultAdapter -InputObject $currBlameResult -SuccessCode 'SVN_BLAME_LINE_READY' -SkippedCode 'SVN_BLAME_LINE_EMPTY'
        if (-not (Test-NarutoResultSuccess -Result $currBlameResult))
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode ([string]$currBlameResult.ErrorCode) -Message ("Strict transition blame lookup failed for '{0}' at r{1}: {2}" -f $afterPath, $Revision, [string]$currBlameResult.Message) -Context @{
                FilePath = $afterPath
                Revision = [int]$Revision
            }
        }
        $currBlame = $currBlameResult.Data
        $currLines = @(Get-StrictTransitionLineFilterResult -Context $Context -Lines @($currBlame.Lines) -TargetUrl $TargetUrl -FilePath $afterPath -Revision $Revision -CacheDir $CacheDir)
    }
    $prelockedPairs = @()
    if (-not $excludeCommentOnlyLines -and $hasTransitionStat -and $TransitionContext.PSObject.Properties.Match('TransitionHunks').Count -gt 0)
    {
        $transitionHunks = @($TransitionContext.TransitionHunks)
        if ($transitionHunks.Count -gt 0)
        {
            $prelockedPairs = @(Get-BlamePrelockedPairPlan -PreviousLineCount $prevLines.Count -CurrentLineCount $currLines.Count -Hunks $transitionHunks)
        }
    }
    return (Compare-BlameOutput -PreviousLines $prevLines -CurrentLines $currLines -PrelockedPairs $prelockedPairs -MinimalOutput)
}
function Update-StrictAccumulatorFromComparison
{
    <#
    .SYNOPSIS
        Strict 比較結果を born/dead などの集計カウンターへ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object]$Accumulator,
        [object]$Comparison,
        [int]$Revision,
        [string]$Killer,
        [string]$MetricFile,
        [int]$FromRevision,
        [int]$ToRevision
    )
    if ($null -eq $Comparison)
    {
        return
    }

    $moveCount = @($Comparison.MovedPairs).Count
    if ($moveCount -gt 0)
    {
        Add-Count -Table $Accumulator.AuthorInternalMove -Key $Killer -Delta $moveCount
        Add-Count -Table $Accumulator.FileInternalMove -Key $MetricFile -Delta $moveCount
    }

    # born は差分比較の行配列または事前集計のいずれかで加算する。
    $hasBornCountCurrentRevision = $Comparison.PSObject.Properties.Match('BornCountCurrentRevision').Count -gt 0
    $hasBornCountByAuthor = $Comparison.PSObject.Properties.Match('BornCountByAuthor').Count -gt 0 -and $null -ne $Comparison.BornCountByAuthor
    if ($hasBornCountCurrentRevision)
    {
        $bornCount = [int]$Comparison.BornCountCurrentRevision
        if ($bornCount -gt 0)
        {
            Add-Count -Table $Accumulator.AuthorBorn -Key $Killer -Delta $bornCount
            Add-Count -Table $Accumulator.AuthorSurvived -Key $Killer -Delta $bornCount
            Add-Count -Table $Accumulator.FileBorn -Key $MetricFile -Delta $bornCount
            Add-Count -Table $Accumulator.FileSurvived -Key $MetricFile -Delta $bornCount
        }
    }
    elseif ($hasBornCountByAuthor)
    {
        $bornTotal = 0
        foreach ($bornAuthorKey in @($Comparison.BornCountByAuthor.Keys))
        {
            $bornCount = [int]$Comparison.BornCountByAuthor[$bornAuthorKey]
            if ($bornCount -le 0)
            {
                continue
            }
            $bornAuthor = Get-NormalizedAuthorName -Author ([string]$bornAuthorKey)
            Add-Count -Table $Accumulator.AuthorBorn -Key $bornAuthor -Delta $bornCount
            Add-Count -Table $Accumulator.AuthorSurvived -Key $bornAuthor -Delta $bornCount
            $bornTotal += $bornCount
        }
        if ($bornTotal -gt 0)
        {
            Add-Count -Table $Accumulator.FileBorn -Key $MetricFile -Delta $bornTotal
            Add-Count -Table $Accumulator.FileSurvived -Key $MetricFile -Delta $bornTotal
        }
    }
    else
    {
        foreach ($born in @($Comparison.BornLines))
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
            if ($null -eq $bornRev -or $bornRev -ne $Revision)
            {
                continue
            }
            if ($bornRev -lt $FromRevision -or $bornRev -gt $ToRevision)
            {
                continue
            }
            $bornAuthor = Get-NormalizedAuthorName -Author ([string]$line.Author)
            Add-Count -Table $Accumulator.AuthorBorn -Key $bornAuthor
            Add-Count -Table $Accumulator.AuthorSurvived -Key $bornAuthor
            Add-Count -Table $Accumulator.FileBorn -Key $MetricFile
            Add-Count -Table $Accumulator.FileSurvived -Key $MetricFile
        }
    }

    # dead は行配列または (revision,author) 集計のいずれかで減算・分類する。
    $hasKilledCountByRevisionAuthor = $Comparison.PSObject.Properties.Match('KilledCountByRevisionAuthor').Count -gt 0 -and $null -ne $Comparison.KilledCountByRevisionAuthor
    if ($hasKilledCountByRevisionAuthor)
    {
        foreach ($bornRevKey in @($Comparison.KilledCountByRevisionAuthor.Keys))
        {
            $bornRev = $null
            try
            {
                $bornRev = [int]$bornRevKey
            }
            catch
            {
                $bornRev = $null
            }
            if ($null -eq $bornRev -or $bornRev -lt $FromRevision -or $bornRev -gt $ToRevision)
            {
                continue
            }
            $authorTable = $Comparison.KilledCountByRevisionAuthor[$bornRevKey]
            if ($authorTable -isnot [hashtable])
            {
                continue
            }
            foreach ($bornAuthorKey in @($authorTable.Keys))
            {
                $killCount = [int]$authorTable[$bornAuthorKey]
                if ($killCount -le 0)
                {
                    continue
                }
                $bornAuthor = Get-NormalizedAuthorName -Author ([string]$bornAuthorKey)
                Add-Count -Table $Accumulator.AuthorDead -Key $bornAuthor -Delta $killCount
                Add-Count -Table $Accumulator.FileDead -Key $MetricFile -Delta $killCount
                Add-Count -Table $Accumulator.AuthorSurvived -Key $bornAuthor -Delta (-1 * $killCount)
                Add-Count -Table $Accumulator.FileSurvived -Key $MetricFile -Delta (-1 * $killCount)
                if ($bornAuthor -eq $Killer)
                {
                    Add-Count -Table $Accumulator.AuthorSelfDead -Key $bornAuthor -Delta $killCount
                    Add-Count -Table $Accumulator.FileSelfCancel -Key $MetricFile -Delta $killCount
                }
                else
                {
                    Add-Count -Table $Accumulator.AuthorOtherDead -Key $bornAuthor -Delta $killCount
                    Add-Count -Table $Accumulator.AuthorCrossRevert -Key $bornAuthor -Delta $killCount
                    Add-Count -Table $Accumulator.AuthorRemovedByOthers -Key $bornAuthor -Delta $killCount
                    Add-Count -Table $Accumulator.FileCrossRevert -Key $MetricFile -Delta $killCount
                    Add-Count -Table $Accumulator.AuthorModifiedOthersCode -Key $Killer -Delta $killCount
                    [void]$Accumulator.RevsWhereKilledOthers.Add(([string]$Revision + [char]31 + $Killer))
                    if (-not $Accumulator.KillMatrix.ContainsKey($Killer))
                    {
                        $Accumulator.KillMatrix[$Killer] = @{}
                    }
                    Add-Count -Table $Accumulator.KillMatrix[$Killer] -Key $bornAuthor -Delta $killCount
                }
            }
        }
    }
    else
    {
        foreach ($killed in @($Comparison.KilledLines))
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
            Add-Count -Table $Accumulator.AuthorDead -Key $bornAuthor
            Add-Count -Table $Accumulator.FileDead -Key $MetricFile
            Add-Count -Table $Accumulator.AuthorSurvived -Key $bornAuthor -Delta (-1)
            Add-Count -Table $Accumulator.FileSurvived -Key $MetricFile -Delta (-1)
            if ($bornAuthor -eq $Killer)
            {
                Add-Count -Table $Accumulator.AuthorSelfDead -Key $bornAuthor
                Add-Count -Table $Accumulator.FileSelfCancel -Key $MetricFile
            }
            else
            {
                Add-Count -Table $Accumulator.AuthorOtherDead -Key $bornAuthor
                Add-Count -Table $Accumulator.AuthorCrossRevert -Key $bornAuthor
                Add-Count -Table $Accumulator.AuthorRemovedByOthers -Key $bornAuthor
                Add-Count -Table $Accumulator.FileCrossRevert -Key $MetricFile
                Add-Count -Table $Accumulator.AuthorModifiedOthersCode -Key $Killer
                [void]$Accumulator.RevsWhereKilledOthers.Add(([string]$Revision + [char]31 + $Killer))
                if (-not $Accumulator.KillMatrix.ContainsKey($Killer))
                {
                    $Accumulator.KillMatrix[$Killer] = @{}
                }
                Add-Count -Table $Accumulator.KillMatrix[$Killer] -Key $bornAuthor
            }
        }
    }
}
function Get-StrictAttributionResult
{
    <#
    .SYNOPSIS
        Strict 帰属集計値と hunk 詳細を最終返却形式へ整形する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [object]$Accumulator,
        [object]$StrictHunk
    )
    return [pscustomobject]@{
        AuthorBorn = $Accumulator.AuthorBorn
        AuthorDead = $Accumulator.AuthorDead
        AuthorSurvived = $Accumulator.AuthorSurvived
        AuthorSelfDead = $Accumulator.AuthorSelfDead
        AuthorOtherDead = $Accumulator.AuthorOtherDead
        AuthorCrossRevert = $Accumulator.AuthorCrossRevert
        AuthorRemovedByOthers = $Accumulator.AuthorRemovedByOthers
        FileBorn = $Accumulator.FileBorn
        FileDead = $Accumulator.FileDead
        FileSurvived = $Accumulator.FileSurvived
        FileSelfCancel = $Accumulator.FileSelfCancel
        FileCrossRevert = $Accumulator.FileCrossRevert
        AuthorInternalMoveCount = $Accumulator.AuthorInternalMove
        FileInternalMoveCount = $Accumulator.FileInternalMove
        AuthorRepeatedHunk = $StrictHunk.AuthorRepeatedHunk
        AuthorPingPong = $StrictHunk.AuthorPingPong
        FileRepeatedHunk = $StrictHunk.FileRepeatedHunk
        FilePingPong = $StrictHunk.FilePingPong
        AuthorModifiedOthersCode = $Accumulator.AuthorModifiedOthersCode
        RevsWhereKilledOthers = $Accumulator.RevsWhereKilledOthers
        KillMatrix = $Accumulator.KillMatrix
    }
}
function Resolve-StrictKillerAuthor
{
    <#
    .SYNOPSIS
        Strict 帰属計算で現在コミットの削除側作者を解決する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$Commit,
        [hashtable]$RevToAuthor
    )
    $revision = [int]$Commit.Revision
    if ($RevToAuthor.ContainsKey($revision))
    {
        return (Get-NormalizedAuthorName -Author ([string]$RevToAuthor[$revision]))
    }
    return (Get-NormalizedAuthorName -Author ([string]$Commit.Author))
}
function Remove-SvnBlameLineMemoryCacheOlderThanRevision
{
    <#
    .SYNOPSIS
        SvnBlameLineMemoryCache から指定リビジョン未満のキーを削除する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [int]$MinimumRevision
    )
    if ($null -eq $Context.Caches.SvnBlameLineMemoryCache -or $Context.Caches.SvnBlameLineMemoryCache.Count -eq 0)
    {
        return
    }
    $separator = [string][char]31
    $keysToRemove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($cacheKey in @($Context.Caches.SvnBlameLineMemoryCache.Keys))
    {
        $parts = ([string]$cacheKey).Split(@($separator), 2, [System.StringSplitOptions]::None)
        if ($parts.Count -eq 0)
        {
            continue
        }
        $entryRevision = 0
        if (-not [int]::TryParse([string]$parts[0], [ref]$entryRevision))
        {
            continue
        }
        if ($entryRevision -lt $MinimumRevision)
        {
            [void]$keysToRemove.Add([string]$cacheKey)
        }
    }
    foreach ($removeKey in @($keysToRemove.ToArray()))
    {
        [void]$Context.Caches.SvnBlameLineMemoryCache.Remove($removeKey)
    }
}
function Invoke-StrictCommitAttribution
{
    <#
    .SYNOPSIS
        Strict 帰属計算をコミット単位で実行して集計へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$Accumulator,
        [object]$Commit,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [hashtable]$RenameMap = @{}
    )
    $revision = [int]$Commit.Revision
    if ($revision -lt $FromRevision -or $revision -gt $ToRevision)
    {
        return $false
    }
    $killer = Resolve-StrictKillerAuthor -Commit $Commit -RevToAuthor $RevToAuthor
    $transitions = @(Get-CommitFileTransition -Commit $Commit)
    foreach ($transition in $transitions)
    {
        try
        {
            $transitionContext = Resolve-StrictTransitionContext -Context $Context -Commit $Commit -Transition $transition -RenameMap $RenameMap
            if ($null -eq $transitionContext)
            {
                continue
            }
            $comparison = Get-StrictTransitionComparison -Context $Context -TransitionContext $transitionContext -TargetUrl $TargetUrl -Revision $revision -CacheDir $CacheDir
            if ($null -eq $comparison)
            {
                continue
            }
            Update-StrictAccumulatorFromComparison -Accumulator $Accumulator -Comparison $comparison -Revision $revision -Killer $killer -MetricFile ([string]$transitionContext.MetricFile) -FromRevision $FromRevision -ToRevision $ToRevision
        }
        catch
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_BLAME_ATTRIBUTION_FAILED' -Message ("Strict blame attribution failed at r{0} (before='{1}', after='{2}'): {3}" -f $revision, [string]$transition.BeforePath, [string]$transition.AfterPath, $_.Exception.Message) -Context @{
                Revision = [int]$revision
                BeforePath = [string]$transition.BeforePath
                AfterPath = [string]$transition.AfterPath
            } -InnerException $_.Exception
        }
    }
    # 次コミットで再利用され得るのは「現コミット revision」のみ。
    # それより古い revision は除去し、再利用性とメモリ上限を両立する。
    Remove-SvnBlameLineMemoryCacheOlderThanRevision -Context $Context -MinimumRevision $revision
    return $true
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [hashtable]$RenameMap = @{},
        [int]$Parallel = 1
    )
    $accumulator = New-StrictAttributionAccumulator
    $strictStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $prefetchTargets = @(Get-StrictBlamePrefetchTarget -Context $Context -Commits $Commits -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir)
    $targetEnumerationSeconds = $strictStopwatch.Elapsed.TotalSeconds
    Invoke-StrictBlameCachePrefetch -Context $Context -Targets $prefetchTargets -TargetUrl $TargetUrl -CacheDir $CacheDir -Parallel $Parallel
    $prefetchSeconds = $strictStopwatch.Elapsed.TotalSeconds
    $sortedCommits = @($Commits | Sort-Object Revision)
    $deathTotal = $sortedCommits.Count
    $deathIdx = 0
    foreach ($commit in $sortedCommits)
    {
        $pct = [Math]::Min(100, [int](($deathIdx / [Math]::Max(1, $deathTotal)) * 100))
        Write-Progress -Id 3 -Activity '行単位の帰属解析' -Status ('r{0} ({1}/{2})' -f [int]$commit.Revision, ($deathIdx + 1), $deathTotal) -PercentComplete $pct
        $processed = Invoke-StrictCommitAttribution -Context $Context -Accumulator $accumulator -Commit $commit -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -RenameMap $RenameMap
        if ($processed)
        {
            $deathIdx++
        }
    }
    $commitLoopSeconds = $strictStopwatch.Elapsed.TotalSeconds
    Write-Progress -Id 3 -Activity '行単位の帰属解析' -Completed
    try
    {
        $strictHunk = Get-StrictHunkDetail -Context $Context -Commits $Commits -RevToAuthor $RevToAuthor -RenameMap $RenameMap
    }
    catch
    {
        Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_HUNK_ANALYSIS_FAILED' -Message ("Strict hunk analysis failed: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) -Context @{} -InnerException $_.Exception
    }
    $hunkSeconds = $strictStopwatch.Elapsed.TotalSeconds
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictBreakdown' -Key 'TargetEnumeration' -Value (Format-MetricValue -Value $targetEnumerationSeconds)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictBreakdown' -Key 'Prefetch' -Value (Format-MetricValue -Value ($prefetchSeconds - $targetEnumerationSeconds))
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictBreakdown' -Key 'CommitLoop' -Value (Format-MetricValue -Value ($commitLoopSeconds - $prefetchSeconds))
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictBreakdown' -Key 'Hunk' -Value (Format-MetricValue -Value ($hunkSeconds - $commitLoopSeconds))
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StrictBreakdown' -Key 'Total' -Value (Format-MetricValue -Value $hunkSeconds)
    return (Get-StrictAttributionResult -Accumulator $accumulator -StrictHunk $strictHunk)
}
# endregion Strict 帰属
# region メトリクス計算
function Initialize-CommitterMetricState
{
    <#
    .SYNOPSIS
        コミッター集計用の初期状態オブジェクトを作成する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Author)
    return [ordered]@{
        Author = $Author
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
function Update-CommitterMetricState
{
    <#
    .SYNOPSIS
        コミット1件分の情報をコミッター集計状態へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [hashtable]$States,
        [object]$Commit,
        [hashtable]$RenameMap = @{}
    )
    $author = [string]$Commit.Author
    if (-not $States.ContainsKey($author))
    {
        $States[$author] = Initialize-CommitterMetricState -Author $author
    }

    $state = $States[$author]
    $state.CommitCount++
    if ($Commit.Date)
    {
        [void]$state.ActiveDays.Add(([datetime]$Commit.Date).ToString('yyyy-MM-dd'))
    }
    $state.Added += [int]$Commit.AddedLines
    $state.Deleted += [int]$Commit.DeletedLines

    $message = [string]$Commit.Message
    if ($null -eq $message)
    {
        $message = ''
    }
    $state.MsgLen += $message.Length
    $messageMetric = Get-MessageMetricCount -Message $message
    $state.Issue += $messageMetric.IssueIdMentionCount
    $state.Fix += $messageMetric.FixKeywordCount
    $state.Revert += $messageMetric.RevertKeywordCount
    $state.Merge += $messageMetric.MergeKeywordCount

    foreach ($filePath in @($Commit.FilesChanged))
    {
        $resolvedFilePath = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$filePath) -RenameMap $RenameMap
        [void]$state.Files.Add($resolvedFilePath)
        $idx = $resolvedFilePath.LastIndexOf('/')
        $dir = if ($idx -lt 0)
        {
            '.'
        }
        else
        {
            $resolvedFilePath.Substring(0, $idx)
        }
        if ($dir)
        {
            [void]$state.Dirs.Add($dir)
        }
        $diffStat = $Commit.FileDiffStats[$filePath]
        $fileChurn = [int]$diffStat.AddedLines + [int]$diffStat.DeletedLines
        if (-not $state.FileChurn.ContainsKey($resolvedFilePath))
        {
            $state.FileChurn[$resolvedFilePath] = 0
        }
        $state.FileChurn[$resolvedFilePath] += $fileChurn
        if ([bool]$diffStat.IsBinary)
        {
            $state.Binary++
        }
    }

    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        switch (([string]$pathEntry.Action).ToUpperInvariant())
        {
            'A'
            {
                $state.ActA++
            }
            'M'
            {
                $state.ActM++
            }
            'D'
            {
                $state.ActD++
            }
            'R'
            {
                $state.ActR++
            }
        }
    }
}
function ConvertTo-CommitterMetricRows
{
    <#
    .SYNOPSIS
        コミッター集計状態を出力行へ変換する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [hashtable]$States,
        [hashtable]$FileAuthors
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($state in $States.Values)
    {
        $net = [int]$state.Added - [int]$state.Deleted
        $churn = [int]$state.Added + [int]$state.Deleted
        $coAvg = 0.0
        $coMax = 0.0
        if ($state.Files.Count -gt 0)
        {
            $vals = @()
            foreach ($file in $state.Files)
            {
                if ($FileAuthors.ContainsKey($file))
                {
                    $vals += [Math]::Max(0, $FileAuthors[$file].Count - 1)
                }
            }
            if ($vals.Count -gt 0)
            {
                $coAvg = ($vals | Measure-Object -Average).Average
                $coMax = ($vals | Measure-Object -Maximum).Maximum
            }
        }
        $entropy = Get-Entropy -Values @($state.FileChurn.Values | ForEach-Object { [double]$_ })
        $churnPerCommit = if ($state.CommitCount -gt 0)
        {
            $churn / [double]$state.CommitCount
        }
        else
        {
            0
        }
        $messageLengthAverage = if ($state.CommitCount -gt 0)
        {
            $state.MsgLen / [double]$state.CommitCount
        }
        else
        {
            0
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                '作者' = [string]$state.Author
                'コミット数' = [int]$state.CommitCount
                '活動日数' = [int]$state.ActiveDays.Count
                '変更ファイル数' = [int]$state.Files.Count
                '変更ディレクトリ数' = [int]$state.Dirs.Count
                '追加行数' = [int]$state.Added
                '削除行数' = [int]$state.Deleted
                '純増行数' = $net
                '総チャーン' = $churn
                'コミットあたりチャーン' = Format-MetricValue -Value $churnPerCommit
                '削除対追加比' = if ([int]$state.Added -gt 0)
                {
                    Format-MetricValue -Value ([int]$state.Deleted / [double]$state.Added)
                }
                else
                {
                    $null
                }
                'チャーン対純増比' = if ([Math]::Abs($net) -gt 0)
                {
                    Format-MetricValue -Value ($churn / [double][Math]::Abs($net))
                }
                else
                {
                    $null
                }
                'リワーク率' = if ($churn -gt 0)
                {
                    Format-MetricValue -Value (1 - [Math]::Abs($net) / [double]$churn)
                }
                else
                {
                    $null
                }
                'バイナリ変更回数' = [int]$state.Binary
                '追加アクション数' = [int]$state.ActA
                '変更アクション数' = [int]$state.ActM
                '削除アクション数' = [int]$state.ActD
                '置換アクション数' = [int]$state.ActR
                '生存行数' = $null
                $Context.Metrics.ColDeadAdded = $null
                '所有行数' = $null
                '所有割合' = $null
                '自己相殺行数' = $null
                '他者差戻行数' = $null
                '同一箇所反復編集数' = $null
                'ピンポン回数' = $null
                '内部移動行数' = $null
                '他者コード変更行数' = $null
                '他者コード変更生存行数' = $null
                '他者コード変更生存率' = $null
                'ピンポン率' = $null
                '変更エントロピー' = Format-MetricValue -Value $entropy
                '平均共同作者数' = Format-MetricValue -Value $coAvg
                '最大共同作者数' = [int]$coMax
                'メッセージ総文字数' = [int]$state.MsgLen
                'メッセージ平均文字数' = Format-MetricValue -Value $messageLengthAverage
                '課題ID言及数' = [int]$state.Issue
                '修正キーワード数' = [int]$state.Fix
                '差戻キーワード数' = [int]$state.Revert
                'マージキーワード数' = [int]$state.Merge
            })
    }
    return @($rows.ToArray())
}
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [object[]]$Commits, [hashtable]$RenameMap = @{})
    $states = @{}
    $fileAuthors = @{}
    foreach ($commit in @($Commits))
    {
        $author = [string]$commit.Author
        foreach ($filePath in @($commit.FilesChanged))
        {
            $resolvedFilePath = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$filePath) -RenameMap $RenameMap
            if (-not $fileAuthors.ContainsKey($resolvedFilePath))
            {
                $fileAuthors[$resolvedFilePath] = New-Object 'System.Collections.Generic.HashSet[string]'
            }
            [void]$fileAuthors[$resolvedFilePath].Add($author)
        }
    }

    foreach ($commit in @($Commits))
    {
        Update-CommitterMetricState -Context $Context -States $states -Commit $commit -RenameMap $RenameMap
    }
    $rows = ConvertTo-CommitterMetricRows -Context $Context -States $states -FileAuthors $fileAuthors
    return @($rows | Sort-Object -Property @{Expression = '総チャーン'
            Descending = $true
        }, '作者')
}
function Initialize-FileMetricState
{
    <#
    .SYNOPSIS
        ファイル集計用の初期状態オブジェクトを作成する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$FilePath)
    return [ordered]@{
        FilePath = $FilePath
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
function Update-FileMetricState
{
    <#
    .SYNOPSIS
        コミット1件分の情報をファイル集計状態へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [hashtable]$States,
        [object]$Commit,
        [hashtable]$RenameMap = @{}
    )
    $author = [string]$Commit.Author
    $files = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($filePath in @($Commit.FilesChanged))
    {
        $resolved = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$filePath) -RenameMap $RenameMap
        [void]$files.Add($resolved)
    }
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        $resolved = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$pathEntry.Path) -RenameMap $RenameMap
        [void]$files.Add($resolved)
    }
    foreach ($file in $files)
    {
        if (-not $States.ContainsKey($file))
        {
            $States[$file] = Initialize-FileMetricState -FilePath $file
        }
        $state = $States[$file]
        $added = $state.Commits.Add([int]$Commit.Revision)
        if ($added -and $Commit.Date)
        {
            [void]$state.Dates.Add([datetime]$Commit.Date)
        }
        [void]$state.Authors.Add($author)
    }

    foreach ($filePath in @($Commit.FilesChanged))
    {
        $resolvedFilePath = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$filePath) -RenameMap $RenameMap
        $state = $States[$resolvedFilePath]
        $diffStat = $Commit.FileDiffStats[$filePath]
        $addedLines = [int]$diffStat.AddedLines
        $deletedLines = [int]$diffStat.DeletedLines
        $state.Added += $addedLines
        $state.Deleted += $deletedLines
        if ([bool]$diffStat.IsBinary)
        {
            $state.Binary++
        }
        if (-not $state.AuthorChurn.ContainsKey($author))
        {
            $state.AuthorChurn[$author] = 0
        }
        $state.AuthorChurn[$author] += ($addedLines + $deletedLines)
    }
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        $resolvedPath = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$pathEntry.Path) -RenameMap $RenameMap
        $state = $States[$resolvedPath]
        switch (([string]$pathEntry.Action).ToUpperInvariant())
        {
            'A'
            {
                $state.Create++
            }
            'D'
            {
                $state.Delete++
            }
            'R'
            {
                $state.Replace++
            }
        }
    }
}
function ConvertTo-FileMetricRows
{
    <#
    .SYNOPSIS
        ファイル集計状態を出力行へ変換する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [hashtable]$States
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($state in $States.Values)
    {
        $commitCount = [int]$state.Commits.Count
        $added = [int]$state.Added
        $deleted = [int]$state.Deleted
        $churn = $added + $deleted
        $first = $null
        $last = $null
        if ($commitCount -gt 0)
        {
            $first = ($state.Commits | Measure-Object -Minimum).Minimum
            $last = ($state.Commits | Measure-Object -Maximum).Maximum
        }
        $averageIntervalDays = 0.0
        $spanDays = 0.0
        if ($state.Dates.Count -gt 1)
        {
            $dates = @($state.Dates | Sort-Object -Unique)
            $vals = @()
            for ($i = 1
                $i -lt $dates.Count
                $i++)
            {
                $vals += (New-TimeSpan -Start $dates[$i - 1] -End $dates[$i]).TotalDays
            }
            if ($vals.Count -gt 0)
            {
                $averageIntervalDays = ($vals | Measure-Object -Average).Average
            }
            $spanDays = (New-TimeSpan -Start $dates[0] -End $dates[-1]).TotalDays
        }
        $topShare = 0.0
        if ($churn -gt 0 -and $state.AuthorChurn.Count -gt 0)
        {
            $mx = ($state.AuthorChurn.Values | Measure-Object -Maximum).Maximum
            $topShare = $mx / [double]$churn
        }
        $authorCount = [int]$state.Authors.Count
        $frequency = [double]$commitCount / [Math]::Max($spanDays, 1.0)
        $hotspotScore = [double]$commitCount * [double]$authorCount * [double]$churn * $frequency
        [void]$rows.Add([pscustomobject][ordered]@{
                'ファイルパス' = [string]$state.FilePath
                'コミット数' = $commitCount
                '作者数' = $authorCount
                '追加行数' = $added
                '削除行数' = $deleted
                '純増行数' = ($added - $deleted)
                '総チャーン' = $churn
                'バイナリ変更回数' = [int]$state.Binary
                '作成回数' = [int]$state.Create
                '削除回数' = [int]$state.Delete
                '置換回数' = [int]$state.Replace
                '初回変更リビジョン' = $first
                '最終変更リビジョン' = $last
                '平均変更間隔日数' = Format-MetricValue -Value $averageIntervalDays
                '活動期間日数' = Format-MetricValue -Value $spanDays
                '生存行数 (範囲指定)' = $null
                $Context.Metrics.ColDeadAdded = $null
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
    foreach ($row in $sorted)
    {
        $rank++
        $row.'ホットスポット順位' = $rank
    }
    return $sorted
}
function Get-CoChangeCounters
{
    <#
    .SYNOPSIS
        共変更集計に必要なペア/ファイル頻度カウンタを算出する。
    .DESCRIPTION
        Committer/File メトリクスは Initialize → Update → ConvertTo の3段階で
        コミットごとに状態を蓄積するパターンを使うが、共変更分析はコミット単位の
        状態蓄積が不要（ペア列挙を1パスで完結できる）ため、初期化と更新を
        本関数に集約し Get → ConvertTo の2段階パターンを採用している。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RenameMap = @{}
    )
    $pair = @{}
    $fileCount = @{}
    $commitTotal = 0
    foreach ($commit in @($Commits))
    {
        $files = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($filePath in @($commit.FilesChanged))
        {
            $resolved = Resolve-PathByRenameMap -Context $Context -FilePath ([string]$filePath) -RenameMap $RenameMap
            [void]$files.Add($resolved)
        }
        if ($files.Count -eq 0)
        {
            continue
        }
        $commitTotal++
        foreach ($file in $files)
        {
            if (-not $fileCount.ContainsKey($file))
            {
                $fileCount[$file] = 0
            }
            $fileCount[$file]++
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
                $pairKey = $list[$i] + [char]31 + $list[$j]
                if (-not $pair.ContainsKey($pairKey))
                {
                    $pair[$pairKey] = 0
                }
                $pair[$pairKey]++
            }
        }
    }
    return [pscustomobject]@{
        Pair = $pair
        FileCount = $fileCount
        CommitTotal = [int]$commitTotal
    }
}
function ConvertTo-CoChangeRows
{
    <#
    .SYNOPSIS
        共変更カウンタを出力行へ変換する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [hashtable]$Pair,
        [hashtable]$FileCount,
        [int]$CommitTotal
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pairKey in $Pair.Keys)
    {
        $parts = $pairKey -split [char]31, 2
        $fileA = $parts[0]
        $fileB = $parts[1]
        $co = [int]$Pair[$pairKey]
        $countA = [int]$FileCount[$fileA]
        $countB = [int]$FileCount[$fileB]
        $jaccard = 0.0
        $denominator = ($countA + $countB - $co)
        if ($denominator -gt 0)
        {
            $jaccard = $co / [double]$denominator
        }
        $lift = 0.0
        if ($CommitTotal -gt 0 -and $countA -gt 0 -and $countB -gt 0)
        {
            $pab = $co / [double]$CommitTotal
            $pa = $countA / [double]$CommitTotal
            $pb = $countB / [double]$CommitTotal
            if (($pa * $pb) -gt 0)
            {
                $lift = $pab / ($pa * $pb)
            }
        }
        [void]$rows.Add([pscustomobject][ordered]@{
                'ファイルA' = $fileA
                'ファイルB' = $fileB
                '共変更回数' = $co
                'Jaccard' = Format-MetricValue -Value $jaccard
                'リフト値' = Format-MetricValue -Value $lift
            })
    }
    return @($rows.ToArray())
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
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RenameMap = @{}
    )
    $states = @{}
    foreach ($commit in @($Commits))
    {
        Update-FileMetricState -Context $Context -States $states -Commit $commit -RenameMap $RenameMap
    }
    return @(ConvertTo-FileMetricRows -Context $Context -States $states)
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [int]$TopNCount = 50,
        [hashtable]$RenameMap = @{}
    )
    $counters = Get-CoChangeCounters -Context $Context -Commits $Commits -RenameMap $RenameMap
    $rows = ConvertTo-CoChangeRows -Pair $counters.Pair -FileCount $counters.FileCount -CommitTotal ([int]$counters.CommitTotal
    )
    $sorted = @($rows | Sort-Object -Property @{Expression = '共変更回数'
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
function New-NarutoVisualizationSkippedResult
{
    <#
    .SYNOPSIS
        可視化出力のスキップ結果を記録し NarutoResult を返す。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [ValidateSet('Warning', 'Verbose')]
        [string]$Level = 'Verbose',
        [string]$OutputName,
        [string]$ErrorCode,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    Write-NarutoDiagnostic -Context $Context -Level $Level -ErrorCode $ErrorCode -Message $Message -OutputName $OutputName -Data $Data
    return (New-NarutoResultSkipped -ErrorCode $ErrorCode -Message $Message -Context $Data)
}
function Initialize-NarutoVisualizationOutputDirectory
{
    <#
    .SYNOPSIS
        可視化出力用のディレクトリ初期化を統一する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$OutDirectory,
        [string]$CallerName,
        [string]$OutputName
    )
    if ([string]::IsNullOrWhiteSpace($OutDirectory))
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Warning' -OutputName $OutputName -ErrorCode 'OUTPUT_OUT_DIRECTORY_EMPTY' -Message ("{0}: OutDirectory が空です。" -f $CallerName))
    }
    $directoryResult = Initialize-OutputDirectory -Path $OutDirectory -CallerName $CallerName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Warning' -OutputName $OutputName -ErrorCode ([string]$directoryResult.ErrorCode) -Message ([string]$directoryResult.Message) -Data @{
                CallerName = $CallerName
                OutDirectory = $OutDirectory
            })
    }
    return $directoryResult
}
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
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$OutDirectory,
        [object[]]$Committers,
        [object[]]$Files,
        [object[]]$Couplings,
        [int]$TopNCount,
        [string]$EncodingName
    )
    $initResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-PlantUmlFile' -OutputName 'plantuml'
    if (-not (Test-NarutoResultSuccess -Result $initResult))
    {
        return $initResult
    }
    if ($TopNCount -le 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName 'plantuml' -ErrorCode 'OUTPUT_PLANTUML_SKIPPED_TOPN' -Message 'TopNCount が 0 以下のため PlantUML 出力をスキップしました。')
    }
    if ((-not $Committers -or @($Committers).Count -eq 0) -and (-not $Files -or @($Files).Count -eq 0) -and (-not $Couplings -or @($Couplings).Count -eq 0))
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName 'plantuml' -ErrorCode 'OUTPUT_PLANTUML_NO_DATA' -Message '可視化データが空のため PlantUML 出力をスキップしました。')
    }
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
    return (New-NarutoResultSuccess -Data @(
            (Join-Path $OutDirectory 'contributors_summary.puml'),
            (Join-Path $OutDirectory 'hotspots.puml'),
            (Join-Path $OutDirectory 'cochange_network.puml')
        ) -ErrorCode 'OUTPUT_PLANTUML_WRITTEN' -Message 'PlantUML 出力を生成しました。')
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
        TopN のファイルをホットスポット順位順で選び、ホットスポットスコア（対数スケール）と最多作者blame占有率を軸に配置する。
        バブル面積は総チャーンに比例させ、色はホットスポット順位を赤から緑で表現する。
        X軸: ホットスポットスコア（対数スケール、目盛りは10の累乗）、Y軸: 最多作者blame占有率、バブルサイズ: 総チャーン、色: ホットスポット順位
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'file_hotspot.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-FileBubbleChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }

    if (-not $Files -or @($Files).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_FILE_HOTSPOT_NO_DATA' -Message 'Write-FileBubbleChart: Files が空のため SVG を生成しません。')
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_FILE_HOTSPOT_NO_PLOTTABLE_DATA' -Message 'Write-FileBubbleChart: blame占有率を持つファイルがないため SVG を生成しません。')
    }
    if ($TopNCount -gt 0)
    {
        $topFiles = @($topFiles | Select-Object -First $TopNCount)
    }

    $svgWidth = 640.0
    $svgHeight = 592.0
    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTopLarge
    $plotWidth = 480.0
    $plotHeight = 440.0
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $tickCount = 6

    $maxRawScore = 0.0
    $maxLogScore = 0.0
    $maxBlameShare = 0.0
    $maxChurn = 0.0
    $maxRank = 1
    foreach ($f in $topFiles)
    {
        $scoreCount = [double]$f.'ホットスポットスコア'
        if ($scoreCount -lt 0.0)
        {
            $scoreCount = 0.0
        }
        $blameShare = [double]$f.'最多作者blame占有率'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'
        if ($scoreCount -gt $maxRawScore)
        {
            $maxRawScore = $scoreCount
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
    if ($maxRawScore -le 0.0)
    {
        $maxRawScore = 1.0
    }
    $maxLogScore = [Math]::Ceiling([Math]::Log10(1.0 + $maxRawScore))
    if ($maxLogScore -le 0)
    {
        $maxLogScore = 1
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
    [void]$sb.AppendLine(('<text class="subtitle" x="20" y="44">X: ホットスポットスコア（スコア=コミット数{0}×作者数×総チャーン÷max(活動期間日数,1)） / Y: 最多作者blame占有率（max(作者別生存行数)÷生存行数合計）</text>' -f [char]0x00B2))
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="58">円: 総チャーン / 色: ホットスポット順位（＝スコア降順）</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))

    # X軸グリッド線とラベル（ホットスポットスコア、対数スケール：0 および 10 の累乗で目盛り）
    # 目盛り 0 （プロット左端）
    $xTick0 = [Math]::Round($plotLeft, 2)
    [void]$sb.AppendLine(('<line class="grid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f $xTick0, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1}" text-anchor="middle">{2}</text>' -f $xTick0, [int]($plotBottom + 16), 0))
    # 目盛り 10^1, 10^2, ... 10^maxLogScore
    for ($exp = 1
        $exp -le $maxLogScore
        $exp++)
    {
        $tickValue = [Math]::Pow(10.0, $exp)
        $logTickValue = [Math]::Log10(1.0 + $tickValue)
        $x = $plotLeft + (($logTickValue / [double]$maxLogScore) * $plotWidth)
        $xRounded = [Math]::Round($x, 2)
        $xLabel = [long]$tickValue
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
        if ($scoreCount -lt 0.0)
        {
            $scoreCount = 0.0
        }
        $scoreCountLog = [Math]::Log10(1.0 + $scoreCount)
        $blameShare = [double]$f.'最多作者blame占有率'
        $churnCount = [double]$f.'総チャーン'
        $rank = [int]$f.'ホットスポット順位'

        $radius = & $radiusCalculator -ChurnValue $churnCount
        $x = $plotLeft + (($scoreCountLog / $maxLogScore) * $plotWidth)
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
        $tooltip = ('{0}&#10;生値スコア={1}, 対数スコア={2}, blame占有率={3}%, 総チャーン={4}, 順位={5}' -f $safePath, [Math]::Round($scoreCount, 2), [Math]::Round($scoreCountLog, 4), $blamePct, [int][Math]::Round($churnCount), $rank)

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
        $fittedLabel = Get-SvgFittedText -Context $Context -Text $label -MaxWidth $maxLabelWidth -FontSize $labelFontSize
        if (-not [string]::IsNullOrWhiteSpace($fittedLabel))
        {
            if ($labelAnchor -eq 'middle')
            {
                $halfWidth = (Measure-SvgTextWidth -Context $Context -Text $fittedLabel -FontSize $labelFontSize) / 2.0
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'file_hotspot.svg') -ErrorCode 'OUTPUT_FILE_HOTSPOT_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'file_quality_scatter.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-FileQualityScatterChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Files -or @($Files).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_FILE_QUALITY_NO_DATA' -Message 'Write-FileQualityScatterChart: Files が空です。')
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
        $prop = $f.PSObject.Properties[$Context.Metrics.ColDeadAdded]
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_FILE_QUALITY_NO_PLOTTABLE_DATA' -Message 'Write-FileQualityScatterChart: 描画対象データがありません。')
    }

    # 描画定数
    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTopLarge
    $plotWidth = $Context.Constants.SvgPlotWidth
    $plotHeight = $Context.Constants.SvgPlotHeight
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
    $minBubble = $Context.Constants.SvgBubbleMin
    $maxBubble = $Context.Constants.SvgBubbleMax

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
    for ($tick = 0.0; $tick -le 1.01; $tick += $Context.Constants.SvgQuadrantTickStep)
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'file_quality_scatter.svg') -ErrorCode 'OUTPUT_FILE_QUALITY_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'commit_timeline.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-CommitTimelineChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Commits -or @($Commits).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMIT_TIMELINE_NO_DATA' -Message 'Write-CommitTimelineChart: Commits が空です。')
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMIT_TIMELINE_NO_PLOTTABLE_DATA' -Message 'Write-CommitTimelineChart: 描画可能なコミットがありません。')
    }
    $sorted = @($commitData | Sort-Object -Property DateTime)

    # 作者→色マッピング
    $colorPalette = $Context.Constants.DefaultColorPalette
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
    $plotTop = $Context.Constants.SvgPlotTop
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'commit_timeline.svg') -ErrorCode 'OUTPUT_COMMIT_TIMELINE_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'commit_scatter.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-CommitScatterChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Commits -or @($Commits).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMIT_SCATTER_NO_DATA' -Message 'Write-CommitScatterChart: Commits が空です。')
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMIT_SCATTER_NO_PLOTTABLE_DATA' -Message 'Write-CommitScatterChart: 描画対象データがありません。')
    }

    # 作者→色マッピング
    $colorPalette = $Context.Constants.DefaultColorPalette
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
    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTop
    $plotWidth = $Context.Constants.SvgPlotWidth
    $plotHeight = $Context.Constants.SvgPlotHeight
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'commit_scatter.svg') -ErrorCode 'OUTPUT_COMMIT_SCATTER_WRITTEN')
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
        $hash = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($safe))).Replace('-', '').Substring(0, $Context.Constants.HashTruncateLength).ToLowerInvariant()
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
        if ($null -ne $c.'他者差戻行数')
        {
            $removedByOthers = [double]$c.'他者差戻行数'
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'committer_outcome'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-CommitterOutcomeChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if ($TopNCount -le 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_OUTCOME_SKIPPED_TOPN' -Message 'Write-CommitterOutcomeChart: TopNCount が 0 以下のため、出力しません。')
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_OUTCOME_NO_DATA' -Message 'Write-CommitterOutcomeChart: Committers が空です。')
    }

    $chartData = @(Get-CommitterOutcomeData -Committers $Committers -TopNCount $TopNCount)
    if ($chartData.Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_OUTCOME_NO_PLOTTABLE_DATA' -Message 'Write-CommitterOutcomeChart: 描画対象データがありません。')
    }

    # --- 色定義 ---
    $colorSurvived = $Context.Constants.ColorSurvived
    $colorSelfCancel = $Context.Constants.ColorSelfCancel
    $colorRemovedByOthers = $Context.Constants.ColorRemovedByOthers
    $colorOther = $Context.Constants.ColorOtherDead

    # --- 個人用 SVG（1人分のみ表示） ---
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $chartData)
    {
        $authorDisplay = [string]$row.Author
        $baseName = 'committer_outcome_' + $authorDisplay
        $fileName = Get-SafeFileName -Context $Context -BaseName $baseName -Extension '.svg'
        while (-not $usedNames.Add($fileName))
        {
            $baseName = $baseName + '_dup'
            $fileName = Get-SafeFileName -Context $Context -BaseName $baseName -Extension '.svg'
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'committer_outcome_combined.svg') -ErrorCode 'OUTPUT_COMMITTER_OUTCOME_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'committer_scatter'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-CommitterScatterChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if ($TopNCount -le 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_SCATTER_SKIPPED_TOPN' -Message 'Write-CommitterScatterChart: TopNCount が 0 以下のため、出力しません。')
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_SCATTER_NO_DATA' -Message 'Write-CommitterScatterChart: Committers が空です。')
    }

    $scatterData = @(Get-CommitterScatterData -Committers $Committers -TopNCount $TopNCount)
    if ($scatterData.Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_COMMITTER_SCATTER_NO_PLOTTABLE_DATA' -Message 'Write-CommitterScatterChart: 描画対象データがありません。')
    }

    # 描画定数
    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTop
    $plotWidth = $Context.Constants.SvgPlotWidth
    $plotHeight = $Context.Constants.SvgPlotHeight
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
    $minBubble = $Context.Constants.SvgBubbleMin
    $maxBubble = $Context.Constants.SvgBubbleMax

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
        $fileName = Get-SafeFileName -Context $Context -BaseName $baseName -Extension '.svg'
        while (-not $usedNames.Add($fileName))
        {
            $baseName = $baseName + '_dup'
            $fileName = Get-SafeFileName -Context $Context -BaseName $baseName -Extension '.svg'
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
        for ($tick = 0.0; $tick -le 1.01; $tick += $Context.Constants.SvgQuadrantTickStep)
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
    for ($tick = 0.0; $tick -le 1.01; $tick += $Context.Constants.SvgQuadrantTickStep)
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
    $colorPalette = $Context.Constants.DefaultColorPalette
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'committer_scatter_combined.svg') -ErrorCode 'OUTPUT_COMMITTER_SCATTER_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'team_survived_share.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-SurvivedShareDonutChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_SURVIVED_SHARE_NO_DATA' -Message 'Write-SurvivedShareDonutChart: Committers が空です。')
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_SURVIVED_SHARE_NO_PLOTTABLE_DATA' -Message 'Write-SurvivedShareDonutChart: 生存行データがありません。')
    }
    $sorted = @($data.ToArray() | Sort-Object -Property @{Expression = 'Survived'; Descending = $true }, 'Author')
    $total = ($sorted | Measure-Object -Property Survived -Sum).Sum
    if ($total -le 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_SURVIVED_SHARE_INVALID_TOTAL' -Message 'Write-SurvivedShareDonutChart: 合計生存行数が 0 のためスキップしました。')
    }

    $colorPalette = $Context.Constants.DefaultColorPalette
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'team_survived_share.svg') -ErrorCode 'OUTPUT_SURVIVED_SHARE_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'team_interaction_heatmap.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-TeamInteractionHeatMap' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if ($null -eq $KillMatrix -or $null -eq $AuthorSelfDead)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_HEATMAP_MISSING_MATRIX' -Message 'Write-TeamInteractionHeatMap: KillMatrix または AuthorSelfDead が null のためスキップしました。')
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_HEATMAP_NO_DATA' -Message 'Write-TeamInteractionHeatMap: Committers が空です。')
    }
    $authors = @($Committers | ForEach-Object { Get-NormalizedAuthorName -Author ([string]$_.'作者') } | Sort-Object)
    if ($authors.Count -lt 2)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_HEATMAP_INSUFFICIENT_AUTHORS' -Message 'Write-TeamInteractionHeatMap: 可視化に必要な作者数が不足しています。')
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
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_HEATMAP_ZERO_VALUES' -Message 'Write-TeamInteractionHeatMap: ヒートマップ値が 0 のためスキップしました。')
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

            $textClass = if ($t -gt $Context.Constants.HeatmapLightTextThreshold)
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'team_interaction_heatmap.svg') -ErrorCode 'OUTPUT_TEAM_HEATMAP_WRITTEN')
}

function Get-TeamActivityProfileData
{
    <#
    .SYNOPSIS
        チーム活動プロファイル散布図用のデータを抽出する。
    .DESCRIPTION
        X 軸: 他者コード介入率（他者コード変更行数 / 総チャーン）
        Y 軸: 介入結果生死差分指数（(生存成果行数 - 介入行数) / (生存成果行数 + 介入行数)）
        バブルサイズ: 総チャーン
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
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
        $interventionLines = 0.0
        if ($null -ne $c.'他者コード変更行数')
        {
            $interventionLines = [double]$c.'他者コード変更行数'
        }
        $survivedOutcomeLines = 0.0
        if ($null -ne $c.'他者コード変更生存行数')
        {
            $survivedOutcomeLines = [double]$c.'他者コード変更生存行数'
        }
        $totalChurn = 0.0
        if ($null -ne $c.'総チャーン')
        {
            $totalChurn = [double]$c.'総チャーン'
        }
        if ($totalChurn -le 0.0)
        {
            continue
        }
        $denominator = $survivedOutcomeLines + $interventionLines
        if ($denominator -le 0.0)
        {
            continue
        }
        $authorName = Get-NormalizedAuthorName -Author ([string]$c.'作者')
        $rawInterventionRate = $interventionLines / $totalChurn
        $interventionRate = $rawInterventionRate
        if ($rawInterventionRate -gt 1.0)
        {
            $interventionRate = 1.0
            Write-NarutoDiagnostic -Context $Context -Level 'Warning' -ErrorCode 'OUTPUT_TEAM_ACTIVITY_INTERVENTION_RATE_OVERFLOW' -Message ("Write-TeamActivityProfileChart: '{0}' の介入率が 100% を超過したため 100% に補正しました (raw={1:N4}, intervention={2:N0}, churn={3:N0})。" -f $authorName, $rawInterventionRate, $interventionLines, $totalChurn) -OutputName 'team_activity_profile.svg' -Data @{
                Author = $authorName
                RawInterventionRate = $rawInterventionRate
                InterventionLines = $interventionLines
                TotalChurn = $totalChurn
            }
        }
        $outcomeBalance = ($survivedOutcomeLines - $interventionLines) / $denominator
        [void]$rows.Add([pscustomobject][ordered]@{
                Author = $authorName
                InterventionRate = $interventionRate
                RawInterventionRate = $rawInterventionRate
                OutcomeBalance = $outcomeBalance
                InterventionLines = $interventionLines
                SurvivedOutcomeLines = $survivedOutcomeLines
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
        X 軸に他者コード介入率（他者コード変更行数 / 総チャーン）、
        Y 軸に介入結果生死差分指数（(生存成果行数 - 介入行数) / (生存成果行数 + 介入行数)）
        を取り、バブルサイズに総チャーンを反映した
        散布図を生成する。4 象限の解釈:
        - 左上: 低介入・生存優位
        - 右上: 高介入・生存優位
        - 左下: 低介入・消滅優位
        - 右下: 高介入・消滅優位
    .PARAMETER OutDirectory
        出力先ディレクトリを指定する。
    .PARAMETER Committers
        Get-CommitterMetric が返すコミッター行配列を指定する。
    .PARAMETER EncodingName
        出力時に使用する文字エンコーディングを指定する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'team_activity_profile.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-TeamActivityProfileChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_ACTIVITY_NO_DATA' -Message 'Write-TeamActivityProfileChart: Committers が空です。')
    }

    $profileData = @(Get-TeamActivityProfileData -Context $Context -Committers $Committers)
    if ($profileData.Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_TEAM_ACTIVITY_NO_PLOTTABLE_DATA' -Message 'Write-TeamActivityProfileChart: 描画対象データがありません。')
    }

    # 描画定数
    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTop
    $plotWidth = $Context.Constants.SvgPlotWidth
    $plotHeight = $Context.Constants.SvgPlotHeight
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $midX = $plotLeft + $plotWidth / 2.0
    $midY = $plotTop + $plotHeight / 2.0

    $maxChurn = ($profileData | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = $Context.Constants.SvgBubbleMin
    $maxBubble = $Context.Constants.SvgBubbleMax

    # 象限ラベル
    $quadrants = @(
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.2; Label = '低介入・生存優位' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.2; Label = '高介入・生存優位' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.8; Label = '低介入・消滅優位' }
        [pscustomobject]@{ X = $plotLeft + $plotWidth * 0.75; Y = $plotTop + $plotHeight * 0.8; Label = '高介入・消滅優位' }
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
    [void]$sb.AppendLine('<text class="subtitle" x="20" y="46">X: 他者コード介入率（他者変更行数÷総チャーン） / Y: 介入結果生死差分指数（(生存成果-介入削除)÷(生存成果+介入削除)） / 円: 総チャーン</text>')

    # プロットエリア
    [void]$sb.AppendLine(('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="#fff" stroke="#ddd"/>' -f [int]$plotLeft, [int]$plotTop, [int]$plotWidth, [int]$plotHeight))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{0}" y2="{2}"/>' -f [int]$midX, [int]$plotTop, [int]$plotBottom))
    [void]$sb.AppendLine(('<line class="mid-line" x1="{0}" y1="{1}" x2="{2}" y2="{1}"/>' -f [int]$plotLeft, [int]$midY, [int]$plotRight))
    # 軸ラベル
    [void]$sb.AppendLine(('<text class="axis-label" x="{0}" y="{1}" text-anchor="middle">他者コード介入率</text>' -f [int]($plotLeft + $plotWidth / 2.0), [int]($plotBottom + 36)))
    [void]$sb.AppendLine(('<text class="axis-label" x="16" y="{0}" text-anchor="middle" transform="rotate(-90,16,{0})">介入結果生死差分指数</text>' -f [int]($plotTop + $plotHeight / 2.0)))
    # X 軸目盛り
    for ($tick = 0.0; $tick -le 1.01; $tick += $Context.Constants.SvgQuadrantTickStep)
    {
        $tx = $plotLeft + $tick * $plotWidth
        [void]$sb.AppendLine(('<text class="tick-label" x="{0:F0}" y="{1}" text-anchor="middle">{2:F0}%</text>' -f $tx, [int]($plotBottom + 16), ($tick * 100)))
    }
    # Y 軸目盛り（-100% ～ +100%）
    for ($tick = -1.0; $tick -le 1.01; $tick += 0.5)
    {
        $normalized = ($tick + 1.0) / 2.0
        $ty = $plotBottom - $normalized * $plotHeight
        [void]$sb.AppendLine(('<text class="tick-label" x="{0}" y="{1:F0}" text-anchor="end">{2:F0}%</text>' -f [int]($plotLeft - 6), ($ty + 4), ($tick * 100)))
    }
    # 象限ラベル
    foreach ($q in $quadrants)
    {
        [void]$sb.AppendLine(('<text class="quadrant-label" x="{0:F0}" y="{1:F0}">{2}</text>' -f $q.X, $q.Y, (ConvertTo-SvgEscapedText -Text $q.Label)))
    }
    # 全員のバブル
    $colorPalette = $Context.Constants.DefaultColorPalette
    $sortedByChurn = @($profileData | Sort-Object -Property TotalChurn -Descending)
    for ($ci = 0; $ci -lt $sortedByChurn.Count; $ci++)
    {
        $d = $sortedByChurn[$ci]
        $bx = $plotLeft + ($d.InterventionRate * $plotWidth)
        $outcomeBalanceNormalized = ($d.OutcomeBalance + 1.0) / 2.0
        $outcomeBalanceNormalized = [Math]::Max(0.0, [Math]::Min(1.0, $outcomeBalanceNormalized))
        $by = $plotBottom - $outcomeBalanceNormalized * $plotHeight
        $br = $minBubble + ($maxBubble - $minBubble) * [Math]::Sqrt($d.TotalChurn / $maxChurn)
        $cIdx = $ci % $colorPalette.Count
        $bColor = $colorPalette[$cIdx]
        [void]$sb.AppendLine(('<circle cx="{0:F1}" cy="{1:F1}" r="{2:F1}" fill="{3}" fill-opacity="0.55" stroke="{3}" stroke-width="1.2"><title>{4} (介入率(raw):{5:F1}%, 介入率(描画):{6:F1}%, 生死差分指数:{7:F1}%, 介入行数:{8}, 生存成果行数:{9}, チャーン:{10})</title></circle>' -f $bx, $by, $br, $bColor, (ConvertTo-SvgEscapedText -Text $d.Author), ($d.RawInterventionRate * 100), ($d.InterventionRate * 100), ($d.OutcomeBalance * 100), [int]$d.InterventionLines, [int]$d.SurvivedOutcomeLines, [int]$d.TotalChurn))
        [void]$sb.AppendLine(('<text class="author-label" x="{0:F1}" y="{1:F1}">{2}</text>' -f $bx, ($by - $br - 4.0), (ConvertTo-SvgEscapedText -Text $d.Author)))
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'team_activity_profile.svg') -Content $sb.ToString() -EncodingName $EncodingName
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'team_activity_profile.svg') -ErrorCode 'OUTPUT_TEAM_ACTIVITY_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'project_code_fate.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-ProjectCodeFateChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if (-not $Committers -or @($Committers).Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_PROJECT_FATE_NO_DATA' -Message 'Write-ProjectCodeFateChart: Committers が空です。')
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
        $totalAdded += Get-ObjectNumericPropertyValue -InputObject $c -PropertyName '追加行数'
        $totalSurvived += Get-ObjectNumericPropertyValue -InputObject $c -PropertyName '生存行数'
        $totalSelfCancel += Get-ObjectNumericPropertyValue -InputObject $c -PropertyName '自己相殺行数'
        $totalRemovedByOthers += Get-ObjectNumericPropertyValue -InputObject $c -PropertyName '他者差戻行数'
    }
    if ($totalAdded -le 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_PROJECT_FATE_ZERO_ADDED' -Message 'Write-ProjectCodeFateChart: 追加行数が 0 のためスキップしました。')
    }
    $totalOther = Get-MetricBreakdownResidualValue -Context $Context -MetricName 'CodeFate.OtherDead' -TotalValue $totalAdded -BreakdownValues @($totalSurvived, $totalSelfCancel, $totalRemovedByOthers) -BreakdownLabels @('survived', 'selfCancel', 'removedByOthers')

    $segments = @(
        [pscustomobject]@{ Label = '生存'; Value = $totalSurvived; Color = $Context.Constants.ColorSurvived }
        [pscustomobject]@{ Label = '自己相殺'; Value = $totalSelfCancel; Color = $Context.Constants.ColorSelfCancel }
        [pscustomobject]@{ Label = '被他者削除'; Value = $totalRemovedByOthers; Color = $Context.Constants.ColorRemovedByOthers }
        [pscustomobject]@{ Label = 'その他消滅'; Value = $totalOther; Color = $Context.Constants.ColorOtherDead }
    )
    # 値が 0 のセグメントを除外
    $segments = @($segments | Where-Object { $_.Value -gt 0 })
    if ($segments.Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_PROJECT_FATE_NO_SEGMENTS' -Message 'Write-ProjectCodeFateChart: 出力対象セグメントがありません。')
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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'project_code_fate.svg') -ErrorCode 'OUTPUT_PROJECT_FATE_WRITTEN')
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
        左上 = 意図的改修（効率は高いが最終的な残存率は低い）
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'project_efficiency_quadrant.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-ProjectEfficiencyQuadrantChart' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    $data = @(Get-ProjectEfficiencyData -Files $Files -TopNCount $TopNCount)
    if ($data.Count -eq 0)
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_PROJECT_EFFICIENCY_NO_PLOTTABLE_DATA' -Message 'Write-ProjectEfficiencyQuadrantChart: 有効なファイルデータがありません。')
    }

    $plotLeft = $Context.Constants.SvgPlotLeft
    $plotTop = $Context.Constants.SvgPlotTopLarge
    $plotWidth = $Context.Constants.SvgPlotWidth
    $plotHeight = $Context.Constants.SvgPlotHeight
    $plotRight = $plotLeft + $plotWidth
    $plotBottom = $plotTop + $plotHeight
    $svgW = 600
    $svgH = 560

    $maxChurn = ($data | Measure-Object -Property TotalChurn -Maximum).Maximum
    if ($maxChurn -le 0)
    {
        $maxChurn = 1.0
    }
    $minBubble = $Context.Constants.SvgBubbleMin
    $maxBubble = $Context.Constants.SvgBubbleMax

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
    for ($tick = 0.0; $tick -le 1.01; $tick += $Context.Constants.SvgQuadrantTickStep)
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
        @{ X = $plotLeft + $plotWidth * 0.25; Y = $plotTop + $plotHeight * 0.15; Text = '🔥 意図的改修' }
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
        $labelText = Get-SvgFittedText -Context $Context -Text $shortName -MaxWidth ($r * 3.0) -FontSize 9.0
        if ($labelText)
        {
            [void]$sb.AppendLine(('<text class="file-label" x="{0:F1}" y="{1:F1}"><title>{2}</title>{3}</text>' -f $bx, ($by + $r + 12.0), $tooltipText, (ConvertTo-SvgEscapedText -Text $labelText)))
        }
    }

    [void]$sb.AppendLine('</svg>')
    Write-TextFile -FilePath (Join-Path $OutDirectory 'project_efficiency_quadrant.svg') -Content $sb.ToString() -EncodingName $EncodingName
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'project_efficiency_quadrant.svg') -ErrorCode 'OUTPUT_PROJECT_EFFICIENCY_WRITTEN')
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
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
    $outputName = 'project_summary_dashboard.svg'
    $directoryResult = Initialize-NarutoVisualizationOutputDirectory -Context $Context -OutDirectory $OutDirectory -CallerName 'Write-ProjectSummaryDashboard' -OutputName $outputName
    if (-not (Test-NarutoResultSuccess -Result $directoryResult))
    {
        return $directoryResult
    }
    if ((-not $Committers -or @($Committers).Count -eq 0) -and (-not $CommitRows -or @($CommitRows).Count -eq 0))
    {
        return (New-NarutoVisualizationSkippedResult -Context $Context -Level 'Verbose' -OutputName $outputName -ErrorCode 'OUTPUT_PROJECT_DASHBOARD_NO_DATA' -Message 'Write-ProjectSummaryDashboard: 入力データが空のためスキップしました。')
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
    $cardColors = @($Context.Constants.DefaultColorPalette[0], $Context.Constants.DefaultColorPalette[0], $Context.Constants.DefaultColorPalette[0], $Context.Constants.DefaultColorPalette[1], $Context.Constants.DefaultColorPalette[4], $Context.Constants.DefaultColorPalette[2], $Context.Constants.ColorSurvived, $Context.Constants.ColorChurn, $Context.Constants.DefaultColorPalette[3])

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
    return (New-NarutoResultSuccess -Data (Join-Path $OutDirectory 'project_summary_dashboard.svg') -ErrorCode 'OUTPUT_PROJECT_DASHBOARD_WRITTEN')
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)]
        [char]$Character,
        [Parameter(Mandatory = $false)]
        [double]$FontSize = 12.0
    )

    $size = [Math]::Max(1.0, [double]$FontSize)
    $codePoint = [int]$Character
    $ratio = $Context.Constants.SvgCharWidthDefault
    if ([char]::IsWhiteSpace($Character))
    {
        $ratio = $Context.Constants.SvgCharWidthSpace
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
        $ratio = $Context.Constants.SvgCharWidthCjk
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
        $ratio = $Context.Constants.SvgCharWidthNarrow
    }
    elseif (
        $Character -eq 'W' -or
        $Character -eq 'M' -or
        $Character -eq '@' -or
        $Character -eq '#'
    )
    {
        $ratio = $Context.Constants.SvgCharWidthWide
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
        [Parameter(Mandatory = $true)][hashtable]$Context,
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
        $width += Get-SvgCharacterWidth -Context $Context -Character $character -FontSize $FontSize
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
        [Parameter(Mandatory = $true)][hashtable]$Context,
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

    if ((Measure-SvgTextWidth -Context $Context -Text $Text -FontSize $FontSize) -le $allowedWidth)
    {
        return $Text
    }

    $ellipsisText = $Ellipsis
    if ([string]::IsNullOrWhiteSpace($ellipsisText))
    {
        $ellipsisText = '…'
    }
    $ellipsisWidth = Measure-SvgTextWidth -Context $Context -Text $ellipsisText -FontSize $FontSize
    if ($ellipsisWidth -ge $allowedWidth)
    {
        return $ellipsisText
    }

    $buffer = New-Object 'System.Collections.Generic.List[char]'
    $currentWidth = 0.0
    foreach ($character in $Text.ToCharArray())
    {
        $charWidth = Get-SvgCharacterWidth -Context $Context -Character $character -FontSize $FontSize
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
# region ハッシュテーブルヘルパー
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
function Get-ObjectPropertyValue
{
    <#
    .SYNOPSIS
        オブジェクトからプロパティ値を取得し、未定義時は既定値を返す。
    .PARAMETER InputObject
        プロパティを取得する対象オブジェクト。
    .PARAMETER PropertyName
        取得するプロパティ名。
    .PARAMETER DefaultValue
        プロパティが存在しないか null の場合に返す既定値。
    #>
    [CmdletBinding()]
    param(
        [object]$InputObject,
        [string]$PropertyName,
        $DefaultValue = $null
    )
    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName))
    {
        return $DefaultValue
    }
    if ($InputObject.PSObject.Properties.Match($PropertyName).Count -eq 0)
    {
        return $DefaultValue
    }
    $value = $InputObject.$PropertyName
    if ($null -eq $value)
    {
        return $DefaultValue
    }
    return $value
}
function Get-ObjectNumericPropertyValue
{
    <#
    .SYNOPSIS
        オブジェクトの数値プロパティを安全に double として取得する。
    .PARAMETER InputObject
        プロパティを取得する対象オブジェクト。
    .PARAMETER PropertyName
        取得する数値プロパティ名。
    .PARAMETER DefaultValue
        プロパティが存在しないか変換不可の場合に返す既定値。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [double]$DefaultValue = 0.0
    )
    $rawValue = Get-ObjectPropertyValue -InputObject $InputObject -PropertyName $PropertyName -DefaultValue $null
    if ($null -eq $rawValue)
    {
        return $DefaultValue
    }
    try
    {
        return [double]$rawValue
    }
    catch
    {
        return $DefaultValue
    }
}
function Get-MetricBreakdownResidualValue
{
    <#
    .SYNOPSIS
        合計値と内訳値から残余値を計算し不整合を診断する。
    .PARAMETER Context
        NarutoContext ハッシュテーブル。指定時は Write-NarutoDiagnostic で構造化診断を記録する。
    .PARAMETER MetricName
        診断メッセージに使用するメトリクス名。
    .PARAMETER TotalValue
        全体の合計値。
    .PARAMETER BreakdownValues
        内訳の数値配列。
    .PARAMETER BreakdownLabels
        内訳ラベルの文字列配列（診断メッセージ用）。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $false)][hashtable]$Context,
        [string]$MetricName,
        [double]$TotalValue,
        [double[]]$BreakdownValues,
        [string[]]$BreakdownLabels
    )
    $sumBreakdown = 0.0
    foreach ($value in @($BreakdownValues))
    {
        $sumBreakdown += [double]$value
    }
    $residual = $TotalValue - $sumBreakdown
    if ($residual -lt 0)
    {
        $detailParts = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0
            $i -lt $BreakdownValues.Count
            $i++)
        {
            $label = if ($i -lt $BreakdownLabels.Count)
            {
                [string]$BreakdownLabels[$i]
            }
            else
            {
                "breakdown[{0}]" -f $i
            }
            [void]$detailParts.Add(("{0}={1}" -f $label, [double]$BreakdownValues[$i]))
        }
        $diagMessage = "Metric breakdown exceeded total: metric={0}, total={1}, {2}" -f $MetricName, $TotalValue, ($detailParts.ToArray() -join ', ')
        if ($null -ne $Context)
        {
            Write-NarutoDiagnostic -Context $Context -Level 'Warning' -ErrorCode 'OUTPUT_METRIC_BREAKDOWN_OVERFLOW' -Message $diagMessage -Data @{
                MetricName = $MetricName
                TotalValue = $TotalValue
                SumBreakdown = $sumBreakdown
                Residual = $residual
            }
        }
        else
        {
            Write-Warning $diagMessage
        }
        return 0.0
    }
    return $residual
}
# endregion ハッシュテーブルヘルパー
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
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    try
    {
        $versionText = (Invoke-SvnCommand -Context $Context -Arguments @('--version', '--quiet') -ErrorContext 'svn version').Split("`n")[0].Trim()
        if ([string]::IsNullOrWhiteSpace($versionText))
        {
            return (New-NarutoResultSkipped -ErrorCode 'SVN_VERSION_UNAVAILABLE' -Message 'svn version の取得結果が空のためスキップしました。')
        }
        return (New-NarutoResultSuccess -Data $versionText -ErrorCode 'SVN_VERSION_READY')
    }
    catch
    {
        return (New-NarutoResultSkipped -ErrorCode 'SVN_VERSION_UNAVAILABLE' -Message ("svn version の取得に失敗しました: {0}" -f $_.Exception.Message))
    }
}
function Get-SvnDiffArgumentList
{
    <#
    .SYNOPSIS
        差分取得オプションから svn diff 引数配列を構築する。
    .PARAMETER IgnoreWhitespace
        指定時は空白・改行コード差分を無視する。
    .PARAMETER ExcludeCommentOnlyLines
        指定時はコメント専用行を全メトリクス集計から除外する。
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
    param([Parameter(Mandatory = $true)][hashtable]$Context, [string]$CacheDir, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
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
    $diffText = Invoke-SvnCommand -Context $Context -Arguments $fetchArgs.ToArray() -ErrorContext ("svn diff -c {0}" -f $Revision)
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
    $appliedInPlace = $false
    if ($targetValue -is [System.Collections.IList])
    {
        $isFixedSize = $false
        if ($targetValue -is [System.Array])
        {
            $isFixedSize = $true
        }
        elseif ($targetValue.PSObject.Properties.Match('IsFixedSize').Count -gt 0)
        {
            $isFixedSize = [bool]$targetValue.IsFixedSize
        }

        if (-not $isFixedSize)
        {
            $targetValue.Clear()
            foreach ($item in $sourceItems.ToArray())
            {
                [void]$targetValue.Add($item)
            }
            $appliedInPlace = $true
        }
    }
    if (-not $appliedInPlace)
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
    $clearedInPlace = $false
    if ($targetValue -is [System.Collections.IList])
    {
        $isFixedSize = $false
        if ($targetValue -is [System.Array])
        {
            $isFixedSize = $true
        }
        elseif ($targetValue.PSObject.Properties.Match('IsFixedSize').Count -gt 0)
        {
            $isFixedSize = [bool]$targetValue.IsFixedSize
        }

        if (-not $isFixedSize)
        {
            $targetValue.Clear()
            $clearedInPlace = $true
        }
    }
    if (-not $clearedInPlace)
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
function Get-RenameCorrectionCandidates
{
    <#
    .SYNOPSIS
        リネーム差分補正の対象ペアを抽出する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object]$Commit,
        [int]$Revision
    )
    $deletedSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        if (([string]$pathEntry.Action).ToUpperInvariant() -eq 'D')
        {
            [void]$deletedSet.Add((ConvertTo-PathKey -Path ([string]$pathEntry.Path)))
        }
    }
    $candidates = New-Object 'System.Collections.Generic.List[object]'
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
        [void]$candidates.Add([pscustomobject]@{
                OldPath = $oldPath
                NewPath = $newPath
                CopyRevision = [int]$copyRev
            })
    }
    return @($candidates.ToArray())
}
function Get-RenamePairRealDiffStat
{
    <#
    .SYNOPSIS
        リネーム前後ペアの実差分を取得して DiffStat として返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$TargetUrl,
        [string]$CacheDir = '',
        [string[]]$DiffArguments,
        [string]$OldPath,
        [string]$NewPath,
        [int]$CopyRevision,
        [int]$Revision
    )
    $compareArguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($DiffArguments))
    {
        [void]$compareArguments.Add([string]$item)
    }
    [void]$compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $OldPath + '@' + [string]$CopyRevision))
    [void]$compareArguments.Add(($TargetUrl.TrimEnd('/') + '/' + $NewPath + '@' + [string]$Revision))
    $realDiff = Invoke-SvnCommand -Context $Context -Arguments $compareArguments.ToArray() -ErrorContext ("svn diff rename pair r{0} {1}->{2}" -f $Revision, $OldPath, $NewPath)
    $excludeCommentOnlyLines = Get-ContextRuntimeSwitchValue -Context $Context -PropertyName 'ExcludeCommentOnlyLines'
    $lineMaskByPath = @{}
    if ($excludeCommentOnlyLines)
    {
        $oldMask = $null
        $newMask = $null
        $oldProfile = Get-CommentSyntaxProfileByPath -Context $Context -FilePath $OldPath
        if ($null -ne $oldProfile)
        {
            $oldCat = Get-CachedOrFetchCatText -Context $Context -Repo $TargetUrl -FilePath $OldPath -Revision $CopyRevision -CacheDir $CacheDir
            if ($null -ne $oldCat)
            {
                $oldMask = ConvertTo-CommentOnlyLineMask -Lines (ConvertTo-TextLine -Text $oldCat) -CommentSyntaxProfile $oldProfile
            }
        }
        $newProfile = Get-CommentSyntaxProfileByPath -Context $Context -FilePath $NewPath
        if ($null -ne $newProfile)
        {
            $newCat = Get-CachedOrFetchCatText -Context $Context -Repo $TargetUrl -FilePath $NewPath -Revision $Revision -CacheDir $CacheDir
            if ($null -ne $newCat)
            {
                $newMask = ConvertTo-CommentOnlyLineMask -Lines (ConvertTo-TextLine -Text $newCat) -CommentSyntaxProfile $newProfile
            }
        }
        if ($null -ne $oldMask -or $null -ne $newMask)
        {
            $maskEntry = [pscustomobject]@{
                OldMask = $oldMask
                NewMask = $newMask
            }
            $lineMaskByPath[$OldPath] = $maskEntry
            $lineMaskByPath[$NewPath] = $maskEntry
        }
    }
    $realParsed = ConvertFrom-SvnUnifiedDiff -Context $Context -DiffText $realDiff -DetailLevel 2 -ExcludeCommentOnlyLines:$excludeCommentOnlyLines -LineMaskByPath $lineMaskByPath

    $realStat = $null
    if ($realParsed.ContainsKey($NewPath))
    {
        $realStat = $realParsed[$NewPath]
    }
    elseif ($realParsed.ContainsKey($OldPath))
    {
        $realStat = $realParsed[$OldPath]
    }
    elseif ($realParsed.Keys.Count -gt 0)
    {
        $firstKey = @($realParsed.Keys | Sort-Object | Select-Object -First 1)[0]
        $realStat = $realParsed[$firstKey]
    }
    if ($null -eq $realStat)
    {
        return [pscustomobject]@{
            AddedLines = 0
            DeletedLines = 0
            Hunks = @()
            IsBinary = $false
            AddedLineHashes = @()
            DeletedLineHashes = @()
        }
    }
    return $realStat
}
function Set-RenamePairDiffStatCorrection
{
    <#
    .SYNOPSIS
        リネーム補正で得た実差分をコミット差分統計へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object]$Commit,
        [string]$OldPath,
        [string]$NewPath,
        [object]$RealStat
    )
    $newStat = $Commit.FileDiffStats[$NewPath]
    $oldStat = $Commit.FileDiffStats[$OldPath]
    Set-DiffStatFromSource -TargetStat $newStat -SourceStat $RealStat
    Reset-DiffStatForRemovedPath -DiffStat $oldStat
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
    param([Parameter(Mandatory = $true)][hashtable]$Context, [object]$Commit, [int]$Revision, [string]$TargetUrl, [string]$CacheDir = '', [string[]]$DiffArguments)
    $candidates = @(Get-RenameCorrectionCandidates -Commit $Commit -Revision $Revision)
    foreach ($candidate in $candidates)
    {
        $realStat = Get-RenamePairRealDiffStat -Context $Context -TargetUrl $TargetUrl -CacheDir $CacheDir -DiffArguments $DiffArguments -OldPath ([string]$candidate.OldPath) -NewPath ([string]$candidate.NewPath) -CopyRevision ([int]$candidate.CopyRevision) -Revision $Revision
        Set-RenamePairDiffStatCorrection -Commit $Commit -OldPath ([string]$candidate.OldPath) -NewPath ([string]$candidate.NewPath) -RealStat $realStat
    }
}
function Get-CommitDerivedChurnValues
{
    <#
    .SYNOPSIS
        コミットの追加・削除・チャーン・エントロピー計算に必要な値を返す。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object])]
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
    return [pscustomobject]@{
        Added = [int]$added
        Deleted = [int]$deleted
        Churn = [int]($added + $deleted)
        Entropy = [double](Get-Entropy -Values @($churnPerFile | ForEach-Object { [double]$_ }))
    }
}
function Get-CommitMessageSummary
{
    <#
    .SYNOPSIS
        コミットメッセージを1行短縮形式へ正規化する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Message
    )
    $normalized = [string]$Message
    if ($null -eq $normalized)
    {
        $normalized = ''
    }
    $oneLineMessage = ($normalized -replace '(\r?\n)+', ' ').Trim()
    if ($oneLineMessage.Length -gt $Context.Constants.CommitMessageMaxLength)
    {
        $oneLineMessage = $oneLineMessage.Substring(0, $Context.Constants.CommitMessageMaxLength) + '...'
    }
    return [pscustomobject]@{
        Length = [int]$normalized.Length
        Short = $oneLineMessage
    }
}
function Set-ObjectPropertyValue
{
    <#
    .SYNOPSIS
        オブジェクトのプロパティを存在有無に応じて設定または追加する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object]$InputObject,
        [string]$PropertyName,
        $Value
    )
    if ($InputObject.PSObject.Properties.Match($PropertyName).Count -gt 0)
    {
        $InputObject.$PropertyName = $Value
        return
    }
    Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $PropertyName -Value $Value -Force
}
function Set-CommitDerivedMetric
{
    <#
    .SYNOPSIS
        コミット単位の派生指標と短縮メッセージを設定する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param( [Parameter(Mandatory = $true)][hashtable]$Context, [object]$Commit)
    $churnValues = Get-CommitDerivedChurnValues -Commit $Commit
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'AddedLines' -Value ([int]$churnValues.Added)
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'DeletedLines' -Value ([int]$churnValues.Deleted)
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'Churn' -Value ([int]$churnValues.Churn)
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'Entropy' -Value ([double]$churnValues.Entropy)

    $messageSummary = Get-CommitMessageSummary -Context $Context -Message ([string]$Commit.Message
    )
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'MsgLen' -Value ([int]$messageSummary.Length)
    Set-ObjectPropertyValue -InputObject $Commit -PropertyName 'MessageShort' -Value ([string]$messageSummary.Short)
}
function New-CommitDiffPrefetchPlan
{
    <#
    .SYNOPSIS
        コミット差分取得の事前計画を構築する。
    .PARAMETER LogPathPrefix
        svn log パスのリポジトリ相対プレフィックス。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [object[]]$Commits,
        [string]$CacheDir,
        [string]$TargetUrl,
        [string[]]$DiffArguments,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePathPatterns,
        [string[]]$ExcludePathPatterns,
        [string]$LogPathPrefix,
        [switch]$ExcludeCommentOnlyLines
    )
    $revToAuthor = @{}
    $phaseAItems = [System.Collections.Generic.List[object]]::new()
    foreach ($commit in @($Commits))
    {
        $revision = [int]$commit.Revision
        $revToAuthor[$revision] = [string]$commit.Author
        # ChangedPaths のパスからプレフィックスを除去してからフィルタリングする
        $normalizedChangedPaths = New-Object 'System.Collections.Generic.List[object]'
        foreach ($pathEntry in @($commit.ChangedPaths))
        {
            if ($null -eq $pathEntry)
            {
                continue
            }
            $normalizedPath = ConvertTo-DiffRelativePath -Path (ConvertTo-PathKey -Path ([string]$pathEntry.Path)) -LogPathPrefix $LogPathPrefix
            $normalizedCopyFrom = [string]$pathEntry.CopyFromPath
            if ($normalizedCopyFrom)
            {
                $normalizedCopyFrom = ConvertTo-DiffRelativePath -Path (ConvertTo-PathKey -Path $normalizedCopyFrom) -LogPathPrefix $LogPathPrefix
            }
            [void]$normalizedChangedPaths.Add([pscustomobject]@{
                    Path = $normalizedPath
                    Action = [string]$pathEntry.Action
                    CopyFromPath = $normalizedCopyFrom
                    CopyFromRev = $pathEntry.CopyFromRev
                    IsDirectory = if ($pathEntry.PSObject.Properties.Match('IsDirectory').Count -gt 0)
                    {
                        [bool]$pathEntry.IsDirectory
                    }
                    else
                    {
                        $false
                    }
                })
        }
        $filteredChangedPaths = @(Get-FilteredChangedPathEntry -ChangedPaths @($normalizedChangedPaths.ToArray()) -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
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
                ChangedPaths = @($filteredChangedPaths)
                ExcludeCommentOnlyLines = [bool]$ExcludeCommentOnlyLines
            })
    }
    return [pscustomobject]@{
        RevToAuthor = $revToAuthor
        PrefetchItems = @($phaseAItems.ToArray())
    }
}
function Invoke-CommitDiffPrefetch
{
    <#
    .SYNOPSIS
        差分取得計画に基づいて raw diff を取得する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$PrefetchItems,
        [int]$Parallel = 1
    )
    $phaseAResults = @()
    if (@($PrefetchItems).Count -gt 0)
    {
        $phaseAWorker = {
            param($Item, $Index)
            [void]$Index # Required by Invoke-ParallelWork contract
            # $Context は Invoke-ParallelWork の SessionVariables 経由で注入される
            $diffText = Get-CachedOrFetchDiffText -Context $Context -CacheDir $Item.CacheDir -Revision ([int]$Item.Revision) -TargetUrl $Item.TargetUrl -DiffArguments @($Item.DiffArguments)
            $lineMaskByPath = @{}
            if ([bool]$Item.ExcludeCommentOnlyLines)
            {
                $targetPathSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($pathEntry in @($Item.ChangedPaths))
                {
                    if ($null -eq $pathEntry)
                    {
                        continue
                    }
                    $targetPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
                    if (-not [string]::IsNullOrWhiteSpace($targetPath))
                    {
                        [void]$targetPathSet.Add($targetPath)
                    }
                }

                $commentMaskCache = @{}
                $getCommentMask = {
                    param(
                        [string]$FilePath,
                        [object]$Revision
                    )
                    if ([string]::IsNullOrWhiteSpace($FilePath) -or $null -eq $Revision)
                    {
                        return $null
                    }
                    $normalizedPath = ConvertTo-PathKey -Path $FilePath
                    if ([string]::IsNullOrWhiteSpace($normalizedPath))
                    {
                        return $null
                    }
                    $normalizedRevision = $null
                    try
                    {
                        $normalizedRevision = [int]$Revision
                    }
                    catch
                    {
                        return $null
                    }
                    if ($normalizedRevision -le 0)
                    {
                        return $null
                    }

                    $cacheKey = [string]$normalizedRevision + [char]31 + $normalizedPath
                    if ($commentMaskCache.ContainsKey($cacheKey))
                    {
                        return $commentMaskCache[$cacheKey]
                    }

                    $commentProfile = Get-CommentSyntaxProfileByPath -Context $Context -FilePath $normalizedPath
                    if ($null -eq $commentProfile)
                    {
                        $commentMaskCache[$cacheKey] = $null
                        return $null
                    }
                    $catText = Get-CachedOrFetchCatText -Context $Context -Repo $Item.TargetUrl -FilePath $normalizedPath -Revision $normalizedRevision -CacheDir $Item.CacheDir
                    if ($null -eq $catText)
                    {
                        $commentMaskCache[$cacheKey] = $null
                        return $null
                    }
                    $contentLines = ConvertTo-TextLine -Text $catText
                    $commentMask = ConvertTo-CommentOnlyLineMask -Lines $contentLines -CommentSyntaxProfile $commentProfile
                    $commentMaskCache[$cacheKey] = $commentMask
                    return $commentMask
                }

                $diffSections = @(Get-SvnUnifiedDiffHeaderSectionList -DiffText $diffText)
                foreach ($section in $diffSections)
                {
                    if ($null -eq $section)
                    {
                        continue
                    }
                    $indexPath = ConvertTo-PathKey -Path ([string]$section.IndexPath)
                    if ([string]::IsNullOrWhiteSpace($indexPath))
                    {
                        continue
                    }
                    if ($targetPathSet.Count -gt 0 -and -not $targetPathSet.Contains($indexPath))
                    {
                        continue
                    }
                    $oldMask = & $getCommentMask -FilePath ([string]$section.OldPath) -Revision $section.OldRevision
                    $newMask = & $getCommentMask -FilePath ([string]$section.NewPath) -Revision $section.NewRevision
                    if ($null -ne $oldMask -or $null -ne $newMask)
                    {
                        $lineMaskByPath[$indexPath] = [pscustomobject]@{
                            OldMask = $oldMask
                            NewMask = $newMask
                        }
                    }
                }

                # ヘッダー欠落時の後方互換フォールバック
                foreach ($pathEntry in @($Item.ChangedPaths))
                {
                    if ($null -eq $pathEntry)
                    {
                        continue
                    }
                    $diffPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
                    if ([string]::IsNullOrWhiteSpace($diffPath) -or $lineMaskByPath.ContainsKey($diffPath))
                    {
                        continue
                    }
                    $action = ([string]$pathEntry.Action).ToUpperInvariant()
                    $copyFromPath = ConvertTo-PathKey -Path ([string]$pathEntry.CopyFromPath)
                    $copyFromRevision = $null
                    if ($pathEntry.PSObject.Properties.Match('CopyFromRev').Count -gt 0 -and $null -ne $pathEntry.CopyFromRev)
                    {
                        try
                        {
                            $copyFromRevision = [int]$pathEntry.CopyFromRev
                        }
                        catch
                        {
                            $copyFromRevision = $null
                        }
                    }

                    $oldPath = $null
                    $oldRevision = $null
                    $newPath = $null
                    $newRevision = $null
                    switch ($action)
                    {
                        'A'
                        {
                            $newPath = $diffPath
                            $newRevision = [int]$Item.Revision
                            if (-not [string]::IsNullOrWhiteSpace($copyFromPath))
                            {
                                $oldPath = $copyFromPath
                                if ($null -ne $copyFromRevision -and $copyFromRevision -gt 0)
                                {
                                    $oldRevision = [int]$copyFromRevision
                                }
                                elseif ([int]$Item.Revision -gt 1)
                                {
                                    $oldRevision = [int]$Item.Revision - 1
                                }
                            }
                        }
                        'R'
                        {
                            $newPath = $diffPath
                            $newRevision = [int]$Item.Revision
                            if (-not [string]::IsNullOrWhiteSpace($copyFromPath))
                            {
                                $oldPath = $copyFromPath
                                if ($null -ne $copyFromRevision -and $copyFromRevision -gt 0)
                                {
                                    $oldRevision = [int]$copyFromRevision
                                }
                                elseif ([int]$Item.Revision -gt 1)
                                {
                                    $oldRevision = [int]$Item.Revision - 1
                                }
                            }
                            elseif ([int]$Item.Revision -gt 1)
                            {
                                # Replace は既存パスの上書きのため、コピー元が未指定でも旧版が存在する
                                $oldPath = $diffPath
                                $oldRevision = [int]$Item.Revision - 1
                            }
                        }
                        'D'
                        {
                            if ([int]$Item.Revision -gt 1)
                            {
                                $oldPath = $diffPath
                                $oldRevision = [int]$Item.Revision - 1
                            }
                        }
                        default
                        {
                            if ([int]$Item.Revision -gt 1)
                            {
                                $oldPath = $diffPath
                                $oldRevision = [int]$Item.Revision - 1
                            }
                            $newPath = $diffPath
                            $newRevision = [int]$Item.Revision
                        }
                    }

                    $oldMask = & $getCommentMask -FilePath $oldPath -Revision $oldRevision
                    $newMask = & $getCommentMask -FilePath $newPath -Revision $newRevision
                    if ($null -ne $oldMask -or $null -ne $newMask)
                    {
                        $lineMaskByPath[$diffPath] = [pscustomobject]@{
                            OldMask = $oldMask
                            NewMask = $newMask
                        }
                    }
                }
            }
            $rawDiffByPath = ConvertFrom-SvnUnifiedDiff -Context $Context -DiffText $diffText -DetailLevel 2 -ExcludeCommentOnlyLines:$([bool]$Item.ExcludeCommentOnlyLines) -LineMaskByPath $lineMaskByPath
            [pscustomobject]@{
                Revision = [int]$Item.Revision
                RawDiffByPath = $rawDiffByPath
            }
        }
        $phaseAResults = @(Invoke-ParallelWork -InputItems @($PrefetchItems) -WorkerScript $phaseAWorker -MaxParallel $Parallel -RequiredFunctions @(
                $Context.Constants.RunspaceSvnCoreFunctions +
                $Context.Constants.RunspaceDiffParserFunctions +
                $Context.Constants.RunspaceBlameCacheFunctions +
                $Context.Constants.RunspaceCommentFilterFunctions +
                @(
                    'Get-CachedOrFetchDiffText'
                )
            ) -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $Context)
                SvnExecutable = $Context.Runtime.SvnExecutable
                SvnGlobalArguments = @($Context.Runtime.SvnGlobalArguments)
            } -ErrorContext 'commit diff prefetch')
    }
    $rawDiffByRevision = @{}
    foreach ($result in @($phaseAResults))
    {
        $rawDiffByRevision[[int]$result.Revision] = $result.RawDiffByPath
    }
    return $rawDiffByRevision
}
function Merge-CommitDiffForCommit
{
    <#
    .SYNOPSIS
        1コミット分の raw diff とログ変更パスを突き合わせる。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [object]$Commit,
        [hashtable]$RawDiffByRevision,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePathPatterns,
        [string[]]$ExcludePathPatterns,
        [string]$LogPathPrefix
    )
    $revision = [int]$Commit.Revision
    $rawDiffByPath = @{}
    if ($RawDiffByRevision.ContainsKey($revision))
    {
        $rawDiffByPath = $RawDiffByRevision[$revision]
    }
    $filteredDiffByPath = @{}
    foreach ($path in $rawDiffByPath.Keys)
    {
        if (Test-ShouldCountFile -FilePath $path -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns)
        {
            $filteredDiffByPath[$path] = $rawDiffByPath[$path]
        }
    }
    $Commit.FileDiffStats = $filteredDiffByPath

    if ($null -eq $Commit.ChangedPathsFiltered)
    {
        $Commit.ChangedPathsFiltered = Get-FilteredChangedPathEntry -ChangedPaths @($Commit.ChangedPaths) -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns
    }

    $allowedFilePathSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $logToDiffPathMap = @{}
    foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
    {
        $logPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
        if ($logPath)
        {
            $diffPath = ConvertTo-DiffRelativePath -Path $logPath -LogPathPrefix $LogPathPrefix
            [void]$allowedFilePathSet.Add($diffPath)
            $logToDiffPathMap[$logPath] = $diffPath
        }
    }

    $filteredByLog = @{}
    foreach ($path in $Commit.FileDiffStats.Keys)
    {
        if ($allowedFilePathSet.Contains([string]$path))
        {
            $filteredByLog[$path] = $Commit.FileDiffStats[$path]
        }
    }
    $Commit.FileDiffStats = $filteredByLog
    $Commit.FilesChanged = @($Commit.FileDiffStats.Keys | Sort-Object)

    # ChangedPathsFiltered のパスも diff 相対パスに統一する
    if ($LogPathPrefix)
    {
        $normalizedEntries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($pathEntry in @($Commit.ChangedPathsFiltered))
        {
            $logPath = ConvertTo-PathKey -Path ([string]$pathEntry.Path)
            $diffPath = $logPath
            if ($logToDiffPathMap.ContainsKey($logPath))
            {
                $diffPath = $logToDiffPathMap[$logPath]
            }
            $copyFromPath = [string]$pathEntry.CopyFromPath
            if ($copyFromPath)
            {
                $copyFromPath = ConvertTo-DiffRelativePath -Path (ConvertTo-PathKey -Path $copyFromPath) -LogPathPrefix $LogPathPrefix
            }
            [void]$normalizedEntries.Add([pscustomobject]@{
                    Path = $diffPath
                    Action = [string]$pathEntry.Action
                    CopyFromPath = $copyFromPath
                    CopyFromRev = $pathEntry.CopyFromRev
                    IsDirectory = $false
                })
        }
        $Commit.ChangedPathsFiltered = $normalizedEntries.ToArray()
    }
}
function Complete-CommitDiffForCommit
{
    <#
    .SYNOPSIS
        1コミット分の差分統計を最終化する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$Commit,
        [int]$Revision,
        [string]$TargetUrl,
        [string]$CacheDir = '',
        [string[]]$DiffArguments
    )
    Update-RenamePairDiffStat -Context $Context -Commit $Commit -Revision $Revision -TargetUrl $TargetUrl -CacheDir $CacheDir -DiffArguments $DiffArguments
    Set-CommitDerivedMetric -Context $Context -Commit $Commit
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
    .PARAMETER LogPathPrefix
        svn log パスのリポジトリ相対プレフィックス。
    .PARAMETER Parallel
        並列実行時の最大ワーカー数を指定する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [string]$CacheDir,
        [string]$TargetUrl,
        [string[]]$DiffArguments,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePathPatterns,
        [string[]]$ExcludePathPatterns,
        [string]$LogPathPrefix,
        [switch]$ExcludeCommentOnlyLines,
        [int]$Parallel = 1
    )
    $prefetchPlan = New-CommitDiffPrefetchPlan -Commits $Commits -CacheDir $CacheDir -TargetUrl $TargetUrl -DiffArguments $DiffArguments -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns -LogPathPrefix $LogPathPrefix -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines
    $rawDiffByRevision = Invoke-CommitDiffPrefetch -Context $Context -PrefetchItems $prefetchPlan.PrefetchItems -Parallel $Parallel

    $commitTotal = @($Commits).Count
    $commitIdx = 0
    foreach ($commit in @($Commits))
    {
        $pct = [Math]::Min(100, [int](($commitIdx / [Math]::Max(1, $commitTotal)) * 100))
        Write-Progress -Id 2 -Activity 'コミット差分の統合' -Status ('{0}/{1}' -f ($commitIdx + 1), $commitTotal) -PercentComplete $pct
        $revision = [int]$commit.Revision
        Merge-CommitDiffForCommit -Commit $commit -RawDiffByRevision $rawDiffByRevision -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePathPatterns -ExcludePathPatterns $ExcludePathPatterns -LogPathPrefix $LogPathPrefix
        Complete-CommitDiffForCommit -Context $Context -Commit $commit -Revision $revision -TargetUrl $TargetUrl -CacheDir $CacheDir -DiffArguments $DiffArguments
        $commitIdx++
    }
    Write-Progress -Id 2 -Activity 'コミット差分の統合' -Completed
    return $prefetchPlan.RevToAuthor
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
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits
    )
    [void]$Context
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
function Add-StrictOwnershipBlameSummary
{
    <#
    .SYNOPSIS
        所有権 blame 1件を集計ハッシュへ反映する。
    #>
    [CmdletBinding()]
    param(
        [hashtable]$BlameByFile,
        [hashtable]$AuthorOwned,
        [ref]$OwnedTotal,
        [string]$FilePath,
        [object]$Blame
    )
    $BlameByFile[$FilePath] = $Blame
    $OwnedTotal.Value += [int]$Blame.LineCountTotal
    foreach ($author in $Blame.LineCountByAuthor.Keys)
    {
        Add-Count -Table $AuthorOwned -Key ([string]$author) -Delta ([int]$Blame.LineCountByAuthor[$author])
    }
}
function Get-StrictOwnershipAggregate
{
    <#
    .SYNOPSIS
        Strict 所有権 blame の取得と集計を実行する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$TargetUrl,
        [int]$ToRevision,
        [string]$CacheDir,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [int]$Parallel = 1
    )
    $ownershipTargets = @(Get-AllRepositoryFile -Context $Context -TargetUrl $TargetUrl -Revision $ToRevision -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePathPatterns $IncludePaths -ExcludePathPatterns $ExcludePaths)
    $existingFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($file in $ownershipTargets)
    {
        [void]$existingFileSet.Add([string]$file)
    }

    $authorOwned = @{}
    $ownedTotal = 0
    $blameByFile = @{}
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
                $blameResult = Get-SvnBlameSummary -Context $Context -Repo $TargetUrl -FilePath $file -ToRevision $ToRevision -CacheDir $CacheDir
                $blameResult = ConvertTo-NarutoResultAdapter -InputObject $blameResult -SuccessCode 'SVN_BLAME_SUMMARY_READY' -SkippedCode 'SVN_BLAME_SUMMARY_EMPTY'
                if (-not (Test-NarutoResultSuccess -Result $blameResult))
                {
                    Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_OWNERSHIP_BLAME_SKIPPED' -Message ("Strict ownership blame was skipped for '{0}' at r{1}: {2}" -f [string]$file, [int]$ToRevision, [string]$blameResult.Message) -Context @{
                        FilePath = [string]$file
                        Revision = [int]$ToRevision
                        ErrorCode = [string]$blameResult.ErrorCode
                    }
                }
            }
            catch
            {
                Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_OWNERSHIP_BLAME_FAILED' -Message ("Strict ownership blame failed for '{0}' at r{1}: {2}" -f [string]$file, [int]$ToRevision, $_.Exception.Message) -Context @{
                    FilePath = [string]$file
                    Revision = [int]$ToRevision
                } -InnerException $_.Exception
            }
            Add-StrictOwnershipBlameSummary -BlameByFile $blameByFile -AuthorOwned $authorOwned -OwnedTotal ([ref]$ownedTotal) -FilePath ([string]$file) -Blame $blameResult.Data
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
                $blameResult = Get-SvnBlameSummary -Context $Context -Repo $Item.TargetUrl -FilePath ([string]$Item.FilePath) -ToRevision ([int]$Item.ToRevision) -CacheDir $Item.CacheDir
                $blameResult = ConvertTo-NarutoResultAdapter -InputObject $blameResult -SuccessCode 'SVN_BLAME_SUMMARY_READY' -SkippedCode 'SVN_BLAME_SUMMARY_EMPTY'
                if (-not (Test-NarutoResultSuccess -Result $blameResult))
                {
                    Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_OWNERSHIP_BLAME_SKIPPED' -Message ("Strict ownership blame was skipped for '{0}' at r{1}: {2}" -f [string]$Item.FilePath, [int]$Item.ToRevision, [string]$blameResult.Message) -Context @{
                        FilePath = [string]$Item.FilePath
                        Revision = [int]$Item.ToRevision
                        ErrorCode = [string]$blameResult.ErrorCode
                    }
                }
                [pscustomobject]@{
                    FilePath = [string]$Item.FilePath
                    Blame = $blameResult.Data
                }
            }
            catch
            {
                Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_OWNERSHIP_BLAME_FAILED' -Message ("Strict ownership blame failed for '{0}' at r{1}: {2}" -f [string]$Item.FilePath, [int]$Item.ToRevision, $_.Exception.Message) -Context @{
                    FilePath = [string]$Item.FilePath
                    Revision = [int]$Item.ToRevision
                } -InnerException $_.Exception
            }
        }
        $ownershipResults = @(Invoke-ParallelWork -InputItems $ownershipItems.ToArray() -WorkerScript $ownershipWorker -MaxParallel $Parallel -RequiredFunctions @(
                $Context.Constants.RunspaceSvnCoreFunctions +
                $Context.Constants.RunspaceBlameCacheFunctions +
                $Context.Constants.RunspaceCommentFilterFunctions +
                @(
                    'ConvertFrom-SvnXmlText',
                    'ConvertFrom-SvnBlameXml',
                    'Get-BlameMemoryCacheKey',
                    'Get-SvnBlameSummary'
                )
            ) -SessionVariables @{
                Context = (Get-RunspaceNarutoContext -Context $Context)
                SvnExecutable = $Context.Runtime.SvnExecutable
                SvnGlobalArguments = @($Context.Runtime.SvnGlobalArguments)
            } -ErrorContext 'strict ownership blame')

        foreach ($entry in @($ownershipResults))
        {
            $file = [string]$entry.FilePath
            $blame = $entry.Blame
            Add-StrictOwnershipBlameSummary -BlameByFile $blameByFile -AuthorOwned $authorOwned -OwnedTotal ([ref]$ownedTotal) -FilePath $file -Blame $blame
        }
    }

    return [pscustomobject]@{
        OwnershipTargets = $ownershipTargets
        ExistingFileSet = $existingFileSet
        BlameByFile = $blameByFile
        AuthorOwned = $authorOwned
        OwnedTotal = [int]$ownedTotal
    }
}
function Get-StrictFileBlameWithFallback
{
    <#
    .SYNOPSIS
        Strict files 行更新向けに候補順フォールバックで blame を取得する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$MetricKey,
        [string]$FilePath,
        [string]$ResolvedFilePath,
        [System.Collections.Generic.HashSet[string]]$ExistingFileSet,
        [hashtable]$BlameByFile,
        [string]$TargetUrl,
        [int]$ToRevision,
        [string]$CacheDir
    )
    $blame = $null
    $existsAtToRevision = $false
    if ($MetricKey)
    {
        $existsAtToRevision = $ExistingFileSet.Contains([string]$MetricKey)
    }
    $lookupCandidates = if ($existsAtToRevision)
    {
        @($MetricKey, $FilePath, $ResolvedFilePath)
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
            $tmpBlameResult = Get-SvnBlameSummary -Context $Context -Repo $TargetUrl -FilePath $lookup -ToRevision $ToRevision -CacheDir $CacheDir
            $tmpBlameResult = ConvertTo-NarutoResultAdapter -InputObject $tmpBlameResult -SuccessCode 'SVN_BLAME_SUMMARY_READY' -SkippedCode 'SVN_BLAME_SUMMARY_EMPTY'
            if (-not (Test-NarutoResultSuccess -Result $tmpBlameResult))
            {
                [void]$lookupErrors.Add(([string]$lookup + ': [' + [string]$tmpBlameResult.ErrorCode + '] ' + [string]$tmpBlameResult.Message))
                continue
            }
            $BlameByFile[$lookup] = $tmpBlameResult.Data
            $blame = $tmpBlameResult.Data
            break
        }
        catch
        {
            [void]$lookupErrors.Add(([string]$lookup + ': ' + $_.Exception.Message))
        }
    }
    if ($null -eq $blame -and $existsAtToRevision)
    {
        return (New-NarutoResultFailure -Data ([pscustomobject]@{
                    Blame = $null
                    ExistsAtToRevision = [bool]$existsAtToRevision
                }) -ErrorCode 'STRICT_BLAME_LOOKUP_FAILED' -Message ("Strict file blame lookup failed for '{0}' at r{1}. Attempts: {2}" -f $MetricKey, $ToRevision, ($lookupErrors.ToArray() -join ' | ')) -Context @{
                MetricKey = $MetricKey
                FilePath = $FilePath
                ResolvedFilePath = $ResolvedFilePath
                Revision = [int]$ToRevision
            })
    }
    $data = [pscustomobject]@{
        Blame = $blame
        ExistsAtToRevision = [bool]$existsAtToRevision
    }
    if (-not $existsAtToRevision)
    {
        return (New-NarutoResultSkipped -Data $data -ErrorCode 'STRICT_FILE_NOT_PRESENT_AT_TARGET' -Message ("'{0}' は r{1} 時点に存在しないため strict blame lookup をスキップしました。" -f [string]$MetricKey, [int]$ToRevision))
    }
    return (New-NarutoResultSuccess -Data $data -ErrorCode 'STRICT_FILE_BLAME_READY')
}
function Get-StrictFileRowMetricValues
{
    <#
    .SYNOPSIS
        files 行へ反映する strict 指標値を算出する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [object]$StrictDetail,
        [string]$MetricKey,
        [object]$Blame
    )
    $survived = 0
    $dead = 0
    $selfCancel = 0
    $crossRevert = 0
    $repeatedHunk = 0
    $pingPong = 0
    $internalMoveCount = 0
    if ($MetricKey)
    {
        $survived = Get-HashtableIntValue -Table $StrictDetail.FileSurvived -Key $MetricKey
        $dead = Get-HashtableIntValue -Table $StrictDetail.FileDead -Key $MetricKey
        $selfCancel = Get-HashtableIntValue -Table $StrictDetail.FileSelfCancel -Key $MetricKey
        $crossRevert = Get-HashtableIntValue -Table $StrictDetail.FileCrossRevert -Key $MetricKey
        $repeatedHunk = Get-HashtableIntValue -Table $StrictDetail.FileRepeatedHunk -Key $MetricKey
        $pingPong = Get-HashtableIntValue -Table $StrictDetail.FilePingPong -Key $MetricKey
        $internalMoveCount = Get-HashtableIntValue -Table $StrictDetail.FileInternalMoveCount -Key $MetricKey
    }
    $maxOwned = 0
    if ($null -ne $Blame -and $Blame.LineCountByAuthor.Count -gt 0)
    {
        $maxOwned = ($Blame.LineCountByAuthor.Values | Measure-Object -Maximum).Maximum
    }
    $topBlameShare = if ($null -ne $Blame -and $Blame.LineCountTotal -gt 0)
    {
        $maxOwned / [double]$Blame.LineCountTotal
    }
    else
    {
        0
    }
    return [pscustomobject]@{
        Survived = [int]$survived
        Dead = [int]$dead
        SelfCancel = [int]$selfCancel
        CrossRevert = [int]$crossRevert
        RepeatedHunk = [int]$repeatedHunk
        PingPong = [int]$pingPong
        InternalMoveCount = [int]$internalMoveCount
        TopBlameShare = [double]$topBlameShare
    }
}
function Set-StrictFileRowMetricValues
{
    <#
    .SYNOPSIS
        算出済み strict 指標値を files 行へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$Row,
        [object]$Values
    )
    $Row.'生存行数 (範囲指定)' = [int]$Values.Survived
    $Row.($Context.Metrics.ColDeadAdded) = [Math]::Max(0, [int]$Row.'追加行数' - [int]$Values.Survived)
    $Row.'自己相殺行数 (合計)' = [int]$Values.SelfCancel
    $Row.'他者差戻行数 (合計)' = [int]$Values.CrossRevert
    $Row.'同一箇所反復編集数 (合計)' = [int]$Values.RepeatedHunk
    $Row.'ピンポン回数 (合計)' = [int]$Values.PingPong
    $Row.'内部移動行数 (合計)' = [int]$Values.InternalMoveCount
    $Row.'最多作者blame占有率' = Format-MetricValue -Value ([double]$Values.TopBlameShare)
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
        $resolvedFilePath = Resolve-PathByRenameMap -Context $Context -FilePath $filePath -RenameMap $RenameMap
        $isOldRenamePath = ($RenameMap.ContainsKey($filePath) -and ([string]$RenameMap[$filePath] -ne $filePath))
        $metricKey = if ($isOldRenamePath)
        {
            $null
        }
        else
        {
            $resolvedFilePath
        }
        $lookupResult = Get-StrictFileBlameWithFallback -Context $Context -MetricKey $metricKey -FilePath $filePath -ResolvedFilePath $resolvedFilePath -ExistingFileSet $ExistingFileSet -BlameByFile $BlameByFile -TargetUrl $TargetUrl -ToRevision $ToRevision -CacheDir $CacheDir
        if ([string]$lookupResult.Status -eq 'Failure')
        {
            Throw-NarutoError -Category 'STRICT' -ErrorCode ([string]$lookupResult.ErrorCode) -Message ([string]$lookupResult.Message) -Context @{
                FilePath = $filePath
                MetricKey = $metricKey
                Revision = [int]$ToRevision
            }
        }
        $lookupData = $lookupResult.Data
        if ($null -eq $lookupData)
        {
            $lookupData = [pscustomobject]@{
                Blame = $null
                ExistsAtToRevision = $false
            }
        }
        $values = Get-StrictFileRowMetricValues -StrictDetail $StrictDetail -MetricKey $metricKey -Blame $lookupData.Blame
        Set-StrictFileRowMetricValues -Context $Context -Row $row -Values $values
    }
}
function Get-StrictCommitterRowMetricValues
{
    <#
    .SYNOPSIS
        committers 行へ反映する strict 指標値を算出する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string]$Author,
        [hashtable]$AuthorSurvived,
        [hashtable]$AuthorOwned,
        [int]$OwnedTotal,
        [object]$StrictDetail,
        [hashtable]$AuthorModifiedOthersSurvived,
        [int]$CommitCount
    )
    $survived = Get-HashtableIntValue -Table $AuthorSurvived -Key $Author
    $owned = Get-HashtableIntValue -Table $AuthorOwned -Key $Author
    $dead = Get-HashtableIntValue -Table $StrictDetail.AuthorDead -Key $Author
    $selfDead = Get-HashtableIntValue -Table $StrictDetail.AuthorSelfDead -Key $Author
    $otherDead = Get-HashtableIntValue -Table $StrictDetail.AuthorOtherDead -Key $Author
    $repeatedHunk = Get-HashtableIntValue -Table $StrictDetail.AuthorRepeatedHunk -Key $Author
    $pingPong = Get-HashtableIntValue -Table $StrictDetail.AuthorPingPong -Key $Author
    $internalMove = Get-HashtableIntValue -Table $StrictDetail.AuthorInternalMoveCount -Key $Author
    $modifiedOthersCode = Get-HashtableIntValue -Table $StrictDetail.AuthorModifiedOthersCode -Key $Author
    $modifiedOthersSurvived = Get-HashtableIntValue -Table $AuthorModifiedOthersSurvived -Key $Author
    $ownShare = if ($OwnedTotal -gt 0)
    {
        $owned / [double]$OwnedTotal
    }
    else
    {
        0
    }
    $otherChangeRate = if ($modifiedOthersCode -gt 0)
    {
        $modifiedOthersSurvived / [double]$modifiedOthersCode
    }
    else
    {
        0
    }
    $pingPongPerCommit = if ($CommitCount -gt 0)
    {
        $pingPong / [double]$CommitCount
    }
    else
    {
        0
    }
    return [pscustomobject]@{
        Survived = [int]$survived
        Dead = [int]$dead
        Owned = [int]$owned
        OwnShare = [double]$ownShare
        SelfDead = [int]$selfDead
        OtherDead = [int]$otherDead
        RepeatedHunk = [int]$repeatedHunk
        PingPong = [int]$pingPong
        InternalMove = [int]$internalMove
        ModifiedOthersCode = [int]$modifiedOthersCode
        ModifiedOthersSurvived = [int]$modifiedOthersSurvived
        OtherChangeRate = [double]$otherChangeRate
        PingPongPerCommit = [double]$pingPongPerCommit
    }
}
function Set-StrictCommitterRowMetricValues
{
    <#
    .SYNOPSIS
        算出済み strict 指標値を committers 行へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$Row,
        [object]$Values
    )
    $Row.'生存行数' = [int]$Values.Survived
    $Row.($Context.Metrics.ColDeadAdded) = [Math]::Max(0, [int]$Row.'追加行数' - [int]$Values.Survived)
    $Row.'所有行数' = [int]$Values.Owned
    $Row.'所有割合' = Format-MetricValue -Value ([double]$Values.OwnShare)
    $Row.'自己相殺行数' = [int]$Values.SelfDead
    $Row.'他者差戻行数' = [int]$Values.OtherDead
    $Row.'同一箇所反復編集数' = [int]$Values.RepeatedHunk
    $Row.'ピンポン回数' = [int]$Values.PingPong
    $Row.'内部移動行数' = [int]$Values.InternalMove
    $Row.'他者コード変更行数' = [int]$Values.ModifiedOthersCode
    $Row.'他者コード変更生存行数' = [int]$Values.ModifiedOthersSurvived
    $Row.'他者コード変更生存率' = Format-MetricValue -Value ([double]$Values.OtherChangeRate)
    $Row.'ピンポン率' = Format-MetricValue -Value ([double]$Values.PingPongPerCommit)
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
        $commitCount = [int]$row.'コミット数'
        $values = Get-StrictCommitterRowMetricValues -Author $author -AuthorSurvived $AuthorSurvived -AuthorOwned $AuthorOwned -OwnedTotal $OwnedTotal -StrictDetail $StrictDetail -AuthorModifiedOthersSurvived $AuthorModifiedOthersSurvived -CommitCount $commitCount
        Set-StrictCommitterRowMetricValues -Context $Context -Row $row -Values $values
    }
}
function Get-EffectiveStrictRenameMap
{
    <#
    .SYNOPSIS
        Strict 実行で利用する最終 rename map を確定する。
    .PARAMETER Commits
        コミット情報オブジェクトの配列。
    .PARAMETER RenameMap
        外部指定のリネームマップ。空の場合はコミットから自動生成する。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object[]]$Commits,
        [hashtable]$RenameMap = @{}
    )
    if ($RenameMap.Count -gt 0)
    {
        return $RenameMap
    }
    return (Get-RenameMap -Commits $Commits)
}
function Get-StrictDeathDetailOrThrow
{
    <#
    .SYNOPSIS
        Strict の厳密死亡帰属結果を取得し、null を拒否する。
    .PARAMETER Context
        NarutoContext ハッシュテーブル。
    .PARAMETER Commits
        対象コミット情報の配列。
    .PARAMETER RevToAuthor
        リビジョン番号から著者名へのマッピング。
    .PARAMETER TargetUrl
        解析対象の SVN リポジトリ URL。
    .PARAMETER FromRevision
        解析範囲の開始リビジョン。
    .PARAMETER ToRevision
        解析範囲の終了リビジョン。
    .PARAMETER CacheDir
        キャッシュディレクトリのパス。
    .PARAMETER RenameMap
        ファイルリネーム追跡用のマッピング。
    .PARAMETER Parallel
        並列実行ワーカー数。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RevToAuthor,
        [string]$TargetUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$CacheDir,
        [hashtable]$RenameMap,
        [int]$Parallel = 1
    )
    $strictDetail = Get-ExactDeathAttribution -Context $Context -Commits $Commits -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -RenameMap $RenameMap -Parallel $Parallel
    if ($null -eq $strictDetail)
    {
        Throw-NarutoError -Category 'STRICT' -ErrorCode 'STRICT_DEATH_ATTRIBUTION_NULL' -Message 'Strict death attribution returned null.' -Context @{}
    }
    return $strictDetail
}
function New-StrictExecutionContext
{
    <#
    .SYNOPSIS
        Strict 実行依存データを格納する DTO を生成する。
    .PARAMETER RenameMap
        ファイルリネーム追跡用のマッピング。
    .PARAMETER StrictDetail
        厳密死亡帰属の詳細結果オブジェクト。
    .PARAMETER AuthorOwned
        著者ごとの所有行数マッピング。
    .PARAMETER OwnedTotal
        所有行数の合計。
    .PARAMETER BlameByFile
        ファイルパスごとの blame 結果マッピング。
    .PARAMETER ExistingFileSet
        現存するファイルパスのセット。
    .PARAMETER AuthorModifiedOthersSurvived
        著者が変更し他者の行として生存したマッピング。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [hashtable]$RenameMap,
        [object]$StrictDetail,
        [hashtable]$AuthorOwned,
        [int]$OwnedTotal,
        [hashtable]$BlameByFile,
        [System.Collections.Generic.HashSet[string]]$ExistingFileSet,
        [hashtable]$AuthorModifiedOthersSurvived
    )
    return [pscustomobject]@{
        RenameMap = $RenameMap
        StrictDetail = $StrictDetail
        AuthorSurvived = $StrictDetail.AuthorSurvived
        AuthorOwned = $AuthorOwned
        OwnedTotal = [int]$OwnedTotal
        BlameByFile = $BlameByFile
        ExistingFileSet = $ExistingFileSet
        AuthorModifiedOthersSurvived = $AuthorModifiedOthersSurvived
    }
}
function New-StrictAttributionResult
{
    <#
    .SYNOPSIS
        Strict 反映結果の返却 DTO を生成する。
    .PARAMETER StrictExecutionContext
        New-StrictExecutionContext で生成した実行コンテキスト DTO。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param([object]$StrictExecutionContext)
    return [pscustomobject]@{
        KillMatrix = $StrictExecutionContext.StrictDetail.KillMatrix
        AuthorSelfDead = $StrictExecutionContext.StrictDetail.AuthorSelfDead
        AuthorBorn = $StrictExecutionContext.StrictDetail.AuthorBorn
    }
}
function Get-StrictExecutionContext
{
    <#
    .SYNOPSIS
        Strict 帰属反映に必要な依存データを一括で構築する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
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
        [int]$Parallel = 1,
        [hashtable]$RenameMap = @{}
    )
    $renameMap = Get-EffectiveStrictRenameMap -Commits $Commits -RenameMap $RenameMap
    $strictDetail = Get-StrictDeathDetailOrThrow -Context $Context -Commits $Commits -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -RenameMap $renameMap -Parallel $Parallel
    $ownershipAggregate = Get-StrictOwnershipAggregate -Context $Context -TargetUrl $TargetUrl -ToRevision $ToRevision -CacheDir $CacheDir -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -Parallel $Parallel
    $authorModifiedOthersSurvived = Get-AuthorModifiedOthersSurvivedCount -BlameByFile $ownershipAggregate.BlameByFile -RevsWhereKilledOthers $strictDetail.RevsWhereKilledOthers -FromRevision $FromRevision -ToRevision $ToRevision

    return (New-StrictExecutionContext -RenameMap $renameMap -StrictDetail $strictDetail -AuthorOwned $ownershipAggregate.AuthorOwned -OwnedTotal ([int]$ownershipAggregate.OwnedTotal) -BlameByFile $ownershipAggregate.BlameByFile -ExistingFileSet $ownershipAggregate.ExistingFileSet -AuthorModifiedOthersSurvived $authorModifiedOthersSurvived)
}
function Update-StrictMetricsOnRows
{
    <#
    .SYNOPSIS
        Strict 実行コンテキストを files/committers 行へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$FileRows,
        [object[]]$CommitterRows,
        [object]$StrictExecutionContext,
        [string]$TargetUrl,
        [int]$ToRevision,
        [string]$CacheDir
    )
    $strictDetail = $StrictExecutionContext.StrictDetail
    Update-FileRowWithStrictMetric -Context $Context -FileRows $FileRows -RenameMap $StrictExecutionContext.RenameMap -StrictDetail $strictDetail -ExistingFileSet $StrictExecutionContext.ExistingFileSet -BlameByFile $StrictExecutionContext.BlameByFile -TargetUrl $TargetUrl -ToRevision $ToRevision -CacheDir $CacheDir
    Update-CommitterRowWithStrictMetric -Context $Context -CommitterRows $CommitterRows -AuthorSurvived $StrictExecutionContext.AuthorSurvived -AuthorOwned $StrictExecutionContext.AuthorOwned -OwnedTotal ([int]$StrictExecutionContext.OwnedTotal) -StrictDetail $strictDetail -AuthorModifiedOthersSurvived $StrictExecutionContext.AuthorModifiedOthersSurvived
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
        [Parameter(Mandatory = $true)][hashtable]$Context,
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

    $strictExecutionContext = Get-StrictExecutionContext -Context $Context -Commits $Commits -RevToAuthor $RevToAuthor -TargetUrl $TargetUrl -FromRevision $FromRevision -ToRevision $ToRevision -CacheDir $CacheDir -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -Parallel $Parallel -RenameMap $RenameMap
    Update-StrictMetricsOnRows -Context $Context -FileRows $FileRows -CommitterRows $CommitterRows -StrictExecutionContext $strictExecutionContext -TargetUrl $TargetUrl -ToRevision $ToRevision -CacheDir $CacheDir

    return (New-StrictAttributionResult -StrictExecutionContext $strictExecutionContext)
}
# endregion Strict メトリクス更新
# region ヘッダーとメタデータ
function Get-MetricColumnDefinitions
{
    <#
    .SYNOPSIS
        メトリクス出力列の定義配列を返す。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    return [ordered]@{
        Committer = @('作者', 'コミット数', '活動日数', '変更ファイル数', '変更ディレクトリ数', '追加行数', '削除行数', '純増行数', '総チャーン', 'コミットあたりチャーン', '削除対追加比', 'チャーン対純増比', 'リワーク率', 'バイナリ変更回数', '追加アクション数', '変更アクション数', '削除アクション数', '置換アクション数', '生存行数', $Context.Metrics.ColDeadAdded, '所有行数', '所有割合', '自己相殺行数', '他者差戻行数', '同一箇所反復編集数', 'ピンポン回数', '内部移動行数', '他者コード変更行数', '他者コード変更生存行数', '他者コード変更生存率', 'ピンポン率', '変更エントロピー', '平均共同作者数', '最大共同作者数', 'メッセージ総文字数', 'メッセージ平均文字数', '課題ID言及数', '修正キーワード数', '差戻キーワード数', 'マージキーワード数')
        File = @('ファイルパス', 'コミット数', '作者数', '追加行数', '削除行数', '純増行数', '総チャーン', 'バイナリ変更回数', '作成回数', '削除回数', '置換回数', '初回変更リビジョン', '最終変更リビジョン', '平均変更間隔日数', '活動期間日数', '生存行数 (範囲指定)', $Context.Metrics.ColDeadAdded, '最多作者チャーン占有率', '最多作者blame占有率', '自己相殺行数 (合計)', '他者差戻行数 (合計)', '同一箇所反復編集数 (合計)', 'ピンポン回数 (合計)', '内部移動行数 (合計)', 'ホットスポットスコア', 'ホットスポット順位')
        Commit = @('リビジョン', '日時', '作者', 'メッセージ文字数', 'メッセージ', '変更ファイル数', '追加行数', '削除行数', 'チャーン', 'エントロピー')
        Coupling = @('ファイルA', 'ファイルB', '共変更回数', 'Jaccard', 'リフト値')
    }
}
function Get-MetricHeader
{
    <#
    .SYNOPSIS
        CSV 出力に使う列ヘッダー定義を返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $definitions = Get-MetricColumnDefinitions -Context $Context
    return [pscustomobject]@{
        Committer = @($definitions.Committer)
        File = @($definitions.File)
        Commit = @($definitions.Commit)
        Coupling = @($definitions.Coupling)
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
    param( [Parameter(Mandatory = $true)][hashtable]$Context,
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
        [switch]$IgnoreWhitespace,
        [switch]$ExcludeCommentOnlyLines
    )
    $diagnosticWarningCount = 0
    $diagnosticWarningCodes = [ordered]@{}
    $diagnosticSkippedOutputs = @()
    $stageSeconds = [ordered]@{}
    $strictBreakdown = [ordered]@{}
    $strictTargetStats = [ordered]@{}
    $svnCommandStats = [ordered]@{}
    $perfGate = [ordered]@{}
    if ($null -ne $Context -and $null -ne $Context.Diagnostics)
    {
        $diagnosticWarningCount = [int]$Context.Diagnostics.WarningCount
        if ($null -ne $Context.Diagnostics.WarningCodes)
        {
            $diagnosticWarningCodes = [ordered]@{} + $Context.Diagnostics.WarningCodes
        }
        if ($null -ne $Context.Diagnostics.SkippedOutputs)
        {
            $diagnosticSkippedOutputs = @($Context.Diagnostics.SkippedOutputs.ToArray())
        }
        if ($Context.Diagnostics.ContainsKey('Performance') -and $null -ne $Context.Diagnostics.Performance)
        {
            if ($Context.Diagnostics.Performance.Contains('StageSeconds') -and $null -ne $Context.Diagnostics.Performance.StageSeconds)
            {
                $stageSeconds = [ordered]@{} + $Context.Diagnostics.Performance.StageSeconds
            }
            if ($Context.Diagnostics.Performance.Contains('StrictBreakdown') -and $null -ne $Context.Diagnostics.Performance.StrictBreakdown)
            {
                $strictBreakdown = [ordered]@{} + $Context.Diagnostics.Performance.StrictBreakdown
            }
            if ($Context.Diagnostics.Performance.Contains('StrictTargetStats') -and $null -ne $Context.Diagnostics.Performance.StrictTargetStats)
            {
                $strictTargetStats = [ordered]@{} + $Context.Diagnostics.Performance.StrictTargetStats
            }
            if ($Context.Diagnostics.Performance.Contains('SvnCommandStats') -and $null -ne $Context.Diagnostics.Performance.SvnCommandStats)
            {
                $svnCommandStats = [ordered]@{} + $Context.Diagnostics.Performance.SvnCommandStats
            }
            if ($Context.Diagnostics.Performance.Contains('PerfGate') -and $null -ne $Context.Diagnostics.Performance.PerfGate)
            {
                $perfGate = [ordered]@{} + $Context.Diagnostics.Performance.PerfGate
            }
        }
    }
    return [ordered]@{
        StartTime = $StartTime.ToString('o')
        EndTime = $EndTime.ToString('o')
        DurationSeconds = Format-MetricValue -Value ((New-TimeSpan -Start $StartTime -End $EndTime).TotalSeconds)
        RepoUrl = $TargetUrl
        FromRev = $FromRevision
        ToRev = $ToRevision
        SvnExecutable = $Context.Runtime.SvnExecutable
        SvnVersion = $SvnVersion
        StrictMode = $true
        Parallel = $Parallel
        TopNCount = $TopNCount
        Encoding = $Encoding
        CommitCount = @($Commits).Count
        FileCount = @($FileRows).Count
        OutputDirectory = (Resolve-Path $OutDirectory).Path
        StrictBlameCallCount = [int]($Context.Caches.StrictBlameCacheHits + $Context.Caches.StrictBlameCacheMisses)
        StrictBlameCacheHits = [int]$Context.Caches.StrictBlameCacheHits
        StrictBlameCacheMisses = [int]$Context.Caches.StrictBlameCacheMisses
        Engine = 'Hybrid'
        StageSeconds = $stageSeconds
        StrictBreakdown = $strictBreakdown
        StrictTargetStats = $strictTargetStats
        SvnCommandStats = $svnCommandStats
        PerfGate = $perfGate
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
            ExcludeCommentOnlyLines = [bool]$ExcludeCommentOnlyLines
        }
        Diagnostics = [ordered]@{
            WarningCount = $diagnosticWarningCount
            WarningCodes = $diagnosticWarningCodes
            SkippedOutputs = $diagnosticSkippedOutputs
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
    .PARAMETER Commits
        解析対象のコミット配列を指定する。
    .PARAMETER LogPathPrefix
        svn log パスのリポジトリ相対プレフィックス。
    #>
    [CmdletBinding()]
    param([object[]]$Commits, [string]$LogPathPrefix)
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
                $oldPath = ConvertTo-DiffRelativePath -Path (ConvertTo-PathKey -Path ([string]$p.CopyFromPath)) -LogPathPrefix $LogPathPrefix
                $newPath = ConvertTo-DiffRelativePath -Path (ConvertTo-PathKey -Path ([string]$p.Path)) -LogPathPrefix $LogPathPrefix
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
function Get-NormalizedRevisionRange
{
    <#
    .SYNOPSIS
        開始/終了リビジョンを昇順に正規化する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [int]$FromRevision,
        [int]$ToRevision
    )
    $normalizedFrom = $FromRevision
    $normalizedTo = $ToRevision
    if ($normalizedFrom -gt $normalizedTo)
    {
        $tmp = $normalizedFrom
        $normalizedFrom = $normalizedTo
        $normalizedTo = $tmp
    }
    return [pscustomobject]@{
        FromRevision = [int]$normalizedFrom
        ToRevision = [int]$normalizedTo
    }
}
function Resolve-PipelineOutputState
{
    <#
    .SYNOPSIS
        パイプライン出力先とキャッシュディレクトリを確定する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([string]$OutDirectory)
    $resolvedOutDirectory = $OutDirectory
    if (-not $resolvedOutDirectory)
    {
        $resolvedOutDirectory = Join-Path (Get-Location) 'NarutoCode_out'
    }
    $resolvedOutDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($resolvedOutDirectory)
    $outputInitializeResult = Initialize-OutputDirectory -Path $resolvedOutDirectory -CallerName 'Resolve-PipelineOutputState'
    if (-not (Test-NarutoResultSuccess -Result $outputInitializeResult))
    {
        Throw-NarutoError -Category 'OUTPUT' -ErrorCode ([string]$outputInitializeResult.ErrorCode) -Message ([string]$outputInitializeResult.Message) -Context @{
            OutDirectory = $resolvedOutDirectory
            Caller = 'Resolve-PipelineOutputState'
        }
    }
    $cacheDir = Join-Path $resolvedOutDirectory 'cache'
    $cacheInitializeResult = Initialize-OutputDirectory -Path $cacheDir -CallerName 'Resolve-PipelineOutputState.Cache'
    if (-not (Test-NarutoResultSuccess -Result $cacheInitializeResult))
    {
        Throw-NarutoError -Category 'OUTPUT' -ErrorCode ([string]$cacheInitializeResult.ErrorCode) -Message ([string]$cacheInitializeResult.Message) -Context @{
            CacheDirectory = $cacheDir
            Caller = 'Resolve-PipelineOutputState.Cache'
        }
    }
    return [pscustomobject]@{
        OutDirectory = $resolvedOutDirectory
        CacheDir = $cacheDir
    }
}
function Get-NormalizedPipelineFilterSet
{
    <#
    .SYNOPSIS
        パイプラインの拡張子/パスフィルタ入力を正規化する。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions
    )
    return [pscustomobject]@{
        IncludePaths = @(ConvertTo-NormalizedPatternList -Patterns $IncludePaths)
        ExcludePaths = @(ConvertTo-NormalizedPatternList -Patterns $ExcludePaths)
        IncludeExtensions = @(ConvertTo-NormalizedExtension -Extensions $IncludeExtensions)
        ExcludeExtensions = @(ConvertTo-NormalizedExtension -Extensions $ExcludeExtensions)
    }
}
function Initialize-PipelineSvnRuntimeContext
{
    <#
    .SYNOPSIS
        実行時 SVN コマンドと共通引数を Context へ反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$SvnExecutable,
        [string]$Username,
        [securestring]$Password,
        [switch]$NonInteractive,
        [switch]$TrustServerCert
    )
    $svnCmd = Get-Command $SvnExecutable -ErrorAction SilentlyContinue
    if (-not $svnCmd)
    {
        Throw-NarutoError -Category 'ENV' -ErrorCode 'ENV_SVN_EXECUTABLE_NOT_FOUND' -Message ("svn executable not found: '{0}'. Install Subversion client or specify -SvnExecutable." -f $SvnExecutable) -Context @{
            SvnExecutable = $SvnExecutable
        }
    }
    $Context.Runtime.SvnExecutable = $svnCmd.Source
    $Context.Runtime.SvnGlobalArguments = Get-SvnGlobalArgumentList -Username $Username -Password $Password -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert
    return $Context.Runtime.SvnExecutable
}
function New-PipelineExecutionState
{
    <#
    .SYNOPSIS
        パイプライン実行状態 DTO を構築する。
    .PARAMETER RepoUrl
        SVN リポジトリのルート URL。
    .PARAMETER FromRevision
        解析範囲の開始リビジョン。
    .PARAMETER ToRevision
        解析範囲の終了リビジョン。
    .PARAMETER OutDirectory
        出力ファイルの配置ディレクトリ。
    .PARAMETER CacheDir
        キャッシュファイルの配置ディレクトリ。
    .PARAMETER IncludePaths
        解析対象に含めるパスフィルタ。
    .PARAMETER ExcludePaths
        解析対象から除外するパスフィルタ。
    .PARAMETER IncludeExtensions
        解析対象に含める拡張子フィルタ。
    .PARAMETER ExcludeExtensions
        解析対象から除外する拡張子フィルタ。
    .PARAMETER TargetUrl
        解析対象の SVN パス URL。
    .PARAMETER LogPathPrefix
        svn log パスのリポジトリ相対プレフィックス。
    .PARAMETER SvnVersion
        使用する SVN クライアントのバージョン文字列。
    .PARAMETER ExcludeCommentOnlyLines
        指定時はコメント専用行を全メトリクス集計から除外する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string]$RepoUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$OutDirectory,
        [string]$CacheDir,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string]$TargetUrl,
        [string]$LogPathPrefix,
        [string]$SvnVersion,
        [switch]$ExcludeCommentOnlyLines
    )
    return [pscustomobject]@{
        RepoUrl = $RepoUrl
        FromRevision = [int]$FromRevision
        ToRevision = [int]$ToRevision
        OutDirectory = $OutDirectory
        CacheDir = $CacheDir
        IncludePaths = @($IncludePaths)
        ExcludePaths = @($ExcludePaths)
        IncludeExtensions = @($IncludeExtensions)
        ExcludeExtensions = @($ExcludeExtensions)
        TargetUrl = $TargetUrl
        LogPathPrefix = [string]$LogPathPrefix
        SvnVersion = $SvnVersion
        ExcludeCommentOnlyLines = [bool]$ExcludeCommentOnlyLines
    }
}
function Resolve-PipelineExecutionState
{
    <#
    .SYNOPSIS
        パイプライン実行前の入力正規化と実行環境確定を行う。
    .DESCRIPTION
        戻り値プロパティ:
        - RepoUrl           [string]   入力リポジトリ URL
        - FromRevision      [int]      正規化済み開始リビジョン
        - ToRevision        [int]      正規化済み終了リビジョン
        - OutDirectory      [string]   絶対パスに解決済みの出力ディレクトリ
        - CacheDir          [string]   キャッシュディレクトリパス
        - IncludePaths      [string[]] 正規化済みパス包含パターン
        - ExcludePaths      [string[]] 正規化済みパス除外パターン
        - IncludeExtensions [string[]] 正規化済み拡張子包含リスト
        - ExcludeExtensions [string[]] 正規化済み拡張子除外リスト
        - TargetUrl         [string]   SVN 実行用に確定したターゲット URL
        - LogPathPrefix    [string]   svn log パスのリポジトリ相対プレフィックス
        - SvnVersion        [string]   検出した SVN バージョン文字列
        - ExcludeCommentOnlyLines [bool] コメント専用行除外の有効フラグ
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$RepoUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$OutDirectory,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [string]$SvnExecutable,
        [string]$Username,
        [securestring]$Password,
        [switch]$NonInteractive,
        [switch]$TrustServerCert,
        [switch]$ExcludeCommentOnlyLines
    )
    $normalizedRange = Get-NormalizedRevisionRange -FromRevision $FromRevision -ToRevision $ToRevision
    $outputState = Resolve-PipelineOutputState -OutDirectory $OutDirectory
    $normalizedFilters = Get-NormalizedPipelineFilterSet -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions

    [void](Initialize-PipelineSvnRuntimeContext -Context $Context -SvnExecutable $SvnExecutable -Username $Username -Password $Password -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert)
    $targetUrl = Resolve-SvnTargetUrl -Context $Context -Target $RepoUrl
    $logPathPrefix = Get-SvnLogPathPrefix -Context $Context -TargetUrl $targetUrl
    $svnVersionResult = Get-SvnVersionSafe -Context $Context
    $svnVersionResult = ConvertTo-NarutoResultAdapter -InputObject $svnVersionResult -SuccessCode 'SVN_VERSION_READY' -SkippedCode 'SVN_VERSION_UNAVAILABLE'
    $svnVersion = '(unknown)'
    if (Test-NarutoResultSuccess -Result $svnVersionResult)
    {
        $svnVersion = [string]$svnVersionResult.Data
    }
    else
    {
        Write-NarutoDiagnostic -Context $Context -Level 'Warning' -ErrorCode ([string]$svnVersionResult.ErrorCode) -Message ([string]$svnVersionResult.Message
        )
    }

    return (New-PipelineExecutionState -RepoUrl $RepoUrl -FromRevision $normalizedRange.FromRevision -ToRevision $normalizedRange.ToRevision -OutDirectory $outputState.OutDirectory -CacheDir $outputState.CacheDir -IncludePaths $normalizedFilters.IncludePaths -ExcludePaths $normalizedFilters.ExcludePaths -IncludeExtensions $normalizedFilters.IncludeExtensions -ExcludeExtensions $normalizedFilters.ExcludeExtensions -TargetUrl $targetUrl -LogPathPrefix $logPathPrefix -SvnVersion $svnVersion -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines)
}
function Invoke-PipelineLogAndDiffStage
{
    <#
    .SYNOPSIS
        SVN ログ取得と差分統合ステージを実行する。
    .DESCRIPTION
        戻り値プロパティ:
        - Commits     [object[]]  パース済みコミット配列
        - RevToAuthor [hashtable] リビジョン→作者名マッピング
        - RenameMap   [hashtable] リネーム元パス→最新パスのマッピング
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$ExecutionState,
        [switch]$IgnoreWhitespace,
        [int]$Parallel
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 2/8: SVN ログの取得' -PercentComplete 5
    $logText = Invoke-SvnCommand -Context $Context -Arguments @('log', '--xml', '--verbose', '-r', ("{0}:{1}" -f $ExecutionState.FromRevision, $ExecutionState.ToRevision), $ExecutionState.TargetUrl) -ErrorContext 'svn log'
    $commits = @(ConvertFrom-SvnLogXml -XmlText $logText)

    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 3/8: 差分の取得と統計構築' -PercentComplete 15
    $diffArgs = Get-SvnDiffArgumentList -IgnoreWhitespace:$IgnoreWhitespace
    $revToAuthor = Initialize-CommitDiffData -Context $Context -Commits $commits -CacheDir $ExecutionState.CacheDir -TargetUrl $ExecutionState.TargetUrl -DiffArguments $diffArgs -IncludeExtensions $ExecutionState.IncludeExtensions -ExcludeExtensions $ExecutionState.ExcludeExtensions -IncludePathPatterns $ExecutionState.IncludePaths -ExcludePathPatterns $ExecutionState.ExcludePaths -LogPathPrefix $ExecutionState.LogPathPrefix -ExcludeCommentOnlyLines:$ExecutionState.ExcludeCommentOnlyLines -Parallel $Parallel
    $renameMap = Get-RenameMap -Commits $commits -LogPathPrefix $ExecutionState.LogPathPrefix

    return [pscustomobject]@{
        Commits = $commits
        RevToAuthor = $revToAuthor
        RenameMap = $renameMap
    }
}
function Invoke-PipelineAggregationStage
{
    <#
    .SYNOPSIS
        基本メトリクス集計ステージを実行する。
    .DESCRIPTION
        戻り値プロパティ:
        - CommitterRows [object[]] コミッター別メトリクス行
        - FileRows      [object[]] ファイル別メトリクス行
        - CouplingRows  [object[]] 共変更カップリング行
        - CommitRows    [object[]] コミット別サマリー行
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object[]]$Commits,
        [hashtable]$RenameMap
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 4/8: 基本メトリクス算出' -PercentComplete 35
    $committerRows = @(Get-CommitterMetric -Context $Context -Commits $Commits -RenameMap $RenameMap)
    $fileRows = @(Get-FileMetric -Context $Context -Commits $Commits -RenameMap $RenameMap)
    $couplingRows = @(Get-CoChangeMetric -Context $Context -Commits $Commits -TopNCount 0 -RenameMap $RenameMap)
    $commitRows = @(New-CommitRowFromCommit -Context $Context -Commits $Commits)

    return [pscustomobject]@{
        CommitterRows = $committerRows
        FileRows = $fileRows
        CouplingRows = $couplingRows
        CommitRows = $commitRows
    }
}
function Invoke-PipelineStrictStage
{
    <#
    .SYNOPSIS
        Strict 帰属解析ステージを実行する。
    .DESCRIPTION
        Update-StrictAttributionMetric への依存注入レイヤーとして機能する。
        前段ステージの出力を展開して渡すことで、パイプラインと Strict 帰属
        ロジックの結合を分離し、Strict 処理の独立テストを容易にする。
        戻り値は Update-StrictAttributionMetric の出力をそのまま返す。
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [object]$ExecutionState,
        [object]$LogAndDiffStage,
        [object]$AggregationStage,
        [int]$Parallel
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 5/8: Strict 帰属解析' -PercentComplete 45
    return (Update-StrictAttributionMetric -Context $Context -Commits $LogAndDiffStage.Commits -RevToAuthor $LogAndDiffStage.RevToAuthor -TargetUrl $ExecutionState.TargetUrl -FromRevision $ExecutionState.FromRevision -ToRevision $ExecutionState.ToRevision -CacheDir $ExecutionState.CacheDir -IncludeExtensions $ExecutionState.IncludeExtensions -ExcludeExtensions $ExecutionState.ExcludeExtensions -IncludePaths $ExecutionState.IncludePaths -ExcludePaths $ExecutionState.ExcludePaths -FileRows $AggregationStage.FileRows -CommitterRows $AggregationStage.CommitterRows -Parallel $Parallel -RenameMap $LogAndDiffStage.RenameMap)
}
function Write-PipelineCsvArtifacts
{
    <#
    .SYNOPSIS
        CSV 成果物出力ステージを実行する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$OutDirectory,
        [object[]]$CommitterRows,
        [object[]]$FileRows,
        [object[]]$CommitRows,
        [object[]]$CouplingRows,
        [object]$StrictResult,
        [string]$Encoding
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 6/8: CSV レポート出力' -PercentComplete 80
    $headers = Get-MetricHeader -Context $Context
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'committers.csv') -Rows $CommitterRows -Headers $headers.Committer -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'files.csv') -Rows $FileRows -Headers $headers.File -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'commits.csv') -Rows $CommitRows -Headers $headers.Commit -EncodingName $Encoding
    Write-CsvFile -FilePath (Join-Path $OutDirectory 'couplings.csv') -Rows $CouplingRows -Headers $headers.Coupling -EncodingName $Encoding
    if ($null -ne $StrictResult)
    {
        Write-KillMatrixCsv -OutDirectory $OutDirectory -KillMatrix $StrictResult.KillMatrix -AuthorSelfDead $StrictResult.AuthorSelfDead -Committers $CommitterRows -EncodingName $Encoding
    }
}
function Write-PipelineVisualizationArtifacts
{
    <#
    .SYNOPSIS
        可視化成果物出力ステージを実行する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$OutDirectory,
        [object[]]$CommitterRows,
        [object[]]$FileRows,
        [object[]]$CommitRows,
        [object[]]$CouplingRows,
        [object]$StrictResult,
        [int]$TopNCount,
        [string]$Encoding
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 7/8: 可視化出力' -PercentComplete 88

    # --- Strict 依存データの安全な展開 ---
    # $StrictResult が $null の場合は $authorBorn = $null になる。
    # Write-ProjectSummaryDashboard は $AuthorBorn が $null でも安全に動作する
    # （$null -ne $AuthorBorn ガードで Born 集計をスキップする）。
    $authorBorn = $null
    if ($null -ne $StrictResult)
    {
        $authorBorn = $StrictResult.AuthorBorn
    }

    # --- テーブル駆動の可視化ディスパッチ ---
    # 各エントリは @{ Fn = '関数名'; Args = @{パラメータ名 = 値} } で定義する。
    # 共通パラメータ（OutDirectory / EncodingName）は後続ループで自動付与される。
    $visualizations = @(
        @{ Fn = 'Write-PlantUmlFile'; Args = @{ Committers = $CommitterRows; Files = $FileRows; Couplings = $CouplingRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-FileBubbleChart'; Args = @{ Files = $FileRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-CommitterOutcomeChart'; Args = @{ Committers = $CommitterRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-CommitterScatterChart'; Args = @{ Committers = $CommitterRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-SurvivedShareDonutChart'; Args = @{ Committers = $CommitterRows } }
        @{ Fn = 'Write-TeamActivityProfileChart'; Args = @{ Committers = $CommitterRows } }
        @{ Fn = 'Write-FileQualityScatterChart'; Args = @{ Files = $FileRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-CommitTimelineChart'; Args = @{ Commits = $CommitRows } }
        @{ Fn = 'Write-CommitScatterChart'; Args = @{ Commits = $CommitRows } }
        @{ Fn = 'Write-ProjectCodeFateChart'; Args = @{ Committers = $CommitterRows } }
        @{ Fn = 'Write-ProjectEfficiencyQuadrantChart'; Args = @{ Files = $FileRows; TopNCount = $TopNCount } }
        @{ Fn = 'Write-ProjectSummaryDashboard'; Args = @{ Committers = $CommitterRows; FileRows = $FileRows; CommitRows = $CommitRows; AuthorBorn = $authorBorn } }
    )
    foreach ($viz in $visualizations)
    {
        $vizArgs = $viz.Args
        $vizArgs['Context'] = $Context
        $vizArgs['OutDirectory'] = $OutDirectory
        $vizArgs['EncodingName'] = $Encoding
        $vizResult = & $viz.Fn @vizArgs
        $vizResult = ConvertTo-NarutoResultAdapter -InputObject $vizResult -SuccessCode 'OUTPUT_VISUALIZATION_WRITTEN' -SkippedCode 'OUTPUT_VISUALIZATION_SKIPPED'
        if ([string]$vizResult.Status -eq 'Failure')
        {
            Throw-NarutoError -Category 'OUTPUT' -ErrorCode ([string]$vizResult.ErrorCode) -Message ([string]$vizResult.Message) -Context @{
                Function = [string]$viz.Fn
                OutDirectory = $OutDirectory
            }
        }
    }

    # Strict 結果がある場合のみヒートマップを出力する
    if ($null -ne $StrictResult)
    {
        $heatMapResult = Write-TeamInteractionHeatMap -Context $Context -OutDirectory $OutDirectory -KillMatrix $StrictResult.KillMatrix -AuthorSelfDead $StrictResult.AuthorSelfDead -Committers $CommitterRows -EncodingName $Encoding
        $heatMapResult = ConvertTo-NarutoResultAdapter -InputObject $heatMapResult -SuccessCode 'OUTPUT_VISUALIZATION_WRITTEN' -SkippedCode 'OUTPUT_VISUALIZATION_SKIPPED'
        if ([string]$heatMapResult.Status -eq 'Failure')
        {
            Throw-NarutoError -Category 'OUTPUT' -ErrorCode ([string]$heatMapResult.ErrorCode) -Message ([string]$heatMapResult.Message) -Context @{
                Function = 'Write-TeamInteractionHeatMap'
                OutDirectory = $OutDirectory
            }
        }
    }
}
function Write-PipelineRunArtifacts
{
    <#
    .SYNOPSIS
        実行メタデータとサマリー出力ステージを実行する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [datetime]$StartedAt,
        [object]$ExecutionState,
        [int]$Parallel,
        [int]$TopNCount,
        [string]$Encoding,
        [object[]]$Commits,
        [object[]]$FileRows,
        [switch]$NonInteractive,
        [switch]$TrustServerCert,
        [switch]$IgnoreWhitespace,
        [switch]$ExcludeCommentOnlyLines
    )
    Write-Progress -Id 0 -Activity 'NarutoCode' -Status 'ステップ 8/8: メタデータ出力' -PercentComplete 95
    $finishedAt = Get-Date
    $meta = New-RunMetaData -Context $Context -StartTime $StartedAt -EndTime $finishedAt -TargetUrl $ExecutionState.TargetUrl -FromRevision $ExecutionState.FromRevision -ToRevision $ExecutionState.ToRevision -SvnVersion $ExecutionState.SvnVersion -Parallel $Parallel -TopNCount $TopNCount -Encoding $Encoding -Commits $Commits -FileRows $FileRows -OutDirectory $ExecutionState.OutDirectory -IncludePaths $ExecutionState.IncludePaths -ExcludePaths $ExecutionState.ExcludePaths -IncludeExtensions $ExecutionState.IncludeExtensions -ExcludeExtensions $ExecutionState.ExcludeExtensions -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -IgnoreWhitespace:$IgnoreWhitespace -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines
    Write-JsonFile -Data $meta -FilePath (Join-Path $ExecutionState.OutDirectory 'run_meta.json') -Depth 12 -EncodingName $Encoding

    Write-Progress -Id 0 -Activity 'NarutoCode' -Completed
    Write-RunSummary -TargetUrl $ExecutionState.TargetUrl -FromRevision $ExecutionState.FromRevision -ToRevision $ExecutionState.ToRevision -Commits $Commits -FileRows $FileRows -OutDirectory $ExecutionState.OutDirectory
    return [pscustomobject]$meta
}
function New-PipelineResultObject
{
    <#
    .SYNOPSIS
        パイプライン実行結果を返却用オブジェクトへ整形する。
    .DESCRIPTION
        戻り値プロパティ:
        - OutDirectory [string]   解決済み出力ディレクトリの絶対パス
        - Committers   [object[]] コミッター別メトリクス行
        - Files        [object[]] ファイル別メトリクス行
        - Commits      [object[]] コミット別サマリー行
        - Couplings    [object[]] 共変更カップリング行
        - RunMeta      [object]   実行メタデータ
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string]$OutDirectory,
        [object[]]$CommitterRows,
        [object[]]$FileRows,
        [object[]]$CommitRows,
        [object[]]$CouplingRows,
        [object]$RunMeta
    )
    return [pscustomobject]@{
        OutDirectory = (Resolve-Path $OutDirectory).Path
        Committers = $CommitterRows
        Files = $FileRows
        Commits = $CommitRows
        Couplings = $CouplingRows
        RunMeta = $RunMeta
    }
}
function Invoke-NarutoCodePipeline
{
    <#
    .SYNOPSIS
        NarutoCode の解析パイプラインを実行する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$RepoUrl,
        [int]$FromRevision,
        [int]$ToRevision,
        [string]$SvnExecutable,
        [string]$OutDirectory,
        [string]$Username,
        [securestring]$Password,
        [switch]$NonInteractive,
        [switch]$TrustServerCert,
        [int]$Parallel,
        [string[]]$IncludePaths,
        [string[]]$ExcludePaths,
        [string[]]$IncludeExtensions,
        [string[]]$ExcludeExtensions,
        [int]$TopNCount,
        [string]$Encoding,
        [switch]$IgnoreWhitespace,
        [switch]$ExcludeCommentOnlyLines
    )
    $startedAt = Get-Date
    $pipelineStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $Context = Initialize-StrictModeContext -Context $Context
    $Context.Runtime.ExcludeCommentOnlyLines = [bool]$ExcludeCommentOnlyLines
    $executionState = Resolve-PipelineExecutionState -Context $Context -RepoUrl $RepoUrl -FromRevision $FromRevision -ToRevision $ToRevision -OutDirectory $OutDirectory -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -SvnExecutable $SvnExecutable -Username $Username -Password $Password -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines

    $stageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $logAndDiffStage = Invoke-PipelineLogAndDiffStage -Context $Context -ExecutionState $executionState -IgnoreWhitespace:$IgnoreWhitespace -Parallel $Parallel
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StageSeconds' -Key 'LogAndDiff' -Value (Format-MetricValue -Value $stageStopwatch.Elapsed.TotalSeconds)
    $stageStopwatch.Restart()
    $aggregationStage = Invoke-PipelineAggregationStage -Context $Context -Commits $logAndDiffStage.Commits -RenameMap $logAndDiffStage.RenameMap
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StageSeconds' -Key 'Aggregation' -Value (Format-MetricValue -Value $stageStopwatch.Elapsed.TotalSeconds)
    $stageStopwatch.Restart()
    $strictResult = Invoke-PipelineStrictStage -Context $Context -ExecutionState $executionState -LogAndDiffStage $logAndDiffStage -AggregationStage $aggregationStage -Parallel $Parallel
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StageSeconds' -Key 'Strict' -Value (Format-MetricValue -Value $stageStopwatch.Elapsed.TotalSeconds)
    $stageStopwatch.Restart()

    Write-PipelineCsvArtifacts -Context $Context -OutDirectory $executionState.OutDirectory -CommitterRows $aggregationStage.CommitterRows -FileRows $aggregationStage.FileRows -CommitRows $aggregationStage.CommitRows -CouplingRows $aggregationStage.CouplingRows -StrictResult $strictResult -Encoding $Encoding
    Write-PipelineVisualizationArtifacts -Context $Context -OutDirectory $executionState.OutDirectory -CommitterRows $aggregationStage.CommitterRows -FileRows $aggregationStage.FileRows -CommitRows $aggregationStage.CommitRows -CouplingRows $aggregationStage.CouplingRows -StrictResult $strictResult -TopNCount $TopNCount -Encoding $Encoding
    $meta = Write-PipelineRunArtifacts -Context $Context -StartedAt $startedAt -ExecutionState $executionState -Parallel $Parallel -TopNCount $TopNCount -Encoding $Encoding -Commits $logAndDiffStage.Commits -FileRows $aggregationStage.FileRows -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -IgnoreWhitespace:$IgnoreWhitespace -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StageSeconds' -Key 'Artifacts' -Value (Format-MetricValue -Value $stageStopwatch.Elapsed.TotalSeconds)
    Set-NarutoPerformanceValue -Context $Context -SectionName 'StageSeconds' -Key 'Total' -Value (Format-MetricValue -Value $pipelineStopwatch.Elapsed.TotalSeconds)

    return (New-PipelineResultObject -OutDirectory $executionState.OutDirectory -CommitterRows $aggregationStage.CommitterRows -FileRows $aggregationStage.FileRows -CommitRows $aggregationStage.CommitRows -CouplingRows $aggregationStage.CouplingRows -RunMeta $meta)
}

if ($MyInvocation.InvocationName -ne '.')
{
    $cliContext = New-NarutoContext -SvnExecutable $SvnExecutable
    try
    {
        [void](Invoke-NarutoCodePipeline -Context $cliContext -RepoUrl $RepoUrl -FromRevision $FromRevision -ToRevision $ToRevision -SvnExecutable $SvnExecutable -OutDirectory $OutDirectory -Username $Username -Password $Password -NonInteractive:$NonInteractive -TrustServerCert:$TrustServerCert -Parallel $Parallel -IncludePaths $IncludePaths -ExcludePaths $ExcludePaths -IncludeExtensions $IncludeExtensions -ExcludeExtensions $ExcludeExtensions -TopNCount $TopNCount -Encoding $Encoding -IgnoreWhitespace:$IgnoreWhitespace -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines)
    }
    catch
    {
        $errorInfo = Get-NarutoErrorInfo -Context $cliContext -ErrorInput $_
        $exitCode = Resolve-NarutoExitCode -Category ([string]$errorInfo.Category)
        Write-Host ("[{0}] {1}" -f [string]$errorInfo.ErrorCode, [string]$errorInfo.Message)

        $reportOutDirectory = $OutDirectory
        if ([string]::IsNullOrWhiteSpace($reportOutDirectory))
        {
            $reportOutDirectory = Join-Path (Get-Location) 'NarutoCode_out'
        }
        $reportResult = Write-NarutoErrorReport -OutDirectory $reportOutDirectory -ErrorInfo $errorInfo -ExitCode $exitCode
        if (-not (Test-NarutoResultSuccess -Result $reportResult))
        {
            Write-NarutoDiagnostic -Context $cliContext -Level 'Warning' -ErrorCode ([string]$reportResult.ErrorCode) -Message ([string]$reportResult.Message)
        }
        exit $exitCode
    }
}


