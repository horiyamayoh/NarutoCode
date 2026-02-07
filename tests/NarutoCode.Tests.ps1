<#
.SYNOPSIS
Pester tests for NarutoCode Phase 1.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:ScriptPath = Join-Path (Join-Path $here '..') 'NarutoCode.ps1'

    $scriptContent = Get-Content -Path $script:ScriptPath -Raw -Encoding UTF8
    $regionPattern = '(?s)(# region Utility.*?# endregion Utility)'
    if ($scriptContent -match $regionPattern) {
        $functionBlock = $Matches[1]
        $script:SvnExecutable = 'svn'
        $script:SvnGlobalArguments = @()
        $tempFile = Join-Path $env:TEMP ('NarutoCode_functions_' + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -Path $tempFile -Value $functionBlock -Encoding UTF8
        . $tempFile
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
    else {
        throw 'Could not extract utility functions from NarutoCode.ps1.'
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
        $alice = $rows | Where-Object { $_.Author -eq 'alice' }
        $alice.CommitCount | Should -Be 1
        $alice.AddedLines | Should -Be 5
        $alice.ActionAddCount | Should -Be 1
        $alice.IssueIdMentionCount | Should -Be 1
    }

    It 'computes file metrics and hotspot rank' {
        $rows = @(Get-FileMetric -Commits $script:mockCommits)
        $a = $rows | Where-Object { $_.FilePath -eq 'src/A.cs' }
        $a.FileCommitCount | Should -Be 2
        $a.FileAuthors | Should -Be 2
        $a.HotspotScore | Should -Be 14
    }

    It 'computes co-change metrics' {
        $rows = @(Get-CoChangeMetric -Commits $script:mockCommits -TopNCount 10)
        $rows.Count | Should -Be 1
        $rows[0].FileA | Should -Be 'src/A.cs'
        $rows[0].FileB | Should -Be 'src/B.cs'
        $rows[0].CoChangeCount | Should -Be 1
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
        $names = @('OutDir','Username','Password','NonInteractive','TrustServerCert','NoBlame','Parallel','IncludePaths','EmitPlantUml','TopN','Encoding')
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
            $script:alice = $script:cRows | Where-Object { $_.Author -eq 'alice' }
            $script:bob = $script:cRows | Where-Object { $_.Author -eq 'bob' }
        }

        It 'counts commits per author correctly' {
            $script:alice.CommitCount | Should -Be 2
            $script:bob.CommitCount | Should -Be 1
        }

        It 'counts active days' {
            $script:alice.ActiveDays | Should -Be 2  # Jan 1 and Jan 2
            $script:bob.ActiveDays | Should -Be 1
        }

        It 'counts unique files and dirs' {
            $script:alice.FilesTouched | Should -Be 2   # src/A.cs, src/B.cs
            $script:alice.DirsTouched | Should -Be 1    # src
        }

        It 'sums added/deleted lines' {
            $script:alice.AddedLines | Should -Be 18    # 13 + 5
            $script:alice.DeletedLines | Should -Be 6   # 1 + 5
            $script:alice.NetLines | Should -Be 12
            $script:alice.TotalChurn | Should -Be 24
        }

        It 'calculates ChurnPerCommit' {
            $script:alice.ChurnPerCommit | Should -Be (Get-RoundedNumber -Value (24.0 / 2))
        }

        It 'calculates DeletedToAddedRatio' {
            $script:alice.DeletedToAddedRatio | Should -Be (Get-RoundedNumber -Value (6.0 / 18))
        }

        It 'calculates ChurnToNetRatio' {
            $script:alice.ChurnToNetRatio | Should -Be (Get-RoundedNumber -Value (24.0 / 12))
        }

        It 'detects action types' {
            $script:alice.ActionModCount | Should -Be 2   # M on A.cs in rev1 + M on A.cs in rev2
            $script:alice.ActionAddCount | Should -Be 1   # A on B.cs in rev1
        }

        It 'calculates AvgCoAuthorsPerTouchedFile correctly' {
            # src/A.cs is touched by alice & bob => co-authors=1 for alice
            # src/B.cs is touched by alice only => co-authors=0 for alice
            # Average for alice = (1+0)/2 = 0.5
            $script:alice.AvgCoAuthorsPerTouchedFile | Should -Be 0.5
        }

        It 'detects message keywords' {
            $script:alice.IssueIdMentionCount | Should -Be 1  # #123
            $script:alice.FixKeywordCount | Should -Be 1
            $script:bob.MergeKeywordCount | Should -Be 1
            $script:bob.IssueIdMentionCount | Should -Be 1    # PROJ-99
        }

        It 'calculates average message length' {
            # alice: msg lengths are 8 + 8 = 16, avg = 8
            $script:alice.MsgLenAvgChars | Should -Be 8.0
        }
    }

    Context 'Get-FileMetric detailed' {
        BeforeAll {
            $script:fRows = @(Get-FileMetric -Commits $script:detailedCommits)
            $script:fileA = $script:fRows | Where-Object { $_.FilePath -eq 'src/A.cs' }
            $script:fileB = $script:fRows | Where-Object { $_.FilePath -eq 'src/B.cs' }
        }

        It 'counts commits and authors per file' {
            $script:fileA.FileCommitCount | Should -Be 3   # rev 1, 2, 3
            $script:fileA.FileAuthors | Should -Be 2       # alice, bob
            $script:fileB.FileCommitCount | Should -Be 1
            $script:fileB.FileAuthors | Should -Be 1
        }

        It 'sums added/deleted lines per file' {
            $script:fileA.AddedLines | Should -Be 10       # 3 + 5 + 2
            $script:fileA.DeletedLines | Should -Be 6      # 1 + 5 + 0
            $script:fileA.NetLines | Should -Be 4
            $script:fileA.TotalChurn | Should -Be 16
        }

        It 'tracks first and last revision' {
            $script:fileA.FirstChangeRev | Should -Be 1
            $script:fileA.LastChangeRev | Should -Be 3
            $script:fileB.FirstChangeRev | Should -Be 1
            $script:fileB.LastChangeRev | Should -Be 1
        }

        It 'calculates HotspotScore = commits * churn' {
            $script:fileA.HotspotScore | Should -Be (3 * 16)   # 48
            $script:fileB.HotspotScore | Should -Be (1 * 10)   # 10
        }

        It 'assigns rank by hotspot descending' {
            $script:fileA.RankByHotspot | Should -BeLessThan $script:fileB.RankByHotspot
        }

        It 'calculates TopAuthorShareByChurn' {
            # src/A.cs total churn=16, alice churn=14, bob churn=2 => top share = 14/16
            $expected = Get-RoundedNumber -Value (14.0 / 16)
            $script:fileA.TopAuthorShareByChurn | Should -Be $expected
        }

        It 'calculates AvgDaysBetweenChanges' {
            # src/A.cs changed on Jan 1, Jan 2, Jan 3 => intervals = 1, 1 => avg = 1.0
            $script:fileA.AvgDaysBetweenChanges | Should -Be 1.0
            # src/B.cs changed only once => avg = 0
            $script:fileB.AvgDaysBetweenChanges | Should -Be 0.0
        }

        It 'counts create/delete/replace actions' {
            $script:fileB.CreateCount | Should -Be 1   # Action='A' maps to Create
        }
    }

    Context 'Get-CoChangeMetric detailed' {
        BeforeAll {
            $script:coRows = @(Get-CoChangeMetric -Commits $script:detailedCommits -TopNCount 10)
        }

        It 'finds co-change pairs' {
            $script:coRows.Count | Should -Be 1
            $script:coRows[0].FileA | Should -Be 'src/A.cs'
            $script:coRows[0].FileB | Should -Be 'src/B.cs'
            $script:coRows[0].CoChangeCount | Should -Be 1
        }

        It 'calculates Jaccard correctly' {
            # A.cs appears in 3 commits, B.cs in 1, co-change=1
            # Jaccard = 1 / (3+1-1) = 1/3
            $expected = Get-RoundedNumber -Value (1.0 / 3)
            $script:coRows[0].Jaccard | Should -Be $expected
        }

        It 'calculates Lift correctly' {
            # Total commits=3, P(A)=3/3=1, P(B)=1/3, P(AB)=1/3
            # Lift = (1/3) / (1 * 1/3) = 1.0
            $script:coRows[0].Lift | Should -Be 1.0
        }

        It 'respects TopNCount limit' {
            $limited = @(Get-CoChangeMetric -Commits $script:detailedCommits -TopNCount 0)
            # TopNCount=0 means no limit in the code (returns all)
            $limited.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'Get-CoChangeMetric with LargeCommitFileThreshold' {
        It 'skips commits exceeding threshold' {
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
            $result = @(Get-CoChangeMetric -Commits @($bigCommit) -TopNCount 100 -LargeCommitFileThreshold 100)
            # Over 100 files, so no pairs should be generated
            $result.Count | Should -Be 0
        }
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
        $committers = @([pscustomobject]@{ Author='alice'; CommitCount=5; TotalChurn=100 })
        $files = @([pscustomobject]@{ FilePath='src/A.cs'; RankByHotspot=1; HotspotScore=500 })
        $couplings = @([pscustomobject]@{ FileA='src/A.cs'; FileB='src/B.cs'; CoChangeCount=3; Jaccard=0.5 })

        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers $committers -Files $files -Couplings $couplings -TopNCount 50 -EncodingName 'UTF8'

        Test-Path (Join-Path $script:pumlDir 'contributors_summary.puml') | Should -BeTrue
        Test-Path (Join-Path $script:pumlDir 'hotspots.puml') | Should -BeTrue
        Test-Path (Join-Path $script:pumlDir 'cochange_network.puml') | Should -BeTrue
    }

    It 'contributors puml contains @startuml/@enduml and author data' {
        $committers = @([pscustomobject]@{ Author='bob'; CommitCount=3; TotalChurn=50 })
        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers $committers -Files @() -Couplings @() -TopNCount 50 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:pumlDir 'contributors_summary.puml') -Raw
        $content | Should -Match '@startuml'
        $content | Should -Match '@enduml'
        $content | Should -Match 'bob'
    }

    It 'cochange puml contains network edges' {
        $couplings = @([pscustomobject]@{ FileA='X.cs'; FileB='Y.cs'; CoChangeCount=2; Jaccard=0.75 })
        Write-PlantUmlFile -OutDirectory $script:pumlDir -Committers @() -Files @() -Couplings $couplings -TopNCount 50 -EncodingName 'UTF8'

        $content = Get-Content -Path (Join-Path $script:pumlDir 'cochange_network.puml') -Raw
        $content | Should -Match 'X\.cs'
        $content | Should -Match 'Y\.cs'
        $content | Should -Match 'co=2'
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
                    -NoBlame `
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

    It 'has DeadDetailLevel parameter with range 0-2' {
        $script:cmd.Parameters['DeadDetailLevel'] | Should -Not -BeNullOrEmpty
        $script:cmd.Parameters['DeadDetailLevel'].ParameterType.Name | Should -Be 'Int32'
    }
}