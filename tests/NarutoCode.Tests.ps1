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

Describe 'Parse-SvnLogXml' {
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
        $commits = @(Parse-SvnLogXml -XmlText $xml)
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
        $commits = @(Parse-SvnLogXml -XmlText $xml)
        $commits[0].Author | Should -Be '(unknown)'
    }
}

Describe 'Parse-SvnUnifiedDiff' {
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
        $parsed = Parse-SvnUnifiedDiff -DiffText $diff
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
        $parsed = Parse-SvnUnifiedDiff -DiffText $diff
        $parsed['trunk/bin/data.bin'].IsBinary | Should -BeTrue
    }
}

Describe 'Parse-SvnBlameXml' {
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
        $summary = Parse-SvnBlameXml -XmlText $xml
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
        $rows = @(Compute-CommitterMetrics -Commits $script:mockCommits)
        $alice = $rows | Where-Object { $_.Author -eq 'alice' }
        $alice.CommitCount | Should -Be 1
        $alice.AddedLines | Should -Be 5
        $alice.ActionAddCount | Should -Be 1
        $alice.IssueIdMentionCount | Should -Be 1
    }

    It 'computes file metrics and hotspot rank' {
        $rows = @(Compute-FileMetrics -Commits $script:mockCommits)
        $a = $rows | Where-Object { $_.FilePath -eq 'src/A.cs' }
        $a.FileCommitCount | Should -Be 2
        $a.FileAuthors | Should -Be 2
        $a.HotspotScore | Should -Be 14
    }

    It 'computes co-change metrics' {
        $rows = @(Compute-CoChangeMetrics -Commits $script:mockCommits -TopNCount 10)
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
