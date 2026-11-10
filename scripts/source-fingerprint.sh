#!/usr/bin/env bash
# Prints one hash of everything that affects the built app (content only, so committing or switching branches without
# changing the code doesn't count as an update). Used by install-macos.sh (to stamp the app) and by the app (to compare).
set -euo pipefail
cd "$(dirname "$0")/.."
git ls-files -c -o --exclude-standard --deduplicate -- Sources Package.swift scripts/build.sh scripts/install-macos.sh scripts/toolchain-fix \
  | while IFS= read -r f; do [ -f "$f" ] && shasum -a 256 "$f"; done | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1
