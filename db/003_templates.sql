-- =====================================================================
-- Document templates
--
-- Every school prints its own forms, so the field list cannot be baked
-- into the code. A template describes what to pull out of a document and
-- what to do with the result. Extraction builds its response schema from
-- the template at run time.
--
-- Apply after 002_rls.sql. Idempotent.
-- =====================================================================

-- What a committed document turns into.
do $$ begin
  create type template_target as enum (
    'student',        -- creates a row in students
    'leave_request',  -- creates a row in leave_requests
    'data_only'       -- stored as an extracted_record, no domain row
  );
exception when duplicate_object then null; end $$;


create table if not exists document_templates (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  description  text,
  target       template_target not null default 'data_only',

  -- [{key, label, type, required, maps_to, description, options[]}]
  -- type: text | longtext | date | number | phone | email | choice | grade
  -- maps_to: destination column when target is student/leave_request
  fields       jsonb not null default '[]'::jsonb,

  -- the blank form this template was discovered from, if any
  sample_path  text,

  is_builtin   boolean not null default false,
  is_active    boolean not null default true,
  created_by   uuid references profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint fields_is_array check (jsonb_typeof(fields) = 'array')
);

create index if not exists idx_templates_active on document_templates(is_active);


-- Documents now belong to a template rather than a fixed enum.
alter table documents
  add column if not exists template_id uuid references document_templates(id) on delete set null;

-- doc_type predates templates; keep the column for existing rows but stop
-- requiring it, since an arbitrary template has no matching enum value.
alter table documents alter column doc_type drop not null;

create index if not exists idx_documents_template on documents(template_id);


-- Committed output for templates that map to no domain table. Keeps
-- "store the data" honest and queryable instead of leaving it in the
-- document's extraction blob.
create table if not exists extracted_records (
  id          uuid primary key default gen_random_uuid(),
  template_id uuid not null references document_templates(id) on delete cascade,
  document_id uuid references documents(id) on delete set null,
  data        jsonb not null default '{}'::jsonb,
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create index if not exists idx_records_template on extracted_records(template_id);


-- ---------- RLS -------------------------------------------------------
alter table document_templates enable row level security;
alter table extracted_records  enable row level security;

drop policy if exists templates_read on document_templates;
create policy templates_read on document_templates
  for select to authenticated using (true);

drop policy if exists templates_admin_write on document_templates;
create policy templates_admin_write on document_templates
  for all to authenticated using (is_admin()) with check (is_admin());

drop policy if exists records_read on extracted_records;
create policy records_read on extracted_records
  for select to authenticated using (is_admin() or created_by = auth.uid());

drop policy if exists records_admin_write on extracted_records;
create policy records_admin_write on extracted_records
  for all to authenticated using (is_admin()) with check (is_admin());


-- ---------- realtime --------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['document_templates', 'extracted_records'] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;


-- ---------- built-in admission template -------------------------------
-- Ships so the app works out of the box; schools add their own alongside.
insert into document_templates (name, description, target, is_builtin, fields)
values (
  'Standard Admission Form',
  'Default nine-field admission form. Duplicate this and edit it to match your school''s own layout.',
  'student',
  true,
  '[
    {"key":"full_name","label":"Student Name","type":"text","required":true,"maps_to":"full_name"},
    {"key":"date_of_birth","label":"Date of Birth","type":"date","required":true,"maps_to":"date_of_birth"},
    {"key":"gender","label":"Gender","type":"choice","required":false,"maps_to":"gender","options":["M","F"]},
    {"key":"class_applying_for","label":"Class Applying For","type":"grade","required":true,"maps_to":"__class"},
    {"key":"guardian_name","label":"Guardian Name","type":"text","required":true,"maps_to":"guardian_name"},
    {"key":"guardian_phone","label":"Guardian Phone","type":"phone","required":false,"maps_to":"guardian_phone"},
    {"key":"address","label":"Address","type":"longtext","required":false,"maps_to":"address"},
    {"key":"previous_school","label":"Previous School","type":"text","required":false,"maps_to":"previous_school"},
    {"key":"admission_date","label":"Date of Admission","type":"date","required":false,"maps_to":"admission_date"}
  ]'::jsonb
)
on conflict (name) do nothing;
