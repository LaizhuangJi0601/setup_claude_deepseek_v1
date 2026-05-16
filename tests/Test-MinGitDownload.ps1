$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "setup_claude_deepseek_v1.ps1"

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw ("PowerShell parse errors: {0}" -f (($parseErrors | ForEach-Object { $_.Message }) -join "; "))
}

$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-MinGitAssetFileNameCandidates"
}, $true)

if (-not $functionAst) {
    throw "Get-MinGitAssetFileNameCandidates function is missing."
}

. ([scriptblock]::Create($functionAst.Extent.Text))

$candidates = @(Get-MinGitAssetFileNameCandidates -Tag "v2.54.0.windows.1")
if ($candidates.Count -eq 0) {
    throw "No MinGit candidates returned."
}

$expectedFirst = "MinGit-2.54.0-64-bit.zip"
if ($candidates[0] -ne $expectedFirst) {
    throw ("Expected first MinGit candidate '{0}', got '{1}'." -f $expectedFirst, $candidates[0])
}

$invalidFirst = "MinGit-2.54.0.windows.1-64-bit.zip"
if ($candidates[0] -eq $invalidFirst) {
    throw ("Invalid Git for Windows tag version was used as the first asset name: {0}" -f $invalidFirst)
}

Write-Host "MinGit download tests passed."
