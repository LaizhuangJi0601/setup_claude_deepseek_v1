# record.ps1 — 安装记录文件管理（.claude-code-setup.json）

function Get-RecordFilePath {
    Join-Path $Script:RootDir $Script:RecordFileName
}

function Save-InstallRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ActiveProvider,
        [Parameter(Mandatory = $true)]$Components,
        [Parameter(Mandatory = $true)]$Providers
    )

    $record = [PSCustomObject]@{
        installDir     = $Script:RootDir
        installTime    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        scriptVersion  = $Script:ScriptVersion
        activeProvider = $ActiveProvider
        components     = $Components
        envVars        = @($Script:ManagedEnvVars)
        providers      = [PSCustomObject]$Providers
    }
    $json = $record | ConvertTo-Json -Depth 4
    $json | Out-File -LiteralPath (Get-RecordFilePath) -Encoding UTF8
    Write-Log "安装记录已保存：$(Get-RecordFilePath)"
}

function Read-InstallRecord {
    $path = Get-RecordFilePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    try { return $content | ConvertFrom-Json }
    catch { return $null }
}

function Merge-ProviderConfigs {
    param(
        $ExistingProviders,
        $NewProviders
    )

    $merged = [ordered]@{}
    foreach ($source in @($ExistingProviders, $NewProviders)) {
        if (-not $source) { continue }

        if ($source -is [System.Collections.IDictionary]) {
            foreach ($key in $source.Keys) {
                $merged[$key] = $source[$key]
            }
            continue
        }

        foreach ($property in $source.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }
    return $merged
}

function Update-InstallRecord {
    param(
        [string]$ActiveProvider,
        $Components,
        $Providers
    )

    $record = Read-InstallRecord
    if (-not $record) {
        $record = [PSCustomObject]@{
            installDir     = $Script:RootDir
            installTime    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            scriptVersion  = $Script:ScriptVersion
            activeProvider = ""
            components     = [PSCustomObject]@{}
            envVars        = @($Script:ManagedEnvVars)
            providers      = [PSCustomObject]@{}
        }
    }

    if ($PSBoundParameters.ContainsKey("ActiveProvider")) {
        $record | Add-Member -MemberType NoteProperty -Name "activeProvider" -Value $ActiveProvider -Force
    }
    if ($Components) {
        $record | Add-Member -MemberType NoteProperty -Name "components" -Value ([PSCustomObject]$Components) -Force
    }
    if ($Providers) {
        $record | Add-Member -MemberType NoteProperty -Name "providers" -Value ([PSCustomObject]$Providers) -Force
    }

    $json = $record | ConvertTo-Json -Depth 4
    $json | Out-File -LiteralPath (Get-RecordFilePath) -Encoding UTF8
    Write-Log "安装记录已更新。"
}

function Clear-InstallRecord {
    $path = Get-RecordFilePath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Log "安装记录已删除。"
    }
}

function Get-ConfiguredProviders {
    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) { return @{} }
    $result = @{}
    foreach ($kv in $record.providers.PSObject.Properties) {
        $result[$kv.Name] = $kv.Value
    }
    return $result
}

function Add-ProviderToRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Config
    )

    $record = Read-InstallRecord
    if (-not $record) {
        # 记录文件不存在，创建新记录
        $providersObj = [PSCustomObject]@{ $Key = $Config }
        $record = [PSCustomObject]@{
            installDir     = $Script:RootDir
            installTime    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            scriptVersion  = $Script:ScriptVersion
            activeProvider = $Key
            components     = [PSCustomObject]@{}
            envVars        = @($Script:ManagedEnvVars)
            providers      = $providersObj
        }
    }
    else {
        # 合并已有 providers
        $providersHash = [ordered]@{}
        if ($record.providers) {
            foreach ($kv in $record.providers.PSObject.Properties) {
                $providersHash[$kv.Name] = $kv.Value
            }
        }
        $providersHash[$Key] = $Config
        $providersObj = [PSCustomObject]$providersHash
        $record | Add-Member -MemberType NoteProperty -Name "providers" -Value $providersObj -Force
    }

    $json = $record | ConvertTo-Json -Depth 4
    $json | Out-File -LiteralPath (Get-RecordFilePath) -Encoding UTF8
    Write-Log "已将 $Key 写入安装记录。"
}

function Remove-ProviderFromRecord {
    param([Parameter(Mandatory = $true)][string]$Key)

    $record = Read-InstallRecord
    if (-not $record -or -not $record.providers) { return }

    $providersHash = @{}
    foreach ($kv in $record.providers.PSObject.Properties) {
        if ($kv.Name -ne $Key) {
            $providersHash[$kv.Name] = $kv.Value
        }
    }

    if ($record.activeProvider -eq $Key) {
        $remaining = @($providersHash.Keys)
        $newActive = if ($remaining.Count -gt 0) { $remaining[0] } else { "" }
        Update-InstallRecord -Providers $providersHash -ActiveProvider $newActive
    }
    else {
        Update-InstallRecord -Providers $providersHash
    }
}
