# Graph Report - cramlab  (2026-11-08)

## Corpus Check
- 109 files · ~111,856 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 3 file(s) not represented in the graph (top: (none) 1, .plist 1, .modulemap 1)

## Summary
- 2449 nodes · 7467 edges · 112 communities (86 shown, 26 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 1107 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Architecture Decision Records
- Snapshot & Self-Test Runner
- Symbolic Math
- Module Imports & Frameworks
- AI Bridge Tests
- Grading & Evaluation Service
- Insights View
- FSRS Scheduler
- GRDB Record Protocols
- Coach & Stuck Guidance
- Topic & Course Models
- LaTeX Rendering
- Practice Session Model
- Course Service
- Course Kinds & Item Status
- Direct AI & Keychain
- Database Migrator
- App Shell & Focus Model
- Practice UI Components
- Design System
- Courses View
- Questions & Revisions
- AI Task Center View
- Review Scheduling Tests
- Documents & Task Creation
- Learning History
- AI Task Service
- Progression Service
- Grade Trust & Evaluator
- Sandbox Exec Profile
- Topic Analysis
- Code Runner
- Topic Review Views
- Process Supervisor
- App Model
- Planner & Math Errors
- Output Comparison
- Mastery Estimator
- Planner Tests
- Prompt Builder
- SandboxRunnerTests cluster
- .create() cluster
- ReviewService.swift cluster
- App cluster
- CaseIterable cluster
- fsrs_vectors.py cluster
- QuestionService.swift cluster
- SkillMapView.swift cluster
- .deleteAssessment() cluster
- FocusTimer cluster
- Choice cluster
- MathView.swift cluster
- .filterControls cluster
- GradingViews.swift cluster
- .importResponse() cluster
- BackupService.swift cluster
- AdaptiveViews.swift cluster
- ClosedRange cluster
- StudyPlanView.swift cluster
- AITaskError cluster
- MasteryDimension cluster
- rejected cluster
- ArithmeticEvaluator.swift cluster
- QuestionValidator.swift cluster
- SettingKey cluster
- Context cluster
- Calibration.swift cluster
- AITaskService.swift cluster
- .report() cluster
- CoachTests cluster
- .peekSchemaVersion() cluster
- .importFile() cluster
- CodeVerificationService cluster
- FocusTimer.swift cluster
- .init() cluster
- CodeRunViews.swift cluster
- FocusViews.swift cluster
- CustomStringConvertible cluster
- .takeBreak() cluster
- .clock() cluster
- BackupError cluster
- SyntaxHighlighter.swift cluster
- HistoryAndStuckTests cluster
- overlay.template.yaml cluster
- EditorLogic.swift cluster
- ColorScheme cluster
- .defaultStorage() cluster
- SidebarItem cluster
- GradeImport.swift cluster
- CourseError cluster
- DocumentError cluster
- RunTermination cluster
- Comparable cluster
- NSApplication cluster
- NSTextViewDelegate cluster
- CodeLanguage cluster
- .init() cluster
- NSCoder cluster
- build.sh cluster
- AssessmentKind cluster
- CodeToolsTests cluster
- EvaluationState cluster
- CodeVerification cluster
- Phase cluster
- EvalError cluster
- .init() cluster
- .clock() cluster
- TransferMethod cluster
- Severity cluster
- Package.swift cluster

## God Nodes (most connected - your core abstractions)
1. `Rig` - 89 edges
2. `PracticeModel` - 65 edges
3. `AppModel` - 63 edges
4. `AppDatabase` - 61 edges
5. `QuestionSpec` - 58 edges
6. `Question` - 57 edges
7. `Assessment` - 55 edges
8. `Skill` - 55 edges
9. `AITaskService` - 54 edges
10. `Attempt` - 54 edges

## Surprising Connections (you probably didn't know these)
- `.hasPython` --references--> `SandboxedCodeRunner`  [INFERRED]
  Tests/CramLabCoreTests/SandboxRunnerTests.swift → Sources/CramLabCore/Execution/SandboxedCodeRunner.swift
- `CodeTestsFlowTests` --calls--> `SandboxedCodeRunner`  [INFERRED]
  Tests/CramLabCoreTests/CodeTestsFlowTests.swift → Sources/CramLabCore/Execution/SandboxedCodeRunner.swift
- `SandboxRunnerTests` --calls--> `SandboxedCodeRunner`  [INFERRED]
  Tests/CramLabCoreTests/SandboxRunnerTests.swift → Sources/CramLabCore/Execution/SandboxedCodeRunner.swift
- `EstimatorTests` --calls--> `HeuristicMasteryEstimator`  [INFERRED]
  Tests/CramLabCoreTests/ProgressionTests.swift → Sources/CramLabCore/Learning/MasteryEstimator.swift
- `CramLabApp` --implements--> `App`  [EXTRACTED]
  Sources/CramLabApp/CramLabApp.swift → Tests/CramLabCoreTests/AcceptanceTests.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Prepared request to reply to import pipeline (manual, direct, topic analysis)** — docs_implementation_status_chatgpt_bridge, docs_implementation_status_direct_ai, docs_implementation_status_topic_analysis, docs_implementation_status_on_device_ai [INFERRED 0.85]
- **Grade to evidence to XP and mastery flow** — docs_implementation_status_evaluation_engine, docs_mastery_learning_evidence, docs_mastery_xp_ledger, docs_mastery_estimator, docs_mastery_grade_trust [INFERRED 0.85]
- **Sandboxed code execution to trusted code-test grading** — docs_implementation_status_sandbox_runner, docs_implementation_status_code_tests, docs_mastery_grade_trust, docs_architecture_decisions_adr_032, docs_architecture_decisions_adr_033 [INFERRED 0.85]

## Communities (112 total, 26 thin omitted)

### Community 0 - "Architecture Decision Records"
Cohesion: 0.05
Nodes (55): Architecture Decisions (ADR-001..036), HTTPTransport (Swift seam), Latex (Swift parser type), ProgressionEngine.commit (Swift type), ProgressionService.mastery (Swift type), Implementation Status, Advanced question interactions (drag/matching/diagram) - deferred, Backup/restore (.cramlabbackup folder) (+47 more)

### Community 1 - "Snapshot & Self-Test Runner"
Cohesion: 0.05
Nodes (28): .item, .spec, .summaryText, SnapshotRunner, .dir, .isActive, AttemptDraft, CodeFile (+20 more)

### Community 2 - "Symbolic Math"
Cohesion: 0.06
Nodes (19): Monomial, ParseFailure, unreadable, unsupported, Parser, .peek, Poly, .constantValue (+11 more)

### Community 3 - "Module Imports & Frameworks"
Cohesion: 0.06
Nodes (22): CoreGraphics, CoreText, CramLabCore, CryptoKit, Foundation, GRDB, PDFKit, AppModel (+14 more)

### Community 4 - "AI Bridge Tests"
Cohesion: 0.08
Nodes (9): AIBridgeTests, DirectAITests, MockTransport, .count, Setup, Fx, .all, Setup (+1 more)

### Community 5 - "Grading & Evaluation Service"
Cohesion: 0.09
Nodes (16): Attempt, .decodedResponse, award, AttemptResult, EvaluationError, .errorDescription, invalidScore, notCodeTests (+8 more)

### Community 6 - "Insights View"
Cohesion: 0.09
Nodes (29): Charts, InsightsView, .body, .content, .historyCard, .recentCard, .reviewsCard, .studyCard (+21 more)

### Community 7 - "FSRS Scheduler"
Cohesion: 0.09
Nodes (16): .card, FSRSCard, FSRSRating, again, easy, good, hard, .label (+8 more)

### Community 8 - "GRDB Record Protocols"
Cohesion: 0.21
Nodes (28): .xpCard, CourseSkill, DocumentAssessment, SkillRelation, CoachEvent, Evaluation, .isCorrect, LearningEvidence (+20 more)

### Community 9 - "Coach & Stuck Guidance"
Cohesion: 0.08
Nodes (30): .color, CoachTrigger, breakthrough, highConfidenceMiss, manyHints, repeatedMistakes, StuckGuidance, AnswerSpec (+22 more)

### Community 10 - "Topic & Course Models"
Cohesion: 0.12
Nodes (17): Row, Assessment, Course, Skill, Candidate, PlannedItem, .id, PlannerService (+9 more)

### Community 11 - "LaTeX Rendering"
Cohesion: 0.10
Nodes (20): Latex, LatexError, tooLarge, unbalanced, unsupported, MathNode, bigOp, delimited (+12 more)

### Community 12 - "Practice Session Model"
Cohesion: 0.11
Nodes (11): .body, .disagreeMenu, PracticeModel, .hintsUsed, .isLast, .layout, .locked, .response (+3 more)

### Community 13 - "Course Service"
Cohesion: 0.15
Nodes (5): CourseService, String, .skillKey, CourseTests, SkillTreeTests

### Community 14 - "Course Kinds & Item Status"
Cohesion: 0.05
Nodes (39): CourseKind, quickCram, structured, ItemStatus, inProgress, notStarted, skipped, submitted (+31 more)

### Community 15 - "Direct AI & Keychain"
Cohesion: 0.10
Nodes (16): Security, DirectAIError, disabled, .errorDescription, http, keychain, malformedResponse, network (+8 more)

### Community 16 - "Database Migrator"
Cohesion: 0.07
Nodes (5): StuckService, AppDatabase, .configuration, DemoTests, PersistenceTests

### Community 17 - "App Shell & Focus Model"
Cohesion: 0.12
Nodes (11): CramLabApp, .body, FocusModel, .isPaused, .isRunning, .notifyOnEnd, .showMenuBar, .svc (+3 more)

### Community 18 - "Practice UI Components"
Cohesion: 0.13
Nodes (19): CoachBanner, ConfidenceRow, CodeWorkspaceView, CodeRunPanel, FocusChip, .body, AnswerView, .body (+11 more)

### Community 19 - "Design System"
Cohesion: 0.09
Nodes (22): Badge, .body, Card, .body, Color, MeterBar, .body, Theme (+14 more)

### Community 20 - "Courses View"
Cohesion: 0.11
Nodes (16): AssessmentSheet, .body, AssessmentsTab, .body, CourseDetailView, .body, CoursesView, .body (+8 more)

### Community 21 - "Questions & Revisions"
Cohesion: 0.16
Nodes (10): Question, .notes, QuestionRevision, .spec, RevisionOrigin, aiImport, duplicate, edit (+2 more)

### Community 22 - "AI Task Center View"
Cohesion: 0.14
Nodes (11): AITaskCenterView, .body, ImportSheet, .body, ImportTarget, NewTaskSheet, .body, RequestSheet (+3 more)

### Community 23 - "Review Scheduling Tests"
Cohesion: 0.16
Nodes (3): ReviewSchedulingTests, CorrectionAndProgressTests, GradingFlowTests

### Community 24 - "Documents & Task Creation"
Cohesion: 0.09
Nodes (21): ImportResult, AssessmentSkill, Document, DocumentChunk, DocumentKind, pasted, pdf, text (+13 more)

### Community 25 - "Learning History"
Cohesion: 0.15
Nodes (8): .body, Breakthrough, .id, LearningHistoryService, Mistake, .id, .wasHighConfidence, WeakSpot

### Community 26 - "AI Task Service"
Cohesion: 0.19
Nodes (3): AITaskService, DirectAIService, DemoWorkspace

### Community 27 - "Progression Service"
Cohesion: 0.16
Nodes (6): AssessmentProgress, ItemResult, .id, ProgressionService, SessionResults, XPSummary

### Community 28 - "Grade Trust & Evaluator"
Cohesion: 0.17
Nodes (8): GradeTrust, aiGraded, provisional, selfReported, trusted, EvaluationOutcome, Evaluator, EvaluatorTests

### Community 29 - "Sandbox Exec Profile"
Cohesion: 0.19
Nodes (11): SpawnResult, Exec, literal, subpath, Prepared, Profile, SandboxedCodeRunner, .isAvailable (+3 more)

### Community 30 - "Topic Analysis"
Cohesion: 0.16
Nodes (14): AnyImportReport, grades, questions, topics, RawTopic, TopicApplyReport, TopicDecision, TopicItem (+6 more)

### Community 31 - "Code Runner"
Cohesion: 0.15
Nodes (13): CodeRunner, CodeRunRequest, CodeRunResult, finished, unavailable, CodeTest, CodeTestReport, compileError (+5 more)

### Community 32 - "Topic Review Views"
Cohesion: 0.13
Nodes (9): .choices, Choice, accept, merge, skip, TopicReviewView, .body, TopicTaskSheet (+1 more)

### Community 33 - "Process Supervisor"
Cohesion: 0.11
Nodes (11): Darwin, free, ProcessSupervisor, SandboxLimits, Termination, exited, failedToStart, memoryLimit (+3 more)

### Community 34 - "App Model"
Cohesion: 0.15
Nodes (7): AppModel, .directAI, .onboarding, .sandboxLanguages, .sandboxProblem, GenerateRequest, OnboardingState

### Community 35 - "Planner & Math Errors"
Cohesion: 0.09
Nodes (21): PlannerError, assessmentRequired, .errorDescription, noBudget, notFound, MathError, divideByZero, tooLarge (+13 more)

### Community 36 - "Output Comparison"
Cohesion: 0.11
Nodes (15): .codeRunner, OutputComparison, TestOutcome, .id, TestStatus, crashed, failed, memoryLimit (+7 more)

### Community 37 - "Mastery Estimator"
Cohesion: 0.25
Nodes (6): DimensionEstimate, EvidenceInput, HeuristicMasteryEstimator, MasteryEstimator, SkillMastery, .isUnknown

### Community 39 - "Prompt Builder"
Cohesion: 0.19
Nodes (9): DocumentEntry, ExportFile, Extract, PromptBuilder, PromptInput, RepairItem, RequestManifest, RequestPackage (+1 more)

### Community 41 - ".create() cluster"
Cohesion: 0.10
Nodes (20): EvaluationMethod, aiRubric, choice, codeTests, exact, numeric, selfReview, symbolic (+12 more)

### Community 42 - "ReviewService.swift cluster"
Cohesion: 0.19
Nodes (4): DueReview, .id, ReviewEngine, ReviewService

### Community 43 - "App cluster"
Cohesion: 0.12
Nodes (14): App, .ai, .courses, .docs, .eval, .focus, .insights, .planner (+6 more)

### Community 44 - "CaseIterable cluster"
Cohesion: 0.12
Nodes (16): StuckSheet, .body, TutorSheet, .body, Tab, assessments, materials, plan (+8 more)

### Community 46 - "QuestionService.swift cluster"
Cohesion: 0.19
Nodes (11): QuestionBankView, .body, .bulkPanel, .filterBar, .list, .id, SkillTagSheet, .body (+3 more)

### Community 47 - "SkillMapView.swift cluster"
Cohesion: 0.14
Nodes (5): SkillMapView, .body, SkillEdge, SkillGraphLayout, SkillNode

### Community 48 - ".deleteAssessment() cluster"
Cohesion: 0.22
Nodes (3): DocumentService, ExtractedPage, Extraction

### Community 49 - "FocusTimer cluster"
Cohesion: 0.24
Nodes (4): FocusTimer, .isActive, .remainingSeconds, FocusTests

### Community 50 - "Choice cluster"
Cohesion: 0.16
Nodes (4): QuestionEditor, .body, CoachService, CoachSuggestion

### Community 51 - "MathView.swift cluster"
Cohesion: 0.16
Nodes (9): MathNodeView, .body, MathView, .body, RichText, .body, .body, BlockView (+1 more)

### Community 52 - ".filterControls cluster"
Cohesion: 0.15
Nodes (7): .filterControls, QuestionFilter, Sort, difficulty, newest, title, QuestionServiceTests

### Community 53 - "GradingViews.swift cluster"
Cohesion: 0.16
Nodes (7): GradePanel, .body, GradeTaskSheet, .body, .courseIds, SelfReviewView, .body

### Community 55 - "BackupService.swift cluster"
Cohesion: 0.34
Nodes (4): BackupManifest, BackupResult, BackupService, FileEntry

### Community 56 - "AdaptiveViews.swift cluster"
Cohesion: 0.16
Nodes (6): AppKit, CodeEditorController, .body, SettingsView, SwiftUI, UserNotifications

### Community 58 - "StudyPlanView.swift cluster"
Cohesion: 0.17
Nodes (4): EmptyStateView, .body, StudyPlanTab, .body

### Community 59 - "AITaskError cluster"
Cohesion: 0.12
Nodes (16): AITaskError, .errorDescription, invalidParams, malformedJSON, missingQuestions, missingRequestId, notAnObject, notFound (+8 more)

### Community 60 - "MasteryDimension cluster"
Cohesion: 0.17
Nodes (7): MasteryDimension, application, .label, recall, recognition, transfer, EstimatorTests

### Community 61 - "rejected cluster"
Cohesion: 0.20
Nodes (4): rejected, BackupTests, World, tempDir()

### Community 62 - "ArithmeticEvaluator.swift cluster"
Cohesion: 0.27
Nodes (3): ArithmeticEvaluator, Parser, .peek

### Community 63 - "QuestionValidator.swift cluster"
Cohesion: 0.16
Nodes (9): .severeEnoughForNotes, QuestionLimits, QuestionValidator, ValidationIssue, .description, ValidationResult, .hasBlocking, .readiness (+1 more)

### Community 64 - "SettingKey cluster"
Cohesion: 0.13
Nodes (15): SettingKey, appearance, coachEnabled, codeExecutionEnabled, codeFontSize, confidencePrompts, directAPIEnabled, directAPIModel (+7 more)

### Community 66 - "Calibration.swift cluster"
Cohesion: 0.27
Nodes (6): Calibration, CalibrationBin, CalibrationReport, .enoughData, CalibrationScore, Pair

### Community 67 - "AITaskService.swift cluster"
Cohesion: 0.26
Nodes (9): AcceptedQuestion, GenerationParams, ImportReport, RejectedEntry, TaskStatus, awaitingImport, completed, draft (+1 more)

### Community 74 - ".init() cluster"
Cohesion: 0.32
Nodes (3): .isEnabled, .model, SettingsStore

### Community 75 - "CodeRunViews.swift cluster"
Cohesion: 0.21
Nodes (7): .body, OutputView, .body, .ok, .statusText, TestReportView, .body

### Community 76 - "FocusViews.swift cluster"
Cohesion: 0.20
Nodes (8): FocusEndBanner, .body, FocusPopover, FocusToolbarButton, .body, RootView, .body, .library

### Community 77 - "CustomStringConvertible cluster"
Cohesion: 0.20
Nodes (7): RunnerError, .description, invalidFile, io, tooLarge, tooManyFiles, CodeRunOutput

### Community 78 - ".takeBreak() cluster"
Cohesion: 0.20
Nodes (6): FocusKind, .label, longBreak, shortBreak, work, FocusSettings

### Community 80 - "BackupError cluster"
Cohesion: 0.18
Nodes (11): BackupError, corruptDatabase, .errorDescription, hashMismatch, missingFile, newerThanApp, notABackup, safetyBackupFailed (+3 more)

### Community 81 - "SyntaxHighlighter.swift cluster"
Cohesion: 0.22
Nodes (8): SyntaxHighlighter, Token, TokenKind, comment, keyword, number, preprocessor, string

### Community 82 - "HistoryAndStuckTests cluster"
Cohesion: 0.27
Nodes (6): HistoryAndStuckTests, .coach, .planner, .reviews, Reopened, Rig

### Community 83 - "overlay.template.yaml cluster"
Cohesion: 0.20
Nodes (9): case-sensitive, external-contents, name, type, roots, contents, name, type (+1 more)

### Community 85 - "ColorScheme cluster"
Cohesion: 0.22
Nodes (6): .colorScheme, .label, AppearanceSetting, dark, light, system

### Community 88 - "SidebarItem cluster"
Cohesion: 0.22
Nodes (9): SidebarItem, aiTasks, courses, home, .id, insights, questionBank, skills (+1 more)

### Community 90 - "CourseError cluster"
Cohesion: 0.22
Nodes (8): CourseError, emptyName, .errorDescription, nameTooLong, notFound, notQuickCram, skillNotInCourse, wouldCreateCycle

### Community 91 - "DocumentError cluster"
Cohesion: 0.22
Nodes (9): DocumentError, emptyText, .errorDescription, lockedPDF, notAPDF, notFound, tooLarge, unreadable (+1 more)

### Community 92 - "RunTermination cluster"
Cohesion: 0.22
Nodes (8): RunTermination, compileFailed, exited, internalError, memoryLimit, outputLimit, signaled, timedOut

### Community 93 - "Comparable cluster"
Cohesion: 0.25
Nodes (6): ConfidenceLevel, .label, moderate, preliminary, strong, unknown

### Community 96 - "CodeLanguage cluster"
Cohesion: 0.25
Nodes (6): CodeLanguage, c, java, .keywords, python, .unavailableReason

### Community 100 - "build.sh cluster"
Cohesion: 0.73
Nodes (5): build_app(), build_core(), build_grdb(), build_test(), build.sh script

### Community 101 - "AssessmentKind cluster"
Cohesion: 0.33
Nodes (6): AssessmentKind, assignment, final, midterm, other, quiz

### Community 103 - "EvaluationState cluster"
Cohesion: 0.40
Nodes (5): EvaluationState, evaluatorUnavailable, graded, needsReview, pending

### Community 104 - "CodeVerification cluster"
Cohesion: 0.40
Nodes (4): CodeVerification, compileError, failed, verified

### Community 105 - "Phase cluster"
Cohesion: 0.40
Nodes (5): Phase, finished, paused, running, stopped

### Community 106 - "EvalError cluster"
Cohesion: 0.40
Nodes (5): EvalError, divideByZero, notFinite, syntax, tooLong

### Community 109 - "TransferMethod cluster"
Cohesion: 0.50
Nodes (4): TransferMethod, api, clipboard, file

### Community 110 - "Severity cluster"
Cohesion: 0.67
Nodes (3): Severity, blocking, review

## Knowledge Gaps
- **429 isolated node(s):** `PackageDescription`, `home`, `courses`, `questionBank`, `skills` (+424 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 654 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **26 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `QuestionSpec` connect `Practice UI Components` to `Snapshot & Self-Test Runner`, `Symbolic Math`, `Grading & Evaluation Service`, `GRDB Record Protocols`, `Coach & Stuck Guidance`, `Practice Session Model`, `Questions & Revisions`, `Review Scheduling Tests`, `Grade Trust & Evaluator`, `Prompt Builder`, `.create() cluster`, `App cluster`, `QuestionService.swift cluster`, `Choice cluster`, `.filterControls cluster`, `GradingViews.swift cluster`, `.importResponse() cluster`, `ClosedRange cluster`, `CodeVerificationService cluster`?**
  _High betweenness centrality (0.039) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `Rig` (e.g. with `.breakthroughOnANewVariationAfterEarlierTrouble()` and `.confidentMissOffersReflection()`) actually correct?**
  _`Rig` has 19 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `home`, `courses` to the rest of the system?**
  _429 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Architecture Decision Records` be split into smaller, more focused modules?**
  _Cohesion score 0.05128205128205128 - nodes in this community are weakly interconnected._
- **Why does `PracticeModel` connect `Practice Session Model` to `Snapshot & Self-Test Runner`, `Module Imports & Frameworks`, `Grading & Evaluation Service`, `Topic & Course Models`, `CodeRunViews.swift cluster`, `CaseIterable cluster`, `CustomStringConvertible cluster`, `Practice UI Components`, `Choice cluster`, `GradingViews.swift cluster`, `AdaptiveViews.swift cluster`, `Progression Service`, `Code Runner`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Should `Snapshot & Self-Test Runner` be split into smaller, more focused modules?**
  _Cohesion score 0.054647599591419814 - nodes in this community are weakly interconnected._
- **Why does `CodeLanguage` connect `CodeLanguage cluster` to `Context cluster`, `App Model`, `Output Comparison`, `CodeToolsTests cluster`, `GRDB Record Protocols`, `Coach & Stuck Guidance`, `CodeRunViews.swift cluster`, `CaseIterable cluster`, `SyntaxHighlighter.swift cluster`, `EditorLogic.swift cluster`, `Sandbox Exec Profile`?**
  _High betweenness centrality (0.035) - this node is a cross-community bridge._