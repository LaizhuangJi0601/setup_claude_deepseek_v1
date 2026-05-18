# env.ps1 — 环境变量读写

function Get-UserEnv {
    param([Parameter(Mandatory = $true)][string]$Name)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
    if (-not $key) { return $null }
    try {
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally {
        $key.Close()
    }
}

function Set-UserEnvRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    if (-not $key) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Environment")
    }

    try {
        $currentValue = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($currentValue -eq $Value) { return }

        if ([string]::IsNullOrEmpty($Value)) {
            try { $key.DeleteValue($Name, $false) } catch { }
        }
        else {
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            try {
                $kind = $key.GetValueKind($Name)
            }
            catch {
                if ($Name.Equals("Path", [StringComparison]::OrdinalIgnoreCase)) {
                    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
                }
            }
            $key.SetValue($Name, $Value, $kind)
        }
        $Script:PendingUserEnvBroadcast = $true
    }
    finally {
        $key.Close()
    }
}

function Publish-UserEnvironmentChange {
    if (-not $Script:PendingUserEnvBroadcast) { return }

    try {
        if (-not ([System.Management.Automation.PSTypeName]'ClaudeCodeSetup.NativeMethods').Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace ClaudeCodeSetup {
public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        int Msg,
        IntPtr wParam,
        string lParam,
        int fuFlags,
        int uTimeout,
        out IntPtr lpdwResult);
}
}
"@
        }

        $result = [IntPtr]::Zero
        $null = [ClaudeCodeSetup.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff,
            0x001A,
            [IntPtr]::Zero,
            "Environment",
            0x0002,
            2000,
            [ref]$result
        )
    }
    catch {
        Write-Warn "环境变量已写入注册表，但通知系统刷新时失败：$($_.Exception.Message)"
    }
    finally {
        $Script:PendingUserEnvBroadcast = $false
    }
}

function Set-UserEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    Set-UserEnvRegistryValue -Name $Name -Value $Value

    if ([string]::IsNullOrEmpty($Value)) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Remove-UserEnv {
    param([Parameter(Mandatory = $true)][string]$Name)

    Set-UserEnvRegistryValue -Name $Name -Value $null
    Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
}

function Get-ProviderAuthEnvName {
    param([Parameter(Mandatory = $true)]$Provider)
    if ($Provider.PSObject.Properties.Name -contains 'AuthEnvName') {
        return $Provider.AuthEnvName
    }
    return "ANTHROPIC_AUTH_TOKEN"
}

function Set-ActiveProviderEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$AuthVarName,
        [AllowEmptyString()][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$MainModel,
        [Parameter(Mandatory = $true)][string]$FastModel,
        [Parameter(Mandatory = $true)][string]$Effort,
        $ExtraEnv = $null,
        [string]$ProviderKey = "",
        [string]$ProviderName = ""
    )

    $desiredEnv = [ordered]@{
        "ANTHROPIC_BASE_URL"                = $BaseUrl
        "ANTHROPIC_MODEL"                   = $MainModel
        "ANTHROPIC_DEFAULT_OPUS_MODEL"      = $MainModel
        "ANTHROPIC_DEFAULT_SONNET_MODEL"    = $MainModel
        "ANTHROPIC_DEFAULT_HAIKU_MODEL"     = $FastModel
        "ANTHROPIC_SMALL_FAST_MODEL"        = $FastModel
        "CLAUDE_CODE_SUBAGENT_MODEL"        = $FastModel
        "CLAUDE_CODE_EFFORT_LEVEL"          = $Effort
    }

    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $desiredEnv[$AuthVarName] = $ApiKey
    }

    if ($ExtraEnv) {
        foreach ($key in $ExtraEnv.Keys) {
            $desiredEnv[$key] = $ExtraEnv[$key]
        }
    }

    foreach ($name in $Script:ManagedEnvVars) {
        if ($desiredEnv.Contains($name)) {
            Set-UserEnv -Name $name -Value $desiredEnv[$name]
        }
        else {
            Remove-UserEnv -Name $name
        }
    }

    if ((-not [string]::IsNullOrWhiteSpace($ApiKey)) -and $ProviderKey) {
        Set-UserEnv -Name "CC_$($ProviderKey.ToUpper())_AUTH" -Value $ApiKey
    }

    Publish-UserEnvironmentChange

    if ($ProviderName) {
        Write-Log "API 提供商：$ProviderName"
    }
    Write-Log "BASE_URL = $BaseUrl"
    Write-Log "$AuthVarName = $(Mask-Secret -Value $ApiKey)"
    Write-Log "主模型 = $MainModel"
    Write-Log "快速模型 = $FastModel"
    Write-Log "Effort = $Effort"
    if ($ExtraEnv) {
        foreach ($key in $ExtraEnv.Keys) {
            Write-Log "$key = $($ExtraEnv[$key])"
        }
    }
}

function Set-APIEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)]$Provider,
        [Parameter(Mandatory = $true)]$ModelConfig,
        [string]$ProviderKey = ""
    )

    $authVar = Get-ProviderAuthEnvName -Provider $Provider
    $extraEnv = Get-ProviderProperty -Provider $Provider -PropertyName 'ExtraEnv'

    Set-ActiveProviderEnvironment `
        -BaseUrl $Provider.BaseUrl `
        -AuthVarName $authVar `
        -ApiKey $ApiKey `
        -MainModel $ModelConfig.MainModel `
        -FastModel $ModelConfig.FastModel `
        -Effort $ModelConfig.Effort `
        -ExtraEnv $extraEnv `
        -ProviderKey $ProviderKey `
        -ProviderName $Provider.Name
}

function Show-VersionSummary {
    $nodeExe = Join-Path $Script:NodeDir "node.exe"
    $npmCmd  = Join-Path $Script:NodeDir "npm.cmd"
    $gitDir  = Get-LocalGitCommandDir
    $claude  = Get-LocalClaudeCommand

    if (-not (Test-Path -LiteralPath $nodeExe)) { Fail "验证失败：未找到本地 node.exe。" }
    if (-not (Test-Path -LiteralPath $npmCmd))  { Fail "验证失败：未找到本地 npm.cmd。" }
    if (-not $gitDir)  { Fail "验证失败：未找到本地 git.exe。" }
    if (-not $claude)  { Fail "验证失败：未找到本地 claude。" }

    $claudeVersion = Invoke-CheckedCommand -FilePath $claude -Arguments @("--version")
    Write-Host ""
    Write-Ok "基础组件验证通过（Claude Code $claudeVersion），继续配置。"
}

function Invoke-TestAPIKey {
    param(
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$AuthVarName,
        [Parameter(Mandatory = $true)][string]$Model
    )

    Write-Info "正在验证 API Key 有效性..."
    try {
        $headers = @{
            "Content-Type"      = "application/json"
            "User-Agent"        = $Script:UserAgent
            "x-api-key"         = $ApiKey
            "anthropic-version" = "2023-06-01"
        }
        $messagesUrl = $BaseUrl.TrimEnd("/") + "/v1/messages"
        $body = @{
            model      = $Model
            max_tokens = 1
            messages   = @(@{ role = "user"; content = "hi" })
        } | ConvertTo-Json -Depth 3

        $response = Invoke-WebRequest -Uri $messagesUrl `
            -Method POST -Headers $headers -Body $body -UseBasicParsing `
            -TimeoutSec 30 -ErrorAction Stop

        if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 201) {
            Write-Ok "API Key 有效 (HTTP $($response.StatusCode))"
            return $true
        }
        Write-Warn "API Key 验证返回异常状态码: HTTP $($response.StatusCode)"
        return $false
    }
    catch [Net.WebException] {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Write-Host "  [错误] API Key 无效 (HTTP $statusCode)" -ForegroundColor Red
            return $false
        }
        if ($statusCode -eq 400 -or $statusCode -eq 404) {
            Write-Host "  [错误] API Key 验证失败 (HTTP $statusCode)。请检查 Key 是否属于当前平台，以及 API 地址和模型是否匹配。" -ForegroundColor Red
            return $false
        }
        if ($statusCode -eq 402 -or $statusCode -eq 429) {
            Write-Warn "请求已到达 API 平台，但账户余额、配额或频率限制阻止了验证 (HTTP $statusCode)。"
            return $false
        }
        Write-Warn "无法连接到 $BaseUrl，跳过 Key 验证。"
        return $null
    }
    catch {
        Write-Warn "API Key 验证异常: $($_.Exception.Message)"
        return $null
    }
}

function Get-CurrentProviderEnvVars {
    $result = @{}
    foreach ($name in $Script:ManagedEnvVars) {
        $value = Get-UserEnv -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $result[$name] = $value
        }
    }
    return $result
}
