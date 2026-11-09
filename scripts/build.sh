#!/usr/bin/env bash
# Direct-swiftc build used when SwiftPM / full Xcode is unavailable (see docs/IMPLEMENTATION_STATUS.md).
# Usage: scripts/build.sh [core|test|app|all]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/.build-manual/out
DEPS=$ROOT/.build-manual/deps
GRDB_TAG=v7.9.0
CLT=/Library/Developer/CommandLineTools
mkdir -p "$OUT" "$DEPS"

# Work around a stale root-owned $CLT/usr/include/swift/module.modulemap that redefines SwiftBridging.
# Harmless on a healthy toolchain; no system files are modified.
OVERLAY=$ROOT/.build-manual/overlay.yaml
if [ -f $CLT/usr/include/swift/module.modulemap ] && [ -f $CLT/usr/include/swift/bridging.modulemap ]; then
  : > "$ROOT/.build-manual/empty.modulemap"
  sed "s#__EMPTY__#$ROOT/.build-manual/empty.modulemap#" scripts/toolchain-fix/overlay.template.yaml > "$OVERLAY"
  VFS=(-vfsoverlay "$OVERLAY")
else VFS=(); fi

SWIFTC=(swiftc "${VFS[@]}" -target arm64-apple-macos15.0 -Onone -g)

build_grdb() {
  [ -f "$OUT/libGRDB.a" ] && return
  [ -d "$DEPS/GRDB.swift" ] || git clone --quiet --depth 1 --branch $GRDB_TAG https://github.com/groue/GRDB.swift.git "$DEPS/GRDB.swift"
  echo "» GRDB $GRDB_TAG (cached after first build)"
  "${SWIFTC[@]}" -swift-version 6 -parse-as-library -wmo -module-name GRDB -emit-module -emit-library -static \
    -D SQLITE_ENABLE_FTS5 -D SQLITE_ENABLE_SNAPSHOT -I "$DEPS/GRDB.swift/Sources/GRDBSQLite" \
    -emit-module-path "$OUT/GRDB.swiftmodule" -o "$OUT/libGRDB.a" \
    $(find "$DEPS/GRDB.swift/GRDB" -name '*.swift')
}

build_core() {
  build_grdb
  echo "» BraincellCore"
  "${SWIFTC[@]}" -swift-version 5 -enable-testing -parse-as-library -wmo -module-name BraincellCore -emit-module -emit-library -static \
    -I "$OUT" -I "$DEPS/GRDB.swift/Sources/GRDBSQLite" -emit-module-path "$OUT/BraincellCore.swiftmodule" -o "$OUT/libBraincellCore.a" \
    $(find Sources/BraincellCore -name '*.swift')
}

# Tests use swift-testing from the Command Line Tools (or Xcode). Runs the compiled test binary.
build_test() {
  build_core
  echo "» BraincellCoreTests"
  local FW=$CLT/Library/Developer/Frameworks
  local TESTMAIN=$ROOT/.build-manual/TestMain.swift
  cat > "$TESTMAIN" <<'SWIFT'
import Foundation
import Testing
@main struct TestMain { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }
SWIFT
  "${SWIFTC[@]}" -swift-version 5 -parse-as-library -module-name BraincellCoreTests -enable-testing \
    -F "$FW" -I "$OUT" -I "$DEPS/GRDB.swift/Sources/GRDBSQLite" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$CLT/usr/lib" \
    "$OUT/libBraincellCore.a" "$OUT/libGRDB.a" -lsqlite3 \
    $(find Tests/BraincellCoreTests -name '*.swift') "$TESTMAIN" -o "$OUT/BraincellCoreTests"
  "$OUT/BraincellCoreTests"
}

build_app() {
  build_core
  echo "» Braincell.app"
  local APP=$OUT/Braincell.app/Contents
  mkdir -p "$APP/MacOS"
  "${SWIFTC[@]}" -swift-version 5 -parse-as-library -module-name BraincellApp -I "$OUT" -I "$DEPS/GRDB.swift/Sources/GRDBSQLite" \
    "$OUT/libBraincellCore.a" "$OUT/libGRDB.a" -lsqlite3 \
    $(find Sources/BraincellApp -name '*.swift') -o "$APP/MacOS/Braincell"
  cp Sources/BraincellApp/Info.plist "$APP/Info.plist" 2>/dev/null || true
  echo "Built $OUT/Braincell.app"
}

case "${1:-all}" in
  core) build_core ;;
  test) build_test ;;
  app) build_app ;;
  all) build_test; build_app ;;
esac
