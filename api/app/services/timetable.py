"""Timetable generation with OR-Tools CP-SAT.

Modelling decisions, and why they matter:

* **Variables are indexed on teaching assignments, not on the cross product.**
  A variable per (teacher, class, room, slot) would be 72 x 40 x 44 x 36 —
  over four million booleans — and it still could not express "9A needs 7
  periods of Maths a week", because it has no subject dimension. Indexing on
  the `teaching_assignments` rows a school already keeps gives
  320 x 36 = 11,520 variables that mean exactly the right thing.

* **Rooms are not a dimension.** Indian schools are home-room based: the class
  owns a room and teachers move. Only labs are scarce, so only labs are
  rationed, as a capacity constraint per slot. Rooms are then assigned after
  the solve, where it is bookkeeping rather than search.

* **Shortfall is modelled, not avoided.** Every curriculum requirement carries
  a slack variable. An over-constrained school therefore returns a near-miss
  plus an explanation of what could not be placed and why, instead of a bare
  INFEASIBLE. A diagnosis is useful; a red error is not.

* **Pre-flight arithmetic runs first.** If a teacher owes 40 periods in a
  36-period week, no amount of search will fix it. Counting that up front is
  instant and gives a far better message than a solver timeout.
"""

from __future__ import annotations

import math
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from ortools.sat.python import cp_model

# Weight on unplaced periods. Large enough that the solver will always accept
# an ugly timetable over an incomplete one.
SLACK_WEIGHT = 1000
# Teaching straight through with no break. Expensive — but deliberately well
# below SLACK_WEIGHT, so the solver never drops a lesson to avoid one.
LONG_RUN_WEIGHT = 40
# A day at the daily maximum is legal but tiring, so spread them out.
HEAVY_DAY_WEIGHT = 6
# Idle time between lessons. Low, and deliberately so — see Rules below.
GAP_WEIGHT = 1

# Feasibility alone now takes about eleven seconds under the daily cap, so the
# old 20s default left almost nothing for the comfort pass.
DEFAULT_TIME_LIMIT = 45.0


@dataclass
class Rules:
    """What a humane timetable means for this school.

    These were hardcoded assumptions until a generated timetable put six
    teachers through six consecutive periods with no break. The cause was the
    objective, not the staffing: the old model *minimised teacher gaps*, and a
    day of six back-to-back lessons has zero gaps — so it scored perfectly.
    The optimiser was rewarding exactly the thing that made the timetable
    unusable.

    Now the humane limits are hard constraints, and idle time is only a mild
    preference. A single free period mid-morning is not waste; it is the break
    that makes the day possible.
    """

    #: Nobody teaches every period of the day. Hard — and it costs nothing:
    #: capping at 5 still solves to optimality in about eleven seconds.
    max_periods_per_day: int = 5

    #: Lessons back to back before a break is wanted. **Strongly preferred,
    #: not enforced.** Making this hard was tested and it does not hold: at
    #: 55 teachers a limit of 3 left 24 periods unplaced and a limit of 4 left
    #: 5, because 40 classes need 40 of the 55 teachers busy in *every* slot,
    #: so there is very little freedom in where the breaks can fall. As a
    #: penalty the solver removes almost all long runs and still places the
    #: whole curriculum.
    preferred_max_consecutive: int = 3

    #: Refuse to exceed the run limit rather than merely disliking it. Off by
    #: default; turning it on trades completeness for comfort, and preflight
    #: says so before the search starts.
    enforce_consecutive: bool = False

    #: Prefer an even week over five heavy days and one empty one.
    balance_daily_load: bool = True

    def as_dict(self) -> dict:
        return {
            "max_periods_per_day": self.max_periods_per_day,
            "preferred_max_consecutive": self.preferred_max_consecutive,
            "enforce_consecutive": self.enforce_consecutive,
            "balance_daily_load": self.balance_daily_load,
        }


@dataclass
class Diagnostic:
    severity: str  # 'error' | 'warning'
    code: str
    message: str
    detail: str | None = None

    def as_dict(self) -> dict:
        return {
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "detail": self.detail,
        }


@dataclass
class SolveResult:
    status: str                      # 'optimal' | 'feasible' | 'infeasible'
    entries: list[dict] = field(default_factory=list)
    diagnostics: list[Diagnostic] = field(default_factory=list)
    stats: dict[str, Any] = field(default_factory=dict)

    @property
    def placed_everything(self) -> bool:
        return not any(d.code == "unplaced" for d in self.diagnostics)


# --------------------------------------------------------------- pre-flight
def preflight(data: dict, rules: Rules | None = None) -> list[Diagnostic]:
    """Arithmetic that decides feasibility before any search happens."""
    rules = rules or Rules()
    out: list[Diagnostic] = []
    slots = data["slots"]
    n_slots = len(slots)
    n_days = len({s["day_of_week"] for s in slots}) or 1

    teachers = {t["id"]: t for t in data["teachers"]}
    classes = {c["id"]: c for c in data["classes"]}

    # --- teacher load against the week -------------------------------
    load: dict[str, int] = defaultdict(int)
    for a in data["assignments"]:
        load[a["teacher_id"]] += a["periods_per_week"]

    # The daily cap lowers the real weekly ceiling below the number of slots:
    # 5 periods a day over 6 days is 30, not 36. Checking that here means an
    # impossible rule is reported as arithmetic in milliseconds, rather than
    # as a solver timeout.
    weekly_ceiling = min(n_slots, rules.max_periods_per_day * n_days)

    for tid, total in sorted(load.items(), key=lambda kv: -kv[1]):
        if total > weekly_ceiling:
            name = teachers.get(tid, {}).get("full_name", tid[:8])
            capped = weekly_ceiling < n_slots
            out.append(Diagnostic(
                "error", "teacher_overcommitted",
                f"{name} is assigned {total} periods but can teach at most "
                f"{weekly_ceiling} a week"
                + (f" under the {rules.max_periods_per_day}-per-day limit."
                   if capped else f" — the week only has {n_slots}."),
                f"Over by {total - weekly_ceiling} periods. Move a class to "
                f"another teacher in the same department"
                + (", or raise the daily limit." if capped else "."),
            ))

    # --- class load --------------------------------------------------
    cload: dict[str, int] = defaultdict(int)
    for a in data["assignments"]:
        cload[a["class_id"]] += a["periods_per_week"]

    for cid, total in cload.items():
        name = classes.get(cid, {}).get("name", cid[:8])
        if total > n_slots:
            out.append(Diagnostic(
                "error", "class_overcommitted",
                f"Class {name} has {total} periods of curriculum but only "
                f"{n_slots} slots in the week.",
                f"Over-subscribed by {total - n_slots} periods.",
            ))
        elif total < n_slots:
            out.append(Diagnostic(
                "warning", "class_underfilled",
                f"Class {name} has {total} periods of curriculum, leaving "
                f"{n_slots - total} free slots.",
            ))

    # --- lab capacity -------------------------------------------------
    lab_demand: dict[str, int] = defaultdict(int)
    for a in data["assignments"]:
        if a["requires_lab"]:
            lab_demand[a["lab_type"]] += a["periods_per_week"]

    for lab_type, demand in lab_demand.items():
        capacity = data["lab_capacity"].get(lab_type, 0) * n_slots
        if demand > capacity:
            out.append(Diagnostic(
                "error", "lab_capacity",
                f"{demand} {lab_type.replace('_', ' ')} periods are required "
                f"but only {capacity} are available.",
                f"{data['lab_capacity'].get(lab_type, 0)} room(s) x {n_slots} "
                f"slots. Reduce practical periods or add a room.",
            ))

    # --- per-day spreading feasibility ---------------------------------
    for a in data["assignments"]:
        if a["periods_per_week"] > n_days * 2:
            cname = classes.get(a["class_id"], {}).get("name", "?")
            out.append(Diagnostic(
                "warning", "subject_concentrated",
                f"{cname} {a['subject_name']} needs {a['periods_per_week']} "
                f"periods across {n_days} days, so some days carry three or more.",
            ))

    return out


# ------------------------------------------------------------------- solve
def solve(data: dict, time_limit: float = DEFAULT_TIME_LIMIT,
          optimise_gaps: bool = True, rules: Rules | None = None) -> SolveResult:
    """Two phases, because they are different problems.

    Phase 1 places every period and nothing else. Phase 2 re-solves for
    comfort — short runs, an even week — warm-started from phase one, so a
    timeout degrades to "valid but less pleasant" rather than "incomplete".

    **Phase 1's budget has to be generous.** It used to get five seconds,
    which was ample when the only hard constraints were clashes and lab
    capacity. Adding a daily cap made feasibility itself take about eleven
    seconds, so five was no longer enough: phase 1 handed over a broken
    timetable and phase 2 dutifully polished it, ending with 874 periods
    unplaced. Feasibility comes first and gets at least half the time.
    """
    t0 = time.perf_counter()
    rules = rules or Rules()
    diagnostics = preflight(data, rules)

    # "Every class slot is filled" is a much stronger propagator, but it is
    # only TRUE when the school is properly staffed. Where preflight has
    # already found an impossibility we need graceful degradation instead, so
    # the constraint is relaxed and shortfall is allowed to show up as
    # unplaced periods with an explanation.
    strict = not any(d.severity == "error" for d in diagnostics)

    # Strict packing either lands in the first few seconds or not at all, so
    # a long phase-1 slice buys nothing and starves whatever has to run next
    # — the relaxed retry, or the comfort pass.
    phase1_budget = min(time_limit, max(12.0, time_limit * 0.4))
    first = _solve_once(data, phase1_budget, gaps=False, hint=None, strict=strict, rules=rules)

    if strict and first.status == "infeasible":
        # Something the arithmetic checks could not see. Re-solve without the
        # strict packing so the reviewer gets a near-miss plus a diagnosis
        # rather than a bare INFEASIBLE.
        #
        # Budgeted from what is LEFT, not another full phase-1 slice: strict
        # packing that times out has already spent its share, and charging a
        # second one doubled the wall clock straight past the caller's limit.
        retry = time_limit - (time.perf_counter() - t0)
        if retry >= 2.0:
            first = _solve_once(data, retry, gaps=False, hint=None,
                                strict=False, rules=rules)
        strict = False

    if not optimise_gaps or first.status == "infeasible" or not first.entries:
        first.diagnostics = diagnostics + first.diagnostics
        first.stats["wall_seconds"] = round(time.perf_counter() - t0, 2)
        first.stats["phases"] = 1
        return first

    remaining = time_limit - (time.perf_counter() - t0)
    if remaining < 2.0:
        first.diagnostics = diagnostics + first.diagnostics
        first.stats["wall_seconds"] = round(time.perf_counter() - t0, 2)
        first.stats["phases"] = 1
        return first

    second = _solve_once(data, remaining, gaps=True, hint=first.entries, strict=strict, rules=rules)

    # Never hand back something worse than phase one. Ranked the way the
    # school would rank it: place every lesson first, then avoid teaching
    # without a break, and only then worry about idle time.
    def rank(r: SolveResult) -> tuple:
        s = r.stats
        return (
            s.get("unplaced_periods") or 0,
            s.get("long_runs") or 0,
            s.get("teacher_gaps") or 0,
        )

    best = second if (second.entries and rank(second) <= rank(first)) else first

    best.diagnostics = diagnostics + best.diagnostics
    best.stats["wall_seconds"] = round(time.perf_counter() - t0, 2)
    best.stats["phases"] = 2
    best.stats["gaps_before_optimising"] = first.stats.get("teacher_gaps")
    best.stats["phase1_seconds"] = first.stats.get("solve_seconds")
    return best


def _solve_once(data: dict, time_limit: float, gaps: bool,
                hint: list[dict] | None, strict: bool = True,
                rules: Rules | None = None) -> SolveResult:
    t0 = time.perf_counter()

    assignments = data["assignments"]
    slots = sorted(data["slots"], key=lambda s: (s["day_of_week"], s["slot_index"]))
    slot_ids = [s["id"] for s in slots]
    by_day: dict[int, list[dict]] = defaultdict(list)
    for s in slots:
        by_day[s["day_of_week"]].append(s)
    n_days = len(by_day)

    diagnostics: list[Diagnostic] = []
    model = cp_model.CpModel()

    # x[assignment, slot] — this assignment is taught in this slot.
    x: dict[tuple[str, str], cp_model.IntVar] = {}
    for a in assignments:
        for sid in slot_ids:
            x[a["id"], sid] = model.NewBoolVar(f"x_{a['id'][:8]}_{sid[:8]}")

    # --- curriculum, with slack so shortfall is reported not hidden ----
    slack: dict[str, cp_model.IntVar] = {}
    for a in assignments:
        need = a["periods_per_week"]
        s = model.NewIntVar(0, need, f"slack_{a['id'][:8]}")
        slack[a["id"]] = s
        model.Add(sum(x[a["id"], sid] for sid in slot_ids) + s == need)

    # --- a teacher is in one place at a time ---------------------------
    by_teacher: dict[str, list[dict]] = defaultdict(list)
    for a in assignments:
        by_teacher[a["teacher_id"]].append(a)
    for tid, group in by_teacher.items():
        for sid in slot_ids:
            model.AddAtMostOne(x[a["id"], sid] for a in group)

    # --- a class is in one lesson at a time ----------------------------
    # When a class's curriculum exactly fills the week — the usual case in an
    # Indian school, where every period has a subject — say so with
    # ExactlyOne. It is a far stronger propagator than AtMostOne and takes the
    # exact-packing search from ~9s to under a second.
    #
    # It is only sound while no shortfall is expected, though: slack lets
    # periods go unplaced, which would leave a class slot empty and make
    # ExactlyOne unsatisfiable. `strict` is therefore off whenever preflight
    # has already found the school over-committed.
    by_class: dict[str, list[dict]] = defaultdict(list)
    for a in assignments:
        by_class[a["class_id"]].append(a)

    exactly_packed = 0
    for cid, group in by_class.items():
        total = sum(a["periods_per_week"] for a in group)
        full_week = total == len(slot_ids)
        if full_week:
            exactly_packed += 1
        for sid in slot_ids:
            lits = [x[a["id"], sid] for a in group]
            if full_week and strict:
                model.AddExactlyOne(lits)
            else:
                model.AddAtMostOne(lits)

    # --- spread each subject across the week ---------------------------
    # A class's Maths should not all land on Monday. The cap is the smallest
    # that still admits a solution: ceil(periods / days).
    by_class_subject: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for a in assignments:
        by_class_subject[a["class_id"], a["subject_id"]].append(a)
    for (_cid, _sub), group in by_class_subject.items():
        total = sum(a["periods_per_week"] for a in group)
        cap = max(1, math.ceil(total / n_days))
        for day, day_slots in by_day.items():
            model.Add(
                sum(x[a["id"], s["id"]] for a in group for s in day_slots) <= cap
            )

    # --- labs are the only scarce room ---------------------------------
    lab_assignments: dict[str, list[dict]] = defaultdict(list)
    for a in assignments:
        if a["requires_lab"]:
            lab_assignments[a["lab_type"]].append(a)
    for lab_type, group in lab_assignments.items():
        capacity = data["lab_capacity"].get(lab_type, 0)
        for sid in slot_ids:
            model.Add(sum(x[a["id"], sid] for a in group) <= capacity)

    # --- teacher unavailability ----------------------------------------
    for tid, blocked in data.get("unavailable", {}).items():
        for a in by_teacher.get(tid, []):
            for sid in blocked:
                model.Add(x[a["id"], sid] == 0)

    # --- is this teacher busy in this slot? -----------------------------
    # Built once and reused by the daily cap, the consecutive-run cap and the
    # objective. AtMostOne above guarantees the sum is 0 or 1.
    works: dict[tuple[str, int, int], cp_model.IntVar] = {}
    for tid, group in by_teacher.items():
        for day, day_slots in by_day.items():
            for i, s in enumerate(day_slots):
                w = model.NewBoolVar(f"w_{tid[:6]}_{day}_{i}")
                model.Add(w == sum(x[a["id"], s["id"]] for a in group))
                works[tid, day, i] = w

    # --- nobody teaches the whole day -----------------------------------
    caps = {
        day: min(rules.max_periods_per_day, len(ds))
        for day, ds in by_day.items()
    }
    total_cap = sum(caps.values())

    heavy_days: list[cp_model.IntVar] = []
    for tid in by_teacher:
        week_owed = sum(a["periods_per_week"] for a in by_teacher[tid])
        week_slack = [slack[a["id"]] for a in by_teacher[tid]]

        for day, day_slots in by_day.items():
            n = len(day_slots)
            todays = [works[tid, day, i] for i in range(n)]
            cap = caps[day]
            model.Add(sum(todays) <= cap)

            # The mirror of the cap, and the reason this model solves at all.
            # A teacher owing 27 lessons who can do at most 5 on each of the
            # other five days must do at least 2 today. That is implied by the
            # constraints above, but CP-SAT cannot see it: the weekly total
            # lives on the assignment variables, the daily cap on these. Say it
            # out loud and a 25%-of-the-time feasibility search becomes
            # reliable. Written with slack so it stays true when the school is
            # short-staffed and lessons go unplaced.
            elsewhere = total_cap - cap
            if week_owed > elsewhere:
                model.Add(
                    sum(todays) + sum(week_slack) + elsewhere >= week_owed)

            # Only built when the objective will actually use them. Phase 1
            # cares solely about placing periods, and making it carry a
            # thousand reified booleans it never reads is what turned a
            # complete solve into thirteen unplaced lessons.
            if gaps and rules.balance_daily_load and cap < n:
                # A day AT the cap is allowed but tiring. Counting them lets
                # the objective prefer 5,5,4,4,4,4 over 5,5,5,5,5,1.
                at_cap = model.NewBoolVar(f"cap_{tid[:6]}_{day}")
                model.Add(sum(todays) >= cap).OnlyEnforceIf(at_cap)
                model.Add(sum(todays) <= cap - 1).OnlyEnforceIf(at_cap.Not())
                heavy_days.append(at_cap)

    # --- a break after so many lessons in a row -------------------------
    # A sliding window: within any stretch of (limit + 1) slots, at most
    # `limit` may be taught, which forces a free period into every longer run.
    #
    # Enforced only if the school insists. By default each violated window is
    # merely expensive, so the solver strips out nearly all long runs but
    # never abandons a lesson to do it.
    run = rules.preferred_max_consecutive
    long_runs: list[cp_model.IntVar] = []
    # Soft penalties are pointless in phase 1, which has no comfort objective,
    # and their reified booleans slow the feasibility search considerably.
    if rules.enforce_consecutive or gaps:
        for tid in by_teacher:
            for day, day_slots in by_day.items():
                n = len(day_slots)
                if run >= n:
                    continue
                for start_i in range(n - run):
                    window = [
                        works[tid, day, start_i + k] for k in range(run + 1)
                    ]
                    if rules.enforce_consecutive:
                        model.Add(sum(window) <= run)
                    else:
                        over = model.NewBoolVar(f"run_{tid[:6]}_{day}_{start_i}")
                        # over == 1 whenever the whole window is taught.
                        model.Add(sum(window) <= run).OnlyEnforceIf(over.Not())
                        model.Add(sum(window) == run + 1).OnlyEnforceIf(over)
                        long_runs.append(over)

    # --- warm start -----------------------------------------------------
    if hint:
        chosen = {(e["assignment_id"], e["slot_id"]) for e in hint}
        for key, var in x.items():
            model.AddHint(var, 1 if key in chosen else 0)

    # --- objective ------------------------------------------------------
    terms = [SLACK_WEIGHT * s for s in slack.values()]

    if gaps:
        # Teaching without a break is the thing this optimiser exists to
        # avoid, so it is the most expensive item short of losing a lesson.
        terms += [LONG_RUN_WEIGHT * r for r in long_runs]

        # Spread the week out. With a hard daily cap in place, minimising the
        # number of days AT that cap is what turns 5,5,5,5,5,1 into
        # 5,5,4,4,4,4.
        terms += [HEAVY_DAY_WEIGHT * h for h in heavy_days]

        # Idle time still counts, but only faintly, and it can no longer be
        # driven to zero by stacking the day into one solid block — the run
        # cap forbids that. What it now discourages is keeping a teacher at
        # school from first period to last for two scattered lessons.
        for tid in by_teacher:
            for day, day_slots in by_day.items():
                n = len(day_slots)
                todays = [works[tid, day, i] for i in range(n)]

                # first taught index, and last taught index + 1
                firsts, lasts = [], []
                for i, w in enumerate(todays):
                    v = model.NewIntVar(0, n, f"v_{tid[:6]}_{day}_{i}")
                    model.Add(v == i).OnlyEnforceIf(w)
                    model.Add(v == n).OnlyEnforceIf(w.Not())
                    firsts.append(v)

                    u = model.NewIntVar(0, n, f"u_{tid[:6]}_{day}_{i}")
                    model.Add(u == i + 1).OnlyEnforceIf(w)
                    model.Add(u == 0).OnlyEnforceIf(w.Not())
                    lasts.append(u)

                first = model.NewIntVar(0, n, f"first_{tid[:6]}_{day}")
                last = model.NewIntVar(0, n, f"last_{tid[:6]}_{day}")
                model.AddMinEquality(first, firsts)
                model.AddMaxEquality(last, lasts)

                # Named gap_var, not `gaps`: that is the boolean parameter of
                # this function, and shadowing it puts an IntVar into stats.
                gap_var = model.NewIntVar(0, n, f"gap_{tid[:6]}_{day}")
                # span minus periods taught, floored at zero so an idle day
                # (first = n, last = 0) contributes nothing.
                model.Add(gap_var >= last - first - sum(todays))
                terms.append(GAP_WEIGHT * gap_var)

    model.Minimize(sum(terms))

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = time_limit
    solver.parameters.num_workers = 8
    status = solver.Solve(model)

    elapsed = time.perf_counter() - t0

    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        diagnostics.append(Diagnostic(
            "error", "no_solution",
            "No timetable could be produced within the time limit.",
            f"Solver returned {solver.StatusName(status)}. "
            f"The problems listed above are the likely cause.",
        ))
        return SolveResult(
            status="infeasible",
            diagnostics=diagnostics,
            stats={
                "solve_seconds": round(elapsed, 2),
                "wall_seconds": round(elapsed, 2),
                "variables": len(x),
                "solver_status": solver.StatusName(status),
            },
        )

    # --- read the solution ---------------------------------------------
    entries: list[dict] = []
    placed_by_slot: dict[str, list[dict]] = defaultdict(list)
    for a in assignments:
        for sid in slot_ids:
            if solver.Value(x[a["id"], sid]):
                entry = {"assignment_id": a["id"], "slot_id": sid, "room_id": None}
                entries.append(entry)
                placed_by_slot[sid].append((a, entry))

    _assign_rooms(placed_by_slot, data)

    # --- report shortfall ------------------------------------------------
    total_unplaced = 0
    for a in assignments:
        missing = solver.Value(slack[a["id"]])
        if not missing:
            continue
        total_unplaced += missing
        teacher = data["teacher_by_id"].get(a["teacher_id"], {})
        cname = data["class_by_id"].get(a["class_id"], {}).get("name", "?")
        load = sum(z["periods_per_week"] for z in by_teacher[a["teacher_id"]])
        diagnostics.append(Diagnostic(
            "error", "unplaced",
            f"{cname} {a['subject_name']}: {missing} of {a['periods_per_week']} "
            f"periods could not be placed.",
            f"{teacher.get('full_name', 'The teacher')} is committed to {load} "
            f"periods across {len(slot_ids)} available slots.",
        ))

    gaps_total = _count_gaps(entries, data, slots)
    long_run_days = _count_long_runs(
        entries, data, slots, rules.preferred_max_consecutive)

    stats = {
        "solve_seconds": round(elapsed, 2),
        "wall_seconds": round(elapsed, 2),
        "variables": len(x),
        "fully_packed_classes": exactly_packed,
        "strict_packing": strict,
        "assignments": len(assignments),
        "slots": len(slot_ids),
        "entries": len(entries),
        "unplaced_periods": total_unplaced,
        "teacher_gaps": gaps_total,
        "long_runs": long_run_days,
        "rules": rules.as_dict(),
        "gap_objective_used": gaps,
        "objective": solver.ObjectiveValue(),
        "solver_status": solver.StatusName(status),
        "branches": solver.NumBranches(),
        "conflicts": solver.NumConflicts(),
    }

    return SolveResult(
        status="optimal" if status == cp_model.OPTIMAL else "feasible",
        entries=entries,
        diagnostics=diagnostics,
        stats=stats,
    )


def _assign_rooms(placed_by_slot: dict, data: dict) -> None:
    """Bookkeeping after the search: home room by default, a free lab where
    the assignment needs one. Lab capacity was already enforced per slot, so
    a room is always available here."""
    labs: dict[str, list[str]] = data["labs_by_type"]
    home: dict[str, str | None] = data["home_room_by_class"]

    for _sid, items in placed_by_slot.items():
        used: dict[str, int] = defaultdict(int)
        for a, entry in items:
            if a["requires_lab"]:
                pool = labs.get(a["lab_type"], [])
                idx = used[a["lab_type"]]
                entry["room_id"] = pool[idx] if idx < len(pool) else None
                used[a["lab_type"]] += 1
            else:
                entry["room_id"] = home.get(a["class_id"])


def _count_long_runs(entries: list[dict], data: dict, slots: list[dict],
                     limit: int) -> int:
    """Teacher-days where someone teaches more than `limit` lessons back to
    back. Measured from the solution rather than read off the model, so it
    stays honest whether the rule was hard, soft, or off."""
    ordered = sorted(slots, key=lambda s: (s["day_of_week"], s["slot_index"]))
    position = {}
    for s in ordered:
        position.setdefault(s["day_of_week"], []).append(s["slot_index"])
    index_of = {
        (d, si): i for d, sis in position.items() for i, si in enumerate(sis)
    }
    slot_meta = {s["id"]: s for s in slots}
    teacher_of = {a["id"]: a["teacher_id"] for a in data["assignments"]}

    per_day: dict[tuple[str, int], list[int]] = defaultdict(list)
    for e in entries:
        s = slot_meta[e["slot_id"]]
        key = (teacher_of[e["assignment_id"]], s["day_of_week"])
        per_day[key].append(index_of[s["day_of_week"], s["slot_index"]])

    over = 0
    for idxs in per_day.values():
        idxs.sort()
        best = current = 1
        for a, b in zip(idxs, idxs[1:]):
            current = current + 1 if b == a + 1 else 1
            best = max(best, current)
        if best > limit:
            over += 1
    return over


def _count_gaps(entries: list[dict], data: dict, slots: list[dict]) -> int:
    """Free periods sandwiched between taught periods, summed over teachers."""
    slot_meta = {s["id"]: s for s in slots}
    order = {s["id"]: i for i, s in enumerate(
        sorted(slots, key=lambda s: (s["day_of_week"], s["slot_index"])))}
    teacher_of = {a["id"]: a["teacher_id"] for a in data["assignments"]}

    per_day: dict[tuple[str, int], list[int]] = defaultdict(list)
    for e in entries:
        s = slot_meta[e["slot_id"]]
        per_day[teacher_of[e["assignment_id"]], s["day_of_week"]].append(order[e["slot_id"]])

    total = 0
    for _key, idxs in per_day.items():
        if len(idxs) > 1:
            total += (max(idxs) - min(idxs) + 1) - len(idxs)
    return total
