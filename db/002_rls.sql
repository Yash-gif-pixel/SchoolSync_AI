-- =====================================================================
-- Row Level Security
--
-- GoRouter only hides UI. THIS is the access control. The service_role
-- key used by the FastAPI backend and seed script bypasses RLS entirely,
-- which is exactly why that key must never reach the Flutter client.
-- Idempotent: safe to re-run.
-- =====================================================================

-- ---------- helpers ---------------------------------------------------
-- SECURITY DEFINER so these can read profiles without re-triggering the
-- policies on profiles (which would recurse infinitely).

create or replace function public.current_role_of()
returns user_role language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false)
$$;

create or replace function public.is_approver()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_approver from profiles where id = auth.uid()), false)
$$;

create or replace function public.my_department()
returns uuid language sql stable security definer set search_path = public as $$
  select department_id from profiles where id = auth.uid()
$$;

-- classes the signed-in teacher actually teaches
create or replace function public.my_class_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select class_id from teaching_assignments where teacher_id = auth.uid()
$$;


-- ---------- enable RLS everywhere ------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'departments','subjects','rooms','classes','time_slots','profiles',
    'documents','students','teaching_assignments','timetable_versions',
    'timetable_entries','attendance','leave_requests','substitutions',
    'calendar_events'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- drop existing policies so this file can be re-run cleanly
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname
           from pg_policies where schemaname = 'public'
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;


-- ---------- reference data: readable by all, writable by admin -------
do $$
declare t text;
begin
  foreach t in array array['departments','subjects','rooms','classes',
                           'time_slots','calendar_events'] loop
    execute format($f$
      create policy %1$I_read on public.%1$I
        for select to authenticated using (true);
      create policy %1$I_write on public.%1$I
        for all to authenticated using (is_admin()) with check (is_admin());
    $f$, t);
  end loop;
end $$;


-- ---------- profiles --------------------------------------------------
-- Everyone signed in can see the staff directory (timetables must render
-- teacher names), but only you or an admin may modify your row.
create policy profiles_read on public.profiles
  for select to authenticated using (true);

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid() or is_admin())
  with check (id = auth.uid() or is_admin());

create policy profiles_admin_all on public.profiles
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- students --------------------------------------------------
-- A teacher sees only students in classes they teach.
create policy students_read on public.students
  for select to authenticated
  using (is_admin() or class_id in (select my_class_ids()));

create policy students_admin_write on public.students
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- teaching assignments & timetable -------------------------
create policy assignments_read on public.teaching_assignments
  for select to authenticated using (true);

create policy assignments_admin_write on public.teaching_assignments
  for all to authenticated using (is_admin()) with check (is_admin());

create policy tt_versions_read on public.timetable_versions
  for select to authenticated using (true);

create policy tt_versions_admin_write on public.timetable_versions
  for all to authenticated using (is_admin()) with check (is_admin());

create policy tt_entries_read on public.timetable_entries
  for select to authenticated using (true);

create policy tt_entries_admin_write on public.timetable_entries
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- attendance ------------------------------------------------
-- Teachers read and mark attendance only for their own classes.
create policy attendance_read on public.attendance
  for select to authenticated
  using (is_admin() or class_id in (select my_class_ids()));

create policy attendance_insert on public.attendance
  for insert to authenticated
  with check (is_admin() or class_id in (select my_class_ids()));

create policy attendance_update on public.attendance
  for update to authenticated
  using (is_admin() or class_id in (select my_class_ids()))
  with check (is_admin() or class_id in (select my_class_ids()));


-- ---------- leave requests -------------------------------------------
-- The strict one. A teacher sees their own requests and nothing else.
-- An HOD additionally sees requests from their own department.
create policy leave_read on public.leave_requests
  for select to authenticated
  using (
    teacher_id = auth.uid()
    or is_admin()
    or (is_approver() and teacher_id in (
          select id from profiles where department_id = my_department()))
  );

create policy leave_insert_own on public.leave_requests
  for insert to authenticated
  with check (teacher_id = auth.uid() or is_admin());

-- Only an HOD of the same department (or an admin) may approve/reject.
create policy leave_review on public.leave_requests
  for update to authenticated
  using (
    is_admin()
    or (is_approver() and teacher_id in (
          select id from profiles where department_id = my_department()))
  )
  with check (
    is_admin()
    or (is_approver() and teacher_id in (
          select id from profiles where department_id = my_department()))
  );


-- ---------- substitutions --------------------------------------------
-- Visible to admins and to the teacher being asked to cover.
create policy subs_read on public.substitutions
  for select to authenticated
  using (is_admin() or substitute_teacher_id = auth.uid());

create policy subs_admin_write on public.substitutions
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- documents -------------------------------------------------
create policy documents_read on public.documents
  for select to authenticated
  using (is_admin() or uploaded_by = auth.uid());

create policy documents_insert on public.documents
  for insert to authenticated
  with check (uploaded_by = auth.uid() or is_admin());

create policy documents_admin_write on public.documents
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- storage: scanned documents bucket ------------------------
drop policy if exists "documents_bucket_rw" on storage.objects;
create policy "documents_bucket_rw" on storage.objects
  for all to authenticated
  using (bucket_id = 'documents')
  with check (bucket_id = 'documents');
