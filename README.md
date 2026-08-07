# SchoolSync AI

AI-powered school operations platform. Flutter Web + FastAPI + Supabase.

**Status: Phase 1 complete**

| Phase | |
|---|---|
| 0 — Foundation | schema, RLS, seed data, auth, role routing |
| 1 — AI Document Reader | any school form → records, via editable templates |
| 2 — Timetable engine | CP-SAT solver with conflict diagnosis |
| 3 — Attendance & cover | default-to-present marking, leave approval, live Action Board |
| 4 — Predictive staffing | interpretable forecast of where cover will run short |

---

## Phase 1: the AI Document Reader

Photograph a handwritten form; Gemini extracts it against a **template**; a
validation layer checks the result; a human reviews and approves; only then
does a record appear.

### Templates — every school prints its own paperwork

Nothing about "admission form" is hardcoded. A template names the fields to
extract, their types, and what a committed document becomes:

| Target | Produces |
|---|---|
| `student` | a row in `students` |
| `leave_request` | a row in `leave_requests` |
| `data_only` | a row in `extracted_records` — mark sheets, fee receipts, TCs |

**Onboarding a new form is itself an AI step.** An admin photographs a *blank*
copy; the model reads the printed labels off it and drafts a field list with
types and destinations; the admin edits it and saves. The proposal is never
saved unreviewed.

Two templates ship built in: **Standard Admission Form** (→ student) and
**Leave / Medical Note** (→ leave request).

### The leave note closes the loop

Photograph a doctor's note → it becomes a *pending* leave request for the
teacher **named on the note** → their HOD approves → the substitution matcher
runs → ranked cover appears on the Action Board. Nobody types any of it.

The hard part is not the extraction, it is the name. A note says "Nisha Nair";
the school has 55 teachers. Match the wrong one and you have filed someone
else's sick leave. `api/app/services/people.py` therefore resolves confidently
or not at all:

| Written on the note | Result |
|---|---|
| `Mrs. Nishá Nair` | resolves — honorifics and accents stripped |
| `Priya` | resolves, flagged *"read as Priya Sharma, confirm this"* |
| `Isha` where two Ishas exist | refused as ambiguous, both offered |
| `Nisha Nar` | **suggested, never chosen** — "Did you mean Nisha Nair?" |

The check runs at extraction time as well as on commit, so the reviewer sees
the problem on screen rather than hitting a failed save.

Extraction then builds its Gemini response schema from the template at run
time, so a school's own form is a first-class citizen, not a special case.

### Validation is type-driven, not name-driven

`api/app/services/validation.py` is deliberately separate and fully
deterministic. Model confidence is directional, not calibrated — a model can be
fluently confident about an impossible value. Rules come from each field's
declared **type**, so a custom form gets the same checks with no new code:

| Field type | Catches |
|---|---|
| `grade` | a form reading "12" when the school runs 1–10 |
| `phone` | `1234568911` — well-formed, not a real Indian mobile |
| `date` | unparseable, future, or impossible dates |
| `number` / `email` / `choice` | wrong shape, or an answer outside the options |

Target-specific cross-checks run only where they make sense — age against class
for a `student` template, end-before-start for a `leave_request`.

Issues are deduplicated per field per concern. A review screen that raises the
same warning twice gets click-through-accepted, which defeats the purpose. For
the same reason, day-month order is *not* flagged on every Indian date; it is
raised only when the age is already implausible and swapping would fix it.

### Model fallback

Free-tier quota is per model per day and **tight** — `gemini-3.6-flash` allows
only 20 requests/day. `MODEL_CHAIN` in `document_ai.py` tries models in order
and falls through on a quota error, since each has its own allowance. The
document records which model actually answered.

### Review UI

The photograph sits beside the extracted fields, every value editable,
colour-coded four ways: green (confident), amber (check this), red (unreadable
or must fix), grey (not on the form). Field order, labels and input types all
come from the template. Dates display as dd/mm/yyyy and echo the date in words
underneath, because `10/03` and `03/10` look near-identical at a glance. The
commit sends the values **on screen**, not the ones the model returned.

```powershell
cd api
..\.venv\Scripts\python.exe test_extract.py         # CLI report over ../samples
..\.venv\Scripts\python.exe -m pytest tests/ -q     # 100 unit tests
..\.venv\Scripts\python.exe test_e2e_documents.py   # 26 end-to-end checks
..\.venv\Scripts\python.exe test_e2e_templates.py   # 44 template-engine checks
..\.venv\Scripts\python.exe test_e2e_leave_note.py  # 25 checks, note -> cover
```

---

## Run it

**For demos, or any time the UI feels slow — use release:**

```powershell
powershell -ExecutionPolicy Bypass -File .\serve-release.ps1
```

`flutter run` builds in debug via DDC, which loads ~930 separate scripts and
runs everything unoptimised. On Flutter web that is 5–10× slower than release
and shows up most obviously as laggy scrolling. Debug is right while writing
code (hot reload); release is right whenever someone is going to look at it.

**For development, with hot reload:**

```powershell
powershell -ExecutionPolicy Bypass -File .\start-dev.ps1
```

Or manually, in two terminals:

```powershell
# terminal 1 — API
cd api
..\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --port 8000

# terminal 2 — app
cd app
C:\dev\flutter\bin\flutter.bat run -d chrome --web-port 5000
```

| | |
|---|---|
| App | http://127.0.0.1:5000 |
| API docs (Swagger) | http://127.0.0.1:8000/docs |
| DB health + row counts | http://127.0.0.1:8000/health/db |

### Demo logins

Password for every account: `Demo@12345`

| Email | Lands on |
|---|---|
| `admin@school.test` | Admin Dashboard |
| `hod@school.test` | Teacher Portal — Science HOD, can approve leave |
| `teacher@school.test` | Teacher Portal — plain teacher |

These three addresses are pinned in `seed.py` (`FIXED_EMAILS`) so the app's
quick-fill buttons survive a re-seed; the other 70 teachers get generated names
and addresses.

---

## Phase 2: the timetable engine

`api/app/services/timetable.py` — OR-Tools CP-SAT.

### Why the model is small

Variables are indexed on **teaching assignments**, not on the cross product.
A variable per (teacher, class, room, slot) would be 72 × 40 × 44 × 36 — over
four million booleans — and it still could not express *"9A needs 7 periods of
Maths a week"*, because it has no subject dimension. Indexing on the
`teaching_assignments` rows a school already keeps gives **11,520** variables
that mean exactly the right thing.

Rooms are not a dimension either. Indian schools are home-room based: the class
owns a room and teachers move. Only labs are scarce, so only labs are rationed,
as a capacity constraint per slot. Rooms are assigned after the solve, where it
is bookkeeping rather than search.

### Two phases

| Phase | Objective | Result on the seeded school |
|---|---|---|
| 1 | place every period | complete timetable in **0.83 s** |
| 2 | minimise teacher idle gaps, warm-started from phase 1 | gaps **551 → 212** |

Phase 2 is seeded with phase 1's answer, so it can only improve on it — a
timeout degrades to "valid but gappier", never to "incomplete".

### Conflict diagnosis instead of INFEASIBLE

The worst demo outcome is a red `INFEASIBLE` with no explanation. Two guards:

**Preflight arithmetic** runs before any search. If a teacher owes 40 periods
in a 36-period week, no amount of solving fixes it, and counting that up front
is instant:

```
Dhruv Chauhan is assigned 50 periods but the week only has 36.
  Over-committed by 14 periods. Move a class to another teacher
  in the same department.
```

**Slack variables** on every curriculum requirement mean an over-constrained
school still returns a near-miss plus a per-class explanation:

```
4C Maths: 4 of 7 periods could not be placed.
  Dhruv Chauhan is committed to 50 periods across 36 available slots.
```

### One subtlety worth knowing

"Every class slot is filled" (`AddExactlyOne`) is a far stronger propagator
than `AddAtMostOne` and is what takes phase 1 from ~9 s to under a second. But
it is only *true* when the school is properly staffed — slack lets periods go
unplaced, which leaves a class slot empty and makes `ExactlyOne` unsatisfiable.
So strict packing is switched off whenever preflight has found an
impossibility, and there is an automatic relaxed retry if a strict solve comes
back infeasible for a reason the arithmetic missed.

```powershell
cd api
..\.venv\Scripts\python.exe test_solver.py --stress   # solver + over-committed fixture
..\.venv\Scripts\python.exe test_e2e_timetable.py     # 31 API checks
```

---

## Phase 3: attendance, leave and cover

### Attendance is shaped around the arithmetic

In a class of 45, roughly 42 are present. Reading 45 names to find 3 absentees
is the wrong shape of work. The roster therefore arrives with **everyone
already marked present** and the teacher taps only the empty desks; tapping
cycles present → absent → late. One bulk write covers the class, and reopening
a period shows what was recorded rather than resetting to the default.

### Approval is decentralised

A teacher files leave; their **head of department** reviews it, not the
administrator. The HOD panel only renders for a teacher with `is_approver` and
only shows their own department — enforced by RLS, not by the UI.

### The substitution matcher

`api/app/services/substitution.py`. A greedy ranked match, not an
optimisation: when a teacher goes off sick the admin wants a shortlist they can
act on in seconds, with the reasoning visible. Three criteria in strict
priority order:

1. **Availability** — genuinely free in that exact slot, and not themselves away
2. **Domain match** — same department, so the cover period is worth something
3. **Load balance** — of those left, whoever is carrying least that day

Every suggestion ships with the rationale that produced it —
*"free this period · same department · 3 periods that day"* — because "why this
person?" is the first question an administrator asks.

### The Action Board updates itself

Approving leave writes suggestions; Postgres pushes the change over a
websocket; the admin's board redraws. No polling, no refresh button needed.
That is the demo moment: **two browser windows side by side**, a teacher
approves leave in one, and the count changes in the other while nobody touches
it.

```powershell
cd api
..\.venv\Scripts\python.exe test_e2e_phase3.py   # 49 checks over the whole pipeline
```

Those checks include the ones that matter for suggestion quality: that the
top-ranked substitute is genuinely free in that slot, that the absent teacher
is never offered as their own cover, and that same-department picks are
preferred where one exists.

---

## Phase 4: predictive staffing

`api/app/services/forecast.py`. **Deliberately not Prophet** — it needs years
of seasonality to beat a naive baseline and this school has 90 days, it drags
in a Stan toolchain that pushes the container past 1 GB, and it cannot be
explained. An administrator is being asked to call someone in on the strength
of this number, and "the model said so" is not a reason.

Every figure decomposes into arithmetic you can say out loud:

```
expected absences = base rate × weekday effect × seasonal effect × headcount
```

Rates are **measured from the school's own leave history**, not assumed — the
seeded Monday spike comes back out of the data at ×1.27. Capacity comes from
the free periods the live timetable actually leaves. The chance of a shortage
is Poisson, the standard model for counting rare independent events, and one
line to justify.

### Two tiers of cover, because they fail differently

| Tier | Meaning | Severity |
|---|---|---|
| in-department | a Science teacher covers Science | **warning** — quality drops |
| school-wide | anyone free covers it | **critical** — nobody is available |

### Recurring findings are said once

"PE has no spare capacity on Friday" is true of *every* Friday. Emitting it per
date produced six near-identical cards, which is the same cry-wolf failure the
document reader avoids. Structural findings are now collapsed into one card per
department listing the weekdays, and marked as a staffing shape rather than an
event.

### Why the seeded school was restaffed

The forecast initially reported zero risk — correctly. The school had 72
teachers carrying 20 of 36 periods, 44% free time, far more generous than a
real Indian secondary school. That over-staffing also made substitution
trivial, since someone was always free. Headcount is now 55 at ~27 periods
each, which leaves the scarcity the cover and forecasting engines exist to
manage. The timetable still solves in 0.89 s, and teacher gaps actually
improved.

```powershell
curl http://127.0.0.1:8000/forecast/staffing   # with an admin bearer token
```

---

## Layout

```
api/            FastAPI backend
  app/          config, Supabase clients, JWT auth, routes
  seed.py       generates the whole demo school
  verify_*.py   schema + RLS verification scripts
  Dockerfile    used in Phase 5
app/            Flutter Web client
  lib/core/     config, auth controller, API client
  lib/screens/  login, splash, admin dashboard, teacher portal
db/             SQL migrations — apply in the Supabase SQL editor, in order
```

---

## The seeded school

| | |
|---|---|
| Classes | 40 (grades 1–10 × sections A–D) |
| Students | 1,800 (45/class) |
| Staff | 73 (1 admin + 72 teachers, 1 HOD per department) |
| Departments | 7 |
| Subjects | 6 core + Physical Education |
| Teaching slots | 36/week (6 periods × Mon–Sat) |
| Teaching assignments | 320, totalling 1,440 teacher-periods/week |
| Leave history | 284 requests over 90 days |
| Attendance | 18,000 marks over 10 days |

Re-seed at any time:

```powershell
cd api
..\.venv\Scripts\python.exe seed.py --reset
```

### Why primary and secondary run different curricula

Grades 1–5 get no lab periods; grades 6–10 take Science 5×/week in the home
room plus 2× practical in a lab, and Computer Science 2× plus 1× in the
computer lab.

That split is load-bearing, not decoration. Labs are the only scarce room:
2 science labs × 36 slots = 72, and 1 computer lab × 36 = 36. If all 40 classes
needed practicals, demand would be 80 and 40 — infeasible before the Phase 2
solver even starts. Restricting lab work to grades 6–10 matches how Indian
primaries actually run and keeps demand at 40/72 and 20/36.

`seed.py` prints both figures and warns if either exceeds capacity.

### Why attendance history is only 10 days

Per-period marks for every student across 90 days would be near a million rows
— slow over PostgREST and wasteful on the free tier. The Phase 4 forecast reads
*teacher leave* (seeded across the full 90 days, with Monday/Friday spikes and
a flu week), so student attendance history is cosmetic. 10 days of first-period
marks is enough to make the dashboard look lived-in.

---

## Security model

`GoRouter` only decides which screen to show. **Row Level Security is the actual
access control**, defined in `db/002_rls.sql`:

- a teacher sees only their own leave requests and only their own classes' students
- an HOD additionally sees leave from their own department, and nothing beyond it
- only an admin can write to `students`, `classes`, `timetable_*`

Verify against the live database with real logins:

```powershell
cd api
..\.venv\Scripts\python.exe verify_rls.py
```

The `service_role` key bypasses RLS and lives only in `api/.env`, never in the
Flutter bundle. The anon key is public by design and ships in the client.

---

## Database changes

Migrations in `db/` are applied by pasting them into the Supabase SQL editor,
in filename order. Both are idempotent and safe to re-run.

> `002_rls.sql` drops **all** policies in the `public` schema before recreating
> them, so it stays re-runnable. If you hand-write a policy in the dashboard,
> add it to that file or it will be dropped on the next run.

Add `DATABASE_URL` to `api/.env` to allow migrations to be applied directly
instead of by hand.
