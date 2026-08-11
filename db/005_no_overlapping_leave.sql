-- =====================================================================
-- A teacher cannot be on two overlapping leaves at once.
--
-- The API refuses a clash on both create and approve, but that is one code
-- path away from being forgotten. Overlapping approved leave would have the
-- substitution matcher arranging cover for the same periods twice, so the
-- rule is worth enforcing where it cannot be bypassed.
--
-- Apply after 004. Idempotent.
-- =====================================================================

-- Range types need btree_gist to combine an equality column (teacher_id)
-- with an overlap operator in the same exclusion constraint.
create extension if not exists btree_gist;


-- ---------- clean up what already exists ------------------------------
-- The seed generator used to produce overlaps. Keep the earliest-created
-- request of any overlapping pair and drop the later one; substitutions
-- cascade with it. Loops because three-way chains need more than one pass.
do $$
declare removed int;
begin
  loop
    delete from leave_requests a
    using leave_requests b
    where a.teacher_id = b.teacher_id
      and a.id <> b.id
      and a.status in ('pending_incharge', 'approved')
      and b.status in ('pending_incharge', 'approved')
      and daterange(a.from_date, a.to_date, '[]')
       && daterange(b.from_date, b.to_date, '[]')
      and (a.created_at, a.id) > (b.created_at, b.id);

    get diagnostics removed = row_count;
    exit when removed = 0;
    raise notice 'removed % overlapping leave request(s)', removed;
  end loop;
end $$;


-- ---------- and stop it happening again -------------------------------
-- Only live requests are constrained: a rejected or cancelled request must
-- never block someone re-applying for the same dates.
alter table leave_requests
  drop constraint if exists no_overlapping_leave;

alter table leave_requests
  add constraint no_overlapping_leave
  exclude using gist (
    teacher_id with =,
    daterange(from_date, to_date, '[]') with &&
  )
  where (status in ('pending_incharge', 'approved'));
