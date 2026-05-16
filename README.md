# setup_claude_deepseek_v1.ps1

一键在 Windows x64 上搭建 **Claude Code CLI + DeepSeek API** 环境。

## 适用环境

| 条件 | 要求                                        |
|------|-------------------------------------------|
| 操作系统 | Windows 10 / Windows 11 x64               |
| PowerShell | 5.1 或更高版本                                 |
| 磁盘 | 优先使用 电脑D盘，若无D盘，则在 `%USERPROFILE%`即C盘用户目录下 |

## 首次运行命令（推荐）

脚本可以放在任意目录。打开 **PowerShell**，进入脚本所在目录后，优先使用下面这条命令运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek_v1.ps1
```

原因：从 GitHub 下载的 `.ps1` 脚本通常没有数字签名，Windows 可能会给文件加上来自 Internet 的安全标记，PowerShell 默认执行策略会拦截未签名脚本并提示“未对文件进行数字签名”。上面的命令只对本次启动的 PowerShell 进程临时绕过执行策略，不需要管理员权限，也不会永久修改系统策略。

如需使用代理安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek_v1.ps1 -Proxy "http://127.0.0.1:7890"
```

如需完全卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_claude_deepseek_v1.ps1 -Uninstall
```

不要以管理员身份运行本脚本；脚本写入的是当前用户级环境变量，管理员窗口会把配置写到 Administrator 账户下。

## 参数说明

| 参数 | 类型 | 说明 |
|------|------|------|
| `-Proxy` | `string` | HTTP/HTTPS 代理地址，例如 `"http://127.0.0.1:7890"` |
| `-Uninstall` | `switch` | 卸载模式，清理脚本写入的所有内容 |

## 功能详解

### 一键安装流程

执行脚本后按以下顺序自动完成：

1. **创建本地目录结构** — 若 `D:\` 可用则安装到 `D:\ClaudeCodeCLI\`，否则安装到 `%USERPROFILE%\ClaudeCodeCLI\`
2. **修复残留 PATH** — 自动检测并修复旧版本脚本可能写坏的 PATH 条目
3. **检查已有配置** — 若系统已存在 Anthropic 相关环境变量会提示是否覆盖
4. **安装 Node.js** — 自动从 nodejs.org 获取最新 LTS 版本并安装到本地目录，不污染系统
5. **配置 npm** — 将 cache、prefix、registry 全部指向本地目录，独立隔离
6. **安装 Git** — 自动获取 MinGit for Windows x64 并安装到本地目录
7. **安装 Claude Code CLI** — 通过 npm 安装 `@anthropic-ai/claude-code`，含平台原生包，带进度显示
8. **输入 API Key** — 安全输入 DeepSeek API Key（密码框，不回显）
9. **选择模型配置** — 提供两组预设模型

### 模型预设

| 选项 | 主模型 | 快速模型 | Effort |
|------|--------|----------|--------|
| 选项 1 | `deepseek-v4-pro[1m]` | `deepseek-v4-flash` | `max` |
| 选项 2 | `deepseek-v4-flash` | `deepseek-v4-flash` | `medium` |

### 写入的环境变量

脚本将以下 8 个环境变量写入当前 Windows 用户级别：

| 环境变量 | 值 |
|----------|-----|
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` |
| `ANTHROPIC_AUTH_TOKEN` | 你输入的 DeepSeek API Key |
| `ANTHROPIC_MODEL` | 主模型（见模型预设） |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | 主模型 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | 主模型 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 快速模型 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 快速模型 |
| `CLAUDE_CODE_EFFORT_LEVEL` | `max` 或 `medium` |

### 卸载流程

使用 `-Uninstall` 参数时会：
1. 删除所有 8 个托管环境变量
2. 备份当前 PATH 到桌面 `.txt` 文件（防止误删可恢复）
3. 从用户 PATH 中移除所有 `ClaudeCodeCLI` 相关条目
4. 删除整个 `ClaudeCodeCLI` 安装目录

## 限制与注意事项

### 平台限制

- **仅支持 Windows x64** — Node.js、Git、Claude Code 的下载链接均硬编码为 win-x64
- **仅支持 DeepSeek API** — `ANTHROPIC_BASE_URL` 固定指向 `https://api.deepseek.com/anthropic`
- **仅支持 DeepSeek 模型** — 模型选项仅包含 `deepseek-v4-pro[1m]` 和 `deepseek-v4-flash`

### 使用注意

- **不要以管理员身份运行** — 脚本写入用户级环境变量，无需管理员权限；以管理员运行反而会将变量写到 Administrator 账户
- **安装后需重新打开 PowerShell** — 环境变量在新窗口中才生效
- **网络要求** — 需要访问 nodejs.org、github.com、npmjs.org，建议使用代理
- **不支持 ARM64** — 未提供 aaarch64/arm64 的下载方式，不支持 Windows on ARM 设备
- **不适用于其他 Anthropic 兼容 API** — 暂不支持其他模型的API接口，仅支持官方DeepSeek API
- **不会自动更新 Claude Code** — 该.sp1脚本不会自动更新已安装Claude Code，安装完成后如需更新，手动执行 `claude --update` 或在安装目录下重新运行 `npm install -g @anthropic-ai/claude-code`
- **与已安装的 Node.js/Git 共存** — 脚本安装的版本会插入到 PATH 最前面，优先于系统已有版本

### 安全说明

- API Key 通过 PowerShell 安全字符串输入，运行过程中不会明文显示
- 卸载时，会自动备份 PATH 到桌面，文件名格式为 `ClaudeCodeCLI_path_backup_yyyyMMdd_HHmmss.txt`
- 删除操作限制在 `ClaudeCodeCLI` 目录内，不要执行其他的删除操作
