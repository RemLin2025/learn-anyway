#!/usr/bin/env python3
"""Writes FSRS test vectors for Tests/Fixtures.

  scripts/fsrs_vectors.py transcription   # independent re-implementation of the formulas (no dependencies)
  scripts/fsrs_vectors.py reference       # uses the real library:  pip install fsrs   (py-fsrs, MIT)

The Swift tests (FSRSTests) compare the Swift port with every fixture file that exists. The `transcription`
vectors catch porting mistakes but share this author's reading of the formulas; the `reference` vectors come
straight from py-fsrs and are the authoritative check.
"""
import json, math, sys
from datetime import datetime, timedelta, timezone

T0 = datetime(2026, 1, 1, tzinfo=timezone.utc)
SCENARIOS = {
    "on_schedule": ([3, 3, 3, 3, 2, 3, 4, 3, 1, 3, 3, 3], None),
    "all_easy": ([4, 4, 4, 4, 4], None),
    "lapses": ([3, 3, 3, 1, 1, 3, 3, 1, 3, 3], None),
    "hard_only": ([2, 2, 2, 2, 2, 2], None),
    "irregular": ([3, 3, 2, 3, 1, 3, 3], [0, 0.5, 30, 24 * 5, 24 * 40, 24 * 40 + 0.1, 24 * 100]),
}
P = [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835,
     0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542]


class Mine:
    """Plain transcription of the FSRS-6 equations (learning steps 1m,10m; relearning 10m; retention 0.9)."""
    LS, RS, RET = [60, 600], [600], 0.9
    def __init__(s): s.decay = -P[20]; s.factor = 0.9 ** (1 / s.decay) - 1
    def card(s): return dict(state=1, step=0, stab=None, diff=None, due=T0, last=None)
    def retr(s, c, now):
        if c["last"] is None: return 0
        return (1 + s.factor * max(0, (now - c["last"]).days) / c["stab"]) ** s.decay
    def d0(s, r, clamp=True):
        d = P[4] - math.e ** (P[5] * (r - 1)) + 1
        return min(max(d, 1.0), 10.0) if clamp else d
    def dn(s, d, r):
        a1 = s.d0(4, False); delta = -(P[6] * (r - 3)); a2 = d + (10 - d) * delta / 9
        return min(max(P[7] * a1 + (1 - P[7]) * a2, 1.0), 10.0)
    def short(s, st, r):
        inc = math.e ** (P[17] * (r - 3 + P[18])) * (st ** -P[19])
        if r >= 2: inc = max(inc, 1.0)
        return max(st * inc, 0.001)
    def nxt(s, d, st, rt, r):
        if r == 1:
            lt = P[11] * (d ** -P[12]) * (((st + 1) ** P[13]) - 1) * math.e ** ((1 - rt) * P[14])
            v = min(lt, st / math.e ** (P[17] * P[18]))
        else:
            v = st * (1 + math.e ** P[8] * (11 - d) * (st ** -P[9]) * (math.e ** ((1 - rt) * P[10]) - 1)
                      * (P[15] if r == 2 else 1) * (P[16] if r == 4 else 1))
        return max(v, 0.001)
    def ivl(s, st):
        return timedelta(days=min(max(round((st / s.factor) * ((s.RET ** (1 / s.decay)) - 1)), 1), 36500))
    def steps(s, c, r, steps, now):
        if not steps or (c["step"] >= len(steps) and r != 1):
            c["state"], c["step"] = 2, None; return s.ivl(c["stab"])
        if r == 1: c["step"] = 0; return timedelta(seconds=steps[0])
        if r == 2:
            if c["step"] == 0 and len(steps) == 1: return timedelta(seconds=steps[0] * 1.5)
            if c["step"] == 0 and len(steps) >= 2: return timedelta(seconds=(steps[0] + steps[1]) / 2)
            return timedelta(seconds=steps[c["step"]])
        if r == 3:
            if c["step"] + 1 == len(steps): c["state"], c["step"] = 2, None; return s.ivl(c["stab"])
            c["step"] += 1; return timedelta(seconds=steps[c["step"]])
        c["state"], c["step"] = 2, None; return s.ivl(c["stab"])
    def review(s, c, r, now):
        c = dict(c); ds = (now - c["last"]).days if c["last"] else None
        if c["state"] == 1:
            if c["stab"] is None or c["diff"] is None: c["stab"], c["diff"] = max(P[r - 1], 0.001), s.d0(r)
            elif ds is not None and ds < 1: c["stab"], c["diff"] = s.short(c["stab"], r), s.dn(c["diff"], r)
            else: c["stab"], c["diff"] = s.nxt(c["diff"], c["stab"], s.retr(c, now), r), s.dn(c["diff"], r)
            iv = s.steps(c, r, s.LS, now)
        elif c["state"] == 2:
            if ds is not None and ds < 1: c["stab"] = s.short(c["stab"], r)
            else: c["stab"] = s.nxt(c["diff"], c["stab"], s.retr(c, now), r)
            c["diff"] = s.dn(c["diff"], r)
            if r == 1 and s.RS: c["state"], c["step"] = 3, 0; iv = timedelta(seconds=s.RS[0])
            else: iv = s.ivl(c["stab"])
        else:
            if ds is not None and ds < 1: c["stab"], c["diff"] = s.short(c["stab"], r), s.dn(c["diff"], r)
            else: c["stab"], c["diff"] = s.nxt(c["diff"], c["stab"], s.retr(c, now), r), s.dn(c["diff"], r)
            iv = s.steps(c, r, s.RS, now)
        c["due"] = now + iv; c["last"] = now
        return c


def run_mine():
    out = {"source": "transcription", "scenarios": []}
    m = Mine()
    for name, (ratings, offsets) in SCENARIOS.items():
        c, steps = m.card(), []
        for i, r in enumerate(ratings):
            t = T0 + timedelta(hours=offsets[i]) if offsets else (c["due"] if i else T0)
            retr = m.retr(c, t) if c["last"] else None
            c = m.review(c, r, t)
            steps.append(dict(rating=r, at=t.isoformat(), retrievability_before=retr, state=c["state"], step=c["step"],
                              stability=c["stab"], difficulty=c["diff"], due=c["due"].isoformat()))
        out["scenarios"].append({"name": name, "steps": steps})
    return out


def run_reference():
    from fsrs import Scheduler, Card, Rating  # pip install fsrs
    sch = Scheduler(enable_fuzzing=False)
    out = {"source": "py-fsrs", "scenarios": []}
    for name, (ratings, offsets) in SCENARIOS.items():
        c, steps = Card(), []
        for i, r in enumerate(ratings):
            t = T0 + timedelta(hours=offsets[i]) if offsets else (c.due if i else T0)
            retr = sch.get_card_retrievability(c, t) if c.last_review else None
            c, _ = sch.review_card(c, Rating(r), t)
            steps.append(dict(rating=r, at=t.isoformat(), retrievability_before=retr, state=int(c.state), step=c.step,
                              stability=c.stability, difficulty=c.difficulty, due=c.due.isoformat()))
        out["scenarios"].append({"name": name, "steps": steps})
    return out


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "transcription"
    json.dump(run_mine() if mode == "transcription" else run_reference(), sys.stdout, indent=1)
