-- =====================================================================
-- School events: Annual Day, Sports Day, inspections
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
--
-- `calendar_events` already existed and already fed the staffing forecast,
-- but it could only say "this day costs 12 teachers" as a bare number that
-- somebody typed in. Two things were missing: an event lasting more than one
-- day, and knowing WHICH teachers are tied up.
--
-- `teachers_required` is kept and is now derived from the roster below, so
-- the forecast keeps reading the column it always read.
-- =====================================================================

-- Null means a single-day event ending on `date`. Kept nullable rather than
-- backfilled-and-required so the existing seeded events stay valid.
alter table calendar_events add column if not exists ends_on date;
alter table calendar_events add column if not exists notes   text;

alter table calendar_events
  drop constraint if exists calendar_events_dates_ordered;
alter table calendar_events
  add constraint calendar_events_dates_ordered
  check (ends_on is null or ends_on >= date);


-- ---------- who is tied up -------------------------------------------
create table if not exists event_teachers (
  event_id   uuid not null references calendar_events(id) on delete cascade,
  teacher_id uuid not null references profiles(id)        on delete cascade,
  role       text,
  primary key (event_id, teacher_id)
);

create index if not exists idx_event_teachers_teacher
  on event_teachers(teacher_id);


-- ---------- RLS -------------------------------------------------------
alter table calendar_events enable row level security;
alter table event_teachers  enable row level security;

-- Everyone signed in reads the calendar: a teacher needs to know they are
-- down for Annual Day. Only admins change it.
drop policy if exists events_read on public.calendar_events;
create policy events_read on public.calendar_events
  for select to authenticated using (true);

drop policy if exists events_admin_write on public.calendar_events;
create policy events_admin_write on public.calendar_events
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists event_teachers_read on public.event_teachers;
create policy event_teachers_read on public.event_teachers
  for select to authenticated using (true);

drop policy if exists event_teachers_admin_write on public.event_teachers;
create policy event_teachers_admin_write on public.event_teachers
  for all to authenticated using (is_admin()) with check (is_admin());
