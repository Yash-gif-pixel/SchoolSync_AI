-- =====================================================================
-- Exam timetables: an exam is a season, not a day
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
--
-- Replaces the single `exams.starts_on` date from 006. A half-yearly runs for
-- a fortnight, Grade 1 sits three papers and Grade 9 sits eight, and no two
-- grades share a calendar. One date per exam could not express any of that.
--
-- The unit of work is now a SITTING: one date, one paper, and the grades
-- writing it. Seating is planned per sitting, which is what makes the room
-- rule work — on Tuesday only Tuesday's grades are out of their rooms.
-- =====================================================================

alter table exams drop column if exists starts_on;

-- Clear days a grade should get between its own papers. Advisory: the
-- schedule editor warns rather than refuses, because a real timetable
-- sometimes has to break its own rule near the end of term.
alter table exams add column if not exists min_gap_days int not null default 1;


-- ---------- sittings --------------------------------------------------
create table if not exists exam_sittings (
  id         uuid primary key default gen_random_uuid(),
  exam_id    uuid not null references exams(id) on delete cascade,
  sits_on    date not null,
  paper      text,
  starts_at  time,
  created_at timestamptz not null default now()
);

create index if not exists idx_sittings_exam on exam_sittings(exam_id, sits_on);

-- Which grades write on that day. A subset of the exam's roster in
-- exam_grades: being enrolled in the exam is not the same as sitting on
-- Tuesday.
create table if not exists exam_sitting_grades (
  sitting_id uuid not null references exam_sittings(id) on delete cascade,
  grade      int  not null check (grade between 1 and 12),
  primary key (sitting_id, grade)
);


-- ---------- seating moves from the exam to the sitting ---------------
-- Dropped rather than migrated: a plan keyed to a whole exam has no meaning
-- once each day seats a different set of grades, and there is no sensible
-- date to attribute an old row to. Both tables were empty at the time this
-- was written; if yours are not, export them before running this.
drop table if exists seat_allocations;
drop table if exists seating_plans;

create table seating_plans (
  id          uuid primary key default gen_random_uuid(),
  sitting_id  uuid not null references exam_sittings(id) on delete cascade,
  is_active   boolean not null default true,
  stats       jsonb,
  diagnostics jsonb,
  created_at  timestamptz not null default now()
);

-- Regenerating replaces: a stale chart on the door is worse than none.
create unique index if not exists seating_one_active_per_sitting
  on seating_plans (sitting_id) where is_active;

create table seat_allocations (
  id         uuid primary key default gen_random_uuid(),
  plan_id    uuid not null references seating_plans(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  room_id    uuid not null references rooms(id)    on delete cascade,
  seat_row   int  not null,
  seat_col   int  not null,
  unique (plan_id, room_id, seat_row, seat_col),
  unique (plan_id, student_id)
);

create index if not exists idx_seat_alloc_plan on seat_allocations(plan_id);
create index if not exists idx_seat_alloc_room on seat_allocations(plan_id, room_id);


-- ---------- RLS -------------------------------------------------------
alter table exam_sittings       enable row level security;
alter table exam_sitting_grades enable row level security;
alter table seating_plans       enable row level security;
alter table seat_allocations    enable row level security;

drop policy if exists sittings_read on public.exam_sittings;
create policy sittings_read on public.exam_sittings
  for select to authenticated using (true);

drop policy if exists sittings_admin_write on public.exam_sittings;
create policy sittings_admin_write on public.exam_sittings
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists sitting_grades_read on public.exam_sitting_grades;
create policy sitting_grades_read on public.exam_sitting_grades
  for select to authenticated using (true);

drop policy if exists sitting_grades_admin_write on public.exam_sitting_grades;
create policy sitting_grades_admin_write on public.exam_sitting_grades
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists seating_plans_read on public.seating_plans;
create policy seating_plans_read on public.seating_plans
  for select to authenticated using (true);

drop policy if exists seating_plans_admin_write on public.seating_plans;
create policy seating_plans_admin_write on public.seating_plans
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists seat_alloc_read on public.seat_allocations;
create policy seat_alloc_read on public.seat_allocations
  for select to authenticated using (true);

drop policy if exists seat_alloc_admin_write on public.seat_allocations;
create policy seat_alloc_admin_write on public.seat_allocations
  for all to authenticated using (is_admin()) with check (is_admin());
