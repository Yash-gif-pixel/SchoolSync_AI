-- =====================================================================
-- Exam seating plans
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
-- =====================================================================

-- ---------- rooms get a physical address ------------------------------
-- Seating needs to know where a room is and what shape it is; until now a
-- room was just a name and a capacity.
--
-- `floor_no`, not `floor`: floor() is a Postgres function, and a column
-- sharing that name turns every unqualified reference into a coin toss.
alter table rooms add column if not exists block     text;
alter table rooms add column if not exists floor_no  int;
alter table rooms add column if not exists room_no   int;
alter table rooms add column if not exists seat_rows int;
alter table rooms add column if not exists seat_cols int;

-- Renumber the 40 home rooms into two blocks.
--
--   Block A = grades 1-5, Block B = grades 6-10
--   ground floor  -> the block's first two grades   ->   1 ..   8
--   first floor   -> the block's last three grades  -> 101 .. 112
--
-- Eight and twelve rather than ten and ten so that no grade is split across
-- two floors — a grade sits its exam on one corridor.
with ordered as (
  select
    c.home_room_id,
    case when c.grade <= 5 then 'A' else 'B' end as blk,
    ((c.grade - 1) % 5) * 4 + (ascii(c.section) - ascii('A')) as pos
  from classes c
  where c.home_room_id is not null
),
numbered as (
  select
    home_room_id,
    blk,
    case when pos < 8 then 0 else 1 end as flr,
    case when pos < 8 then pos + 1 else 101 + (pos - 8) end as rno
  from ordered
)
update rooms r
set block     = n.blk,
    floor_no  = n.flr,
    room_no   = n.rno,
    seat_rows = 5,
    seat_cols = 10,
    name      = n.blk || '-' || n.rno::text
from numbered n
where r.id = n.home_room_id;


-- ---------- exams -----------------------------------------------------
create table if not exists exams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  starts_on  date,
  notes      text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Which grades sit this exam. Whole grades, not sections: an exam is set for
-- "Grade 6", and every section of it writes the same paper.
create table if not exists exam_grades (
  exam_id uuid not null references exams(id) on delete cascade,
  grade   int  not null check (grade between 1 and 12),
  primary key (exam_id, grade)
);


-- ---------- seating plans --------------------------------------------
create table if not exists seating_plans (
  id          uuid primary key default gen_random_uuid(),
  exam_id     uuid not null references exams(id) on delete cascade,
  is_active   boolean not null default true,
  stats       jsonb,          -- seats used, occupancy, adjacency breaches
  diagnostics jsonb,          -- human-readable reasons, same shape as the solver
  created_at  timestamptz not null default now()
);

-- Regenerating replaces rather than accumulates: only one live plan per exam.
create unique index if not exists seating_one_active_per_exam
  on seating_plans (exam_id) where is_active;

create table if not exists seat_allocations (
  id         uuid primary key default gen_random_uuid(),
  plan_id    uuid not null references seating_plans(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  room_id    uuid not null references rooms(id)    on delete cascade,
  seat_row   int  not null,
  seat_col   int  not null,
  -- The two rules that make a seating chart a seating chart.
  unique (plan_id, room_id, seat_row, seat_col),
  unique (plan_id, student_id)
);

create index if not exists idx_seat_alloc_plan on seat_allocations(plan_id);
create index if not exists idx_seat_alloc_room on seat_allocations(plan_id, room_id);


-- ---------- RLS -------------------------------------------------------
alter table exams            enable row level security;
alter table exam_grades      enable row level security;
alter table seating_plans    enable row level security;
alter table seat_allocations enable row level security;

-- Everyone signed in may read the schedule and find their room; only admins
-- may change it. Invigilators are teachers, so they need the read.
drop policy if exists exams_read on public.exams;
create policy exams_read on public.exams
  for select to authenticated using (true);

drop policy if exists exams_admin_write on public.exams;
create policy exams_admin_write on public.exams
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists exam_grades_read on public.exam_grades;
create policy exam_grades_read on public.exam_grades
  for select to authenticated using (true);

drop policy if exists exam_grades_admin_write on public.exam_grades;
create policy exam_grades_admin_write on public.exam_grades
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
