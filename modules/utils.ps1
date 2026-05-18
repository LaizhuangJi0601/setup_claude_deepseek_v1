# utils.ps1 — 通用工具函数

# ---------- 控制台输出 ----------
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
    if (-not $Script:LogFile) { return }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $Message" | Out-File -LiteralPath $Script:LogFile -Append -Encoding UTF8
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

# ---------- 安全掩码 ----------
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

# ---------- PATH 列表拆分 ----------
function Split-PathList {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return $Value.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

# ---------- 菜单输入解析 ----------
function ConvertTo-MenuIndex {
    param(
        [AllowEmptyString()][string]$Choice,
        [Parameter(Mandatory = $true)][int]$Count
    )

    $idx = 0
    if (-not [int]::TryParse($Choice, [ref]$idx)) {
        return $null
    }
    if ($idx -lt 1 -or $idx -gt $Count) {
        return $null
    }
    return $idx
}

# ---------- 安全删除 ----------
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

# ---------- 命令查找 / 版本检查 ----------
function Find-CommandPath {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        if ($cmd.Path) { return $cmd.Path }
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
        Name    = $CommandName
        Path    = $path
        Version = $version
    }
}

# ---------- SecureString 转换 ----------
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

# ---------- 安全属性访问（兼容 strict mode）----------
function Get-ProviderProperty {
    param(
        [Parameter(Mandatory = $true)]$Provider,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        $Default = $null
    )
    if ($Provider.PSObject.Properties.Name -contains $PropertyName) {
        return $Provider.$PropertyName
    }
    return $Default
}
