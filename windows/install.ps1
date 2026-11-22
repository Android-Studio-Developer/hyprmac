<#
Installs hyprwin (Hyprland-style tiling for Windows) for the current user. No administrator rights:
everything goes to %LOCALAPPDATA%\Programs\hyprwin.

  irm https://kelus.org/hyprwin.ps1 | iex
  & ([scriptblock]::Create((irm https://kelus.org/hyprwin.ps1))) -Startup -Start

Options: -Startup        start hyprwin when you sign in
         -Start          start it now (it tiles your open windows right away)
         -NoModifyPath   never change your user PATH
         -Uninstall      remove hyprwin (your config in ~\.config\hyprwin stays)
Run it again to update. The download is checked against a SHA-256 sum before use.
Works in Windows PowerShell 5.1 (built into Windows 10 and 11) and PowerShell 7.
#>
param(
  [switch]$Startup,
  [switch]$Start,
  [switch]$NoModifyPath,
  [switch]$Uninstall
)

function Install-Hyprwin {
  param([switch]$Startup, [switch]$Start, [switch]$NoModifyPath, [switch]$Uninstall)

  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'  # Windows PowerShell 5.1 downloads far slower with the progress bar on
  $Version = '@VERSION@'
  $Sha256 = '@SHA256@'
  $Url = if ($env:HYPRWIN_URL) { $env:HYPRWIN_URL } else { "https://github.com/Android-Studio-Developer/hyprmac/releases/download/v$Version/hyprwin-$Version-win-x64.zip" }
  $LocalData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
  $InstallDir = if ($env:HYPRWIN_HOME) { $env:HYPRWIN_HOME } else { Join-Path $LocalData 'Programs\hyprwin' }
  $Programs = [Environment]::GetFolderPath('Programs')
  $StartupDir = [Environment]::GetFolderPath('Startup')
  $MenuLink = Join-Path $Programs 'hyprwin.lnk'
  $StartupLink = Join-Path $StartupDir 'hyprwin.lnk'

  if ([Environment]::Is64BitOperatingSystem -eq $false) { throw 'hyprwin needs 64-bit Windows.' }

  # A running hyprwin holds its files open; quit it (it puts windows back on screen first).
  $running = Get-Process -Name hyprwin -ErrorAction SilentlyContinue
  if ($running) {
    Write-Host 'Stopping the running hyprwin...'
    $ctl = Join-Path $InstallDir 'hyprwinctl.exe'
    if (Test-Path -LiteralPath $ctl) { & $ctl dispatch exit 2>$null | Out-Null; Start-Sleep -Seconds 2 }
    Get-Process -Name hyprwin -ErrorAction SilentlyContinue | Stop-Process -Force
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $pathParts = @(); if ($userPath) { $pathParts = $userPath -split ';' | Where-Object { $_ } }

  if ($Uninstall) {
    foreach ($p in @($MenuLink, $StartupLink)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    if ($pathParts -contains $InstallDir) {
      [Environment]::SetEnvironmentVariable('Path', (($pathParts | Where-Object { $_ -ne $InstallDir }) -join ';'), 'User')
    }
    Write-Host 'hyprwin removed. Your config in ~\.config\hyprwin and rices in %LOCALAPPDATA%\hyprwin were kept.'
    return
  }

  $temporary = Join-Path ([IO.Path]::GetTempPath()) ('hyprwin-install-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $temporary | Out-Null
  try {
    Write-Host "Downloading hyprwin $Version (about 50 MB)..."
    $archive = Join-Path $temporary 'hyprwin.zip'
    try {
      if ($Url -like 'file://*') { Copy-Item -LiteralPath ([Uri]$Url).LocalPath -Destination $archive }
      else {
        # Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub needs it. Nothing older is turned on.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
      }
    } catch { throw "could not download $Url" }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256) {
      throw 'the download does not match its SHA-256 sum; nothing was installed.'
    }

    $staging = Join-Path $temporary 'files'
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'hyprwin.exe'))) { throw 'the download is missing hyprwin.exe; nothing was installed.' }

    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $InstallDir) -Force | Out-Null
    Move-Item -LiteralPath $staging -Destination $InstallDir
    # Files from the internet carry a "blocked" mark that makes Windows ask before each start.
    Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Unblock-File
  } finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
  }

  $exe = Join-Path $InstallDir 'hyprwin.exe'
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($MenuLink)
  $link.TargetPath = $exe
  $link.WorkingDirectory = $InstallDir
  $link.Description = 'hyprwin: Hyprland-style tiling'
  $link.Save()
  if ($Startup) {
    $link = $shell.CreateShortcut($StartupLink)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $InstallDir
    $link.Save()
  }

  if (-not $NoModifyPath -and -not ($pathParts -contains $InstallDir)) {
    [Environment]::SetEnvironmentVariable('Path', (($pathParts + $InstallDir) -join ';'), 'User')
    $env:Path = "$env:Path;$InstallDir"
    Write-Host "Added $InstallDir to your PATH (new terminals see hyprwinctl)."
  }

  Write-Host ''
  Write-Host "hyprwin $Version installed to $InstallDir"
  Write-Host '  Start it: Start menu > hyprwin (it tiles your open windows right away).'
  Write-Host '  Main key is Alt: Alt+Enter terminal, Alt+1..9 workspaces, Alt+arrows focus, Alt+Shift+M quit.'
  Write-Host '  Config: ~\.config\hyprwin\hyprland.conf   Rices: hyprwinctl rice install <git-url>'
  if (-not $Startup) { Write-Host '  Start with Windows: run this again with -Startup.' }

  if ($Start) { Start-Process -FilePath $exe -WorkingDirectory $InstallDir }
}

Install-Hyprwin -Startup:$Startup -Start:$Start -NoModifyPath:$NoModifyPath -Uninstall:$Uninstall
