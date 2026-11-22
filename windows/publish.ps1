# Builds hyprwin into windows\dist\hyprwin-win-x64\ (needs the .NET 10 SDK: winget install Microsoft.DotNet.SDK.10).
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$out = "dist\hyprwin-win-x64"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
dotnet publish src\Hyprwin -c Release -r win-x64 --self-contained false -p:DebugType=none -o $out
dotnet publish src\hyprwinctl -c Release -r win-x64 --self-contained false -p:DebugType=none -o $out
Write-Host "built $out  (run $out\hyprwin.exe)"
