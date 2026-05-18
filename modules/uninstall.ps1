# uninstall.ps1 — 卸载流程

function Test-UninstallRootIsTrusted {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        $Record
    )

    $rootFull = [IO.Path]::GetFullPath($RootDir).TrimEnd("\")

    if ($Record -and $Record.installDir) {
        try {
            $recordRoot = [IO.Path]::GetFullPath([string]$Record.installDir).TrimEnd("\")
            if ($rootFull.Equals($recordRoot, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch { }
    }

    $leaf = Split-Path -Leaf $rootFull
    return $leaf.Equals("ClaudeCodeCLI", [StringComparison]::OrdinalIgnoreCase)
}

function Confirm-UninstallRootSafety {
    param($Record)

    if (Test-UninstallRootIsTrusted -RootDir $Script:RootDir -Record $Record) {
        return $true
    }

    Write-Warn "安装目录不是记录文件中的目录，也不是默认的 ClaudeCodeCLI 目录：$($Script:RootDir)"
    Write-Warn "为避免误删自定义目录，请输入完整安装目录进行二次确认。"
    $typed = Read-Host "请输入完整路径确认删除，直接回车取消"
    if ([string]::IsNullOrWhiteSpace($typed)) {
        Write-Warn "已取消卸载。"
        return $false
    }

    try {
        $typedFull = [IO.Path]::GetFullPath($typed).TrimEnd("\")
        $rootFull  = [IO.Path]::GetFullPath($Script:RootDir).TrimEnd("\")
        if ($typedFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    catch { }

    Write-Warn "输入路径与目标安装目录不一致，已取消卸载。"
    return $false
}

function Invoke-Uninstall {
    Write-Info "开始清理本脚本写入的所有内容。"

    # 卸载日志写入系统临时目录
    $uninstallLogDir  = Join-Path ([IO.Path]::GetTempPath()) "ClaudeCodeCLI_uninstall_logs"
    New-Item -ItemType Directory -Force -Path $uninstallLogDir -ErrorAction SilentlyContinue | Out-Null
    $uninstallLogFile = Join-Path $uninstallLogDir ("uninstall_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    function Write-UninstallLog {
        param([string]$Message)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$ts  $Message" | Out-File -LiteralPath $uninstallLogFile -Append -Encoding UTF8
    }

    Write-UninstallLog "========== 卸载日志 =========="
    Write-UninstallLog "卸载时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-UninstallLog "目标安装目录：$($Script:RootDir)"
    Write-UninstallLog "卸载日志文件：$uninstallLogFile"

    # 读取安装记录文件
    $record = Read-InstallRecord
    if ($record) {
        Write-Host ""
        Write-Host "======================================================" -ForegroundColor Yellow
        Write-Host "  卸载摘要" -ForegroundColor Yellow
        Write-Host "======================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  安装目录：$($record.installDir)"
        Write-Host "  安装时间：$($record.installTime)"
        if ($record.components) {
            foreach ($comp in $record.components.PSObject.Properties) {
                Write-Host "  $($comp.Name)：$($comp.Value)"
            }
        }
        if ($record.providers -and @($record.providers.PSObject.Properties).Count -gt 0) {
            Write-Host "  已配置提供商："
            foreach ($kv in $record.providers.PSObject.Properties) {
                Write-Host "    - $($kv.Value.name) ($($kv.Value.mainModel))"
            }
        }
        Write-Host ""
        Write-Host "  将清理环境变量：$($Script:ManagedEnvVars.Count) 个"
        Write-Host ""
        # 优先使用记录中的安装目录
        if ($record.installDir -and (-not $InstallDir)) {
            $Script:RootDir = $record.installDir
            Write-UninstallLog "使用记录文件中的安装目录：$($Script:RootDir)"
        }
    }

    # 从用户 PATH 中自动检测真正的安装目录
    $detectedRoots = @{}
    $userPathForDetect = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not [string]::IsNullOrWhiteSpace($userPathForDetect)) {
        foreach ($entry in $userPathForDetect.Split(';')) {
            if ($entry -match 'ClaudeCodeCLI') {
                $idx = $entry.IndexOf('ClaudeCodeCLI', [StringComparison]::OrdinalIgnoreCase)
                if ($idx -ge 0) {
                    $potentialRoot = $entry.Substring(0, $idx + 'ClaudeCodeCLI'.Length)
                    try {
                        $resolvedRoot = [IO.Path]::GetFullPath($potentialRoot).TrimEnd('\')
                        if (-not $detectedRoots.ContainsKey($resolvedRoot)) {
                            $detectedRoots[$resolvedRoot] = $entry
                        }
                    }
                    catch { }
                }
            }
        }
    }

    if (-not (Test-Path -LiteralPath $Script:RootDir)) {
        $otherRoots = @($detectedRoots.Keys | Where-Object { $_ -ne $Script:RootDir })
        if ($otherRoots.Count -gt 0) {
            Write-Warn "当前目标：$($Script:RootDir)（不存在）"
            Write-Warn "但在 PATH 中检测到以下 ClaudeCodeCLI 安装目录："
            foreach ($root in $otherRoots) {
                Write-Warn "  → $root"
            }
            Write-Warn "请使用 -InstallDir 参数指定正确的安装目录后重新卸载。"
            Write-Warn ('例如：-Uninstall -InstallDir "{0}"' -f $otherRoots[0])
            Write-UninstallLog "检测到其他安装目录：$($otherRoots -join ', ')，但用户未指定 -InstallDir。"
            return
        }

        Write-Warn "未检测到安装目录 $($Script:RootDir)，可能已被删除或安装时使用了不同的路径。"
        Write-Warn "如果安装时指定了 -InstallDir，卸载时也需要传入相同的路径。"
        Write-UninstallLog "安装目录不存在，跳过目录删除。"
        $answer = Read-Host "是否仍要继续清理环境变量和 PATH 条目？输入 Y 继续，其他输入退出"
        if ($answer -notmatch "^(Y|y)$") {
            Write-Warn "已取消卸载。"
            Write-UninstallLog "用户取消卸载。"
            return
        }
    }
    else {
        $runningClaude = Get-Process -Name "claude" -ErrorAction SilentlyContinue
        if ($runningClaude) {
            Write-Warn "检测到 Claude Code 进程正在运行（PID：$($runningClaude.Id)），请先关闭 claude 再卸载。"
            Write-UninstallLog "警告：Claude Code 进程正在运行（PID：$($runningClaude.Id)）。"
        }

        if (-not (Confirm-UninstallRootSafety -Record $record)) {
            Write-UninstallLog "用户未通过安装目录安全确认，卸载取消。"
            return
        }

        $answer = Read-Host ('将删除所有 Claude Code 环境变量、PATH 条目以及 {0} 文件夹，是否继续？输入 Y 继续，其他输入退出' -f $Script:RootDir)
        if ($answer -notmatch "^(Y|y)$") {
            Write-Warn "已取消卸载。"
            Write-UninstallLog "用户取消卸载。"
            return
        }
    }

    Write-Info "正在清除 DeepSeek/Claude Code 用户环境变量..."
    foreach ($name in $Script:ManagedEnvVars) {
        Remove-UserEnv -Name $name
        Write-Info "已删除 $name"
        Write-UninstallLog "已删除环境变量：$name"
    }

    # 同时清理专属 Key 变量 (CC_*_AUTH)
    if ($record -and $record.providers) {
        foreach ($kv in $record.providers.PSObject.Properties) {
            $dedicatedKey = "CC_$($kv.Name.ToUpper())_AUTH"
            Remove-UserEnv -Name $dedicatedKey
            Write-Info "已删除 $dedicatedKey"
            Write-UninstallLog "已删除环境变量：$dedicatedKey"
        }
    }

    Write-Info ('正在从 PATH 中移除 {0} 相关条目...' -f $Script:RootDir)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $desktop     = [Environment]::GetFolderPath("Desktop")
    $pathBackup  = Join-Path $desktop "ClaudeCodeCLI_path_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $userPath | Out-File -LiteralPath $pathBackup -Encoding UTF8
    Write-Info "原始 PATH 已备份到: $pathBackup"
    Write-UninstallLog "PATH 备份已保存到：$pathBackup"

    $rootFull     = [IO.Path]::GetFullPath($Script:RootDir).TrimEnd("\")
    $parts        = @(Split-PathList -Value $userPath)
    $newParts     = @()
    $removedCount = 0
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $matchesRoot = $false
        try {
            $partFull = [IO.Path]::GetFullPath($part).TrimEnd("\")
            if ($partFull.StartsWith($rootFull + "\", [StringComparison]::OrdinalIgnoreCase) -or
                $partFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                $matchesRoot = $true
            }
        }
        catch {
            Write-Warn "PATH 中包含无法解析的条目，已跳过: $($part.Substring(0, [Math]::Min(60, $part.Length)))"
        }
        if (-not $matchesRoot) {
            $newParts += $part
        }
        else {
            Write-Info "已从 PATH 移除: $part"
            Write-UninstallLog "已从 PATH 移除：$part"
            $removedCount++
        }
    }
    if ($newParts.Count -ne $parts.Count) {
        $newPath = ($newParts -join ';')
        Set-UserEnv -Name "Path" -Value $newPath
        Write-UninstallLog "已更新用户 PATH（移除了 $removedCount 个条目）。"
    }
    else {
        Write-UninstallLog "PATH 中未找到需移除的条目。"
    }
    Publish-UserEnvironmentChange

    if (Test-Path -LiteralPath $Script:RootDir) {
        Write-Info ('正在删除 {0} 文件夹...' -f $Script:RootDir)
        Write-UninstallLog "开始删除安装目录：$($Script:RootDir)"
        try {
            Remove-Item -LiteralPath $Script:RootDir -Recurse -Force -ErrorAction Stop
            Write-Info ('{0} 已删除。' -f $Script:RootDir)
            Write-UninstallLog "安装目录已成功删除。"
        }
        catch {
            Write-Warn "删除安装目录时出错：$($_.Exception.Message)"
            Write-Warn "可能有文件正在被占用，请关闭相关程序后手动删除：$($Script:RootDir)"
            Write-UninstallLog "删除安装目录失败：$($_.Exception.Message)"
        }
    }
    else {
        Write-Info ('未检测到安装目录 {0}，跳过目录删除。' -f $Script:RootDir)
        Write-UninstallLog "安装目录不存在，跳过删除：$($Script:RootDir)"
    }

    Clear-InstallRecord

    Write-UninstallLog "========== 卸载结束 =========="
    Write-Ok "卸载完成。卸载日志：$uninstallLogFile"
    Write-Ok "请重新打开 PowerShell 使所有变更生效。"
}
