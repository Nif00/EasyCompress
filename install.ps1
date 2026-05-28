$ErrorActionPreference = "Stop"

$AppName = "VideoCompressor"
$InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$InstalledScript = Join-Path $InstallRoot "VideoCompressor.ps1"
$TempScript = Join-Path $InstallRoot "VideoCompressor.ps1.download"
$BackupScript = Join-Path $InstallRoot "VideoCompressor.ps1.backup"
$ScriptUrl = "https://raw.githubusercontent.com/Nif00/EasyCompress/main/VideoCompressor.ps1"
$NoCacheHeaders = @{
    "Cache-Control" = "no-cache, no-store, must-revalidate"
    "Pragma" = "no-cache"
}

function Write-InstallerStatus {
    param([string]$Message)
    Write-Host "[VideoCompressor] $Message"
}

function Get-PowerShellExe {
    $pwsh = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    $powershell = Get-Command "powershell.exe" -ErrorAction Stop
    return $powershell.Source
}

function Invoke-InstalledApp {
    $exe = Get-PowerShellExe
    Write-InstallerStatus "Launching installed app..."
    Start-Process -FilePath $exe -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$InstalledScript`""
    )
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }

    $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $downloadUrl = "$ScriptUrl`?v=$cacheBuster"

    Write-InstallerStatus "Downloading latest script..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $TempScript -UseBasicParsing -Headers $NoCacheHeaders

    $downloaded = Get-Item -LiteralPath $TempScript
    if ($downloaded.Length -lt 10000) {
        throw "Downloaded script is unexpectedly small."
    }

    $head = Get-Content -LiteralPath $TempScript -TotalCount 20 -ErrorAction Stop
    if (($head -join "`n") -notmatch "VideoCompressor") {
        throw "Downloaded file does not look like VideoCompressor.ps1."
    }

    if (Test-Path -LiteralPath $InstalledScript) {
        Copy-Item -LiteralPath $InstalledScript -Destination $BackupScript -Force
    }

    Move-Item -LiteralPath $TempScript -Destination $InstalledScript -Force
    $hash = (Get-FileHash -LiteralPath $InstalledScript -Algorithm SHA256).Hash.Substring(0, 12)
    Write-InstallerStatus "Installed to $InstalledScript"
    Write-InstallerStatus "Installed script hash: $hash"
    Invoke-InstalledApp
} catch {
    Write-Host "[VideoCompressor] Install/update failed: $($_.Exception.Message)" -ForegroundColor Red

    if (Test-Path -LiteralPath $TempScript) {
        Remove-Item -LiteralPath $TempScript -Force -ErrorAction SilentlyContinue
    }

    if ((-not (Test-Path -LiteralPath $InstalledScript)) -and (Test-Path -LiteralPath $BackupScript)) {
        Copy-Item -LiteralPath $BackupScript -Destination $InstalledScript -Force
    }

    if (Test-Path -LiteralPath $InstalledScript) {
        Write-InstallerStatus "Starting existing installed copy instead."
        Invoke-InstalledApp
    } else {
        Write-Host "[VideoCompressor] No installed copy is available to launch." -ForegroundColor Red
        exit 1
    }
}
