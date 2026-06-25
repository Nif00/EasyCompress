$ErrorActionPreference = "Stop"
# Invoke-WebRequest's progress stream is extremely slow on Windows PowerShell 5.1 and can
# stall the download on some machines; suppressing it makes the one-line install reliable.
$ProgressPreference = "SilentlyContinue"

try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue } catch {}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$AppName = "VideoCompressor"
$LocalAppDataRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
if (-not $LocalAppDataRoot) { $LocalAppDataRoot = Join-Path $env:USERPROFILE "AppData\Local" }
$InstallRoot = Join-Path $LocalAppDataRoot "Programs\$AppName"
$InstalledScript = Join-Path $InstallRoot "VideoCompressor.ps1"
$TempScript = Join-Path $InstallRoot "VideoCompressor.ps1.download"
$BackupScript = Join-Path $InstallRoot "VideoCompressor.ps1.backup"
$ScriptUrl = "https://raw.githubusercontent.com/Nif00/EasyCompress/main/VideoCompressor.ps1"
$NoCacheHeaders = @{
    "Cache-Control" = "no-cache, no-store, must-revalidate"
    "Pragma" = "no-cache"
}
$BackupMade = $false

function Write-InstallerStatus {
    param([string]$Message)
    Write-Host "[VideoCompressor] $Message"
}

function Get-PowerShellExe {
    $pwsh = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Source -and (Test-Path -LiteralPath $pwsh.Source)) {
        return $pwsh.Source
    }

    $powershell = Get-Command "powershell.exe" -ErrorAction SilentlyContinue
    if ($powershell -and $powershell.Source -and (Test-Path -LiteralPath $powershell.Source)) {
        return $powershell.Source
    }

    return "powershell.exe"
}

function ConvertTo-WindowsArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $result = '"'
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
        } elseif ($char -eq '"') {
            $result += ('\' * (($backslashes * 2) + 1))
            $result += '"'
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) {
                $result += ('\' * $backslashes)
                $backslashes = 0
            }
            $result += $char
        }
    }

    if ($backslashes -gt 0) {
        $result += ('\' * ($backslashes * 2))
    }

    $result += '"'
    return $result
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join " "
}

function Invoke-InstalledApp {
    $exe = Get-PowerShellExe
    $argumentList = ConvertTo-ProcessArgumentString -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Sta",
        "-File",
        $InstalledScript
    )
    Write-InstallerStatus "Launching installed app..."
    Start-Process -FilePath $exe -ArgumentList $argumentList
}

function Test-DownloadedScript {
    param([string]$Path)

    $downloaded = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($downloaded.Length -lt 10000) {
        throw "Downloaded script is unexpectedly small."
    }

    $head = Get-Content -LiteralPath $Path -TotalCount 30 -ErrorAction Stop
    if (($head -join "`n") -notmatch "VideoCompressor") {
        throw "Downloaded file does not look like VideoCompressor.ps1."
    }

    $tokens = $null
    $errors = $null
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "Downloaded script has PowerShell parse errors."
    }

    $requiredFunctions = @("Show-CompressorUi", "Register-ContextMenu", "Ensure-FFmpeg")
    foreach ($fn in $requiredFunctions) {
        $fnAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true) | Select-Object -First 1
        if (-not $fnAst) {
            throw "Downloaded script is missing required function '$fn'."
        }
        $statementCount = 0
        if ($fnAst.Body -and $fnAst.Body.EndBlock) {
            $statementCount = @($fnAst.Body.EndBlock.Statements).Count
        }
        if ($statementCount -lt 1) {
            throw "Downloaded function '$fn' has no implementation (stub)."
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }

    $cacheBuster = [DateTime]::UtcNow.Ticks
    $downloadUrl = "$ScriptUrl`?v=$cacheBuster"

    Write-InstallerStatus "Downloading latest script..."
    $iwrParams = @{
        Uri = $downloadUrl
        OutFile = $TempScript
        Headers = $NoCacheHeaders
        TimeoutSec = 60
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $iwrParams.UseBasicParsing = $true
    }
    Invoke-WebRequest @iwrParams

    Test-DownloadedScript -Path $TempScript

    if (Test-Path -LiteralPath $InstalledScript) {
        Copy-Item -LiteralPath $InstalledScript -Destination $BackupScript -Force
        $BackupMade = $true
    }

    Move-Item -LiteralPath $TempScript -Destination $InstalledScript -Force
    $hash = (Get-FileHash -LiteralPath $InstalledScript -Algorithm SHA256).Hash.Substring(0, 12)
    Write-InstallerStatus "Installed to $InstalledScript"
    Write-InstallerStatus "Installed script hash: $hash"
    Invoke-InstalledApp
    if (Test-Path -LiteralPath $BackupScript) {
        Remove-Item -LiteralPath $BackupScript -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "[VideoCompressor] Install/update failed: $($_.Exception.Message)" -ForegroundColor Red

    if (Test-Path -LiteralPath $TempScript) {
        Remove-Item -LiteralPath $TempScript -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $InstalledScript) {
        try {
            Test-DownloadedScript -Path $InstalledScript
        } catch {
            if ($BackupMade -and (Test-Path -LiteralPath $BackupScript)) {
                Copy-Item -LiteralPath $BackupScript -Destination $InstalledScript -Force
            }
        }
    } elseif ($BackupMade -and (Test-Path -LiteralPath $BackupScript)) {
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
