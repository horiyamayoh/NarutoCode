@{
    # =====================================================================
    # PSScriptAnalyzer 設定ファイル — NarutoCode プロジェクト
    # =====================================================================
    #
    # ■ 用途
    #   1. 静的解析 (Invoke-ScriptAnalyzer)
    #   2. 自動フォーマット (Invoke-Formatter)
    #
    # ■ 使い方
    #   # 静的解析 — 違反の検出
    #   Invoke-ScriptAnalyzer -Path .\NarutoCode.ps1 `
    #       -Settings .\.PSScriptAnalyzerSettings.psd1
    #
    #   # 自動フォーマット — 厳密 Allman スタイルの適用
    #   $code = Get-Content -Path .\NarutoCode.ps1 -Raw
    #   $formatted = Invoke-Formatter -ScriptDefinition $code `
    #       -Settings .\.PSScriptAnalyzerSettings.psd1
    #   Set-Content -Path .\NarutoCode.ps1 -Value $formatted -NoNewline -Encoding UTF8
    #
    # ■ スタイル方針
    #   - 厳密な Allman スタイル（波括弧は必ず独立行）
    #   - 1行ブロックも展開する (IgnoreOneLineBlock = $false)
    #   - インデント: スペース 4 つ
    # =====================================================================

    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-Host はユーザー向け出力に使用しているため許可
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        # --- 開き波括弧: 厳密 Allman（必ず次の行に配置） ---
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $false    # Allman: 同じ行に置かない
            NewLineAfter       = $true     # 開き波括弧の後に改行を強制
            IgnoreOneLineBlock = $false    # 1行ブロックも展開する
        }

        # --- 閉じ波括弧 ---
        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true     # 閉じ波括弧の後に改行を強制
            IgnoreOneLineBlock = $false    # 1行ブロックも展開する
            NoEmptyLineBefore  = $false
        }

        # --- インデント: スペース 4 つ ---
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }

        # --- 空白の一貫性 ---
        PSUseConsistentWhitespace = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true   # 波括弧前のスペースをチェック
            CheckOpenParen                  = $true
            CheckOperator                   = $true
            CheckPipe                       = $true
            CheckPipeForRedundantWhitespace = $false
            CheckSeparator                  = $true
            CheckParameter                  = $false
        }

        # --- 代入文の揃え（無効: 好みが分かれるため） ---
        PSAlignAssignmentStatement = @{
            Enable         = $false
            CheckHashtable = $false
        }

        # --- セミコロンの末尾使用を禁止 ---
        PSAvoidSemicolonsAsLineTerminators = @{
            Enable = $true
        }

        # --- 末尾空白の禁止 ---
        PSAvoidTrailingWhitespace = @{
            Enable = $true
        }
    }
}
