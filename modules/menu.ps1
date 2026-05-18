# menu.ps1 — 主菜单、子菜单、帮助、模型选择循环、管理操作

# 安全获取 record 中指定 provider 的配置（兼容 strict mode）
function Get-RecordProviderConfig {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$ProviderKey)
    if (-not $Record -or -not $Record.providers) { return $null }
    $prop = $Record.providers.PSObject.Properties | Where-Object { $_.Name -eq $ProviderKey } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function Pause-Menu {
    Write-Host ""
    Write-Host "按 Enter 键返回..." -NoNewline
    $null = Read-Host
}

function Show-MainMenu {
    while ($true) {
        Write-Host ("`n" * 5)
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host "  Claude Code 多模型管理工具 v$($Script:ScriptVersion)" -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] 完整安装 — 安装 Node/Git/Claude Code + 配置模型"
        Write-Host "  [2] 仅配置模型 — 先检测环境，通过后配置模型"
        Write-Host "  [3] 管理已配置模型 — 切换基座 / 改 Key / 改模型 / 删除"
        Write-Host "  [4] 环境检测 — 显示版本、PATH、环境变量、已配置模型"
        Write-Host "  [5] 卸载 — 自动检测安装目录，确认后清理"
        Write-Host "  [6] 帮助 — 快速帮助 + 可选打开浏览器"
        Write-Host "  [Q] 退出"
        Write-Host ""

        $choice = Read-Host "请输入选项"
        switch ($choice) {
            "1" { Invoke-FullInstall; Pause-Menu }
            "2" { Invoke-ConfigureModels; Pause-Menu }
            "3" { Show-ManageModelsMenu }
            "4" { Invoke-EnvironmentCheck; Pause-Menu }
            "5" { Invoke-Uninstall; Pause-Menu }
            "6" { Show-Help; Pause-Menu }
            "Q" { return }
            "q" { return }
            default { Write-Warn "无效选项，请重新输入。"; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-ManageModelsMenu {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers -or @($record.providers.PSObject.Properties).Count -eq 0) {
        Write-Warn "尚未配置任何提供商，请先完成安装或模型配置。"
        Pause-Menu
        return
    }

    # 自动修正：如果 activeProvider 在 providers 中不存在，取第一个
    $activeConfig = Get-RecordProviderConfig -Record $record -ProviderKey $record.activeProvider
    if (-not $activeConfig) {
        $firstKey = @($record.providers.PSObject.Properties.Name)[0]
        $record | Add-Member -MemberType NoteProperty -Name "activeProvider" -Value $firstKey -Force
        $json = $record | ConvertTo-Json -Depth 4
        $json | Out-File -LiteralPath (Get-RecordFilePath) -Encoding UTF8
    }

    while ($true) {
        Write-Host ("`n" * 5)
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host "  管理已配置模型" -ForegroundColor Cyan
        Write-Host "======================================================" -ForegroundColor Cyan
        Write-Host ""
        $activeName = '无'
        if ($record.activeProvider) {
            $prop = $record.providers.PSObject.Properties | Where-Object { $_.Name -eq $record.activeProvider } | Select-Object -First 1
            if ($prop -and $prop.Value.PSObject.Properties.Name -contains 'name') {
                $activeName = $prop.Value.name
            }
        }
        Write-Host "  当前基座模型: $activeName"
        Write-Host ""
        Write-Host "  [1] 切换基座模型"
        Write-Host "  [2] 修改 API Key"
        Write-Host "  [3] 修改模型参数 (MainModel/FastModel/Effort)"
        Write-Host "  [4] 删除提供商配置"
        Write-Host "  [B] 返回主菜单"
        Write-Host ""

        $choice = Read-Host "请输入选项"
        switch ($choice) {
            "1" { Invoke-SwitchBaseModel; Pause-Menu; return }
            "2" { Invoke-ChangeAPIKey; Pause-Menu; return }
            "3" { Invoke-ChangeModelParams; Pause-Menu; return }
            "4" { Invoke-RemoveProviderConfig; Pause-Menu; return }
            "B" { return }
            "b" { return }
            default { Write-Warn "无效选项，请重新输入。"; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  帮助" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  支持的 API 提供商："
    Write-Host ""
    $i = 1
    foreach ($key in $Script:Providers.Keys) {
        $p = $Script:Providers[$key]
        $authInfo = if ($p.PSObject.Properties.Name -contains 'AuthEnvName') { $p.AuthEnvName } else { "ANTHROPIC_AUTH_TOKEN" }
        Write-Host "  $i. $($p.Name)"
        Write-Host "     地址: $($p.BaseUrl)"
        Write-Host "     认证: $authInfo"
        Write-Host ""
        $i++
    }
    Write-Host "  Key 获取地址："
    Write-Host "    DeepSeek  → platform.deepseek.com"
    Write-Host "    GLM 国内  → open.bigmodel.cn"
    Write-Host "    Kimi K2.5 → platform.moonshot.ai"
    Write-Host "    Kimi K2.6 → kimi.com/code/console"
    Write-Host "    Qwen      → dashscope.aliyun.com"
    Write-Host ""
    Write-Host "  命令行参数："
    Write-Host "    -Uninstall          直接卸载（跳过菜单）"
    Write-Host "    -InstallDir <path>  指定安装目录"
    Write-Host "    -Proxy <url>        指定 HTTP 代理"
    Write-Host "    -Model <key>        直接配置指定模型（跳过菜单）"
    Write-Host ""

    $answer = Read-Host "是否在浏览器中打开项目文档？输入 Y 打开，其他输入跳过"
    if ($answer -match "^(Y|y)$") {
        $docUrl = "https://github.com/LaizhuangJi0601/setup_claude_deepseek"
        try {
            Start-Process $docUrl
            Write-Ok "已打开浏览器。"
        }
        catch {
            Write-Warn "无法打开浏览器。请手动访问：$docUrl"
        }
    }
}

# ======================== 多模型选择循环 ========================
function Select-ProvidersLoop {
    $configuredProviders = [ordered]@{}
    $providerKeys = @($Script:Providers.Keys)

    while ($true) {
        Write-Host ""
        Write-Host "请选择要配置的 API 提供商（已配置显示 ✓）："
        Write-Host ""

        $record = Read-InstallRecord
        $recordProviders = Get-ConfiguredProviders

        $activeKey = if ($record -and $record.activeProvider) { $record.activeProvider } else { "" }

        for ($i = 0; $i -lt $providerKeys.Count; $i++) {
            $key = $providerKeys[$i]
            $p = $Script:Providers[$key]
            $mark = if ($recordProviders.ContainsKey($key)) { " ✓" } else { "  " }
            $activeMark = if ($activeKey -eq $key) { " [当前基座]" } else { "" }
            Write-Host "[$($i+1)]$mark $($p.Name)$activeMark"
            Write-Host "    $($p.Description)"
            Write-Host ""
        }
        Write-Host "[B] 返回$(if ($configuredProviders.Count -gt 0) { '完成配置' } else { '' })"
        Write-Host ""

        $choice = Read-Host "请输入选项编号"
        if ($choice -match "^(B|b)$") { break }

        $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
        if (-not $idx) {
            Write-Warn "请输入 1 到 $($providerKeys.Count) 或 B。"
            continue
        }

        $selectedKey = $providerKeys[$idx - 1]
        $provider = $Script:Providers[$selectedKey]

        if (($configuredProviders.Keys -contains $selectedKey) -or $recordProviders.ContainsKey($selectedKey)) {
            Write-Warn "$($provider.Name) 已配置，请选择其他提供商。"
            continue
        }

        Write-Ok "已选择：$($provider.Name)"
        $hint = Get-ProviderProperty -Provider $provider -PropertyName 'Hint'
        if ($hint) {
            Write-Host "  [提示] $hint" -ForegroundColor DarkYellow
        }

        $modelConfig = Select-ModelConfig -Provider $provider
        $apiKey = Read-APIKey -Provider $provider -ProviderKey $selectedKey

        # Key 验证
        $authVar = if ($provider.PSObject.Properties.Name -contains 'AuthEnvName') { $provider.AuthEnvName } else { "ANTHROPIC_AUTH_TOKEN" }
        $validationResult = Invoke-TestAPIKey -ApiKey $apiKey -BaseUrl $provider.BaseUrl -AuthVarName $authVar -Model $modelConfig.MainModel
        if ($validationResult -eq $false) {
            $answer = Read-Host "API Key 验证未通过，是否仍要保存？输入 Y 保存，其他输入重新选择"
            if ($answer -notmatch "^(Y|y)$") {
                Write-Warn "已取消保存该提供商配置。"
                continue
            }
        }
        elseif ($validationResult -eq $null) {
            Write-Warn "无法完成 API Key 验证（网络问题），已跳过。"
        }
        else {
            Write-Ok "API Key 验证通过。请确认此 Key 属于 $($provider.Name) 平台，否则 Claude Code 将无法正常使用。"
        }

        Write-Info "正在写入 $($provider.Name) 环境变量..."
        Set-APIEnvironment -ApiKey $apiKey -Provider $provider -ModelConfig $modelConfig -ProviderKey $selectedKey
        Write-Ok "$($provider.Name) 环境变量已写入。"

        $configuredProviders[$selectedKey] = [PSCustomObject]@{
            name      = $provider.Name
            baseUrl   = $provider.BaseUrl
            authVar   = $authVar
            mainModel = $modelConfig.MainModel
            fastModel = $modelConfig.FastModel
            effort    = $modelConfig.Effort
        }

        Write-Host ""
        Write-Ok "$($provider.Name) 已配置。"
        Write-Info "本次流程将继续完成安装。若要添加更多提供商，安装完成后重新运行脚本并选择 [2] 仅配置模型。"
        break
    }

    return $configuredProviders
}

# ======================== [管理] 切换基座模型 ========================
function Invoke-SwitchBaseModel {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) {
        Write-Warn "尚未配置任何提供商。"
        return
    }

    $providerKeys = @($record.providers.PSObject.Properties.Name)
    if ($providerKeys.Count -le 1) {
        Write-Warn "仅有一个已配置的提供商，无需切换。"
        return
    }

    Write-Host ""
    Write-Host "当前基座模型：$($record.activeProvider)"
    Write-Host ""

    for ($i = 0; $i -lt $providerKeys.Count; $i++) {
        $key = $providerKeys[$i]
        $config = (Get-RecordProviderConfig -Record $record -ProviderKey $key)
        $activeMark = if ($key -eq $record.activeProvider) { " [当前]" } else { "" }
        Write-Host "[$($i+1)] $($config.name)$activeMark"
    }
    Write-Host "[B] 取消"

    $choice = Read-Host "请选择要切换到的提供商"
    if ($choice -match "^(B|b)$") { return }

    $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
    if (-not $idx) {
        Write-Warn "无效选项。"
        return
    }

    $targetKey = $providerKeys[$idx - 1]
    if ($targetKey -eq $record.activeProvider) {
        Write-Warn "已经是当前基座模型。"
        return
    }

    $targetConfig = (Get-RecordProviderConfig -Record $record -ProviderKey $targetKey)

    $dedicatedKey = "CC_$($targetKey.ToUpper())_AUTH"
    $targetApiKey = Get-UserEnv -Name $dedicatedKey
    if (-not $targetApiKey) {
        Write-Warn "未找到 $($targetConfig.name) 的专属 Key ($dedicatedKey)，请先修改该提供商的 API Key。"
        return
    }

    $providerDef = if ($Script:Providers.Contains($targetKey)) { $Script:Providers[$targetKey] } else { $null }
    $extraEnv = if ($providerDef) { Get-ProviderProperty -Provider $providerDef -PropertyName 'ExtraEnv' } else { $null }

    Set-ActiveProviderEnvironment `
        -BaseUrl $targetConfig.baseUrl `
        -AuthVarName $targetConfig.authVar `
        -ApiKey $targetApiKey `
        -MainModel $targetConfig.mainModel `
        -FastModel $targetConfig.fastModel `
        -Effort $targetConfig.effort `
        -ExtraEnv $extraEnv `
        -ProviderKey $targetKey `
        -ProviderName $targetConfig.name

    Update-InstallRecord -ActiveProvider $targetKey

    Write-Ok "已切换到基座模型：$($targetConfig.name)"
    Write-Info "API 地址：$($targetConfig.baseUrl)"
    Write-Info "主模型：$($targetConfig.mainModel)"
    Write-Info "快速模型：$($targetConfig.fastModel)"
}

# ======================== [管理] 修改 API Key ========================
function Invoke-ChangeAPIKey {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) {
        Write-Warn "尚未配置任何提供商。"
        return
    }

    $providerKeys = @($record.providers.PSObject.Properties.Name)

    Write-Host ""
    for ($i = 0; $i -lt $providerKeys.Count; $i++) {
        $key = $providerKeys[$i]
        $config = (Get-RecordProviderConfig -Record $record -ProviderKey $key)
        Write-Host "[$($i+1)] $($config.name)"
    }
    Write-Host "[B] 取消"

    $choice = Read-Host "请选择要修改 Key 的提供商"
    if ($choice -match "^(B|b)$") { return }

    $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
    if (-not $idx) { Write-Warn "无效选项。"; return }

    $targetKey = $providerKeys[$idx - 1]
    $config = (Get-RecordProviderConfig -Record $record -ProviderKey $targetKey)
    $dedicatedKey = "CC_$($targetKey.ToUpper())_AUTH"

    $currentKey = if ($targetKey -eq $record.activeProvider) { Get-UserEnv -Name $config.authVar } else { Get-UserEnv -Name $dedicatedKey }
    Write-Host ""
    Write-Host "提供商：$($config.name)"
    Write-Host "当前 Key：$(Mask-Secret -Value $currentKey)"
    $authDisplay = if ($targetKey -eq $record.activeProvider) { "$dedicatedKey / $($config.authVar)" } else { $dedicatedKey }
    Write-Host "环境变量：$authDisplay"

    $providerDef = if ($Script:Providers.Contains($targetKey)) { $Script:Providers[$targetKey] } else { [PSCustomObject]@{ Name = $config.name } }
    $newKey = Read-APIKey -Provider $providerDef -ProviderKey $targetKey -AllowEmptyCancel
    if ([string]::IsNullOrWhiteSpace($newKey)) { Write-Warn "已取消。"; return }

    $validationResult = Invoke-TestAPIKey -ApiKey $newKey -BaseUrl $config.baseUrl -AuthVarName $config.authVar -Model $config.mainModel
    if ($validationResult -eq $false) {
        $answer = Read-Host "Key 验证未通过，是否仍要保存？输入 Y 保存，其他输入取消"
        if ($answer -notmatch "^(Y|y)$") { Write-Warn "已取消。"; return }
    }

    Set-UserEnv -Name $dedicatedKey -Value $newKey
    if ($targetKey -eq $record.activeProvider) {
        Set-UserEnv -Name $config.authVar -Value $newKey
    }
    Publish-UserEnvironmentChange
    Write-Ok "$($config.name) API Key 已更新。"
}

# ======================== [管理] 修改模型参数 ========================
function Invoke-ChangeModelParams {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) {
        Write-Warn "尚未配置任何提供商。"
        return
    }

    $providerKeys = @($record.providers.PSObject.Properties.Name)

    Write-Host ""
    for ($i = 0; $i -lt $providerKeys.Count; $i++) {
        $key = $providerKeys[$i]
        $config = (Get-RecordProviderConfig -Record $record -ProviderKey $key)
        Write-Host "[$($i+1)] $($config.name)"
    }
    Write-Host "[B] 取消"

    $choice = Read-Host "请选择要修改模型参数的提供商"
    if ($choice -match "^(B|b)$") { return }

    $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
    if (-not $idx) { Write-Warn "无效选项。"; return }

    $targetKey = $providerKeys[$idx - 1]
    $providerDef = $Script:Providers[$targetKey]
    if (-not $providerDef) { Write-Warn "提供商定义已不存在：$targetKey"; return }

    $modelConfig = Select-ModelConfig -Provider $providerDef

    $updatedConfig = @{
        name      = $providerDef.Name
        baseUrl   = $providerDef.BaseUrl
        authVar   = Get-ProviderAuthEnvName -Provider $providerDef
        mainModel = $modelConfig.MainModel
        fastModel = $modelConfig.FastModel
        effort    = $modelConfig.Effort
    }
    Add-ProviderToRecord -Key $targetKey -Config $updatedConfig

    if ($targetKey -eq $record.activeProvider) {
        $dedicatedKey = "CC_$($targetKey.ToUpper())_AUTH"
        $apiKey = Get-UserEnv -Name $dedicatedKey
        if (-not $apiKey) {
            $apiKey = Get-UserEnv -Name $updatedConfig.authVar
        }
        $extraEnv = Get-ProviderProperty -Provider $providerDef -PropertyName 'ExtraEnv'
        Set-ActiveProviderEnvironment `
            -BaseUrl $updatedConfig.baseUrl `
            -AuthVarName $updatedConfig.authVar `
            -ApiKey $apiKey `
            -MainModel $updatedConfig.mainModel `
            -FastModel $updatedConfig.fastModel `
            -Effort $updatedConfig.effort `
            -ExtraEnv $extraEnv `
            -ProviderKey $targetKey `
            -ProviderName $updatedConfig.name
    }

    Write-Ok "$($providerDef.Name) 模型已更新为：$($modelConfig.Label)"
}

# ======================== [管理] 删除提供商配置 ========================
function Invoke-RemoveProviderConfig {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) {
        Write-Warn "尚未配置任何提供商。"
        return
    }

    $providerKeys = @($record.providers.PSObject.Properties.Name)

    Write-Host ""
    for ($i = 0; $i -lt $providerKeys.Count; $i++) {
        $key = $providerKeys[$i]
        $config = (Get-RecordProviderConfig -Record $record -ProviderKey $key)
        $activeTag = if ($key -eq $record.activeProvider) { " [当前基座]" } else { "" }
        Write-Host "[$($i+1)] $($config.name)$activeTag"
    }
    Write-Host "[B] 取消"

    $choice = Read-Host "请选择要删除的提供商"
    if ($choice -match "^(B|b)$") { return }

    $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
    if (-not $idx) { Write-Warn "无效选项。"; return }

    $targetKey = $providerKeys[$idx - 1]
    $config = (Get-RecordProviderConfig -Record $record -ProviderKey $targetKey)

    if ($targetKey -eq $record.activeProvider -and $providerKeys.Count -gt 1) {
        Write-Warn "$($config.name) 是当前基座模型，无法直接删除。请先切换到其他基座模型。"
        return
    }

    Write-Host ""
    Write-Host "确认删除：$($config.name)"
    Write-Host "  地址：$($config.baseUrl)"
    Write-Host "  模型：$($config.mainModel)"
    $confirm = Read-Host "确认删除？输入 Y 确认，其他输入取消"
    if ($confirm -notmatch "^(Y|y)$") { Write-Warn "已取消。"; return }

    $providersHash = @{}
    foreach ($kv in $record.providers.PSObject.Properties) {
        if ($kv.Name -ne $targetKey) { $providersHash[$kv.Name] = $kv.Value }
    }

    Remove-UserEnv -Name "CC_$($targetKey.ToUpper())_AUTH"

    if ($providersHash.Count -eq 0) {
        Write-Info "已无配置的提供商，清理所有环境变量..."
        foreach ($varName in $Script:ManagedEnvVars) {
            Remove-UserEnv -Name $varName
        }
        Update-InstallRecord -Providers $providersHash -ActiveProvider ""
    }
    else {
        Update-InstallRecord -Providers $providersHash
    }

    Publish-UserEnvironmentChange

    Write-Ok "已删除 $($config.name) 的配置。"
}
