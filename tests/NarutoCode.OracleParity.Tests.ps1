<#
.SYNOPSIS
Oracle parity integration tests based on raw svn log and svn diff output.
#>

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $script:NarutoScriptPath = Join-Path $script:ProjectRoot 'NarutoCode.ps1'

    function Find-OracleExecutablePath
    {
        <#
        .SYNOPSIS
            Returns the first available executable path from candidate list.
        #>
        param([string[]]$Candidates)
        foreach ($candidate in @($Candidates))
        {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd)
            {
                return [string]$cmd.Source
            }
            if (Test-Path $candidate)
            {
                return [string]$candidate
            }
        }
        return $null
    }

    function Invoke-OracleExternalCommand
    {
        <#
        .SYNOPSIS
            Invokes external command and throws on non-zero exit code.
        #>
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$ErrorContext
        )
        $outputLines = @(& $Executable @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0)
        {
            $text = ($outputLines -join [Environment]::NewLine).Trim()
            if ([string]::IsNullOrWhiteSpace($text))
            {
                $text = '(no output)'
            }
            throw ("{0} failed. executable={1} args={2} output={3}" -f $ErrorContext, $Executable, ($Arguments -join ' '), $text)
        }
        return ($outputLines -join [Environment]::NewLine)
    }

    function ConvertTo-OracleInt
    {
        <#
        .SYNOPSIS
            Converts value to Int32 (blank becomes zero).
        #>
        param([object]$Value)
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text))
        {
            return 0
        }
        return [int]$text
    }

    function Get-OracleDiffLineStat
    {
        <#
        .SYNOPSIS
            Counts +/- lines from raw svn diff output.
        .DESCRIPTION
            Property sections are excluded from counting.
        #>
        param([string]$DiffText)
        $added = 0
        $deleted = 0
        $inPropertySection = $false
        $lines = @($DiffText -split "`r?`n")
        foreach ($line in $lines)
        {
            if ($line -like 'Index: *')
            {
                $inPropertySection = $false
                continue
            }
            if ($line -like 'Property changes on:*')
            {
                $inPropertySection = $true
                continue
            }
            if ($inPropertySection)
            {
                continue
            }
            if ([string]::IsNullOrEmpty($line))
            {
                continue
            }
            if ($line.StartsWith('--- ') -or
                $line.StartsWith('+++ ') -or
                $line.StartsWith('@@ ') -or
                $line.StartsWith('===') -or
                $line.StartsWith('\ No newline at end of file') -or
                $line.StartsWith('Cannot display:') -or
                $line.StartsWith('svn:mime-type = ') -or
                $line.StartsWith('Binary files '))
            {
                continue
            }
            if ($line.StartsWith('+'))
            {
                $added++
                continue
            }
            if ($line.StartsWith('-'))
            {
                $deleted++
                continue
            }
        }
        return [pscustomobject]@{
            Added = [int]$added
            Deleted = [int]$deleted
            Churn = [int]($added + $deleted)
        }
    }

    function Get-OracleCommitRows
    {
        <#
        .SYNOPSIS
            Builds revision-level oracle rows from raw svn log/diff.
        #>
        param(
            [string]$SvnExecutable,
            [string]$RepoUrl,
            [int]$FromRevision,
            [int]$ToRevision
        )
        $logText = Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('log', '--xml', '--verbose', '-r', ("{0}:{1}" -f $FromRevision, $ToRevision), $RepoUrl) -ErrorContext 'svn log'
        $xml = [xml]$logText
        $entries = @($xml.log.logentry | Sort-Object { [int]$_.revision })
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $entries)
        {
            $revision = [int]$entry.revision
            $author = [string]$entry.author
            if ([string]::IsNullOrWhiteSpace($author))
            {
                $author = '(unknown)'
            }

            $filePathEntries = @()
            if ($entry.paths -and $entry.paths.path)
            {
                $filePathEntries = @(
                    $entry.paths.path | Where-Object {
                        $kind = [string]$_.kind
                        [string]::IsNullOrWhiteSpace($kind) -or $kind -ne 'dir'
                    }
                )
            }

            $actionA = 0
            $actionM = 0
            $actionD = 0
            $actionR = 0
            foreach ($pathEntry in $filePathEntries)
            {
                switch ((([string]$pathEntry.action).ToUpperInvariant()))
                {
                    'A' { $actionA++ }
                    'M' { $actionM++ }
                    'D' { $actionD++ }
                    'R' { $actionR++ }
                    default { }
                }
            }

            $diffText = Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('diff', '-c', [string]$revision, $RepoUrl) -ErrorContext ("svn diff -c {0}" -f $revision)
            $lineStat = Get-OracleDiffLineStat -DiffText $diffText

            [void]$rows.Add([pscustomobject]@{
                    Revision = [int]$revision
                    Author = [string]$author
                    FileCount = [int]$filePathEntries.Count
                    Added = [int]$lineStat.Added
                    Deleted = [int]$lineStat.Deleted
                    Churn = [int]$lineStat.Churn
                    ActionA = [int]$actionA
                    ActionM = [int]$actionM
                    ActionD = [int]$actionD
                    ActionR = [int]$actionR
                })
        }
        return @($rows.ToArray())
    }

    function Get-OracleCommitterRows
    {
        <#
        .SYNOPSIS
            Aggregates author-level oracle rows from commit-level oracle rows.
        #>
        param([object[]]$OracleCommitRows)
        $states = @{}
        foreach ($row in @($OracleCommitRows))
        {
            $author = [string]$row.Author
            if (-not $states.ContainsKey($author))
            {
                $states[$author] = [pscustomobject]@{
                    Author = $author
                    CommitCount = 0
                    Added = 0
                    Deleted = 0
                    Churn = 0
                    ActionA = 0
                    ActionM = 0
                    ActionD = 0
                    ActionR = 0
                }
            }
            $state = $states[$author]
            $state.CommitCount += 1
            $state.Added += [int]$row.Added
            $state.Deleted += [int]$row.Deleted
            $state.Churn += [int]$row.Churn
            $state.ActionA += [int]$row.ActionA
            $state.ActionM += [int]$row.ActionM
            $state.ActionD += [int]$row.ActionD
            $state.ActionR += [int]$row.ActionR
        }
        return @($states.Values | Sort-Object Author)
    }

    function Get-ActualCommitRows
    {
        <#
        .SYNOPSIS
            Loads comparable commit rows from NarutoCode commits.csv.
        #>
        param([string]$OutDirectory)
        $rows = @(Import-Csv -Path (Join-Path $OutDirectory 'commits.csv') -Encoding UTF8)
        $result = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $rows)
        {
            [void]$result.Add([pscustomobject]@{
                    Revision = ConvertTo-OracleInt -Value $row.'リビジョン'
                    FileCount = ConvertTo-OracleInt -Value $row.'変更ファイル数'
                    Added = ConvertTo-OracleInt -Value $row.'追加行数'
                    Deleted = ConvertTo-OracleInt -Value $row.'削除行数'
                    Churn = ConvertTo-OracleInt -Value $row.'チャーン'
                })
        }
        return @($result.ToArray() | Sort-Object Revision)
    }

    function Get-ActualCommitterRows
    {
        <#
        .SYNOPSIS
            Loads comparable committer rows from NarutoCode committers.csv.
        #>
        param([string]$OutDirectory)
        $rows = @(Import-Csv -Path (Join-Path $OutDirectory 'committers.csv') -Encoding UTF8)
        $result = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $rows)
        {
            [void]$result.Add([pscustomobject]@{
                    Author = [string]$row.'作者'
                    CommitCount = ConvertTo-OracleInt -Value $row.'コミット数'
                    Added = ConvertTo-OracleInt -Value $row.'追加行数'
                    Deleted = ConvertTo-OracleInt -Value $row.'削除行数'
                    Churn = ConvertTo-OracleInt -Value $row.'総チャーン'
                    ActionA = ConvertTo-OracleInt -Value $row.'追加アクション数'
                    ActionM = ConvertTo-OracleInt -Value $row.'変更アクション数'
                    ActionD = ConvertTo-OracleInt -Value $row.'削除アクション数'
                    ActionR = ConvertTo-OracleInt -Value $row.'置換アクション数'
                })
        }
        return @($result.ToArray() | Sort-Object Author)
    }

    function Assert-OracleMismatchFree
    {
        <#
        .SYNOPSIS
            Fails when mismatch list is non-empty.
        #>
        param(
            [System.Collections.Generic.List[string]]$Mismatches,
            [string]$Label
        )
        if ($Mismatches.Count -gt 0)
        {
            $preview = (@($Mismatches | Select-Object -First 30) -join [Environment]::NewLine)
            $Mismatches.Count | Should -Be 0 -Because ("{0} mismatch detected`n{1}" -f $Label, $preview)
            return
        }
        $Mismatches.Count | Should -Be 0
    }

    function Assert-OracleCommitParity
    {
        <#
        .SYNOPSIS
            Compares oracle and NarutoCode commit-level metrics.
        #>
        param(
            [object[]]$OracleRows,
            [object[]]$ActualRows,
            [string]$Label
        )
        $mismatches = New-Object 'System.Collections.Generic.List[string]'
        $actualByRevision = @{}
        foreach ($row in @($ActualRows))
        {
            $actualByRevision[[int]$row.Revision] = $row
        }

        if (@($OracleRows).Count -ne @($ActualRows).Count)
        {
            [void]$mismatches.Add(("{0}: row count actual={1} oracle={2}" -f $Label, @($ActualRows).Count, @($OracleRows).Count))
        }

        foreach ($oracle in @($OracleRows))
        {
            $revision = [int]$oracle.Revision
            if (-not $actualByRevision.ContainsKey($revision))
            {
                [void]$mismatches.Add(("{0}: missing actual row r{1}" -f $Label, $revision))
                continue
            }
            $actual = $actualByRevision[$revision]
            if ([int]$actual.FileCount -ne [int]$oracle.FileCount)
            {
                [void]$mismatches.Add(("{0}: r{1} file count actual={2} oracle={3}" -f $Label, $revision, [int]$actual.FileCount, [int]$oracle.FileCount))
            }
            if ([int]$actual.Added -ne [int]$oracle.Added)
            {
                [void]$mismatches.Add(("{0}: r{1} added actual={2} oracle={3}" -f $Label, $revision, [int]$actual.Added, [int]$oracle.Added))
            }
            if ([int]$actual.Deleted -ne [int]$oracle.Deleted)
            {
                [void]$mismatches.Add(("{0}: r{1} deleted actual={2} oracle={3}" -f $Label, $revision, [int]$actual.Deleted, [int]$oracle.Deleted))
            }
            if ([int]$actual.Churn -ne [int]$oracle.Churn)
            {
                [void]$mismatches.Add(("{0}: r{1} churn actual={2} oracle={3}" -f $Label, $revision, [int]$actual.Churn, [int]$oracle.Churn))
            }
        }

        Assert-OracleMismatchFree -Mismatches $mismatches -Label ("{0} commits.csv parity" -f $Label)
    }

    function Assert-OracleCommitterParity
    {
        <#
        .SYNOPSIS
            Compares oracle and NarutoCode committer-level metrics.
        #>
        param(
            [object[]]$OracleRows,
            [object[]]$ActualRows,
            [string]$Label
        )
        $mismatches = New-Object 'System.Collections.Generic.List[string]'
        $actualByAuthor = @{}
        foreach ($row in @($ActualRows))
        {
            $actualByAuthor[[string]$row.Author] = $row
        }

        if (@($OracleRows).Count -ne @($ActualRows).Count)
        {
            [void]$mismatches.Add(("{0}: row count actual={1} oracle={2}" -f $Label, @($ActualRows).Count, @($OracleRows).Count))
        }

        foreach ($oracle in @($OracleRows))
        {
            $author = [string]$oracle.Author
            if (-not $actualByAuthor.ContainsKey($author))
            {
                [void]$mismatches.Add(("{0}: missing actual row author={1}" -f $Label, $author))
                continue
            }
            $actual = $actualByAuthor[$author]
            if ([int]$actual.CommitCount -ne [int]$oracle.CommitCount)
            {
                [void]$mismatches.Add(("{0}: {1} commit count actual={2} oracle={3}" -f $Label, $author, [int]$actual.CommitCount, [int]$oracle.CommitCount))
            }
            if ([int]$actual.Added -ne [int]$oracle.Added)
            {
                [void]$mismatches.Add(("{0}: {1} added actual={2} oracle={3}" -f $Label, $author, [int]$actual.Added, [int]$oracle.Added))
            }
            if ([int]$actual.Deleted -ne [int]$oracle.Deleted)
            {
                [void]$mismatches.Add(("{0}: {1} deleted actual={2} oracle={3}" -f $Label, $author, [int]$actual.Deleted, [int]$oracle.Deleted))
            }
            if ([int]$actual.Churn -ne [int]$oracle.Churn)
            {
                [void]$mismatches.Add(("{0}: {1} churn actual={2} oracle={3}" -f $Label, $author, [int]$actual.Churn, [int]$oracle.Churn))
            }
            if ([int]$actual.ActionA -ne [int]$oracle.ActionA)
            {
                [void]$mismatches.Add(("{0}: {1} action A actual={2} oracle={3}" -f $Label, $author, [int]$actual.ActionA, [int]$oracle.ActionA))
            }
            if ([int]$actual.ActionM -ne [int]$oracle.ActionM)
            {
                [void]$mismatches.Add(("{0}: {1} action M actual={2} oracle={3}" -f $Label, $author, [int]$actual.ActionM, [int]$oracle.ActionM))
            }
            if ([int]$actual.ActionD -ne [int]$oracle.ActionD)
            {
                [void]$mismatches.Add(("{0}: {1} action D actual={2} oracle={3}" -f $Label, $author, [int]$actual.ActionD, [int]$oracle.ActionD))
            }
            if ([int]$actual.ActionR -ne [int]$oracle.ActionR)
            {
                [void]$mismatches.Add(("{0}: {1} action R actual={2} oracle={3}" -f $Label, $author, [int]$actual.ActionR, [int]$oracle.ActionR))
            }
        }

        Assert-OracleMismatchFree -Mismatches $mismatches -Label ("{0} committers.csv parity" -f $Label)
    }

    function Invoke-NarutoCodeOracleRun
    {
        <#
        .SYNOPSIS
            Runs NarutoCode and loads comparable CSV rows.
        #>
        param(
            [string]$NarutoScriptPath,
            [string]$RepoUrl,
            [int]$FromRevision,
            [int]$ToRevision,
            [string]$SvnExecutable,
            [string]$OutDirectory,
            [switch]$ExcludeCommentOnlyLines
        )
        $null = & $NarutoScriptPath `
            -RepoUrl $RepoUrl `
            -FromRevision $FromRevision `
            -ToRevision $ToRevision `
            -OutDirectory $OutDirectory `
            -SvnExecutable $SvnExecutable `
            -Encoding UTF8 `
            -NoProgress `
            -ExcludeCommentOnlyLines:$ExcludeCommentOnlyLines `
            -ErrorAction Stop

        return [pscustomobject]@{
            CommitRows = @(Get-ActualCommitRows -OutDirectory $OutDirectory)
            CommitterRows = @(Get-ActualCommitterRows -OutDirectory $OutDirectory)
        }
    }

    function New-OracleScenarioRepository
    {
        <#
        .SYNOPSIS
            Creates temporary SVN repository with oracle stress scenarios.
        #>
        param(
            [string]$SvnExecutable,
            [string]$SvnAdminExecutable
        )
        $rootDir = Join-Path $env:TEMP ('narutocode_oracle_repo_' + [guid]::NewGuid().ToString('N'))
        $repoDir = Join-Path $rootDir 'repo'
        $wcDir = Join-Path $rootDir 'wc'
        New-Item -Path $rootDir -ItemType Directory -Force | Out-Null

        try
        {
            [void](Invoke-OracleExternalCommand -Executable $SvnAdminExecutable -Arguments @('create', $repoDir) -ErrorContext 'svnadmin create')
            Set-Content -Path (Join-Path $repoDir 'hooks\pre-revprop-change.bat') -Value 'exit 0' -Encoding ASCII

            $repoUrl = 'file:///' + ($repoDir -replace '\\', '/')
            [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('checkout', $repoUrl, $wcDir, '--quiet') -ErrorContext 'svn checkout')

            $srcDir = Join-Path $wcDir 'src'
            New-Item -Path $srcDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $srcDir 'a.txt') -Value "alpha`r`nbeta`r`n" -Encoding UTF8 -NoNewline
            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('add', 'src/a.txt', '--parents', '--force', '--quiet') -ErrorContext 'svn add r1')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r1 add text file', '--quiet') -ErrorContext 'svn commit r1')
            }
            finally
            {
                Pop-Location
            }

            $aPath = Join-Path $srcDir 'a.txt'
            $aText = Get-Content -Path $aPath -Raw
            $aText = $aText -replace 'beta', 'beta   '
            Set-Content -Path $aPath -Value $aText -Encoding UTF8 -NoNewline
            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r2 whitespace only update', '--quiet') -ErrorContext 'svn commit r2')
            }
            finally
            {
                Pop-Location
            }

            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('move', 'src/a.txt', 'src/b.txt', '--quiet') -ErrorContext 'svn move r3')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r3 rename a to b', '--quiet') -ErrorContext 'svn commit r3')
            }
            finally
            {
                Pop-Location
            }

            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('delete', 'src/b.txt', '--quiet') -ErrorContext 'svn delete r4')
                Set-Content -Path (Join-Path $wcDir 'src\b.txt') -Value "replacement`r`ncontent`r`n" -Encoding UTF8 -NoNewline
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('add', 'src/b.txt', '--quiet') -ErrorContext 'svn add r4')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r4 replace same path', '--quiet') -ErrorContext 'svn commit r4')
            }
            finally
            {
                Pop-Location
            }

            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('propset', 'svn:eol-style', 'native', 'src/b.txt', '--quiet') -ErrorContext 'svn propset r5')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r5 property only change', '--quiet') -ErrorContext 'svn commit r5')
            }
            finally
            {
                Pop-Location
            }

            $assetsDir = Join-Path $wcDir 'assets'
            New-Item -Path $assetsDir -ItemType Directory -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $assetsDir 'logo.bin'), [byte[]](0, 1, 2, 3, 4, 5, 6, 7, 8, 9))
            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('add', 'assets/logo.bin', '--parents', '--force', '--quiet') -ErrorContext 'svn add r6')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('propset', 'svn:mime-type', 'application/octet-stream', 'assets/logo.bin', '--quiet') -ErrorContext 'svn propset mime r6')
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r6 add binary asset', '--quiet') -ErrorContext 'svn commit r6')
            }
            finally
            {
                Pop-Location
            }

            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('copy', 'src/b.txt', 'src/c.txt', '--quiet') -ErrorContext 'svn copy r7')
            }
            finally
            {
                Pop-Location
            }

            $cPath = Join-Path $wcDir 'src\c.txt'
            $cText = Get-Content -Path $cPath -Raw
            $cText = $cText + "`r`ncopy edit"
            Set-Content -Path $cPath -Value $cText -Encoding UTF8 -NoNewline
            Push-Location $wcDir
            try
            {
                [void](Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('commit', '-m', 'r7 copyfrom and edit', '--quiet') -ErrorContext 'svn commit r7')
            }
            finally
            {
                Pop-Location
            }

            $infoXmlText = Invoke-OracleExternalCommand -Executable $SvnExecutable -Arguments @('info', '--xml', $repoUrl) -ErrorContext 'svn info'
            $infoXml = [xml]$infoXmlText
            $toRevision = [int]$infoXml.info.entry.revision

            return [pscustomobject]@{
                RootDir = $rootDir
                RepoDir = $repoDir
                WorkingCopyDir = $wcDir
                RepoUrl = $repoUrl
                FromRevision = 1
                ToRevision = $toRevision
            }
        }
        catch
        {
            if (Test-Path $rootDir)
            {
                Remove-Item -Path $rootDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    $script:SvnExecutable = Find-OracleExecutablePath -Candidates @(
        'svn',
        'svn.exe',
        'C:\Program Files\SlikSvn\bin\svn.exe',
        'C:\Program Files\TortoiseSVN\bin\svn.exe',
        'C:\Program Files (x86)\SlikSvn\bin\svn.exe'
    )
    $script:SvnAdminExecutable = Find-OracleExecutablePath -Candidates @(
        'svnadmin',
        'svnadmin.exe',
        'C:\Program Files\SlikSvn\bin\svnadmin.exe',
        'C:\Program Files\TortoiseSVN\bin\svnadmin.exe',
        'C:\Program Files (x86)\SlikSvn\bin\svnadmin.exe'
    )
}

$script:fixtureSkipReason = $null
$script:scenarioSkipReason = $null

Describe 'Oracle parity integration - fixture repository' -Tag 'Integration', 'Oracle' {
    BeforeAll {
        $script:fixtureSkipReason = $null
        $script:fixtureOutDir = $null
        $script:fixtureOutDirExclude = $null
        $script:fixtureOracleCommitRows = @()
        $script:fixtureOracleCommitterRows = @()
        $script:fixtureActualCommitRows = @()
        $script:fixtureActualCommitterRows = @()
        $script:fixtureActualCommitRowsExclude = @()

        if (-not $script:SvnExecutable)
        {
            $script:fixtureSkipReason = 'svn executable not found'
            return
        }

        $fixtureRepoDir = Join-Path $script:ProjectRoot 'tests\fixtures\svn_repo\repo'
        if (-not (Test-Path $fixtureRepoDir))
        {
            $script:fixtureSkipReason = 'fixture svn repository not found'
            return
        }

        $fixtureRepoUrl = 'file:///' + ($fixtureRepoDir -replace '\\', '/')
        $script:fixtureOutDir = Join-Path $env:TEMP ('narutocode_oracle_fixture_' + [guid]::NewGuid().ToString('N'))
        $script:fixtureOutDirExclude = Join-Path $env:TEMP ('narutocode_oracle_fixture_exclude_' + [guid]::NewGuid().ToString('N'))

        $runResult = Invoke-NarutoCodeOracleRun `
            -NarutoScriptPath $script:NarutoScriptPath `
            -RepoUrl $fixtureRepoUrl `
            -FromRevision 1 `
            -ToRevision 20 `
            -SvnExecutable $script:SvnExecutable `
            -OutDirectory $script:fixtureOutDir

        $script:fixtureActualCommitRows = @($runResult.CommitRows)
        $script:fixtureActualCommitterRows = @($runResult.CommitterRows)
        $runResultExclude = Invoke-NarutoCodeOracleRun `
            -NarutoScriptPath $script:NarutoScriptPath `
            -RepoUrl $fixtureRepoUrl `
            -FromRevision 1 `
            -ToRevision 20 `
            -SvnExecutable $script:SvnExecutable `
            -OutDirectory $script:fixtureOutDirExclude `
            -ExcludeCommentOnlyLines
        $script:fixtureActualCommitRowsExclude = @($runResultExclude.CommitRows)
        $script:fixtureOracleCommitRows = @(Get-OracleCommitRows -SvnExecutable $script:SvnExecutable -RepoUrl $fixtureRepoUrl -FromRevision 1 -ToRevision 20)
        $script:fixtureOracleCommitterRows = @(Get-OracleCommitterRows -OracleCommitRows $script:fixtureOracleCommitRows)
    }

    AfterAll {
        if ($script:fixtureOutDir -and (Test-Path $script:fixtureOutDir))
        {
            Remove-Item -Path $script:fixtureOutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:fixtureOutDirExclude -and (Test-Path $script:fixtureOutDirExclude))
        {
            Remove-Item -Path $script:fixtureOutDirExclude -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'matches commits.csv against svn log/diff oracle' -Skip:($null -ne $script:fixtureSkipReason) {
        Assert-OracleCommitParity -OracleRows $script:fixtureOracleCommitRows -ActualRows $script:fixtureActualCommitRows -Label 'fixture r1-r20'
    }

    It 'matches committers.csv against svn log/diff oracle' -Skip:($null -ne $script:fixtureSkipReason) {
        Assert-OracleCommitterParity -OracleRows $script:fixtureOracleCommitterRows -ActualRows $script:fixtureActualCommitterRows -Label 'fixture r1-r20'
    }

    It 'keeps comment-exclusion ON commit counts less than or equal to oracle raw diff counts' -Skip:($null -ne $script:fixtureSkipReason) {
        $oracleByRevision = @{}
        foreach ($row in @($script:fixtureOracleCommitRows))
        {
            $oracleByRevision[[int]$row.Revision] = $row
        }
        foreach ($actual in @($script:fixtureActualCommitRowsExclude))
        {
            $revision = [int]$actual.Revision
            $oracle = $oracleByRevision[$revision]
            ([int]$actual.Added -le [int]$oracle.Added) | Should -BeTrue
            ([int]$actual.Deleted -le [int]$oracle.Deleted) | Should -BeTrue
            ([int]$actual.Churn -le [int]$oracle.Churn) | Should -BeTrue
        }
        $meta = Get-Content -Path (Join-Path $script:fixtureOutDirExclude 'run_meta.json') -Raw | ConvertFrom-Json
        [bool]$meta.Parameters.ExcludeCommentOnlyLines | Should -BeTrue
    }
}

Describe 'Oracle parity integration - generated scenario repository' -Tag 'Integration', 'Oracle' {
    BeforeAll {
        $script:scenarioSkipReason = $null
        $script:scenarioRepo = $null
        $script:scenarioOutDir = $null
        $script:scenarioOracleCommitRows = @()
        $script:scenarioOracleCommitterRows = @()
        $script:scenarioActualCommitRows = @()
        $script:scenarioActualCommitterRows = @()

        if (-not $script:SvnExecutable)
        {
            $script:scenarioSkipReason = 'svn executable not found'
            return
        }
        if (-not $script:SvnAdminExecutable)
        {
            $script:scenarioSkipReason = 'svnadmin executable not found'
            return
        }

        $script:scenarioRepo = New-OracleScenarioRepository -SvnExecutable $script:SvnExecutable -SvnAdminExecutable $script:SvnAdminExecutable
        $script:scenarioOutDir = Join-Path $env:TEMP ('narutocode_oracle_generated_' + [guid]::NewGuid().ToString('N'))

        $runResult = Invoke-NarutoCodeOracleRun `
            -NarutoScriptPath $script:NarutoScriptPath `
            -RepoUrl $script:scenarioRepo.RepoUrl `
            -FromRevision $script:scenarioRepo.FromRevision `
            -ToRevision $script:scenarioRepo.ToRevision `
            -SvnExecutable $script:SvnExecutable `
            -OutDirectory $script:scenarioOutDir

        $script:scenarioActualCommitRows = @($runResult.CommitRows)
        $script:scenarioActualCommitterRows = @($runResult.CommitterRows)
        $script:scenarioOracleCommitRows = @(Get-OracleCommitRows -SvnExecutable $script:SvnExecutable -RepoUrl $script:scenarioRepo.RepoUrl -FromRevision $script:scenarioRepo.FromRevision -ToRevision $script:scenarioRepo.ToRevision)
        $script:scenarioOracleCommitterRows = @(Get-OracleCommitterRows -OracleCommitRows $script:scenarioOracleCommitRows)
    }

    AfterAll {
        if ($script:scenarioOutDir -and (Test-Path $script:scenarioOutDir))
        {
            Remove-Item -Path $script:scenarioOutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:scenarioRepo -and $script:scenarioRepo.RootDir -and (Test-Path $script:scenarioRepo.RootDir))
        {
            Remove-Item -Path $script:scenarioRepo.RootDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'matches commits.csv for generated scenario with rename/copy/R/property/binary/whitespace cases' -Skip:($null -ne $script:scenarioSkipReason) {
        Assert-OracleCommitParity -OracleRows $script:scenarioOracleCommitRows -ActualRows $script:scenarioActualCommitRows -Label 'generated scenario'
    }

    It 'matches committers.csv for generated scenario with action counters' -Skip:($null -ne $script:scenarioSkipReason) {
        Assert-OracleCommitterParity -OracleRows $script:scenarioOracleCommitterRows -ActualRows $script:scenarioActualCommitterRows -Label 'generated scenario'
    }
}
