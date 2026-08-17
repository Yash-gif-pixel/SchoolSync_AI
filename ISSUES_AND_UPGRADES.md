# SchoolSync AI — System Defects, Non-Working Components & Recommended Upgrades

> **Status: sections 1 and 2 are fixed** (2.4 excluded at the owner's request).
> Where the original diagnosis turned out to be wrong, the entry says so and
> records what was actually wrong instead. Section 3 remains a proposal list —
> see §5 for what was and was not built, and why.

---

## 1. Broken Parts & Critical Bugs

### 1.1 Outdated Function Import in `test_extract.py` — **FIXED**
- **File:** `api/test_extract.py`
- **Problem:** imported `extract_admission_form`, which no longer exists.
- **Also found:** the same file called `validate(raw)` with the old
  single-argument signature and read `result['is_admission_form']`, a key that
  was renamed to `matches_template`. Fixing only the import would have moved
  the crash two lines down.
- **Fix:** rewritten around the template-driven API. It loads the same template
  row the server would (`_load_template`), accepts `--template <name>` to read
  against any other one, and reports against the template's own field labels.

### 1.2 Missing Test Assets / `samples/` Directory — **FIXED**
- **Files:** `api/test_e2e_documents.py`, `api/test_extract.py`
- **Problem:** both read `../samples/`, which is gitignored — those scans are
  real children's admission paperwork and cannot be committed.
- **Fix:** `api/sample_forms.py` generates stand-ins. The synthetic admission
  form reproduces the two features the assertions are about: a struck-through
  year of birth with the correction beside it, and no address line at all. A
  real scan is still preferred when one is present, and
  `admission_sample(prefer=...)` makes sure an unrelated photograph in the
  folder is not used instead.
- **Also found:** Pillow was undeclared. `test_e2e_leave_note.py` imported it,
  but `requirements.txt` did not list it, so a fresh clone failed with a
  missing-package error that read like a missing fixture. Added.
- The medical-note generator moved into the same module, and both now render
  with a real TrueType face rather than Pillow's ~11px bitmap default.

### 1.3 Timetable Solver Test Budget Timeout — **FIXED, and it was not only the test**
- **Problem as reported:** `test_e2e_timetable.py` passed `time_limit: 20`,
  clamping phase 1 to 12s against the ~14.5s it needs.
- **What was actually wrong:** the same 20-second budget was in **three**
  places, and the one that mattered most was not a test —
  `app/lib/core/timetable_repository.dart` defaulted `timeLimit` to 20 and
  `timetable_screen.dart` called it with no arguments. **Every timetable
  generated from the UI was running the relaxed fallback.** `test_solver.py`
  defaulted to 20 as well.
- **Fix:** all three now use 45, matching `DEFAULT_TIME_LIMIT`, each with a
  comment saying why it is not a knob to turn down.

### 1.4 Incomplete `/me` Endpoint Role Attributes — **FIXED**
- **File:** `api/app/main.py`
- **Fix:** `/me` now returns `is_vice_principal`, `is_principal` and `is_admin`
  alongside the existing fields.

### 1.5 Unverified Model Identifiers in Gemini Model Chain — **FIXED, diagnosis reversed**
- **Reported:** `gemini-3.5-flash`, `gemini-3.6-flash` and
  `gemini-3.1-flash-lite` are "experimental/hypothetical", and the chain should
  fall back to `gemini-2.5-flash`, `gemini-2.0-flash`, `gemini-1.5-flash`.
- **What is actually true** (checked against Google's current model list): the
  three 3.x tags are real, current, vision-capable models. The **2.0
  generation has been shut down**, and 1.5-flash is gone — so the recommended
  fix would have replaced a working chain with two dead tags, and the real
  defect was the existing last entry, `gemini-2.0-flash`. A chain whose last
  resort is a retired tag has no last resort; it just spends a round trip
  finding that out.
- **Fix:** last entry is now `gemini-2.5-flash`. More usefully, the fallback no
  longer treats "model does not exist" as fatal — it logs loudly and moves on,
  exactly as it does for a quota error — and `GEMINI_MODELS` in `api/.env`
  overrides the chain, so the next retirement is a config change. Anything
  else (a corrupt image, a bad schema) is still raised immediately rather than
  retried against three models that would fail identically.

---

## 2. Non-Working & Partially Implemented Parts

### 2.1 Lack of Deep-Linking & Route Navigation — **FIXED**
- **Fix:** `/documents/:id`, `/attendance/:classId/:slotId`, `/templates/new`
  and `/templates/:id/edit` are declarative GoRouter routes. Each screen loads
  what it needs from the path alone, so a refresh, a browser Back or a shared
  link all work.
- **Also found:** the role guard matched the guard list **exactly**, so it only
  ever covered the section roots. Adding `/documents/:id` without fixing that
  would have let a teacher type a detail URL straight past the check. Guards
  now cover a section and everything beneath it, and the rule is a pure
  function (`resolveRedirect`) with 26 tests on it.
- **Known limit:** a freshly discovered template proposal exists only in
  memory, so refreshing `/templates/new` opens an empty editor. Nothing in a
  URL could rebuild an unsaved draft; it degrades instead of throwing.

### 2.2 Synchronous Long-Running HTTP Solver Blocking — **FIXED**
- **Fix:** `POST /timetable/jobs` returns a job id immediately;
  `GET /timetable/jobs/{id}` polls. The solve runs on a worker thread. The
  Flutter client uses this path and falls back to the old one against an older
  backend. `POST /timetable/generate` still blocks, which is what a script
  wants, and both refuse a second concurrent solve — two CP-SAT runs on one
  container take each other's cores and both miss their budget.
- **Scope, stated plainly:** the job registry is in-process
  (`app/services/jobs.py`). Jobs do not survive a restart and a second replica
  cannot see them. That fits one container on Render and nothing larger; the
  endpoint contract is already the right shape to put Redis behind.

### 2.3 Absence of Student Photo Upload & Thumbnail Pipeline — **FIXED**
- **Fix:** `POST/DELETE /directory/students/{id}/photo`, a private
  `student-photos` bucket (`db/011_student_photos.sql`), and signed URLs on
  both the roll and the attendance roster. Upload and removal are in the
  students screen; `StudentAvatar` shows the face or falls back to initials.
- Uploads are squared, turned upright from the EXIF rotation flag, and then
  stripped of all metadata — phone EXIF routinely carries GPS, and a directory
  of children's portraits tagged with where they were taken is not a thing to
  keep. A 12 MB upload becomes a ~5 KB 320px JPEG.
- The bucket is separate from `documents` on purpose: that bucket's policy
  lets any authenticated user read all of it, and here the object path is the
  student's id and therefore guessable. This bucket has no client-facing
  policy at all; every read is an API-minted signed URL.
- **Not done:** cropping a passport photo out of an admission scan
  automatically. It needs the model to return a bounding box, and nothing
  about that could be verified here without a Gemini key — see §5.

### 2.4 Missing Password Reset & Account Invitation Flow — **SKIPPED**
Excluded at the owner's request.

---

## 3. High-Value Upgrades & Architectural Enhancements

Unchanged from the original proposal — these are features, not defects. See §5.

### 3.1 PDF & Spreadsheet Export Engine
### 3.2 Automated Push Notifications & WhatsApp/SMS Cover Alerts
### 3.3 Offline-First Attendance Marking Mode
### 3.4 Strict Production Backend Authorization Layer (Defense-in-Depth)
### 3.5 Multi-Tenant Database Architecture for School Chains

---

## 4. Defects found while fixing the above

None of these were in the original report.

### 4.1 A substitute could be booked into two rooms at once — **FIXED**
- **Files:** `api/app/services/substitution.py`, `routers/leave.py`,
  `routers/substitutions.py`
- Two teachers off on the same day are two separate runs of the matcher.
  Neither run knew what the other had already committed, so both offered the
  one colleague free in period 3 — and an admin working down the Action Board
  confirmed them twice. Nothing anywhere refused it.
- **Fix:** the matcher is given the cover already confirmed in the window, and
  confirming re-checks from scratch: not already covering that period, not
  teaching their own class then, not on leave that day. The check belongs at
  confirm time because the suggestion may be days old, the timetable may have
  been regenerated since, and an admin may override the suggested name with
  anybody at all. Confirming twice now returns 409 with the reason.

### 4.2 `/forecast/staffing` returned 500 on a half-configured school — **FIXED**
- **File:** `api/app/services/forecast.py`
- If no teacher has a department yet, the school has zero free periods, and the
  "% of all slack" line in an event warning divided by it. A plausible state
  during setup took down the whole endpoint. Now reported as 100%.

### 4.3 Roster photos were unusable even once set — **FIXED**
- `/attendance/roster` selected `photo_url` and returned it raw. It is a path
  inside a private bucket, so a browser could never load it. Both the roster
  and the roll now sign in one batch call rather than one round trip per pupil.

### 4.4 Exam calendar month names sat over the wrong months — **FIXED**
- **File:** `app/lib/widgets/exam_calendar.dart`
- The heading was a single centred `Text` holding both month names joined
  together, spanning the full width between the arrows. The grids below are
  two fixed 320px columns starting at the left edge, so the heading was
  centred over the whole row while the grids were not — leaving an empty gap
  on the left and putting "August 2026" over September's column.
- **Fix:** each month column carries its own heading, so the caption is laid
  out by the thing it captions and cannot drift. The paging arrows moved to
  the outer edges of the first and last month. Pinned by a test that compares
  each label's centre against the centre of the grid it names.

### 4.5 Signed-URL logic was duplicated three ways — **FIXED**
- `documents.py` and `templates.py` each had their own copy, with the
  three-way SDK key spelling repeated. Consolidated into
  `app/services/storage.py`.

---

## 5. What was deliberately not built

Stated plainly rather than left implied.

| Item | Why not |
| :--- | :--- |
| **3.1 PDF / Excel export** | New rendering dependencies on both sides. Worth doing; it is a feature, not a defect, and it wants its own scope. |
| **3.2 WhatsApp / SMS / push alerts** | Needs a paid provider account, a verified sender and webhook credentials. None of it could be exercised here, and untested notification code that silently fails is worse than none. |
| **3.3 Offline-first attendance** | A local write queue with conflict resolution is a substantial subsystem, and the failure mode of getting it subtly wrong is lost registers. |
| **3.4 RLS defence-in-depth** | Routing every handler through a user-scoped client is a good idea and a large, uniform change across ten routers. Doing it without a live database to verify each policy against would be guesswork. |
| **3.5 Multi-tenant `school_id`** | A schema migration touching all 15 tables plus every RLS policy and every query. Architecture work, not a fix. |
| **Auto-cropping photos from admission scans** | Depends on the model returning a reliable bounding box; unverifiable without a Gemini key. |

---

## 6. Verification

Run from a clone with no database:

```bash
cd api && python -m pytest tests/ -q          # 162 unit tests
python test_solver.py --fixture --stress      # 13 solver checks, no DB needed
cd ../app && flutter analyze && flutter test  # 127 Dart tests
```

The end-to-end scripts still need a running API, a seeded Supabase project and
a Gemini key. `test_e2e_photos.py` is new and covers §2.3; `test_e2e_timetable.py`
gained a section covering the job flow in §2.2.

| Suite | Before | After |
| :--- | :--- | :--- |
| `api/tests/` | 100 | **162** |
| `app/test/` | 92 | **127** |
| `test_solver.py` | needed a seeded database | runs offline via `--fixture` |

---

## 7. Summary Matrix

| Category | Component / Item | Status |
| :--- | :--- | :--- |
| **Bug** | `test_extract.py` import + stale signature | Fixed |
| **Bug** | `samples/` missing; Pillow undeclared | Fixed |
| **Bug** | 20s solver budget in test, client **and** solver harness | Fixed |
| **Bug** | `/me` missing VP/Principal flags | Fixed |
| **Bug** | Retired `gemini-2.0-flash` as last resort | Fixed |
| **Bug** | Substitute confirmable into two rooms at once | Fixed (new) |
| **Bug** | `/forecast/staffing` 500 on zero slack | Fixed (new) |
| **Bug** | Roster returned unloadable raw photo paths | Fixed (new) |
| **Bug** | Exam calendar month names over the wrong months | Fixed (new) |
| **Limitation** | No deep links; guards matched roots only | Fixed |
| **Limitation** | Solver held the HTTP socket open | Fixed |
| **Limitation** | No student photo pipeline | Fixed |
| **Limitation** | No password reset | Skipped by request |
| **Upgrade** | 3.1–3.5 | Not built — see §5 |
