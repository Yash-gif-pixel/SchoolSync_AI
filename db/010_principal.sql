-- =====================================================================
-- The Principal
-- Apply in the Supabase dashboard SQL Editor (or via psql).
-- Idempotent: safe to re-run.
--
-- The admin account is office staff, not the head of the school. The
-- principal is a real member of staff who belongs in the directory — but
-- they do not run the software, which is why this is a flag on a normal
-- profile rather than another admin login.
-- =====================================================================

alter table profiles
  add column if not exists is_principal boolean not null default false;

create index if not exists idx_profiles_principal
  on profiles(is_principal) where is_principal;

-- One school, one principal.
drop index if exists profiles_one_principal;
create unique index profiles_one_principal
  on profiles ((true)) where is_principal;
