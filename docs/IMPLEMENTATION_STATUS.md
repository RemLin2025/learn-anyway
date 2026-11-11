# Braincell — Implementation Status

**Current milestone:** M8 delivered in part, plus topic analysis (see “M8 implemented” and “M8 not built”). 211 automated tests plus a 44-check in-process model self-test pass. Real clicking, VoiceOver and a live API call were not possible in this environment (see “Not verified”).

## Build environment (important)
This machine has only the Command Line Tools (Swift 6.1.2, macOS SDK 15.5). **No Xcode, `xcodebuild`, or working SwiftPM:**
- `swift build` fails: the CLT's `libPackageDescription.dylib` doesn't match its module interface (even a trivial manifest fails to link).
- Plain `swiftc` fails on `import Foundation` because a stale root-owned `/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` redefines `SwiftBridging`.

Workaround (no system files modified): `scripts/build.sh` compiles with `swiftc` plus a VFS overlay that masks the stale modulemap, builds GRDB 7.9.0 from a pinned git clone, runs swift-testing, and assembles `.build-manual/out/Braincell.app`.

```
scripts/build.sh test   # build core + run all tests
scripts/build.sh app    # build Braincell.app
open .build-manual/out/Braincell.app   # launch via `open`; running the raw binary creates no window
```
Developer aid: `BRAINCELL_DATA_DIR=<dir>` isolates data; `BRAINCELL_SNAPSHOT_DIR=<dir>` (with `open --env …`) loads the demo workspace, writes PNGs of the app's own window and quits.
`Package.swift` is the intended Xcode entry point (File ▸ Open the folder). **It could not be verified here.** With a full Xcode, `swift test` and `swift run Braincell` should work. No `.xcodeproj` was generated.
Real fix on this machine: `sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` or reinstall CLT / install Xcode (needs your password; not done).

## Implemented
- Swift package layout: `BraincellCore` (domain, GRDB persistence, services; no SwiftUI) + `BraincellApp` (SwiftUI shell).
- GRDB database with foreign keys enforced, append-only migrations (`v1_foundation`, `v2_materials`), settings store.
- Tables: settings, courses, assessments, skills, course_skills, assessment_skills, skill_relations, documents, document_chunks, document_assessments.
- Courses, Quick Cram (+ conversion keeping the same row), assessments (deadline, cumulative), skills reused only within a course (normalized name), hierarchy / prerequisite / related relations with cycle prevention, assessment scope.
- Document import: PDF (PDFKit text with page refs), TXT/MD, pasted text; managed copy, SHA-256, dedupe per course, size/type/magic-byte validation, low-content/failed flagging, no orphaned files on failure.
- UI: sidebar nav (Home, Courses, Question Bank, Skills, Insights), Home with Quick Cram / Create Course / checklist, course detail (Assessments + scope editor, Topics tree with rename/archive/prerequisites, Materials with picker/drag-drop/paste), Settings (appearance), adaptive design tokens.

## M3 implemented
- Versioned question schema `cramlab.questions.v1` with 9 types, rich blocks (markdown/code/math/table/image with required alt text), per-type answer + evaluation specs, hints, solution, sources, metadata.
- Validation: structural + consistency with exact JSON paths (`questions[3].answer.correctIds`); deterministic verification for numeric answers via a safe arithmetic evaluator (`verificationExpression`). Readiness: Verified / Unverified / Needs review / Invalid. Only Verified may later drive trusted auto-grading; users can mark Verified (recorded as user verification).
- Revisions: edit appends a new revision; a DB trigger forbids updating a revision. Questions link to many assessments without duplication; families (duplicates), skill tags, archive, saved filter views, search/sort/filters (course, assessment, skill, type, difficulty, readiness).
- ChatGPT bridge (manual only): tasks split into batches of ≤10 with unique request IDs; request preview lists exactly what is shared and what is excluded; recommended clipboard vs file (12k-char threshold, overridable); explicit Copy / folder export; nothing opens ChatGPT. Import by paste/file/clipboard: size/count limits, fenced-JSON tolerance, schema-version and requestId checks (no silent mis-attachment), hash-based idempotency, exact-duplicate skipping, probable-duplicate/ambiguous-skill → Needs review, partial imports, atomic commit, original responses preserved, repair and continuation requests, state survives restart.
- UI: Question Bank (filters, saved views, preview with inert markdown, editor, bulk actions, context menu) and AI Task Center. Demo Workspace (clearly labelled) imports a 9-question fixture through the real pipeline.

## M4 implemented
- **Sessions** (`study_sessions`, `session_items`, `attempt_drafts`, `attempts`): items pin the question *revision* at creation; drafts are an idempotent upsert (debounced autosave + flush on navigation/exit/quit); submission creates one immutable attempt per item (DB trigger blocks updates; resubmitting returns the same attempt); skipping keeps the draft; hints are progressive and recorded; active time is tracked per item (timer pauses on pause/inactive window); unfinished sessions resume from Home after relaunch.
- **Practice UI**: Focus layout (flashcard, single/multiple choice with 1–9 keys, short answer, numeric) and Workspace layout (code tracing, coding, long-form, derivation/proof) with resizable regions and a collapsible Help panel (hints, sources, skills). Keyboard: ⌘↩ submit, ⌘[ / ⌘] previous/next, ⇧⌘] skip, ⇧⌘H hint, Space reveals a flashcard. Entry points: Question Bank (selection or everything shown), question preview, course, assessment, Home resume.
- **After submit**: reference answer + solution shown *without a verdict*; grading/XP are Milestone 5.
- **Code editor** (AppKit `NSTextView`): Python/C/Java highlighting, line numbers, auto-indent, bracket matching, undo/redo, find bar, no smart-quote/“autocorrect”, configurable font size (Settings), read-only mode, starter code, multi-file data model with tabs. **Run Tests is disabled** with an explanation; Since M8, Run Tests/Try it use `SandboxedCodeRunner` when the learner opts in; otherwise `UnavailableCodeRunner` and nothing executes.
- **Math**: offline LaTeX-subset parser (fractions, roots, scripts, sums/integrals with limits, Greek/symbols, delimiters, text). Display math is typeset natively; inline `$…$` is shown as Unicode (so text wraps); unsupported LaTeX falls back to its source. Works in questions, choices, hints, solutions, flashcards and a live preview of the learner's own written answer.

## M5 implemented
- **Evaluation engine** (pure, independent of UI): exact (case/whitespace/punctuation-normalised; multi-line, case-sensitive for code output), choice (partial credit for multiple select), numeric with tolerance and fractions/scientific notation (unreadable input → *needs review*, never “wrong”), flashcard/self-review/AI-rubric → **pending**.
- **Evaluations** are append-only: a new grade supersedes the old one (`supersedesId`, one active per attempt via a partial unique index); self-review, dispute, “I disagree”, regrade and AI grades all preserve history. Evaluations record which question revision they graded against.
- **Learning evidence, four-dimension mastery, evidence quality, Unknown/Preliminary/Moderate/Strong** (see docs/MASTERY.md). Append-only `skill_estimates` snapshots.
- **XP ledger** with unique event keys, auditable corrections, skill allocation that sums to the course total, levels, and milestones (first answer, skill/course levels).
- **Answer-change handling:** attempts graded against an older revision are detected (`affectedAttempts`) and can be regraded (adds a new grade + ledger corrections). Verifying a question regrades its automatic grades.
- **ChatGPT grading batches** (`cramlab.grades.v1`): pick pending answers of one course → request with attempt IDs, revision IDs, statements, rubrics, reference solutions and the learner’s responses (disclosed in the review sheet) → import validates request ID, that each attemptId belongs to the batch, score/rubric ranges, duplicates, and refuses to overwrite machine-graded attempts; idempotent; raw text preserved; ungraded answers stay pending.
- **UI:** grade panel after submit (verdict, trust, XP, self-review with rubric/flashcard ratings, disagree menu), real session summary, Skills screen (level/XP, overall + four dimensions, confidence, evidence quality, recent evidence, practise this skill), course XP chip, regrade banner, Grade Pending… sheet, grade import routing.

## M6 implemented
- **Spaced repetition:** FSRS-6 port with persisted review states/logs (see docs/SPACED_REPETITION.md for exactly what is and isn't verified). Due reviews are listed per course and on Home; “Review now” starts a review-only session.
- **Study planner (offline, deterministic):** *Cram* for a chosen assessment and *Mastery* mode. Cram stays inside the exam's scope and weighs importance (instructor-confirmed > user-adjusted > AI-estimated, the last labelled as a guess), deadline urgency, demonstrated gaps, uncertainty, and weak prerequisites (prerequisite first, dependent waits; out-of-scope prerequisites are mentioned, never silently added). Due reviews come first (30% of time in cram, 50% in mastery); the rest rotates across the highest-priority skills with a per-skill cap and never repeats a skill back to back when alternatives exist. Time budgets use per-type estimates refined from your own answer times. Every item has a plain-language reason. User constraints: focus/exclude skills, excluded questions, max difficulty, question types, budget; items can be unchecked before starting.
- **Diagnostic:** one short question per skill with no evidence (quick types only, ≤10), labelled as early signals; results stay Preliminary.
- **Recommendation on Home:** nearest upcoming exam (cram) else keep learning (mastery), from local evidence.
- **Mistakes & history:** observed mistakes (with times missed, hints, confidence), weak spots, breakthroughs (unassisted success on a *different* question after recent trouble), reflections. Shown under each skill; the full Learning History screen is Milestone 7.
- **Coach (local triggers only):** repeated misses, many hints, breakthrough, confident miss. One suggestion at a time, 10-minute cooldown, once per trigger+subject per session, never in timed sessions, switchable off in Settings, always dismissible, never changes or skips a question.
- **Minimal metacognition:** the optional “How sure are you?” appears only for difficult (≥4) questions, questions missed before, or skills with two recent misses; optional end-of-session note. Settings can turn confidence checks off.
- **“I'm stuck”:** four options using prepared hints and prerequisite links; if still stuck, a help request to copy into ChatGPT (you see exactly what's included; the reference solution is never included). Hint use is recorded.
- **UI:** course Plan tab, Home suggestions/due reviews, “Why this question?” + kind badge in practice, coach banner, Stuck? menu, session reflection, mistakes in Skills, Settings toggles.

## M7 implemented
- **Focus timer (Pomodoro):** 15/25/45/custom focus, short and long breaks, pause/resume/stop; toolbar popover available everywhere, compact chip during practice, optional menu-bar timer, ⌥⌘F/⌥⌘P shortcuts. Time while the app is in the background counts as focus; time the Mac is **asleep counts as paused**. Active vs paused seconds are persisted with a heartbeat; an interval left open by a quit/crash is closed as *interrupted*, never silently resumed. When an interval ends mid-question the learner chooses *Finish this question* or *Take a break now*; nothing is submitted or discarded. Optional notification (asks macOS first). Focus time never creates evidence, XP or mastery (tested).
- **Insights:** exam coverage (never a grade prediction; “Not enough evidence” states), study time (30 days), due-review forecast, skill trend charts, XP ledger (every award and correction) and milestones, a combined Learning History timeline (mistakes, notes, breakthroughs, milestones), recent sessions and answers. Charts via Swift Charts.
- **Skill visualisation:** list and a pannable/zoomable **map** (hierarchy + dashed prerequisite edges, collapsible branches, mastery/confidence styling, keyboard-focusable nodes).
- **Backup/restore:** a portable `.braincellbackup` folder (consistent SQLite copy, every imported original, manifest with SHA-256 checksums). Restore validates first (format, schema not newer than the app, safe paths under `Documents/` only, no symlinks, checksums, SQLite integrity + foreign-key check), saves a safety backup of current data, stages and re-verifies files, replaces the database in one SQLite backup operation and migrates forward. Rejections leave current data untouched (tested for tampering, traversal, symlinks, missing files, newer schema, wrong format).
- **Polish:** real onboarding checklist (every step actionable and detected from data), empty states for all listed cases, Go menu ⌘1–⌘6, MeterBar replacing AppKit progress bars (they ignored tints in light mode), custom code for light/dark via adaptive tokens.

## Topic analysis (added after the M8 audit)
AI Tasks → New Task → Topic Analysis. The request lists the course’s existing skills and assessments plus the document extracts you tick, and states what is *not* shared. The reply (`cramlab.topics.v1`) is **staged, not applied**: the review screen shows each proposed skill as New, Already have, or Ambiguous (similar to an existing skill), with its parent, prerequisites and assessment coverage. You can rename, decline, add as new or merge an ambiguous one into an existing skill (undecided ambiguous items are left out). Apply runs in one transaction; it never deletes anything, so existing skills keep their mastery, XP and answers. Cycles, unknown references and unknown assessment names are skipped with a reason. Re-pasting or re-applying adds nothing. Skills from other courses never match. The reply is also routed correctly when it arrives through Direct AI requests (`importAny`). Tested with 9 core tests (disclosure, staging changes nothing, classification, creation/links/coverage, mastery untouched, idempotence, decisions, cycles, invalid entries, routing, cross-course). **Not clicked:** the task sheet and review screen were compiled and their logic tested, but never driven with a mouse or seen on screen.

## M8 implemented
Each item is independent and off by default; the offline workflow is unchanged when they are off.

- **Sandboxed code execution (Python, C, Java).** Opt-in in Settings. Code runs in a child process under macOS Seatbelt (`sandbox-exec`, deny-by-default profile): no network, no reads outside the toolchain and one per-run temp folder, writes only inside that folder, no process creation except the compile step, minimal environment (no secrets), rlimits set by a trusted launcher (CPU, file size, no core files, open files), and a supervisor that enforces wall time, an output cap and a resident-memory cap and kills the whole process group. The run folder is always deleted. File names are validated. If no toolchain or sandbox is found, nothing runs and the UI says why.
- **`code_tests` questions.** Coding questions can carry 1–20 stdin→stdout tests (some hidden). The validator requires a reference solution; **Verify Tests** runs that reference against its own tests, and only then is the key trusted. Learners get Run Tests (per-test pass/fail, hidden tests reveal nothing), Try it (free run with stdin), and automatic grading on submit: score = share of tests passed, compile error = 0, runner problems leave the answer pending instead of marking it wrong.
- **Symbolic math (`symbolic` for short answer).** Exact equivalence of polynomial and rational expressions (+ − × ÷, integer powers, implicit multiplication, simple LaTeX) by cross-multiplying exact rational polynomials. Functions, roots, π and non-integer powers are *unsupported* and unreadable input is *needs review*: both go to the learner, never to “wrong”. Key expressions are validated at import.
- **Estimator calibration.** Insights shows a walk-forward check: each answer is predicted from earlier answers only; reports Brier error vs a plain-average baseline, binned predicted-vs-actual, bias, and three what-if variants. Needs ≥ 30 predictions before it says anything; a suggestion appears only for a clear margin and **nothing is ever applied automatically**.
- **Direct AI API (Anthropic Messages API).** Opt-in; key in the macOS Keychain (never the database or backups); a disclosure in Settings and a confirmation naming the character count and model before every send. The reply goes through the same parse/validate/import as a pasted reply, and a failed call leaves the batch untouched so the manual route still works. Verified only against a mock transport.

## M8 not built (and why)
- **On-device AI:** Apple’s Foundation Models framework is not present on this Mac (macOS 15.3, no `FoundationModels.framework` in the SDK). Nothing was written against an API that could not be compiled. Revisit on macOS 26+; the seam is the same “prepared request → reply text → import pipeline” used by `DirectAIService`.
- **Advanced question interactions** (drag-and-order, matching, diagram labelling): deferred. They need new question types, schema versions and accessibility design, and would not be verifiable without interactive testing.
- Other languages, per-question resource limits, and a symbolic checker for trigonometry/roots/calculus.

## Definition of done — status
| Requirement | Status |
|---|---|
| Native macOS 15+, local, no accounts/backend | ✅ (SwiftUI/AppKit, SQLite) |
| Courses, assessments, Quick Cram | ✅ tested |
| PDF/text import and topics | ✅ (no OCR, no PowerPoint) |
| Manual ChatGPT export/import | ✅ tested; **never exercised with a real ChatGPT reply** |
| All question types render and accept answers | ✅ snapshots + tests; not click-tested |
| Python/C/Java editing and saving | ✅ editor self-test; no execution by design |
| No fabricated correctness | ✅ tested |
| Sessions/attempts persist | ✅ tested across a DB restart |
| XP and mastery independent; 4-D mastery | ✅ tested |
| Offline adaptive recommendations | ✅ tested |
| Deadline and long-term study | ✅ cram/mastery planner |
| Focus sessions and learning history | ✅ (focus UI untested by clicks) |
| Backup and restore | ✅ service tested; UI dialogs not clicked |
| Accessibility | ⚠️ labels, shortcuts, adaptive colours; **no VoiceOver testing** |
| End-to-end COMP 211 scenario | ✅ automated (`COMP211JourneyTests`) |
| Tests pass; limitations documented | ✅ |

## Verification round 2 (open items from the M7 report)
| Item | Result |
|---|---|
| **FSRS vs py-fsrs** | **Now checked against the library authors' own hard-coded test expectations** (read from `tests/test_basic.py`; the library's code was *not* executed): the 13-step interval history `[0,2,11,46,163,498,0,0,2,4,7,12,21]`, memory state after 6 reviews (stability 53.62691, difficulty 6.3574867, tol 1e-4), difficulty floor 1.0, all learning/relearning-step cases, no-step configurations. All pass. Running the library itself to generate full vectors is still not done (see docs/SPACED_REPETITION.md). |
| **Restore of an older-schema backup** | Tested: a genuine v6 database restores into a v9 install, is migrated forward, new tables work, safety copy valid. |
| **Large libraries** | `ScaleTests` (1,500 questions / 2,500 answers by default; `BRAINCELL_SCALE_QUESTIONS`/`_ATTEMPTS` to scale up). First run found the cram plan, mastery plan and Home recommendation at ~470 ms and the sessions list at ~515 ms (per-question / per-item queries). Fixed with aggregate queries and a v10 migration (indexes on `xp_events.attemptId`, `attempts.submittedAt`, active evaluations): planner ≈ 57 ms, sessions ≈ 3 ms. At **6,000 questions / 10,000 answers** every service call is ≤ ~190 ms except the breakthrough scan/timeline (~650 ms, now capped to the 150 most recent unassisted wins). Home and Insights now load off the main thread. Single answer grading ≈ 10–21 ms. **Only services were timed**, not SwiftUI rendering of huge lists (the Question Bank list is not virtualised/paginated beyond SwiftUI's own laziness). |
| **UI click-through** | **Not done: computer-use access was declined.** Substituted an **in-process self-test** (`BRAINCELL_SNAPSHOT_DIR=… BRAINCELL_SELFTEST=1`) that runs the real `PracticeModel`, `FocusModel` (real timers, simulated sleep/wake notifications) and the backup/restore logic inside the running app: 34 checks pass (autosave debounce, pause/resume, submit lock, skip keeps work, hints, self-review, flashcard→FSRS, finish/summary, exit/resume with draft, countdown, pause, sleep counts as paused, stop, a full 60 s break completing with the end prompt, no evidence/XP from focus, create/restore/safety backup, refusal of a non-backup). This does **not** exercise the SwiftUI view wiring (button hit-targets, popovers, NSOpenPanel/NSAlert). |
| **Accessibility** | With `accessibilityEnhancedUserInterface` forced on, SwiftUI builds its tree and an audit found **four genuinely unlabelled controls** (Quick Cram field, Create Course field, Search field, Preview-math switch); all now have labels, and sheet fields were labelled too. Caveat: SwiftUI exposes the contents of scroll views only partially to this kind of query (e.g. practice focus layouts list 4–5 elements), so “0 unlabelled” on those screens is **not conclusive**. VoiceOver itself was not run. |
| Package.swift / Xcode | Still unverifiable on this machine. |
| Real ChatGPT reply | Still not exercised. |
| Notification delivery, menu-bar item appearance | Not verified (notification authorisation and a visible menu-bar extra need an interactive session). |

## Verification performed
- **M8:** 199 tests pass. New: an adversarial sandbox suite (python/C/Java cannot read files outside the run folder, write outside it, reach a local TCP listener or DNS/UDP, spawn subprocesses, signal the parent, follow symlinks/hardlinks, chmod, or see environment secrets; infinite loops are killed in all three languages with no leftover processes; fork bomb harmless; output flood capped; memory hog killed; disk-fill stopped; crashes reported; run folders removed; concurrency; no toolchain → nothing runs), the code-test flow (validator, reference verification, grading, partial credit, compile errors, unavailable runner, idempotence, Java end to end), the symbolic checker (expansion, factoring, rational functions, notation variants, unsupported/unreadable inputs, size bounds), calibration (no look-ahead, ordering, no suggestion on thin data), and the direct API client against a mock transport (disabled/no-key sends nothing, request shape, key only in the header, replies validated by the normal import, HTTP/network/shape failures, model setting, Keychain round trip). The in-process self-test (44 checks, all pass) drives the real models: code execution off/on, Verify Tests, Run Tests 4/4 and 0/4, hidden test, `/etc/passwd` blocked, auto-grading with XP.
- **150 tests pass** (`scripts/build.sh test`); the M1–M2 set below plus validator (all 9 types, readiness levels, exact paths, limits, bool/number bridging), arithmetic evaluator, question service (multi-assessment reuse, revision immutability, edit/verification, search/filter/saved views, duplicate/bulk tags) and AI bridge (batching, prompt contents/disclosure, file export safety, restart survival, import happy path, fenced JSON, malformed/unsupported/missing/wrong requestId, idempotent re-paste, cross-response duplicates, partial + repair loop, continuation, review flags, skill scoping, limits, atomicity), demo workspace: persistence reopen, migration upgrade preserving data, FK enforcement, settings, the COMP 211 scenario (Midterm 2 → Midterm 1 → cumulative Final, no duplicate skills, later skills join cumulative scope), cross-course non-merge, cycle rejection, Quick Cram conversion, PDF import (pages/hash/managed copy), blank-page flagging, duplicate import idempotency, rejection of unsupported/fake files, cascade behaviour, skill tree flattening.
- App builds and launches via `open`. Window snapshots (Home, Course, Question Bank with preview, AI Tasks) were captured and inspected; this caught and fixed a cramped filter bar.
- M7 screens (Insights, skill map, light-mode Home/Skills/Insights) were captured and inspected. **A real bug was found this way:** `MenuBarExtra` writes its `isInserted` binding on every update and the `@Published` setter fires on equal values, so the scene body re-evaluated forever and starved the main thread; fixed by only forwarding real changes. Light mode also exposed that AppKit `ProgressView` ignores our tint; replaced by `MeterBar`.
- M6 screens (Plan tab with reasons and checkboxes, Home suggestion + due review, planned practice item with Repair badge and coach banner) were captured and inspected.
- M5 screens (session summary, graded and pending result panels, Skills with four dimensions, grading task) were captured and inspected. A bug found by the tests was fixed: correction events must carry the original attempt’s id.
- Practice screens (flashcard, choice, numeric, tracing, coding, long-form, proof) were captured and inspected. An in-process self-test drove the real editor: Return auto-indent, typing, undo, and the autosave reaching SQLite all passed.
- Writing the demo fixture exposed a real validator bug (JSON `1` was treated as boolean, rejecting every difficulty-1 question); fixed with a regression test.

## Not verified
- **M8:** no click-through of the new UI (the user declined computer-use access): Settings sections, Run Tests/Try it panels, “Run the tests and grade”, Verify Tests, the Insights calibration card, the request sheet’s “Send to Anthropic API…” confirmation. **No live Anthropic API call was ever made**; the client is tested with a mock transport only, so real headers/model availability/billing behaviour are unconfirmed. Calibration has only been run on synthetic and demo data, not on a real learner’s history.
- **Sandbox limits:** `sandbox-exec` is deprecated by Apple though functional on this macOS; memory is enforced by 50 ms resident-size polling from outside (RLIMIT_AS is not enforced on macOS), so a very fast allocator can briefly exceed the cap; `/System` and toolchain folders are readable (not secrets); results come from one macOS version. Passing the reference solution’s tests shows the tests and reference agree, not that the tests are complete.
- The AX scan reports a few unlabeled `AXButton`s of 12-px width: these appear to be scroll bar parts, not content controls, but VoiceOver was not run.
- M6 clicks: Build plan / Quick diagnostic / Start session / Review now / Adjust plan, the Stuck? menu and sheets, tutor-request copy, confidence buttons, reflection fields, Settings toggles. The “Why this question?” popover was not captured.
- **Accessibility:** an in-process audit of the live accessibility tree was inconclusive (SwiftUI only builds it when an assistive technology is running, so it saw a single group). A static scan found no icon-only buttons without labels. VoiceOver, Full Keyboard Access and Reduce Motion (the app has no custom animations) were not exercised.
- M7 clicks (model logic now covered by the in-process self-test, view wiring not): Focus popover/menu-bar item/end-of-interval banner, notification delivery, Insights interactions, skill map pan/zoom/collapse, Create/Restore Backup dialogs, checklist navigation.
- **FSRS vs the real py-fsrs library** (see docs/SPACED_REPETITION.md): not run.
- M5 clicks: self-review steppers/buttons, “I disagree” menu, Grade Pending sheet, grade import sheet, regrade banner. The grading request/import sheets were never opened (only their logic is tested).
- Practice flow clicks (submit/reveal panel, pause overlay, session summary, resume card on Home), editor bracket highlight, find bar, line-number ruler while scrolling long files, focus-mode screens after submission. Flashcard/short-answer/numeric screens were only seen empty.
- Interactive UI behaviour: sheets (request review, import, new task, editor), file pickers, clipboard buttons and folder export were not clicked through (snapshots capture only the main window). Light mode, keyboard navigation and VoiceOver untested.
- No real ChatGPT output has been imported; fixtures are hand-written to the schema. The acceptance wording “real structured AI outputs” still needs a manual check with an actual ChatGPT reply.
- `Package.swift` / Xcode build. Persistence "across restart" is tested at the service level only.

## Rename (CramLab → Braincell)
Done across code, docs, scripts and bundle ID (ADR-037). 211 tests and the in-process self-test pass on the renamed build. **Not verified:** migration against a real existing CramLab data folder and a real Keychain entry (only temp-folder and temp-service tests); opening the app via Finder after the rename; `Package.swift`/Xcode build. `graphify-out/` was generated before the rename and still shows old names until rebuilt.

## UI redesign
Shared tokens, `Card`, `PageHeader`, `PrimaryButtonStyle`/`SecondaryButtonStyle` (applied app-wide from `RootView`), `AppFieldStyle`, `RingMeter` and a dark collapsible `SidebarView` live in `DesignSystem.swift`. Home is redesigned (suggested-next hero, course cards with level/XP); practice bars use the surface style. Checked from rendered snapshots and the self-test, never clicked. Second pass: added `SearchField`, `ListRowLabel`, `fieldSurface()` (TextEditor/text areas) and `dialogSurface()`; restyled Courses lists/tabs, Question Bank, Practice (prompt card, choice rows, bars) and all sheets. Verified by build, 211 tests and rendered snapshots (dark and light), never clicked. Still native: pickers/menus in the Question Bank filter bar (it scrolls horizontally), Settings segmented picker, grouped Forms inside sheets, system alerts.

## AI gateway and AI settings
`Sources/BraincellCore/Gateway/` (migration v11) routes model requests: provider registry, Keychain-held keys, OpenAI-compatible + Anthropic + Ollama LLM adapters, task routing (task override → capability default → fallback), bounded retries, usage log, cost estimates (unknown ≠ zero), budgets enforced in the gateway. Settings has General + four AI pages. The AI Tasks send button uses the gateway when a route resolves; the legacy Anthropic-direct path and the manual ChatGPT bridge are unchanged. **Operational: LLM only.** Image, video, TTS, STT, parsing, search, fetch, embeddings and vision have registry/UI entries but no adapters. MiniMax, TokenDance, SiliconFlow, GLM, Qwen and Azure are listed as not supported. Moonshot and Gemini endpoints are unverified. Tested with mocked transports (25 tests); never run against a real provider, and the new screens were checked from rendered snapshots only, never clicked.

## Library and course Materials
Migration v12 rebuilds `documents` (ids and columns preserved; `courseId` now optional; adds folder, name, favorite, modified and soft-delete fields) and adds `library_folders` plus course soft-delete columns. The Library page and each course's Materials tab are one browser (`LibraryBrowser`) over the same records: a file belongs to one course folder tree or to the global Library, moves change that record, nothing is copied. Course deletion is a seven-day soft delete (reuses the archived exclusion every study screen honours); expiry runs at launch via an injectable clock. **Deliberate deviation:** purging a course removes its materials and folders only, because learning evidence tables are `ON DELETE RESTRICT` (append-only); the hidden course row and its study history stay. The Plan tab and `StudyPlanView` were removed (the planner behind Home's recommendation is unchanged). Not built: drag-to-move between folders (use Move…), Reveal in Finder shows the stored `original.ext` name, video/other files are previewed by Quick Look only. Checked by 13 new tests and rendered snapshots; interactions (menus, drag-drop import, panels, Quick Look sheet) were never clicked.

## Home chat assistant
Home is a persistent chat (migration v13: `chat_conversations`, `chat_messages`, `agent_actions`, `study_plans`). `AgentRunner` (BraincellCore/Agent) builds the prompt, calls the model through `AIGateway` (new routable task `chatAssistant`, so Settings → AI Workflow/Model Services control it), parses one JSON tool call per reply, validates it against `AgentRegistry`, enforces approval for every write/destructive tool, runs it against the existing services, and records the real result. Tools: courses.list/get/create/rename/delete, assessments.create, library.search, materials.list/read/attachToCourse, questions.search/generate/save, insights.getWeakTopics, studyPlans.create/get, aiTasks.list, quickCram.start, ui.suggestActions/requestFiles. Question drafts are validated and previewed; Save commits through the existing import. Study plans are saved artifacts built by the existing `PlannerService`; there is no Plan page. Idempotency: one `agent_actions` row per (conversation, turn, tool, args); step budget 6 tool calls per request. **Not built:** streaming, native function-calling (tool calls are JSON in text, so any LLM works), model-written summaries of old history (older messages are dropped with a notice), the manual ChatGPT Bridge as a chat backend (it can't run tools; the UI says so). Verified by 22 tests with a scripted model over the real services, and by driving the real UI against a local scripted HTTP model; never run with a live hosted model.

## Known limitations / deferred
- No OCR; PowerPoint not supported (rejected with a clear message).
- **Not built:** a mock-exam mode (sessions can be flagged `timed`, which suppresses coaching, but nothing creates one), XP/level animations (optional), OCR, and PowerPoint import. The coach has no separate focus-interval trigger: the end-of-interval prompt (finish the question / take a break) covers that moment. Estimator constants are heuristics, not calibrated against a real learner. Math covers a LaTeX subset (no matrices/aligned environments); unsupported input shows its source.
- Request text for a batch is rebuilt each time it is prepared (the request ID never changes), so existing-question titles can differ slightly between views.
- UI target uses Swift 5 language mode; Core is compiled in Swift 5 mode by `build.sh` (the manifest requests the Swift 6 default for Core).

## Remaining work
On-device AI and advanced question interactions (M8, see above), a mock-exam mode, a Demo→real data cleanup, OCR, and the unverified items above. Also: first run in a real Xcode (Package.swift) and signing, if this is ever distributed beyond local use.

(Superseded plan text follows.)
M7 practice workspaces → M5 evaluation/XP/mastery (core MVP gate) → M6 adaptive learning → M7 release polish → M8 post-MVP.

## Settings redesign
- Settings is a destination inside the main window (`AppModel.settingsOpen`; ⌘, and the sidebar row open it); the separate `Settings` scene is gone.
- Model Services: lazy, debounced, cancellable model table (`ModelListModel`, `ModelCatalog.filter`), model inspector, custom price estimates stored in separate columns (migration v14) so provider prices never get overwritten.
- AI Workflow: new Pipelines view from `WorkflowPipeline` (real flows only); Model map kept; Fit uses `CanvasFit`. Task inspector has Overview / Configuration with prompt override.
- Usage: two primary cards, SQL aggregates (`UsageService.totals/slices/page/dailyTotals`).
- Not verified by hand: mouse clicks on every control, drag/pan feel, VoiceOver. Context window and live execution traces are not available in the data.

## In-app updates
- `scripts/install-macos.sh` stamps `SourceRoot` and `SourceFingerprint` (content hash from `scripts/source-fingerprint.sh`) into the installed app's Info.plist.
- On launch (toggle in Settings → General → Updates) `UpdateModel` compares the stamp with the source folder and, when the branch tracks a remote, runs `git fetch`. A bottom banner offers Update now / Later.
- Update now: optional `git pull --ff-only`, then the install script rebuilds in the background; when ready the app quits itself and the script swaps `/Applications/Learn Anyway.app` and relaunches. Failures leave the current app untouched and show the log tail.
- Verified: detection and banner (test bundle with a stale fingerprint). Not run end to end: the actual rebuild, swap and relaunch.

## Study assistant workflow (chat)
- Requests are role-based (`LLMRequest.messages`, merged/alternating for OpenAI-compatible, Anthropic and Ollama); instructions stay in `system`. Single-prompt callers are unchanged.
- Chats: search, edit (archives the old branch, restorable), regenerate, auto title (deterministic fallback, one model title, never over a rename), interrupted-work recovery on launch (migration v15).
- Exam workflow tools: `sources.status`, `sources.search` (ranked across all documents, with page provenance and coverage gaps), `studyMap.create/get` (verified source refs; instructor weight needs a quote found in the material; estimates carry no percentage; research rejected because no web tool exists).
- Stages shown are real tool/workflow steps. No streaming, no OCR/vision, no web research, no independent answer verification (questions stay "Unverified").

## Reasoning-aware practice generation (migration v17)

- **Source analysis** (`Assessment/SourceAnalysis.swift`): instructor practice questions and worked solutions are extracted in overlapping windows, cached by document content + analyzer version, resumable, and flagged partial/complete with extraction limitations. Manual-bridge routes pause as `awaitingImport`. No OCR: scanned pages are reported, not analyzed.
- **Style profile** (`Assessment/StyleProfile.swift`): inferred patterns (with confidence and references) are kept apart from user-provided exam settings; counts are never used as exam topic weights.
- **Planner** (`Assessment/GenerationPlanner.swift`): one plan per generation task (four modes), sliced per batch, tracked by slot across imports/continuations. Used by AI Tasks and Home chat via `AITaskService.createGenerationTask`.
- **Scope**: `assessment_config` includes/excludes are enforced at task creation and again at import.
- **Validation** (`Assessment/MathChecks.swift`): interval choices, structured checks (finite/joint PMF, geometric MGF), evidence rows. Schema v2 adds optional fields; v1 stays valid.
- **Exam simulation** (`Practice/ExamService.swift`): persisted selection, exam-wide clock, deferred feedback, idempotent submission.
- Not done: OCR, DOCX/PPTX, a general CAS, guided step-by-step work submission, per-step diagnosis.
