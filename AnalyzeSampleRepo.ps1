$repoPath = (Resolve-Path "tests\fixtures\svn_repo\repo").Path -replace '\\','/'
$info = svn info --xml "file:///$repoPath"
$headRev = [int]([xml]$info).info.entry.revision
.\NarutoCode.ps1 -RepoUrl "file:///$repoPath" -FromRevision 1 -ToRevision $headRev -OutDirectory ".\demo_output"