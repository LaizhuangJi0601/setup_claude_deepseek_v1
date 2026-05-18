# providers.ps1 — API 提供商定义与模型选择

$Script:Providers = [ordered]@{
    "deepseek" = [PSCustomObject]@{
        Name        = "DeepSeek"
        BaseUrl     = "https://api.deepseek.com/anthropic"
        Description = "性价比最高，V4-Pro 适合日常 Claude Code 使用"
        Models      = @(
            [PSCustomObject]@{ Label = "V4-Pro[1m] + V4-Flash"; MainModel = "deepseek-v4-pro[1m]"; FastModel = "deepseek-v4-flash"; Effort = "max"    ; Desc = "推荐：性能优先，适合日常 Claude Code 使用" },
            [PSCustomObject]@{ Label = "V4-Flash";                  MainModel = "deepseek-v4-flash";    FastModel = "deepseek-v4-flash"; Effort = "medium" ; Desc = "速度优先，适合轻量任务" }
        )
    }
    "glm" = [PSCustomObject]@{
        Name        = "智谱 GLM (Z.AI)"
        BaseUrl     = "https://api.z.ai/api/anthropic"
        Description = "GLM-5.1 旗舰模型，744B MoE，支持超长自主任务"
        ExtraEnv    = @{
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" = "1"
            "API_TIMEOUT_MS" = "3000000"
        }
        Models      = @(
            [PSCustomObject]@{ Label = "GLM-5.1 + GLM-4.7";     MainModel = "glm-5.1"; FastModel = "glm-4.7";     Effort = "max"    ; Desc = "推荐：GLM-5.1 旗舰推理 + GLM-4.7 日常编码" },
            [PSCustomObject]@{ Label = "GLM-4.7 + GLM-4.5-Air"; MainModel = "glm-4.7"; FastModel = "glm-4.5-air"; Effort = "medium" ; Desc = "均衡：GLM-4.7 主力 + GLM-4.5-Air 轻量任务" },
            [PSCustomObject]@{ Label = "GLM-4.5-Air";           MainModel = "glm-4.5-air"; FastModel = "glm-4.5-air"; Effort = "medium" ; Desc = "轻量：仅使用 GLM-4.5-Air" }
        )
    }
    "kimi" = [PSCustomObject]@{
        Name        = "Kimi K2.5 (Moonshot)"
        BaseUrl     = "https://api.moonshot.cn/anthropic"
        Description = "Kimi K2.5，1T MoE，256K 上下文（Moonshot 中文开放平台）"
        Hint        = "国内 Kimi/Moonshot Key 使用 api.moonshot.cn；国际版 Key 需要改为 api.moonshot.ai"
        ExtraEnv    = @{
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" = "1"
            "API_TIMEOUT_MS" = "600000"
            "ENABLE_TOOL_SEARCH" = "false"
        }
        Models      = @(
            [PSCustomObject]@{ Label = "K2.5"; MainModel = "kimi-k2.5"; FastModel = "kimi-k2.5"; Effort = "medium" ; Desc = "主模型和快速模型均使用 K2.5" }
        )
    }
    "kimi26" = [PSCustomObject]@{
        Name        = "Kimi K2.6 (Kimi Code)"
        BaseUrl     = "https://api.kimi.com/coding/"
        Description = "Kimi K2.6 旗舰编程模型，SWE-Bench 超越 Opus 4.6（Kimi Code 平台）"
        AuthEnvName = "ANTHROPIC_API_KEY"
        Hint        = "Key 前缀 sk-kimi-，从 kimi.com/code/console 获取，与 Moonshot 平台不互通"
        ExtraEnv    = @{
            "ENABLE_TOOL_SEARCH" = "false"
        }
        Models      = @(
            [PSCustomObject]@{ Label = "kimi-for-coding"; MainModel = "kimi-for-coding"; FastModel = "kimi-for-coding"; Effort = "max"; Desc = "K2.6 编程专用，主模型和快速模型均使用 kimi-for-coding" }
        )
    }
    "qwen" = [PSCustomObject]@{
        Name        = "阿里 Qwen (DashScope)"
        BaseUrl     = "https://dashscope.aliyuncs.com/apps/anthropic"
        Description = "Qwen3.6 系列，32K+ 上下文，可用国际版 DashScope"
        Hint        = "中国站 dashscope.aliyuncs.com，国际站 dashscope-intl.aliyuncs.com。Key 前缀 sk-，从百炼控制台获取"
        Models      = @(
            [PSCustomObject]@{ Label = "Qwen3.6-Plus + Qwen3-Coder-Next"; MainModel = "qwen3.6-plus"; FastModel = "qwen3-coder-next"; Effort = "max";    Desc = "推荐：Qwen3.6-Plus 主力 + Qwen3-Coder-Next 快速编码" },
            [PSCustomObject]@{ Label = "Qwen3.6-Flash + Qwen-Turbo";     MainModel = "qwen3.6-flash"; FastModel = "qwen-turbo";        Effort = "medium"; Desc = "速度优先：Qwen3.6-Flash 主力 + Qwen-Turbo 轻量" }
        )
    }
}

function Select-APIProvider {
    Write-Host ""
    Write-Host "请选择 API 提供商："
    Write-Host ""

    $i = 1
    $providerKeys = @($Script:Providers.Keys)
    foreach ($key in $providerKeys) {
        $p = $Script:Providers[$key]
        Write-Host "[$i] $($p.Name)"
        Write-Host "    $($p.Description)"
        Write-Host ""
        $i++
    }

    while ($true) {
        $choice = Read-Host "请输入选项编号"
        $idx = ConvertTo-MenuIndex -Choice $choice -Count $providerKeys.Count
        if ($idx) {
            $selectedKey = $providerKeys[$idx - 1]
            $provider = $Script:Providers[$selectedKey]
            Write-Ok "已选择：$($provider.Name)"
            $hint = Get-ProviderProperty -Provider $provider -PropertyName 'Hint'
            if ($hint) {
                Write-Host "  [提示] $hint" -ForegroundColor DarkYellow
            }
            return [PSCustomObject]@{
                Key      = $selectedKey
                Provider = $provider
            }
        }
        Write-Warn "请输入 1 到 $($providerKeys.Count) 之间的数字。"
    }
}

function Select-ModelConfig {
    param([Parameter(Mandatory = $true)]$Provider)

    Write-Host ""
    Write-Host "请选择 $($Provider.Name) 模型配置："
    Write-Host ""

    for ($i = 0; $i -lt $Provider.Models.Count; $i++) {
        $m = $Provider.Models[$i]
        Write-Host "[$($i + 1)] $($m.Label)"
        Write-Host "    $($m.Desc)"
        Write-Host ""
    }

    while ($true) {
        $choice = Read-Host "请输入选项编号"
        $idx = ConvertTo-MenuIndex -Choice $choice -Count $Provider.Models.Count
        if ($idx) {
            $model = $Provider.Models[$idx - 1]
            Write-Ok "已选择：$($model.Label)"
            return $model
        }
        Write-Warn "请输入 1 到 $($Provider.Models.Count) 之间的数字。"
    }
}
