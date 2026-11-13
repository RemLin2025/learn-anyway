# Exam preparation implementation and verification

The provided brief describes a seven-step wizard, but this checkout has no such
view or “Analyze materials” control. Its existing course action sends a chat
request to `exam.prepare`, which ran the entire `StudyPrep` job without a review
boundary. Consequently, the reported Step 3 UI hang cannot be reproduced or
attributed to a particular view in this revision.

Verified existing infrastructure: Library-managed imports with extraction and
hashes; document-to-assessment references; gateway task routing, timeouts and
bounded retries; source-reference validation; stored study maps; topic/assessment
scope synchronization; generation batches with question validation and deduplication;
persisted preparation jobs and interrupted-job recovery. Existing topic analysis
and instructor question analysis have their own services. The new workspace uses
the preparation job and existing question-generation engine rather than duplicating
their storage.

## Changes

The native sheet offers Setup → Materials → Review → Generate from Home and the
course topic view. Chat's exam action opens this flow rather than bypassing review.
Setup reuses existing assessments, loads dates and saved instructions, and does not
invent deadlines. Materials are opt-in Library references, with upload/drop, course
and full Library browsing, previews, extraction status, separate type/relevance,
and nonblocking warnings for different numbered assessments in document names.
References can span assessments without duplicating document bytes. Classification
is learner-controlled; no automatic AI material suggestions are claimed.

Analysis reuses extraction, topic prompts, evidence validation and study-map
persistence. It includes selected-source problem-pattern analysis in the topic
request; this is a bounded excerpt sample, not a full-document instructor-bank
analysis. Pattern findings and uncertainty are reviewable. Review permits editing
names, objectives/subtopics, priority, adding topics and excluding topics. Approval
commits the included topics as the generation input. Only practice questions are
offered; guides, flashcards and schedules have not been added to this flow.

The assessment workspace stores selections, classification, instructions, draft
findings, exclusions, approval and question count. Meaningful job checkpoints are
retained. Closing requests cancellation, not background continuation. Pending import
files may finish their current extraction before cancellation is observed; their
Library copies remain available. Main-actor UI updates are operation-scoped and
late updates are ignored. Extraction and AI work run in detached tasks. Progress
shows service milestones, not timer-based percentages.

## Reliability fixes

- Failed question imports now pause the job instead of falling through to success.
  Empty/all-rejected results also pause, retaining earlier saved batches.
- Explicit retries receive a fresh bounded invocation budget; successful stages and
  batches are reused. Previously exhausted persisted budgets prevented recovery.
- Cached completed results retain completed status instead of leaving a running job.
- Source discovery errors are caught and persisted, including deleted selections.
- Empty extraction chunks do not count as readable material.
- Changed sources require another analysis and approval before generation.
- Changed approved topics invalidate the previous generation checkpoint.
- Native workspace IDs are not inserted as nonexistent chat foreign keys.
- Ambiguous document names cannot silently resolve to an arbitrary citation.

## Validation

Added regression coverage in `StudyPrepTests.swift` for the review boundary,
approval/edit/exclusion persistence, shared document associations, chat routing,
explicit retry after exhausted topic budgets, missing documents, ambiguous citations
and the cached completed status. Existing preparation tests continue to cover real
persistence, validation, source changes and failed-question recovery.

Executed: tree-sitter-swift syntax parsing of all 13 changed Swift files including
tests (zero syntax errors); `git diff --check` (pass). These are syntax and whitespace
checks, not compilation or behavioral tests.

Attempted: `swift test --filter StudyPrepTests`; blocked with `swift: command not
found`. This executor is Linux and has no Xcode/macOS SDK. The core also imports
PDFKit and CryptoKit, and the UI imports SwiftUI/AppKit, so installing a Linux Swift
toolchain alone would not enable native verification. No live model calls, native
screenshots, or UI behavior are claimed as verified.

On a macOS development machine, run `swift test` and `swift build`, then exercise:
new/existing assessments; shared and global Library files; import failures/scanned
PDFs; missing credentials and malformed model replies; topic edits and exclusions;
close/reopen during each model stage; changing/deleting a selected source; generation
failure after a saved batch; cached completion; question-bank navigation. Native
build, concurrency diagnostics and manual UI validation remain required before release.
