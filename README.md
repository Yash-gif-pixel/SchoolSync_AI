# Smart School Ops Platform

AI-powered school operations platform. Flutter Web + FastAPI + Supabase.

**Status: Phase 0 complete** — foundation, schema, RLS, seed data, auth, role routing.

---

## Run it

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
| `ishaan.reddy@school.test` | Teacher Portal (plain teacher) |
| `isha.reddy@school.test` | Teacher Portal (HOD — can approve leave) |

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
| Classes | 20 (grades 6–10 × sections A–D) |
| Students | 900 (45/class) |
| Staff | 37 (1 admin + 36 teachers, 1 HOD per department) |
| Departments | 7 |
| Subjects | 6 core + Physical Education |
| Teaching slots | 36/week (6 periods × Mon–Sat) |
| Teaching assignments | 180, totalling 720 teacher-periods/week |
| Leave history | 145 requests over 90 days |
| Attendance | 9,000 marks over 10 days |

Re-seed at any time:

```powershell
cd api
..\.venv\Scripts\python.exe seed.py --reset
```

### Why the curriculum splits theory from lab

A class takes Science 5×/week in its home room plus 2× practical in a lab, and
Computer Science 2× plus 1× in the computer lab. If every Science period needed
a lab, demand would be 20 × 7 = 140 lab-periods against a capacity of 72
(2 labs × 36 slots) and the Phase 2 solver would be infeasible by construction.
As seeded, lab demand is 60 against a capacity of 108.

### Why attendance history is only 10 days

Per-period marks for every student across 90 days would be ~486,000 rows —
slow over PostgREST and wasteful on the free tier. The Phase 4 forecast reads
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
