[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Proxy,
    [string]$InstallDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# 切换控制台编码为 UTF-8，避免中文路径/用户名和 npm 输出乱码
# 必须同时设置 OutputEncoding，否则 Write-Host 输出的中文字符会因编码不一致而重复
try {
    $utf8 = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = $utf8
    [Console]::InputEncoding = $utf8
    $null = chcp 65001 2>$null
}
catch {
    Write-Host "[警告] 无法设置控制台 UTF-8 编码，中文可能显示异常。" -ForegroundColor Yellow
}

if ($InstallDir) {
    $resolved = [IO.Path]::GetFullPath($InstallDir)
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Fail "指定的安装目录父路径不存在：$parent，请先确保盘符存在或检查路径拼写。"
    }
    $Script:RootDir = $resolved
}
elseif (Test-Path -LiteralPath "D:\" -PathType Container) {
    $Script:RootDir = "D:\ClaudeCodeCLI"
}
else {
    $Script:RootDir = Join-Path $env:USERPROFILE "ClaudeCodeCLI"
}
$Script:NodeDir = Join-Path $Script:RootDir "nodejs"
$Script:NpmGlobalDir = Join-Path $Script:RootDir "npm-global"
$Script:NpmCacheDir = Join-Path $Script:RootDir "npm-cache"
$Script:GitDir = Join-Path $Script:RootDir "Git"
$Script:DownloadsDir = Join-Path $Script:RootDir "downloads"
$Script:LogsDir = Join-Path $Script:RootDir "logs"
$Script:DeepSeekBaseUrl = "https://api.deepseek.com/anthropic"
$Script:NetworkFailureMessage = "下载失败，请使用代理后重新运行本脚本。"
$Script:UserAgent = "ClaudeCodeCLI-DeepSeek-Setup/2.0"
$Script:NpmRegistry = "https://registry.npmjs.org/"
$Script:Proxy = $Proxy

$Script:ManagedEnvVars = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL"
)

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[信息] $Message"
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[成功] $Message" -ForegroundColor Green
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $Message" | Out-File -LiteralPath $Script:LogFile -Append -Encoding UTF8
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Get-UserEnv {
    param([Parameter(Mandatory = $true)][string]$Name)
    [Environment]::GetEnvironmentVariable($Name, "User")
}

function Set-UserEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, "User")
    if ([string]::IsNullOrEmpty($Value)) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Remove-UserEnv {
    param([Parameter(Mandatory = $true)][string]$Name)
    [Environment]::SetEnvironmentVariable($Name, $null, "User")
    Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
}

function Mask-Secret {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "<空>"
    }
    if ($Value.Length -le 8) {
        return "********"
    }
    return "{0}...{1}" -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4)
}

function Split-PathList {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return $Value.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Add-UserPath {
    param([Parameter(Mandatory = $true)][string]$PathToAdd)

    $resolved = [IO.Path]::GetFullPath($PathToAdd).TrimEnd("\")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @(Split-PathList -Value $userPath)
    $exists = $false

    foreach ($part in $parts) {
        if ($part.TrimEnd("\").Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newPath = (@($resolved + $parts) -join ';')
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    $processParts = @(Split-PathList -Value $env:Path)
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
    # 清理旧版本脚本可能写坏的 PATH 条目（缺少分号导致的粘连）
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { return }

    $escapedRoot = [regex]::Escape($Script:RootDir)
    $matches = [regex]::Matches($userPath, "$escapedRoot[^;]*")
    if ($matches.Count -le 1) { return }

    Write-Warn "检测到用户 PATH 中 ClaudeCodeCLI 条目异常（可能缺少分隔符），正在修复..."
    $fixed = $userPath
    foreach ($m in $matches) {
        $fixed = $fixed.Replace($m.Value, ";$($m.Value);")
    }
    $fixed = ($fixed -replace ";;+" , ";") -replace "^;|;$" , ""
    [Environment]::SetEnvironmentVariable("Path", $fixed, "User")
    Write-Ok "PATH 已修复。"
}

function Sync-ClaudeCodeCLIPath {
    # 确保 ClaudeCodeCLI 的关键目录在用户 PATH 最前面，并刷新当前进程
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $escapedRoot = [regex]::Escape($Script:RootDir)
    $userPath = [regex]::Replace($userPath, "$escapedRoot[^;]*;?", "")
    $userPath = ($userPath -replace ";;+" , ";") -replace "^;|;$" , ""

    $prefix = "$Script:NpmGlobalDir;$Script:NodeDir"
    $gitDir = Get-LocalGitCommandDir
    if ($gitDir) { $prefix += ";$gitDir" }
    $newPath = "$prefix;$userPath"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    $env:Path = "$newPath;$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
    Write-Ok "PATH 已同步到当前会话。"
}

function Confirm-OverwriteExistingConfig {
    $existing = @()
    foreach ($name in $Script:ManagedEnvVars) {
        $value = Get-UserEnv -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $display = if ($name -eq "ANTHROPIC_AUTH_TOKEN") { Mask-Secret -Value $value } else { $value }
            $existing += [PSCustomObject]@{ Name = $name; Value = $display }
        }
    }

    if ($existing.Count -eq 0) {
        return $true
    }

    Write-Warn "检测到已有 Claude/Anthropic 相关用户环境变量："
    foreach ($item in $existing) {
        Write-Host ("  {0} = {1}" -f $item.Name, $item.Value)
    }

    $answer = Read-Host "是否覆盖为 DeepSeek 配置？输入 Y 继续，其他输入退出"
    return $answer -match "^(Y|y)$"
}

function Initialize-Proxy {
    if ([string]::IsNullOrWhiteSpace($Script:Proxy)) {
        return
    }

    $Script:Proxy = $Script:Proxy.Trim()
    $env:HTTP_PROXY = $Script:Proxy
    $env:HTTPS_PROXY = $Script:Proxy
    $env:ALL_PROXY = $Script:Proxy
    Write-Info "本次脚本将使用代理：$Script:Proxy"
}

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

function Test-IsUnderRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootFull = [IO.Path]::GetFullPath($Script:RootDir).TrimEnd("\")
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $pathFull.StartsWith($rootFull + "\", [StringComparison]::OrdinalIgnoreCase)
}

function Remove-DirectorySafely {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-IsUnderRoot -Path $Path)) {
        Fail ('拒绝删除非 {0} 范围内的目录：{1}' -f $Script:RootDir, $Path)
    }
    if ($Path.TrimEnd("\").Equals($Script:RootDir.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) {
        Fail ('拒绝删除 {0} 根目录。' -f $Script:RootDir)
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Initialize-Directories {
    $parentPath = Split-Path -Parent $Script:RootDir
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        Fail "未检测到目标盘符 $parentPath，无法创建 $Script:RootDir。"
    }

    $dirs = @(
        $Script:RootDir,
        $Script:NodeDir,
        $Script:NpmGlobalDir,
        $Script:NpmCacheDir,
        $Script:GitDir,
        $Script:DownloadsDir
    )

    foreach ($dir in $dirs) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

function Find-CommandPath {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        if ($cmd.Path) {
            return $cmd.Path
        }
        return $cmd.Source
    }
    return $null
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $output = & $FilePath @Arguments 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        Fail ("命令执行失败：{0} {1}`n{2}" -f $FilePath, ($Arguments -join " "), ($output -join "`n"))
    }
    return ($output -join "`n").Trim()
}

function Test-CommandVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $path = Find-CommandPath -CommandName $CommandName
    if (-not $path) {
        return $null
    }

    $version = Invoke-CheckedCommand -FilePath $path -Arguments $Arguments
    [PSCustomObject]@{
        Name = $CommandName
        Path = $path
        Version = $version
    }
}

function Invoke-DirectDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$What,
        [int]$MaxRetries = 2
    )

    $retry = 0
    while ($retry -le $MaxRetries) {
        if ($retry -gt 0) {
            Write-Warn "$What 下载失败，正在进行第 $retry 次重试..."
            Start-Sleep -Seconds ($retry * 2)
        }

        try {
            if ($retry -eq 0) {
                Write-Info "正在下载 $What"
            }
            else {
                Write-Info "正在下载 $What（重试 $retry/$MaxRetries）"
            }

            $request = [Net.HttpWebRequest]::Create($Uri)
            $request.UserAgent = $Script:UserAgent
            $request.AllowAutoRedirect = $true
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
                $request.Proxy = New-Object Net.WebProxy($Script:Proxy, $true)
            }

            $response = $request.GetResponse()
            try {
                Save-ResponseStreamWithProgress -Response $response -OutFile $OutFile -What $What
            }
            finally {
                $response.Dispose()
            }
            return
        }
        catch [Net.WebException] {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "无响应" }
            # 非临时性错误（资源不存在/无权限），不重试直接退出
            if ($statusCode -match "^(401|403|404|410)$") {
                Fail "$What 下载失败（HTTP $statusCode），资源不存在或无权访问。"
            }
            # 临时性错误，可重试
            if ($retry -ge $MaxRetries) {
                $detail = "URL: $Uri`nHTTP 状态: $statusCode`n错误: $($_.Exception.Message)"
                Write-Warn "$What 下载失败（已重试 $MaxRetries 次）：$detail"
                Fail $Script:NetworkFailureMessage
            }
        }
        catch {
            # 非网络错误不重试
            if ($_.Exception.Message -notmatch "timeout|timed|connect|network|resolve|refused|unreachable|aborted") {
                Write-Warn "$What 下载失败：URL: $Uri`n$($_.Exception.Message)"
                Fail $Script:NetworkFailureMessage
            }
            if ($retry -ge $MaxRetries) {
                Write-Warn "$What 下载失败（已重试 $MaxRetries 次）：URL: $Uri`n$($_.Exception.Message)"
                Fail $Script:NetworkFailureMessage
            }
        }

        $retry++
    }
}

function Save-ResponseStreamWithProgress {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$What
    )

    $directory = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $totalBytes = [int64]$Response.ContentLength
    $downloadedBytes = [int64]0
    $buffer = New-Object byte[] 1048576
    $activity = "下载进度：$What"
    $source = $Response.GetResponseStream()
    $target = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $lastUpdate = [DateTime]::MinValue
    $lastPercent = -1
    $updateInterval = [TimeSpan]::FromMilliseconds(300)

    try {
        while ($true) {
            $read = $source.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }

            $target.Write($buffer, 0, $read)
            $downloadedBytes += $read

            $now = [DateTime]::UtcNow
            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes * 100) / $totalBytes))
            }
            else {
                $percent = -1
            }

            # 节流：至少间隔 300ms 或百分比变化才刷新
            if (($now - $lastUpdate) -ge $updateInterval -or $percent -ne $lastPercent) {
                $lastUpdate = $now
                $lastPercent = $percent

                if ($totalBytes -gt 0) {
                    $status = "{0:N1} MB / {1:N1} MB" -f ($downloadedBytes / 1MB), ($totalBytes / 1MB)
                    Write-Progress -Activity $activity -Status $status -PercentComplete $percent
                }
                else {
                    $status = "已下载 {0:N1} MB" -f ($downloadedBytes / 1MB)
                    Write-Progress -Activity $activity -Status $status
                }
            }
        }
    }
    finally {
        $target.Dispose()
        $source.Dispose()
        Write-Progress -Activity $activity -Completed
    }
}

function Expand-ZipToCleanDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$What
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $tempDir = Join-Path $Script:DownloadsDir ("extract-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)
        $children = @(Get-ChildItem -LiteralPath $tempDir -Force)
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            $source = $children[0].FullName
        }
        else {
            $source = $tempDir
        }

        Remove-DirectorySafely -Path $Destination
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null

        Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $Destination -Force
        }
    }
    catch {
        Fail "$What 解压失败：$($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NodeLtsDownload {
    $indexPath = Join-Path $Script:DownloadsDir "node-index.json"
    Invoke-DirectDownload -Uri "https://nodejs.org/dist/index.json" -OutFile $indexPath -What "Node.js 版本索引"

    $versions = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lts = $versions | Where-Object { $_.lts -ne $false } | Select-Object -First 1
    if (-not $lts) {
        Fail "无法从 Node.js 官方索引中找到 LTS 版本。"
    }

    $version = [string]$lts.version
    $fileName = "node-$version-win-x64.zip"
    [PSCustomObject]@{
        Version = $version
        FileName = $fileName
        Uri = "https://nodejs.org/dist/$version/$fileName"
    }
}

function Ensure-Node {
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"

    $systemNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($systemNode -and $systemNode.Path -and -not $systemNode.Path.StartsWith($Script:RootDir, [StringComparison]::OrdinalIgnoreCase)) {
        $sysVersion = & node --version 2>$null
        Write-Warn "检测到系统中已存在 Node.js：$sysVersion（路径：$($systemNode.Path)）"
        Write-Warn "脚本安装的版本将插入到 PATH 最前面，优先使用脚本版本。"
    }

    if ((Test-Path -LiteralPath $nodeExe) -and (Test-Path -LiteralPath $npmCmd)) {
        Add-UserPath -PathToAdd $Script:NodeDir
        $nodeVersion = Invoke-CheckedCommand -FilePath $nodeExe -Arguments @("--version")
        $npmVersion = Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("--version")
        Write-Ok "检测到本地 Node.js：$nodeVersion"
        Write-Ok "检测到本地 npm：$npmVersion"
        Write-Log "Node.js（检测）：$nodeVersion（路径：$nodeExe）"
        Write-Log "npm（检测）：$npmVersion（路径：$npmCmd）"
        return
    }

    $download = Get-NodeLtsDownload
    $zipPath = Join-Path $Script:DownloadsDir $download.FileName
    Invoke-DirectDownload -Uri $download.Uri -OutFile $zipPath -What "Node.js LTS $($download.Version)"
    Expand-ZipToCleanDirectory -ZipPath $zipPath -Destination $Script:NodeDir -What "Node.js"

    Add-UserPath -PathToAdd $Script:NodeDir
    $nodeVersion = Invoke-CheckedCommand -FilePath (Join-Path $Script:NodeDir "node.exe") -Arguments @("--version")
    $npmVersion = Invoke-CheckedCommand -FilePath (Join-Path $Script:NodeDir "npm.cmd") -Arguments @("--version")
    Write-Ok "Node.js 已安装：$nodeVersion"
    Write-Ok "npm 已安装：$npmVersion"
    Write-Log "Node.js（安装）：$nodeVersion"
    Write-Log "npm（安装）：$npmVersion"
}

function Configure-Npm {
    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
    if (-not (Test-Path -LiteralPath $npmCmd)) {
        Fail "未找到本地 npm：$npmCmd"
    }

    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "prefix", $Script:NpmGlobalDir) | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "cache", $Script:NpmCacheDir) | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "registry", $Script:NpmRegistry) | Out-Null
    Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "ignore-scripts", "false") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
        Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "proxy", $Script:Proxy) | Out-Null
        Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("config", "set", "https-proxy", $Script:Proxy) | Out-Null
    }
    Add-UserPath -PathToAdd $Script:NpmGlobalDir
    Write-Ok ('npm prefix/cache 已配置到 {0}。' -f $Script:RootDir)
    Write-Log "npm prefix：$Script:NpmGlobalDir"
    Write-Log "npm cache：$Script:NpmCacheDir"
    Write-Log "npm registry：$Script:NpmRegistry"
}

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
    $packageDir = Get-ClaudeCodePackageDir
    $binExe = Join-Path $packageDir "bin\claude.exe"
    $platformPackageDir = Join-Path $packageDir "node_modules\@anthropic-ai\claude-code-win32-x64"
    $platformExe = Join-Path $platformPackageDir "claude.exe"

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
    $packageDir = Get-ClaudeCodePackageDir
    $anthropicRoot = Join-Path $Script:NpmGlobalDir "node_modules\@anthropic-ai"
    $launchers = @(
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

function Test-NpmRegistryAccess {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    Write-Info "正在检查 npm registry 连通性。"
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
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $outputText = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()

    if ($exit -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            Write-Host $outputText
        }
        if ($outputText -match "ETIMEDOUT|ENOTFOUND|ENETUNREACH|ECONNREFUSED") {
            Fail "npm registry 连接失败（DNS/网络不通），请检查网络或使用 -Proxy 参数设置代理。"
        }
        if ($outputText -match "E403|E401") {
            Fail "npm registry 返回鉴权错误，请检查是否被防火墙拦截或需配置代理。"
        }
        Fail "npm registry 连通性检查失败（退出码 $exit）。请检查网络连接。"
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

    # Start-Process -NoNewWindow 在一些 Win10/11 系统上不能可靠地将
    # $env:Path 传递给子进程，导致 npm postinstall 找不到 node。
    # 改用批处理包装：在 cmd.exe 内部显式设置 PATH 再调 npm。
    $wrapperBat = Join-Path $Script:DownloadsDir "npm-install-wrapper.bat"
    $batContent = @"
@echo off
set "PATH=$($Script:NodeDir);%PATH%"
"$NpmPath" %*
"@
    $batContent | Out-File -LiteralPath $wrapperBat -Encoding ASCII

    Write-Info "正在安装 Claude Code：@anthropic-ai/claude-code"
    $cmdArgs = @("/c", "call", $wrapperBat) + $arguments
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $warnedNoOutput = $false
    $activity = "Claude Code 安装进度"
    $dotCount = 0

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
            $elapsedSeconds = [Math]::Max(1, [int]$stopwatch.Elapsed.TotalSeconds)
            $elapsedStr = if ($elapsedSeconds -ge 60) { "{0}分{1}秒" -f ([int]($elapsedSeconds / 60)), ($elapsedSeconds % 60) } else { "{0}秒" -f $elapsedSeconds }

            if ($totalOutputBytes -gt 0) {
                $status = "已运行 {0}，npm 正在下载安装（日志 {1:N0} KB）" -f $elapsedStr, ($totalOutputBytes / 1KB)
            }
            else {
                $dots = "." * (($dotCount % 3) + 1)
                $status = "已运行 {0}，正在连接 npm registry{1}" -f $elapsedStr, $dots
                $dotCount++
            }

            # 不显示虚假百分比，用日志大小 / 10MB 作为参考上限（通常不会超过）
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
    $npmReportedOk = ($combinedOutput -match "npm info ok")
    $packagesAdded = ($combinedOutput -match "added \d+ packages")
    $nodeNotFound = ($combinedOutput -match "'node' is not recognized")

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
        # Start-Process -NoNewWindow 在某些环境下 ExitCode 不可靠（null 或异常值），
        # 但 npm 自身输出已确认成功，只需静默记录日志，不警告用户。
        Write-Log "注：npm 进程退出码为 $($process.ExitCode)，但 npm 输出已确认安装成功。"
    }

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $lastLines = $stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5
        foreach ($line in $lastLines) {
            Write-Info $line
        }
    }

    # 清理临时 bat 文件
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

function Get-MinGitAssetFileNameCandidates {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $version = $Tag -replace '^v', ''
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
    $apiFailed = $false

    try {
        Invoke-DirectDownload -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -OutFile $releasePath -What "Git for Windows 版本信息"

        $release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $asset = $release.assets |
            Where-Object { $_.name -like "MinGit-*-64-bit.zip" -and $_.name -notlike "*busybox*" } |
            Select-Object -First 1

        if ($asset) {
            return [PSCustomObject]@{
                FileName = $asset.name
                Uri = $asset.browser_download_url
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
        $request.UserAgent = $Script:UserAgent
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
            $request.Proxy = New-Object Net.WebProxy($Script:Proxy, $true)
        }

        try {
            $response = $request.GetResponse()
            $redirectUrl = $response.Headers["Location"]
            $response.Dispose()

            if ([string]::IsNullOrWhiteSpace($redirectUrl)) {
                Fail "无法获取 Git for Windows 最新版本。"
            }

            $tag = $redirectUrl.Split("/") | Select-Object -Last 1
            $version = $tag -replace '^v', ''
            $fileName = @(Get-MinGitAssetFileNameCandidates -Tag $tag)[0]
            $downloadUrl = "https://github.com/git-for-windows/git/releases/download/$tag/$fileName"

            Write-Info "通过重定向解析到版本：$version"
            Write-Info "使用 MinGit 资源名：$fileName"
            return [PSCustomObject]@{
                FileName = $fileName
                Uri = $downloadUrl
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
    $zipPath = Join-Path $Script:DownloadsDir $download.FileName
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

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory = $true)][securestring]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-DeepSeekApiKey {
    $secure = Read-Host "请输入 DeepSeek API Key" -AsSecureString
    $plain = ConvertFrom-SecureStringPlainText -SecureValue $secure
    if ([string]::IsNullOrWhiteSpace($plain)) {
        Fail "DeepSeek API Key 不能为空。"
    }
    return $plain
}

function Select-DeepSeekModelConfig {
    Write-Host ""
    Write-Host "请选择本次配置模型："
    Write-Host ""
    Write-Host "[1] deepseek-v4-pro[1m] + deepseek-v4-flash"
    Write-Host "    推荐：性能优先，适合日常 Claude Code 使用"
    Write-Host ""
    Write-Host "[2] deepseek-v4-flash"
    Write-Host "    速度优先，适合轻量任务"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "请输入选项编号"
        switch ($choice) {
            "1" {
                return [PSCustomObject]@{
                    MainModel = "deepseek-v4-pro[1m]"
                    FastModel = "deepseek-v4-flash"
                    Effort = "max"
                }
            }
            "2" {
                return [PSCustomObject]@{
                    MainModel = "deepseek-v4-flash"
                    FastModel = "deepseek-v4-flash"
                    Effort = "medium"
                }
            }
            default {
                Write-Warn "请输入 1 或 2。"
            }
        }
    }
}

function Set-DeepSeekEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][psobject]$ModelConfig
    )

    Set-UserEnv -Name "ANTHROPIC_BASE_URL" -Value $Script:DeepSeekBaseUrl
    Set-UserEnv -Name "ANTHROPIC_AUTH_TOKEN" -Value $ApiKey
    Set-UserEnv -Name "ANTHROPIC_MODEL" -Value $ModelConfig.MainModel
    Set-UserEnv -Name "ANTHROPIC_DEFAULT_OPUS_MODEL" -Value $ModelConfig.MainModel
    Set-UserEnv -Name "ANTHROPIC_DEFAULT_SONNET_MODEL" -Value $ModelConfig.MainModel
    Set-UserEnv -Name "ANTHROPIC_DEFAULT_HAIKU_MODEL" -Value $ModelConfig.FastModel
    Set-UserEnv -Name "CLAUDE_CODE_SUBAGENT_MODEL" -Value $ModelConfig.FastModel
    Set-UserEnv -Name "CLAUDE_CODE_EFFORT_LEVEL" -Value $ModelConfig.Effort

    Write-Log "环境变量已设置："
    Write-Log "  ANTHROPIC_BASE_URL = $Script:DeepSeekBaseUrl"
    Write-Log "  ANTHROPIC_AUTH_TOKEN = $(Mask-Secret -Value $ApiKey)"
    Write-Log "  ANTHROPIC_MODEL = $($ModelConfig.MainModel)"
    Write-Log "  ANTHROPIC_DEFAULT_OPUS_MODEL = $($ModelConfig.MainModel)"
    Write-Log "  ANTHROPIC_DEFAULT_SONNET_MODEL = $($ModelConfig.MainModel)"
    Write-Log "  ANTHROPIC_DEFAULT_HAIKU_MODEL = $($ModelConfig.FastModel)"
    Write-Log "  CLAUDE_CODE_SUBAGENT_MODEL = $($ModelConfig.FastModel)"
    Write-Log "  CLAUDE_CODE_EFFORT_LEVEL = $($ModelConfig.Effort)"
}

function Show-VersionSummary {
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
    $gitDir = Get-LocalGitCommandDir
    $claude = Get-LocalClaudeCommand

    if (-not (Test-Path -LiteralPath $nodeExe)) { Fail "验证失败：未找到本地 node.exe。" }
    if (-not (Test-Path -LiteralPath $npmCmd)) { Fail "验证失败：未找到本地 npm.cmd。" }
    if (-not $gitDir) { Fail "验证失败：未找到本地 git.exe。" }
    if (-not $claude) { Fail "验证失败：未找到本地 claude。" }

    $claudeVersion = Invoke-CheckedCommand -FilePath $claude -Arguments @("--version")
    Write-Host ""
    Write-Ok "基础组件验证通过（Claude Code $claudeVersion），继续配置。"
}

function Confirm-LaunchClaude {
    # 收集版本信息
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
    $gitDir = Get-LocalGitCommandDir
    $claude = Get-LocalClaudeCommand
    $nodeVersion = if (Test-Path -LiteralPath $nodeExe) { Invoke-CheckedCommand -FilePath $nodeExe -Arguments @("--version") } else { "未安装" }
    $npmVersion = if (Test-Path -LiteralPath $npmCmd) { Invoke-CheckedCommand -FilePath $npmCmd -Arguments @("--version") } else { "未安装" }
    $gitVersion = if ($gitDir) { Invoke-CheckedCommand -FilePath (Join-Path $gitDir "git.exe") -Arguments @("--version") } else { "未安装" }
    $claudeVersion = if ($claude) { Invoke-CheckedCommand -FilePath $claude -Arguments @("--version") } else { "未安装" }
    $baseUrl = Get-UserEnv -Name "ANTHROPIC_BASE_URL"
    $mainModel = Get-UserEnv -Name "ANTHROPIC_MODEL"
    $fastModel = Get-UserEnv -Name "CLAUDE_CODE_SUBAGENT_MODEL"
    $effort = Get-UserEnv -Name "CLAUDE_CODE_EFFORT_LEVEL"

    # 输出总结
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  安装已完成！" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  安装目录：  $($Script:RootDir)"
    Write-Host "  日志文件：  $($Script:LogFile)"
    Write-Host "  node 版本： $nodeVersion"
    Write-Host "  npm 版本：  $npmVersion"
    Write-Host "  git 版本：  $gitVersion"
    Write-Host "  claude 版本：$claudeVersion"
    Write-Host "  API 地址：  $baseUrl"
    Write-Host "  主模型：    $mainModel"
    Write-Host "  快速模型：  $fastModel"
    Write-Host "  Effort：    $effort"
    Write-Host ""

    # 写入日志
    Write-Log "========== 安装总结 =========="
    Write-Log "安装目录：$($Script:RootDir)"
    Write-Log "日志文件：$($Script:LogFile)"
    Write-Log "node 版本：$nodeVersion"
    Write-Log "npm 版本：$npmVersion"
    Write-Log "git 版本：$gitVersion"
    Write-Log "claude 版本：$claudeVersion"
    Write-Log "ANTHROPIC_BASE_URL：$baseUrl"
    Write-Log "主模型：$mainModel"
    Write-Log "快速模型：$fastModel"
    Write-Log "Effort：$effort"
    Write-Log "下一步：重新打开 PowerShell 后运行 claude"

    Write-Warn "环境变量在当前 PowerShell 窗口中尚未生效。"
    Write-Host ""
    Write-Host "  请执行以下其中一种操作使其生效："
    Write-Host "    1. 关闭并重新打开 PowerShell（推荐）"
    Write-Host "    2. 运行: refreshenv   （如果安装了 Chocolatey）"
    Write-Host "    3. 运行以下命令来刷新当前窗口的环境变量："
    Write-Host "       `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"
    Write-Host ""
    Write-Host "  生效后在新的 PowerShell 中运行: claude"
    Write-Host ""
    $answer = Read-Host "是否现在立即尝试在当前窗口启动 claude？输入 Y 启动，其他输入结束"
    if ($answer -match "^(Y|y)$") {
        Write-Warn "当前窗口环境变量可能未完全生效，如果启动失败请换新 PowerShell 窗口重试。"
        $claude = Get-LocalClaudeCommand
        if (-not $claude) {
            Fail "未找到本地 claude，无法启动。"
        }
        & $claude
    }
}

function Remove-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$PathToRemove)

    $resolved = [IO.Path]::GetFullPath($PathToRemove).TrimEnd("\")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @(Split-PathList -Value $userPath)
    $newParts = @()

    foreach ($part in $parts) {
        $partResolved = $part.TrimEnd("\")
        if (-not $partResolved.Equals($resolved, [StringComparison]::OrdinalIgnoreCase)) {
            $newParts += $part
        }
    }

    if ($newParts.Count -ne $parts.Count) {
        $newPath = ($newParts -join ';')
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

        $envParts = @(Split-PathList -Value $env:Path)
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

function Invoke-Uninstall {
    Write-Info "开始清理本脚本写入的所有内容。"

    # 初始化卸载日志
    $uninstallLogDir = if (Test-Path -LiteralPath $Script:RootDir) {
        $logsDir = Join-Path $Script:RootDir "logs"
        New-Item -ItemType Directory -Force -Path $logsDir -ErrorAction SilentlyContinue | Out-Null
        $logsDir
    }
    else {
        $tempLogDir = Join-Path ([IO.Path]::GetTempPath()) "ClaudeCodeCLI_uninstall_logs"
        New-Item -ItemType Directory -Force -Path $tempLogDir -ErrorAction SilentlyContinue | Out-Null
        $tempLogDir
    }
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

    # 从用户 PATH 中自动检测真正的安装目录，应对卸载时忘传 -InstallDir 的情况
    $detectedRoots = @{}
    $userPathForDetect = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not [string]::IsNullOrWhiteSpace($userPathForDetect)) {
        foreach ($entry in $userPathForDetect.Split(';')) {
            if ($entry -match 'ClaudeCodeCLI') {
                # 从 PATH 条目中提取 ClaudeCodeCLI 根目录
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
        # 如果有检测到其他 ClaudeCodeCLI 根目录，提示用户
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
        # 检查是否有正在运行的 Claude Code 进程
        $runningClaude = Get-Process -Name "claude" -ErrorAction SilentlyContinue
        if ($runningClaude) {
            Write-Warn "检测到 Claude Code 进程正在运行（PID：$($runningClaude.Id)），请先关闭 claude 再卸载。"
            Write-UninstallLog "警告：Claude Code 进程正在运行（PID：$($runningClaude.Id)）。"
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

    Write-Info ('正在从 PATH 中移除 {0} 相关条目...' -f $Script:RootDir)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

    # 备份原始 PATH 到桌面，以防误删后可以恢复
    $desktop = [Environment]::GetFolderPath("Desktop")
    $pathBackup = Join-Path $desktop "ClaudeCodeCLI_path_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $userPath | Out-File -LiteralPath $pathBackup -Encoding UTF8
    Write-Info "原始 PATH 已备份到: $pathBackup"
    Write-UninstallLog "PATH 备份已保存到：$pathBackup"

    $rootFull = [IO.Path]::GetFullPath($Script:RootDir).TrimEnd("\")
    $parts = @(Split-PathList -Value $userPath)
    $newParts = @()
    $removedCount = 0
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
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
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-UninstallLog "已更新用户 PATH（移除了 $removedCount 个条目）。"
    }
    else {
        Write-UninstallLog "PATH 中未找到需移除的条目。"
    }

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

    Write-UninstallLog "========== 卸载结束 =========="
    Write-Ok "卸载完成。卸载日志：$uninstallLogFile"
    Write-Ok "请重新打开 PowerShell 使所有变更生效。"
}

function Invoke-Setup {
    Write-Info "开始准备 Claude Code + DeepSeek 环境。"

    Initialize-Directories

    # 初始化日志
    $Script:LogFile = Join-Path $Script:LogsDir ("setup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    New-Item -ItemType Directory -Force -Path $Script:LogsDir | Out-Null
    Write-Log "========== Claude Code + DeepSeek 安装日志 =========="
    Write-Log "启动时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "PowerShell 版本：$($PSVersionTable.PSVersion)"
    if ($InstallDir) {
        Write-Log "安装目录：$($Script:RootDir)（用户指定：$InstallDir）"
    }
    else {
        Write-Log "安装目录：$($Script:RootDir)（默认）"
    }
    if ([string]::IsNullOrWhiteSpace($Script:Proxy)) {
        Write-Log "代理：未使用"
    }
    else {
        Write-Log "代理：$($Script:Proxy)"
    }

    try {
        # 清理旧版本可能写坏的用户 PATH（缺少分号分隔符的条目）
        Repair-UserPath

        if (-not (Confirm-OverwriteExistingConfig)) {
            Write-Warn "用户取消覆盖已有配置，脚本已退出。"
            Write-Log "结果：用户取消覆盖配置，脚本退出。"
            return
        }

        Ensure-Node
        Configure-Npm
        Ensure-Git
        Ensure-ClaudeCode

        Show-VersionSummary

        $apiKey = Read-DeepSeekApiKey
        $modelConfig = Select-DeepSeekModelConfig
        Set-DeepSeekEnvironment -ApiKey $apiKey -ModelConfig $modelConfig

        Write-Log "主模型：$($modelConfig.MainModel)"
        Write-Log "快速模型：$($modelConfig.FastModel)"
        Write-Log "Effort：$($modelConfig.Effort)"

        # 确保当前用户允许运行 PowerShell 脚本，否则 claude.ps1 会被拦截
        $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
        if ($currentPolicy -eq "RemoteSigned" -or $currentPolicy -eq "Bypass" -or $currentPolicy -eq "Unrestricted") {
            Write-Ok "PowerShell 执行策略已为 $currentPolicy（CurrentUser），无需修改。"
        }
        else {
            try {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
                Write-Ok "已设置 PowerShell 执行策略为 RemoteSigned（CurrentUser）。"
            }
            catch {
                Write-Warn "无法设置执行策略（$($_.Exception.Message.Trim())）。Claude Code 可用 claude.cmd 启动。"
            }
        }

        # 确保干净的路径已写入用户级 PATH
        Sync-ClaudeCodeCLIPath

        # 清理 npm 代理配置，避免后续无代理环境下 npm 操作失败
        if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
            $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
            if (Test-Path -LiteralPath $npmCmd) {
                & $npmCmd config delete proxy 2>$null
                & $npmCmd config delete https-proxy 2>$null
                Write-Log "已清理 npm 代理配置。"
            }
        }

        Write-Ok "DeepSeek API 已写入当前 Windows 用户级环境变量。"
        Write-Info "当前主模型：$($modelConfig.MainModel)"
        Write-Info "当前快速模型：$($modelConfig.FastModel)"

        Write-Log "========== 安装成功 =========="
        Confirm-LaunchClaude
    }
    catch {
        Write-Log "========== 安装失败 =========="
        Write-Log "失败原因：$($_.Exception.Message)"
        throw
    }
}

function Main {
    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

    Invoke-Setup
}

Main







