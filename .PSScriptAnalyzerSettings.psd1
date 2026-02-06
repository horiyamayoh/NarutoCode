@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-Host はユーザー向け出力に使用しているため許可
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        # --- Allman スタイル: 開き波括弧を次の行に配置 ---
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $false
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        # --- インデント: スペース4つ ---
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
            CheckOpenBrace                  = $false  # Allman では開き波括弧前の空白チェックを無効化
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
