# Braincell

Native macOS (15+) adaptive study app. Local-first (SQLite via GRDB), works offline, no account or API key. ChatGPT is used through a manual copy/paste/import workflow only.

## Build, test, run
This repo was developed on a machine with only the Command Line Tools (no Xcode, broken SwiftPM), so the verified path is a direct-`swiftc` script:

```
scripts/build.sh test                 # build core + run all tests
scripts/build.sh app                  # build .build-manual/out/Braincell.app
open .build-manual/out/Braincell.app    # launch (running the raw binary shows no window)
```
`Package.swift` is provided for Xcode (open the folder) but has **not** been verified. Data lives in `~/Library/Application Support/Braincell` (override with `BRAINCELL_DATA_DIR`). An existing `CramLab` data folder and Keychain key are copied over on first launch; the old folder is left as it was. *Load Demo Workspace* on Home gives a clearly labelled sample course.

## Docs
`docs/IMPLEMENTATION_STATUS.md` (what works, what is verified, what is not), `docs/ARCHITECTURE_DECISIONS.md`, `docs/MASTERY.md`, `docs/SPACED_REPETITION.md`.

## Developer aids (all inert unless their env vars are set)
* `BRAINCELL_DATA_DIR=<dir>` isolates data.
* `BRAINCELL_SNAPSHOT_DIR=<dir>` (use `open --env …`): loads the demo workspace, writes window PNGs of every main screen (dark and light) and quits.
* add `BRAINCELL_SELFTEST=1`: runs the in-process model self-test (practice, focus timer, backup) → `selftest-models.txt`; `BRAINCELL_AXONLY=1`: accessibility audit → `ax-audit.txt`.
* `BRAINCELL_SCALE_QUESTIONS` / `BRAINCELL_SCALE_ATTEMPTS`: size of the scale test (`scripts/build.sh test`).


## Optional features (Milestone 8)
All off by default; Braincell stays fully usable offline without them.
- **Run code in a sandbox** (Settings → Code execution): Python, C and Java, no network or file access, strict limits. Enables Run Tests, Try it and automatic grading of `code_tests` questions.
- **Algebra answers**: short-answer questions with `"method": "symbolic"` accept any algebraically equivalent polynomial/rational expression.
- **Calibration** (Insights): how well the mastery estimate predicted your later answers. Informational only.
- **Direct AI requests** (Settings): send a prepared request to the Anthropic API instead of copying it to ChatGPT. Key in the Keychain; confirmation before each send.
Not built: on-device AI (needs macOS 26 Foundation Models) and advanced question interactions. See `docs/IMPLEMENTATION_STATUS.md`.
