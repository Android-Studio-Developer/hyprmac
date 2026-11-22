#!/bin/sh
# Builds hyprwin for Windows (works from macOS/Linux too) into windows/dist/hyprwin-win-x64/.
# Needs the .NET 10 SDK. The result needs the .NET 10 Desktop Runtime on the PC, unless SELF_CONTAINED=1.
set -e
cd "$(dirname "$0")"
OUT=dist/hyprwin-win-x64
SC=${SELF_CONTAINED:-0}
FLAGS="-c Release -r win-x64 -p:DebugType=none"
[ "$SC" = 1 ] && FLAGS="$FLAGS --self-contained true -p:PublishSingleFile=false" || FLAGS="$FLAGS --self-contained false"
rm -rf "$OUT"
dotnet publish src/Hyprwin $FLAGS -o "$OUT"
dotnet publish src/hyprwinctl $FLAGS -o "$OUT"

echo "built $OUT"
