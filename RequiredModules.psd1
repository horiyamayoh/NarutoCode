@{
    # NarutoCode 開発で使用する PowerShell モジュールのバージョン定義
    # Setup.ps1 がこのファイルを読み込んでインストールします

    Modules = @(
        @{
            Name            = 'Pester'
            RequiredVersion = '5.7.1'
            Description     = 'PowerShell テストフレームワーク'
        }
        @{
            Name            = 'PSScriptAnalyzer'
            RequiredVersion = '1.24.0'
            Description     = 'PowerShell 静的解析 / フォーマッタ'
        }
    )
}
