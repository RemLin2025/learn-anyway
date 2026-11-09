# Mastery and XP model (heuristic-v1)

Mastery and XP are **independent systems**. XP rewards effort; mastery estimates what the evidence supports. Neither reads the other.

## Evidence
Every real grade (`graded` state) writes one `learning_evidence` row per skill tagged on the question, attributable to the evaluation, question revision and skill mapping that produced it. Pending, disputed (`needsReview`) and unavailable grades write **no** evidence. When a grade is superseded its evidence is marked superseded (never deleted); the new grade writes fresh evidence.

Each question type feeds one of four dimensions:

| Dimension | Question types |
|---|---|
| Recognition | single choice, multiple select |
| Recall & explanation | flashcard, short answer, long-form |
| Independent application | numeric, code tracing, coding (difficulty ≤ 3) |
| Transfer & reasoning | derivation/proof, coding (difficulty ≥ 4) |

## Estimator
Weight of one piece of evidence: `w = difficulty × independence × novelty × reliability × recency`

| Factor | Values |
|---|---|
| difficulty (1–5) | 0.6, 0.8, 1.0, 1.2, 1.4 |
| independence (hints used) | 0 → 1.0, 1 → 0.7, 2 → 0.5, ≥3 → 0.35 |
| novelty (nth attempt at this question) | 0.5^(n−1), floor 0.15 |
| reliability (grade trust) | trusted 1.0 · AI-graded 0.85 · self-reported 0.6 · provisional 0.5 |
| recency | 0.5^(days/60), floor 0.2 |

Per dimension: estimate = weight-averaged score; **confidence comes from total weight**, not question count: 0 → Unknown, < 1.5 → Preliminary, < 4 → Moderate, otherwise Strong. A dimension or skill with no evidence has **no estimate** (shown as “Not assessed” / Unknown), never 0%. One easy provisional answer therefore stays Preliminary whatever its score. Overall = weight-averaged across dimensions. *Evidence quality* = share of weight from trusted or AI-graded grades.

The estimator sits behind the `MasteryEstimator` protocol; `skill_estimates` stores an append-only snapshot (with `estimatorVersion`) after each grading event, and the UI computes the live value (so recency stays current).

## Grade trust
* `trusted` – deterministic grade against a **verified** answer key (computed check or user-verified), current revision only.
* `provisional` – deterministic grade, key not verified (or graded against an older revision).
* `selfReported` – the learner graded themselves (lower-confidence evidence, no correctness XP).
* `aiGraded` – imported from a manual ChatGPT grading round.

## XP (append-only ledger)
* Participation: `5 + 2·difficulty` per submitted attempt, × 1, 0.5, 0.25, 0 for the 1st, 2nd, 3rd, later attempts at the same question (repeats can’t be farmed). Also paid for pending work (it is effort, not correctness).
* Correctness bonus: `4 + 3·difficulty`, **once per question**, for the earliest attempt that is graded ≥ 0.8, trusted or AI-graded, with no hints.
* Every event has a unique `eventKey`; XP for a reward is reconciled to its desired net amount, so retries and double calls do nothing. A regrade/dispute that removes a reward appends a **correction** event (negative amount, same attempt). Net XP = SUM(amount).
* Each event’s amount is split across the question’s skills in `xp_event_skills` (sums to the event amount), so skill XP never double-counts into course XP. Level = 1 + ⌊√(XP/25)⌋.

## Calibration (M8)
Insights → “How well does the mastery estimate predict you?” replays each answer against the estimate built from earlier evidence only (Brier error vs a plain-average baseline, binned, bias, three what-if variants). It needs ≥ 30 predictions and never changes the estimator; constants change only through a deliberate, versioned code change.
