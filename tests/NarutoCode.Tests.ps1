<#
.SYNOPSIS
Pester tests for NarutoCode Phase 1.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'
    . $script:ScriptPath -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 1 -ToRevision 1
    $script:TestContext = New-NarutoContext -SvnExecutable 'svn'
    $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
}

Describe 'ConvertTo-NormalizedExtension' {
    It 'returns empty for null/empty' {
        @(ConvertTo-NormalizedExtension -Extensions $null).Count | Should -Be 0
        @(ConvertTo-NormalizedExtension -Extensions @()).Count | Should -Be 0
    }

    It 'normalizes dot and case' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('.CS', 'Ps1', '.txt'))
        $result -contains 'cs' | Should -BeTrue
        $result -contains 'ps1' | Should -BeTrue
        $result -contains 'txt' | Should -BeTrue
    }

    It 'removes duplicates' {
        $result = @(ConvertTo-NormalizedExtension -Extensions @('cs', '.cs', 'CS'))
        $result.Count | Should -Be 1
    }
}

Describe 'Test-ShouldCountFile' {
    It 'applies include extension' {
        Test-ShouldCountFile -FilePath 'src/a.cs' -IncludeExtensions @('cs') | Should -BeTrue
        Test-ShouldCountFile -FilePath 'src/a.java' -IncludeExtensions @('cs') | Should -BeFalse
    }

    It 'applies exclude extension' {
        Test-ShouldCountFile -FilePath 'src/a.cs' -ExcludeExtensions @('cs') | Should -BeFalse
        Test-ShouldCountFile -FilePath 'src/a.java' -ExcludeExtensions @('cs') | Should -BeTrue
    }

    It 'applies include and exclude path patterns' {
        Test-ShouldCountFile -FilePath 'src/generated/a.cs' -IncludePathPatterns @('src/*') -ExcludePathPatterns @('*generated*') | Should -BeFalse
        Test-ShouldCountFile -FilePath 'src/core/a.cs' -IncludePathPatterns @('src/*') -ExcludePathPatterns @('*generated*') | Should -BeTrue
    }
}

Describe 'ConvertFrom-SvnLogXml' {
    It 'parses revisions, actions, and copyfrom metadata' {
        $xml = @"
<log>
  <logentry revision="10">
    <author>alice</author>
    <date>2026-01-01T00:00:00Z</date>
    <msg>init</msg>
    <paths>
      <path action="M">/trunk/src/Main.cs</path>
      <path action="R" copyfrom-path="/branches/old/Util.cs" copyfrom-rev="9">/trunk/src/Util.cs</path>
    </paths>
  </logentry>
</log>
"@
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits.Count | Should -Be 1
        $commits[0].Revision | Should -Be 10
        $commits[0].ChangedPaths.Count | Should -Be 2
        $commits[0].ChangedPaths[1].Action | Should -Be 'R'
        $commits[0].ChangedPaths[1].CopyFromRev | Should -Be 9
    }

    It 'uses (unknown) for missing author' {
        $xml = @"
<log>
  <logentry revision="11">
    <date>2026-01-02T00:00:00Z</date>
    <msg>no author</msg>
    <paths><path action="A">/trunk/readme.md</path></paths>
  </logentry>
</log>
"@
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits[0].Author | Should -Be '(unknown)'
    }
}

Describe 'ConvertFrom-SvnUnifiedDiff' {
    It 'counts added and deleted lines with hunk metadata' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -10,2 +10,3 @@
 old
-new
+new
+extra
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff
        $parsed['trunk/src/Main.cs'].AddedLines | Should -Be 2
        $parsed['trunk/src/Main.cs'].DeletedLines | Should -Be 1
        $parsed['trunk/src/Main.cs'].Hunks.Count | Should -Be 1
        $parsed['trunk/src/Main.cs'].Hunks[0].OldStart | Should -Be 10
    }

    It 'detects binary diff markers' {
        $diff = @"
Index: trunk/bin/data.bin
===================================================================
Cannot display: file marked as a binary type.
svn:mime-type = application/octet-stream
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff
        $parsed['trunk/bin/data.bin'].IsBinary | Should -BeTrue
    }
}

Describe 'Get-SvnUnifiedDiffHeaderSectionList' {
    It 'extracts old/new path and revision per index section' {
        $diff = @"
Index: src/new.cs
===================================================================
--- src/old.cs	(revision 9)
+++ src/new.cs	(revision 10)
@@ -1 +1 @@
-old
+new
Index: src/add.cs
===================================================================
--- src/add.cs	(nonexistent)
+++ src/add.cs	(revision 10)
@@ -0,0 +1 @@
+line
"@
        $sections = @(Get-SvnUnifiedDiffHeaderSectionList -DiffText $diff)
        $sections.Count | Should -Be 2
        $sections[0].IndexPath | Should -Be 'src/new.cs'
        $sections[0].OldPath | Should -Be 'src/old.cs'
        $sections[0].OldRevision | Should -Be 9
        $sections[0].NewPath | Should -Be 'src/new.cs'
        $sections[0].NewRevision | Should -Be 10
        $sections[1].IndexPath | Should -Be 'src/add.cs'
        $sections[1].OldPath | Should -BeNullOrEmpty
        $sections[1].OldRevision | Should -BeNullOrEmpty
        $sections[1].NewPath | Should -Be 'src/add.cs'
        $sections[1].NewRevision | Should -Be 10
    }
}

Describe 'Comment syntax profile and line mask' {
    It 'resolves profile by extension' {
        (Get-CommentSyntaxProfileByPath -FilePath 'src/main.c').Name | Should -Be 'CStyle'
        (Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs').Name | Should -Be 'CSharpStyle'
        (Get-CommentSyntaxProfileByPath -FilePath 'src/main.ts').Name | Should -Be 'JsTsStyle'
        (Get-CommentSyntaxProfileByPath -FilePath 'scripts/build.ps1').Name | Should -Be 'PowerShellStyle'
        (Get-CommentSyntaxProfileByPath -FilePath 'config/app.ini').Name | Should -Be 'IniStyle'
    }

    It 'returns null for undefined extension' {
        Get-CommentSyntaxProfileByPath -FilePath 'docs/readme.txt' | Should -BeNullOrEmpty
    }

    It 'marks comment-only lines for CSharpStyle and ignores comment tokens in strings' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs'
        $lines = @(
            '// line comment'
            'var x = 1; // trailing comment'
            '/* block start'
            'block middle'
            'block end */'
            'var s = "//not-comment";'
            'return x;'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($true, $false, $true, $true, $true, $false, $false)
    }

    It 'does not treat C# verbatim multi-line string lines as comment-only' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs'
        $lines = @(
            'var text = @"'
            '// inside verbatim'
            'line2";'
            '// real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($false, $false, $false, $true)
    }

    It 'does not treat PowerShell here-string lines as comment-only' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'scripts/build.ps1'
        $lines = @(
            '@"'
            '# inside here-string'
            '"@'
            '# real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($false, $false, $false, $true)
    }

    It 'does not skip YAML single-quote string ending with backslash' {
        $iniProfile = Get-CommentSyntaxProfileByPath -FilePath 'config/app.yaml'
        $lines = @(
            "key: 'path\to\dir'"
            '# real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $iniProfile
        @($mask) | Should -Be @($false, $true)
    }

    It 'does not escape next line start in JS template literal ending with backslash' {
        $jsProfile = Get-CommentSyntaxProfileByPath -FilePath 'src/app.js'
        $lines = @(
            'var t = `line1\'
            '// still template'
            '`;'
            '// real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $jsProfile
        @($mask) | Should -Be @($false, $false, $false, $true)
    }

    It 'marks comment-only lines for PowerShellStyle and IniStyle' {
        $psProfile = Get-CommentSyntaxProfileByPath -FilePath 'scripts/task.ps1'
        $psLines = @(
            '# line comment'
            'Write-Host "hello" # trailing'
            '<#'
            'inside block'
            '#>'
        )
        $psMask = ConvertTo-CommentOnlyLineMask -Lines $psLines -CommentSyntaxProfile $psProfile
        @($psMask) | Should -Be @($true, $false, $true, $true, $true)

        $iniProfile = Get-CommentSyntaxProfileByPath -FilePath 'config/app.ini'
        $iniLines = @(
            '# hash comment'
            '; semicolon comment'
            'key=value ; trailing'
            '   '
        )
        $iniMask = ConvertTo-CommentOnlyLineMask -Lines $iniLines -CommentSyntaxProfile $iniProfile
        @($iniMask) | Should -Be @($true, $true, $false, $false)
    }

    It 'does not treat C# raw string """ content as comment-only' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs'
        $lines = @(
            'var s = """'
            '// inside raw string'
            'line with "embedded"'
            '"""'
            '// real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask)[0] | Should -Be $false
        @($mask)[1] | Should -Be $false
        @($mask)[2] | Should -Be $false
        @($mask)[3] | Should -Be $false
        @($mask)[4] | Should -Be $true
    }

    It 'handles C# verbatim @" with doubled-quote escape' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs'
        $lines = @(
            'var s = @"He said ""hello""";'
            '// real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($false, $true)
    }

    It 'marks remaining lines as code when multi-line string never closes' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'src/main.cs'
        $lines = @(
            'var s = @"'
            '// still inside string'
            '# also inside'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($false, $false, $false)
    }

    It 'does not treat TOML multi-line string content as comment-only' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'config/app.toml'
        $lines = @(
            'desc = """'
            '# not a comment'
            'content'
            '"""'
            '# real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask)[0] | Should -Be $false
        @($mask)[1] | Should -Be $false
        @($mask)[2] | Should -Be $false
        @($mask)[3] | Should -Be $false
        @($mask)[4] | Should -Be $true
    }

    It 'does not close PowerShell here-string when "@ appears mid-line' {
        $profile = Get-CommentSyntaxProfileByPath -FilePath 'scripts/build.ps1'
        $lines = @(
            '@"'
            'user"@example.com'
            '"@'
            '# real comment'
        )
        $mask = ConvertTo-CommentOnlyLineMask -Lines $lines -CommentSyntaxProfile $profile
        @($mask) | Should -Be @($false, $false, $false, $true)
    }

    It 'returns empty mask for null or empty input' {
        @(ConvertTo-CommentOnlyLineMask -Lines @() -CommentSyntaxProfile ([pscustomobject]@{ LineCommentTokens = @('#') })).Count | Should -Be 0
        @(ConvertTo-CommentOnlyLineMask -Lines $null -CommentSyntaxProfile ([pscustomobject]@{ LineCommentTokens = @('#') })).Count | Should -Be 0
        @(ConvertTo-CommentOnlyLineMask -Lines @('# comment') -CommentSyntaxProfile $null).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-SvnUnifiedDiff comment exclusion' {
    It 'excludes comment-only changes from added/deleted counts and effective segments' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -1,3 +1,3 @@
 keep1
-// old comment
+// new comment
 keep2
"@
        $lineMaskByPath = @{
            'trunk/src/Main.cs' = [pscustomobject]@{
                OldMask = @($false, $true, $false)
                NewMask = @($false, $true, $false)
            }
        }
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 2 -ExcludeCommentOnlyLines -LineMaskByPath $lineMaskByPath
        $stat = $parsed['trunk/src/Main.cs']
        $stat.AddedLines | Should -Be 0
        $stat.DeletedLines | Should -Be 0
        $stat.Hunks.Count | Should -Be 1
        @($stat.Hunks[0].EffectiveSegments).Count | Should -Be 0
    }

    It 'keeps non-comment changes in mixed hunk and builds effective segment' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -1,4 +1,4 @@
 keep1
-// old comment
+// new comment
-old code
+new code
 keep2
"@
        $lineMaskByPath = @{
            'trunk/src/Main.cs' = [pscustomobject]@{
                OldMask = @($false, $true, $false, $false)
                NewMask = @($false, $true, $false, $false)
            }
        }
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 2 -ExcludeCommentOnlyLines -LineMaskByPath $lineMaskByPath
        $stat = $parsed['trunk/src/Main.cs']
        $stat.AddedLines | Should -Be 1
        $stat.DeletedLines | Should -Be 1
        @($stat.Hunks[0].EffectiveSegments).Count | Should -Be 1
        $stat.Hunks[0].EffectiveSegments[0].OldStart | Should -Be 3
        $stat.Hunks[0].EffectiveSegments[0].OldCount | Should -Be 1
        $stat.Hunks[0].EffectiveSegments[0].NewStart | Should -Be 3
        $stat.Hunks[0].EffectiveSegments[0].NewCount | Should -Be 1
    }

    It 'keeps behavior unchanged when extension is undefined' {
        $diff = @"
Index: trunk/src/unknown.extx
===================================================================
--- trunk/src/unknown.extx	(revision 1)
+++ trunk/src/unknown.extx	(revision 2)
@@ -1 +1 @@
-old
+new
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -ExcludeCommentOnlyLines
        $parsed['trunk/src/unknown.extx'].AddedLines | Should -Be 1
        $parsed['trunk/src/unknown.extx'].DeletedLines | Should -Be 1
    }
}

Describe 'ConvertFrom-SvnBlameXml' {
    It 'parses totals and per-revision/author counts' {
        $xml = @"
<blame>
  <target path="trunk/src/Main.cs">
    <entry line-number="1"><commit revision="10"><author>alice</author></commit></entry>
    <entry line-number="2"><commit revision="11"><author>bob</author></commit></entry>
    <entry line-number="3"><commit revision="10"><author>alice</author></commit></entry>
  </target>
</blame>
"@
        $summary = ConvertFrom-SvnBlameXml -XmlText $xml
        $summary.LineCountTotal | Should -Be 3
        $summary.LineCountByRevision[10] | Should -Be 2
        $summary.LineCountByAuthor['alice'] | Should -Be 2
    }
}

Describe 'Metrics functions' {
    BeforeAll {
        $script:mockCommits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'fix #123'
                ChangedPathsFiltered = @(
                    [pscustomobject]@{ Path='src/A.cs'; Action='M' },
                    [pscustomobject]@{ Path='src/B.cs'; Action='A' }
                )
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{ AddedLines=3; DeletedLines=1; Hunks=@(); IsBinary=$false }
                    'src/B.cs' = [pscustomobject]@{ AddedLines=2; DeletedLines=0; Hunks=@(); IsBinary=$false }
                }
                FilesChanged = @('src/A.cs','src/B.cs')
                AddedLines = 5
                DeletedLines = 1
                Churn = 6
                Entropy = 0.9
                MsgLen = 8
                MessageShort = 'fix #123'
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'bob'
                Date = [datetime]'2026-01-02'
                Message = 'merge branch'
                ChangedPathsFiltered = @([pscustomobject]@{ Path='src/A.cs'; Action='M' })
                FileDiffStats = @{ 'src/A.cs' = [pscustomobject]@{ AddedLines=1; DeletedLines=2; Hunks=@(); IsBinary=$false } }
                FilesChanged = @('src/A.cs')
                AddedLines = 1
                DeletedLines = 2
                Churn = 3
                Entropy = 0.0
                MsgLen = 12
                MessageShort = 'merge branch'
            }
        )
    }

    It 'computes committer metrics' {
        $rows = @(Get-CommitterMetric -Commits $script:mockCommits)
        $alice = $rows | Where-Object { $_.'作者' -eq 'alice' }
        $alice.'コミット数' | Should -Be 1
        $alice.'追加行数' | Should -Be 5
        $alice.'追加アクション数' | Should -Be 1
        $alice.'課題ID言及数' | Should -Be 1
    }

    It 'computes file metrics and hotspot rank' {
        $rows = @(Get-FileMetric -Commits $script:mockCommits)
        $a = $rows | Where-Object { $_.'ファイルパス' -eq 'src/A.cs' }
        $a.'コミット数' | Should -Be 2
        $a.'作者数' | Should -Be 2
        $a.'ホットスポットスコア' | Should -Be 56
    }

    It 'computes co-change metrics' {
        $rows = @(Get-CoChangeMetric -Commits $script:mockCommits -TopNCount 10)
        $rows.Count | Should -Be 1
        $rows[0].'ファイルA' | Should -Be 'src/A.cs'
        $rows[0].'ファイルB' | Should -Be 'src/B.cs'
        $rows[0].'共変更回数' | Should -Be 1
    }
}
Describe 'NarutoCode.ps1 parameter definition' {
    BeforeAll {
        $script:cmd = Get-Command $script:ScriptPath
    }

    It 'has required RepoUrl/FromRevision/ToRevision with compatibility aliases' {
        $script:cmd.Parameters['RepoUrl'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['RepoUrl'].Aliases -contains 'Path' | Should -BeTrue

        $script:cmd.Parameters['FromRevision'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['FromRevision'].Aliases -contains 'FromRev' | Should -BeTrue
        $script:cmd.Parameters['FromRevision'].Aliases -contains 'From' | Should -BeTrue

        $script:cmd.Parameters['ToRevision'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['ToRevision'].Aliases -contains 'ToRev' | Should -BeTrue
        $script:cmd.Parameters['ToRevision'].Aliases -contains 'To' | Should -BeTrue
    }

    It 'contains new Phase 1 parameters' {
        $names = @('OutDirectory','Username','Password','NonInteractive','TrustServerCert','Parallel','IncludePaths','IgnoreWhitespace','ExcludeCommentOnlyLines','TopNCount','Encoding')
        foreach ($name in $names) {
            $script:cmd.Parameters[$name] | Should -Not -BeNullOrEmpty
        }
        $script:cmd.Parameters['Password'].ParameterType.Name | Should -Be 'SecureString'
        $script:cmd.Parameters['NonInteractive'].ParameterType.Name | Should -Be 'SwitchParameter'
        $script:cmd.Parameters['Parallel'].ParameterType.Name | Should -Be 'Int32'
    }
}

Describe 'Invoke-SvnCommand' {
    It 'returns stdout on success' {
        $script:TestContext.Runtime.SvnExecutable = 'powershell'
        try {
            $text = Invoke-SvnCommand -Arguments @('-NoProfile','-Command','Write-Output hello') -ErrorContext 'test'
            $text.Trim() | Should -Be 'hello'
        }
        finally {
            $script:TestContext.Runtime.SvnExecutable = 'svn'
        }
    }

    It 'throws on non-zero exit code' {
        $script:TestContext.Runtime.SvnExecutable = 'powershell'
        try {
            { Invoke-SvnCommand -Arguments @('-NoProfile','-Command','exit 1') -ErrorContext 'test fail' } | Should -Throw
        }
        finally {
            $script:TestContext.Runtime.SvnExecutable = 'svn'
        }
    }
}

Describe 'ConvertTo-PathKey' {
    It 'trims leading slash and normalizes backslash' {
        ConvertTo-PathKey -Path '/trunk/src/Main.cs' | Should -Be 'trunk/src/Main.cs'
        ConvertTo-PathKey -Path 'trunk\src\Main.cs' | Should -Be 'trunk/src/Main.cs'
    }

    It 'strips ./ prefix' {
        ConvertTo-PathKey -Path './src/Main.cs' | Should -Be 'src/Main.cs'
    }

    It 'strips URL scheme prefix and returns path portion' {
        ConvertTo-PathKey -Path 'https://svn.example.com/repos/trunk/File.cs' | Should -Be 'repos/trunk/File.cs'
    }

    It 'returns empty string for null/blank' {
        ConvertTo-PathKey -Path $null | Should -Be ''
        ConvertTo-PathKey -Path '   ' | Should -Be ''
    }
}

Describe 'ConvertTo-NormalizedPatternList' {
    It 'returns empty for null/empty' {
        @(ConvertTo-NormalizedPatternList -Patterns $null).Count | Should -Be 0
        @(ConvertTo-NormalizedPatternList -Patterns @()).Count | Should -Be 0
    }

    It 'trims whitespace and removes blanks' {
        $result = @(ConvertTo-NormalizedPatternList -Patterns @('  src/*  ', '', '  ', 'tests/*'))
        $result.Count | Should -Be 2
        $result[0] | Should -Be 'src/*'
        $result[1] | Should -Be 'tests/*'
    }

    It 'deduplicates' {
        $result = @(ConvertTo-NormalizedPatternList -Patterns @('src/*', 'src/*', 'tests/*'))
        $result.Count | Should -Be 2
    }
}

Describe 'Get-TextEncoding' {
    It 'returns UTF8 without BOM' {
        $enc = Get-TextEncoding -Name 'UTF8'
        $enc | Should -BeOfType [System.Text.UTF8Encoding]
        # UTF8 without BOM = preamble is empty
        $enc.GetPreamble().Length | Should -Be 0
    }

    It 'returns UTF8 with BOM' {
        $enc = Get-TextEncoding -Name 'UTF8BOM'
        $enc | Should -BeOfType [System.Text.UTF8Encoding]
        $enc.GetPreamble().Length | Should -BeGreaterThan 0
    }

    It 'returns Unicode' {
        $enc = Get-TextEncoding -Name 'Unicode'
        $enc.EncodingName | Should -Match 'Unicode'
    }

    It 'returns ASCII' {
        $enc = Get-TextEncoding -Name 'ASCII'
        $enc.EncodingName | Should -Match 'ASCII'
    }

    It 'throws for unsupported encoding' {
        $thrown = $null
        try
        {
            [void](Get-TextEncoding -Name 'EBCDIC')
        }
        catch
        {
            $thrown = $_.Exception
        }
        $thrown | Should -Not -BeNullOrEmpty
        [string]$thrown.Data['ErrorCode'] | Should -Be 'INPUT_UNSUPPORTED_ENCODING'
        [string]$thrown.Data['Category'] | Should -Be 'INPUT'
        [string]$thrown.Message | Should -BeLike '*未対応*'
    }
}

Describe 'Get-Entropy' {
    It 'returns 0 for empty input' {
        Get-Entropy -Values @() | Should -Be 0.0
    }

    It 'returns 0 for single value' {
        Get-Entropy -Values @(5.0) | Should -Be 0.0
    }

    It 'returns 1.0 for two equal values (1 bit of entropy)' {
        $e = Get-Entropy -Values @(1.0, 1.0)
        [Math]::Round($e, 4) | Should -Be 1.0
    }

    It 'returns log2(N) for N equal values' {
        # 4 equal values => log2(4) = 2.0
        $e = Get-Entropy -Values @(1.0, 1.0, 1.0, 1.0)
        [Math]::Round($e, 4) | Should -Be 2.0
    }

    It 'returns less than log2(N) for skewed values' {
        # One large, one small => less than 1.0
        $e = Get-Entropy -Values @(100.0, 1.0)
        $e | Should -BeLessThan 1.0
        $e | Should -BeGreaterThan 0.0
    }
}

Describe 'Get-MessageMetricCount' {
    It 'counts issue IDs (#123 and JIRA-style)' {
        $m = Get-MessageMetricCount -Message 'fix #123 and PROJ-456'
        $m.IssueIdMentionCount | Should -Be 2
    }

    It 'counts fix keywords' {
        $m = Get-MessageMetricCount -Message 'Fix a bug and hotfix'
        $m.FixKeywordCount | Should -Be 3  # fix, bug, hotfix
    }

    It 'counts revert keywords' {
        $m = Get-MessageMetricCount -Message 'Revert the rollback from yesterday'
        $m.RevertKeywordCount | Should -Be 2
    }

    It 'counts merge keywords' {
        $m = Get-MessageMetricCount -Message 'Merge branch feature into trunk'
        $m.MergeKeywordCount | Should -Be 1
    }

    It 'returns all zeros for null/empty message' {
        $m = Get-MessageMetricCount -Message $null
        $m.IssueIdMentionCount | Should -Be 0
        $m.FixKeywordCount | Should -Be 0
        $m.RevertKeywordCount | Should -Be 0
        $m.MergeKeywordCount | Should -Be 0
    }
}

Describe 'Join-CommandArgument' {
    It 'joins simple arguments' {
        Join-CommandArgument -Arguments @('log', '--xml', '-r', '1:10') | Should -Be 'log --xml -r 1:10'
    }

    It 'quotes arguments with spaces' {
        $result = Join-CommandArgument -Arguments @('diff', '--extensions', '--ignore-all-space --ignore-eol-style')
        $result | Should -Match '"--ignore-all-space --ignore-eol-style"'
    }

    It 'handles null arguments' {
        # null is converted to empty string by PowerShell, so result has extra space
        $result = Join-CommandArgument -Arguments @('a', $null, 'b')
        $result | Should -Match '^a\s+b$'
    }
}

Describe 'ConvertTo-PlainText' {
    It 'converts SecureString back to plain text' {
        $sec = ConvertTo-SecureString 'MyP@ssword' -AsPlainText -Force
        ConvertTo-PlainText -SecureValue $sec | Should -Be 'MyP@ssword'
    }

    It 'returns null for null input' {
        ConvertTo-PlainText -SecureValue $null | Should -Be $null
    }
}

Describe 'Write-TextFile and Write-CsvFile' {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP ('narutocode_writetest_' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        Remove-Item -Path $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates directory and file' {
        $filePath = Join-Path (Join-Path $script:testDir 'sub') 'out.txt'
        Write-TextFile -FilePath $filePath -Content 'hello world' -EncodingName 'UTF8'
        Test-Path $filePath | Should -BeTrue
        (Get-Content -Path $filePath -Raw).Trim() | Should -Be 'hello world'
    }

    It 'Write-CsvFile outputs header + data rows' {
        $filePath = Join-Path $script:testDir 'data.csv'
        $rows = @(
            [pscustomobject]@{ Name = 'alice'; Count = 1 },
            [pscustomobject]@{ Name = 'bob'; Count = 2 }
        )
        Write-CsvFile -FilePath $filePath -Rows $rows -Headers @('Name','Count')
        Test-Path $filePath | Should -BeTrue
        $content = Get-Content -Path $filePath -Encoding UTF8
        $content.Count | Should -BeGreaterOrEqual 3  # header + 2 data rows
        $content[0] | Should -Match 'Name'
        $content[0] | Should -Match 'Count'
    }

    It 'Write-CsvFile outputs header-only for empty rows' {
        $filePath = Join-Path $script:testDir 'empty.csv'
        Write-CsvFile -FilePath $filePath -Rows @() -Headers @('Col1','Col2')
        Test-Path $filePath | Should -BeTrue
        $raw = Get-Content -Path $filePath -Raw -Encoding UTF8
        $raw | Should -Match 'Col1'
        $raw | Should -Match 'Col2'
    }

    It 'Write-TextFile resolves relative path correctly' {
        # Create a temp base dir and a subdirectory to Push-Location into
        $baseDir = Join-Path $env:TEMP ('narutocode_relpath_' + [guid]::NewGuid().ToString('N'))
        $subDir  = Join-Path $baseDir 'child'
        New-Item -Path $subDir -ItemType Directory -Force | Out-Null
        try {
            # The output target is a relative path from $subDir
            $targetDir = Join-Path $baseDir 'output'
            Push-Location $subDir
            try {
                # Use a relative path that goes up and into 'output'
                Write-TextFile -FilePath '..\output\rel_test.txt' -Content 'relative path works' -EncodingName 'UTF8'
            } finally {
                Pop-Location
            }
            $resultFile = Join-Path $targetDir 'rel_test.txt'
            Test-Path $resultFile | Should -BeTrue
            (Get-Content -Path $resultFile -Raw).Trim() | Should -Be 'relative path works'
        } finally {
            Remove-Item -Path $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-CsvFile resolves relative path correctly' {
        $baseDir = Join-Path $env:TEMP ('narutocode_relcsv_' + [guid]::NewGuid().ToString('N'))
        $subDir  = Join-Path $baseDir 'child'
        New-Item -Path $subDir -ItemType Directory -Force | Out-Null
        try {
            $rows = @([pscustomobject]@{ Name = 'test'; Value = 42 })
            Push-Location $subDir
            try {
                Write-CsvFile -FilePath '..\output\rel_test.csv' -Rows $rows -Headers @('Name','Value')
            } finally {
                Pop-Location
            }
            $resultFile = Join-Path (Join-Path $baseDir 'output') 'rel_test.csv'
            Test-Path $resultFile | Should -BeTrue
            $csv = Import-Csv $resultFile
            $csv[0].Name | Should -Be 'test'
        } finally {
            Remove-Item -Path $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-JsonFile' {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP ('narutocode_jsontest_' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        Remove-Item -Path $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes valid JSON' {
        $filePath = Join-Path $script:testDir 'meta.json'
        $data = [ordered]@{ Version = '1.0'; Count = 42 }
        Write-JsonFile -Data $data -FilePath $filePath
        Test-Path $filePath | Should -BeTrue
        $parsed = Get-Content -Path $filePath -Raw | ConvertFrom-Json
        $parsed.Version | Should -Be '1.0'
        $parsed.Count | Should -Be 42
    }
}

Describe 'New-RunMetaData' {
    BeforeEach {
        $script:runMetaDir = Join-Path $env:TEMP ('narutocode_runmeta_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:runMetaDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:runMetaDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lists output file names that match generated artifacts' {
        $start = [datetime]'2026-01-01T00:00:00Z'
        $end = [datetime]'2026-01-01T00:00:02Z'

        $meta = New-RunMetaData `
            -StartTime $start `
            -EndTime $end `
            -TargetUrl 'https://example.invalid/svn/repo/trunk' `
            -FromRevision 1 `
            -ToRevision 2 `
            -SvnVersion '1.14.2' `
            -Parallel 4 `
            -TopNCount 10 `
            -Encoding 'UTF8' `
            -Commits @() `
            -FileRows @() `
            -OutDirectory $script:runMetaDir `
            -IncludePaths @() `
            -ExcludePaths @() `
            -IncludeExtensions @() `
            -ExcludeExtensions @() `
            -NonInteractive:$false `
            -TrustServerCert:$false `
            -IgnoreWhitespace:$false

        $meta.Outputs.CouplingsCsv | Should -Be 'couplings.csv'
        $meta.Outputs.KillMatrixCsv | Should -Be 'kill_matrix.csv'
        $meta.Outputs.SurvivedShareDonutSvg | Should -Be 'team_survived_share.svg'
        $meta.Outputs.CommitTimelineSvg | Should -Be 'commit_timeline.svg'
        $meta.Outputs.PSObject.Properties.Name | Should -Not -Contain 'ContributorBalanceSvg'
    }
}

Describe 'ConvertFrom-SvnLogXml edge cases' {
    It 'handles empty log (no entries)' {
        $xml = '<log></log>'
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits.Count | Should -Be 0
    }

    It 'handles entry with no paths element' {
        $xml = @"
<log>
  <logentry revision="5">
    <author>tester</author>
    <date>2026-01-01T00:00:00Z</date>
    <msg>empty commit</msg>
  </logentry>
</log>
"@
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits.Count | Should -Be 1
        $commits[0].Revision | Should -Be 5
        $commits[0].ChangedPaths.Count | Should -Be 0
    }

    It 'sorts entries by revision' {
        $xml = @"
<log>
  <logentry revision="20"><author>a</author><date>2026-01-02T00:00:00Z</date><msg>second</msg><paths><path action="M">/x.cs</path></paths></logentry>
  <logentry revision="10"><author>b</author><date>2026-01-01T00:00:00Z</date><msg>first</msg><paths><path action="A">/y.cs</path></paths></logentry>
</log>
"@
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits[0].Revision | Should -Be 10
        $commits[1].Revision | Should -Be 20
    }

    It 'handles directory paths (trailing slash)' {
        $xml = @"
<log>
  <logentry revision="3">
    <author>dev</author>
    <date>2026-01-01T00:00:00Z</date>
    <msg>dir add</msg>
    <paths>
      <path action="A">/trunk/newdir/</path>
      <path action="A">/trunk/newdir/file.txt</path>
    </paths>
  </logentry>
</log>
"@
        $commits = @(ConvertFrom-SvnLogXml -XmlText $xml)
        $commits[0].ChangedPaths.Count | Should -Be 2
        $dirEntry = $commits[0].ChangedPaths | Where-Object { $_.IsDirectory -eq $true }
        $dirEntry | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-SvnUnifiedDiff edge cases' {
    It 'handles empty diff text' {
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText ''
        $parsed.Keys.Count | Should -Be 0
    }

    It 'handles multi-file diff' {
        $diff = @"
Index: trunk/A.cs
===================================================================
--- trunk/A.cs	(revision 9)
+++ trunk/A.cs	(revision 10)
@@ -1,3 +1,4 @@
 unchanged
+added line
 unchanged
 unchanged
Index: trunk/B.cs
===================================================================
--- trunk/B.cs	(revision 9)
+++ trunk/B.cs	(revision 10)
@@ -5,2 +5,1 @@
 keep
-removed
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff
        $parsed.Keys.Count | Should -Be 2
        $parsed['trunk/A.cs'].AddedLines | Should -Be 1
        $parsed['trunk/A.cs'].DeletedLines | Should -Be 0
        $parsed['trunk/B.cs'].AddedLines | Should -Be 0
        $parsed['trunk/B.cs'].DeletedLines | Should -Be 1
    }

    It 'handles hunk without comma (single line)' {
        $diff = @"
Index: trunk/X.txt
===================================================================
--- trunk/X.txt	(revision 1)
+++ trunk/X.txt	(revision 2)
@@ -1 +1 @@
-old
+new
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff
        $parsed['trunk/X.txt'].Hunks[0].OldCount | Should -Be 1
        $parsed['trunk/X.txt'].Hunks[0].NewCount | Should -Be 1
    }

    It 'finalizes previous hunk when file section changes in detail mode' {
        $diff = @"
Index: trunk/A.cs
===================================================================
--- trunk/A.cs	(revision 1)
+++ trunk/A.cs	(revision 2)
@@ -1,2 +1,2 @@
 context
-old
+new
Index: trunk/B.cs
===================================================================
--- trunk/B.cs	(revision 1)
+++ trunk/B.cs	(revision 2)
@@ -1,1 +1,1 @@
-before
+after
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 1
        $parsed.Keys.Count | Should -Be 2
        $parsed['trunk/A.cs'].Hunks.Count | Should -Be 1
        $parsed['trunk/A.cs'].Hunks[0].ContextHash | Should -Not -BeNullOrEmpty
        @($parsed['trunk/A.cs'].Hunks[0].AddedLineHashes).Count | Should -Be 1
        @($parsed['trunk/A.cs'].Hunks[0].DeletedLineHashes).Count | Should -Be 1
        @($parsed['trunk/B.cs'].Hunks[0].AddedLineHashes).Count | Should -Be 1
    }

    It 'handles binary and text files in the same diff independently' {
        $diff = @"
Index: trunk/bin/data.bin
===================================================================
Cannot display: file marked as a binary type.
svn:mime-type = application/octet-stream
Index: trunk/src/App.cs
===================================================================
--- trunk/src/App.cs	(revision 1)
+++ trunk/src/App.cs	(revision 2)
@@ -1 +1,2 @@
 keep
+added
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 1
        $parsed['trunk/bin/data.bin'].IsBinary | Should -BeTrue
        $parsed['trunk/src/App.cs'].IsBinary | Should -BeFalse
        $parsed['trunk/src/App.cs'].AddedLines | Should -Be 1
        $parsed['trunk/src/App.cs'].DeletedLines | Should -Be 0
    }
}

Describe 'Metrics functions — detailed verification' {
    BeforeAll {
        $script:detailedCommits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'fix #123'
                ChangedPathsFiltered = @(
                    [pscustomobject]@{ Path='src/A.cs'; Action='M' },
                    [pscustomobject]@{ Path='src/B.cs'; Action='A' }
                )
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{ AddedLines=3; DeletedLines=1; Hunks=@(); IsBinary=$false }
                    'src/B.cs' = [pscustomobject]@{ AddedLines=10; DeletedLines=0; Hunks=@(); IsBinary=$false }
                }
                FilesChanged = @('src/A.cs','src/B.cs')
                AddedLines = 13
                DeletedLines = 1
                Churn = 14
                Entropy = 0.9
                MsgLen = 8
                MessageShort = 'fix #123'
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'alice'
                Date = [datetime]'2026-01-02'
                Message = 'refactor'
                ChangedPathsFiltered = @([pscustomobject]@{ Path='src/A.cs'; Action='M' })
                FileDiffStats = @{ 'src/A.cs' = [pscustomobject]@{ AddedLines=5; DeletedLines=5; Hunks=@(); IsBinary=$false } }
                FilesChanged = @('src/A.cs')
                AddedLines = 5
                DeletedLines = 5
                Churn = 10
                Entropy = 0.0
                MsgLen = 8
                MessageShort = 'refactor'
            },
            [pscustomobject]@{
                Revision = 3
                Author = 'bob'
                Date = [datetime]'2026-01-03'
                Message = 'merge branch PROJ-99'
                ChangedPathsFiltered = @([pscustomobject]@{ Path='src/A.cs'; Action='M' })
                FileDiffStats = @{ 'src/A.cs' = [pscustomobject]@{ AddedLines=2; DeletedLines=0; Hunks=@(); IsBinary=$false } }
                FilesChanged = @('src/A.cs')
                AddedLines = 2
                DeletedLines = 0
                Churn = 2
                Entropy = 0.0
                MsgLen = 20
                MessageShort = 'merge branch PROJ-99'
            }
        )
    }

    Context 'Get-CommitterMetric detailed' {
        BeforeAll {
            $script:cRows = @(Get-CommitterMetric -Commits $script:detailedCommits)
            $script:alice = $script:cRows | Where-Object { $_.'作者' -eq 'alice' }
            $script:bob = $script:cRows | Where-Object { $_.'作者' -eq 'bob' }
        }

        It 'counts commits per author correctly' {
            $script:alice.'コミット数' | Should -Be 2
            $script:bob.'コミット数' | Should -Be 1
        }

        It 'counts active days' {
            $script:alice.'活動日数' | Should -Be 2  # Jan 1 and Jan 2
            $script:bob.'活動日数' | Should -Be 1
        }

        It 'counts unique files and dirs' {
            $script:alice.'変更ファイル数' | Should -Be 2   # src/A.cs, src/B.cs
            $script:alice.'変更ディレクトリ数' | Should -Be 1    # src
        }

        It 'sums added/deleted lines' {
            $script:alice.'追加行数' | Should -Be 18    # 13 + 5
            $script:alice.'削除行数' | Should -Be 6   # 1 + 5
            $script:alice.'純増行数' | Should -Be 12
            $script:alice.'総チャーン' | Should -Be 24
        }

        It 'calculates ChurnPerCommit' {
            $script:alice.'コミットあたりチャーン' | Should -Be (24.0 / 2)
        }

        It 'calculates DeletedToAddedRatio' {
            $script:alice.'削除対追加比' | Should -Be (6.0 / 18)
        }

        It 'calculates ChurnToNetRatio' {
            $script:alice.'チャーン対純増比' | Should -Be (24.0 / 12)
        }

        It 'calculates ReworkRate' {
            # alice: Added=18, Deleted=6, Net=12, TotalChurn=24
            # ReworkRate = 1 - |12| / 24 = 0.5
            $script:alice.'リワーク率' | Should -Be 0.5
        }

        It 'detects action types' {
            $script:alice.'変更アクション数' | Should -Be 2   # M on A.cs in rev1 + M on A.cs in rev2
            $script:alice.'追加アクション数' | Should -Be 1   # A on B.cs in rev1
        }

        It 'calculates AvgCoAuthorsPerTouchedFile correctly' {
            # src/A.cs is touched by alice & bob => co-authors=1 for alice
            # src/B.cs is touched by alice only => co-authors=0 for alice
            # Average for alice = (1+0)/2 = 0.5
            $script:alice.'平均共同作者数' | Should -Be 0.5
        }

        It 'detects message keywords' {
            $script:alice.'課題ID言及数' | Should -Be 1  # #123
            $script:alice.'修正キーワード数' | Should -Be 1
            $script:bob.'マージキーワード数' | Should -Be 1
            $script:bob.'課題ID言及数' | Should -Be 1    # PROJ-99
        }

        It 'calculates average message length' {
            # alice: msg lengths are 8 + 8 = 16, avg = 8
            $script:alice.'メッセージ平均文字数' | Should -Be 8.0
        }
    }

    Context 'Get-FileMetric detailed' {
        BeforeAll {
            $script:fRows = @(Get-FileMetric -Commits $script:detailedCommits)
            $script:fileA = $script:fRows | Where-Object { $_.'ファイルパス' -eq 'src/A.cs' }
            $script:fileB = $script:fRows | Where-Object { $_.'ファイルパス' -eq 'src/B.cs' }
        }

        It 'counts commits and authors per file' {
            $script:fileA.'コミット数' | Should -Be 3   # rev 1, 2, 3
            $script:fileA.'作者数' | Should -Be 2       # alice, bob
            $script:fileB.'コミット数' | Should -Be 1
            $script:fileB.'作者数' | Should -Be 1
        }

        It 'sums added/deleted lines per file' {
            $script:fileA.'追加行数' | Should -Be 10       # 3 + 5 + 2
            $script:fileA.'削除行数' | Should -Be 6      # 1 + 5 + 0
            $script:fileA.'純増行数' | Should -Be 4
            $script:fileA.'総チャーン' | Should -Be 16
        }

        It 'tracks first and last revision' {
            $script:fileA.'初回変更リビジョン' | Should -Be 1
            $script:fileA.'最終変更リビジョン' | Should -Be 3
            $script:fileB.'初回変更リビジョン' | Should -Be 1
            $script:fileB.'最終変更リビジョン' | Should -Be 1
        }

        It 'calculates HotspotScore = commits * authors * churn * frequency' {
            $script:fileA.'ホットスポットスコア' | Should -Be 144   # 3 * 2 * 16 * (3/2)
            $script:fileB.'ホットスポットスコア' | Should -Be 10    # 1 * 1 * 10 * (1/1)
        }

        It 'assigns rank by hotspot descending' {
            $script:fileA.'ホットスポット順位' | Should -BeLessThan $script:fileB.'ホットスポット順位'
        }

        It 'calculates 活動期間日数' {
            # src/A.cs changed on Jan 1, Jan 2, Jan 3 => span = 2 days
            $script:fileA.'活動期間日数' | Should -Be 2.0
            # src/B.cs changed only once => span = 0
            $script:fileB.'活動期間日数' | Should -Be 0.0
        }

        It 'calculates TopAuthorShareByChurn' {
            # src/A.cs total churn=16, alice churn=14, bob churn=2 => top share = 14/16
            $expected = (14.0 / 16)
            $script:fileA.'最多作者チャーン占有率' | Should -Be $expected
        }

        It 'calculates AvgDaysBetweenChanges' {
            # src/A.cs changed on Jan 1, Jan 2, Jan 3 => intervals = 1, 1 => avg = 1.0
            $script:fileA.'平均変更間隔日数' | Should -Be 1.0
            # src/B.cs changed only once => avg = 0
            $script:fileB.'平均変更間隔日数' | Should -Be 0.0
        }

        It 'counts create/delete/replace actions' {
            $script:fileB.'作成回数' | Should -Be 1   # Action='A' maps to Create
        }
    }

    Context 'Get-CoChangeMetric detailed' {
        BeforeAll {
            $script:coRows = @(Get-CoChangeMetric -Commits $script:detailedCommits -TopNCount 10)
        }

        It 'finds co-change pairs' {
            $script:coRows.Count | Should -Be 1
            $script:coRows[0].'ファイルA' | Should -Be 'src/A.cs'
            $script:coRows[0].'ファイルB' | Should -Be 'src/B.cs'
            $script:coRows[0].'共変更回数' | Should -Be 1
        }

        It 'calculates Jaccard correctly' {
            # A.cs appears in 3 commits, B.cs in 1, co-change=1
            # Jaccard = 1 / (3+1-1) = 1/3
            $expected = (1.0 / 3)
            $script:coRows[0].'Jaccard' | Should -Be $expected
        }

        It 'calculates Lift correctly' {
            # Total commits=3, P(A)=3/3=1, P(B)=1/3, P(AB)=1/3
            # Lift = (1/3) / (1 * 1/3) = 1.0
            $script:coRows[0].'リフト値' | Should -Be 1.0
        }

        It 'respects TopNCount limit' {
            $limited = @(Get-CoChangeMetric -Commits $script:detailedCommits -TopNCount 0)
            # TopNCount=0 means no limit in the code (returns all)
            $limited.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'Get-CoChangeMetric large commit handling' {
        It 'includes commits with many files' {
            $bigCommit = [pscustomobject]@{
                Revision = 99
                Author = 'bulk'
                Date = [datetime]'2026-06-01'
                Message = 'bulk import'
                ChangedPathsFiltered = @()
                FileDiffStats = @{}
                FilesChanged = (1..150 | ForEach-Object { "file$_.cs" })
                AddedLines = 0
                DeletedLines = 0
                Churn = 0
                Entropy = 0.0
                MsgLen = 11
                MessageShort = 'bulk import'
            }
            $result = @(Get-CoChangeMetric -Commits @($bigCommit) -TopNCount 100)
            $result.Count | Should -Be 100
        }
    }
}

Describe 'Strict-only behavior' {
    It 'Format-MetricValue returns exact value without rounding' {
        (Format-MetricValue -Value 1.23456) | Should -Be 1.23456
    }

    It 'Get-CommitterMetric returns null ratios for zero denominators' {
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'strict-user'
                Date = [datetime]'2026-01-01'
                Message = 'strict'
                ChangedPathsFiltered = @([pscustomobject]@{ Path='src/A.cs'; Action='M' })
                FileDiffStats = @{ 'src/A.cs' = [pscustomobject]@{ AddedLines=0; DeletedLines=0; Hunks=@(); IsBinary=$false } }
                FilesChanged = @('src/A.cs')
                AddedLines = 0
                DeletedLines = 0
                Churn = 0
                Entropy = 0.0
                MsgLen = 6
                MessageShort = 'strict'
            }
        )
        $row = @(Get-CommitterMetric -Commits $commits)[0]
        $row.'削除対追加比' | Should -Be $null
        $row.'チャーン対純増比' | Should -Be $null
        $row.'リワーク率' | Should -Be $null
    }

    It 'Get-CoChangeMetric does not skip large commits' {
        $bigCommit = [pscustomobject]@{
            Revision = 99
            Author = 'bulk'
            Date = [datetime]'2026-06-01'
            Message = 'bulk import'
            ChangedPathsFiltered = @()
            FileDiffStats = @{}
            FilesChanged = (1..150 | ForEach-Object { "file$_.cs" })
            AddedLines = 0
            DeletedLines = 0
            Churn = 0
            Entropy = 0.0
            MsgLen = 11
            MessageShort = 'bulk import'
        }
        $result = @(Get-CoChangeMetric -Commits @($bigCommit) -TopNCount 10)
        $result.Count | Should -Be 10
    }

    It 'uses strict dead-related column names by default' {
        $rows = @(Get-CommitterMetric -Commits @(
                [pscustomobject]@{
                    Revision = 1
                    Author = 'strict-user'
                    Date = [datetime]'2026-01-01'
                    Message = ''
                    ChangedPathsFiltered = @()
                    FileDiffStats = @{}
                    FilesChanged = @()
                    AddedLines = 0
                    DeletedLines = 0
                    Churn = 0
                    Entropy = 0.0
                    MsgLen = 0
                    MessageShort = ''
                }
            ))
        $row = $rows[0]
        $row.PSObject.Properties.Name -contains '消滅追加行数' | Should -BeTrue
        $row.PSObject.Properties.Name -contains '他者コード変更行数' | Should -BeTrue
        $row.PSObject.Properties.Name -contains '他者コード変更生存行数' | Should -BeTrue
    }
}

Describe 'ConvertFrom-SvnUnifiedDiff localized binary marker' {
    It 'detects binary via mime-type line even when marker text is localized' {
        $diff = @"
Index: assets/logo.png
===================================================================
表示できません: バイナリタイプとしてマークされたファイルです。
svn:mime-type = application/octet-stream
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff
        $parsed['assets/logo.png'].IsBinary | Should -BeTrue
    }
}

Describe 'Test-ShouldCountFile extended' {
    It 'returns true for file with no extension when no IncludeExtensions specified' {
        Test-ShouldCountFile -FilePath 'Makefile' | Should -BeTrue
    }

    It 'returns false for file with no extension when IncludeExtensions specified' {
        Test-ShouldCountFile -FilePath 'Makefile' -IncludeExtensions @('cs') | Should -BeFalse
    }

    It 'returns false for blank/null path' {
        Test-ShouldCountFile -FilePath '' | Should -BeFalse
        Test-ShouldCountFile -FilePath $null | Should -BeFalse
    }

    It 'returns false for directory path (trailing slash)' {
        Test-ShouldCountFile -FilePath 'src/dir/' | Should -BeFalse
    }

    It 'combines include+exclude extensions' {
        Test-ShouldCountFile -FilePath 'a.cs' -IncludeExtensions @('cs','java') -ExcludeExtensions @('cs') | Should -BeFalse
        Test-ShouldCountFile -FilePath 'a.java' -IncludeExtensions @('cs','java') -ExcludeExtensions @('cs') | Should -BeTrue
    }
}

Describe 'ConvertFrom-SvnBlameXml edge cases' {
    It 'handles empty blame (no entries)' {
        $xml = '<blame><target path="trunk/empty.cs"></target></blame>'
        $summary = ConvertFrom-SvnBlameXml -XmlText $xml
        $summary.LineCountTotal | Should -Be 0
        $summary.LineCountByRevision.Count | Should -Be 0
    }

    It 'handles missing author in blame entry' {
        $xml = @"
<blame>
  <target path="trunk/x.cs">
    <entry line-number="1"><commit revision="5"></commit></entry>
  </target>
</blame>
"@
        $summary = ConvertFrom-SvnBlameXml -XmlText $xml
        $summary.LineCountTotal | Should -Be 1
        $summary.LineCountByAuthor['(unknown)'] | Should -Be 1
    }
}

Describe 'Write-PlantUmlFile' {
    BeforeEach {
        $script:pumlDir = Join-Path $env:TEMP ('narutocode_puml_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:pumlDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:pumlDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates all three puml files' {
        $committers = @([pscustomobject]@{ '作者'='alice'; 'コミット数'=5; '活動日数'=3; '総チャーン'=100; '所有割合'=0.4; '他者コード変更行数'=10; '他者コード変更生存率'=0.5; '変更エントロピー'=2.1; '平均共同作者数'=0.8 })
        $files = @([pscustomobject]@{ 'ファイルパス'='src/A.cs'; 'ホットスポット順位'=1; 'ホットスポットスコア'=500 })
        $couplings = @([pscustomobject]@{ 'ファイルA'='src/A.cs'; 'ファイルB'='src/B.cs'; '共変更回数'=3; 'Jaccard'=0.5 })

        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers $committers -Files $files -Couplings $couplings -TopNCount 50 -EncodingName 'UTF8'

        Test-Path (Join-Path $script:pumlDir 'contributors_summary.puml') | Should -BeTrue
        Test-Path (Join-Path $script:pumlDir 'hotspots.puml') | Should -BeTrue
        Test-Path (Join-Path $script:pumlDir 'cochange_network.puml') | Should -BeTrue
    }

    It 'contributors puml contains @startuml/@enduml and author data' {
        $committers = @([pscustomobject]@{ '作者'='bob'; 'コミット数'=3; '活動日数'=2; '総チャーン'=50; '所有割合'=0.3; '他者コード変更行数'=5; '他者コード変更生存率'=0.6; '変更エントロピー'=1.5; '平均共同作者数'=0.5 })
        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers $committers -Files @() -Couplings @() -TopNCount 50 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:pumlDir 'contributors_summary.puml') -Raw
        $content | Should -Match '@startuml'
        $content | Should -Match '@enduml'
        $content | Should -Match 'bob'
    }

    It 'cochange puml contains network edges' {
        $couplings = @([pscustomobject]@{ 'ファイルA'='X.cs'; 'ファイルB'='Y.cs'; '共変更回数'=2; 'Jaccard'=0.75 })
        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers @() -Files @() -Couplings $couplings -TopNCount 50 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:pumlDir 'cochange_network.puml') -Raw
        $content | Should -Match 'X\.cs'
        $content | Should -Match 'Y\.cs'
        $content | Should -Match 'co=2'
    }
}

Describe 'Write-FileBubbleChart' {
    BeforeEach {
        $script:svgDir = Join-Path $env:TEMP ('narutocode_svg_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:svgDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:svgDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates svg file and includes circles and axis labels' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/A.cs'
                'コミット数' = 12
                '作者数' = 4
                '総チャーン' = 180
                'ホットスポット順位' = 1
                'ホットスポットスコア' = 2160
                '最多作者blame占有率' = 0.75
            },
            [pscustomobject]@{
                'ファイルパス' = 'src/B.cs'
                'コミット数' = 8
                '作者数' = 3
                '総チャーン' = 90
                'ホットスポット順位' = 2
                'ホットスポットスコア' = 720
                '最多作者blame占有率' = 0.50
            }
        )

        Write-FileBubbleChart -OutDirectory $script:svgDir -Files $files -TopNCount 50 -EncodingName 'UTF8'

        $svgPath = Join-Path $script:svgDir 'file_hotspot.svg'
        Test-Path $svgPath | Should -BeTrue
        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<circle'
        $content | Should -Match '>ホットスポットスコア<'
        $content | Should -Match '対数スコア'
        $content | Should -Match '最多作者blame占有率'
        # 対数スケール目盛り: 0 および 10 の累乗が表示される（maxScore=2160 → ceil(log10(2161))=4）
        $content | Should -Match '>0<'
        $content | Should -Match '>10<'
        $content | Should -Match '>100<'
        $content | Should -Match '>1000<'
    }
}

Describe 'Write-CommitterOutcomeChart' {
    BeforeEach {
        $script:chartDir = Join-Path $env:TEMP ('narutocode_chart_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:chartDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:chartDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates individual and combined outcome SVGs for top committers' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'
                '総チャーン' = 200
                '追加行数' = 100
                '削除行数' = 20
                '生存行数' = 80
                '自己相殺行数' = 10
                '他者差戻行数' = 5
                'ピンポン率' = 0.2
                'コミット数' = 10
            },
            [pscustomobject]@{
                '作者' = 'bob'
                '総チャーン' = 150
                '追加行数' = 80
                '削除行数' = 30
                '生存行数' = 40
                '自己相殺行数' = 20
                '他者差戻行数' = 10
                'ピンポン率' = 0.25
                'コミット数' = 12
            },
            [pscustomobject]@{
                '作者' = 'binary-only'
                '総チャーン' = 999
                '追加行数' = 0
                '削除行数' = 0
                '生存行数' = 0
                '自己相殺行数' = 0
                '他者差戻行数' = 0
                'ピンポン率' = 0
                'コミット数' = 1
            }
        )

        Write-CommitterOutcomeChart -OutDirectory $script:chartDir -Committers $committers -TopNCount 2 -EncodingName 'UTF8'

        Test-Path (Join-Path $script:chartDir 'committer_outcome_alice.svg') | Should -BeTrue
        Test-Path (Join-Path $script:chartDir 'committer_outcome_bob.svg') | Should -BeTrue
        Test-Path (Join-Path $script:chartDir 'committer_outcome_binary-only.svg') | Should -BeFalse
        Test-Path (Join-Path $script:chartDir 'committer_outcome_combined.svg') | Should -BeTrue
    }

    It 'individual svg contains stacked bar segments and author name' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'charlie'
                '総チャーン' = 10
                '追加行数' = 20
                '削除行数' = 5
                '生存行数' = 15
                '自己相殺行数' = 1
                '他者差戻行数' = 2
                'ピンポン率' = 0.2
                'コミット数' = 5
            }
        )

        Write-CommitterOutcomeChart -OutDirectory $script:chartDir -Committers $committers -TopNCount 1 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:chartDir 'committer_outcome_charlie.svg') -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match 'charlie'
        $content | Should -Match '<rect'
        $content | Should -Match '生存'
        $content | Should -Match '自己相殺'
        $content | Should -Match '被他者削除'
        $content | Should -Match 'ピンポン率'
    }

    It 'combined svg contains team comparison title' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'
                '総チャーン' = 100
                '追加行数' = 50
                '削除行数' = 10
                '生存行数' = 40
                '自己相殺行数' = 5
                '他者差戻行数' = 3
                'ピンポン率' = 0.1
                'コミット数' = 5
            }
        )

        Write-CommitterOutcomeChart -OutDirectory $script:chartDir -Committers $committers -TopNCount 1 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:chartDir 'committer_outcome_combined.svg') -Raw -Encoding UTF8
        $content | Should -Match 'チーム比較'
    }
}

Describe 'Write-CommitterScatterChart' {
    BeforeEach {
        $script:scatterDir = Join-Path $env:TEMP ('narutocode_scatter_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:scatterDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:scatterDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates individual and combined scatter SVGs' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'
                '総チャーン' = 200
                '追加行数' = 100
                '削除行数' = 20
                '生存行数' = 80
                'リワーク率' = 0.333
                'コミット数' = 10
            },
            [pscustomobject]@{
                '作者' = 'bob'
                '総チャーン' = 150
                '追加行数' = 80
                '削除行数' = 30
                '生存行数' = 40
                'リワーク率' = 0.545
                'コミット数' = 12
            }
        )

        Write-CommitterScatterChart -OutDirectory $script:scatterDir -Committers $committers -TopNCount 2 -EncodingName 'UTF8'

        Test-Path (Join-Path $script:scatterDir 'committer_scatter_alice.svg') | Should -BeTrue
        Test-Path (Join-Path $script:scatterDir 'committer_scatter_bob.svg') | Should -BeTrue
        Test-Path (Join-Path $script:scatterDir 'committer_scatter_combined.svg') | Should -BeTrue
    }

    It 'scatter svg contains quadrant labels and axis labels' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'charlie'
                '総チャーン' = 50
                '追加行数' = 30
                '削除行数' = 10
                '生存行数' = 20
                'リワーク率' = 0.5
                'コミット数' = 5
            }
        )

        Write-CommitterScatterChart -OutDirectory $script:scatterDir -Committers $committers -TopNCount 1 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:scatterDir 'committer_scatter_charlie.svg') -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match 'charlie'
        $content | Should -Match 'リワーク率'
        $content | Should -Match 'コード生存率'
        $content | Should -Match '<circle'
    }

    It 'skips committers without rework rate' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'no-rework'
                '総チャーン' = 0
                '追加行数' = 0
                '削除行数' = 0
                '生存行数' = $null
                'リワーク率' = $null
                'コミット数' = 0
            }
        )

        Write-CommitterScatterChart -OutDirectory $script:scatterDir -Committers $committers -TopNCount 1 -EncodingName 'UTF8'

        Test-Path (Join-Path $script:scatterDir 'committer_scatter_no-rework.svg') | Should -BeFalse
        Test-Path (Join-Path $script:scatterDir 'committer_scatter_combined.svg') | Should -BeFalse
    }
}

Describe 'NarutoCode.ps1 execution' {
    It 'fails when svn executable does not exist' {
        $tempOut = Join-Path $env:TEMP ('narutocode_test_' + [guid]::NewGuid().ToString('N'))
        try {
            & $script:ScriptPath `
                -RepoUrl 'https://svn.example.com/repos/proj/trunk' `
                -FromRevision 1 -ToRevision 2 `
                -OutDirectory $tempOut `
                -SvnExecutable 'nonexistent_svn_command_xyz'

            $LASTEXITCODE | Should -Be 20
            $reportPath = Join-Path $tempOut 'error_report.json'
            (Test-Path -LiteralPath $reportPath) | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            [string]$report.ErrorCode | Should -Be 'ENV_SVN_EXECUTABLE_NOT_FOUND'
            [string]$report.Category | Should -Be 'ENV'
            [string]$report.Message | Should -BeLike '*not found*'
            [int]$report.ExitCode | Should -Be 20
            [string]$report.Timestamp | Should -Not -BeNullOrEmpty
            $report.Context | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tempOut -Recurse -Force -ErrorAction SilentlyContinue
        }
    }


}

Describe 'Contributor balance removal' {
    It 'does not export Write-ContributorBalanceChart function' {
        Get-Command -Name 'Write-ContributorBalanceChart' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

# ===== Phase 2 Tests =====

Describe 'ConvertTo-LineHash' {
    It 'produces consistent hash for same content' {
        $h1 = ConvertTo-LineHash -FilePath 'src/A.cs' -Content '    return null;  '
        $h2 = ConvertTo-LineHash -FilePath 'src/A.cs' -Content '  return  null;'
        $h1 | Should -Be $h2
    }

    It 'produces different hash for different files' {
        $h1 = ConvertTo-LineHash -FilePath 'src/A.cs' -Content 'return null;'
        $h2 = ConvertTo-LineHash -FilePath 'src/B.cs' -Content 'return null;'
        $h1 | Should -Not -Be $h2
    }

    It 'returns a 40 char hex string' {
        $h = ConvertTo-LineHash -FilePath 'x.cs' -Content 'hello'
        $h.Length | Should -Be 40
        $h | Should -Match '^[0-9a-f]{40}$'
    }
}

Describe 'ConvertTo-ContextHash' {
    It 'produces consistent hash for same context' {
        $h1 = ConvertTo-ContextHash -FilePath 'src/A.cs' -ContextLines @('line1', 'line2', 'line3', 'line4')
        $h2 = ConvertTo-ContextHash -FilePath 'src/A.cs' -ContextLines @('line1', 'line2', 'line3', 'line4')
        $h1 | Should -Be $h2
    }

    It 'produces different hash for different files' {
        $h1 = ConvertTo-ContextHash -FilePath 'src/A.cs' -ContextLines @('line1')
        $h2 = ConvertTo-ContextHash -FilePath 'src/B.cs' -ContextLines @('line1')
        $h1 | Should -Not -Be $h2
    }

    It 'handles empty context lines' {
        $h = ConvertTo-ContextHash -FilePath 'x.cs' -ContextLines @()
        $h | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-SvnUnifiedDiff with DetailLevel' {
    It 'captures line hashes at DetailLevel 1' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -10,2 +10,3 @@
 context line
-old line
+new line
+extra line
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 1
        $stat = $parsed['trunk/src/Main.cs']
        $stat.AddedLines | Should -Be 2
        $stat.DeletedLines | Should -Be 1
        $stat.AddedLineHashes.Count | Should -Be 2
        $stat.DeletedLineHashes.Count | Should -Be 1
    }

    It 'captures context hash on hunks at DetailLevel 1' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -10,4 +10,5 @@
 context1
 context2
+added
 context3
 context4
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 1
        $hunk = $parsed['trunk/src/Main.cs'].Hunks[0]
        $hunk.ContextHash | Should -Not -BeNullOrEmpty
        $hunk.AddedLineHashes.Count | Should -Be 1
    }

    It 'does not capture hashes at DetailLevel 0' {
        $diff = @"
Index: trunk/src/Main.cs
===================================================================
--- trunk/src/Main.cs	(revision 9)
+++ trunk/src/Main.cs	(revision 10)
@@ -10,2 +10,3 @@
 context
+added
"@
        $parsed = ConvertFrom-SvnUnifiedDiff -DiffText $diff -DetailLevel 0
        $stat = $parsed['trunk/src/Main.cs']
        $stat.AddedLines | Should -Be 1
        # AddedLineHashes should be empty at level 0
        $stat.AddedLineHashes.Count | Should -Be 0
    }
}

Describe 'Get-RenameMap' {
    It 'tracks renames via copyfrom' {
        $commits = @(
            [pscustomobject]@{
                Revision = 10
                Author = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path='/trunk/NewFile.cs'; Action='A'; CopyFromPath='/trunk/OldFile.cs'; CopyFromRev=9; IsDirectory=$false }
                )
            }
        )
        $map = Get-RenameMap -Commits $commits
        $map['trunk/OldFile.cs'] | Should -Be 'trunk/NewFile.cs'
    }

    It 'chains renames A->B->C' {
        $commits = @(
            [pscustomobject]@{
                Revision = 10
                Author = 'alice'
                ChangedPaths = @(
                    [pscustomobject]@{ Path='/trunk/B.cs'; Action='A'; CopyFromPath='/trunk/A.cs'; CopyFromRev=9; IsDirectory=$false }
                )
            },
            [pscustomobject]@{
                Revision = 11
                Author = 'bob'
                ChangedPaths = @(
                    [pscustomobject]@{ Path='/trunk/C.cs'; Action='R'; CopyFromPath='/trunk/B.cs'; CopyFromRev=10; IsDirectory=$false }
                )
            }
        )
        $map = Get-RenameMap -Commits $commits
        $map['trunk/A.cs'] | Should -Be 'trunk/C.cs'
        $map['trunk/B.cs'] | Should -Be 'trunk/C.cs'
    }
}

Describe 'Compare-BlameOutput' {
    It 'does not misattribute killed line when duplicate contents exist' {
        $prev = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'dup'; Revision = 2; Author = 'bob' },
            [pscustomobject]@{ LineNumber = 2; Content = 'dup'; Revision = 1; Author = 'alice' }
        )
        $curr = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'dup'; Revision = 2; Author = 'bob' }
        )

        $cmp = Compare-BlameOutput -PreviousLines $prev -CurrentLines $curr
        $cmp.KilledLines.Count | Should -Be 1
        $cmp.KilledLines[0].Line.Author | Should -Be 'alice'
        $cmp.BornLines.Count | Should -Be 0
    }

    It 'classifies same-content attribution change as reattribution' {
        $prev = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'value'; Revision = 10; Author = 'alice' }
        )
        $curr = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'value'; Revision = 11; Author = 'bob' }
        )

        $cmp = Compare-BlameOutput -PreviousLines $prev -CurrentLines $curr
        $cmp.KilledLines.Count | Should -Be 0
        $cmp.BornLines.Count | Should -Be 0
        $cmp.ReattributedPairs.Count | Should -Be 1
    }

    It 'classifies reordered identical lines as move without born or killed' {
        $prev = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'first'; Revision = 10; Author = 'alice' },
            [pscustomobject]@{ LineNumber = 2; Content = 'second'; Revision = 10; Author = 'alice' }
        )
        $curr = @(
            [pscustomobject]@{ LineNumber = 1; Content = 'second'; Revision = 10; Author = 'alice' },
            [pscustomobject]@{ LineNumber = 2; Content = 'first'; Revision = 10; Author = 'alice' }
        )

        $cmp = Compare-BlameOutput -PreviousLines $prev -CurrentLines $curr
        $cmp.KilledLines.Count | Should -Be 0
        $cmp.BornLines.Count | Should -Be 0
        $cmp.MovedPairs.Count | Should -Be 1
        $cmp.MovedPairs[0].MatchType | Should -Be 'Move'
    }

    It 'completes within acceptable time for 1000-line blame comparison (Queue benchmark)' {
        # 1000 行のうち中央ブロックを移動させるシナリオで処理時間を計測する。
        # identity key = Revision + Author + Content のため、Revision と Author を
        # 同一に保つことで identity LCS / Move 検出が正しく機能することを確認する。
        # Queue[int] の Dequeue O(1) の効果は、同一 identity を持つ移動行が
        # 多数存在する場合に発揮される。
        $lineCount = 1000
        $prev = @(
            for ($i = 1; $i -le $lineCount; $i++)
            {
                [pscustomobject]@{
                    LineNumber = $i
                    Content = "line_$i"
                    Revision = 10
                    Author = ('author_' + ($i % 5))
                }
            }
        )
        # 中央 200 行 (401-600) を先頭へ移動し、残りは元の順序を維持する。
        # identity key は全行で保持されるため、prefix/suffix 不一致 → LCS + Move で解決される。
        $movedBlock = @($prev[400..599])
        $beforeBlock = @($prev[0..399])
        $afterBlock = @($prev[600..999])
        $reordered = $movedBlock + $beforeBlock + $afterBlock
        $curr = @(
            for ($idx = 0; $idx -lt $reordered.Count; $idx++)
            {
                $src = $reordered[$idx]
                [pscustomobject]@{
                    LineNumber = $idx + 1
                    Content = $src.Content
                    Revision = $src.Revision
                    Author = $src.Author
                }
            }
        )

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cmp = Compare-BlameOutput -PreviousLines $prev -CurrentLines $curr
        $sw.Stop()

        # 全行がマッチし、born/killed が出ないことを確認
        $cmp.KilledLines.Count | Should -Be 0
        $cmp.BornLines.Count | Should -Be 0
        # 移動行が検出されること
        $cmp.MatchedPairs.Count | Should -Be $lineCount

        # 1000 行比較が 10 秒以内に完了することを確認
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}

Describe 'Test-BlameHasUnmatchedSharedKey' {
    It 'returns true when unmatched shared content exists' {
        $previousKeys = @('a', 'shared', 'z')
        $currentKeys = @('x', 'shared', 'y')
        $previousMatched = @($true, $false, $true)
        $currentMatched = @($true, $false, $true)

        $actual = Test-BlameHasUnmatchedSharedKey -PreviousKeys $previousKeys -CurrentKeys $currentKeys -PreviousMatched $previousMatched -CurrentMatched $currentMatched

        $actual | Should -BeTrue
    }

    It 'returns false when unmatched shared content does not exist' {
        $previousKeys = @('a', 'b')
        $currentKeys = @('x', 'y')
        $previousMatched = @($false, $false)
        $currentMatched = @($false, $false)

        $actual = Test-BlameHasUnmatchedSharedKey -PreviousKeys $previousKeys -CurrentKeys $currentKeys -PreviousMatched $previousMatched -CurrentMatched $currentMatched

        $actual | Should -BeFalse
    }
}

Describe 'Resolve-PipelineExecutionState' {
    BeforeAll {
        $script:origResolveSvnTargetUrlForExecutionState = (Get-Item function:Resolve-SvnTargetUrl).ScriptBlock.ToString()
        $script:origGetSvnVersionSafeForExecutionState = (Get-Item function:Get-SvnVersionSafe).ScriptBlock.ToString()
        $script:origGetSvnLogPathPrefixForExecutionState = (Get-Item function:Get-SvnLogPathPrefix).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Resolve-SvnTargetUrl -Value $script:origResolveSvnTargetUrlForExecutionState
        Set-Item -Path function:Get-SvnVersionSafe -Value $script:origGetSvnVersionSafeForExecutionState
        Set-Item -Path function:Get-SvnLogPathPrefix -Value $script:origGetSvnLogPathPrefixForExecutionState
    }

    It 'normalizes revisions and filter inputs while resolving runtime state' {
        Set-Item -Path function:Resolve-SvnTargetUrl -Value {
            param([hashtable]$Context, [string]$Target)
            [void]$Context
            [void]$Target
            return 'https://example.invalid/normalized/repo'
        }
        Set-Item -Path function:Get-SvnVersionSafe -Value {
            param([hashtable]$Context)
            [void]$Context
            return '1.14.2'
        }
        Set-Item -Path function:Get-SvnLogPathPrefix -Value {
            param([hashtable]$Context, [string]$TargetUrl)
            [void]$Context
            [void]$TargetUrl
            return 'proj/trunk/'
        }

        $outDir = Join-Path $env:TEMP ('narutocode_exec_state_' + [guid]::NewGuid().ToString('N'))
        $password = ConvertTo-SecureString -String 'p@ss' -AsPlainText -Force
        try {
            $state = Resolve-PipelineExecutionState -Context $script:TestContext -RepoUrl 'https://example.invalid/repos/proj/trunk' -FromRevision 20 -ToRevision 10 -OutDirectory $outDir -IncludePaths @(' src/* ', 'src/*') -ExcludePaths @(' tmp/* ', 'tmp/*') -IncludeExtensions @('.cs', 'CS') -ExcludeExtensions @(' .bin ', 'BIN') -SvnExecutable 'powershell' -Username 'tester' -Password $password -NonInteractive -TrustServerCert -ExcludeCommentOnlyLines

            $state.FromRevision | Should -Be 10
            $state.ToRevision | Should -Be 20
            $state.TargetUrl | Should -Be 'https://example.invalid/normalized/repo'
            $state.SvnVersion | Should -Be '1.14.2'
            $state.OutDirectory | Should -Be $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outDir)
            (Test-Path $state.CacheDir) | Should -BeTrue
            $state.IncludePaths.Count | Should -Be 1
            $state.IncludePaths[0] | Should -Be 'src/*'
            $state.ExcludePaths.Count | Should -Be 1
            $state.ExcludePaths[0] | Should -Be 'tmp/*'
            $state.IncludeExtensions.Count | Should -Be 1
            $state.IncludeExtensions[0] | Should -Be 'cs'
            $state.ExcludeExtensions.Count | Should -Be 1
            $state.ExcludeExtensions[0] | Should -Be 'bin'
            $script:TestContext.Runtime.SvnGlobalArguments -contains '--username' | Should -BeTrue
            $script:TestContext.Runtime.SvnGlobalArguments -contains 'tester' | Should -BeTrue
            $script:TestContext.Runtime.SvnGlobalArguments -contains '--non-interactive' | Should -BeTrue
            $script:TestContext.Runtime.SvnGlobalArguments -contains '--trust-server-cert' | Should -BeTrue
            [bool]$state.ExcludeCommentOnlyLines | Should -BeTrue
            $state.LogPathPrefix | Should -Be 'proj/trunk/'
        }
        finally {
            Remove-Item -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'NarutoCode.ps1 parameter definition — Phase 2' {
    BeforeAll {
        $script:cmd = Get-Command $script:ScriptPath
    }

    It 'has IgnoreWhitespace switch parameter' {
        $script:cmd.Parameters['IgnoreWhitespace'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['IgnoreWhitespace'].ParameterType.Name | Should -Be 'SwitchParameter'
    }

    It 'has ExcludeCommentOnlyLines switch parameter' {
        $script:cmd.Parameters['ExcludeCommentOnlyLines'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['ExcludeCommentOnlyLines'].ParameterType.Name | Should -Be 'SwitchParameter'
    }
}

# ---------------------------------------------------------------------------
#  Integration test: run NarutoCode.ps1 against the test SVN repository
#  and compare CSV / PlantUML output with the expected baseline files.
# ---------------------------------------------------------------------------
$script:skipReason = $null   # initialise before Describe so -Skip expressions work during discovery
Describe 'Integration — test SVN repo output matches baseline' -Tag 'Integration' {
    BeforeAll {
        # ----- Locate svn executable -----
        $script:svnExe = $null
        foreach ($candidate in @(
                'svn',
                'svn.exe',
                'C:\Program Files\SlikSvn\bin\svn.exe',
                'C:\Program Files\TortoiseSVN\bin\svn.exe',
                'C:\Program Files (x86)\SlikSvn\bin\svn.exe'
            )) {
            if (Get-Command $candidate -ErrorAction SilentlyContinue) {
                $script:svnExe = (Get-Command $candidate).Source
                break
            }
            if (Test-Path $candidate) {
                $script:svnExe = $candidate
                break
            }
        }

        $script:skipReason = $null
        if (-not $script:svnExe) {
            $script:skipReason = 'svn executable not found — skipping integration tests'
        }

        # ----- Paths -----
        $here = Split-Path -Parent $PSCommandPath
        $script:projectRoot = Split-Path -Parent $here
        $script:fixturesDir = Join-Path (Join-Path $script:projectRoot 'tests') 'fixtures'
        $script:repoDir = Join-Path (Join-Path $script:fixturesDir 'svn_repo') 'repo'
        $script:expectedDir = Join-Path $script:fixturesDir 'expected_output'
        $script:actualDir = Join-Path $env:TEMP ('narutocode_integ_' + [guid]::NewGuid().ToString('N'))

        if (-not $script:skipReason -and -not (Test-Path $script:repoDir)) {
            $script:skipReason = 'tests/fixtures/svn_repo/repo not found — skipping integration tests'
        }

        # ----- Run NarutoCode.ps1 -----
        if (-not $script:skipReason) {
            $repoUrl = 'file:///' + ($script:repoDir -replace '\\', '/')
            & $script:ScriptPath `
                -RepoUrl $repoUrl `
                -FromRevision 1 -ToRevision 20 `
                -OutDirectory $script:actualDir `
                -SvnExecutable $script:svnExe `
                -Encoding UTF8 `
                -ErrorAction Stop
        }

        # ---- Helper: compare two CSV files cell-by-cell ----
        function script:Assert-CsvEqual {
            param(
                [string]$ActualPath,
                [string]$ExpectedPath,
                [string]$Label
            )
            $actual   = @(Import-Csv -Path $ActualPath   -Encoding UTF8)
            $expected = @(Import-Csv -Path $ExpectedPath  -Encoding UTF8)

            $actual.Count | Should -Be $expected.Count -Because "$Label row count"

            $headers = ($expected[0].PSObject.Properties | ForEach-Object { $_.Name })
            for ($i = 0; $i -lt $expected.Count; $i++) {
                foreach ($h in $headers) {
                    $actual[$i].$h | Should -Be $expected[$i].$h `
                        -Because "$Label row $i column '$h'"
                }
            }
        }
    }

    AfterAll {
        if ($script:actualDir -and (Test-Path $script:actualDir)) {
            Remove-Item -Path $script:actualDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'produces commits.csv identical to baseline' -Skip:($null -ne $script:skipReason) {
        Assert-CsvEqual `
            -ActualPath   (Join-Path $script:actualDir 'commits.csv') `
            -ExpectedPath (Join-Path $script:expectedDir 'commits.csv') `
            -Label 'commits.csv'
    }

    It 'produces committers.csv identical to baseline' -Skip:($null -ne $script:skipReason) {
        Assert-CsvEqual `
            -ActualPath   (Join-Path $script:actualDir 'committers.csv') `
            -ExpectedPath (Join-Path $script:expectedDir 'committers.csv') `
            -Label 'committers.csv'
    }

    It 'produces files.csv identical to baseline' -Skip:($null -ne $script:skipReason) {
        Assert-CsvEqual `
            -ActualPath   (Join-Path $script:actualDir 'files.csv') `
            -ExpectedPath (Join-Path $script:expectedDir 'files.csv') `
            -Label 'files.csv'
    }

    It 'produces couplings.csv identical to baseline' -Skip:($null -ne $script:skipReason) {
        Assert-CsvEqual `
            -ActualPath   (Join-Path $script:actualDir 'couplings.csv') `
            -ExpectedPath (Join-Path $script:expectedDir 'couplings.csv') `
            -Label 'couplings.csv'
    }

    It 'produces contributors_summary.puml identical to baseline' -Skip:($null -ne $script:skipReason) {
        $actual   = (Get-Content (Join-Path $script:actualDir   'contributors_summary.puml') -Raw).TrimEnd()
        $expected = (Get-Content (Join-Path $script:expectedDir 'contributors_summary.puml') -Raw).TrimEnd()
        $actual | Should -Be $expected -Because 'contributors_summary.puml content'
    }

    It 'produces hotspots.puml identical to baseline' -Skip:($null -ne $script:skipReason) {
        $actual   = (Get-Content (Join-Path $script:actualDir   'hotspots.puml') -Raw).TrimEnd()
        $expected = (Get-Content (Join-Path $script:expectedDir 'hotspots.puml') -Raw).TrimEnd()
        $actual | Should -Be $expected -Because 'hotspots.puml content'
    }

    It 'produces cochange_network.puml identical to baseline' -Skip:($null -ne $script:skipReason) {
        $actual   = (Get-Content (Join-Path $script:actualDir   'cochange_network.puml') -Raw).TrimEnd()
        $expected = (Get-Content (Join-Path $script:expectedDir 'cochange_network.puml') -Raw).TrimEnd()
        $actual | Should -Be $expected -Because 'cochange_network.puml content'
    }

    It 'produces run_meta.json with correct summary fields' -Skip:($null -ne $script:skipReason) {
        $meta = Get-Content (Join-Path $script:actualDir 'run_meta.json') -Raw | ConvertFrom-Json
        $meta.FromRev       | Should -Be 1
        $meta.ToRev         | Should -Be 20
        $meta.CommitCount   | Should -Be 20
        $meta.FileCount     | Should -Be 17
        $meta.StrictMode    | Should -BeTrue
        $meta.Encoding      | Should -Be 'UTF8'
        [bool]$meta.Parameters.ExcludeCommentOnlyLines | Should -BeFalse
        $meta.Outputs.SurvivedShareDonutSvg | Should -Be 'team_survived_share.svg'
        $meta.Outputs.PSObject.Properties.Name | Should -Not -Contain 'ContributorBalanceSvg'
    }

    It 'does not generate contributor_balance.svg in pipeline output' -Skip:($null -ne $script:skipReason) {
        Test-Path (Join-Path $script:actualDir 'contributor_balance.svg') | Should -BeFalse
    }

    It 'keeps couplings.csv full even when TopNCount is 1' -Skip:($null -ne $script:skipReason) {
        $topNDir = Join-Path $env:TEMP ('narutocode_integ_topn_' + [guid]::NewGuid().ToString('N'))
        try {
            $repoUrl = 'file:///' + ($script:repoDir -replace '\\', '/')
            $null = & $script:ScriptPath `
                -RepoUrl $repoUrl `
                -FromRevision 1 -ToRevision 20 `
                -OutDirectory $topNDir `
                -SvnExecutable $script:svnExe `
                -TopNCount 1 `
                -Encoding UTF8 `
                -NoProgress `
                -ErrorAction Stop

            $couplingLineCount = (Get-Content (Join-Path $topNDir 'couplings.csv') -Encoding UTF8).Count
            $couplingLineCount | Should -BeGreaterThan 2 -Because '-TopNCount は可視化だけを制御し、CSV は全件出力するため'
        }
        finally {
            Remove-Item -Path $topNDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-ParallelWork' {
    It 'preserves input order while executing in parallel' {
        $items = 1..24
        $worker = {
            param($Item, $Index)
            Start-Sleep -Milliseconds (10 + (24 - [int]$Item))
            return ([int]$Item * [int]$Item)
        }
        $actual = @(Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 4 -ErrorContext 'test parallel')
        $expected = @($items | ForEach-Object { [int]$_ * [int]$_ })
        $actual | Should -Be $expected
    }

    It 'returns identical results between sequential and parallel execution' {
        $items = 1..40
        $worker = {
            param($Item, $Index)
            return ([int]$Item + [int]$Index)
        }
        $seq = @(Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 1 -ErrorContext 'test seq')
        $par = @(Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 4 -ErrorContext 'test par')
        $par | Should -Be $seq
    }

    It 'propagates worker exceptions with failed item count in parallel mode' {
        $items = 1..8
        $worker = {
            param($Item, $Index)
            if ([int]$Item -eq 5)
            {
                throw 'intentional failure'
            }
            return ([int]$Item * 2)
        }
        {
            $null = Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 4 -ErrorContext 'test fail'
        } | Should -Throw '*failed for 1 item*'
    }

    It 'includes failed item index in parallel error details' {
        $items = 1..6
        $worker = {
            param($Item, $Index)
            if ([int]$Item -eq 4)
            {
                throw 'intentional detail failure'
            }
            return ([int]$Item * 3)
        }
        $errorText = $null
        try
        {
            $null = Invoke-ParallelWork -InputItems $items -WorkerScript $worker -MaxParallel 4 -ErrorContext 'detail fail'
        }
        catch
        {
            $errorText = $_.Exception.Message
        }
        $errorText | Should -Not -BeNullOrEmpty
        $errorText | Should -Match '\[3\]'
        $errorText | Should -Match 'intentional detail failure'
    }
}

Describe 'Initialize-CommitDiffData parallel consistency' {
    BeforeAll {
        $script:origGetCachedOrFetchDiffText = (Get-Item function:Get-CachedOrFetchDiffText).ScriptBlock.ToString()
        Set-Item -Path function:Get-CachedOrFetchDiffText -Value {
            param([hashtable]$Context, [string]$CacheDir, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
            [void]$Context
            @"
Index: trunk/src/file$Revision.txt
===================================================================
--- trunk/src/file$Revision.txt	(revision $([Math]::Max(0, $Revision - 1)))
+++ trunk/src/file$Revision.txt	(revision $Revision)
@@ -1,0 +1,1 @@
+line$Revision
"@
        }
        $script:commitFactory = {
            $commits = New-Object 'System.Collections.Generic.List[object]'
            for ($rev = 1; $rev -le 12; $rev++) {
                $path = "trunk/src/file{0}.txt" -f $rev
                $commits.Add([pscustomobject]@{
                        Revision = $rev
                        Author = 'alice'
                        Date = [datetime]'2026-01-01T00:00:00Z'
                        Message = "m$rev"
                        ChangedPaths = @([pscustomobject]@{
                                Path = $path
                                Action = 'M'
                                CopyFromPath = $null
                                CopyFromRev = $null
                                IsDirectory = $false
                            })
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
            return @($commits.ToArray())
        }
    }

    AfterAll {
        Set-Item -Path function:Get-CachedOrFetchDiffText -Value $script:origGetCachedOrFetchDiffText
    }

    It 'returns identical commit metrics between -Parallel 1 and -Parallel 4' {
        $commitsSeq = & $script:commitFactory
        $commitsPar = & $script:commitFactory

        $mapSeq = Initialize-CommitDiffData -Commits $commitsSeq -CacheDir 'dummy' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @('diff') -IncludeExtensions @() -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @() -Parallel 1
        $mapPar = Initialize-CommitDiffData -Commits $commitsPar -CacheDir 'dummy' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @('diff') -IncludeExtensions @() -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @() -Parallel 4

        @($mapSeq.Keys | Sort-Object) | Should -Be @($mapPar.Keys | Sort-Object)
        foreach ($rev in @($mapSeq.Keys)) {
            $mapSeq[$rev] | Should -Be $mapPar[$rev]
        }

        for ($i = 0; $i -lt $commitsSeq.Count; $i++) {
            $s = $commitsSeq[$i]
            $p = $commitsPar[$i]
            $s.FilesChanged | Should -Be $p.FilesChanged
            $s.AddedLines | Should -Be $p.AddedLines
            $s.DeletedLines | Should -Be $p.DeletedLines
            $s.Churn | Should -Be $p.Churn
            [Math]::Round([double]$s.Entropy, 10) | Should -Be ([Math]::Round([double]$p.Entropy, 10))

            @($s.FileDiffStats.Keys | Sort-Object) | Should -Be @($p.FileDiffStats.Keys | Sort-Object)
            foreach ($filePath in @($s.FileDiffStats.Keys)) {
                $sStat = $s.FileDiffStats[$filePath]
                $pStat = $p.FileDiffStats[$filePath]
                [int]$sStat.AddedLines | Should -Be ([int]$pStat.AddedLines)
                [int]$sStat.DeletedLines | Should -Be ([int]$pStat.DeletedLines)
            }
        }
    }
}

Describe 'Initialize-CommitDiffData skip non-target commit' {
    BeforeAll {
        $script:origGetCachedOrFetchDiffTextSkip = (Get-Item function:Get-CachedOrFetchDiffText).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Get-CachedOrFetchDiffText -Value $script:origGetCachedOrFetchDiffTextSkip
    }

    It 'does not call svn diff fetch when filtered changed paths are empty' {
        Set-Item -Path function:Get-CachedOrFetchDiffText -Value {
            param([hashtable]$Context, [string]$CacheDir, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
            [void]$Context
            throw 'Get-CachedOrFetchDiffText should not be called for filtered-out commit'
        }

        $commit = [pscustomobject]@{
            Revision = 100
            Author = 'alice'
            Date = [datetime]'2026-01-01'
            Message = 'docs only'
            ChangedPaths = @(
                [pscustomobject]@{
                    Path = 'docs/readme.md'
                    Action = 'M'
                    CopyFromPath = $null
                    CopyFromRev = $null
                    IsDirectory = $false
                }
            )
            ChangedPathsFiltered = @()
            FileDiffStats = @{}
            FilesChanged = @()
            AddedLines = 0
            DeletedLines = 0
            Churn = 0
            Entropy = 0.0
            MsgLen = 0
            MessageShort = ''
        }

        $map = Initialize-CommitDiffData -Commits @($commit) -CacheDir 'dummy' -TargetUrl 'https://example.invalid/svn/repo' -DiffArguments @('diff') -IncludeExtensions @('cs') -ExcludeExtensions @() -IncludePathPatterns @() -ExcludePathPatterns @() -Parallel 4

        $map.ContainsKey(100) | Should -BeTrue
        @($commit.ChangedPathsFiltered).Count | Should -Be 0
        @($commit.FileDiffStats.Keys).Count | Should -Be 0
        @($commit.FilesChanged).Count | Should -Be 0
        [int]$commit.AddedLines | Should -Be 0
        [int]$commit.DeletedLines | Should -Be 0
    }
}

Describe 'Blame memory cache' {
    BeforeEach {
        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
    }

    It 'reuses Get-SvnBlameSummary result without extra svn command call' {
        $xml = @"
<blame>
  <target path="trunk/src/A.cs">
    <entry line-number="1"><commit revision="10"><author>alice</author></commit></entry>
  </target>
</blame>
"@
        Mock Read-BlameCacheFile {
            return $null
        }
        Mock Invoke-SvnCommandAllowMissingTarget {
            return $xml
        }
        Mock Write-BlameCacheFile {
            param([string]$CacheDir, [int]$Revision, [string]$FilePath, [string]$Content)
        }

        $first = Get-SvnBlameSummary -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/A.cs' -ToRevision 10 -CacheDir 'dummy'
        $second = Get-SvnBlameSummary -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/A.cs' -ToRevision 10 -CacheDir 'dummy'

        [string]$first.Status | Should -Be 'Success'
        [string]$second.Status | Should -Be 'Success'
        $first.Data.LineCountTotal | Should -Be 1
        $second.Data.LineCountTotal | Should -Be 1
        Assert-MockCalled Invoke-SvnCommandAllowMissingTarget -Times 1 -Exactly
    }

    It 'separates summary memory cache between comment exclusion OFF and ON' {
        $xml = @"
<blame>
  <target path="trunk/src/A.cs">
    <entry line-number="1"><commit revision="10"><author>alice</author></commit></entry>
    <entry line-number="2"><commit revision="10"><author>alice</author></commit></entry>
  </target>
</blame>
"@
        Mock Read-BlameCacheFile {
            return $xml
        }
        Mock Read-CatCacheFile {
            return "// comment only`ncode line`n"
        }
        Mock Invoke-SvnCommandAllowMissingTarget {
            return $null
        }

        $script:TestContext.Runtime.ExcludeCommentOnlyLines = $false
        $off = Get-SvnBlameSummary -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/A.cs' -ToRevision 10 -CacheDir 'dummy'
        $off.Data.LineCountTotal | Should -Be 2

        $script:TestContext.Runtime.ExcludeCommentOnlyLines = $true
        $on = Get-SvnBlameSummary -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/A.cs' -ToRevision 10 -CacheDir 'dummy'
        $on.Data.LineCountTotal | Should -Be 1

        $script:TestContext.Runtime.ExcludeCommentOnlyLines = $false
        $offAgain = Get-SvnBlameSummary -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/A.cs' -ToRevision 10 -CacheDir 'dummy'
        $offAgain.Data.LineCountTotal | Should -Be 2
        Assert-MockCalled Invoke-SvnCommandAllowMissingTarget -Times 0 -Exactly
    }

    It 'reuses Get-SvnBlameLine result without extra svn blame/cat command call' {
        $xml = @"
<blame>
  <target path="trunk/src/B.cs">
    <entry line-number="1"><commit revision="20"><author>bob</author></commit></entry>
  </target>
</blame>
"@
        Mock Read-BlameCacheFile {
            return $null
        }
        Mock Read-CatCacheFile {
            return $null
        }
        Mock Invoke-SvnCommandAllowMissingTarget {
            param([string[]]$Arguments, [string]$ErrorContext)
            if ($Arguments[0] -eq 'blame')
            {
                return $xml
            }
            if ($Arguments[0] -eq 'cat')
            {
                return "line1`n"
            }
            return $null
        }
        Mock Write-BlameCacheFile {
            param([string]$CacheDir, [int]$Revision, [string]$FilePath, [string]$Content)
        }
        Mock Write-CatCacheFile {
            param([string]$CacheDir, [int]$Revision, [string]$FilePath, [string]$Content)
        }

        $first = Get-SvnBlameLine -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/B.cs' -Revision 20 -CacheDir 'dummy'
        $second = Get-SvnBlameLine -Repo 'https://example.invalid/svn/repo' -FilePath 'trunk/src/B.cs' -Revision 20 -CacheDir 'dummy'

        [string]$first.Status | Should -Be 'Success'
        [string]$second.Status | Should -Be 'Success'
        $first.Data.LineCountTotal | Should -Be 1
        $second.Data.LineCountTotal | Should -Be 1
        Assert-MockCalled Invoke-SvnCommandAllowMissingTarget -Times 2 -Exactly
    }
}

Describe 'Get-StrictTransitionComparison fast path' {
    BeforeAll {
        $script:origGetSvnBlameLineFastCmp = (Get-Item function:Get-SvnBlameLine).ScriptBlock.ToString()
        $script:origCompareBlameOutputFastCmp = (Get-Item function:Compare-BlameOutput).ScriptBlock.ToString()
        $script:origGetCachedOrFetchCatTextFastCmp = (Get-Item function:Get-CachedOrFetchCatText).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Get-SvnBlameLine -Value $script:origGetSvnBlameLineFastCmp
        Set-Item -Path function:Compare-BlameOutput -Value $script:origCompareBlameOutputFastCmp
        Set-Item -Path function:Get-CachedOrFetchCatText -Value $script:origGetCachedOrFetchCatTextFastCmp
        $script:TestContext.Runtime.ExcludeCommentOnlyLines = $false
    }

    It 'uses add-only fast path without calling Compare-BlameOutput' {
        Set-Item -Path function:Get-SvnBlameLine -Value {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir, [bool]$NeedContent = $true, [bool]$NeedLines = $true)
            [pscustomobject]@{
                LineCountTotal = 3
                LineCountByRevision = @{}
                LineCountByAuthor = @{}
                Lines = @(
                    [pscustomobject]@{ LineNumber = 1; Content = 'base'; Revision = 9; Author = 'alice' },
                    [pscustomobject]@{ LineNumber = 2; Content = 'add-1'; Revision = 10; Author = 'alice' },
                    [pscustomobject]@{ LineNumber = 3; Content = 'add-2'; Revision = 10; Author = 'alice' }
                )
            }
        }
        Set-Item -Path function:Compare-BlameOutput -Value {
            param([object[]]$PreviousLines, [object[]]$CurrentLines)
            throw 'Compare-BlameOutput should not be called for add-only fast path'
        }
        $context = [pscustomobject]@{
            BeforePath = 'src/a.cs'
            AfterPath = 'src/a.cs'
            MetricFile = 'src/a.cs'
            HasTransitionStat = $true
            TransitionAdded = 2
            TransitionDeleted = 0
        }
        $cmp = Get-StrictTransitionComparison -TransitionContext $context -TargetUrl 'https://example.invalid/svn/repo' -Revision 10 -CacheDir 'dummy'
        @($cmp.KilledLines).Count | Should -Be 0
        $bornCount = @($cmp.BornLines).Count
        if ($cmp.PSObject.Properties.Match('BornCountCurrentRevision').Count -gt 0)
        {
            $bornCount = [int]$cmp.BornCountCurrentRevision
        }
        elseif ($cmp.PSObject.Properties.Match('BornCountByAuthor').Count -gt 0 -and $null -ne $cmp.BornCountByAuthor)
        {
            $bornCount = (($cmp.BornCountByAuthor.Values | Measure-Object -Sum).Sum)
        }
        $bornCount | Should -Be 2
        @($cmp.MovedPairs).Count | Should -Be 0
    }

    It 'applies comment-only filtering in add-only fast path when option is enabled' {
        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        $script:TestContext.Runtime.ExcludeCommentOnlyLines = $true

        Set-Item -Path function:Get-SvnBlameLine -Value {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir, [bool]$NeedContent = $true, [bool]$NeedLines = $true)
            [pscustomobject]@{
                LineCountTotal = 2
                LineCountByRevision = @{ 10 = 2 }
                LineCountByAuthor = @{ alice = 2 }
                Lines = @(
                    [pscustomobject]@{ LineNumber = 1; Content = '// comment only'; Revision = 10; Author = 'alice' },
                    [pscustomobject]@{ LineNumber = 2; Content = 'code line'; Revision = 10; Author = 'alice' }
                )
            }
        }
        Set-Item -Path function:Get-CachedOrFetchCatText -Value {
            param([hashtable]$Context, [string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir)
            [void]$Context
            [void]$Repo
            [void]$FilePath
            [void]$Revision
            [void]$CacheDir
            return "// comment only`ncode line`n"
        }
        Set-Item -Path function:Compare-BlameOutput -Value {
            param([object[]]$PreviousLines, [object[]]$CurrentLines)
            throw 'Compare-BlameOutput should not be called for add-only fast path'
        }

        $context = [pscustomobject]@{
            BeforePath = 'src/a.cs'
            AfterPath = 'src/a.cs'
            MetricFile = 'src/a.cs'
            HasTransitionStat = $true
            TransitionAdded = 2
            TransitionDeleted = 0
        }
        $cmp = Get-StrictTransitionComparison -Context $script:TestContext -TransitionContext $context -TargetUrl 'https://example.invalid/svn/repo' -Revision 10 -CacheDir 'dummy'
        @($cmp.BornLines).Count | Should -Be 1
        $cmp.BornLines[0].Line.Content | Should -Be 'code line'
    }
}

Describe 'Get-ExactDeathAttribution fast path' {
    BeforeAll {
        $script:origGetStrictBlamePrefetchTargetFast = (Get-Item function:Get-StrictBlamePrefetchTarget).ScriptBlock.ToString()
        $script:origInvokeStrictBlameCachePrefetchFast = (Get-Item function:Invoke-StrictBlameCachePrefetch).ScriptBlock.ToString()
        $script:origGetCommitFileTransitionFast = (Get-Item function:Get-CommitFileTransition).ScriptBlock.ToString()
        $script:origCompareBlameOutputFast = (Get-Item function:Compare-BlameOutput).ScriptBlock.ToString()
        $script:origGetStrictHunkDetailFast = (Get-Item function:Get-StrictHunkDetail).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Get-StrictBlamePrefetchTarget -Value $script:origGetStrictBlamePrefetchTargetFast
        Set-Item -Path function:Invoke-StrictBlameCachePrefetch -Value $script:origInvokeStrictBlameCachePrefetchFast
        Set-Item -Path function:Get-CommitFileTransition -Value $script:origGetCommitFileTransitionFast
        Set-Item -Path function:Compare-BlameOutput -Value $script:origCompareBlameOutputFast
        Set-Item -Path function:Get-StrictHunkDetail -Value $script:origGetStrictHunkDetailFast
    }

    It 'skips unnecessary blame side fetch for no-change/add-only/delete-file transitions' {
        Set-Item -Path function:Get-StrictBlamePrefetchTarget -Value {
            param([object[]]$Commits, [int]$FromRevision, [int]$ToRevision, [string]$CacheDir)
            return @()
        }
        Set-Item -Path function:Invoke-StrictBlameCachePrefetch -Value {
            param([object[]]$Targets, [string]$TargetUrl, [string]$CacheDir, [int]$Parallel)
        }
        Set-Item -Path function:Get-CommitFileTransition -Value {
            param([object]$Commit)
            switch ([int]$Commit.Revision) {
                1 { return @([pscustomobject]@{ BeforePath = 'src/nochange.cs'; AfterPath = 'src/nochange.cs' }) }
                2 { return @([pscustomobject]@{ BeforePath = 'src/addonly.cs'; AfterPath = 'src/addonly.cs' }) }
                3 { return @([pscustomobject]@{ BeforePath = 'src/delete.cs'; AfterPath = $null }) }
                default { return @() }
            }
        }
        Set-Item -Path function:Compare-BlameOutput -Value {
            param([object[]]$PreviousLines, [object[]]$CurrentLines)
            throw 'Compare-BlameOutput should not be called in this fast-path test'
        }
        Set-Item -Path function:Get-StrictHunkDetail -Value {
            param([object[]]$Commits, [hashtable]$RevToAuthor, [hashtable]$RenameMap)
            [pscustomobject]@{
                AuthorRepeatedHunk = @{}
                AuthorPingPong = @{}
                FileRepeatedHunk = @{}
                FilePingPong = @{}
            }
        }

        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                FileDiffStats = @{
                    'src/nochange.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 0; Hunks = @(); IsBinary = $false }
                }
                FilesChanged = @('src/nochange.cs')
                ChangedPathsFiltered = @()
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'alice'
                FileDiffStats = @{
                    'src/addonly.cs' = [pscustomobject]@{ AddedLines = 2; DeletedLines = 0; Hunks = @(); IsBinary = $false }
                }
                FilesChanged = @('src/addonly.cs')
                ChangedPathsFiltered = @()
            },
            [pscustomobject]@{
                Revision = 3
                Author = 'charlie'
                FileDiffStats = @{
                    'src/delete.cs' = [pscustomobject]@{ AddedLines = 0; DeletedLines = 2; Hunks = @(); IsBinary = $false }
                }
                FilesChanged = @('src/delete.cs')
                ChangedPathsFiltered = @()
            }
        )
        $revToAuthor = @{ 1 = 'alice'; 2 = 'alice'; 3 = 'charlie' }

        Mock Get-SvnBlameLine {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir, [bool]$NeedContent = $true, [bool]$NeedLines = $true)
            if ($FilePath -eq 'src/addonly.cs') {
                return [pscustomobject]@{
                    LineCountTotal = 3
                    LineCountByRevision = @{}
                    LineCountByAuthor = @{}
                    Lines = @(
                        [pscustomobject]@{ LineNumber = 1; Content = 'old'; Revision = 1; Author = 'alice' },
                        [pscustomobject]@{ LineNumber = 2; Content = 'new-a'; Revision = 2; Author = 'alice' },
                        [pscustomobject]@{ LineNumber = 3; Content = 'new-b'; Revision = 2; Author = 'alice' }
                    )
                }
            }
            return [pscustomobject]@{
                LineCountTotal = 2
                LineCountByRevision = @{}
                LineCountByAuthor = @{}
                Lines = @(
                    [pscustomobject]@{ LineNumber = 1; Content = 'x'; Revision = 2; Author = 'bob' },
                    [pscustomobject]@{ LineNumber = 2; Content = 'y'; Revision = 2; Author = 'bob' }
                )
            }
        }

        $result = Get-ExactDeathAttribution -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 3 -CacheDir 'dummy' -RenameMap @{} -Parallel 1

        $result | Should -Not -BeNullOrEmpty
        Assert-MockCalled Get-SvnBlameLine -Times 1 -Exactly
    }
}

Describe 'Update-StrictAttributionMetric parallel consistency' {
    BeforeAll {
        $script:origGetRenameMap = (Get-Item function:Get-RenameMap).ScriptBlock.ToString()
        $script:origGetExactDeathAttribution = (Get-Item function:Get-ExactDeathAttribution).ScriptBlock.ToString()
        $script:origGetAllRepositoryFile = (Get-Item function:Get-AllRepositoryFile).ScriptBlock.ToString()
        $script:origGetSvnBlameSummary = (Get-Item function:Get-SvnBlameSummary).ScriptBlock.ToString()
        $script:origGetAuthorModifiedOthersSurvivedCount = (Get-Item function:Get-AuthorModifiedOthersSurvivedCount).ScriptBlock.ToString()
        $script:origUpdateFileRowWithStrictMetric = (Get-Item function:Update-FileRowWithStrictMetric).ScriptBlock.ToString()
        $script:origUpdateCommitterRowWithStrictMetric = (Get-Item function:Update-CommitterRowWithStrictMetric).ScriptBlock.ToString()

        Set-Item -Path function:Get-RenameMap -Value { param([object[]]$Commits) @{} }
        Set-Item -Path function:Get-ExactDeathAttribution -Value {
            param([object[]]$Commits, [hashtable]$RevToAuthor, [string]$TargetUrl, [int]$FromRevision, [int]$ToRevision, [string]$CacheDir, [hashtable]$RenameMap, [int]$Parallel)
            [pscustomobject]@{
                AuthorBorn = @{}
                AuthorDead = @{}
                AuthorSurvived = @{ 'alice' = 7; 'bob' = 5 }
                AuthorSelfDead = @{}
                AuthorOtherDead = @{}
                AuthorCrossRevert = @{}
                AuthorRemovedByOthers = @{}
                FileBorn = @{}
                FileDead = @{}
                FileSurvived = @{}
                FileSelfCancel = @{}
                FileCrossRevert = @{}
                AuthorInternalMoveCount = @{}
                FileInternalMoveCount = @{}
                AuthorRepeatedHunk = @{}
                AuthorPingPong = @{}
                FileRepeatedHunk = @{}
                FilePingPong = @{}
                AuthorModifiedOthersCode = @{}
                RevsWhereKilledOthers = (New-Object 'System.Collections.Generic.HashSet[string]')
                KillMatrix = @{}
            }
        }
        Set-Item -Path function:Get-AllRepositoryFile -Value {
            param([hashtable]$Context, [string]$TargetUrl, [int]$Revision, [string[]]$IncludeExtensions, [string[]]$ExcludeExtensions, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
            [void]$Context
            @('src/a.cs', 'src/b.cs', 'src/c.cs')
        }
        Set-Item -Path function:Get-SvnBlameSummary -Value {
            param([string]$Repo, [string]$FilePath, [int]$ToRevision, [string]$CacheDir)
            if ($FilePath -eq 'src/a.cs') {
                return [pscustomobject]@{
                    LineCountTotal = 3
                    LineCountByRevision = @{}
                    LineCountByAuthor = @{ 'alice' = 2; 'bob' = 1 }
                    Lines = @()
                }
            }
            return [pscustomobject]@{
                LineCountTotal = 2
                LineCountByRevision = @{}
                LineCountByAuthor = @{ 'alice' = 1; 'bob' = 1 }
                Lines = @()
            }
        }
        Set-Item -Path function:Get-AuthorModifiedOthersSurvivedCount -Value {
            param([hashtable]$BlameByFile, [System.Collections.Generic.HashSet[string]]$RevsWhereKilledOthers, [int]$FromRevision, [int]$ToRevision)
            @{ 'alice' = 2; 'bob' = 1 }
        }
        Set-Item -Path function:Update-FileRowWithStrictMetric -Value {
            param([object[]]$FileRows, [hashtable]$RenameMap, [object]$StrictDetail, [System.Collections.Generic.HashSet[string]]$ExistingFileSet, [hashtable]$BlameByFile, [string]$TargetUrl, [int]$ToRevision, [string]$CacheDir)
            foreach ($row in @($FileRows)) {
                $path = [string]$row.'ファイルパス'
                if ($BlameByFile.ContainsKey($path)) {
                    $row.'生存行数 (範囲指定)' = [int]$BlameByFile[$path].LineCountTotal
                }
                else {
                    $row.'生存行数 (範囲指定)' = 0
                }
            }
        }
        Set-Item -Path function:Update-CommitterRowWithStrictMetric -Value {
            param([object[]]$CommitterRows, [hashtable]$AuthorSurvived, [hashtable]$AuthorOwned, [int]$OwnedTotal, [object]$StrictDetail, [hashtable]$AuthorModifiedOthersSurvived)
            foreach ($row in @($CommitterRows)) {
                $author = [string]$row.'作者'
                $row.'生存行数' = Get-HashtableIntValue -Table $AuthorSurvived -Key $author
                $row.'所有行数' = Get-HashtableIntValue -Table $AuthorOwned -Key $author
                $row.'他者コード変更生存行数' = Get-HashtableIntValue -Table $AuthorModifiedOthersSurvived -Key $author
            }
        }
    }

    AfterAll {
        Set-Item -Path function:Get-RenameMap -Value $script:origGetRenameMap
        Set-Item -Path function:Get-ExactDeathAttribution -Value $script:origGetExactDeathAttribution
        Set-Item -Path function:Get-AllRepositoryFile -Value $script:origGetAllRepositoryFile
        Set-Item -Path function:Get-SvnBlameSummary -Value $script:origGetSvnBlameSummary
        Set-Item -Path function:Get-AuthorModifiedOthersSurvivedCount -Value $script:origGetAuthorModifiedOthersSurvivedCount
        Set-Item -Path function:Update-FileRowWithStrictMetric -Value $script:origUpdateFileRowWithStrictMetric
        Set-Item -Path function:Update-CommitterRowWithStrictMetric -Value $script:origUpdateCommitterRowWithStrictMetric
    }

    It 'produces identical outputs for -Parallel 1 and -Parallel 4' {
        $commits = @([pscustomobject]@{ Revision = 10; Author = 'alice'; FilesChanged = @(); ChangedPathsFiltered = @(); FileDiffStats = @{} })
        $revToAuthor = @{ 10 = 'alice' }

        $fileRowsSeq = @(
            [pscustomobject]@{ 'ファイルパス' = 'src/a.cs'; '生存行数 (範囲指定)' = $null },
            [pscustomobject]@{ 'ファイルパス' = 'src/b.cs'; '生存行数 (範囲指定)' = $null },
            [pscustomobject]@{ 'ファイルパス' = 'src/c.cs'; '生存行数 (範囲指定)' = $null }
        )
        $fileRowsPar = @(
            [pscustomobject]@{ 'ファイルパス' = 'src/a.cs'; '生存行数 (範囲指定)' = $null },
            [pscustomobject]@{ 'ファイルパス' = 'src/b.cs'; '生存行数 (範囲指定)' = $null },
            [pscustomobject]@{ 'ファイルパス' = 'src/c.cs'; '生存行数 (範囲指定)' = $null }
        )
        $committerRowsSeq = @(
            [pscustomobject]@{ '作者' = 'alice'; '生存行数' = $null; '所有行数' = $null; '他者コード変更生存行数' = $null },
            [pscustomobject]@{ '作者' = 'bob'; '生存行数' = $null; '所有行数' = $null; '他者コード変更生存行数' = $null }
        )
        $committerRowsPar = @(
            [pscustomobject]@{ '作者' = 'alice'; '生存行数' = $null; '所有行数' = $null; '他者コード変更生存行数' = $null },
            [pscustomobject]@{ '作者' = 'bob'; '生存行数' = $null; '所有行数' = $null; '他者コード変更生存行数' = $null }
        )

        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -FileRows $fileRowsSeq -CommitterRows $committerRowsSeq -Parallel 1

        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -FileRows $fileRowsPar -CommitterRows $committerRowsPar -Parallel 4

        ($fileRowsSeq | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($fileRowsPar | ConvertTo-Json -Depth 10 -Compress)
        ($committerRowsSeq | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($committerRowsPar | ConvertTo-Json -Depth 10 -Compress)
    }
}

Describe 'Get-StrictOwnershipAggregate' {
    BeforeAll {
        $script:origGetAllRepositoryFileOwnership = (Get-Item function:Get-AllRepositoryFile).ScriptBlock.ToString()
        $script:origGetSvnBlameSummaryOwnership = (Get-Item function:Get-SvnBlameSummary).ScriptBlock.ToString()
        $script:origInvokeParallelWorkOwnership = (Get-Item function:Invoke-ParallelWork).ScriptBlock.ToString()

        Set-Item -Path function:Get-AllRepositoryFile -Value {
            param([hashtable]$Context, [string]$TargetUrl, [int]$Revision, [string[]]$IncludeExtensions, [string[]]$ExcludeExtensions, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
            [void]$Context
            @('src/a.cs', 'src/b.cs')
        }
        Set-Item -Path function:Get-SvnBlameSummary -Value {
            param([string]$Repo, [string]$FilePath, [int]$ToRevision, [string]$CacheDir)
            if ($FilePath -eq 'src/a.cs') {
                return [pscustomobject]@{
                    LineCountTotal = 3
                    LineCountByRevision = @{}
                    LineCountByAuthor = @{ 'alice' = 2; 'bob' = 1 }
                    Lines = @()
                }
            }
            return [pscustomobject]@{
                LineCountTotal = 2
                LineCountByRevision = @{}
                LineCountByAuthor = @{ 'alice' = 1; 'charlie' = 1 }
                Lines = @()
            }
        }
        Set-Item -Path function:Invoke-ParallelWork -Value {
            param(
                [object[]]$InputItems,
                [scriptblock]$WorkerScript,
                [int]$MaxParallel = 1,
                [string[]]$RequiredFunctions = @(),
                [hashtable]$SessionVariables = @{},
                [string]$ErrorContext = 'parallel work'
            )
            $rows = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in @($InputItems))
            {
                $blame = Get-SvnBlameSummary -Repo $item.TargetUrl -FilePath ([string]$item.FilePath) -ToRevision ([int]$item.ToRevision) -CacheDir $item.CacheDir
                [void]$rows.Add([pscustomobject]@{
                        FilePath = [string]$item.FilePath
                        Blame = $blame
                    })
            }
            return @($rows.ToArray())
        }
    }

    AfterAll {
        Set-Item -Path function:Get-AllRepositoryFile -Value $script:origGetAllRepositoryFileOwnership
        Set-Item -Path function:Get-SvnBlameSummary -Value $script:origGetSvnBlameSummaryOwnership
        Set-Item -Path function:Invoke-ParallelWork -Value $script:origInvokeParallelWorkOwnership
    }

    It 'returns identical ownership aggregates between sequential and parallel branches' {
        $seq = Get-StrictOwnershipAggregate -TargetUrl 'https://example.invalid/svn/repo' -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -Parallel 1
        $par = Get-StrictOwnershipAggregate -TargetUrl 'https://example.invalid/svn/repo' -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -Parallel 4

        [int]($seq.OwnedTotal) | Should -Be ([int]$par.OwnedTotal)
        (Get-HashtableIntValue -Table $seq.AuthorOwned -Key 'alice') | Should -Be (Get-HashtableIntValue -Table $par.AuthorOwned -Key 'alice')
        (Get-HashtableIntValue -Table $seq.AuthorOwned -Key 'bob') | Should -Be (Get-HashtableIntValue -Table $par.AuthorOwned -Key 'bob')
        (Get-HashtableIntValue -Table $seq.AuthorOwned -Key 'charlie') | Should -Be (Get-HashtableIntValue -Table $par.AuthorOwned -Key 'charlie')
        @($seq.ExistingFileSet | Sort-Object) | Should -Be @($par.ExistingFileSet | Sort-Object)
        @($seq.BlameByFile.Keys | Sort-Object) | Should -Be @($par.BlameByFile.Keys | Sort-Object)
    }
}

Describe 'Get-StrictFileBlameWithFallback' {
    BeforeAll {
        $script:origGetSvnBlameSummaryFallback = (Get-Item function:Get-SvnBlameSummary).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Get-SvnBlameSummary -Value $script:origGetSvnBlameSummaryFallback
    }

    It 'tries metricKey then filePath in order and returns first successful blame' {
        $script:blameLookupCalls = New-Object 'System.Collections.Generic.List[string]'
        Set-Item -Path function:Get-SvnBlameSummary -Value {
            param([string]$Repo, [string]$FilePath, [int]$ToRevision, [string]$CacheDir)
            [void]$script:blameLookupCalls.Add([string]$FilePath)
            if ($FilePath -eq 'src/canonical.cs')
            {
                throw 'missing canonical'
            }
            if ($FilePath -eq 'src/legacy.cs')
            {
                return [pscustomobject]@{
                    LineCountTotal = 2
                    LineCountByRevision = @{}
                    LineCountByAuthor = @{ 'alice' = 2 }
                    Lines = @()
                }
            }
            throw 'unexpected lookup'
        }

        $existing = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$existing.Add('src/canonical.cs')
        $blameByFile = @{}
        $result = Get-StrictFileBlameWithFallback -MetricKey 'src/canonical.cs' -FilePath 'src/legacy.cs' -ResolvedFilePath 'src/canonical.cs' -ExistingFileSet $existing -BlameByFile $blameByFile -TargetUrl 'https://example.invalid/svn/repo' -ToRevision 20 -CacheDir 'dummy'

        [string]$result.Status | Should -Be 'Success'
        [bool]$result.Data.ExistsAtToRevision | Should -BeTrue
        [int]$result.Data.Blame.LineCountTotal | Should -Be 2
        @($script:blameLookupCalls.ToArray()) | Should -Be @('src/canonical.cs', 'src/legacy.cs')
        $blameByFile.ContainsKey('src/legacy.cs') | Should -BeTrue
    }
}

Describe 'Invoke-StrictBlameCachePrefetch parallel consistency' {
    BeforeAll {
        $script:origInitializeSvnBlameLineCache = (Get-Item function:Initialize-SvnBlameLineCache).ScriptBlock.ToString()
        Set-Item -Path function:Initialize-SvnBlameLineCache -Value {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir, [bool]$NeedContent = $true)
            if ($FilePath -like '*miss*') {
                return [pscustomobject]@{ CacheHits = 0; CacheMisses = 1 }
            }
            return [pscustomobject]@{ CacheHits = 1; CacheMisses = 0 }
        }
    }

    AfterAll {
        Set-Item -Path function:Initialize-SvnBlameLineCache -Value $script:origInitializeSvnBlameLineCache
    }

    It 'keeps cache hit/miss counts identical between sequential and parallel prefetch' {
        $targets = @(
            [pscustomobject]@{ FilePath = 'src/hit-a.cs'; Revision = 10 },
            [pscustomobject]@{ FilePath = 'src/miss-b.cs'; Revision = 10 },
            [pscustomobject]@{ FilePath = 'src/hit-c.cs'; Revision = 11 }
        )

        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        Invoke-StrictBlameCachePrefetch -Targets $targets -TargetUrl 'https://example.invalid/svn/repo' -CacheDir 'dummy' -Parallel 1
        $seqHits = [int]$script:TestContext.Caches.StrictBlameCacheHits
        $seqMisses = [int]$script:TestContext.Caches.StrictBlameCacheMisses

        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        Invoke-StrictBlameCachePrefetch -Targets $targets -TargetUrl 'https://example.invalid/svn/repo' -CacheDir 'dummy' -Parallel 4
        $parHits = [int]$script:TestContext.Caches.StrictBlameCacheHits
        $parMisses = [int]$script:TestContext.Caches.StrictBlameCacheMisses

        $seqHits | Should -Be $parHits
        $seqMisses | Should -Be $parMisses
        $parHits | Should -Be 2
        $parMisses | Should -Be 1
    }
}

Describe 'Test-SvnMissingTargetError' {
    It 'E200009 を含むメッセージで true を返す' {
        Test-SvnMissingTargetError -Message 'svn: E200009: Could not get info' | Should -BeTrue
    }
    It "targets don't exist を含むメッセージで true を返す" {
        Test-SvnMissingTargetError -Message "Some of the specified targets don't exist" | Should -BeTrue
    }
    It '通常のエラーメッセージで false を返す' {
        Test-SvnMissingTargetError -Message 'svn: E170001: Authorization failed' | Should -BeFalse
    }
    It '空文字列で false を返す' {
        Test-SvnMissingTargetError -Message '' | Should -BeFalse
    }
    It 'null で false を返す' {
        Test-SvnMissingTargetError -Message $null | Should -BeFalse
    }
}

Describe 'Invoke-SvnCommandAllowMissingTarget' {
    It 'missing-target エラー時に Skipped 結果を返す' {
        Mock Invoke-SvnCommand {
            throw "svn: E200009: Some of the specified targets don't exist"
        }
        $result = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test'
        [string]$result.Status | Should -Be 'Skipped'
        [string]$result.ErrorCode | Should -Be 'SVN_TARGET_MISSING'
    }
    It 'その他のエラーは再スローする' {
        Mock Invoke-SvnCommand {
            throw 'svn: E170001: Authorization failed'
        }
        { Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test' } | Should -Throw
    }
    It '正常時は Success 結果を返す' {
        Mock Invoke-SvnCommand {
            return '<xml>ok</xml>'
        }
        $result = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test'
        [string]$result.Status | Should -Be 'Success'
        [string]$result.ErrorCode | Should -Be 'SVN_COMMAND_SUCCEEDED'
        [string]$result.Data | Should -Be '<xml>ok</xml>'
    }
}

Describe 'Get-EmptyBlameResult' {
    It '正しいスキーマの空オブジェクトを返す' {
        $result = Get-EmptyBlameResult
        $result.LineCountTotal | Should -Be 0
        $result.LineCountByRevision | Should -BeOfType [hashtable]
        $result.LineCountByRevision.Keys.Count | Should -Be 0
        $result.LineCountByAuthor | Should -BeOfType [hashtable]
        $result.LineCountByAuthor.Keys.Count | Should -Be 0
        @($result.Lines).Count | Should -Be 0
    }
}

Describe 'Write-KillMatrixCsv' {
    BeforeEach {
        $script:kmDir = Join-Path $env:TEMP ('narutocode_km_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:kmDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:kmDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates kill_matrix.csv with correct cross-kill values and self-dead diagonal' {
        $killMatrix = @{
            'alice' = @{ 'bob' = 5; 'charlie' = 3 }
            'charlie' = @{ 'bob' = 10 }
        }
        $authorSelfDead = @{ 'alice' = 8; 'bob' = 2; 'charlie' = 1 }
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice' }
            [pscustomobject]@{ '作者' = 'bob' }
            [pscustomobject]@{ '作者' = 'charlie' }
        )

        Write-KillMatrixCsv -OutDirectory $script:kmDir -KillMatrix $killMatrix -AuthorSelfDead $authorSelfDead -Committers $committers -EncodingName 'UTF8'

        $csvPath = Join-Path $script:kmDir 'kill_matrix.csv'
        Test-Path $csvPath | Should -BeTrue

        $rows = @(Import-Csv -Path $csvPath -Encoding UTF8)
        $rows.Count | Should -Be 3

        # alice row: self=8, killed bob=5, killed charlie=3
        $aliceRow = $rows | Where-Object { $_.'削除者＼被削除者' -eq 'alice' }
        $aliceRow.'alice' | Should -Be '8'
        $aliceRow.'bob' | Should -Be '5'
        $aliceRow.'charlie' | Should -Be '3'

        # bob row: self=2, no kills
        $bobRow = $rows | Where-Object { $_.'削除者＼被削除者' -eq 'bob' }
        $bobRow.'bob' | Should -Be '2'
        $bobRow.'alice' | Should -Be '0'

        # charlie row: self=1, killed bob=10
        $charlieRow = $rows | Where-Object { $_.'削除者＼被削除者' -eq 'charlie' }
        $charlieRow.'charlie' | Should -Be '1'
        $charlieRow.'bob' | Should -Be '10'
        $charlieRow.'alice' | Should -Be '0'
    }

    It 'returns without output when KillMatrix is null' {
        Write-KillMatrixCsv -OutDirectory $script:kmDir -KillMatrix $null -AuthorSelfDead @{} -Committers @([pscustomobject]@{ '作者' = 'x' }) -EncodingName 'UTF8'
        Test-Path (Join-Path $script:kmDir 'kill_matrix.csv') | Should -BeFalse
    }
}

Describe 'Write-SurvivedShareDonutChart' {
    BeforeEach {
        $script:donutDir = Join-Path $env:TEMP ('narutocode_donut_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:donutDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:donutDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates donut SVG with correct author segments' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice'; '生存行数' = 350 }
            [pscustomobject]@{ '作者' = 'bob'; '生存行数' = 68 }
            [pscustomobject]@{ '作者' = 'charlie'; '生存行数' = 113 }
        )

        Write-SurvivedShareDonutChart -OutDirectory $script:donutDir -Committers $committers -EncodingName 'UTF8'

        $svgPath = Join-Path $script:donutDir 'team_survived_share.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match '<path'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
        $content | Should -Match 'charlie'
        $content | Should -Match '生存行数'
        $content | Should -Match '531'
    }

    It 'skips committers with zero survived lines' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice'; '生存行数' = 100 }
            [pscustomobject]@{ '作者' = 'zero'; '生存行数' = 0 }
        )

        Write-SurvivedShareDonutChart -OutDirectory $script:donutDir -Committers $committers -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:donutDir 'team_survived_share.svg') -Raw -Encoding UTF8
        $content | Should -Match 'alice'
        $content | Should -Not -Match 'zero'
    }

    It 'does not create SVG when Committers is empty' {
        Write-SurvivedShareDonutChart -OutDirectory $script:donutDir -Committers @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:donutDir 'team_survived_share.svg') | Should -BeFalse
    }
}

Describe 'Write-TeamInteractionHeatMap' {
    BeforeEach {
        $script:teamHmDir = Join-Path $env:TEMP ('narutocode_teamhm_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:teamHmDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:teamHmDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates team interaction heatmap SVG with correct cell values' {
        $killMatrix = @{
            'alice' = @{ 'bob' = 13 }
            'charlie' = @{ 'bob' = 49 }
        }
        $authorSelfDead = @{ 'alice' = 16; 'bob' = 0; 'charlie' = 2 }
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice' }
            [pscustomobject]@{ '作者' = 'bob' }
            [pscustomobject]@{ '作者' = 'charlie' }
        )

        Write-TeamInteractionHeatMap -OutDirectory $script:teamHmDir -KillMatrix $killMatrix -AuthorSelfDead $authorSelfDead -Committers $committers -EncodingName 'UTF8'

        $svgPath = Join-Path $script:teamHmDir 'team_interaction_heatmap.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match '<rect'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
        $content | Should -Match 'charlie'
        $content | Should -Match '削除者'
        $content | Should -Match '被削除者'
        # Check that cell values appear
        $content | Should -Match '49'
        $content | Should -Match '16'
        $content | Should -Match '13'
    }

    It 'does not create SVG when only one committer' {
        $killMatrix = @{}
        $authorSelfDead = @{ 'solo' = 5 }
        $committers = @(
            [pscustomobject]@{ '作者' = 'solo' }
        )

        Write-TeamInteractionHeatMap -OutDirectory $script:teamHmDir -KillMatrix $killMatrix -AuthorSelfDead $authorSelfDead -Committers $committers -EncodingName 'UTF8'
        Test-Path (Join-Path $script:teamHmDir 'team_interaction_heatmap.svg') | Should -BeFalse
    }
}

Describe 'Get-TeamActivityProfileData' {
    It 'calculates intervention rate and outcome balance from intervention/survived outcome lines' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'; '他者コード変更行数' = 40
                '他者コード変更生存行数' = 30; '総チャーン' = 400
            }
            [pscustomobject]@{
                '作者' = 'bob'; '他者コード変更行数' = 6
                '他者コード変更生存行数' = 12; '総チャーン' = 120
            }
            [pscustomobject]@{
                '作者' = 'charlie'; '他者コード変更行数' = 50
                '他者コード変更生存行数' = 50; '総チャーン' = 100
            }
        )

        $data = @(Get-TeamActivityProfileData -Context $script:TestContext -Committers $committers)
        $data.Count | Should -Be 3
        $data[0].Author | Should -Be 'alice'

        $alice = $data | Where-Object { $_.Author -eq 'alice' }
        $alice.InterventionRate | Should -Be 0.1
        $alice.OutcomeBalance | Should -BeGreaterThan -0.15
        $alice.OutcomeBalance | Should -BeLessThan -0.14
        $alice.InterventionLines | Should -Be 40
        $alice.SurvivedOutcomeLines | Should -Be 30

        $bob = $data | Where-Object { $_.Author -eq 'bob' }
        $bob.InterventionRate | Should -Be 0.05
        $bob.OutcomeBalance | Should -BeGreaterThan 0.33
        $bob.OutcomeBalance | Should -BeLessThan 0.34

        $charlie = $data | Where-Object { $_.Author -eq 'charlie' }
        $charlie.InterventionRate | Should -Be 0.5
        $charlie.OutcomeBalance | Should -Be 0.0
    }

    It 'skips rows when total churn is 0 or outcome denominator is 0' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'newbie'; '他者コード変更行数' = 0
                '他者コード変更生存行数' = 0; '総チャーン' = 10
            }
            [pscustomobject]@{
                '作者' = 'ghost'; '他者コード変更行数' = 5
                '他者コード変更生存行数' = 2; '総チャーン' = 0
            }
            [pscustomobject]@{
                '作者' = 'valid'; '他者コード変更行数' = 3
                '他者コード変更生存行数' = 1; '総チャーン' = 20
            }
        )

        $data = @(Get-TeamActivityProfileData -Context $script:TestContext -Committers $committers)
        $data.Count | Should -Be 1
        $data[0].Author | Should -Be 'valid'
        $data[0].InterventionRate | Should -Be 0.15
        $data[0].OutcomeBalance | Should -Be -0.5
    }

    It 'clamps overflow intervention rate to 100% and records warning diagnostic' {
        $script:TestContext.Diagnostics.WarningCount = 0
        $script:TestContext.Diagnostics.WarningCodes = @{}
        $script:TestContext.Diagnostics.SkippedOutputs = (New-Object 'System.Collections.Generic.List[object]')

        $committers = @(
            [pscustomobject]@{
                '作者' = 'overflow-user'
                '他者コード変更行数' = 300
                '他者コード変更生存行数' = 120
                '総チャーン' = 100
            }
        )

        $data = @(Get-TeamActivityProfileData -Context $script:TestContext -Committers $committers 3>$null)
        $data.Count | Should -Be 1
        $data[0].RawInterventionRate | Should -Be 3.0
        $data[0].InterventionRate | Should -Be 1.0
        $script:TestContext.Diagnostics.WarningCount | Should -Be 1
        $script:TestContext.Diagnostics.WarningCodes.ContainsKey('OUTPUT_TEAM_ACTIVITY_INTERVENTION_RATE_OVERFLOW') | Should -BeTrue
        $script:TestContext.Diagnostics.WarningCodes['OUTPUT_TEAM_ACTIVITY_INTERVENTION_RATE_OVERFLOW'] | Should -Be 1
    }
}

Describe 'Write-TeamActivityProfileChart' {
    BeforeEach {
        $script:profileDir = Join-Path $env:TEMP ('narutocode_profile_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:profileDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates team activity profile SVG with quadrant labels' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'; '他者コード変更行数' = 40
                '他者コード変更生存行数' = 30; '総チャーン' = 400
            }
            [pscustomobject]@{
                '作者' = 'bob'; '他者コード変更行数' = 6
                '他者コード変更生存行数' = 12; '総チャーン' = 123
            }
        )

        Write-TeamActivityProfileChart -Context $script:TestContext -OutDirectory $script:profileDir -Committers $committers -EncodingName 'UTF8'

        $svgPath = Join-Path $script:profileDir 'team_activity_profile.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match '<circle'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
        $content | Should -Match '低介入・生存優位'
        $content | Should -Match '高介入・生存優位'
        $content | Should -Match '低介入・消滅優位'
        $content | Should -Match '高介入・消滅優位'
        $content | Should -Match '他者コード介入率'
        $content | Should -Match '介入結果生死差分指数'
    }

    It 'does not create SVG when Committers is empty' {
        Write-TeamActivityProfileChart -Context $script:TestContext -OutDirectory $script:profileDir -Committers @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:profileDir 'team_activity_profile.svg') | Should -BeFalse
    }

    It 'uses fixed absolute x-axis ticks and places overflow point at 100%' {
        $script:TestContext.Diagnostics.WarningCount = 0
        $script:TestContext.Diagnostics.WarningCodes = @{}
        $script:TestContext.Diagnostics.SkippedOutputs = (New-Object 'System.Collections.Generic.List[object]')

        $committers = @(
            [pscustomobject]@{
                '作者' = 'overflow-user'
                '他者コード変更行数' = 300
                '他者コード変更生存行数' = 120
                '総チャーン' = 100
            }
        )
        Write-TeamActivityProfileChart -Context $script:TestContext -OutDirectory $script:profileDir -Committers $committers -EncodingName 'UTF8' 3>$null

        $svgPath = Join-Path $script:profileDir 'team_activity_profile.svg'
        Test-Path $svgPath | Should -BeTrue
        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '0%'
        $content | Should -Match '25%'
        $content | Should -Match '50%'
        $content | Should -Match '75%'
        $content | Should -Match '100%'
        $content | Should -Match '介入率\(raw\):300\.0%'
        $content | Should -Match '介入率\(描画\):100\.0%'

        $plotRight = [double]$script:TestContext.Constants.SvgPlotLeft + [double]$script:TestContext.Constants.SvgPlotWidth
        $expectedCx = ('<circle cx="{0:F1}"' -f $plotRight)
        $content | Should -Match ([regex]::Escape($expectedCx))

        $script:TestContext.Diagnostics.WarningCodes.ContainsKey('OUTPUT_TEAM_ACTIVITY_INTERVENTION_RATE_OVERFLOW') | Should -BeTrue
    }
}

Describe 'Write-FileQualityScatterChart' {
    BeforeEach {
        $script:fqsDir = Join-Path $env:TEMP ('narutocode_fqs_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:fqsDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:fqsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates scatter SVG with quadrant labels and axis labels' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/A.cs'
                '追加行数' = 100
                '消滅追加行数' = 40
                '総チャーン' = 200
                '自己相殺行数(合計)' = 10
                '他者差戻行数(合計)' = 5
                'ピンポン回数(合計)' = 3
                'ホットスポット順位' = 1
            },
            [pscustomobject]@{
                'ファイルパス' = 'src/B.cs'
                '追加行数' = 80
                '消滅追加行数' = 10
                '総チャーン' = 120
                '自己相殺行数(合計)' = 2
                '他者差戻行数(合計)' = 1
                'ピンポン回数(合計)' = 0
                'ホットスポット順位' = 2
            }
        )

        Write-FileQualityScatterChart -OutDirectory $script:fqsDir -Files $files -TopNCount 10 -EncodingName 'UTF8'

        $svgPath = Join-Path $script:fqsDir 'file_quality_scatter.svg'
        Test-Path $svgPath | Should -BeTrue
        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '<circle'
        $content | Should -Match 'コード消滅率'
        $content | Should -Match '無駄チャーン率'
        $content | Should -Match '安定型'
        $content | Should -Match '高リスク'
    }

    It 'does not create SVG when Files is empty' {
        Write-FileQualityScatterChart -OutDirectory $script:fqsDir -Files @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:fqsDir 'file_quality_scatter.svg') | Should -BeFalse
    }

    It 'skips files with zero added lines' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/Zero.cs'
                '追加行数' = 0
                '消滅追加行数' = 0
                '総チャーン' = 50
                '自己相殺行数(合計)' = 0
                '他者差戻行数(合計)' = 0
                'ピンポン回数(合計)' = 0
                'ホットスポット順位' = 1
            }
        )

        Write-FileQualityScatterChart -OutDirectory $script:fqsDir -Files $files -TopNCount 10 -EncodingName 'UTF8'
        Test-Path (Join-Path $script:fqsDir 'file_quality_scatter.svg') | Should -BeFalse
    }
}

Describe 'Write-CommitTimelineChart' {
    BeforeEach {
        $script:timelineDir = Join-Path $env:TEMP ('narutocode_timeline_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:timelineDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:timelineDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates timeline SVG with bars and axis labels' {
        $commits = @(
            [pscustomobject]@{
                'リビジョン' = '1'
                '日時' = '2025-01-10T10:00:00'
                '作者' = 'alice'
                'チャーン' = 50
                '変更ファイル数' = 3
            },
            [pscustomobject]@{
                'リビジョン' = '2'
                '日時' = '2025-01-15T14:30:00'
                '作者' = 'bob'
                'チャーン' = 120
                '変更ファイル数' = 5
            },
            [pscustomobject]@{
                'リビジョン' = '3'
                '日時' = '2025-01-20T09:00:00'
                '作者' = 'alice'
                'チャーン' = 30
                '変更ファイル数' = 1
            }
        )

        Write-CommitTimelineChart -OutDirectory $script:timelineDir -Commits $commits -EncodingName 'UTF8'

        $svgPath = Join-Path $script:timelineDir 'commit_timeline.svg'
        Test-Path $svgPath | Should -BeTrue
        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '<rect'
        $content | Should -Match '日時'
        $content | Should -Match 'チャーン'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
    }

    It 'does not create SVG when Commits is empty' {
        Write-CommitTimelineChart -OutDirectory $script:timelineDir -Commits @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:timelineDir 'commit_timeline.svg') | Should -BeFalse
    }

    It 'skips commits with unparseable dates' {
        $commits = @(
            [pscustomobject]@{
                'リビジョン' = '1'
                '日時' = 'not-a-date'
                '作者' = 'alice'
                'チャーン' = 50
            }
        )

        Write-CommitTimelineChart -OutDirectory $script:timelineDir -Commits $commits -EncodingName 'UTF8'
        Test-Path (Join-Path $script:timelineDir 'commit_timeline.svg') | Should -BeFalse
    }
}

Describe 'Write-CommitScatterChart' {
    BeforeEach {
        $script:commitScatterDir = Join-Path $env:TEMP ('narutocode_cs_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:commitScatterDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:commitScatterDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates scatter SVG with bubbles and axis labels' {
        $commits = @(
            [pscustomobject]@{
                'リビジョン' = '1'
                '作者' = 'alice'
                '変更ファイル数' = 5
                'エントロピー' = 1.2
                'チャーン' = 80
            },
            [pscustomobject]@{
                'リビジョン' = '2'
                '作者' = 'bob'
                '変更ファイル数' = 2
                'エントロピー' = 0.5
                'チャーン' = 30
            }
        )

        Write-CommitScatterChart -OutDirectory $script:commitScatterDir -Commits $commits -EncodingName 'UTF8'

        $svgPath = Join-Path $script:commitScatterDir 'commit_scatter.svg'
        Test-Path $svgPath | Should -BeTrue
        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '<circle'
        $content | Should -Match '変更ファイル数'
        $content | Should -Match 'エントロピー'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
    }

    It 'does not create SVG when Commits is empty' {
        Write-CommitScatterChart -OutDirectory $script:commitScatterDir -Commits @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:commitScatterDir 'commit_scatter.svg') | Should -BeFalse
    }

    It 'skips commits with zero file count and zero churn' {
        $commits = @(
            [pscustomobject]@{
                'リビジョン' = '1'
                '作者' = 'alice'
                '変更ファイル数' = 0
                'エントロピー' = 0
                'チャーン' = 0
            }
        )

        Write-CommitScatterChart -OutDirectory $script:commitScatterDir -Commits $commits -EncodingName 'UTF8'
        Test-Path (Join-Path $script:commitScatterDir 'commit_scatter.svg') | Should -BeFalse
    }
}

Describe 'Write-ProjectCodeFateChart' {
    BeforeEach {
        $script:fateDir = Join-Path $env:TEMP ('narutocode_fate_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:fateDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:fateDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates donut SVG with fate segments and survival rate' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice'; '追加行数' = 400; '生存行数' = 300; '自己相殺行数' = 30; '他者差戻行数' = 20 }
            [pscustomobject]@{ '作者' = 'bob'; '追加行数' = 100; '生存行数' = 50; '自己相殺行数' = 10; '他者差戻行数' = 5 }
        )

        Write-ProjectCodeFateChart -OutDirectory $script:fateDir -Committers $committers -EncodingName 'UTF8'

        $svgPath = Join-Path $script:fateDir 'project_code_fate.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match '<path'
        $content | Should -Match '生存'
        $content | Should -Match '自己相殺'
        $content | Should -Match '被他者削除'
        $content | Should -Match 'コード生存率'
        $content | Should -Match '70\.0%'
    }

    It 'does not create SVG when Committers is empty' {
        Write-ProjectCodeFateChart -OutDirectory $script:fateDir -Committers @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:fateDir 'project_code_fate.svg') | Should -BeFalse
    }

    It 'does not create SVG when total added is zero' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'x'; '追加行数' = 0; '生存行数' = 0; '自己相殺行数' = 0; '他者差戻行数' = 0 }
        )
        Write-ProjectCodeFateChart -OutDirectory $script:fateDir -Committers $committers -EncodingName 'UTF8'
        Test-Path (Join-Path $script:fateDir 'project_code_fate.svg') | Should -BeFalse
    }

    It 'clamps other to zero when breakdown exceeds total added' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice'; '追加行数' = 100; '生存行数' = 80; '自己相殺行数' = 15; '他者差戻行数' = 10 }
        )

        Write-ProjectCodeFateChart -OutDirectory $script:fateDir -Committers $committers -EncodingName 'UTF8' 3>$null

        $content = Get-Content -Path (Join-Path $script:fateDir 'project_code_fate.svg') -Raw -Encoding UTF8
        $content | Should -Match '生存'
        # その他消滅は 0 になるのでセグメントが出ないはず
        $content | Should -Not -Match 'その他消滅'
    }
}

Describe 'Get-ProjectEfficiencyData' {
    It 'calculates survival rate and churn efficiency per file' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/A.cs'
                '追加行数' = 100
                '生存行数 (範囲指定)' = 80
                '純増行数' = 60
                '総チャーン' = 200
            }
            [pscustomobject]@{
                'ファイルパス' = 'src/B.cs'
                '追加行数' = 50
                '生存行数 (範囲指定)' = 10
                '純増行数' = -20
                '総チャーン' = 80
            }
        )

        $data = @(Get-ProjectEfficiencyData -Files $files)
        $data.Count | Should -Be 2

        $a = $data | Where-Object { $_.FilePath -eq 'src/A.cs' }
        $a.SurvivalRate | Should -BeGreaterThan 0.79
        $a.SurvivalRate | Should -BeLessThan 0.81
        $a.ChurnEfficiency | Should -BeGreaterThan 0.29
        $a.ChurnEfficiency | Should -BeLessThan 0.31

        $b = $data | Where-Object { $_.FilePath -eq 'src/B.cs' }
        $b.SurvivalRate | Should -BeGreaterThan 0.19
        $b.SurvivalRate | Should -BeLessThan 0.21
        $b.ChurnEfficiency | Should -BeGreaterThan 0.24
        $b.ChurnEfficiency | Should -BeLessThan 0.26
    }

    It 'excludes files with zero added lines' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/empty.cs'
                '追加行数' = 0
                '生存行数 (範囲指定)' = 0
                '純増行数' = 0
                '総チャーン' = 0
            }
        )
        $data = @(Get-ProjectEfficiencyData -Files $files)
        $data.Count | Should -Be 0
    }

    It 'respects TopNCount parameter' {
        $files = @(
            [pscustomobject]@{ 'ファイルパス' = 'a.cs'; '追加行数' = 100; '生存行数 (範囲指定)' = 50; '純増行数' = 50; '総チャーン' = 200 }
            [pscustomobject]@{ 'ファイルパス' = 'b.cs'; '追加行数' = 80; '生存行数 (範囲指定)' = 40; '純増行数' = 40; '総チャーン' = 160 }
            [pscustomobject]@{ 'ファイルパス' = 'c.cs'; '追加行数' = 50; '生存行数 (範囲指定)' = 20; '純増行数' = 20; '総チャーン' = 100 }
        )
        $data = @(Get-ProjectEfficiencyData -Files $files -TopNCount 2)
        $data.Count | Should -Be 2
    }
}

Describe 'Write-ProjectEfficiencyQuadrantChart' {
    BeforeEach {
        $script:effDir = Join-Path $env:TEMP ('narutocode_eff_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:effDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:effDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates quadrant SVG with axis labels and quadrant labels' {
        $files = @(
            [pscustomobject]@{
                'ファイルパス' = 'src/A.cs'
                '追加行数' = 100
                '生存行数 (範囲指定)' = 80
                '純増行数' = 60
                '総チャーン' = 200
            }
            [pscustomobject]@{
                'ファイルパス' = 'src/B.cs'
                '追加行数' = 50
                '生存行数 (範囲指定)' = 10
                '純増行数' = -20
                '総チャーン' = 80
            }
        )

        Write-ProjectEfficiencyQuadrantChart -OutDirectory $script:effDir -Files $files -EncodingName 'UTF8'

        $svgPath = Join-Path $script:effDir 'project_efficiency_quadrant.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '<circle'
        $content | Should -Match 'コード生存率'
        $content | Should -Match 'チャーン効率'
        $content | Should -Match '高効率安定'
        $content | Should -Match '高リスク不安定'
        $content | Should -Match '過修正安定'
        $content | Should -Match '意図的改修'
        $content | Should -Not -Match '無駄な変動'
    }

    It 'does not create SVG when Files is empty' {
        Write-ProjectEfficiencyQuadrantChart -OutDirectory $script:effDir -Files @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:effDir 'project_efficiency_quadrant.svg') | Should -BeFalse
    }
}

Describe 'Write-ProjectSummaryDashboard' {
    BeforeEach {
        $script:dashDir = Join-Path $env:TEMP ('narutocode_dash_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:dashDir -ItemType Directory -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:dashDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates dashboard SVG with all KPI cards' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'alice'; '追加行数' = 400; '削除行数' = 50; '生存行数' = 300; '所有割合' = 0.7 }
            [pscustomobject]@{ '作者' = 'bob'; '追加行数' = 100; '削除行数' = 30; '生存行数' = 50; '所有割合' = 0.3 }
        )
        $fileRows = @(
            [pscustomobject]@{ 'ファイルパス' = 'a.cs' }
            [pscustomobject]@{ 'ファイルパス' = 'b.cs' }
        )
        $commitRows = @(
            [pscustomobject]@{ '変更ファイル数' = 3; 'エントロピー' = 1.2 }
            [pscustomobject]@{ '変更ファイル数' = 1; 'エントロピー' = 0.0 }
        )

        Write-ProjectSummaryDashboard -OutDirectory $script:dashDir -Committers $committers -FileRows $fileRows -CommitRows $commitRows -EncodingName 'UTF8'

        $svgPath = Join-Path $script:dashDir 'project_summary_dashboard.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match 'プロジェクトサマリーダッシュボード'
        $content | Should -Match 'コミット数'
        $content | Should -Match '作者数'
        $content | Should -Match 'ファイル数'
        $content | Should -Match '追加行数'
        $content | Should -Match '削除行数'
        $content | Should -Match '純増行数'
        $content | Should -Match 'コード生存率'
        $content | Should -Match 'リワーク率'
        $content | Should -Match 'HHI'
    }

    It 'calculates HHI as 1.0 when single author' {
        $committers = @(
            [pscustomobject]@{ '作者' = 'solo'; '追加行数' = 100; '削除行数' = 10; '生存行数' = 80; '所有割合' = 1.0 }
        )
        $commitRows = @(
            [pscustomobject]@{ '変更ファイル数' = 1; 'エントロピー' = 0.0 }
        )

        Write-ProjectSummaryDashboard -OutDirectory $script:dashDir -Committers $committers -FileRows @() -CommitRows $commitRows -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:dashDir 'project_summary_dashboard.svg') -Raw -Encoding UTF8
        $content | Should -Match '1\.000'
    }

    It 'does not create SVG when all inputs are empty' {
        Write-ProjectSummaryDashboard -OutDirectory $script:dashDir -Committers @() -FileRows @() -CommitRows @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:dashDir 'project_summary_dashboard.svg') | Should -BeFalse
    }
}

Describe 'SvnBlameLineMemoryCache revision window eviction' {
    BeforeAll {
        $script:origGetStrictBlamePrefetchTargetEvict = (Get-Item function:Get-StrictBlamePrefetchTarget).ScriptBlock.ToString()
        $script:origInvokeStrictBlameCachePrefetchEvict = (Get-Item function:Invoke-StrictBlameCachePrefetch).ScriptBlock.ToString()
        $script:origGetCommitFileTransitionEvict = (Get-Item function:Get-CommitFileTransition).ScriptBlock.ToString()
        $script:origGetStrictHunkDetailEvict = (Get-Item function:Get-StrictHunkDetail).ScriptBlock.ToString()
    }

    AfterAll {
        Set-Item -Path function:Get-StrictBlamePrefetchTarget -Value $script:origGetStrictBlamePrefetchTargetEvict
        Set-Item -Path function:Invoke-StrictBlameCachePrefetch -Value $script:origInvokeStrictBlameCachePrefetchEvict
        Set-Item -Path function:Get-CommitFileTransition -Value $script:origGetCommitFileTransitionEvict
        Set-Item -Path function:Get-StrictHunkDetail -Value $script:origGetStrictHunkDetailEvict
    }

    It 'evicts only older revisions and keeps current revision entries for next commit reuse' {
        $script:TestContext = Initialize-StrictModeContext -Context $script:TestContext
    $PSDefaultParameterValues['*:Context'] = $script:TestContext
        Set-Item -Path function:Get-StrictBlamePrefetchTarget -Value {
            param([object[]]$Commits, [int]$FromRevision, [int]$ToRevision, [string]$CacheDir)
            return @()
        }
        Set-Item -Path function:Invoke-StrictBlameCachePrefetch -Value {
            param([object[]]$Targets, [string]$TargetUrl, [string]$CacheDir, [int]$Parallel)
        }
        Set-Item -Path function:Get-CommitFileTransition -Value {
            param([object]$Commit)
            switch ([int]$Commit.Revision)
            {
                10 { return @([pscustomobject]@{ BeforePath = 'src/file1.cs'; AfterPath = 'src/file1.cs' }) }
                20 { return @([pscustomobject]@{ BeforePath = 'src/file2.cs'; AfterPath = 'src/file2.cs' }) }
                default { return @() }
            }
        }
        Set-Item -Path function:Get-StrictHunkDetail -Value {
            param([object[]]$Commits, [hashtable]$RevToAuthor, [hashtable]$RenameMap)
            [pscustomobject]@{
                AuthorRepeatedHunk = @{}
                AuthorPingPong = @{}
                FileRepeatedHunk = @{}
                FilePingPong = @{}
            }
        }

        $blameCallLog = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-SvnBlameLine {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir, [bool]$NeedContent = $true, [bool]$NeedLines = $true)
            $blameCallLog.Add("$FilePath@$Revision")
            $cacheVariant = if ($NeedContent) {
                'line.withcontent.1'
            } else {
                'line.withcontent.0'
            }
            $cacheKey = Get-BlameMemoryCacheKey -Revision $Revision -FilePath $FilePath -Variant $cacheVariant
            $script:TestContext.Caches.SvnBlameLineMemoryCache[$cacheKey] = [pscustomobject]@{
                Mocked = $true
            }
            return [pscustomobject]@{
                LineCountTotal = 1
                LineCountByRevision = @{}
                LineCountByAuthor = @{}
                Lines = @(
                    [pscustomobject]@{ LineNumber = 1; Content = 'code'; Revision = $Revision; Author = 'alice' }
                )
            }
        }

        $commits = @(
            [pscustomobject]@{
                Revision = 10
                Author = 'alice'
                FileDiffStats = @{
                    'src/file1.cs' = [pscustomobject]@{ AddedLines = 1; DeletedLines = 1; Hunks = @(); IsBinary = $false }
                }
                FilesChanged = @('src/file1.cs')
                ChangedPathsFiltered = @()
            },
            [pscustomobject]@{
                Revision = 20
                Author = 'bob'
                FileDiffStats = @{
                    'src/file2.cs' = [pscustomobject]@{ AddedLines = 1; DeletedLines = 1; Hunks = @(); IsBinary = $false }
                }
                FilesChanged = @('src/file2.cs')
                ChangedPathsFiltered = @()
            }
        )
        $revToAuthor = @{ 10 = 'alice'; 20 = 'bob' }

        $null = Get-ExactDeathAttribution -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 10 -ToRevision 20 -CacheDir 'dummy' -RenameMap @{} -Parallel 1

        # rev10 と rev9 は最終コミット(rev20)処理後に不要なためエビクションされる
        $key10 = Get-BlameMemoryCacheKey -Revision 10 -FilePath 'src/file1.cs' -Variant 'line.withcontent.1'
        $key9  = Get-BlameMemoryCacheKey -Revision 9  -FilePath 'src/file1.cs' -Variant 'line.withcontent.1'
        $script:TestContext.Caches.SvnBlameLineMemoryCache.ContainsKey($key10) | Should -BeFalse
        $script:TestContext.Caches.SvnBlameLineMemoryCache.ContainsKey($key9)  | Should -BeFalse

        # 最終コミット revision のキャッシュは次コミット再利用のため保持される
        $key20 = Get-BlameMemoryCacheKey -Revision 20 -FilePath 'src/file2.cs' -Variant 'line.withcontent.1'
        $key19 = Get-BlameMemoryCacheKey -Revision 19 -FilePath 'src/file2.cs' -Variant 'line.withcontent.1'
        $script:TestContext.Caches.SvnBlameLineMemoryCache.ContainsKey($key20) | Should -BeTrue
        $script:TestContext.Caches.SvnBlameLineMemoryCache.ContainsKey($key19) | Should -BeFalse

        # blame 呼び出し自体は行われていることを確認(キャッシュではなく実際に呼ばれた)
        $blameCallLog.Count | Should -BeGreaterOrEqual 4
    }
}

Describe 'Get-FileMetric - RenameMap統合' {
    It 'リネームされたファイルは最新パスに統合される' {
        $renameMap = @{ 'src/old.cpp' = 'src/new.cpp' }
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'add old.cpp'
                AddedLines = 10
                DeletedLines = 0
                FilesChanged = @('src/old.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                FileDiffStats = @{
                    'src/old.cpp' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0; IsBinary = $false }
                }
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'bob'
                Date = [datetime]'2026-01-02'
                Message = 'rename old.cpp to new.cpp'
                AddedLines = 5
                DeletedLines = 2
                FilesChanged = @('src/new.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'A'; CopyFromPath = 'src/old.cpp' })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'A'; CopyFromPath = 'src/old.cpp' })
                FileDiffStats = @{
                    'src/new.cpp' = [pscustomobject]@{ AddedLines = 5; DeletedLines = 2; IsBinary = $false }
                }
            }
        )

        $rows = @(Get-FileMetric -Commits $commits -RenameMap $renameMap)

        # 旧パスと新パスが分離せず、1行に統合されること
        $rows.Count | Should -Be 1
        $rows[0].'ファイルパス' | Should -Be 'src/new.cpp'
        $rows[0].'追加行数' | Should -Be 15
        $rows[0].'削除行数' | Should -Be 2
        $rows[0].'コミット数' | Should -Be 2
        $rows[0].'作者数' | Should -Be 2
    }

    It 'RenameMap未指定時は従来通りの分離動作' {
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'add old.cpp'
                AddedLines = 10
                DeletedLines = 0
                FilesChanged = @('src/old.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                FileDiffStats = @{
                    'src/old.cpp' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0; IsBinary = $false }
                }
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'bob'
                Date = [datetime]'2026-01-02'
                Message = 'add new.cpp'
                AddedLines = 5
                DeletedLines = 2
                FilesChanged = @('src/new.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'A'; CopyFromPath = $null })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'A'; CopyFromPath = $null })
                FileDiffStats = @{
                    'src/new.cpp' = [pscustomobject]@{ AddedLines = 5; DeletedLines = 2; IsBinary = $false }
                }
            }
        )

        $rows = @(Get-FileMetric -Commits $commits)
        $rows.Count | Should -Be 2
    }
}

Describe 'Get-CommitterMetric - RenameMap統合' {
    It 'リネームされたファイルが変更ファイル数に重複カウントされない' {
        $renameMap = @{ 'src/old.cpp' = 'src/new.cpp' }
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'add old.cpp'
                AddedLines = 10
                DeletedLines = 0
                FilesChanged = @('src/old.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/old.cpp'; Action = 'A'; CopyFromPath = $null })
                FileDiffStats = @{
                    'src/old.cpp' = [pscustomobject]@{ AddedLines = 10; DeletedLines = 0; IsBinary = $false }
                }
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'alice'
                Date = [datetime]'2026-01-02'
                Message = 'modify new.cpp'
                AddedLines = 3
                DeletedLines = 1
                FilesChanged = @('src/new.cpp')
                ChangedPathsFiltered = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'M'; CopyFromPath = $null })
                ChangedPaths = @([pscustomobject]@{ Path = 'src/new.cpp'; Action = 'M'; CopyFromPath = $null })
                FileDiffStats = @{
                    'src/new.cpp' = [pscustomobject]@{ AddedLines = 3; DeletedLines = 1; IsBinary = $false }
                }
            }
        )

        $rows = @(Get-CommitterMetric -Commits $commits -RenameMap $renameMap)
        $rows.Count | Should -Be 1
        # 旧パスと新パスは同一論理ファイルとしてカウントされる
        $rows[0].'変更ファイル数' | Should -Be 1
    }
}

Describe 'Get-CoChangeMetric - RenameMap統合' {
    It 'リネーム前後のパスが同一ファイルとして扱われペアが不要に増えない' {
        $renameMap = @{ 'src/old.cpp' = 'src/new.cpp' }
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                Date = [datetime]'2026-01-01'
                Message = 'add both'
                AddedLines = 10
                DeletedLines = 0
                FilesChanged = @('src/old.cpp', 'src/helper.cpp')
                ChangedPathsFiltered = @()
                ChangedPaths = @()
                FileDiffStats = @{
                    'src/old.cpp' = [pscustomobject]@{ AddedLines = 5; DeletedLines = 0; IsBinary = $false }
                    'src/helper.cpp' = [pscustomobject]@{ AddedLines = 5; DeletedLines = 0; IsBinary = $false }
                }
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'bob'
                Date = [datetime]'2026-01-02'
                Message = 'modify both'
                AddedLines = 4
                DeletedLines = 2
                FilesChanged = @('src/new.cpp', 'src/helper.cpp')
                ChangedPathsFiltered = @()
                ChangedPaths = @()
                FileDiffStats = @{
                    'src/new.cpp' = [pscustomobject]@{ AddedLines = 2; DeletedLines = 1; IsBinary = $false }
                    'src/helper.cpp' = [pscustomobject]@{ AddedLines = 2; DeletedLines = 1; IsBinary = $false }
                }
            }
        )

        $rows = @(Get-CoChangeMetric -Commits $commits -TopNCount 0 -RenameMap $renameMap)
        # リネーム解決により new.cpp + helper.cpp の1ペアのみ
        $rows.Count | Should -Be 1
        $rows[0].'ファイルA' | Should -Be 'src/helper.cpp'
        $rows[0].'ファイルB' | Should -Be 'src/new.cpp'
        $rows[0].'共変更回数' | Should -Be 2
    }
}

Describe 'Get-RenameMap - 連鎖リネーム' {
    It '連鎖リネーム A->B->C が正しく伝播される' {
        $commits = @(
            [pscustomobject]@{
                Revision = 1
                Author = 'alice'
                ChangedPaths = @([pscustomobject]@{ Path = 'src/b.cpp'; Action = 'A'; CopyFromPath = 'src/a.cpp' })
            },
            [pscustomobject]@{
                Revision = 2
                Author = 'alice'
                ChangedPaths = @([pscustomobject]@{ Path = 'src/c.cpp'; Action = 'A'; CopyFromPath = 'src/b.cpp' })
            }
        )

        $map = Get-RenameMap -Commits $commits
        $map['src/a.cpp'] | Should -Be 'src/c.cpp'
        $map['src/b.cpp'] | Should -Be 'src/c.cpp'
    }
}

Describe 'Resolve-PathByRenameMap - 連鎖解決' {
    It '連鎖リネームを最終パスまで解決する' {
        $map = @{ 'src/a.cpp' = 'src/b.cpp'; 'src/b.cpp' = 'src/c.cpp' }
        $result = Resolve-PathByRenameMap -FilePath 'src/a.cpp' -RenameMap $map
        $result | Should -Be 'src/c.cpp'
    }

    It 'マップに存在しないパスはそのまま返す' {
        $map = @{ 'src/a.cpp' = 'src/b.cpp' }
        $result = Resolve-PathByRenameMap -FilePath 'src/x.cpp' -RenameMap $map
        $result | Should -Be 'src/x.cpp'
    }

    It '空のマップでもエラーにならない' {
        $result = Resolve-PathByRenameMap -FilePath 'src/a.cpp' -RenameMap @{}
        $result | Should -Be 'src/a.cpp'
    }
}






