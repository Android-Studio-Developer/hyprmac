#!/bin/sh
# Regenerates Sources/HyprLua/Prelude.swift from shared/hl-prelude.lua (the source of truth).
set -e
cd "$(dirname "$0")/.."
{
  echo '// GENERATED from shared/hl-prelude.lua by scripts/sync-prelude.sh. Edit that file instead.'
  echo ''
  echo '/// Lua code loaded before a Hyprland Lua config: defines `hl` and records calls as hyprlang text.'
  echo 'let prelude = #"""'
  cat shared/hl-prelude.lua
  echo '"""#'
} > Sources/HyprLua/Prelude.swift
