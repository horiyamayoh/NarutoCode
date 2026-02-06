<#
.SYNOPSIS
NarutoCode.ps1 のユニットテスト (Pester 5.x)

.DESCRIPTION
SVN が存在しない環境でも動作するテストです。
スクリプト内部のヘルパー関数を dot-source で読み込み、
純粋ロジック部分を検証します。
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'

    # スクリプト内の関数だけを読み込む:
    # # region Utility ～ # endregion Utility を抽出して dot-source する
    $scriptContent = Get-Content -Path $script:ScriptPath -Raw -Encoding UTF8

    $regionPattern = '(?s)(# region Utility.*?# endregion Utility)'
    if ($scriptContent -match $regionPattern) {
        $functionBlock = $Matches[1]
        $script:SvnExecutable = 'svn'
        $tempFile = Join-Path $env:TEMP 'NarutoCode_functions_test.ps1'
        Set-Content -Path $tempFile -Value $functionBlock -Encoding UTF8
        . $tempFile
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
    else {
        throw "Could not extract function definitions from NarutoCode.ps1."
    }
}

# ============================================================
# ConvertTo-NormalizedExtension
# ============================================================
Describe 'ConvertTo-NormalizedExtension' {

    It '空配列を渡すと空配列を返す' {
        $result = ConvertTo-NormalizedExtension -Extensions @()
        $result | Should -BeNullOrEmpty
    }

    It '$null を渡すと空配列を返す' {
        $result = ConvertTo-NormalizedExtension -Extensions $null
        $result | Should -BeNullOrEmpty
    }

    It 'ドット付き拡張子を正規化する' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('.cs', '.PS1', '.txt'))
        $result -contains 'cs'  | Should -BeTrue
        $result -contains 'ps1' | Should -BeTrue
        $result -contains 'txt' | Should -BeTrue
    }

    It 'ドットなし拡張子もそのまま小文字に変換する' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('CS', 'Ps1'))
        $result -contains 'cs'  | Should -BeTrue
        $result -contains 'ps1' | Should -BeTrue
    }

    It '重複を排除する' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('.cs', 'cs', '.CS', 'CS'))
        $result.Count | Should -Be 1
        $result -contains 'cs' | Should -BeTrue
    }

    It '空白文字列やスペースのみの要素を無視する' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('cs', '', '  ', 'txt'))
        $result.Count | Should -Be 2
        $result -contains 'cs'  | Should -BeTrue
        $result -contains 'txt' | Should -BeTrue
    }

    It 'ドットだけの文字列を無視する' {
        $result = ConvertTo-NormalizedExtension -Extensions @('.')
        $result | Should -BeNullOrEmpty
    }
}

# ============================================================
# Test-ShouldCountFile
# ============================================================
Describe 'Test-ShouldCountFile' {

    Context 'フィルタなし（全ファイル対象）' {

        It '通常のファイルは $true を返す' {
            Test-ShouldCountFile -FilePath 'src/main.cs' | Should -BeTrue
        }

        It '拡張子なしファイルも $true を返す' {
            Test-ShouldCountFile -FilePath 'Makefile' | Should -BeTrue
        }
    }

    Context 'IncludeExtensions のみ指定' {

        It '含まれる拡張子のファイルは $true を返す' {
            Test-ShouldCountFile -FilePath 'src/main.cs' -IncludeExt @('cs') | Should -BeTrue
        }

        It '含まれない拡張子のファイルは $false を返す' {
            Test-ShouldCountFile -FilePath 'src/main.java' -IncludeExt @('cs') | Should -BeFalse
        }

        It '拡張子なしファイルは $false を返す' {
            Test-ShouldCountFile -FilePath 'Makefile' -IncludeExt @('cs') | Should -BeFalse
        }
    }

    Context 'ExcludeExtensions のみ指定' {

        It '除外拡張子のファイルは $false を返す' {
            Test-ShouldCountFile -FilePath 'src/main.designer.cs' -ExcludeExt @('cs') | Should -BeFalse
        }

        It '除外でない拡張子のファイルは $true を返す' {
            Test-ShouldCountFile -FilePath 'src/main.java' -ExcludeExt @('cs') | Should -BeTrue
        }

        It '拡張子なしファイルは $true を返す' {
            Test-ShouldCountFile -FilePath 'Makefile' -ExcludeExt @('cs') | Should -BeTrue
        }
    }

    Context 'ExcludePaths 指定' {

        It 'ワイルドカードに一致するパスは $false を返す' {
            Test-ShouldCountFile -FilePath 'src/Generated/Model.cs' -ExcludePathPatterns @('*Generated*') | Should -BeFalse
        }

        It 'ワイルドカードに一致しないパスは $true を返す' {
            Test-ShouldCountFile -FilePath 'src/Services/Service.cs' -ExcludePathPatterns @('*Generated*') | Should -BeTrue
        }

        It '*.min.js パターンで minified ファイルを除外する' {
            Test-ShouldCountFile -FilePath 'wwwroot/app.min.js' -ExcludePathPatterns @('*.min.js') | Should -BeFalse
        }
    }

    Context 'Include と Exclude の組み合わせ' {

        It 'Include に含まれ Exclude にも含まれる場合は $false を返す' {
            Test-ShouldCountFile -FilePath 'test.cs' -IncludeExt @('cs','txt') -ExcludeExt @('cs') | Should -BeFalse
        }

        It 'Include に含まれ Exclude に含まれない場合は $true を返す' {
            Test-ShouldCountFile -FilePath 'test.txt' -IncludeExt @('cs','txt') -ExcludeExt @('cs') | Should -BeTrue
        }
    }

    Context 'ExcludePaths と拡張子フィルタの組み合わせ' {

        It 'パス除外が優先される' {
            Test-ShouldCountFile -FilePath 'Generated/code.cs' -IncludeExt @('cs') -ExcludePathPatterns @('Generated/*') | Should -BeFalse
        }

        It 'パスが一致しなければ拡張子フィルタが適用される' {
            Test-ShouldCountFile -FilePath 'src/code.cs' -IncludeExt @('cs') -ExcludePathPatterns @('Generated/*') | Should -BeTrue
        }
    }
}

# ============================================================
# ConvertFrom-SvnXmlText
# ============================================================
Describe 'ConvertFrom-SvnXmlText' {

    It '正常な XML をパースできる' {
        $xml = ConvertFrom-SvnXmlText -Text '<?xml version="1.0"?><log><logentry revision="100"><author>user1</author><date>2025-01-01T00:00:00Z</date><msg>test commit</msg></logentry></log>'
        $xml | Should -Not -BeNullOrEmpty
        $xml.log.logentry.revision | Should -Be '100'
        $xml.log.logentry.author | Should -Be 'user1'
    }

    It 'XML の前に警告テキストがあってもパースできる' {
        $text = "WARNING: some svn warning`n<?xml version=""1.0""?><log><logentry revision=""200""><author>dev</author><date>2025-06-01T00:00:00Z</date><msg>fix</msg></logentry></log>"
        $xml = ConvertFrom-SvnXmlText -Text $text
        $xml.log.logentry.revision | Should -Be '200'
    }

    It 'log タグから始まる場合もパースできる' {
        $xml = ConvertFrom-SvnXmlText -Text '<log><logentry revision="300"><author>admin</author><date>2025-01-01T00:00:00Z</date><msg>init</msg></logentry></log>'
        $xml.log.logentry.revision | Should -Be '300'
    }

    It 'info タグで始まる XML もパースできる' {
        $xml = ConvertFrom-SvnXmlText -Text '<info><entry revision="1"><url>http://example.com/svn</url></entry></info>'
        $xml.info.entry.url | Should -Be 'http://example.com/svn'
    }

    It '不正な XML はエラーを投げる' {
        { ConvertFrom-SvnXmlText -Text 'this is not xml at all' } | Should -Throw
    }
}

# ============================================================
# Write-FileIfRequested
# ============================================================
Describe 'Write-FileIfRequested' {

    It 'ファイルに内容を書き込める' {
        $tempPath = Join-Path $env:TEMP ('naruto_test_' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            Write-FileIfRequested -FilePath $tempPath -Content 'Hello World'
            Test-Path $tempPath | Should -BeTrue
            (Get-Content $tempPath -Raw).Trim() | Should -Be 'Hello World'
        }
        finally {
            Remove-Item $tempPath -ErrorAction SilentlyContinue
        }
    }

    It '存在しないディレクトリを自動作成する' {
        $tempDir = Join-Path $env:TEMP ('naruto_test_' + [guid]::NewGuid().ToString('N'))
        $tempPath = Join-Path (Join-Path $tempDir 'sub') 'output.txt'
        try {
            Write-FileIfRequested -FilePath $tempPath -Content 'nested content'
            Test-Path $tempPath | Should -BeTrue
            (Get-Content $tempPath -Raw).Trim() | Should -Be 'nested content'
        }
        finally {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
# Invoke-SvnCommand (実在コマンドで代替テスト)
# ============================================================
Describe 'Invoke-SvnCommand' {

    It 'プロセス正常終了時に stdout を返す' {
        $script:SvnExecutable = 'powershell'
        try {
            $result = Invoke-SvnCommand -Arguments @('-Command', '"Write-Output hello"') -ErrorContext 'test'
            $result.Trim() | Should -Be 'hello'
        }
        finally {
            $script:SvnExecutable = 'svn'
        }
    }

    It 'プロセス異常終了時にエラーを投げる' {
        $script:SvnExecutable = 'powershell'
        try {
            { Invoke-SvnCommand -Arguments @('-Command', '"exit 1"') -ErrorContext 'test fail' } | Should -Throw
        }
        finally {
            $script:SvnExecutable = 'svn'
        }
    }
}

# ============================================================
# Resolve-SvnTargetUrl (URL バリデーション)
# ============================================================
Describe 'Resolve-SvnTargetUrl' {

    It 'ローカルパスを指定するとエラーを投げる' {
        { Resolve-SvnTargetUrl -Target 'C:\work\project' } | Should -Throw
    }

    It '相対パスを指定するとエラーを投げる' {
        { Resolve-SvnTargetUrl -Target '.\myrepo' } | Should -Throw
    }

    It 'UNC パスを指定するとエラーを投げる' {
        { Resolve-SvnTargetUrl -Target '\\server\share\repo' } | Should -Throw
    }
}

# ============================================================
# スクリプト パラメータ定義の検証
# ============================================================
Describe 'NarutoCode.ps1 パラメータ定義' {

    BeforeAll {
        $script:cmd = Get-Command $script:ScriptPath
    }

    It 'Path パラメータが必須である' {
        $param = $script:cmd.Parameters['Path']
        $param | Should -Not -BeNullOrEmpty
        $mandatoryAttr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $mandatoryAttr.Mandatory | Should -BeTrue
    }

    It 'FromRevision パラメータが必須である' {
        $param = $script:cmd.Parameters['FromRevision']
        $param | Should -Not -BeNullOrEmpty
        $mandatoryAttr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $mandatoryAttr.Mandatory | Should -BeTrue
    }

    It 'ToRevision パラメータが必須である' {
        $param = $script:cmd.Parameters['ToRevision']
        $param | Should -Not -BeNullOrEmpty
        $mandatoryAttr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $mandatoryAttr.Mandatory | Should -BeTrue
    }

    It 'FromRevision のエイリアスに Pre, Start, StartRevision, From がある' {
        $aliases = $script:cmd.Parameters['FromRevision'].Aliases
        $aliases -contains 'Pre'           | Should -BeTrue
        $aliases -contains 'Start'         | Should -BeTrue
        $aliases -contains 'StartRevision' | Should -BeTrue
        $aliases -contains 'From'          | Should -BeTrue
    }

    It 'ToRevision のエイリアスに Post, End, EndRevision, To がある' {
        $aliases = $script:cmd.Parameters['ToRevision'].Aliases
        $aliases -contains 'Post'        | Should -BeTrue
        $aliases -contains 'End'         | Should -BeTrue
        $aliases -contains 'EndRevision' | Should -BeTrue
        $aliases -contains 'To'          | Should -BeTrue
    }

    It 'Author のエイリアスに Name, User がある' {
        $aliases = $script:cmd.Parameters['Author'].Aliases
        $aliases -contains 'Name' | Should -BeTrue
        $aliases -contains 'User' | Should -BeTrue
    }

    It 'すべてのスイッチパラメータが存在する' {
        $switches = @('IgnoreSpaceChange','IgnoreAllSpace','IgnoreEolStyle',
                      'IncludeProperties','ForceBinary','ShowPerRevision','NoProgress')
        foreach ($s in $switches) {
            $script:cmd.Parameters[$s] | Should -Not -BeNullOrEmpty
            $script:cmd.Parameters[$s].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    It '配列パラメータ (string[]) が存在する' {
        $arrays = @('IncludeExtensions','ExcludeExtensions','ExcludePaths')
        foreach ($a in $arrays) {
            $script:cmd.Parameters[$a] | Should -Not -BeNullOrEmpty
            $script:cmd.Parameters[$a].ParameterType.Name | Should -Be 'String[]'
        }
    }

    It '出力パラメータ (string) が存在する' {
        $outputs = @('OutputCsv','OutputJson','OutputMarkdown')
        foreach ($o in $outputs) {
            $script:cmd.Parameters[$o] | Should -Not -BeNullOrEmpty
            $script:cmd.Parameters[$o].ParameterType.Name | Should -Be 'String'
        }
    }
}

# ============================================================
# スクリプト実行: SVN が見つからない場合
# ============================================================
Describe 'NarutoCode.ps1 実行テスト' {

    It 'SvnExecutable に存在しないコマンドを指定するとエラーになる' {
        {
            & $script:ScriptPath `
                -Path 'https://svn.example.com/repos/proj/trunk' `
                -FromRevision 200 -ToRevision 250 `
                -SvnExecutable 'nonexistent_svn_command_xyz' `
                -NoProgress `
                -ErrorAction Stop
        } | Should -Throw -ExpectedMessage '*not found*'
    }
}
