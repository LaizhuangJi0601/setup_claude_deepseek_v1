# path.ps1 — 用户 PATH 管理

function Add-UserPath {
    param([Parameter(Mandatory = $true)][string]$PathToAdd)

    $resolved = [IO.Path]::GetFullPath($PathToAdd).TrimEnd("\")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts    = @(Split-PathList -Value $userPath)
    $exists   = $false

    foreach ($part in $parts) {
        if ($part.TrimEnd("\").Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newPath = (@($resolved + $parts) -join ';')
        Set-UserEnv -Name "Path" -Value $newPath
        Publish-UserEnvironmentChange
    }

    $processParts  = @(Split-PathList -Value $env:Path)
    $processExists = $false
    foreach ($part in $processParts) {
        if ($part.TrimEnd("\").Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            $processExists = $true
            break
        }
    }

    if (-not $processExists) {
        $env:Path = (@($resolved + $processParts) -join ';')
    }
}

function Repair-UserPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { return }

    $escapedRoot = [regex]::Escape($Script:RootDir)
    $matches = [regex]::Matches($userPath, "$escapedRoot(\\[^;]*)?")
    if ($matches.Count -le 1) { return }

    Write-Warn "检测到用户 PATH 中 ClaudeCodeCLI 条目异常（可能缺少分隔符），正在修复..."
    $fixed = $userPath
    foreach ($m in $matches) {
        $fixed = $fixed.Replace($m.Value, ";$($m.Value);")
    }
    $fixed = ($fixed -replace ";;+", ";") -replace "^;|;$", ""
    Set-UserEnv -Name "Path" -Value $fixed
    Publish-UserEnvironmentChange
    Write-Ok "PATH 已修复。"
}

function Sync-ClaudeCodeCLIPath {
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $escapedRoot = [regex]::Escape($Script:RootDir)
    $userPath    = [regex]::Replace($userPath, "$escapedRoot(\\[^;]*)?;?", "")
    $userPath    = ($userPath -replace ";;+", ";") -replace "^;|;$", ""

    $prefix = "$Script:NpmGlobalDir;$Script:NodeDir"
    $gitDir = Get-LocalGitCommandDir
    if ($gitDir) { $prefix += ";$gitDir" }
    $newPath = "$prefix;$userPath"
    Set-UserEnv -Name "Path" -Value $newPath
    Publish-UserEnvironmentChange

    $env:Path = "$newPath;$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
    Write-Ok "PATH 已同步到当前会话。"
}

function Remove-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$PathToRemove)

    $resolved  = [IO.Path]::GetFullPath($PathToRemove).TrimEnd("\")
    $userPath  = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts     = @(Split-PathList -Value $userPath)
    $newParts  = @()

    foreach ($part in $parts) {
        $partResolved = $part.TrimEnd("\")
        if (-not $partResolved.Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            $newParts += $part
        }
    }

    if ($newParts.Count -ne $parts.Count) {
        $newPath = ($newParts -join ';')
        Set-UserEnv -Name "Path" -Value $newPath
        Publish-UserEnvironmentChange

        $envParts    = @(Split-PathList -Value $env:Path)
        $newEnvParts = @()
        foreach ($ep in $envParts) {
            $epResolved = $ep.TrimEnd("\")
            if (-not $epResolved.Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
                $newEnvParts += $ep
            }
        }
        $env:Path = ($newEnvParts -join ';')
    }
}
