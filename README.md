# Video Compressor

A single-file Windows context menu tool for compressing and optionally trimming videos with FFmpeg.

## Features

- Right-click Explorer integration for video compression.
- Separate right-click **EasyCompress Settings** entry with a gear icon for launching setup.
- One PowerShell file handles setup, uninstall, FFmpeg checks, and compression.
- Setup TUI checks permissions, FFmpeg, FFprobe, `winget`, user `PATH`, and context-menu registration.
- Can install FFmpeg with `winget` and add the detected FFmpeg folder to the user `PATH`.
- Borderless native WinForms compressor UI with light/dark mode support.
- Uses the Windows app theme on launch and includes an in-window theme toggle.
- Uses the current Windows accent color for the side strip and primary button.
- Supports 1080p, 720p, 480p, 360p, or original resolution.
- Optional trimming; video duration is loaded only when trimming is enabled, so the window opens faster.
- Preserves the original file creation and modified timestamps on the compressed output.

## Requirements

- Windows PowerShell or PowerShell.
- `winget` for automatic FFmpeg installation.
- FFmpeg and FFprobe available in `PATH`; the setup flow can install/fix this.

## Setup

Install or launch with one command:

```powershell
irm "https://raw.githubusercontent.com/Nif00/EasyCompress/main/install.ps1?$(Get-Random)" | iex
```

The bootstrap downloads `VideoCompressor.ps1` to:

```text
%LOCALAPPDATA%\Programs\VideoCompressor\VideoCompressor.ps1
```

It downloads to a temporary file first, validates the result, then replaces the installed script. If an update fails but an older installed copy exists, it launches the existing copy instead of leaving the app broken.

Move this folder to a permanent location before registration. The context menu points to the script path, so moving the folder afterward will break the registered command.

Open the setup TUI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VideoCompressor.ps1
```

The setup TUI can:

- Install EasyCompress using the first menu choice.
- Install or fix FFmpeg.
- Register the Explorer context menu.
- Unregister the Explorer context menu.
- Remove old admin/HKCR entries from earlier versions.
- Refresh readiness checks on demand.

Direct register command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VideoCompressor.ps1 -Register
```

Direct unregister command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VideoCompressor.ps1 -Unregister
```

## Usage

1. Right-click a video file, such as `.mp4`, `.mkv`, `.mov`, or `.webm`.
2. Choose **Compress Video**.
3. Select resolution and compression level.
4. Enable trimming only if needed.
5. Click **Compress**.

The output is written next to the input file with a suffix such as `video_720p.mp4`.

To reopen setup from Explorer, right-click a file and choose **EasyCompress Settings**.

## Notes

- Setup and maintenance modes automatically request Administrator elevation.
- Normal right-click compression does not request Administrator elevation.
- Runtime logs are written to the system temp folder as `VideoCompressor-debug.log`, not to this project directory.
