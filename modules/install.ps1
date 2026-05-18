# install.ps1 — Node.js / Git / Claude Code 安装与检测

# ======================== npm 代理参数 ========================
function Get-NpmProxyArguments {
    if ([string]::IsNullOrWhiteSpace($Script:Proxy)) {
        return @()
    }

    @(
        "--proxy",
        $Script:Proxy,
        "--https-proxy",
        $Script:Proxy
    )
}

# ======================== Node.js ========================
function Get-NodeLtsDownload {
    $indexPath = Join-Path $Script:DownloadsDir "node-index.json"
    Invoke-DirectDownload -Uri "https://nodejs.org/dist/index.json" -OutFile $indexPath -What "Node.js 版本索引"

    $versions = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lts = $versions | Where-Object { $_.lts -ne $false } | Select-Object -First 1
    if (-not $lts) {
        Fail "无法从 Node.js 官方索引中找到 LTS 版本。"
    }

    $version  = [string]$lts.version
    $fileName = "node-$version-win-x64.zip"
    [PSCustomObject]@{
        Version  = $version
        FileName = $fileName
        Uri      = "https://nodejs.org/dist/$version/$fileName"
    }
}

function Ensure-Node {
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd  = Join-Path $Script:NodeDir "npm.cmd"

    $systemNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($systemNode -and $systemNode.Path -and -not $systemNode.Path.StartsWith($Script:RootDir, [StringComparison]::OrdinalIgnoreCase)) {
        $sysVersion = & node --version 2>$null
        Write-Warn "检测到系统中已存在 Node.js：$sysVersion（路径：$($systemNode.Path)）"
        Write-Warn "脚本安装的版本将插入到 PATH 最前面，优先使用脚本版本。"
    }

    if ((Test-Path -LiteralPath $nodeExe) -and (Test-Path -LiteralPath $npmCmd)) {
        Add-UserPath -PathToAdd $Script:NodeDir
        $nodeVersion = Invoke-CheckedCommand -FilePath $nodeExe -Arguments @("--version")
        $npmVersion  = Invoke-CheckedCommand -FilePath $npmCmd  -Arguments @("--version")
        Write-Ok "检测到本地 Node.js：$nodeVersion"
        Write-Ok "检测到本地 npm：$npmVersion"
        Write-Log "Node.js（检测）：$nodeVersion（路径：$nodeExe）"
        Write-Log "npm（检测）：$npmVersion（路径：$npmCmd）"
        return
    }

    $download = Get-NodeLtsDownload
    $zipPath  = Join-Path $Script:DownloadsDir $download.FileName
    Invoke-DirectDownload -Uri $download.Uri -OutFile $zipPath -What "Node.js LTS $($download.Version)"
    Expand-ZipToCleanDirectory -ZipPath $zipPath -Destination $Script:NodeDir -What "Node.js"

    Add-UserPath -PathToAdd $Script:NodeDir
    $nodeVersion = Invoke-CheckedCommand -FilePath (Join-Path $Script:NodeDir "node.exe") -Arguments @("--version")
    $npmVersion  = Invoke-CheckedCommand -FilePath (Join-Path $Script:NodeDir "npm.cmd")  -Arguments @("--version")
    Write-Ok "Node.js 已安装：$nodeVersion"
    Write-Ok "npm 已安装：$npmVersion"
    Write-Log "Node.js（安装）：$nodeVersion"
    Write-Log "npm（安装）：$npmVersion"
}

# ======================== npm 配置 ========================
function Configure-Npm {
    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
    if (-not (Test-Path -LiteralPath $npmCmd)) {
        Fail "未找到本地 npm：$npmCmd"
    }

    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "prefix",   $Script:NpmGlobalDir) | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "cache",    $Script:NpmCacheDir)  | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "registry", $Script:NpmRegistry)  | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "ignore-scripts", "false")        | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
        Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "proxy",       $Script:Proxy) | Out-Null
        Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "https-proxy", $Script:Proxy) | Out-Null
    }
    Add-UserPath -PathToAdd $Script:NpmGlobalDir
    Write-Ok ('npm prefix/cache 已配置到 {0}。' -f $Script:RootDir)
    Write-Log "npm prefix：$Script:NpmGlobalDir"
    Write-Log "npm cache：$Script:NpmCacheDir"
    Write-Log "npm registry：$Script:NpmRegistry"
}

# ======================== Claude Code ========================
function Get-LocalClaudeCommand {
    $candidates = @(
        (Join-Path $Script:NpmGlobalDir "claude.cmd"),
        (Join-Path $Script:NpmGlobalDir "claude.ps1"),
        (Join-Path $Script:NpmGlobalDir "claude")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-ClaudeCodePackageDir {
    Join-Path $Script:NpmGlobalDir "node_modules\@anthropic-ai\claude-code"
}

function Test-ClaudeCodeInstallLooksValid {
    $packageDir         = Get-ClaudeCodePackageDir
    $binExe             = Join-Path $packageDir "bin\claude.exe"
    $platformPackageDir = Join-Path $packageDir "node_modules\@anthropic-ai\claude-code-win32-x64"
    $platformExe        = Join-Path $platformPackageDir "claude.exe"

    if (-not (Test-Path -LiteralPath $binExe)) {
        Write-Warn "未找到 Claude Code 可执行文件：$binExe"
        return $false
    }

    $binLength = (Get-Item -LiteralPath $binExe).Length
    if ($binLength -lt 1048576) {
        Write-Warn "claude.exe 文件异常，当前大小只有 $binLength 字节，平台可选依赖可能没有正确安装。"
        return $false
    }

    if (-not (Test-Path -LiteralPath $platformExe)) {
        Write-Warn "未找到 Claude Code Windows x64 平台包：claude-code-win32-x64"
        return $false
    }

    $platformLength = (Get-Item -LiteralPath $platformExe).Length
    if ($platformLength -lt 1048576) {
        Write-Warn "claude-code-win32-x64 平台包中的 claude.exe 文件异常，当前大小只有 $platformLength 字节。"
        return $false
    }

    return $true
}

function Reset-ClaudeCodeInstall {
    $packageDir   = Get-ClaudeCodePackageDir
    $anthropicRoot = Join-Path $Script:NpmGlobalDir "node_modules\@anthropic-ai"
    $launchers    = @(
        (Join-Path $Script:NpmGlobalDir "claude"),
        (Join-Path $Script:NpmGlobalDir "claude.cmd"),
        (Join-Path $Script:NpmGlobalDir "claude.ps1")
    )

    Write-Warn "正在清理异常的 Claude Code 安装产物。"
    foreach ($launcher in $launchers) {
        Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $packageDir) {
        Remove-DirectorySafely -Path $packageDir
    }

    if (Test-Path -LiteralPath $anthropicRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $anthropicRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-DirectorySafely -Path $anthropicRoot
        }
    }
}

function Ask-NpmMirrorSwitch {
    Write-Warn "npm 官方 registry (registry.npmjs.org) 连接较慢或失败。"
    Write-Host "  国内用户可切换到 npmmirror.com 镜像以加速下载。" -ForegroundColor Cyan
    $answer = Read-Host "是否切换到 npmmirror.com 镜像？输入 Y 切换，其他输入跳过"
    if ($answer -match "^(Y|y)$") {
        $Script:NpmRegistry = $Script:NpmRegistryMirror
        Write-Ok "已切换到 $Script:NpmRegistry"
        return $true
    }
    return $false
}

function Test-NpmRegistryAccess {
    param(
        [Parameter(Mandatory = $true)][string]$NpmPath,
        [int]$Depth = 0
    )

    if ($Depth -ge 2) {
        Fail "npm registry 连通性检查失败（已尝试镜像切换）。请检查网络连接。"
    }

    Write-Info "正在检查 npm registry 连通性。"
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    $args = @(
        "view",
        "@anthropic-ai/claude-code",
        "version",
        "--registry",
        $Script:NpmRegistry,
        "--loglevel",
        "verbose"
    )
    $args = @($args + (Get-NpmProxyArguments))

    $env:NODE_OPTIONS = "--dns-result-order=ipv4first"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $NpmPath @args 2>&1
        $exit   = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $stopwatch.Stop()
    $outputText = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()

    if ($exit -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            Write-Host $outputText
        }
        if ($outputText -match "ETIMEDOUT|ENOTFOUND|ENETUNREACH|ECONNREFUSED") {
            if (Ask-NpmMirrorSwitch) {
                return Test-NpmRegistryAccess -NpmPath $NpmPath -Depth ($Depth + 1)
            }
            Fail "npm registry 连接失败（DNS/网络不通），请检查网络或使用 -Proxy 参数设置代理。"
        }
        if ($outputText -match "E403|E401") {
            Fail "npm registry 返回鉴权错误，请检查是否被防火墙拦截或需配置代理。"
        }
        Fail "npm registry 连通性检查失败（退出码 $exit）。请检查网络连接。"
    }

    if ($stopwatch.Elapsed.TotalMilliseconds -gt 8000 -and $Depth -eq 0) {
        Write-Warn "npm registry 连接较慢 ($([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s)"
        if (Ask-NpmMirrorSwitch) {
            Invoke-CheckedCommand -FilePath $NpmPath -Arguments @("config", "set", "registry", $Script:NpmRegistry) | Out-Null
            return Test-NpmRegistryAccess -NpmPath $NpmPath -Depth ($Depth + 1)
        }
    }

    $lines = $outputText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 6
    foreach ($line in $lines) {
        Write-Info $line
    }
}

function Invoke-NpmInstallClaudeCodeWithProgress {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    $env:NODE_OPTIONS = "--dns-result-order=ipv4first"

    $stdoutPath = Join-Path $Script:DownloadsDir "claude-code-install.out.log"
    $stderrPath = Join-Path $Script:DownloadsDir "claude-code-install.err.log"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $arguments = @(
        "install",
        "-g",
        "@anthropic-ai/claude-code",
        "--prefix",
        $Script:NpmGlobalDir,
        "--cache",
        $Script:NpmCacheDir,
        "--registry",
        $Script:NpmRegistry,
        "--include=optional",
        "--foreground-scripts",
        "--loglevel",
        "verbose"
    )

    $wrapperBat = Join-Path $Script:DownloadsDir "npm-install-wrapper.bat"
    $batContent = @"
@echo off
set "PATH=$($Script:NodeDir);%PATH%"
"$NpmPath" %*
"@
    $batContent | Out-File -LiteralPath $wrapperBat -Encoding ASCII

    Write-Info "正在安装 Claude Code：@anthropic-ai/claude-code"
    $cmdArgs  = @("/c", "call", $wrapperBat) + $arguments
    $process  = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $warnedNoOutput = $false
    $activity      = "Claude Code 安装进度"
    $dotCount      = 0

    try {
        while (-not $process.HasExited) {
            Start-Sleep -Seconds 1

            $stdoutBytes = [int64]0
            $stderrBytes = [int64]0
            if (Test-Path -LiteralPath $stdoutPath) {
                $stdoutBytes = (Get-Item -LiteralPath $stdoutPath).Length
            }
            if (Test-Path -LiteralPath $stderrPath) {
                $stderrBytes = (Get-Item -LiteralPath $stderrPath).Length
            }

            $totalOutputBytes = $stdoutBytes + $stderrBytes
            $elapsedSeconds   = [Math]::Max(1, [int]$stopwatch.Elapsed.TotalSeconds)
            $elapsedStr       = if ($elapsedSeconds -ge 60) { "{0}分{1}秒" -f ([int]($elapsedSeconds / 60)), ($elapsedSeconds % 60) } else { "{0}秒" -f $elapsedSeconds }

            if ($totalOutputBytes -gt 0) {
                $status = "已运行 {0}，npm 正在下载安装（日志 {1:N0} KB）" -f $elapsedStr, ($totalOutputBytes / 1KB)
            }
            else {
                $dots   = "." * (($dotCount % 3) + 1)
                $status = "已运行 {0}，正在连接 npm registry{1}" -f $elapsedStr, $dots
                $dotCount++
            }

            $roughPercent = [Math]::Min(99, [int](($totalOutputBytes / 1KB) * 100 / 10240))
            Write-Progress -Activity $activity -Status $status -PercentComplete $roughPercent

            if (-not $warnedNoOutput -and $elapsedSeconds -ge 60 -and $totalOutputBytes -eq 0) {
                Write-Warn "Claude Code 安装超过 1 分钟没有安装输出，可能是网络无法访问 npm registry。若长时间不动，请使用代理后重新运行本脚本。"
                $warnedNoOutput = $true
            }
        }
    }
    finally {
        Write-Progress -Activity $activity -Completed
        $process.Refresh()
        $stopwatch.Stop()
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }

    $combinedOutput = $stdout + $stderr
    $npmReportedOk  = ($combinedOutput -match "npm info ok")
    $packagesAdded  = ($combinedOutput -match "added \d+ packages")
    $nodeNotFound   = ($combinedOutput -match "'node' is not recognized")

    if ($process.ExitCode -ne 0 -and -not ($npmReportedOk -and $packagesAdded)) {
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr
        }
        if ($nodeNotFound) {
            Fail "npm postinstall 脚本找不到 node 命令。请检查 `$env:Path` 是否包含 $($Script:NodeDir)。"
        }
        if ($combinedOutput -match "ETIMEDOUT|ENOTFOUND|ECONNREFUSED|ESOCKETTIMEDOUT") {
            Fail "npm 安装时网络连接失败，请检查网络或使用 -Proxy 参数。"
        }
        Fail $Script:NetworkFailureMessage
    }

    if ($process.ExitCode -ne 0 -and $npmReportedOk) {
        Write-Log "注：npm 进程退出码为 $($process.ExitCode)，但 npm 输出已确认安装成功。"
    }

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $lastLines = $stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5
        foreach ($line in $lastLines) {
            Write-Info $line
        }
    }

    # 清理临时文件
    if (Test-Path -LiteralPath $wrapperBat) {
        Remove-Item -LiteralPath $wrapperBat -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-ClaudeCode {
    Add-UserPath -PathToAdd $Script:NpmGlobalDir
    $localClaude = Get-LocalClaudeCommand
    if ($localClaude) {
        if (-not (Test-ClaudeCodeInstallLooksValid)) {
            Reset-ClaudeCodeInstall
            $localClaude = $null
        }
    }

    if ($localClaude) {
        $version = Invoke-CheckedCommand -FilePath $localClaude -Arguments @("--version")
        Write-Ok "检测到本地 Claude Code：$version"
        Write-Log "Claude Code（检测）：$version"
        return
    }

    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
    try {
        Test-NpmRegistryAccess -NpmPath $npmCmd
        Invoke-NpmInstallClaudeCodeWithProgress -NpmPath $npmCmd
    }
    catch {
        if ($_.Exception.Message -eq $Script:NetworkFailureMessage) {
            Fail $Script:NetworkFailureMessage
        }
        Fail "Claude Code 安装失败：$($_.Exception.Message)"
    }

    $localClaude = Get-LocalClaudeCommand
    if (-not $localClaude) {
        Fail ('Claude Code 安装后仍无法在 {0}\npm-global 中找到 claude。' -f $Script:RootDir)
    }

    if (-not (Test-ClaudeCodeInstallLooksValid)) {
        Fail "Claude Code 安装后校验失败：claude.exe 文件异常或缺少 claude-code-win32-x64 平台包。"
    }

    $version = Invoke-CheckedCommand -FilePath $localClaude -Arguments @("--version")
    Write-Ok "Claude Code 已安装：$version"
    Write-Log "Claude Code（安装）：$version"
}

# ======================== Git ========================
function Get-MinGitAssetFileNameCandidates {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $version  = $Tag -replace '^v', ''
    $versions = New-Object System.Collections.Generic.List[string]

    $baseVersion = $version -replace '\.windows\.\d+$', ''
    if (-not [string]::IsNullOrWhiteSpace($baseVersion)) {
        $versions.Add($baseVersion)
    }

    if ($version -ne $baseVersion -and -not [string]::IsNullOrWhiteSpace($version)) {
        $versions.Add($version)
    }

    $versions |
        Select-Object -Unique |
        ForEach-Object { "MinGit-$($_)-64-bit.zip" }
}

function Get-MinGitDownload {
    $releasePath = Join-Path $Script:DownloadsDir "git-for-windows-latest.json"
    $apiFailed   = $false

    try {
        Invoke-DirectDownload -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -OutFile $releasePath -What "Git for Windows 版本信息"

        $release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $asset   = $release.assets |
            Where-Object { $_.name -like "MinGit-*-64-bit.zip" -and $_.name -notlike "*busybox*" } |
            Select-Object -First 1

        if ($asset) {
            return [PSCustomObject]@{
                FileName = $asset.name
                Uri      = $asset.browser_download_url
            }
        }
        $apiFailed = $true
    }
    catch {
        Write-Warn "GitHub API 请求失败（可能触发限流），尝试通过重定向获取最新版本。"
        $apiFailed = $true
    }

    if ($apiFailed) {
        $latestUrl = "https://github.com/git-for-windows/git/releases/latest"
        Write-Info "正在通过 $latestUrl 获取 Git 最新版本..."

        $request = [Net.HttpWebRequest]::Create($latestUrl)
        $request.UserAgent       = $Script:UserAgent
        $request.AllowAutoRedirect = $false
        $request.Timeout         = 30000
        if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
            $request.Proxy = New-Object Net.WebProxy($Script:Proxy, $true)
        }

        try {
            $response    = $request.GetResponse()
            $redirectUrl = $response.Headers["Location"]
            $response.Dispose()

            if ([string]::IsNullOrWhiteSpace($redirectUrl)) {
                Fail "无法获取 Git for Windows 最新版本。"
            }

            $tag         = $redirectUrl.Split("/") | Select-Object -Last 1
            $version     = $tag -replace '^v', ''
            $fileName    = @(Get-MinGitAssetFileNameCandidates -Tag $tag)[0]
            $downloadUrl = "https://github.com/git-for-windows/git/releases/download/$tag/$fileName"

            Write-Info "通过重定向解析到版本：$version"
            Write-Info "使用 MinGit 资源名：$fileName"
            return [PSCustomObject]@{
                FileName = $fileName
                Uri      = $downloadUrl
            }
        }
        catch {
            Fail "无法获取 Git for Windows 版本信息（API 和重定向均失败）。请使用代理后重试。"
        }
    }
}

function Get-LocalGitCommandDir {
    $candidates = @(
        (Join-Path $Script:GitDir "cmd"),
        (Join-Path $Script:GitDir "mingw64\bin"),
        (Join-Path $Script:GitDir "bin")
    )

    foreach ($dir in $candidates) {
        $gitExe = Join-Path $dir "git.exe"
        if (Test-Path -LiteralPath $gitExe) {
            return $dir
        }
    }

    $found = Get-ChildItem -LiteralPath $Script:GitDir -Recurse -Filter "git.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        return $found.DirectoryName
    }

    return $null
}

function Ensure-Git {
    $gitDir = Get-LocalGitCommandDir
    if ($gitDir) {
        Add-UserPath -PathToAdd $gitDir
        $version = Invoke-CheckedCommand -FilePath (Join-Path $gitDir "git.exe") -Arguments @("--version")
        Write-Ok "检测到本地 Git：$version"
        Write-Log "Git（检测）：$version"
        return
    }

    $download = Get-MinGitDownload
    $zipPath  = Join-Path $Script:DownloadsDir $download.FileName
    Invoke-DirectDownload -Uri $download.Uri -OutFile $zipPath -What "MinGit"
    Expand-ZipToCleanDirectory -ZipPath $zipPath -Destination $Script:GitDir -What "MinGit"

    $gitDir = Get-LocalGitCommandDir
    if (-not $gitDir) {
        Fail "MinGit 解压后未找到 git.exe。"
    }

    Add-UserPath -PathToAdd $gitDir
    $version = Invoke-CheckedCommand -FilePath (Join-Path $gitDir "git.exe") -Arguments @("--version")
    Write-Ok "Git 已安装：$version"
    Write-Log "Git（安装）：$version"
}
