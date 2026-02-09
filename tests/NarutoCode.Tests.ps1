<#
.SYNOPSIS
Pester tests for NarutoCode Phase 1.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'

    $scriptContent = Get-Content -Path $script:ScriptPath -Raw -Encoding UTF8
    # Extract the script-scope variables and all region blocks (functions) from
    # NarutoCode.ps1, skipping the param() block at the top and the try/catch
    # execution body at the bottom.
    $regionPattern = '(?s)(\$script:StrictModeEnabled\b.*# endregion [^\r\n]+)'
    if ($scriptContent -match $regionPattern)
    {
        $functionBlock = $Matches[1]
        $script:SvnExecutable = 'svn'
        $script:SvnGlobalArguments = @()
        $script:StrictModeEnabled = $true
        $script:ColDeadAdded = '消滅追加行数'
        $script:ColSelfDead = '自己消滅行数'
        $script:ColOtherDead = '被他者消滅行数'
        $script:StrictBlameCacheHits = 0
        $script:StrictBlameCacheMisses = 0
        $tempFile = Join-Path $env:TEMP ('NarutoCode_functions_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -Path $tempFile -Value $functionBlock -Encoding UTF8
        . $tempFile
        Remove-Item $tempFile -ErrorAction SilentlyContinue
        Initialize-StrictModeContext
    }
    else
    {
        throw 'Could not extract function regions from NarutoCode.ps1.'
    }
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
        Test-ShouldCountFile -FilePath 'src/a.cs' -IncludeExt @('cs') | Should -BeTrue
        Test-ShouldCountFile -FilePath 'src/a.java' -IncludeExt @('cs') | Should -BeFalse
    }

    It 'applies exclude extension' {
        Test-ShouldCountFile -FilePath 'src/a.cs' -ExcludeExt @('cs') | Should -BeFalse
        Test-ShouldCountFile -FilePath 'src/a.java' -ExcludeExt @('cs') | Should -BeTrue
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

    It 'has required RepoUrl/FromRev/ToRev with compatibility aliases' {
        $script:cmd.Parameters['RepoUrl'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['RepoUrl'].Aliases -contains 'Path' | Should -BeTrue

        $script:cmd.Parameters['FromRev'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['FromRev'].Aliases -contains 'FromRevision' | Should -BeTrue
        $script:cmd.Parameters['FromRev'].Aliases -contains 'From' | Should -BeTrue

        $script:cmd.Parameters['ToRev'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['ToRev'].Aliases -contains 'ToRevision' | Should -BeTrue
        $script:cmd.Parameters['ToRev'].Aliases -contains 'To' | Should -BeTrue
    }

    It 'contains new Phase 1 parameters' {
        $names = @('OutDir','Username','Password','NonInteractive','TrustServerCert','Parallel','IncludePaths','IgnoreWhitespace','TopN','Encoding')
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
        $script:SvnExecutable = 'powershell'
        try {
            $text = Invoke-SvnCommand -Arguments @('-NoProfile','-Command','Write-Output hello') -ErrorContext 'test'
            $text.Trim() | Should -Be 'hello'
        }
        finally {
            $script:SvnExecutable = 'svn'
        }
    }

    It 'throws on non-zero exit code' {
        $script:SvnExecutable = 'powershell'
        try {
            { Invoke-SvnCommand -Arguments @('-NoProfile','-Command','exit 1') -ErrorContext 'test fail' } | Should -Throw
        }
        finally {
            $script:SvnExecutable = 'svn'
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
        { Get-TextEncoding -Name 'EBCDIC' } | Should -Throw -ExpectedMessage '*Unsupported encoding*'
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
            -TopN 10 `
            -Encoding 'UTF8' `
            -Commits @() `
            -FileRows @() `
            -OutDir $script:runMetaDir `
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
        $row.PSObject.Properties.Name -contains '自己消滅行数' | Should -BeTrue
        $row.PSObject.Properties.Name -contains '被他者消滅行数' | Should -BeTrue
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
    It 'returns true for file with no extension when no IncludeExt specified' {
        Test-ShouldCountFile -FilePath 'Makefile' | Should -BeTrue
    }

    It 'returns false for file with no extension when IncludeExt specified' {
        Test-ShouldCountFile -FilePath 'Makefile' -IncludeExt @('cs') | Should -BeFalse
    }

    It 'returns false for blank/null path' {
        Test-ShouldCountFile -FilePath '' | Should -BeFalse
        Test-ShouldCountFile -FilePath $null | Should -BeFalse
    }

    It 'returns false for directory path (trailing slash)' {
        Test-ShouldCountFile -FilePath 'src/dir/' | Should -BeFalse
    }

    It 'combines include+exclude extensions' {
        Test-ShouldCountFile -FilePath 'a.cs' -IncludeExt @('cs','java') -ExcludeExt @('cs') | Should -BeFalse
        Test-ShouldCountFile -FilePath 'a.java' -IncludeExt @('cs','java') -ExcludeExt @('cs') | Should -BeTrue
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
        $content | Should -Match 'ホットスポットスコア'
        $content | Should -Match '最多作者blame占有率'
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
                '被他者削除行数' = 5
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
                '被他者削除行数' = 10
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
                '被他者削除行数' = 0
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
                '被他者削除行数' = 2
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
                '被他者削除行数' = 3
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
            {
                & $script:ScriptPath `
                    -RepoUrl 'https://svn.example.com/repos/proj/trunk' `
                    -FromRev 1 -ToRev 2 `
                    -OutDir $tempOut `
                    -SvnExecutable 'nonexistent_svn_command_xyz' `
                    -ErrorAction Stop
            } | Should -Throw -ExpectedMessage '*not found*'
        }
        finally {
            Remove-Item -Path $tempOut -Recurse -Force -ErrorAction SilentlyContinue
        }
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

Describe 'Test-IsTrivialLine' {
    It 'detects trivial lines' {
        Test-IsTrivialLine -Content '{' | Should -BeTrue
        Test-IsTrivialLine -Content '  }  ' | Should -BeTrue
        Test-IsTrivialLine -Content 'return;' | Should -BeTrue
        Test-IsTrivialLine -Content '' | Should -BeTrue
        Test-IsTrivialLine -Content '  ' | Should -BeTrue
    }

    It 'rejects non-trivial lines' {
        Test-IsTrivialLine -Content 'var x = 42;' | Should -BeFalse
        Test-IsTrivialLine -Content 'public void Run()' | Should -BeFalse
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
}

Describe 'Get-DeadLineDetail — SelfCancel and CrossRevert' {
    BeforeAll {
        # Simulate: alice adds 2 lines in r100, alice deletes 1 in r101, bob deletes 1 in r102
        $addHash1 = ConvertTo-LineHash -FilePath 'src/A.cs' -Content 'var x = 1;'
        $addHash2 = ConvertTo-LineHash -FilePath 'src/A.cs' -Content 'var y = 2;'

        $script:ddCommits = @(
            [pscustomobject]@{
                Revision = 100
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        AddedLines = 2; DeletedLines = 0
                        AddedLineHashes = @($addHash1, $addHash2)
                        DeletedLineHashes = @()
                        Hunks = @()
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 101
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        AddedLines = 0; DeletedLines = 1
                        AddedLineHashes = @()
                        DeletedLineHashes = @($addHash1)
                        Hunks = @()
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 102
                Author = 'bob'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        AddedLines = 0; DeletedLines = 1
                        AddedLineHashes = @()
                        DeletedLineHashes = @($addHash2)
                        Hunks = @()
                        IsBinary = $false
                    }
                }
            }
        )
        $script:revMap = @{ 100 = 'alice'; 101 = 'alice'; 102 = 'bob' }
    }

    It 'counts SelfCancel correctly' {
        $result = Get-DeadLineDetail -Commits $script:ddCommits -RevToAuthor $script:revMap -DetailLevel 1
        $result.AuthorSelfCancel['alice'] | Should -Be 1
    }

    It 'counts CrossRevert correctly' {
        $result = Get-DeadLineDetail -Commits $script:ddCommits -RevToAuthor $script:revMap -DetailLevel 1
        $result.AuthorCrossRevert['alice'] | Should -Be 1
    }

    It 'counts RemovedByOthers correctly' {
        $result = Get-DeadLineDetail -Commits $script:ddCommits -RevToAuthor $script:revMap -DetailLevel 1
        $result.AuthorRemovedByOthers['alice'] | Should -Be 1
    }

    It 'counts file-level SelfCancel' {
        $result = Get-DeadLineDetail -Commits $script:ddCommits -RevToAuthor $script:revMap -DetailLevel 1
        $result.FileSelfCancel['src/A.cs'] | Should -Be 1
    }

    It 'counts file-level CrossRevert' {
        $result = Get-DeadLineDetail -Commits $script:ddCommits -RevToAuthor $script:revMap -DetailLevel 1
        $result.FileCrossRevert['src/A.cs'] | Should -Be 1
    }
}

Describe 'Get-DeadLineDetail — Internal Move Detection' {
    It 'detects file-internal moves at DetailLevel 2' {
        $moveHash = ConvertTo-LineHash -FilePath 'src/A.cs' -Content 'public void DoWork()'

        $commits = @(
            [pscustomobject]@{
                Revision = 200
                Author = 'alice'
                FilesChanged = @('src/A.cs')
                FileDiffStats = @{
                    'src/A.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 1
                        AddedLineHashes = @($moveHash)
                        DeletedLineHashes = @($moveHash)
                        Hunks = @()
                        IsBinary = $false
                    }
                }
            }
        )
        $result = Get-DeadLineDetail -Commits $commits -RevToAuthor @{ 200 = 'alice' } -DetailLevel 2
        $result.FileInternalMoveCount['src/A.cs'] | Should -Be 1
        $result.AuthorInternalMoveCount['alice'] | Should -Be 1
    }
}

Describe 'Get-DeadLineDetail — Rename tracking' {
    It 'tracks line hashes across renames' {
        $lineHash = ConvertTo-LineHash -FilePath 'src/New.cs' -Content 'important code'

        $commits = @(
            [pscustomobject]@{
                Revision = 300
                Author = 'alice'
                FilesChanged = @('src/Old.cs')
                FileDiffStats = @{
                    'src/Old.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 0
                        AddedLineHashes = @($lineHash)
                        DeletedLineHashes = @()
                        Hunks = @(); IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 301
                Author = 'bob'
                FilesChanged = @('src/New.cs')
                FileDiffStats = @{
                    'src/New.cs' = [pscustomobject]@{
                        AddedLines = 0; DeletedLines = 1
                        AddedLineHashes = @()
                        DeletedLineHashes = @($lineHash)
                        Hunks = @(); IsBinary = $false
                    }
                }
            }
        )
        $renameMap = @{ 'src/Old.cs' = 'src/New.cs' }
        $result = Get-DeadLineDetail -Commits $commits -RevToAuthor @{ 300 = 'alice'; 301 = 'bob' } -DetailLevel 1 -RenameMap $renameMap
        $result.AuthorCrossRevert['alice'] | Should -Be 1
    }
}

Describe 'Get-DeadLineDetail — PingPong and RepeatedHunkEdits' {
    It 'detects ping-pong pattern A-B-A' {
        $ctxHash = ConvertTo-ContextHash -FilePath 'src/X.cs' -ContextLines @('ctx1', 'ctx2', 'ctx3')

        $commits = @(
            [pscustomobject]@{
                Revision = 400
                Author = 'alice'
                FilesChanged = @('src/X.cs')
                FileDiffStats = @{
                    'src/X.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 0
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 10; OldCount = 3; NewStart = 10; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 401
                Author = 'bob'
                FilesChanged = @('src/X.cs')
                FileDiffStats = @{
                    'src/X.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 1
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 10; OldCount = 4; NewStart = 10; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 402
                Author = 'alice'
                FilesChanged = @('src/X.cs')
                FileDiffStats = @{
                    'src/X.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 1
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 10; OldCount = 4; NewStart = 10; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            }
        )
        $result = Get-DeadLineDetail -Commits $commits -RevToAuthor @{ 400='alice'; 401='bob'; 402='alice' } -DetailLevel 2
        $result.AuthorPingPong['alice'] | Should -Be 1
        $result.FilePingPong['src/X.cs'] | Should -Be 1
    }

    It 'counts repeated hunk edits by same author' {
        $ctxHash = ConvertTo-ContextHash -FilePath 'src/Y.cs' -ContextLines @('c1', 'c2', 'c3')

        $commits = @(
            [pscustomobject]@{
                Revision = 500
                Author = 'alice'
                FilesChanged = @('src/Y.cs')
                FileDiffStats = @{
                    'src/Y.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 0
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 1; OldCount = 3; NewStart = 1; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 501
                Author = 'alice'
                FilesChanged = @('src/Y.cs')
                FileDiffStats = @{
                    'src/Y.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 1
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 1; OldCount = 4; NewStart = 1; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            },
            [pscustomobject]@{
                Revision = 502
                Author = 'alice'
                FilesChanged = @('src/Y.cs')
                FileDiffStats = @{
                    'src/Y.cs' = [pscustomobject]@{
                        AddedLines = 1; DeletedLines = 1
                        AddedLineHashes = @(); DeletedLineHashes = @()
                        Hunks = @([pscustomobject]@{
                            OldStart = 1; OldCount = 4; NewStart = 1; NewCount = 4
                            ContextHash = $ctxHash
                            AddedLineHashes = @(); DeletedLineHashes = @()
                        })
                        IsBinary = $false
                    }
                }
            }
        )
        $result = Get-DeadLineDetail -Commits $commits -RevToAuthor @{ 500='alice'; 501='alice'; 502='alice' } -DetailLevel 2
        # alice edits the same hunk 3 times => repeated = 3-1 = 2
        $result.AuthorRepeatedHunk['alice'] | Should -Be 2
        $result.FileRepeatedHunk['src/Y.cs'] | Should -Be 2
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
                -FromRev 1 -ToRev 20 `
                -OutDir $script:actualDir `
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
        $meta.FileCount     | Should -Be 19
        $meta.StrictMode    | Should -BeTrue
        $meta.Encoding      | Should -Be 'UTF8'
        $meta.Outputs.SurvivedShareDonutSvg | Should -Be 'team_survived_share.svg'
    }

    It 'keeps couplings.csv full even when TopN is 1' -Skip:($null -ne $script:skipReason) {
        $topNDir = Join-Path $env:TEMP ('narutocode_integ_topn_' + [guid]::NewGuid().ToString('N'))
        try {
            $repoUrl = 'file:///' + ($script:repoDir -replace '\\', '/')
            $null = & $script:ScriptPath `
                -RepoUrl $repoUrl `
                -FromRev 1 -ToRev 20 `
                -OutDir $topNDir `
                -SvnExecutable $script:svnExe `
                -TopN 1 `
                -Encoding UTF8 `
                -NoProgress `
                -ErrorAction Stop

            $couplingLineCount = (Get-Content (Join-Path $topNDir 'couplings.csv') -Encoding UTF8).Count
            $couplingLineCount | Should -BeGreaterThan 2 -Because '-TopN は可視化だけを制御し、CSV は全件出力するため'
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
}

Describe 'Initialize-CommitDiffData parallel consistency' {
    BeforeAll {
        $script:origGetCachedOrFetchDiffText = (Get-Item function:Get-CachedOrFetchDiffText).ScriptBlock.ToString()
        Set-Item -Path function:Get-CachedOrFetchDiffText -Value {
            param([string]$CacheDir, [int]$Revision, [string]$TargetUrl, [string[]]$DiffArguments)
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
            param([string]$Repo, [int]$Revision, [string[]]$IncludeExt, [string[]]$ExcludeExt, [string[]]$IncludePathPatterns, [string[]]$ExcludePathPatterns)
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

        Initialize-StrictModeContext
        Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -FileRows $fileRowsSeq -CommitterRows $committerRowsSeq -Parallel 1

        Initialize-StrictModeContext
        Update-StrictAttributionMetric -Commits $commits -RevToAuthor $revToAuthor -TargetUrl 'https://example.invalid/svn/repo' -FromRevision 1 -ToRevision 20 -CacheDir 'dummy' -IncludeExtensions @() -ExcludeExtensions @() -IncludePaths @() -ExcludePaths @() -FileRows $fileRowsPar -CommitterRows $committerRowsPar -Parallel 4

        ($fileRowsSeq | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($fileRowsPar | ConvertTo-Json -Depth 10 -Compress)
        ($committerRowsSeq | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($committerRowsPar | ConvertTo-Json -Depth 10 -Compress)
    }
}

Describe 'Invoke-StrictBlameCachePrefetch parallel consistency' {
    BeforeAll {
        $script:origInitializeSvnBlameLineCache = (Get-Item function:Initialize-SvnBlameLineCache).ScriptBlock.ToString()
        Set-Item -Path function:Initialize-SvnBlameLineCache -Value {
            param([string]$Repo, [string]$FilePath, [int]$Revision, [string]$CacheDir)
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

        Initialize-StrictModeContext
        Invoke-StrictBlameCachePrefetch -Targets $targets -TargetUrl 'https://example.invalid/svn/repo' -CacheDir 'dummy' -Parallel 1
        $seqHits = [int]$script:StrictBlameCacheHits
        $seqMisses = [int]$script:StrictBlameCacheMisses

        Initialize-StrictModeContext
        Invoke-StrictBlameCachePrefetch -Targets $targets -TargetUrl 'https://example.invalid/svn/repo' -CacheDir 'dummy' -Parallel 4
        $parHits = [int]$script:StrictBlameCacheHits
        $parMisses = [int]$script:StrictBlameCacheMisses

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
    It 'missing-target エラー時に null を返す' {
        Mock Invoke-SvnCommand {
            throw "svn: E200009: Some of the specified targets don't exist"
        }
        $result = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test'
        $result | Should -BeNullOrEmpty
    }
    It 'その他のエラーは再スローする' {
        Mock Invoke-SvnCommand {
            throw 'svn: E170001: Authorization failed'
        }
        { Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test' } | Should -Throw
    }
    It '正常時は結果をそのまま返す' {
        Mock Invoke-SvnCommand {
            return '<xml>ok</xml>'
        }
        $result = Invoke-SvnCommandAllowMissingTarget -Arguments @('blame', 'dummy') -ErrorContext 'test'
        $result | Should -Be '<xml>ok</xml>'
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
    It 'calculates intervention rate from deleted and others-modified lines' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'alice'; '削除行数' = 20; '他者コード変更行数' = 1
                '他者コード変更生存率' = 0; '総チャーン' = 400
            }
            [pscustomobject]@{
                '作者' = 'bob'; '削除行数' = 6; '他者コード変更行数' = 6
                '他者コード変更生存率' = 0.833; '総チャーン' = 123
            }
            [pscustomobject]@{
                '作者' = 'charlie'; '削除行数' = 58; '他者コード変更行数' = 55
                '他者コード変更生存率' = 0.382; '総チャーン' = 174
            }
        )

        $data = @(Get-TeamActivityProfileData -Committers $committers)
        $data.Count | Should -Be 3

        $alice = $data | Where-Object { $_.Author -eq 'alice' }
        $alice.InterventionRate | Should -BeGreaterThan 0.04
        $alice.InterventionRate | Should -BeLessThan 0.06

        $bob = $data | Where-Object { $_.Author -eq 'bob' }
        $bob.InterventionRate | Should -Be 1.0

        $charlie = $data | Where-Object { $_.Author -eq 'charlie' }
        $charlie.InterventionRate | Should -BeGreaterThan 0.94
        $charlie.InterventionRate | Should -BeLessThan 0.96
    }

    It 'returns 0 intervention rate when deleted is 0' {
        $committers = @(
            [pscustomobject]@{
                '作者' = 'newbie'; '削除行数' = 0; '他者コード変更行数' = 0
                '他者コード変更生存率' = 0; '総チャーン' = 10
            }
        )

        $data = @(Get-TeamActivityProfileData -Committers $committers)
        $data[0].InterventionRate | Should -Be 0.0
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
                '作者' = 'alice'; '削除行数' = 20; '他者コード変更行数' = 1
                '他者コード変更生存率' = 0; '総チャーン' = 400
            }
            [pscustomobject]@{
                '作者' = 'bob'; '削除行数' = 6; '他者コード変更行数' = 6
                '他者コード変更生存率' = 0.833; '総チャーン' = 123
            }
        )

        Write-TeamActivityProfileChart -OutDirectory $script:profileDir -Committers $committers -EncodingName 'UTF8'

        $svgPath = Join-Path $script:profileDir 'team_activity_profile.svg'
        Test-Path $svgPath | Should -BeTrue

        $content = Get-Content -Path $svgPath -Raw -Encoding UTF8
        $content | Should -Match '<svg'
        $content | Should -Match '</svg>'
        $content | Should -Match '<circle'
        $content | Should -Match 'alice'
        $content | Should -Match 'bob'
        $content | Should -Match '独立型'
        $content | Should -Match '改善者'
        $content | Should -Match '孤立型'
        $content | Should -Match '破壊者'
        $content | Should -Match '他者コード削除介入度'
        $content | Should -Match '他者コード変更生存率'
    }

    It 'does not create SVG when Committers is empty' {
        Write-TeamActivityProfileChart -OutDirectory $script:profileDir -Committers @() -EncodingName 'UTF8'
        Test-Path (Join-Path $script:profileDir 'team_activity_profile.svg') | Should -BeFalse
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
