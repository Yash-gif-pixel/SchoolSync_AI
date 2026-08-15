# SchoolSync AI

AI-powered school operations platform. Flutter Web + FastAPI + Supabase.

**Live**

| | |
|---|---|
| App | https://schoolsync-ai.yashmalik0904.workers.dev |
| API | https://schoolsync-api-6frq.onrender.com |
| API reference | https://schoolsync-api-6frq.onrender.com/docs |

Sign in as `admin@school.test` with the password below, or use the quick-fill
buttons. The first load can take up to a minute if the API has been idle —
free hosting sleeps, and the app says so rather than spinning silently.

| Phase | |
|---|---|
| 0 — Foundation | schema, RLS, seed data, auth, role routing |
| 1 — AI Document Reader | any school form → records, via editable templates |
| 2 — Timetable engine | CP-SAT solver with conflict diagnosis |
| 3 — Attendance & cover | default-to-present marking, leave approval, live Action Board |
| 4 — Predictive staffing | interpretable forecast of where cover will run short |
| 5 — Deployment | Cloudflare Workers + Render + Supabase — see *Deploying* |

Built after the original five phases:

| | |
|---|---|
| Exam seating | per-day plans that seat a grade in its own rooms, nobody beside their own class |
| School events | Annual Day and the like — named staff, multi-day, feeds the forecast |
| Directory | 1,800 students by class, 59 staff by department |
| Leadership | principal, vice principal and HODs, appointed from the dashboard |

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

Two example templates are seeded so the app is usable on first run — one
producing a student, one producing a leave request. They are starting points,
not a standard: there is no such thing as a standard admission form, and a
school is expected to photograph its own blank paperwork and let the model
draft the template from it.

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

**Locally, for demos or any time the UI feels slow — use release:**

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
| `admin@school.test` | Admin Dashboard — office staff, not the principal |
| `principal@school.test` | Teacher Portal — heads the school |
| `vp@school.test` | Teacher Portal — reviews leave for the heads of department |
| `hod@school.test` | Teacher Portal — Science HOD, approves their department |
| `teacher@school.test` | Teacher Portal — plain teacher |

The three original addresses are pinned in `seed.py` (`FIXED_EMAILS`) so the
app's quick-fill buttons survive a re-seed; the rest of the staff get generated
names and addresses.

The principal and vice principal are created by `make_leadership.py` rather
than by the seed, because auth users cannot be created from SQL. It is
re-runnable — an existing account is reused rather than duplicated.

```powershell
cd api
..\.venv\Scripts\python.exe make_leadership.py
```

The login page also carries **Admin (new)**, which is not a login. It opens a
preview of first-run setup — add classes, name students, generate an invite
link — that writes nothing at all. It exists to show how a school onboards
without touching the seeded one.

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

### No overlapping leave

A teacher cannot be on two overlapping leaves at once — otherwise the
substitution matcher arranges cover for the same periods twice. Leave arrives
by two doors, the teacher portal form and a scanned medical note, so the check
lives in `services/leave_rules.py` and both call it. It also runs again at
approval time, and a Postgres exclusion constraint
(`db/005_no_overlapping_leave.sql`) makes the rule true regardless of which
code path is used:

```sql
exclude using gist (teacher_id with =, daterange(from_date, to_date, '[]') with &&)
  where (status in ('pending_incharge', 'approved'))
```

Rejected and cancelled requests are excluded, so someone refused for a date can
always re-apply for it.

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
..\.venv\Scripts\python.exe test_e2e_phase3.py       # 49 checks, whole pipeline
..\.venv\Scripts\python.exe test_e2e_leave_clash.py  # 16 checks, overlap rules
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

## Exam seating

`api/app/services/seating.py`. Not a solver — see below for why.

An exam is a **season**, not a day. Name it, put grades on its roster, then mark
each day on a calendar and say which grades sit that day. Seating is planned
**per day**, which is what makes the room rule hold: on Tuesday only Tuesday's
grades leave their classrooms and the rest of the school has a normal day.

**The rule that shapes everything:** only the rooms belonging to the grades
actually sitting are used. Grade 1 writes in Grade 1's four rooms. So the seat
supply is fixed by the selection, and the anti-copying guarantee has to come
from *arrangement* rather than from empty space.

Two stages, because they are different problems:

1. **Deal students to rooms.** Each section is spread evenly across every
   available room. Keeping a section together would make stage 2 impossible —
   a room of nothing but 1A has no valid arrangement.
2. **Lay out each room.** Walk the grid in reading order; at each seat take
   from whichever class has the most students still waiting, excluding any
   class already sitting to the left or directly in front.

Largest-remaining-first is the part that matters: serving the biggest group
while it still has legal seats is what stops it being stranded at the end with
only adjacent seats free.

**No CP-SAT here, unlike the timetable.** Rooms are independent once stage 1
has dealt the students, and grid colouring has a known-good greedy. A solver
would add a time limit and a failure mode in exchange for nothing. What it does
borrow is the honesty — every breach is counted, verified independently of the
code that placed the seats, and reported.

Measured on the seeded school:

| Selection | Students | Rooms | Occupancy | Same-class neighbours |
|---|---|---|---|---|
| Grade 1 | 180 | 4 | 90% | **0** |
| Grades 1+2 | 360 | 8 | 90% | **0** |
| Grades 1–6 | 1,080 | 24 | 90% | **0** |

At 90% occupancy students do sit shoulder to shoulder — just never beside
their own class. Physical spacing would need roughly twice the rooms, which
would break the rule above. That was the trade.

### Rooms have an address

`006_seating.sql` renumbers the 40 home rooms into two blocks:

| | Ground floor | First floor |
|---|---|---|
| **Block A** | `A-1`–`A-8` (grades 1–2) | `A-101`–`A-112` (grades 3–5) |
| **Block B** | `B-1`–`B-8` (grades 6–7) | `B-101`–`B-112` (grades 8–10) |

Eight and twelve rather than ten and ten so that no grade is split across two
floors — a grade sits its exam on one corridor.

---

## School events

Annual Day, Sports Day, an inspection — anything that takes staff off the
timetable without being leave. Name it, pick the days from a calendar, tick the
staff who will be tied up.

`calendar_events` already existed and already fed the forecast, but
`teachers_required` was a number somebody typed. It is now **derived from a
roster somebody actually chose**, so the forecast keeps reading the column it
always read while the number becomes trustworthy.

Two things follow from naming the individuals rather than a headcount:

- The **forecast** counts the event on every day it runs, not just the first.
- The **substitution matcher** will not offer somebody who is at the event, and
  says so when that leaves a period uncovered: *"No teacher is free this period
  — 11 are committed to Annual Day 2026."*

---

## Directory and leadership

The **Students** and **Staff** tiles on the admin dashboard are clickable.
Students opens the roll class by class; Staff opens the list by department,
with heads pinned to the top of their group.

The staff page is also the appointment desk. **Principal** and **Vice
Principal** show their holder or read *Vacant*; every teacher row has a menu to
make them head of their department. Appointing is a **swap done in one call** —
the unique indexes mean a new principal cannot be inserted while the old one
still holds the post, so the API stands the incumbent down in the same
transaction and reports who that was.

The administrator account is refused all three posts. It is office staff; the
principal runs the school.

> The student roll is 1,800 rows and PostgREST caps a select at 1,000, so
> `/directory/students` pages. Unpaged it would have stopped at a thousand
> names and nobody would have noticed until a parent asked.

---

## Layout

```
api/            FastAPI backend
  app/          config, Supabase clients, JWT auth, routes
  seed.py       generates the whole demo school
  verify_*.py   schema + RLS verification scripts
  Dockerfile    the image Render builds
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
| Staff | 59 — 1 admin, 57 teachers, plus principal and vice principal |
| Heads of department | 8 |
| Departments | 7 |
| Subjects | 6 core + Physical Education |
| Rooms | 44 — 40 home rooms (5 × 10 seats), 2 science labs, 1 computer lab, 1 sports |
| Teaching slots | 36/week (6 periods × Mon–Sat) |
| Teaching assignments | 320, totalling 1,440 teacher-periods/week |
| Leave history | ~215 requests over 90 days |
| Attendance | ~18,000 marks over 10 days |

Counts drift as the demo is used — leave gets filed, appointments change. The
figures above were read from the live database, not from `seed.py`.

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

### Two paths to the data, protected differently

Worth being precise about, because the answer differs:

| Path | Protected by |
|---|---|
| Flutter → Supabase directly (anon key) | **RLS** |
| Flutter → FastAPI → Supabase (`service_role`) | **the API's own auth guards** |

Every router uses the `service_role` client, so RLS is bypassed on that path by
design — the backend is trusted, which is exactly why its key never reaches the
browser. That makes `Depends(get_current_user)` and `Depends(require_admin)`
load-bearing rather than decorative. All 56 operations carry one; an
unauthenticated request gets `401` and writes nothing.

### The API docs are public, deliberately

`/docs`, `/redoc` and `/openapi.json` are served by default. Publishing the API
surface is not a vulnerability — authentication is the boundary, not obscurity,
and the web client calls these same URLs in the open regardless.

Turn them off once the database holds real student records, at which point they
are free reconnaissance with no compensating benefit:

```bash
DOCS_ENABLED=false
```

All three go at once. Hiding the two pages but leaving `openapi.json` up would
serve the same information as JSON.

---

## Deploying

Three services on three providers. Supabase was always hosted, so deploying
meant putting the other two somewhere public.

```
Browser  ->  Cloudflare Workers      Flutter web, static assets
                  |  HTTPS + JWT
             Render                  FastAPI in Docker
                  |  service_role
             Supabase                Postgres, Auth, Realtime
```

| | Where | Config |
|---|---|---|
| Flutter | Cloudflare Workers | [app/wrangler.toml](app/wrangler.toml) |
| FastAPI | Render | [render.yaml](render.yaml), [api/Dockerfile](api/Dockerfile) |
| Database | Supabase | migrations in `db/` |

### Order matters, because each step needs the previous one's address

```
1. deploy the API          -> learn its URL
2. build the app with that URL baked in -> deploy -> learn its URL
3. set CORS_ORIGINS on the API to the app's URL
```

Step 2 is the one that catches people. `API_BASE_URL` is compiled **into**
`main.dart.js` by `--dart-define`; it is not read at runtime. Change the API's
address and the frontend must be rebuilt, not reconfigured. Check a build with:

```bash
grep -c "your-api-host" build/web/main.dart.js   # expect > 0
grep -c "127.0.0.1:8000" build/web/main.dart.js  # expect 0
```

### Cloudflare build settings

Their build image has no Flutter, so the build command installs it — pinned to
the same version the tests run against, because `stable` drifts.

| Field | Value |
|---|---|
| Root directory | `app` |
| Deploy command | `npx wrangler deploy` |
| Env var | `API_BASE_URL` = the Render URL |

```bash
git clone https://github.com/flutter/flutter.git --depth 1 -b 3.44.8 $HOME/flutter \
  && export PATH="$HOME/flutter/bin:$PATH" \
  && flutter build web --release --dart-define=API_BASE_URL=$API_BASE_URL
```

### What bites

- **Cold starts.** Render's free tier sleeps after 15 minutes idle; the next
  request takes up to a minute. The app shows *"Waking the server"* rather than
  a bare spinner, because 50 seconds of silent spinning reads as broken. A
  10-minute ping on `/health/db` prevents it entirely — and keeps Supabase
  awake too, since that endpoint touches the database. Check the host's terms
  before relying on it; some treat keep-alive pings as abuse.
- **Supabase pauses free projects after ~7 days idle.** The API can be running
  perfectly and still fail because the database is asleep.
- **CORS must name the deployed frontend origin exactly.** No trailing slash,
  never `*` — credentials are sent with every request. The symptom is a page
  that loads normally with every data call failing, and only the browser
  console says why.
- **Paths in host settings are repo-relative.** `app`, not `C:\...\app`; the
  build runs on their Linux container against a clone of the repo.

---

## Database changes

Migrations in `db/` are applied by pasting them into the Supabase SQL editor,
in filename order. All are idempotent and safe to re-run.

| | |
|---|---|
| `001_schema.sql` | core tables |
| `002_rls.sql` | row level security |
| `003_templates.sql` | document templates |
| `004_leave_note_template.sql` | the second built-in template |
| `005_no_overlapping_leave.sql` | exclusion constraint on leave dates |
| `006_seating.sql` | rooms get a block/floor/seat grid; exams |
| `007_exam_schedule.sql` | an exam becomes a season of sittings |
| `008_events.sql` | multi-day events with a named staff roster |
| `009_vice_principal.sql` | `is_vice_principal` |
| `010_principal.sql` | `is_principal` |

Two are not purely additive and are called out in their own headers:

- **`006`** renames every home room — `Room 1A` becomes `A-1` — to give rooms a
  physical address the seating engine can reason about.
- **`007`** drops and recreates `seating_plans` and `seat_allocations`, because
  a plan keyed to a whole exam has no meaningful date once each day seats a
  different set of grades.

> `002_rls.sql` drops **all** policies in the `public` schema before recreating
> them, so it stays re-runnable. If you hand-write a policy in the dashboard,
> add it to that file or it will be dropped on the next run.

Add `DATABASE_URL` to `api/.env` to allow migrations to be applied directly
instead of by hand.
