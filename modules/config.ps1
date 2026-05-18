# config.ps1 — 安装目录与全局变量定义
# 依赖：调用方需已设置 $InstallDir、$Proxy 变量

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- TLS 兼容 ----------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# ---------- 控制台 UTF-8 ----------
try {
    $utf8 = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = $utf8
    [Console]::InputEncoding = $utf8
    $null = chcp 65001 2>$null
}
catch {
    Write-Host "[警告] 无法设置控制台 UTF-8 编码，中文可能显示异常。" -ForegroundColor Yellow
}

# ---------- 安装根目录 ----------
if ($InstallDir) {
    $resolved = [IO.Path]::GetFullPath($InstallDir)
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "指定的安装目录父路径不存在：$parent，请先确保盘符存在或检查路径拼写。"
    }
    $Script:RootDir = $resolved
}
elseif (Test-Path -LiteralPath "D:\" -PathType Container) {
    $Script:RootDir = "D:\ClaudeCodeCLI"
}
else {
    $Script:RootDir = Join-Path $env:USERPROFILE "ClaudeCodeCLI"
}

# ---------- 子目录变量 ----------
$Script:NodeDir       = Join-Path $Script:RootDir "nodejs"
$Script:NpmGlobalDir  = Join-Path $Script:RootDir "npm-global"
$Script:NpmCacheDir   = Join-Path $Script:RootDir "npm-cache"
$Script:GitDir        = Join-Path $Script:RootDir "Git"
$Script:DownloadsDir  = Join-Path $Script:RootDir "downloads"
$Script:LogsDir       = Join-Path $Script:RootDir "logs"

# ---------- 脚本级常量 ----------
$Script:NetworkFailureMessage = "下载失败，请使用代理后重新运行本脚本。"
$Script:UserAgent             = "ClaudeCodeCLI-Setup/2.0"
$Script:NpmRegistry           = "https://registry.npmjs.org/"
$Script:NpmRegistryMirror     = "https://registry.npmmirror.com/"
$Script:Proxy                 = $Proxy
$Script:ScriptVersion         = "2.0"
$Script:RecordFileName        = ".claude-code-setup.json"
$Script:DiskSpaceThresholdGB  = 1.5
$Script:LogFile               = $null
$Script:PendingUserEnvBroadcast = $false

# ---------- 托管环境变量列表 ----------
$Script:ManagedEnvVars = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
    "API_TIMEOUT_MS",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "ENABLE_TOOL_SEARCH"
)

# ---------- 目录初始化 ----------
function Initialize-Directories {
    $parentPath = Split-Path -Parent $Script:RootDir
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        throw "未检测到目标盘符 $parentPath，无法创建 $Script:RootDir。"
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

# ---------- 代理初始化 ----------
function Initialize-Proxy {
    if ([string]::IsNullOrWhiteSpace($Script:Proxy)) {
        return
    }

    $Script:Proxy = $Script:Proxy.Trim()
    $env:HTTP_PROXY  = $Script:Proxy
    $env:HTTPS_PROXY = $Script:Proxy
    $env:ALL_PROXY   = $Script:Proxy
    Write-Info "本次脚本将使用代理：$Script:Proxy"
}

# ---------- 磁盘空间检查 ----------
function Test-DiskSpace {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    $driveName = $root.TrimEnd(":\")
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if (-not $drive) { return $true }

    $freeGB = [Math]::Round($drive.Free / 1GB, 1)
    Write-Info "磁盘 ($root) 剩余空间：${freeGB}GB"
    if ($freeGB -lt $Script:DiskSpaceThresholdGB) {
        Write-Warn "磁盘空间不足！仅剩 ${freeGB}GB，安装建议至少 $($Script:DiskSpaceThresholdGB)GB。"
        $answer = Read-Host "是否继续？输入 Y 继续，其他输入退出"
        return $answer -match "^(Y|y)$"
    }
    return $true
}

# ---------- 脚本版本检查 ----------
function Test-ScriptVersion {
    # 此功能需配置实际仓库地址后启用，当前仅占位
}
