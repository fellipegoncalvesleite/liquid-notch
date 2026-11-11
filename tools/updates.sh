#!/bin/zsh
# Signs Liquid Notch update files for Sparkle. See tools/updates/main.swift for the commands.
# The signing key lives in ~/.config/liquid-notch/update-signing.key, never in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/tools/liquid-notch-updates
if [[ ! -x $BIN || tools/updates/main.swift -nt $BIN ]]; then
  mkdir -p .build/tools
  swiftc -O -o "$BIN" tools/updates/main.swift
fi
exec "$BIN" "$@"
