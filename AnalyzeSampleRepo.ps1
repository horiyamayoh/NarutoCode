$repoPath = (Resolve-Path "tests\fixtures\svn_repo\repo").Path -replace '\\','/'  
.\NarutoCode.ps1 -RepoUrl "file:///$repoPath" -FromRevision 1 -ToRevision 20 -OutDirectory ".\demo_output"