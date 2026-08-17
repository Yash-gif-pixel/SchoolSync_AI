-- =====================================================================
-- Student photographs
--
-- `students.photo_url` has existed since 001 and nothing ever wrote to it,
-- so every register and every roll showed a coloured circle with initials
-- in it. A teacher covering an unfamiliar class needs faces.
--
-- Photos live in their own bucket rather than alongside the scanned
-- documents. Two reasons:
--
--   * The `documents` bucket's policy lets ANY authenticated user read the
--     whole bucket. That is already loose for admission scans; it would be
--     indefensible for a directory of children's faces, where the object
--     path is the student's id and therefore guessable.
--   * Photos and scans have different lifetimes. A scan is evidence and is
--     kept; a photo is replaced whenever a better one is taken.
--
-- This bucket deliberately gets NO policy for the `authenticated` role.
-- Nothing reaches it directly. The API mints a short-lived signed URL with
-- the service key after checking who is asking, which is the only path in.
--
-- Apply after 010_principal.sql. Idempotent.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'student-photos',
  'student-photos',
  false,
  5242880,                                  -- 5 MB; the API resizes anyway
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- Belt and braces: if a policy for this bucket was ever added by hand, take
-- it back off. Direct client access is not part of the design.
drop policy if exists "student_photos_rw" on storage.objects;


-- What is stored in students.photo_url is an object PATH inside the bucket
-- above ("<student id>.jpg"), never a URL. A stored URL would either expire,
-- or -- worse -- not expire.
comment on column public.students.photo_url is
  'Object path within the private student-photos bucket. The API signs it on '
  'the way out; it is never a public URL.';
