-- =====================================================================
-- Built-in leave / medical note template.
--
-- Closes the loop between the document reader and the cover pipeline: a
-- teacher photographs a doctor's note, it becomes a pending leave request,
-- the HOD approves it, and the substitution matcher fills the Action Board.
-- No one types any of it.
--
-- Apply after 003_templates.sql. Idempotent.
-- =====================================================================

insert into document_templates (name, description, target, is_builtin, fields)
values (
  'Leave / Medical Note',
  'A doctor''s note or written leave application. Becomes a pending leave request for the named teacher.',
  'leave_request',
  true,
  '[
    {"key":"teacher_name","label":"Teacher Name","type":"text","required":true,"maps_to":"__teacher",
     "description":"Whose leave this is. Matched against the staff list."},
    {"key":"from_date","label":"Leave From","type":"date","required":true,"maps_to":"from_date"},
    {"key":"to_date","label":"Leave To","type":"date","required":true,"maps_to":"to_date",
     "description":"If the note gives only one date, use that same date here."},
    {"key":"reason","label":"Reason","type":"longtext","required":false,"maps_to":"reason",
     "description":"The stated reason or diagnosis, as written."}
  ]'::jsonb
)
on conflict (name) do nothing;
