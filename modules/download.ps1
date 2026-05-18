# download.ps1 — 下载 / 解压 / 进度条

function Invoke-DirectDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$What,
        [int]$MaxRetries = 2
    )

    $retry = 0
    while ($retry -le $MaxRetries) {
        if ($retry -gt 0) {
            Write-Warn "$What 下载失败，正在进行第 $retry 次重试..."
            Start-Sleep -Seconds ($retry * 2)
        }

        try {
            if ($retry -eq 0) {
                Write-Info "正在下载 $What"
            }
            else {
                Write-Info "正在下载 $What（重试 $retry/$MaxRetries）"
            }

            $request = [Net.HttpWebRequest]::Create($Uri)
            $request.UserAgent = $Script:UserAgent
            $request.AllowAutoRedirect = $true
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            if (-not [string]::IsNullOrWhiteSpace($Script:Proxy)) {
                $request.Proxy = New-Object Net.WebProxy($Script:Proxy, $true)
            }

            $response = $request.GetResponse()
            try {
                Save-ResponseStreamWithProgress -Response $response -OutFile $OutFile -What $What
            }
            finally {
                $response.Dispose()
            }
            return
        }
        catch [Net.WebException] {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "无响应" }
            if ($statusCode -match "^(401|403|404|410)$") {
                Fail "$What 下载失败（HTTP $statusCode），资源不存在或无权访问。"
            }
            if ($retry -ge $MaxRetries) {
                $detail = "URL: $Uri`nHTTP 状态: $statusCode`n错误: $($_.Exception.Message)"
                Write-Warn "$What 下载失败（已重试 $MaxRetries 次）：$detail"
                Fail $Script:NetworkFailureMessage
            }
        }
        catch {
            if ($_.Exception.Message -notmatch "timeout|timed|connect|network|resolve|refused|unreachable|aborted") {
                Write-Warn "$What 下载失败：URL: $Uri`n$($_.Exception.Message)"
                Fail $Script:NetworkFailureMessage
            }
            if ($retry -ge $MaxRetries) {
                Write-Warn "$What 下载失败（已重试 $MaxRetries 次）：URL: $Uri`n$($_.Exception.Message)"
                Fail $Script:NetworkFailureMessage
            }
        }

        $retry++
    }
}

function Save-ResponseStreamWithProgress {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$What
    )

    $directory = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $totalBytes     = [int64]$Response.ContentLength
    $downloadedBytes = [int64]0
    $buffer          = New-Object byte[] 1048576
    $activity        = "下载进度：$What"
    $source          = $Response.GetResponseStream()
    $target          = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $lastUpdate      = [DateTime]::MinValue
    $lastPercent     = -1
    $updateInterval  = [TimeSpan]::FromMilliseconds(300)

    try {
        while ($true) {
            $read = $source.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }

            $target.Write($buffer, 0, $read)
            $downloadedBytes += $read

            $now = [DateTime]::UtcNow
            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes * 100) / $totalBytes))
            }
            else {
                $percent = -1
            }

            if (($now - $lastUpdate) -ge $updateInterval -or $percent -ne $lastPercent) {
                $lastUpdate  = $now
                $lastPercent = $percent

                if ($totalBytes -gt 0) {
                    $status = "{0:N1} MB / {1:N1} MB" -f ($downloadedBytes / 1MB), ($totalBytes / 1MB)
                    Write-Progress -Activity $activity -Status $status -PercentComplete $percent
                }
                else {
                    $status = "已下载 {0:N1} MB" -f ($downloadedBytes / 1MB)
                    Write-Progress -Activity $activity -Status $status
                }
            }
        }
    }
    finally {
        $target.Dispose()
        $source.Dispose()
        Write-Progress -Activity $activity -Completed
    }
}

function Expand-ZipToCleanDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$What
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $tempDir = Join-Path $Script:DownloadsDir ("extract-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)
        $children = @(Get-ChildItem -LiteralPath $tempDir -Force)
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            $source = $children[0].FullName
        }
        else {
            $source = $tempDir
        }

        Remove-DirectorySafely -Path $Destination
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null

        Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $Destination -Force
        }
    }
    catch {
        Fail "$What 解压失败：$($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
