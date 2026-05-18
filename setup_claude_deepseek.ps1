# 兼容入口：保留旧版 README 中的运行命令，实际逻辑在 setup.ps1。
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Proxy,
    [string]$InstallDir,
    [string]$Model
)

$entry = Join-Path $PSScriptRoot "setup.ps1"
if (-not (Test-Path -LiteralPath $entry)) {
    throw "未找到入口脚本：$entry"
}

& $entry @PSBoundParameters
exit $LASTEXITCODE
