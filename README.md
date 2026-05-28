# EasyCompress

A small Windows right-click tool for compressing videos with FFmpeg.

## Install

Run this in PowerShell:

```powershell
irm "https://raw.githubusercontent.com/Nif00/EasyCompress/main/install.ps1?$(Get-Random)" | iex
```

The installer downloads the app to:

```text
%LOCALAPPDATA%\Programs\VideoCompressor\VideoCompressor.ps1
```

It then opens the setup menu. Choose `1. Install` to install FFmpeg if needed and add the Explorer context menu.

To update later, open **EasyCompress Settings** and choose `6. Update EasyCompress`.

## Uninstall

Open the setup menu from the right-click **EasyCompress Settings** entry, then choose uninstall.

Or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\VideoCompressor\VideoCompressor.ps1" -Unregister
```

## Installer Script

The one-command installer is [install.ps1](install.ps1). It downloads the latest app script, replaces the installed copy only after a successful download, and launches the local copy.
