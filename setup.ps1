[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Proxy,
    [string]$InstallDir,
    [string]$Model
)

# ======================== 加载子模块 ========================
$moduleDir = Join-Path $PSScriptRoot "modules"

. (Join-Path $moduleDir "config.ps1")
. (Join-Path $moduleDir "utils.ps1")
. (Join-Path $moduleDir "record.ps1")
. (Join-Path $moduleDir "providers.ps1")
. (Join-Path $moduleDir "download.ps1")
. (Join-Path $moduleDir "path.ps1")
. (Join-Path $moduleDir "install.ps1")
. (Join-Path $moduleDir "env.ps1")
. (Join-Path $moduleDir "uninstall.ps1")
. (Join-Path $moduleDir "menu.ps1")

# ======================== 辅助函数 ========================
function Initialize-LogHeader {
    $Script:LogFile = Join-Path $Script:LogsDir ("setup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    New-Item -ItemType Directory -Force -Path $Script:LogsDir | Out-Null
    Write-Log "========== Claude Code 安装日志 =========="
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
}

function Set-ExecutionPolicyIfNeeded {
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
}

function Get-ComponentVersions {
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd  = Join-Path $Script:NodeDir "npm.cmd"
    $gitDir  = Get-LocalGitCommandDir
    $claude  = Get-LocalClaudeCommand

    return [PSCustomObject]@{
        node       = if (Test-Path -LiteralPath $nodeExe) { Invoke-CheckedCommand -FilePath $nodeExe -Arguments @("--version") } else { "未安装" }
        npm        = if (Test-Path -LiteralPath $npmCmd)  { Invoke-CheckedCommand -FilePath $npmCmd  -Arguments @("--version") } else { "未安装" }
        git        = if ($gitDir) { Invoke-CheckedCommand -FilePath (Join-Path $gitDir "git.exe") -Arguments @("--version") } else { "未安装" }
        claudeCode = if ($claude) { Invoke-CheckedCommand -FilePath $claude -Arguments @("--version") } else { "未安装" }
    }
}

function Clean-NpmProxyIfNeeded {
    if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
        $npmCmd = Join-Path $Script:NodeDir "npm.cmd"
        if (Test-Path -LiteralPath $npmCmd) {
            & $npmCmd config delete proxy 2>$null
            & $npmCmd config delete https-proxy 2>$null
            Write-Log "已清理 npm 代理配置。"
        }
    }
}

# ======================== 确认覆盖已有配置 ========================
function Confirm-OverwriteExistingConfig {
    $existing = @()
    foreach ($name in $Script:ManagedEnvVars) {
        $value = Get-UserEnv -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $display = if ($name -match "ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY") { Mask-Secret -Value $value } else { $value }
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

    $answer = Read-Host "是否覆盖为本次配置？输入 Y 继续，其他输入退出"
    return $answer -match "^(Y|y)$"
}

# ======================== API Key 输入 ========================
function Read-APIKey {
    param(
        [Parameter(Mandatory = $true)]$Provider,
        [string]$ProviderKey = "",
        [switch]$AllowEmptyCancel
    )

    if ($ProviderKey) {
        $automationEnvName = "CC_$($ProviderKey.ToUpper())_TEST_API_KEY"
        $automationKey = [Environment]::GetEnvironmentVariable($automationEnvName, "Process")
        if ([string]::IsNullOrWhiteSpace($automationKey)) {
            $automationKey = [Environment]::GetEnvironmentVariable($automationEnvName, "User")
        }
        if (-not [string]::IsNullOrWhiteSpace($automationKey)) {
            Write-Info "已从 $automationEnvName 读取 $($Provider.Name) 测试 API Key。"
            return $automationKey
        }
    }

    $secure = Read-Host "请输入 $($Provider.Name) API Key" -AsSecureString
    $plain  = ConvertFrom-SecureStringPlainText -SecureValue $secure
    if ([string]::IsNullOrWhiteSpace($plain)) {
        if ($AllowEmptyCancel) {
            return $null
        }
        Fail "$($Provider.Name) API Key 不能为空。"
    }
    return $plain
}

# ======================== 安装后总结 ========================
function Confirm-LaunchClaude {
    $components = Get-ComponentVersions
    $baseUrl    = Get-UserEnv -Name "ANTHROPIC_BASE_URL"
    $mainModel  = Get-UserEnv -Name "ANTHROPIC_MODEL"
    $fastModel  = Get-UserEnv -Name "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    $effort     = Get-UserEnv -Name "CLAUDE_CODE_EFFORT_LEVEL"

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  安装已完成！" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  安装目录：  $($Script:RootDir)"
    Write-Host "  日志文件：  $($Script:LogFile)"
    Write-Host "  node 版本： $($components.node)"
    Write-Host "  npm 版本：  $($components.npm)"
    Write-Host "  git 版本：  $($components.git)"
    Write-Host "  claude 版本：$($components.claudeCode)"
    Write-Host "  API 地址：  $baseUrl"
    Write-Host "  主模型：    $mainModel"
    Write-Host "  快速模型：  $fastModel"
    Write-Host "  Effort：    $effort"
    Write-Host ""

    Write-Log "========== 安装总结 =========="
    Write-Log "安装目录：$($Script:RootDir)"
    Write-Log "node 版本：$($components.node)"
    Write-Log "npm 版本：$($components.npm)"
    Write-Log "git 版本：$($components.git)"
    Write-Log "claude 版本：$($components.claudeCode)"
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

# ======================== [1] 完整安装 ========================
function Invoke-FullInstall {
    Write-Info "开始完整安装：Node/Git/Claude Code + 模型配置"

    if (-not (Test-DiskSpace -Path $Script:RootDir)) {
        Write-Warn "用户因磁盘空间不足取消安装。"
        return
    }

    Initialize-Directories
    Initialize-LogHeader

    try {
        Repair-UserPath

        if (-not (Confirm-OverwriteExistingConfig)) {
            Write-Warn "用户取消覆盖已有配置。"
            Write-Log "结果：用户取消覆盖配置，脚本退出。"
            return
        }

        Ensure-Node
        Configure-Npm
        Ensure-Git
        Ensure-ClaudeCode
        Show-VersionSummary

        # 多模型选择循环
        $configuredProviders = Select-ProvidersLoop

        if ($configuredProviders.Count -eq 0) {
            Write-Warn "未配置任何 API 提供商。基础组件安装已完成。"
            Write-Log "结果：基础组件安装完成，但未配置模型。"
            return
        }

        # 取第一个配置的 provider 作为活动基座
        $activeKey = @($configuredProviders.Keys)[-1]

        # 收集组件版本
        $components = Get-ComponentVersions

        # 保存安装记录
        Save-InstallRecord -ActiveProvider $activeKey -Components $components -Providers $configuredProviders

        Set-ExecutionPolicyIfNeeded
        Sync-ClaudeCodeCLIPath
        Clean-NpmProxyIfNeeded

        Write-Log "========== 安装成功 =========="
        Write-Log "活动提供商：$activeKey"

        # 总结已配置的模型
        Write-Host ""
        Write-Ok "已配置 $($configuredProviders.Count) 个 API 提供商："
        foreach ($kv in $configuredProviders.GetEnumerator()) {
            $config = $kv.Value
            $activeTag = if ($kv.Key -eq $activeKey) { " [基座]" } else { "" }
            Write-Host "  - $($config.name)$activeTag ($($config.mainModel))"
        }

        Confirm-LaunchClaude
    }
    catch {
        Write-Log "========== 安装失败 =========="
        Write-Log "失败原因：$($_.Exception.Message)"
        throw
    }
}

# ======================== [2] 仅配置模型 ========================
function Invoke-ConfigureModels {
    Write-Info "开始配置模型..."

    # 环境检测
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $gitDir  = Get-LocalGitCommandDir
    $claude  = Get-LocalClaudeCommand

    $missing = @()
    if (-not (Test-Path -LiteralPath $nodeExe)) { $missing += "Node.js" }
    if (-not $gitDir) { $missing += "Git" }
    if (-not $claude) { $missing += "Claude Code" }

    if ($missing.Count -gt 0) {
        Write-Warn "以下组件未安装：$($missing -join ', ')"
        Write-Warn "请先运行菜单选项 [1] 完整安装。"
        return
    }

    Write-Ok "环境检测通过：所有组件已安装。"

    Initialize-Directories
    New-Item -ItemType Directory -Force -Path $Script:LogsDir | Out-Null
    $Script:LogFile = Join-Path $Script:LogsDir ("config_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    Write-Log "========== 模型配置日志 =========="

    try {
        $configuredProviders = Select-ProvidersLoop

        if ($configuredProviders.Count -eq 0) {
            Write-Warn "未配置任何 API 提供商。"
            return
        }

        $activeKey = @($configuredProviders.Keys)[-1]
        $record = Read-InstallRecord
        if ($record) {
            $mergedProviders = Merge-ProviderConfigs -ExistingProviders $record.providers -NewProviders $configuredProviders
            Update-InstallRecord -ActiveProvider $activeKey -Providers $mergedProviders
        }
        else {
            $components = Get-ComponentVersions
            Save-InstallRecord -ActiveProvider $activeKey -Components $components -Providers $configuredProviders
        }

        Write-Ok "已配置 $($configuredProviders.Count) 个 API 提供商。"
    }
    catch {
        Write-Log "配置失败：$($_.Exception.Message)"
        throw
    }
}

# ======================== [4] 环境检测 ========================
function Invoke-EnvironmentCheck {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  环境检测报告" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""

    # PowerShell
    Write-Host "  PowerShell：$($PSVersionTable.PSVersion)" -ForegroundColor $(if ($PSVersionTable.PSVersion.Major -ge 7) { "Green" } else { "Yellow" })

    # Node
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    if (Test-Path -LiteralPath $nodeExe) {
        try { $nv = Invoke-CheckedCommand -FilePath $nodeExe -Arguments @("--version"); Write-Host "  Node.js：  $nv ($nodeExe)" -ForegroundColor Green }
        catch { Write-Host "  Node.js：  (无法获取版本) ($nodeExe)" -ForegroundColor Yellow }
    }
    else { Write-Host "  Node.js：  未安装" -ForegroundColor Red }

    # Git
    $gitDir = Get-LocalGitCommandDir
    if ($gitDir) {
        try { $gv = Invoke-CheckedCommand -FilePath (Join-Path $gitDir "git.exe") -Arguments @("--version"); Write-Host "  Git：      $gv ($gitDir)" -ForegroundColor Green }
        catch { Write-Host "  Git：      (无法获取版本) ($gitDir)" -ForegroundColor Yellow }
    }
    else { Write-Host "  Git：      未安装" -ForegroundColor Red }

    # Claude Code
    $claude = Get-LocalClaudeCommand
    if ($claude) {
        try { $cv = Invoke-CheckedCommand -FilePath $claude -Arguments @("--version"); Write-Host "  Claude Code：$cv ($claude)" -ForegroundColor Green }
        catch { Write-Host "  Claude Code：(无法获取版本) ($claude)" -ForegroundColor Yellow }
    }
    else { Write-Host "  Claude Code：未安装" -ForegroundColor Red }

    # 环境变量
    Write-Host ""
    Write-Host "  --- ANTHROPIC_* 环境变量 ---"
    $hasAny = $false
    foreach ($name in $Script:ManagedEnvVars) {
        $value = Get-UserEnv -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $display = if ($name -match "AUTH_TOKEN|API_KEY") { Mask-Secret -Value $value } else { $value }
            Write-Host "  $name = $display"
            $hasAny = $true
        }
    }
    if (-not $hasAny) { Write-Host "  （无）" -ForegroundColor DarkGray }

    # 已配置的提供商
    Write-Host ""
    Write-Host "  --- 已配置的提供商 ---"
    $record = Read-InstallRecord
    if ($record -and $record.providers -and @($record.providers.PSObject.Properties).Count -gt 0) {
        foreach ($kv in $record.providers.PSObject.Properties) {
            $config = $kv.Value
            $activeTag = if ($record.activeProvider -eq $kv.Name) { " [当前基座]" } else { "" }
            Write-Host "  [$($kv.Name)] $($config.name)$activeTag"
            Write-Host "  地址：$($config.baseUrl)"
            Write-Host "  模型：$($config.mainModel) / $($config.fastModel) [effort=$($config.effort)]"
            Write-Host ""
        }
    }
    else { Write-Host "  （无）" -ForegroundColor DarkGray }

    # 磁盘
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Script:RootDir))
    $driveName = $root.TrimEnd(":\")
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [Math]::Round($drive.Free / 1GB, 1)
        $totalGB = [Math]::Round(($drive.Used + $drive.Free) / 1GB, 1)
        Write-Host "  --- 磁盘 ($root) ---"
        Write-Host "  总空间：${totalGB}GB，剩余：${freeGB}GB"
    }

    # PATH
    Write-Host ""
    Write-Host "  --- 用户 PATH (ClaudeCodeCLI 相关) ---"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $cliEntries = @(Split-PathList -Value $userPath) | Where-Object { $_ -match 'ClaudeCodeCLI' }
    if ($cliEntries.Count -gt 0) {
        foreach ($entry in $cliEntries) {
            $exists = if ($entry -and (Test-Path -LiteralPath $entry)) { "存在" } else { "不存在" }
            Write-Host "  $entry [$exists]"
        }
    }
    else { Write-Host "  （PATH 中未找到 ClaudeCodeCLI 相关条目）" -ForegroundColor DarkGray }
}

# ======================== CLI -Model 直接模式 ========================
function Invoke-SetupDirect {
    param([Parameter(Mandatory = $true)][string]$ModelSpec)

    $parts = $ModelSpec -split '/'
    $providerKey = $parts[0]
    $modelLabel  = if ($parts.Count -gt 1) { $parts[1] } else { $null }

    if (-not $Script:Providers.Contains($providerKey)) {
        Fail "未知的提供商 Key: $providerKey。可用：$($Script:Providers.Keys -join ', ')"
    }

    $provider = $Script:Providers[$providerKey]

    $modelConfig = if ($modelLabel) {
        $model = $provider.Models | Where-Object { $_.Label -eq $modelLabel -or $_.MainModel -eq $modelLabel } | Select-Object -First 1
        if (-not $model) { Fail "未找到模型: $modelLabel" }
        $model
    }
    else {
        $provider.Models[0]
    }

    Write-Info "开始配置：$($provider.Name) -> $($modelConfig.Label)"

    Initialize-Directories
    Initialize-LogHeader

    try {
        Repair-UserPath

        Ensure-Node
        Configure-Npm
        Ensure-Git
        Ensure-ClaudeCode
        Show-VersionSummary

        $apiKey = Read-APIKey -Provider $provider -ProviderKey $providerKey
        $authVar = if ($provider.PSObject.Properties.Name -contains 'AuthEnvName') { $provider.AuthEnvName } else { "ANTHROPIC_AUTH_TOKEN" }
        $validationResult = Invoke-TestAPIKey -ApiKey $apiKey -BaseUrl $provider.BaseUrl -AuthVarName $authVar -Model $modelConfig.MainModel
        if ($validationResult -eq $false) {
            Fail "API Key 验证未通过，已停止写入配置。"
        }
        elseif ($validationResult -eq $null) {
            Write-Warn "无法完成 API Key 验证（网络问题），将继续写入配置。"
        }
        Set-APIEnvironment -ApiKey $apiKey -Provider $provider -ModelConfig $modelConfig -ProviderKey $providerKey

        $components = Get-ComponentVersions
        $providersHash = @{
            $providerKey = [PSCustomObject]@{
                name      = $provider.Name
                baseUrl   = $provider.BaseUrl
                authVar   = $authVar
                mainModel = $modelConfig.MainModel
                fastModel = $modelConfig.FastModel
                effort    = $modelConfig.Effort
            }
        }
        Save-InstallRecord -ActiveProvider $providerKey -Components $components -Providers $providersHash

        Set-ExecutionPolicyIfNeeded
        Sync-ClaudeCodeCLIPath
        Clean-NpmProxyIfNeeded

        Write-Log "========== 安装成功 =========="
        Confirm-LaunchClaude
    }
    catch {
        Write-Log "========== 安装失败 =========="
        Write-Log "失败原因：$($_.Exception.Message)"
        throw
    }
}

# ======================== 主入口 ========================
function Main {
    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

    Test-ScriptVersion

    if ($Model) {
        Invoke-SetupDirect -ModelSpec $Model
        return
    }

    Show-MainMenu
}

Main
