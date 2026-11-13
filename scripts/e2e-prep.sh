#!/bin/bash
# Two-process end-to-end run of the exam-preparation flow against scripts/mock-model-server.py (no network, no cost).
# Usage: scripts/e2e-prep.sh OUTDIR   — writes e2e-log-phase{1,2}.txt, screenshots and server.jsonl (counted model calls) into OUTDIR.
set -u
OUT="${1:?output dir}"; mkdir -p "$OUT"; rm -rf "${OUT:?}/data"; mkdir -p "$OUT/data"
APP="$(cd "$(dirname "$0")/.." && pwd)/.build-manual/out/Braincell.app/Contents/MacOS/Braincell"
LOG="$OUT/server.jsonl"; : > "$LOG"
python3 "$(dirname "$0")/mock-model-server.py" 8791 "$LOG" >/dev/null 2>&1 & SP=$!
sleep 1
for PH in 1 2; do
  BRAINCELL_DATA_DIR="$OUT/data" BRAINCELL_SNAPSHOT_DIR="$OUT" BRAINCELL_E2E=1 BRAINCELL_E2E_PORT=8791 BRAINCELL_E2E_LOG="$LOG" BRAINCELL_E2E_PHASE=$PH "$APP" >/dev/null 2>&1 & P=$!
  for i in $(seq 1 90); do sleep 2; kill -0 $P 2>/dev/null || break; done; kill $P 2>/dev/null
  echo "== phase $PH"; cat "$OUT/e2e-log-phase$PH.txt"
done
kill $SP; echo; echo "model calls by kind:"; sort "$LOG" | uniq -c
