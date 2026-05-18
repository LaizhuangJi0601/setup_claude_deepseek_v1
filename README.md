# setup_claude_deepseek

Windows x64 上的 **Claude Code CLI 多模型安装与管理工具**。

它会在当前用户环境下安装独立的 Node.js、npm、MinGit 和 Claude Code，并配置 Anthropic-compatible API 提供商。目前支持 DeepSeek、智谱 GLM/Z.AI、Kimi K2.5、Kimi Code/K2.6 和阿里 Qwen/DashScope。

如果这个项目对你有帮助，欢迎在 GitHub 右上角点一个 Star。

## v2.0.0 更新内容

v2.0.0 是一次结构升级：项目从早期单 DeepSeek 脚本升级为模块化多模型管理工具。

主要变化：

- 单文件脚本拆分为 `setup.ps1` 加 `modules/` 模块目录，后续更容易维护。
- 保留兼容入口 `setup_claude_deepseek.ps1`，用户仍可按旧命令运行。
- 新增交互式主菜单：完整安装、仅配置模型、管理模型、环境检测、卸载和帮助。
- 新增多 provider 管理：添加、切换基座、修改 API Key、修改模型参数、删除配置。
- 支持 DeepSeek、GLM/Z.AI、Kimi K2.5、Kimi Code/K2.6、Qwen/DashScope。
- 新增安装记录 `.claude-code-setup.json`，记录 provider 和模型配置，但不保存 API Key 明文。
- 为每个 provider 保存独立 Key 环境变量，例如 `CC_DEEPSEEK_AUTH`、`CC_KIMI_AUTH`。
- 增强安装日志、卸载日志、PATH 修复、平台包校验和 npm 异常安装清理。

已实测链路：

- DeepSeek：`https://api.deepseek.com/anthropic`，`deepseek-v4-pro[1m]` / `deepseek-v4-flash`
- Kimi K2.5：`https://api.moonshot.cn/anthropic`，`kimi-k2.5`
- 菜单 `[2]` 添加模型、`[3]` 修改 Key / 切换基座、`[4]` 环境检测和卸载清理流程已做过实际验证。

## 适用环境

| 条件 | 要求 |
|------|------|
| 操作系统 | Windows 10 / Windows 11 x64 |
| PowerShell | 5.1 或更高版本 |
| 网络 | 需要访问 nodejs.org、github.com、registry.npmjs.org，以及所选 API 平台 |
| 磁盘 | 默认使用 `D:\ClaudeCodeCLI`，无 D 盘则使用 `%USERPROFILE%\ClaudeCodeCLI` |

不要以管理员身份运行。脚本写入的是当前用户级环境变量；管理员窗口会把配置写到 Administrator 账户下。

## 下载和运行

v2.0.0 不是单文件脚本。请下载整个项目目录，并保持以下结构：

```text
setup_claude_deepseek/
  setup_claude_deepseek.ps1
  setup.ps1
  modules/
    *.ps1
```

打开 PowerShell，进入项目目录后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1
```

也可以直接运行内部入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

从 GitHub 下载的 `.ps1` 文件通常没有数字签名，Windows 可能会加上来自 Internet 的安全标记。上面的命令只对本次 PowerShell 进程临时绕过执行策略，不需要管理员权限，也不会永久修改系统策略。

## 常用命令

指定安装目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -InstallDir "E:\ClaudeCodeCLI"
```

使用代理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Proxy "http://127.0.0.1:7890"
```

直接安装并配置指定 provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Model deepseek
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Model kimi/kimi-k2.5
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Model kimi26/kimi-for-coding
```

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Uninstall
```

如果安装时用了自定义目录，卸载时也传入相同目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek.ps1 -Uninstall -InstallDir "E:\ClaudeCodeCLI"
```

## 参数说明

| 参数 | 类型 | 说明 |
|------|------|------|
| `-InstallDir` | `string` | 自定义安装根目录，例如 `"E:\ClaudeCodeCLI"` |
| `-Proxy` | `string` | HTTP/HTTPS 代理地址，例如 `"http://127.0.0.1:7890"` |
| `-Uninstall` | `switch` | 卸载模式，清理脚本写入的环境变量、PATH 条目和安装目录 |
| `-Model` | `string` | 跳过菜单直接安装并配置模型，格式为 `<provider>` 或 `<provider>/<model>` |

## 支持的 provider

| Key | 平台 | 默认地址 | 认证变量 |
|-----|------|----------|----------|
| `deepseek` | DeepSeek | `https://api.deepseek.com/anthropic` | `ANTHROPIC_AUTH_TOKEN` |
| `glm` | 智谱 GLM / Z.AI | `https://api.z.ai/api/anthropic` | `ANTHROPIC_AUTH_TOKEN` |
| `kimi` | Kimi K2.5 / Moonshot 中文开放平台 | `https://api.moonshot.cn/anthropic` | `ANTHROPIC_AUTH_TOKEN` |
| `kimi26` | Kimi Code / Kimi K2.6 | `https://api.kimi.com/coding/` | `ANTHROPIC_API_KEY` |
| `qwen` | 阿里 Qwen / DashScope | `https://dashscope.aliyuncs.com/apps/anthropic` | `ANTHROPIC_AUTH_TOKEN` |

Kimi 有两个不同平台，Key 不互通：

- `kimi` 对应 Kimi K2.5 / Moonshot 开放平台。
- `kimi26` 对应 Kimi Code / Kimi K2.6 平台，通常需要从 Kimi Code 控制台获取 `sk-kimi-` 前缀的 Key。
- 如果你使用的是 Moonshot 国际版 Key，需要把 `modules/providers.ps1` 里的 `kimi` 地址改为 `https://api.moonshot.ai/anthropic`。

## 菜单功能

直接运行脚本会进入主菜单：

```text
[1] 完整安装 - 安装 Node/Git/Claude Code + 配置模型
[2] 仅配置模型 - 先检测环境，通过后配置模型
[3] 管理已配置模型 - 切换基座 / 改 Key / 改模型 / 删除
[4] 环境检测 - 显示版本、PATH、环境变量、已配置模型
[5] 卸载 - 自动检测安装目录，确认后清理
[6] 帮助 - 快速帮助 + 可选打开浏览器
[Q] 退出
```

## 完整安装流程

执行完整安装后，脚本会按顺序完成：

1. 创建本地目录结构
2. 修复旧版本可能写坏的 PATH 条目
3. 检查已有 Claude/Anthropic 相关环境变量并确认是否覆盖
4. 下载并安装 Node.js LTS
5. 配置 npm prefix/cache/registry
6. 下载并安装 MinGit
7. 安装 `@anthropic-ai/claude-code`
8. 选择 API 提供商和模型预设
9. 输入 API Key
10. 使用所选模型轻量验证 API Key
11. 写入用户级环境变量
12. 保存 `.claude-code-setup.json` 安装记录
13. 输出安装总结

完整安装流程每次配置一个 API 提供商。需要添加更多提供商时，安装完成后重新运行脚本并选择 `[2] 仅配置模型`。

## 写入的环境变量

当前版本托管以下用户级环境变量：

| 环境变量 | 说明 |
|----------|------|
| `ANTHROPIC_BASE_URL` | 当前基座 provider 的 Anthropic-compatible API 地址 |
| `ANTHROPIC_AUTH_TOKEN` | 大多数 provider 使用的认证变量 |
| `ANTHROPIC_API_KEY` | 部分 provider 使用的认证变量，例如 Kimi Code |
| `ANTHROPIC_MODEL` | 当前主模型 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | 当前主模型 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | 当前主模型 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 当前快速模型 |
| `ANTHROPIC_SMALL_FAST_MODEL` | 当前快速模型 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 子任务/快速模型 |
| `CLAUDE_CODE_EFFORT_LEVEL` | 推理 effort 档位 |
| `API_TIMEOUT_MS` | provider 需要时写入的超时设置 |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | provider 需要时关闭非必要流量 |
| `ENABLE_TOOL_SEARCH` | provider 需要时控制工具搜索 |

脚本还会为每个已配置 provider 保存专属 Key，例如 `CC_DEEPSEEK_AUTH`、`CC_KIMI_AUTH`、`CC_KIMI26_AUTH`。切换基座时会从这些专属变量恢复对应 Key，并清理旧 provider 残留的通用环境变量。

API Key 明文不会写入 `.claude-code-setup.json`，日志中也会打码显示。

## 安装记录和日志

安装目录下会生成：

```text
.claude-code-setup.json
logs\setup_yyyyMMdd_HHmmss.log
logs\config_yyyyMMdd_HHmmss.log
```

日志会记录安装目录、代理设置、组件版本、模型配置和失败原因。API Key 会打码，不会明文写入日志。

## 卸载流程

使用 `-Uninstall` 或菜单卸载时会：

1. 读取 `.claude-code-setup.json`
2. 显示安装摘要
3. 检测 PATH 中可能存在的真实安装目录
4. 检测运行中的 Claude Code 进程
5. 对非默认或无记录的自定义目录进行二次路径确认
6. 删除托管环境变量和 provider 专属 Key
7. 备份当前用户 PATH 到桌面
8. 从用户 PATH 移除安装目录相关条目
9. 删除安装目录
10. 在 `%TEMP%\ClaudeCodeCLI_uninstall_logs\` 生成卸载日志

## 注意事项

- 仅支持 Windows x64；不支持 Windows on ARM。
- 安装后建议关闭并重新打开 PowerShell，再运行 `claude`。
- 如果 npm 官方 registry 很慢，脚本会提示是否切换到 npmmirror。
- 如果网络受限，请使用 `-Proxy` 参数。
- 当前脚本不会自动更新已安装的 Claude Code；需要更新时可重新运行完整安装，或在安装目录的 npm 环境下手动更新。
- 修改 provider 端点或模型名时，请先确认对应平台的官方文档和 Key 类型。
