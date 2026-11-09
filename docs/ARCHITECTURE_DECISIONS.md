# Architecture Decisions

**ADR-001 Package layout.** `BraincellCore` (no UI imports) holds domain, persistence and services; `BraincellApp` is a thin SwiftUI shell. Keeps logic testable without a UI and enforces "views don't compute progression".

**ADR-002 GRDB records are the domain models.** Structs are `Codable` + GRDB records, with no SwiftUI dependency. A separate DTO layer would double the code for no current benefit.

**ADR-003 UUID primary keys (blob), camelCase columns.** Stable identifiers for sync/backup; GRDB's default UUID encoding.

**ADR-004 Skills are global rows linked to courses via `course_skills`.** Auto-reuse happens only inside one course (normalized name). Cross-course equivalence is an explicit `related` relation, never automatic.

**ADR-005 Cumulative assessments are a flag, not copied rows.** Their scope is computed (all course skills), so later-added skills are covered without edits.

**ADR-006 Hierarchy and prerequisites are separate relation kinds** with independent cycle checks.

**ADR-007 Archive instead of delete for skills/courses**, so future evidence, XP and attempts keep valid references.

**ADR-008 Documents deduplicated by (course, SHA-256);** re-import is a no-op. Original bytes are always preserved; failed extraction is flagged, never silently replaced by OCR.

**ADR-009 Direct-swiftc build script** because SwiftPM/Xcode are unusable on the dev machine (see IMPLEMENTATION_STATUS.md). `Package.swift` remains for Xcode users.

**ADR-010 ObservableObject (not `@Observable`)** for the app model, to avoid macro-plugin dependence on a limited toolchain.

**ADR-011 Question content is a JSON payload on immutable revisions.** Type-specific fields live in one validated Codable payload; the `questions` row holds mutable state (readiness, archive). Revision immutability is enforced by a SQLite trigger, not just convention.

**ADR-012 Readiness ≠ validity.** Valid JSON never implies a correct answer. `verified` requires an independent deterministic check (e.g. arithmetic re-derivation) or explicit user verification; everything else is `unverified` and excluded from trusted auto-grading.

**ADR-013 Responses are matched by requestId and deduplicated by canonical-JSON hash.** A response is never attached to a batch whose requestId differs; re-pasting (even reformatted) is a no-op; unusable responses are preserved for audit but never count as imported (partial unique index).

**ADR-014 Skill resolution on import:** exact normalized match in the same course → attach; near match → leave untagged and flag for review; no match → create in this course only.

**ADR-015 Code editor on AppKit text infrastructure, no third-party package.** The brief asks to test a maintained editor library for Python/C/Java first. That wasn't possible: SwiftPM is unusable on the dev machine (see status doc), so packages can't be resolved and tree-sitter based editors can't be built. A small `NSTextView` wrapper provides the required features, with pure, tested logic in Core (`SyntaxHighlighter`, `AutoIndent`, `BracketMatcher`). Highlighting uses layout-manager temporary attributes so it never touches undo history or stored text. Revisit with CodeEditSourceEditor once a real Xcode is available.

**ADR-016 Native LaTeX-subset renderer instead of a web view.** MathJax/KaTeX would need a WKWebView and bundled JS (and AI output into a script-capable view). A small parser (`Latex`) plus SwiftUI layout keeps rendering offline, inert and testable; anything outside the subset throws and shows its source rather than mis-rendering.

**ADR-017 Attempts are one-per-session-item and carry the pinned revision.** Retrying a question means a new session item, so history is a clean append-only log and no attempt can ever be rewritten or point at changed content.

**ADR-018 Practice records submissions only.** Evaluation (and therefore correctness, XP, mastery) is Milestone 5; until then the UI shows the reference without a verdict so nothing is graded by implication.

**ADR-019 Grades are append-only; “current” is a partial unique index.** Every change of mind (self-review, dispute, regrade, AI import) supersedes rather than edits. Evidence, XP corrections and snapshots all follow from the new grade inside one transaction (`ProgressionEngine.commit`), so they can never disagree.

**ADR-020 XP is reconciled, not blindly appended.** Each reward is a *subject* with a desired net amount; the engine appends an award or correction only for the difference. This makes retries idempotent and regrades auditable without special cases.

**ADR-021 Grade trust gates rewards, not participation.** Only trusted machine grades and AI grades can earn the correctness bonus; provisional/self-reported grades still count as (discounted) evidence. This keeps an unverified AI answer key from handing out rewards while letting the user unlock them by verifying.

**ADR-022 Mastery is a live computation over evidence; snapshots are history.** Recency decay means a stored value would go stale, so `ProgressionService.mastery` recomputes on read and `skill_estimates` records each grading event for later charts.

**ADR-023 FSRS ported, not reinvented; verification stated honestly.** The scheduler follows py-fsrs line by line (no fuzzing for determinism) and ships with a script to compare against the real library. Until that comparison is run, docs say “ported and cross-checked”, not “reference-verified”.

**ADR-024 The planner is a pure function of local evidence.** Plans depend only on mastery estimates, review states, assessment scope/importance/deadline, prerequisites and recent attempts; no AI, network or randomness (no fuzz), so the same data gives the same plan and every item can carry its reason.

**ADR-025 Exam scope is authoritative.** Cram never leaves an assessment's scope; related-but-out-of-scope prerequisites are surfaced as notes. AI-estimated importance is down-weighted and labelled.

**ADR-026 Coaching is advisory and rate-limited.** Coach events are persisted (cooldown, once per trigger+subject, dismissal), suppressed for timed sessions, and carry no authority over the question list.

**ADR-027 Focus time is a record, not evidence.** `focus_intervals` never feeds mastery or XP. Sleep counts as paused, background as active (the learner may be working in another window); open intervals are closed as interrupted on next launch rather than resumed.

**ADR-028 Backups are folders, not archives.** A folder with a manifest, per-file SHA-256 and a SQLite copy avoids implementing/trusting a zip extractor (no archive path-traversal class), is easy to inspect, and can be zipped by the user. Restore = validate → safety backup → stage → one atomic SQLite `backup(to:)` → migrate forward → move files.

**ADR-029 Draw our own meters.** AppKit-backed `ProgressView` ignored tints in light mode; `MeterBar` uses design tokens so both appearances match.

**ADR-030 Guard bindings handed to scenes.** SwiftUI scene APIs may write bindings every update. Never forward writes to a `@Published` property unless the value changed.

**ADR-031 Aggregate queries over per-row queries in anything the UI runs on load.** The scale test showed per-question/per-item lookups dominating at a few thousand rows; planner and insights now use grouped queries plus indexes, and heavy loads run off the main thread.

**ADR-032 Run learner code with Seatbelt, a launcher and a supervisor.** Docker/VMs are not available on a stock Mac and in-process interpreters share our address space. `sandbox-exec` with a deny-by-default profile (no network, reads limited to toolchains plus one run folder, writes only there, exec only the target) is the strongest isolation available without entitlements. Limits that the profile cannot express are set by a trusted `/bin/sh` launcher (`ulimit`) and a supervisor (wall time, output, resident memory, process-group kill). Known cost: `sandbox-exec` is deprecated, and memory is polled (RLIMIT_AS is not enforced on macOS). Execution is off until the learner opts in, and an absent sandbox means nothing runs (never a fallback to unsandboxed).

**ADR-033 A code-test key is trusted only after its reference passes.** `code_tests` grades are `trusted` only when the question was verified on its current revision by running the reference solution against its own tests; otherwise they are provisional. Runner problems leave the answer pending, never wrong.

**ADR-034 Symbolic equivalence is exact, narrow and honest.** Only polynomial/rational expressions over exact rationals are compared (cross-multiplication). Anything else is “unsupported” and routed to the learner rather than guessed; this avoids numeric-sampling false positives.

**ADR-035 Calibration informs, never changes.** The estimator is evaluated walk-forward (earlier evidence only) against a naive baseline; alternatives are reported as what-ifs and a suggestion needs ≥ 30 predictions and a clear margin. Changing constants stays a deliberate, versioned code change.

**ADR-036 Direct AI is the manual bridge with a different transport.** The same prepared request and the same import pipeline; the key lives in the Keychain; every send is confirmed with what leaves the device; a failure changes nothing. The `HTTPTransport` seam keeps it testable offline.

**ADR-037 The CramLab → Braincell rename keeps old data and wire formats working.** Code, modules, bundle ID and env vars (`BRAINCELL_*`) are renamed. On first launch the old `~/Library/Application Support/CramLab` folder is *copied* to `Braincell` (database files renamed; the old folder is left untouched), and a Keychain API key found only under `com.cramlab.api-keys` is copied to `com.braincell.api-keys`. Existing `.cramlabbackup` folders still restore (restore reads the manifest, not the name); new ones are `.braincellbackup`. The schema IDs `cramlab.questions.v1`, `cramlab.grades.v1` and `cramlab.topics.v1` are protocol identifiers, not branding, so they are unchanged: requests already sent to ChatGPT would otherwise stop importing.
