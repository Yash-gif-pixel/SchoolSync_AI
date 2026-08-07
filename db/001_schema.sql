-- =====================================================================
-- Smart School Ops Platform — Phase 0 schema
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
-- =====================================================================

-- ---------- enums -----------------------------------------------------
do $$ begin
  create type user_role          as enum ('admin', 'teacher');
exception when duplicate_object then null; end $$;

do $$ begin
  create type room_type          as enum ('home', 'science_lab', 'computer_lab', 'sports');
exception when duplicate_object then null; end $$;

do $$ begin
  create type attendance_status  as enum ('present', 'absent', 'late');
exception when duplicate_object then null; end $$;

do $$ begin
  create type leave_status       as enum ('pending_incharge', 'approved', 'rejected', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type substitution_status as enum ('suggested', 'confirmed', 'declined');
exception when duplicate_object then null; end $$;

do $$ begin
  create type document_type      as enum ('admission_form', 'leave_note');
exception when duplicate_object then null; end $$;

do $$ begin
  create type document_status    as enum ('uploaded', 'extracted', 'needs_review', 'committed', 'failed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type timetable_status   as enum ('draft', 'active', 'infeasible');
exception when duplicate_object then null; end $$;


-- ---------- reference data -------------------------------------------
create table if not exists departments (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique
);

create table if not exists subjects (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  code          text not null unique,
  department_id uuid not null references departments(id) on delete restrict,
  -- non-core subjects (PE/games) are timetabled but not examined
  is_core       boolean not null default true
);

create table if not exists rooms (
  id       uuid primary key default gen_random_uuid(),
  name     text not null unique,
  type     room_type not null default 'home',
  capacity int
);

create table if not exists classes (
  id           uuid primary key default gen_random_uuid(),
  grade        int  not null check (grade between 1 and 12),
  section      text not null check (section ~ '^[A-Z]$'),
  name         text generated always as (grade::text || section) stored,
  home_room_id uuid references rooms(id) on delete set null,
  unique (grade, section)
);

-- 8 slots/day x 6 days (Mon-Sat). Slots 3 and 6 are breaks and are never
-- scheduled; the solver filters on is_break = false, leaving 36 teaching slots.
create table if not exists time_slots (
  id           uuid primary key default gen_random_uuid(),
  day_of_week  int  not null check (day_of_week between 1 and 6),   -- 1 = Monday
  slot_index   int  not null check (slot_index between 1 and 8),
  start_time   time not null,
  end_time     time not null,
  is_break     boolean not null default false,
  label        text,
  unique (day_of_week, slot_index)
);


-- ---------- people ----------------------------------------------------
-- Mirrors auth.users. `role` drives GoRouter redirects; RLS enforces the
-- actual access rules (see 002_rls.sql).
create table if not exists profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text not null,
  employee_code text unique,
  role          user_role not null default 'teacher',
  department_id uuid references departments(id) on delete set null,
  is_approver   boolean not null default false,   -- HOD / in-charge
  phone         text,
  created_at    timestamptz not null default now()
);

-- Documents are declared before students/leave_requests because both
-- carry a provenance FK back to the scan they were extracted from.
create table if not exists documents (
  id             uuid primary key default gen_random_uuid(),
  doc_type       document_type not null,
  storage_path   text not null,
  status         document_status not null default 'uploaded',
  extracted_json jsonb,
  confidence     numeric(4,3) check (confidence between 0 and 1),
  model          text,
  error          text,
  uploaded_by    uuid references profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  committed_at   timestamptz
);

create table if not exists students (
  id                 uuid primary key default gen_random_uuid(),
  full_name          text not null,
  class_id           uuid references classes(id) on delete set null,
  roll_no            int,
  date_of_birth      date,
  gender             text,
  guardian_name      text,
  guardian_phone     text,
  address            text,
  previous_school    text,
  admission_date     date,
  photo_url          text,
  source_document_id uuid references documents(id) on delete set null,
  created_at         timestamptz not null default now(),
  unique (class_id, roll_no)
);


-- ---------- curriculum & timetable -----------------------------------
-- The solver's variable domain. One row = "this teacher teaches this
-- subject to this class N periods per week".
create table if not exists teaching_assignments (
  id               uuid primary key default gen_random_uuid(),
  teacher_id       uuid not null references profiles(id) on delete cascade,
  class_id         uuid not null references classes(id) on delete cascade,
  subject_id       uuid not null references subjects(id) on delete cascade,
  periods_per_week int  not null check (periods_per_week between 1 and 12),
  requires_lab     boolean not null default false,
  -- A subject may be split into a theory row and a practical row for the same
  -- class (e.g. Science 5/wk in the home room + 2/wk in a lab). Labs are the
  -- only scarce room, so lab demand must stay under capacity -- see seed.py.
  unique (class_id, subject_id, requires_lab)
);

create table if not exists timetable_versions (
  id           uuid primary key default gen_random_uuid(),
  label        text,
  status       timetable_status not null default 'draft',
  is_active    boolean not null default false,
  solver_stats jsonb,          -- wall time, #vars, #conflicts, objective
  diagnostics  jsonb,          -- unplaced periods + human-readable reasons
  created_at   timestamptz not null default now()
);

-- Only one version may be active at a time.
create unique index if not exists timetable_one_active
  on timetable_versions (is_active) where is_active;

create table if not exists timetable_entries (
  id            uuid primary key default gen_random_uuid(),
  version_id    uuid not null references timetable_versions(id) on delete cascade,
  assignment_id uuid not null references teaching_assignments(id) on delete cascade,
  slot_id       uuid not null references time_slots(id) on delete cascade,
  room_id       uuid references rooms(id) on delete set null,
  unique (version_id, assignment_id, slot_id)
);

create index if not exists idx_tt_entries_version on timetable_entries(version_id);
create index if not exists idx_tt_entries_slot    on timetable_entries(slot_id);


-- ---------- daily operations -----------------------------------------
create table if not exists attendance (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id) on delete cascade,
  class_id   uuid not null references classes(id) on delete cascade,
  slot_id    uuid not null references time_slots(id) on delete cascade,
  date       date not null,
  status     attendance_status not null default 'present',
  marked_by  uuid references profiles(id) on delete set null,
  marked_at  timestamptz not null default now(),
  unique (student_id, date, slot_id)
);

create index if not exists idx_attendance_date  on attendance(date);
create index if not exists idx_attendance_class on attendance(class_id, date);

create table if not exists leave_requests (
  id                 uuid primary key default gen_random_uuid(),
  teacher_id         uuid not null references profiles(id) on delete cascade,
  from_date          date not null,
  to_date            date not null,
  reason             text,
  status             leave_status not null default 'pending_incharge',
  source_document_id uuid references documents(id) on delete set null,
  reviewed_by        uuid references profiles(id) on delete set null,
  reviewed_at        timestamptz,
  created_at         timestamptz not null default now(),
  check (to_date >= from_date)
);

create index if not exists idx_leave_teacher on leave_requests(teacher_id);
create index if not exists idx_leave_status  on leave_requests(status);

create table if not exists substitutions (
  id                   uuid primary key default gen_random_uuid(),
  leave_request_id     uuid not null references leave_requests(id) on delete cascade,
  timetable_entry_id   uuid not null references timetable_entries(id) on delete cascade,
  date                 date not null,
  substitute_teacher_id uuid references profiles(id) on delete set null,
  status               substitution_status not null default 'suggested',
  rank                 int,        -- 1 = best candidate
  rationale            text,       -- "free this slot · same dept · lowest load"
  created_at           timestamptz not null default now()
);

create index if not exists idx_subs_date on substitutions(date);

create table if not exists calendar_events (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  date              date not null,
  event_type        text,
  teachers_required int not null default 0
);

create index if not exists idx_events_date on calendar_events(date);


-- ---------- storage bucket for scanned documents ----------------------
insert into storage.buckets (id, name, public)
values ('documents', 'documents', false)
on conflict (id) do nothing;


-- ---------- realtime --------------------------------------------------
-- Phase 3 depends on these being published. Adding now is harmless.
do $$
declare t text;
begin
  foreach t in array array['leave_requests','substitutions','timetable_versions',
                           'documents','attendance']
  loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
