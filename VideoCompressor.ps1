param(
    [Parameter(Position = 0)]
    [string]$InputFile,

    [switch]$Register,
    [switch]$Unregister,
    [switch]$InstallFFmpeg,
    [switch]$Update
)

$ErrorActionPreference = "Stop"
# Invoke-WebRequest's progress stream is extremely slow on Windows PowerShell 5.1 and
# can stall downloads on some machines; suppressing it makes the in-app updater reliable.
$ProgressPreference = "SilentlyContinue"
$ScriptPath = $PSCommandPath
$TempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LocalAppDataRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
if (-not $LocalAppDataRoot) { $LocalAppDataRoot = Join-Path $env:USERPROFILE "AppData\Local" }
$AppName = "VideoCompressor"
$InstallRoot = Join-Path $LocalAppDataRoot "Programs\$AppName"
$InstalledScript = Join-Path $InstallRoot "VideoCompressor.ps1"
$ScriptUrl = "https://raw.githubusercontent.com/Nif00/EasyCompress/main/VideoCompressor.ps1"
$NoCacheHeaders = @{
    "Cache-Control" = "no-cache, no-store, must-revalidate"
    "Pragma" = "no-cache"
}
$LogFile = Join-Path $TempRoot "VideoCompressor-debug.log"
$ContextMenuKey = "HKCU\Software\Classes\*\shell\CompressVideo"
$VideoContextMenuKey = "HKCU\Software\Classes\SystemFileAssociations\video\shell\CompressVideo"
$ContextMenuSubKey = "Software\Classes\*\shell\CompressVideo"
$VideoContextMenuSubKey = "Software\Classes\SystemFileAssociations\video\shell\CompressVideo"
$SettingsContextMenuSubKey = "Software\Classes\*\shell\EasyCompressSettings"
$VideoSettingsContextMenuSubKey = "Software\Classes\SystemFileAssociations\video\shell\EasyCompressSettings"
$LegacyContextMenuKeys = @(
    "HKCR\*\shell\CompressVideo",
    "HKCR\SystemFileAssociations\video\shell\CompressVideo"
)
$LegacyContextMenuSubKeys = @(
    "*\shell\CompressVideo",
    "SystemFileAssociations\video\shell\CompressVideo",
    "*\shell\EasyCompressSettings",
    "SystemFileAssociations\video\shell\EasyCompressSettings"
)
$script:ReadinessCache = $null
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8 -ErrorAction Stop
    } catch {
        # Logging is best-effort. With $ErrorActionPreference = 'Stop', a locked log file
        # (antivirus scan, a concurrent compress run) would otherwise crash the whole app.
    }
}

function Write-LogFileTail {
    param(
        [string]$Path,
        [string]$Label,
        [int]$Lines = 80
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "$Label missing: $Path"
        return
    }

    Write-Log "$Label path: $Path"
    Write-Log "$Label tail:"
    try {
        Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop | ForEach-Object {
            Write-Log "  $_"
        }
    } catch {
        Write-Log "$Label read failed: $($_.Exception.Message)"
    }
}

function Write-DebugEnvironment {
    Write-Log "Script path: $ScriptPath"
    Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Log "User: $env:USERNAME"
    Write-Log "User profile: $env:USERPROFILE"
    Write-Log "LocalAppData: $LocalAppDataRoot"
    Write-Log "Temp: $TempRoot"
    Write-Log "Current culture: $([System.Globalization.CultureInfo]::CurrentCulture.Name)"
    Write-Log "Current UI culture: $([System.Globalization.CultureInfo]::CurrentUICulture.Name)"
    Write-Log "Is admin: $(Test-IsAdministrator)"
    Write-Log "Log file: $LogFile"
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

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath,
        [hashtable]$ControlState
    )

    $argumentString = ConvertTo-ProcessArgumentString -Arguments $Arguments
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $process = $null
    $cancelled = $false

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $argumentString
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw "The process did not start."
        }

        if ($ControlState) {
            $ControlState.Process = $process
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        while (-not $process.WaitForExit(200)) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($ControlState -and $ControlState.Cancelled -and -not $cancelled) {
                $cancelled = $true
                Write-Log "Cancellation requested; terminating FFmpeg process $($process.Id)."
                try {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                } catch {
                    Write-Log "Failed to kill FFmpeg process: $($_.Exception.Message)"
                }
            }
        }

        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()

        [System.IO.File]::WriteAllText($StdOutPath, [string]$stdoutTask.Result, $encoding)
        [System.IO.File]::WriteAllText($StdErrPath, [string]$stderrTask.Result, $encoding)

        return [pscustomobject]@{
            Id = $process.Id
            ExitCode = [int]$process.ExitCode
            Arguments = $argumentString
            Cancelled = $cancelled
        }
    } finally {
        if ($ControlState) {
            $ControlState.Process = $null
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Test-CompletedFfmpegOutput {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath
    )

    try {
        $output = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
        if ($output.Length -le 0) {
            Write-Log "Output fallback check failed: output is empty."
            return $false
        }

        if (-not (Test-Path -LiteralPath $StdErrPath)) {
            Write-Log "Output fallback check failed: FFmpeg stderr log missing."
            return $false
        }

        $tail = Get-Content -LiteralPath $StdErrPath -Tail 160 -ErrorAction Stop
        if (($tail -match "Lsize=") -or ($tail -match "muxing overhead")) {
            Write-Log "Output fallback check passed. Output size: $($output.Length)"
            return $true
        }

        Write-Log "Output fallback check failed: FFmpeg completion markers missing."
        return $false
    } catch {
        Write-Log "Output fallback check exception: $($_.Exception.Message)"
        return $false
    }
}

function Set-OutputTimestamps {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $originalFile = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
            $newFile = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
            $newFile.CreationTime = $originalFile.CreationTime
            $newFile.LastWriteTime = $originalFile.LastWriteTime
            Write-Log "Output timestamps copied from source on attempt $attempt."
            return $newFile
        } catch {
            $lastError = $_.Exception.Message
            Write-Log "Timestamp copy attempt $attempt failed: $lastError"
            Start-Sleep -Milliseconds 250
        }
    }

    Write-Log "Could not copy timestamps to output file after retries. $lastError"
    # Copying timestamps is a nicety, not a requirement. A briefly locked output file
    # (antivirus, Explorer thumbnail) must not turn a successful compression into a failure.
    return (Get-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    param([string[]]$Arguments)

    $argumentList = ConvertTo-ProcessArgumentString -Arguments (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta", "-File", $ScriptPath) + $Arguments)
    try {
        Start-Process -FilePath (Get-PowerShellExe) -ArgumentList $argumentList -Verb RunAs
        exit
    } catch {
        throw "Elevation was declined or is unavailable. Run the action again as Administrator, or accept the UAC prompt."
    }
}

function Test-ExecutableInPath {
    param([string]$Name)

    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-DirectoryToUserPath {
    param([string]$Directory)

    Write-Log "Add-DirectoryToUserPath requested: $Directory"

    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) {
        Write-Log "PATH add skipped because directory is missing."
        return
    }

    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathParts = @()
    if ($currentUserPath) {
        $pathParts = $currentUserPath -split ";" | Where-Object { $_ }
    }

    $alreadyPresent = $pathParts | Where-Object {
        [string]::Equals($_.TrimEnd([char]'\'), $Directory.TrimEnd([char]'\'), [StringComparison]::OrdinalIgnoreCase)
    }

    if ($alreadyPresent) {
        Write-Log "Directory already present in user PATH."
        $newPath = $currentUserPath
    } else {
        $newPath = (@($pathParts) + $Directory) -join ";"
        try {
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            Write-Log "Added directory to user PATH."
        } catch {
            Write-Log "Could not persist user PATH (likely too long): $($_.Exception.Message). FFmpeg is still discoverable via direct candidates in this process."
        }
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $env:Path = @($machinePath, $newPath) -join ";"
}

function Find-Executable {
    param([string]$Name)

    Write-Log "Finding executable: $Name"
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        $sourcePath = [System.IO.Path]::GetFullPath($command.Source)
        Write-Log "Found via PATH: $sourcePath"
        return $sourcePath
    }

    $directCandidates = @(
        "$InstallRoot\ffmpeg\bin\$Name",
        "$LocalAppDataRoot\Microsoft\WinGet\Links\$Name",
        "$env:ProgramFiles\ffmpeg\bin\$Name",
        "${env:ProgramFiles(x86)}\ffmpeg\bin\$Name",
        "$LocalAppDataRoot\Programs\ffmpeg\bin\$Name",
        "$LocalAppDataRoot\Programs\FFmpeg\bin\$Name",
        "$env:ProgramData\chocolatey\bin\$Name",
        "$env:USERPROFILE\scoop\shims\$Name",
        "$env:ProgramData\scoop\shims\$Name"
    ) | Where-Object { $_ }

    foreach ($candidate in $directCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $candidatePath = [System.IO.Path]::GetFullPath($candidate)
            Write-Log "Found direct candidate: $candidatePath"
            return $candidatePath
        }
    }

    $wingetPackages = "$LocalAppDataRoot\Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetPackages) {
        $packageRoots = Get-ChildItem -LiteralPath $wingetPackages -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "FFmpeg|Gyan" }

        foreach ($packageRoot in $packageRoots) {
            $knownMatches = @(
                Join-Path $packageRoot.FullName "ffmpeg-*\bin\$Name",
                Join-Path $packageRoot.FullName "bin\$Name",
                Join-Path $packageRoot.FullName "$Name"
            )

            foreach ($pattern in $knownMatches) {
                $match = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($match -and (Test-Path -LiteralPath $match.FullName)) {
                    $matchPath = [System.IO.Path]::GetFullPath($match.FullName)
                    Write-Log "Found WinGet package candidate: $matchPath"
                    return $matchPath
                }
            }
        }
    }

    Write-Log "Executable not found: $Name"
    return $null
}

function Ensure-FFmpeg {
    Add-Type -AssemblyName System.Windows.Forms

    Write-Log "Ensuring FFmpeg availability."
    $ffmpeg = Find-Executable "ffmpeg.exe"
    $ffprobe = Find-Executable "ffprobe.exe"

    if ($ffmpeg -and $ffprobe) {
        Write-Log "FFmpeg ready: $ffmpeg"
        Write-Log "FFprobe ready: $ffprobe"
        Add-DirectoryToUserPath -Directory (Split-Path -Parent $ffmpeg)
        return @{
            FFmpeg = $ffmpeg
            FFprobe = $ffprobe
        }
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "FFmpeg is needed to compress videos. Download it now? A copy is installed just for you and no administrator rights are required.",
        "FFmpeg Required",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Log "User declined FFmpeg install."
        throw "FFmpeg is required to compress videos."
    }

    # The compress GUI always uses the portable, per-user download here: it needs no admin,
    # no winget, and cannot land in the wrong profile hive. (The setup menu still offers
    # winget for people who prefer a managed install.)
    $binDir = Install-FFmpegPortable
    Add-DirectoryToUserPath -Directory $binDir

    $ffmpeg = Find-Executable "ffmpeg.exe"
    $ffprobe = Find-Executable "ffprobe.exe"
    if (-not $ffmpeg -or -not $ffprobe) {
        Write-Log "FFmpeg install completed but executables were not found. ffmpeg='$ffmpeg' ffprobe='$ffprobe'"
        throw "FFmpeg installation finished, but ffmpeg.exe or ffprobe.exe could not be found. Restart PowerShell or install FFmpeg manually."
    }

    Write-Log "FFmpeg installed/found after install: $ffmpeg"
    Write-Log "FFprobe installed/found after install: $ffprobe"
    Add-DirectoryToUserPath -Directory (Split-Path -Parent $ffmpeg)
    return @{
        FFmpeg = $ffmpeg
        FFprobe = $ffprobe
    }
}

function Get-FFmpegStatus {
    $ffmpegInPath = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
    $ffprobeInPath = Get-Command "ffprobe.exe" -ErrorAction SilentlyContinue
    $ffmpegFound = if ($ffmpegInPath) { $ffmpegInPath.Source } else { Find-Executable "ffmpeg.exe" }
    $ffprobeFound = if ($ffprobeInPath) { $ffprobeInPath.Source } else { Find-Executable "ffprobe.exe" }

    return [pscustomobject]@{
        FFmpegInPath = [bool]$ffmpegInPath
        FFprobeInPath = [bool]$ffprobeInPath
        FFmpegPath = $ffmpegFound
        FFprobePath = $ffprobeFound
        Ready = [bool]($ffmpegInPath -and $ffprobeInPath)
        Detected = [bool]($ffmpegFound -and $ffprobeFound)
    }
}

function Install-FFmpegWithWinget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget.exe was not found. Install FFmpeg manually from https://ffmpeg.org/download.html and run this script again."
    }

    Write-Log "Installing FFmpeg with winget."
    $wingetArguments = ConvertTo-ProcessArgumentString -Arguments @(
        "install",
        "--id", "Gyan.FFmpeg",
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    $process = Start-Process -FilePath $winget.Source -ArgumentList $wingetArguments -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "winget failed to install FFmpeg. Exit code: $($process.ExitCode)"
    }
}

function Install-FFmpegPortable {
    # Downloads a self-contained FFmpeg build into the app's own folder, just for the current
    # user. No admin rights, no winget, and it can never land in another account's profile
    # hive (the failure mode when winget runs under a separate admin account). Returns the
    # bin directory containing ffmpeg.exe / ffprobe.exe.
    $ffmpegRoot = Join-Path $InstallRoot "ffmpeg"
    $binDir = Join-Path $ffmpegRoot "bin"

    if ((Test-Path -LiteralPath (Join-Path $binDir "ffmpeg.exe")) -and
        (Test-Path -LiteralPath (Join-Path $binDir "ffprobe.exe"))) {
        Write-Log "Portable FFmpeg already present at $binDir"
        return $binDir
    }

    $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    $runId = [Guid]::NewGuid().ToString("N")
    $zipPath = Join-Path $TempRoot "EasyCompress-ffmpeg-$runId.zip"
    $extractDir = Join-Path $TempRoot "EasyCompress-ffmpeg-$runId"

    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}
        Write-Log "Downloading portable FFmpeg from $zipUrl"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -Headers $NoCacheHeaders -TimeoutSec 600

        $zipItem = Get-Item -LiteralPath $zipPath -ErrorAction Stop
        if ($zipItem.Length -lt 1MB) {
            throw "The downloaded FFmpeg archive is unexpectedly small ($($zipItem.Length) bytes)."
        }

        Write-Log "Extracting portable FFmpeg to $extractDir"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $sourceFfmpeg = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "ffmpeg.exe" -ErrorAction Stop |
            Select-Object -First 1
        if (-not $sourceFfmpeg) {
            throw "ffmpeg.exe was not found inside the downloaded archive."
        }
        $sourceBin = Split-Path -Parent $sourceFfmpeg.FullName

        if (Test-Path -LiteralPath $ffmpegRoot) {
            try {
                Remove-Item -LiteralPath $ffmpegRoot -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Log "First remove attempt failed, retrying: $($_.Exception.Message)"
                Start-Sleep -Milliseconds 500
                Remove-Item -LiteralPath $ffmpegRoot -Recurse -Force -ErrorAction Stop
            }
        }
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null

        foreach ($exe in @("ffmpeg.exe", "ffprobe.exe")) {
            $source = Join-Path $sourceBin $exe
            if (-not (Test-Path -LiteralPath $source)) {
                throw "$exe was not found inside the downloaded archive."
            }
            Copy-Item -LiteralPath $source -Destination (Join-Path $binDir $exe) -Force
        }

        Write-Log "Portable FFmpeg installed to $binDir"
        return $binDir
    } finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Register-ContextMenu {
    $powerShellExe = Get-PowerShellExe
    $compressCommand = ((@($powerShellExe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta", "-WindowStyle", "Hidden", "-File", $ScriptPath) | ForEach-Object { ConvertTo-WindowsArgument $_ }) + '"%1"') -join " "
    $settingsCommand = ConvertTo-ProcessArgumentString -Arguments @($powerShellExe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta", "-WindowStyle", "Hidden", "-File", $ScriptPath)
    $settingsIcon = "%SystemRoot%\ImmersiveControlPanel\SystemSettings.exe"

    foreach ($subKey in @($ContextMenuSubKey, $VideoContextMenuSubKey)) {
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
            $key.SetValue("MUIVerb", "Compress Video", [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue("Icon", "imageres.dll,77", [Microsoft.Win32.RegistryValueKind]::String)
            $key.Close()

            $commandKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$subKey\command")
            $commandKey.SetValue("", $compressCommand, [Microsoft.Win32.RegistryValueKind]::String)
            $commandKey.Close()
        } catch {
            throw
        }
    }

    foreach ($subKey in @($SettingsContextMenuSubKey, $VideoSettingsContextMenuSubKey)) {
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
            $key.SetValue("MUIVerb", "EasyCompress Settings", [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue("Icon", $settingsIcon, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            $key.SetValue("Position", "Bottom", [Microsoft.Win32.RegistryValueKind]::String)
            $key.Close()

            $commandKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$subKey\command")
            $commandKey.SetValue("", $settingsCommand, [Microsoft.Win32.RegistryValueKind]::String)
            $commandKey.Close()
        } catch {
            throw
        }
    }

    Write-Host "Context menu registered for the current user." -ForegroundColor Green
    Write-Host "Right-click a video file and choose 'Compress Video' or 'EasyCompress Settings'."
}

function Unregister-ContextMenu {
    foreach ($subKey in @($ContextMenuSubKey, $VideoContextMenuSubKey, $SettingsContextMenuSubKey, $VideoSettingsContextMenuSubKey)) {
        try {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey, $false)
        } catch {
            throw
        }
    }

    if (Test-IsAdministrator) {
        foreach ($subKey in $LegacyContextMenuSubKeys) {
            try {
                [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKey, $false)
            } catch {
                throw
            }
        }
    }

    Write-Host "Context menu removed for the current user." -ForegroundColor Green
    if (-not (Test-IsAdministrator)) {
        Write-Host "Run this command as Administrator only if you need to remove entries created by the older split scripts." -ForegroundColor Yellow
    }
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

function Start-UpdatedScript {
    param([string]$Path)

    $powerShellExe = Get-PowerShellExe
    $argumentList = ConvertTo-ProcessArgumentString -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Sta",
        "-File",
        $Path
    )
    Start-Process -FilePath $powerShellExe -ArgumentList $argumentList
}

function Update-EasyCompressFromGithub {
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }

    $targetScript = if (Test-Path -LiteralPath $InstalledScript) { $InstalledScript } else { Join-Path $InstallRoot "VideoCompressor.ps1" }
    $tempScript = Join-Path $InstallRoot "VideoCompressor.ps1.download"
    $backupScript = Join-Path $InstallRoot "VideoCompressor.ps1.backup"
    $backupMade = $false

    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}
        $cacheBuster = [DateTime]::UtcNow.Ticks
        $downloadUrl = "$ScriptUrl`?v=$cacheBuster"

        Write-Host "Downloading latest EasyCompress..." -ForegroundColor Cyan
        Write-Log "Updating EasyCompress from $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempScript -UseBasicParsing -Headers $NoCacheHeaders -TimeoutSec 60
        Test-DownloadedScript -Path $tempScript

        if (Test-Path -LiteralPath $targetScript) {
            Copy-Item -LiteralPath $targetScript -Destination $backupScript -Force
            $backupMade = $true
        }

        Move-Item -LiteralPath $tempScript -Destination $targetScript -Force
        $hash = (Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash.Substring(0, 12)
        Write-Log "Updated EasyCompress at $targetScript. Hash: $hash"
        Write-Host "Updated EasyCompress." -ForegroundColor Green
        Write-Host "Script hash: $hash"
        Write-Host "Restarting updated setup menu..."
        if (Test-Path -LiteralPath $backupScript) {
            Remove-Item -LiteralPath $backupScript -Force -ErrorAction SilentlyContinue
        }
        Start-UpdatedScript -Path $targetScript
        exit
    } catch {
        Write-Log "Update failed: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        }

        if ($backupMade -and (Test-Path -LiteralPath $backupScript)) {
            Copy-Item -LiteralPath $backupScript -Destination $targetScript -Force
            Write-Log "Restored backup after failed update."
        }

        throw "Update failed: $($_.Exception.Message)"
    }
}

function Test-ContextMenuRegistered {
    $compressKey = $null
    $settingsKey = $null
    try {
        $compressKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$ContextMenuSubKey\command", $false)
        $settingsKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$SettingsContextMenuSubKey\command", $false)
        if (-not $compressKey -or -not $settingsKey) {
            return $false
        }

        $compressValue = [string]$compressKey.GetValue("")
        $settingsValue = [string]$settingsKey.GetValue("")
        return (($compressValue -match [regex]::Escape($ScriptPath)) -and ($settingsValue -match [regex]::Escape($ScriptPath)))
    } finally {
        if ($compressKey) {
            $compressKey.Close()
        }
        if ($settingsKey) {
            $settingsKey.Close()
        }
    }
}

function Test-UserRegistryWritable {
    $subKey = "Software\Classes\VideoCompressorPermissionTest"
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
        $key.SetValue("", "ok", [Microsoft.Win32.RegistryValueKind]::String)
        $key.Close()
        $key = $null
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey, $false)
        return $true
    } catch {
        try {
            if ($key) {
                $key.Close()
            }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey, $false)
        } catch {
        }
        return $false
    }
}

function Test-UserPathWritable {
    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $sentinel = "VideoCompressorProbe_$([Guid]::NewGuid().ToString("N"))"
    $probedPath = if ($currentUserPath) { "$currentUserPath;$sentinel" } else { $sentinel }
    $probed = $false
    try {
        [Environment]::SetEnvironmentVariable("Path", $probedPath, "User")
        $probed = $true
        $restoredPath = if ($currentUserPath) { $currentUserPath } else { $null }
        [Environment]::SetEnvironmentVariable("Path", $restoredPath, "User")
        return $true
    } catch {
        return $false
    } finally {
        if ($probed -and $currentUserPath) {
            try { [Environment]::SetEnvironmentVariable("Path", $currentUserPath, "User") } catch {}
        }
    }
}

function Show-StatusLine {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    $state = if ($Ok) { "OK" } else { "MISSING" }
    $color = if ($Ok) { "Green" } else { "Yellow" }
    Write-Host ("  {0,-24} " -f $Name) -NoNewline
    Write-Host ("[{0}]" -f $state) -ForegroundColor $color -NoNewline
    if ($Detail) {
        Write-Host " $Detail"
    } else {
        Write-Host ""
    }
}

function Get-ReadinessStatus {
    param([switch]$Force)

    if ($script:ReadinessCache -and -not $Force) {
        return $script:ReadinessCache
    }

    $script:ReadinessCache = [pscustomobject]@{
        IsAdmin = Test-IsAdministrator
        FFmpeg = Get-FFmpegStatus
        RegistryWritable = Test-UserRegistryWritable
        PathWritable = Test-UserPathWritable
        Registered = Test-ContextMenuRegistered
        Winget = Test-ExecutableInPath "winget.exe"
    }

    return $script:ReadinessCache
}

function Show-ReadinessReport {
    param([switch]$Force)

    $status = Get-ReadinessStatus -Force:$Force

    try { Clear-Host } catch {}
    Write-Host "Video Compressor setup" -ForegroundColor Cyan
    Write-Host ""
    Show-StatusLine -Name "Admin window" -Ok $status.IsAdmin -Detail "Only needed for winget fallback or old HKCR cleanup."
    Show-StatusLine -Name "Registry permission" -Ok $status.RegistryWritable -Detail "Required for current-user context menu registration."
    Show-StatusLine -Name "User PATH permission" -Ok $status.PathWritable -Detail "Required to add FFmpeg to PATH."
    Show-StatusLine -Name "winget available" -Ok $status.Winget -Detail "Required for automatic FFmpeg install."
    Show-StatusLine -Name "FFmpeg in PATH" -Ok $status.FFmpeg.Ready -Detail $(if ($status.FFmpeg.Ready) { $status.FFmpeg.FFmpegPath } elseif ($status.FFmpeg.Detected) { "Detected, but not fully in PATH." } else { "Not found." })
    Show-StatusLine -Name "Context menu" -Ok $status.Registered -Detail $(if ($status.Registered) { "Registered to this script." } else { "Not registered." })
    Write-Host ""

    if ($status.RegistryWritable -and $status.PathWritable -and $status.FFmpeg.Ready -and $status.Registered) {
        Write-Host "All clear: FFmpeg, PATH, permissions, and context menu are ready." -ForegroundColor Green
    } elseif ($status.RegistryWritable -and $status.PathWritable -and $status.FFmpeg.Ready) {
        Write-Host "All clear to register the context menu." -ForegroundColor Green
    } else {
        Write-Host "Setup needs attention before compression is fully ready." -ForegroundColor Yellow
    }
    Write-Host ""

    return $status
}

function Install-OrFixFFmpegFromTui {
    $ffmpeg = Get-FFmpegStatus

    if ($ffmpeg.Ready) {
        Write-Host "FFmpeg and FFprobe are already in PATH." -ForegroundColor Green
        return
    }

    if ($ffmpeg.Detected) {
        $directory = Split-Path -Parent $ffmpeg.FFmpegPath
        Write-Host "FFmpeg was detected here:" -ForegroundColor Cyan
        Write-Host "  $directory"
        $answer = Read-Host "Add this directory to your user PATH? [Y/N]"
        if ($answer -match "^(y|yes)$") {
            Add-DirectoryToUserPath -Directory $directory
            Write-Host "Added FFmpeg to user PATH for future sessions and this process." -ForegroundColor Green
        }
        return
    }

    $answer = Read-Host "FFmpeg is not installed. Install it now? [Y/N]"
    if ($answer -notmatch "^(y|yes)$") {
        Write-Host "Skipped FFmpeg install." -ForegroundColor Yellow
        return
    }

    if (Test-ExecutableInPath "winget.exe") {
        try {
            Install-FFmpegWithWinget
            $installed = Get-FFmpegStatus
            if ($installed.Detected) {
                Add-DirectoryToUserPath -Directory (Split-Path -Parent $installed.FFmpegPath)
                Write-Host "FFmpeg installed and added to user PATH." -ForegroundColor Green
                return
            }
            Write-Host "winget finished, but FFmpeg was not detected for your account." -ForegroundColor Yellow
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        $fallback = Read-Host "Download a self-contained FFmpeg for your account instead (no admin needed)? [Y/N]"
        if ($fallback -notmatch "^(y|yes)$") {
            return
        }
    }

    try {
        Write-Host "Downloading a portable FFmpeg for your account..." -ForegroundColor Cyan
        $binDir = Install-FFmpegPortable
        Add-DirectoryToUserPath -Directory $binDir
        $installed = Get-FFmpegStatus
        if ($installed.Detected) {
            Write-Host "FFmpeg installed for your account and added to PATH." -ForegroundColor Green
        } else {
            Write-Host "FFmpeg was downloaded to $binDir but could not be verified." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Could not set up portable FFmpeg: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-VideoDuration {
    param(
        [string]$Path,
        [string]$FFprobePath
    )

    try {
        $durationRaw = & $FFprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path
        if (-not $durationRaw) {
            return 0
        }

        $durationValue = 0.0
        $durationText = ([string]$durationRaw).Trim()
        if ([double]::TryParse($durationText, [System.Globalization.NumberStyles]::Float, $script:InvariantCulture, [ref]$durationValue)) {
            return [math]::Round($durationValue)
        }

        if ([double]::TryParse($durationText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$durationValue)) {
            return [math]::Round($durationValue)
        }

        Write-Log "Could not parse duration: $durationText"
        return 0
    } catch {
        Write-Log "Error getting duration: $($_.Exception.Message)"
        return 0
    }
}

function Format-Seconds {
    param([int]$Seconds)

    $time = [TimeSpan]::FromSeconds($Seconds)
    return "{0:D2}:{1:D2}:{2:D2}" -f ([int]$time.TotalHours), $time.Minutes, $time.Seconds
}

function Install-EasyCompressFromTui {
    $ffmpeg = Get-FFmpegStatus
    if (-not $ffmpeg.Ready) {
        Install-OrFixFFmpegFromTui
    }

    Register-ContextMenu
    Write-Host "Install complete." -ForegroundColor Green
}

function Show-SetupTui {
    $forceRefresh = $true

    while ($true) {
        $status = Show-ReadinessReport -Force:$forceRefresh
        $forceRefresh = $false

        if (-not $status.FFmpeg.Ready) {
            if ($status.FFmpeg.Detected) {
                Write-Host "FFmpeg is installed but is not fully available through PATH." -ForegroundColor Yellow
            } else {
                Write-Host "FFmpeg is required before compression can run." -ForegroundColor Yellow
            }
            $answer = Read-Host "Fix FFmpeg now? [Y/N]"
            if ($answer -match "^(y|yes)$") {
                Install-OrFixFFmpegFromTui
                $forceRefresh = $true
                Write-Host ""
                Read-Host "Press Enter to continue"
                continue
            }
        }

        Write-Host "Actions"
        Write-Host "  1. Install"
        Write-Host "  2. Install or fix FFmpeg PATH"
        Write-Host "  3. Register Explorer context menu"
        Write-Host "  4. Unregister Explorer context menu"
        Write-Host "  5. Remove old admin/HKCR entries"
        Write-Host "  6. Update EasyCompress"
        Write-Host "  7. Refresh checks"
        Write-Host "  0. Exit"
        Write-Host ""

        $choice = Read-Host "Choose"
        switch ($choice) {
            "1" {
                Install-EasyCompressFromTui
                $forceRefresh = $true
                Read-Host "Press Enter to continue"
            }
            "2" {
                Install-OrFixFFmpegFromTui
                $forceRefresh = $true
                Read-Host "Press Enter to continue"
            }
            "3" {
                Register-ContextMenu
                $forceRefresh = $true
                Read-Host "Press Enter to continue"
            }
            "4" {
                Unregister-ContextMenu
                $forceRefresh = $true
                Read-Host "Press Enter to continue"
            }
            "5" {
                if (-not (Test-IsAdministrator)) {
                    Write-Host "Old HKCR entries require Administrator rights to remove." -ForegroundColor Yellow
                    $elevate = Read-Host "Open an Administrator window for cleanup? [Y/N]"
                    if ($elevate -match "^(y|yes)$") {
                        Start-Elevated -Arguments @("-Unregister")
                    }
                } else {
                    foreach ($subKey in $LegacyContextMenuSubKeys) {
                        [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree($subKey, $false)
                    }
                    Write-Host "Old admin/HKCR context menu entries removed." -ForegroundColor Green
                }
                $forceRefresh = $true
                Read-Host "Press Enter to continue"
            }
            "6" {
                try {
                    Update-EasyCompressFromGithub
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                }
                $forceRefresh = $true
            }
            "7" { $forceRefresh = $true }
            "0" { return }
            default {
                Write-Host "Unknown option." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-CompressorUi {
    param([string]$Path)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-DebugEnvironment
    Write-Log "Show-CompressorUi path: $Path"

    if (-not $Path) {
        Write-Log "No input file provided."
        [System.Windows.Forms.MessageBox]::Show("No input file provided.", "Error", "OK", "Error") | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Input file not found: $Path"
        [System.Windows.Forms.MessageBox]::Show("Input file not found: $Path", "Error", "OK", "Error") | Out-Null
        return
    }

    $inputItem = Get-Item -LiteralPath $Path
    $Path = $inputItem.FullName
    Write-Log "Input full name: $($inputItem.FullName)"
    Write-Log "Input size: $($inputItem.Length)"

    try {
        $tools = Ensure-FFmpeg
    $uiState = @{
        TotalSeconds = 0
        DurationLoaded = $false
    }
    $compressionState = @{
        Running = $false
        Cancelled = $false
        Process = $null
    }
    $themeState = @{
        Dark = $false
    }

    try {
        $personalize = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
        $themeState.Dark = ($personalize.AppsUseLightTheme -eq 0)
    } catch {
        $themeState.Dark = $false
    }

    function Get-WindowsAccentColor {
        function Convert-ArgbDwordToColor {
            param([uint32]$Value)

            $red = ($Value -shr 16) -band 0xff
            $green = ($Value -shr 8) -band 0xff
            $blue = $Value -band 0xff

            if (($red + $green + $blue) -gt 0) {
                return [System.Drawing.Color]::FromArgb($red, $green, $blue)
            }

            return $null
        }

        function Convert-AbgrDwordToColor {
            param([uint32]$Value)

            $red = $Value -band 0xff
            $green = ($Value -shr 8) -band 0xff
            $blue = ($Value -shr 16) -band 0xff

            if (($red + $green + $blue) -gt 0) {
                return [System.Drawing.Color]::FromArgb($red, $green, $blue)
            }

            return $null
        }

        try {
            $accent = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent" -ErrorAction Stop
            foreach ($propertyName in @("AccentColorMenu", "StartColorMenu")) {
                if ($null -ne $accent.$propertyName) {
                    $color = Convert-ArgbDwordToColor -Value ([uint32]$accent.$propertyName)
                    if ($color) {
                        return $color
                    }
                }
            }
        } catch {
        }

        try {
            $dwm = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -ErrorAction Stop
            if ($null -ne $dwm.AccentColor) {
                $color = Convert-AbgrDwordToColor -Value ([uint32]$dwm.AccentColor)
                if ($color) {
                    return $color
                }
            }

            if ($null -ne $dwm.ColorizationColor) {
                $color = Convert-AbgrDwordToColor -Value ([uint32]$dwm.ColorizationColor)
                if ($color) {
                    return $color
                }
            }
        } catch {
        }

        return [System.Drawing.Color]::FromArgb(0, 120, 212)
    }

    $systemAccent = Get-WindowsAccentColor

    function Get-CompressorTheme {
        param([bool]$Dark)

        if ($Dark) {
            return @{
                Accent = $systemAccent
                FormBack = [System.Drawing.Color]::FromArgb(28, 30, 34)
                PanelBack = [System.Drawing.Color]::FromArgb(38, 41, 46)
                PanelBorder = [System.Drawing.Color]::FromArgb(62, 66, 74)
                TextMain = [System.Drawing.Color]::FromArgb(241, 243, 245)
                TextMuted = [System.Drawing.Color]::FromArgb(164, 171, 181)
                FieldBack = [System.Drawing.Color]::FromArgb(32, 35, 39)
                Hover = [System.Drawing.Color]::FromArgb(50, 54, 61)
                SecondaryButton = [System.Drawing.Color]::FromArgb(38, 41, 46)
                ToggleText = [string][char]0x2600
            }
        }

        return @{
            Accent = $systemAccent
            FormBack = [System.Drawing.Color]::FromArgb(246, 247, 249)
            PanelBack = [System.Drawing.Color]::White
            PanelBorder = [System.Drawing.Color]::FromArgb(221, 225, 230)
            TextMain = [System.Drawing.Color]::FromArgb(32, 35, 39)
            TextMuted = [System.Drawing.Color]::FromArgb(96, 103, 112)
            FieldBack = [System.Drawing.Color]::White
            Hover = [System.Drawing.Color]::FromArgb(232, 235, 239)
            SecondaryButton = [System.Drawing.Color]::White
            ToggleText = [string][char]0x263E
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Compress Video"
    $form.Size = New-Object System.Drawing.Size(462, 382)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "None"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $palette = Get-CompressorTheme -Dark $themeState.Dark
    $form.BackColor = $palette.FormBack

    $accentStrip = New-Object System.Windows.Forms.Panel
    $accentStrip.Location = New-Object System.Drawing.Point(0, 0)
    $accentStrip.Size = New-Object System.Drawing.Size(5, 382)
    $accentStrip.BackColor = $palette.Accent
    $form.Controls.Add($accentStrip)

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(5, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(457, 60)
    $headerPanel.BackColor = $form.BackColor
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Compress Video"
    $titleLabel.Location = New-Object System.Drawing.Point(17, 8)
    $titleLabel.Size = New-Object System.Drawing.Size(180, 18)
    $titleLabel.ForeColor = $palette.TextMuted
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $headerPanel.Controls.Add($titleLabel)

    $fileLabel = New-Object System.Windows.Forms.Label
    $fileLabel.Text = Split-Path $Path -Leaf
    $fileLabel.Location = New-Object System.Drawing.Point(17, 27)
    $fileLabel.Size = New-Object System.Drawing.Size(330, 24)
    $fileLabel.AutoEllipsis = $true
    $fileLabel.ForeColor = $palette.TextMain
    $fileLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $headerPanel.Controls.Add($fileLabel)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "X"
    $themeBtn = New-Object System.Windows.Forms.Button
    $themeBtn.Text = $palette.ToggleText
    $themeBtn.Location = New-Object System.Drawing.Point(374, 8)
    $themeBtn.Size = New-Object System.Drawing.Size(30, 30)
    $themeBtn.FlatStyle = "Flat"
    $themeBtn.FlatAppearance.BorderSize = 0
    $themeBtn.BackColor = $form.BackColor
    $themeBtn.ForeColor = $palette.TextMuted
    $themeBtn.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11)
    $themeBtn.Add_MouseEnter({ $themeBtn.BackColor = (Get-CompressorTheme -Dark $themeState.Dark).Hover })
    $themeBtn.Add_MouseLeave({ $themeBtn.BackColor = $form.BackColor })
    $headerPanel.Controls.Add($themeBtn)

    $closeBtn.Location = New-Object System.Drawing.Point(411, 8)
    $closeBtn.Size = New-Object System.Drawing.Size(34, 30)
    $closeBtn.FlatStyle = "Flat"
    $closeBtn.FlatAppearance.BorderSize = 0
    $closeBtn.BackColor = $form.BackColor
    $closeBtn.ForeColor = $palette.TextMain
    $closeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $closeBtn.Add_MouseEnter({ $closeBtn.BackColor = (Get-CompressorTheme -Dark $themeState.Dark).Hover })
    $closeBtn.Add_MouseLeave({ $closeBtn.BackColor = $form.BackColor })
    $closeBtn.Add_Click({ $form.Close() })
    $headerPanel.Controls.Add($closeBtn)

    $dragState = @{
        Active = $false
        Cursor = [System.Drawing.Point]::Empty
        Form = [System.Drawing.Point]::Empty
    }

    $startDrag = {
        param($eventSender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $dragState.Active = $true
            $dragState.Cursor = [System.Windows.Forms.Control]::MousePosition
            $dragState.Form = $form.Location
        }
    }
    $moveDrag = {
        if ($dragState.Active) {
            $current = [System.Windows.Forms.Control]::MousePosition
            $form.Location = New-Object System.Drawing.Point(
                ($dragState.Form.X + $current.X - $dragState.Cursor.X),
                ($dragState.Form.Y + $current.Y - $dragState.Cursor.Y)
            )
        }
    }
    $endDrag = { $dragState.Active = $false }

    foreach ($dragControl in @($headerPanel, $titleLabel, $fileLabel)) {
        $dragControl.Add_MouseDown($startDrag)
        $dragControl.Add_MouseMove($moveDrag)
        $dragControl.Add_MouseUp($endDrag)
    }

    $settingsPanel = New-Object System.Windows.Forms.Panel
    $settingsPanel.Location = New-Object System.Drawing.Point(20, 64)
    $settingsPanel.Size = New-Object System.Drawing.Size(404, 86)
    $settingsPanel.BackColor = $palette.PanelBack
    $settingsPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($settingsPanel)

    $lblResolution = New-Object System.Windows.Forms.Label
    $lblResolution.Text = "Resolution"
    $lblResolution.Location = New-Object System.Drawing.Point(14, 16)
    $lblResolution.Size = New-Object System.Drawing.Size(105, 23)
    $lblResolution.ForeColor = $palette.TextMuted
    $settingsPanel.Controls.Add($lblResolution)

    $resolutions = @(
        @{ Name = "1080p"; Scale = "-2:1080" },
        @{ Name = "720p"; Scale = "-2:720" },
        @{ Name = "480p"; Scale = "-2:480" },
        @{ Name = "360p"; Scale = "-2:360" },
        @{ Name = "Original"; Scale = "" }
    )

    $cmbResolution = New-Object System.Windows.Forms.ComboBox
    $cmbResolution.DropDownStyle = "DropDownList"
    $cmbResolution.Location = New-Object System.Drawing.Point(132, 13)
    $cmbResolution.Size = New-Object System.Drawing.Size(252, 26)
    foreach ($res in $resolutions) {
        [void]$cmbResolution.Items.Add($res.Name)
    }
    $cmbResolution.SelectedItem = "720p"
    $cmbResolution.BackColor = $palette.FieldBack
    $cmbResolution.ForeColor = $palette.TextMain
    $settingsPanel.Controls.Add($cmbResolution)

    $lblCompression = New-Object System.Windows.Forms.Label
    $lblCompression.Text = "Compression"
    $lblCompression.Location = New-Object System.Drawing.Point(14, 50)
    $lblCompression.Size = New-Object System.Drawing.Size(105, 23)
    $lblCompression.ForeColor = $palette.TextMuted
    $settingsPanel.Controls.Add($lblCompression)

    $levels = @(
        @{ Name = "Low (Best Quality)"; CRF = 18 },
        @{ Name = "Medium"; CRF = 23 },
        @{ Name = "High"; CRF = 28 },
        @{ Name = "X-High (Smallest Size)"; CRF = 33 }
    )

    $cmbCompression = New-Object System.Windows.Forms.ComboBox
    $cmbCompression.DropDownStyle = "DropDownList"
    $cmbCompression.Location = New-Object System.Drawing.Point(132, 47)
    $cmbCompression.Size = New-Object System.Drawing.Size(252, 26)
    foreach ($level in $levels) {
        [void]$cmbCompression.Items.Add($level.Name)
    }
    $cmbCompression.SelectedItem = "Medium"
    $cmbCompression.BackColor = $palette.FieldBack
    $cmbCompression.ForeColor = $palette.TextMain
    $settingsPanel.Controls.Add($cmbCompression)

    $trimTitle = New-Object System.Windows.Forms.Label
    $trimTitle.Text = "Trim"
    $trimTitle.Location = New-Object System.Drawing.Point(22, 156)
    $trimTitle.Size = New-Object System.Drawing.Size(200, 21)
    $trimTitle.ForeColor = $palette.TextMain
    $trimTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($trimTitle)

    $trimPanel = New-Object System.Windows.Forms.Panel
    $trimPanel.Location = New-Object System.Drawing.Point(20, 178)
    $trimPanel.Size = New-Object System.Drawing.Size(404, 128)
    $trimPanel.BackColor = $palette.PanelBack
    $trimPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($trimPanel)

    $chkTrim = New-Object System.Windows.Forms.CheckBox
    $chkTrim.Text = "Enable"
    $chkTrim.Location = New-Object System.Drawing.Point(14, 14)
    $chkTrim.Size = New-Object System.Drawing.Size(130, 22)
    $chkTrim.ForeColor = $palette.TextMain
    $trimPanel.Controls.Add($chkTrim)

    $lblDuration = New-Object System.Windows.Forms.Label
    $lblDuration.Text = "Duration not loaded"
    $lblDuration.Location = New-Object System.Drawing.Point(176, 15)
    $lblDuration.Size = New-Object System.Drawing.Size(207, 21)
    $lblDuration.TextAlign = "MiddleRight"
    $lblDuration.ForeColor = $palette.TextMuted
    $trimPanel.Controls.Add($lblDuration)

    $lblStart = New-Object System.Windows.Forms.Label
    $lblStart.Text = "Start: 00:00:00"
    $lblStart.Location = New-Object System.Drawing.Point(14, 48)
    $lblStart.Size = New-Object System.Drawing.Size(105, 20)
    $lblStart.ForeColor = $palette.TextMuted
    $trimPanel.Controls.Add($lblStart)

    $trackStart = New-Object System.Windows.Forms.TrackBar
    $trackStart.Location = New-Object System.Drawing.Point(126, 42)
    $trackStart.Size = New-Object System.Drawing.Size(260, 42)
    $trackStart.Maximum = 1
    $trackStart.Enabled = $false
    $trimPanel.Controls.Add($trackStart)

    $lblEnd = New-Object System.Windows.Forms.Label
    $lblEnd.Text = "End: 00:00:00"
    $lblEnd.Location = New-Object System.Drawing.Point(14, 90)
    $lblEnd.Size = New-Object System.Drawing.Size(105, 20)
    $lblEnd.ForeColor = $palette.TextMuted
    $trimPanel.Controls.Add($lblEnd)

    $trackEnd = New-Object System.Windows.Forms.TrackBar
    $trackEnd.Location = New-Object System.Drawing.Point(126, 84)
    $trackEnd.Size = New-Object System.Drawing.Size(260, 42)
    $trackEnd.Maximum = 1
    $trackEnd.Value = 1
    $trackEnd.Enabled = $false
    $trimPanel.Controls.Add($trackEnd)

    $loadDuration = {
        if ($uiState.DurationLoaded) {
            return $true
        }

        $lblDuration.Text = "Loading duration..."
        $form.Refresh()

        $uiState.TotalSeconds = Get-VideoDuration -Path $Path -FFprobePath $tools.FFprobe
        Write-Log "Detected duration for '$Path': $($uiState.TotalSeconds) seconds"

        if ($uiState.TotalSeconds -le 1) {
            $lblDuration.Text = "Duration unavailable"
            [System.Windows.Forms.MessageBox]::Show("Could not read the video duration, so trimming is unavailable.", "Video Compressor", "OK", "Warning") | Out-Null
            return $false
        }

        $trackStart.Maximum = $uiState.TotalSeconds
        $trackStart.TickFrequency = [math]::Max(1, [math]::Round($uiState.TotalSeconds / 10))
        $trackStart.Value = 0
        $trackEnd.Maximum = $uiState.TotalSeconds
        $trackEnd.TickFrequency = [math]::Max(1, [math]::Round($uiState.TotalSeconds / 10))
        $trackEnd.Value = $uiState.TotalSeconds
        $lblEnd.Text = "End: $(Format-Seconds ($uiState.TotalSeconds))"
        $lblDuration.Text = "Duration: $(Format-Seconds ($uiState.TotalSeconds))"
        $uiState.DurationLoaded = $true
        return $true
    }

    $chkTrim.Add_CheckedChanged({
        if ($chkTrim.Checked) {
            if (& $loadDuration) {
                $trackStart.Enabled = $true
                $trackEnd.Enabled = $true
            } else {
                $chkTrim.Checked = $false
                $trackStart.Enabled = $false
                $trackEnd.Enabled = $false
            }
        } else {
            $trackStart.Enabled = $false
            $trackEnd.Enabled = $false
        }
    })

    $trackStart.Add_ValueChanged({
        if ($trackStart.Value -ge $trackEnd.Value) {
            $trackStart.Value = [math]::Max(0, $trackEnd.Value - 1)
        }
        $lblStart.Text = "Start: $(Format-Seconds $trackStart.Value)"
    })

    $trackEnd.Add_ValueChanged({
        if ($trackEnd.Value -le $trackStart.Value) {
            $trackEnd.Value = [math]::Min($trackEnd.Maximum, $trackStart.Value + 1)
        }
        $lblEnd.Text = "End: $(Format-Seconds $trackEnd.Value)"
    })

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 315)
    $progressBar.Size = New-Object System.Drawing.Size(404, 8)
    $progressBar.Style = "Marquee"
    $progressBar.Visible = $false
    $form.Controls.Add($progressBar)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(220, 330)
    $cancelBtn.Size = New-Object System.Drawing.Size(94, 34)
    $cancelBtn.FlatStyle = "Flat"
    $cancelBtn.FlatAppearance.BorderColor = $palette.PanelBorder
    $cancelBtn.BackColor = $palette.SecondaryButton
    $cancelBtn.ForeColor = $palette.TextMain
    $cancelBtn.Add_Click({
        if ($compressionState.Running) {
            $compressionState.Cancelled = $true
            $cancelBtn.Enabled = $false
            $statusLabel.Text = "Cancelling..."
        } else {
            $form.Close()
        }
    })
    $form.Controls.Add($cancelBtn)

    $compressBtn = New-Object System.Windows.Forms.Button
    $compressBtn.Text = "Compress"
    $compressBtn.Location = New-Object System.Drawing.Point(324, 330)
    $compressBtn.Size = New-Object System.Drawing.Size(100, 34)
    $compressBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $compressBtn.FlatStyle = "Flat"
    $compressBtn.FlatAppearance.BorderSize = 0
    $compressBtn.BackColor = $palette.Accent
    $compressBtn.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($compressBtn)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Ready"
    $statusLabel.Location = New-Object System.Drawing.Point(20, 334)
    $statusLabel.Size = New-Object System.Drawing.Size(190, 24)
    $statusLabel.TextAlign = "MiddleLeft"
    $statusLabel.ForeColor = $palette.TextMuted
    $form.Controls.Add($statusLabel)

    $applyTheme = {
        $palette = Get-CompressorTheme -Dark $themeState.Dark

        $form.BackColor = $palette.FormBack
        $accentStrip.BackColor = $palette.Accent
        $headerPanel.BackColor = $palette.FormBack
        $titleLabel.BackColor = $palette.FormBack
        $titleLabel.ForeColor = $palette.TextMuted
        $fileLabel.BackColor = $palette.FormBack
        $fileLabel.ForeColor = $palette.TextMain

        $themeBtn.Text = $palette.ToggleText
        $themeBtn.BackColor = $palette.FormBack
        $themeBtn.ForeColor = $palette.TextMuted
        $closeBtn.BackColor = $palette.FormBack
        $closeBtn.ForeColor = $palette.TextMain

        $settingsPanel.BackColor = $palette.PanelBack
        $trimPanel.BackColor = $palette.PanelBack
        foreach ($label in @($lblResolution, $lblCompression, $lblDuration, $lblStart, $lblEnd, $statusLabel)) {
            $label.BackColor = $palette.PanelBack
            $label.ForeColor = $palette.TextMuted
        }
        $statusLabel.BackColor = $palette.FormBack
        $trimTitle.BackColor = $palette.FormBack
        $trimTitle.ForeColor = $palette.TextMain
        $chkTrim.BackColor = $palette.PanelBack
        $chkTrim.ForeColor = $palette.TextMain

        foreach ($combo in @($cmbResolution, $cmbCompression)) {
            $combo.BackColor = $palette.FieldBack
            $combo.ForeColor = $palette.TextMain
        }

        $cancelBtn.BackColor = $palette.SecondaryButton
        $cancelBtn.ForeColor = $palette.TextMain
        $cancelBtn.FlatAppearance.BorderColor = $palette.PanelBorder
        $compressBtn.BackColor = $palette.Accent
        $compressBtn.ForeColor = [System.Drawing.Color]::White
    }

    $themeBtn.Add_Click({
        $themeState.Dark = -not $themeState.Dark
        & $applyTheme
    })
    & $applyTheme

    $resetControls = {
        $compressBtn.Enabled = $true
        $cmbResolution.Enabled = $true
        $cmbCompression.Enabled = $true
        $chkTrim.Enabled = $true
        $cancelBtn.Enabled = $true
        $progressBar.Visible = $false
    }

    $form.Add_FormClosing({
        # Closing the window mid-encode aborts FFmpeg instead of orphaning ffmpeg.exe.
        if ($compressionState.Running) {
            $compressionState.Cancelled = $true
        }
    })

    $compressBtn.Add_Click({
        $selectedRes = $resolutions | Where-Object { $_.Name -eq [string]$cmbResolution.SelectedItem } | Select-Object -First 1
        $scale = $selectedRes.Scale
        $suffix = $selectedRes.Name.ToLower()

        $selectedLevel = $levels | Where-Object { $_.Name -eq [string]$cmbCompression.SelectedItem } | Select-Object -First 1
        $crf = $selectedLevel.CRF

        # NOTE: [Path]::ChangeExtension($Path, $null) leaves a trailing dot in PowerShell
        # (the $null is coerced to ""), producing names like "clip._720p.mp4". Build the
        # name from the parts instead.
        $outputDirectory = [System.IO.Path]::GetDirectoryName($Path)
        $outputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $outputFile = [System.IO.Path]::Combine($outputDirectory, "${outputBaseName}_$suffix.mp4")
        $runId = [Guid]::NewGuid().ToString("N")
        $ffmpegStdOut = Join-Path $TempRoot "EasyCompress-ffmpeg-$runId.out.log"
        $ffmpegStdErr = Join-Path $TempRoot "EasyCompress-ffmpeg-$runId.err.log"

        try {
            $compressionState.Cancelled = $false
            $compressionState.Running = $true
            $compressBtn.Enabled = $false
            $cmbResolution.Enabled = $false
            $cmbCompression.Enabled = $false
            $chkTrim.Enabled = $false
            $cancelBtn.Enabled = $true
            $progressBar.Visible = $true
            $statusLabel.Text = "Compressing... (FFmpeg running)"
            $form.Refresh()

            $ffmpegArgs = @("-y")
            if ($chkTrim.Checked) {
                # -ss as an input option (before -i) makes FFmpeg measure -to on the post-seek
                # output timeline, so "-ss 3 -to 6" yields 6s of video, not 3s. Use an explicit
                # duration (-t) instead so the trimmed length always matches the slider range.
                $trimDuration = [math]::Max(1, $trackEnd.Value - $trackStart.Value)
                $ffmpegArgs += @("-ss", (Format-Seconds $trackStart.Value), "-t", (Format-Seconds $trimDuration))
            }

            $ffmpegArgs += @("-i", $Path)
            if ($scale) {
                $ffmpegArgs += @("-vf", "scale=$scale")
            }

            $ffmpegArgs += @("-c:v", "libx264", "-crf", $crf, "-preset", "medium", "-c:a", "aac", "-b:a", "128k", $outputFile)
            $ffmpegArgumentString = ConvertTo-ProcessArgumentString -Arguments $ffmpegArgs
            Write-Log "Selected resolution: $($selectedRes.Name)"
            Write-Log "Selected scale: $scale"
            Write-Log "Selected compression: $($selectedLevel.Name)"
            Write-Log "Selected CRF: $crf"
            Write-Log "Trim enabled: $($chkTrim.Checked)"
            if ($chkTrim.Checked) {
                Write-Log "Trim start seconds: $($trackStart.Value)"
                Write-Log "Trim end seconds: $($trackEnd.Value)"
            }
            Write-Log "Output file: $outputFile"
            Write-Log "FFmpeg stdout: $ffmpegStdOut"
            Write-Log "FFmpeg stderr: $ffmpegStdErr"
            Write-Log "Running FFmpeg: $($tools.FFmpeg) $ffmpegArgumentString"

            try {
                $processResult = Invoke-LoggedProcess -FilePath $tools.FFmpeg -Arguments $ffmpegArgs -StdOutPath $ffmpegStdOut -StdErrPath $ffmpegStdErr -ControlState $compressionState
                Write-Log "FFmpeg process id: $($processResult.Id)"
                $exitCode = $processResult.ExitCode
                Write-Log "FFmpeg process exited. ExitCode: $exitCode"
                Write-LogFileTail -Path $ffmpegStdOut -Label "FFmpeg stdout"
                Write-LogFileTail -Path $ffmpegStdErr -Label "FFmpeg stderr"

                if ($processResult.Cancelled) {
                    Write-Log "Compression cancelled by user; removing partial output."
                    Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $ffmpegStdOut, $ffmpegStdErr -Force -ErrorAction SilentlyContinue
                    if (-not $form.IsDisposed) {
                        $statusLabel.Text = "Cancelled."
                        & $resetControls
                    }
                    return
                }

                $compressionSucceeded = ($exitCode -eq 0)
                if ($compressionSucceeded) {
                    if (-not (Test-CompletedFfmpegOutput -OutputPath $outputFile -StdErrPath $ffmpegStdErr)) {
                        Write-Log "FFmpeg exited cleanly but output is missing or truncated."
                        $compressionSucceeded = $false
                    }
                } elseif (Test-CompletedFfmpegOutput -OutputPath $outputFile -StdErrPath $ffmpegStdErr) {
                    Write-Log "FFmpeg exit code was not clean, but output is complete. Continuing."
                    $compressionSucceeded = $true
                }

                if ($compressionSucceeded) {
                    $newFile = Set-OutputTimestamps -SourcePath $Path -OutputPath $outputFile
                    if ($newFile) {
                        Write-Log "Compression succeeded. Output size: $($newFile.Length)"
                    } else {
                        Write-Log "Compression succeeded. Output file could not be inspected for size (likely transient AV lock)."
                    }
                    Remove-Item -LiteralPath $ffmpegStdOut, $ffmpegStdErr -Force -ErrorAction SilentlyContinue
                    $form.Close()
                } else {
                    $statusLabel.Text = "Error occurred."
                    [System.Windows.Forms.MessageBox]::Show("FFmpeg failed with exit code $exitCode.`n`nDebug log:`n$LogFile", "Error", "OK", "Error") | Out-Null
                    & $resetControls
                }
            } catch {
                Write-Log "FFmpeg launch/compression exception: $($_.Exception.Message)"
                Write-LogFileTail -Path $ffmpegStdOut -Label "FFmpeg stdout"
                Write-LogFileTail -Path $ffmpegStdErr -Label "FFmpeg stderr"
                $statusLabel.Text = "Error: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("An error occurred: $($_.Exception.Message)`n`nDebug log:`n$LogFile", "Error", "OK", "Error") | Out-Null
                & $resetControls
            } finally {
                $compressionState.Running = $false
            }
        } finally {
            $compressionState.Running = $false
            if ($compressBtn.Enabled -eq $false -and -not $form.IsDisposed -and -not $compressionState.Cancelled) {
                & $resetControls
            }
        }
    })

        $form.ShowDialog() | Out-Null
    } finally {
        if ($null -ne $form -and -not $form.IsDisposed) {
            try { $form.Dispose() } catch {}
        }
    }
}

try {
    Write-Log "--- Script started ---"

    # The setup menu runs as the invoking (non-elevated) user on purpose: the context menu
    # lives in HKCU and FFmpeg goes on the user PATH, both of which are per-user. Elevating
    # here would switch to the admin's profile hive on machines where the signed-in user is
    # a standard account, silently registering everything for the wrong user. Elevation is
    # requested only where it is actually needed (winget fallback, legacy HKCR cleanup).

    if ($InstallFFmpeg) {
        Add-Type -AssemblyName System.Windows.Forms
        Install-FFmpegWithWinget
        $ffmpeg = Find-Executable "ffmpeg.exe"
        if ($ffmpeg) {
            Add-DirectoryToUserPath -Directory (Split-Path -Parent $ffmpeg)
        }
        [System.Windows.Forms.MessageBox]::Show("FFmpeg installed and added to your user PATH.", "Video Compressor", "OK", "Information") | Out-Null
        exit
    }

    if ($Update) {
        Update-EasyCompressFromGithub
        exit
    }

    if ($Register) {
        Register-ContextMenu
        exit
    }

    if ($Unregister) {
        Unregister-ContextMenu
        exit
    }

    if ($InputFile) {
        Show-CompressorUi -Path $InputFile
    } else {
        Show-SetupTui
    }
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Video Compressor", "OK", "Error") | Out-Null
    } catch {
        Write-Error $_.Exception.Message
    }
    exit 1
}
