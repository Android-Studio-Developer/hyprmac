#!/bin/sh
# Builds the self-contained Windows zip and fills install.ps1 with its version and SHA-256.
# Output: dist/hyprwin-<version>-win-x64.zip and dist/hyprwin.ps1 (served at kelus.org/hyprwin.ps1).
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's/.*public const string Version = "\(.*\)";/\1/p' src/Hyprwin.Core/Defaults.cs)
SELF_CONTAINED=1 ./publish.sh
ZIP="dist/hyprwin-$VERSION-win-x64.zip"
rm -f "$ZIP"
(cd dist/hyprwin-win-x64 && zip -qr9 "../hyprwin-$VERSION-win-x64.zip" .)
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" install.ps1 > dist/hyprwin.ps1
echo "$ZIP  sha256 $SHA"
echo "dist/hyprwin.ps1 ready"
