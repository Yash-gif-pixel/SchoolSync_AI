-- =====================================================================
-- Vice Principal, and an admin who is not the principal
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
--
-- Two corrections to the staff model:
--
-- 1. A head of department approves their department's leave, but nobody was
--    set over the HODs themselves — their requests fell through to whoever
--    held the admin account. That is the Vice Principal's job.
--
-- 2. The admin account was named "Principal Sharma". The principal does not
--    run the software; an office administrator does. The name was implying an
--    org chart the product does not have.
-- =====================================================================

-- A flag rather than a new value on the user_role enum, exactly like
-- is_approver. A VP is a teacher with a second responsibility, not a third
-- kind of account — so routing, RLS and the role checks all stay as they are.
alter table profiles
  add column if not exists is_vice_principal boolean not null default false;

create index if not exists idx_profiles_vp
  on profiles(is_vice_principal) where is_vice_principal;

-- Only one person holds the post.
drop index if exists profiles_one_vice_principal;
create unique index profiles_one_vice_principal
  on profiles ((true)) where is_vice_principal;


-- The admin is office staff. Renamed only if it is still the seeded default,
-- so a real deployment's own name is never overwritten.
update profiles
set full_name = 'Latha Krishnan'
where full_name = 'Principal Sharma' and role = 'admin';
