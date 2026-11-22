#!/bin/sh
# Builds Hyprmac.app, copies it to ~/Applications, and links `hyprmac` and `hyprmacctl`
# into ~/.local/bin (or $BIN_DIR). Re-run after pulling changes.
set -e
cd "$(dirname "$0")/.."
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
APP_DIR=${APP_DIR:-$HOME/Applications}
./scripts/bundle.sh
mkdir -p "$BIN_DIR" "$APP_DIR"
rm -rf "$APP_DIR/Hyprmac.app"
cp -R build/Hyprmac.app "$APP_DIR/"
ln -sf "$APP_DIR/Hyprmac.app/Contents/MacOS/hyprmac" "$BIN_DIR/hyprmac"
ln -sf "$APP_DIR/Hyprmac.app/Contents/MacOS/hyprmacctl" "$BIN_DIR/hyprmacctl"
echo "installed $APP_DIR/Hyprmac.app"
echo "linked $BIN_DIR/hyprmac and $BIN_DIR/hyprmacctl"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "add to your shell profile: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo "start the window manager: open \"$APP_DIR/Hyprmac.app\""
