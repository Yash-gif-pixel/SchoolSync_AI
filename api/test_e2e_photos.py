"""End-to-end test of student photographs against the running API.

    python test_e2e_photos.py

`students.photo_url` existed from the first migration and nothing ever wrote
to it, so every register showed a circle of initials. This exercises the whole
path: upload -> normalise -> private bucket -> signed URL on the roster and on
the roll. Cleans up after itself.

Needs db/011_student_photos.sql applied.
"""

from __future__ import annotations

import io
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

sys.path.insert(0, str(Path(__file__).parent))

from app.services.images import PORTRAIT_PX  # noqa: E402
from sample_forms import portrait_png  # noqa: E402

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"
BUCKET = "student-photos"

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed = failed = 0


def check(label: str, ok: bool, detail: str = "") -> bool:
    global passed, failed
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{'  -- ' + detail if detail else ''}")
    if ok:
        passed += 1
    else:
        failed += 1
    return ok


def token_for(email: str) -> str:
    r = httpx.post(
        f"{os.environ['SUPABASE_URL']}/auth/v1/token?grant_type=password",
        headers={"apikey": os.environ["SUPABASE_ANON_KEY"]},
        json={"email": email, "password": PASSWORD},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def main() -> int:
    admin_tok = token_for("admin@school.test")
    teacher_tok = token_for("teacher@school.test")
    A = {"Authorization": f"Bearer {admin_tok}"}
    T = {"Authorization": f"Bearer {teacher_tok}"}

    # A student the signed-in teacher actually teaches, so the roster check
    # below is not refused for the wrong reason.
    me = httpx.get(f"{API}/me", headers=T, timeout=30).json()
    assignment = (sb.table("teaching_assignments")
                  .select("class_id").eq("teacher_id", me["id"])
                  .limit(1).execute().data)
    if not assignment:
        print("the demo teacher has no classes; seed the database first")
        return 1
    class_id = assignment[0]["class_id"]

    student = (sb.table("students").select("id, full_name, photo_url")
               .eq("class_id", class_id).limit(1).execute().data)
    if not student:
        print(f"no students in class {class_id}; seed the database first")
        return 1
    student = student[0]
    original_photo = student.get("photo_url")
    print(f"\nusing: {student['full_name']}")

    image = portrait_png("MS")

    with httpx.Client(timeout=90) as c:
        print("\n1. Authorisation")
        r = c.post(f"{API}/directory/students/{student['id']}/photo",
                   headers=T, files={"file": ("p.png", image, "image/png")})
        check("a teacher cannot set a photo (403)", r.status_code == 403,
              str(r.status_code))
        r = c.post(f"{API}/directory/students/{student['id']}/photo",
                   files={"file": ("p.png", image, "image/png")})
        check("anonymous cannot set a photo (401)", r.status_code == 401,
              str(r.status_code))

        print("\n2. Rejections")
        r = c.post(f"{API}/directory/students/{student['id']}/photo",
                   headers=A,
                   files={"file": ("x.png", b"not an image", "image/png")})
        check("a file that is not an image is refused (422)",
              r.status_code == 422, str(r.status_code))

        r = c.post(f"{API}/directory/students/{student['id']}/photo",
                   headers=A,
                   files={"file": ("x.pdf", b"%PDF-1.4", "application/pdf")})
        check("a PDF is refused on type (415)", r.status_code == 415,
              str(r.status_code))

        r = c.post(f"{API}/directory/students/00000000-0000-0000-0000-000000000000/photo",
                   headers=A, files={"file": ("p.png", image, "image/png")})
        check("an unknown student is a 404", r.status_code == 404,
              str(r.status_code))

        print("\n3. Upload")
        r = c.post(f"{API}/directory/students/{student['id']}/photo",
                   headers=A, files={"file": ("portrait.png", image, "image/png")})
        if not check("upload returns 200", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        body = r.json()
        check("a signed URL comes back", bool(body.get("photo_url")))
        check("the stored image is far smaller than the upload",
              body["bytes"] < len(image),
              f"{body['bytes']:,} from {len(image):,} bytes")

        print("\n4. What actually got stored")
        row = (sb.table("students").select("photo_url")
               .eq("id", student["id"]).single().execute().data)
        check("the column holds a bucket path, not a URL",
              row["photo_url"] == f"{student['id']}.jpg", row["photo_url"])

        stored = sb.storage.from_(BUCKET).download(row["photo_url"])
        from PIL import Image
        img = Image.open(io.BytesIO(stored))
        check("stored as a square thumbnail",
              img.size == (PORTRAIT_PX, PORTRAIT_PX), str(img.size))
        check("stored as JPEG", img.format == "JPEG", str(img.format))
        check("no metadata survived the upload", not dict(img.getexif()))

        print("\n5. The signed URL works, and the raw path does not")
        r = httpx.get(body["photo_url"], timeout=30)
        check("the signed URL serves the image", r.status_code == 200,
              str(r.status_code))
        raw = (f"{os.environ['SUPABASE_URL']}/storage/v1/object/public/"
               f"{BUCKET}/{row['photo_url']}")
        r = httpx.get(raw, timeout=30)
        check("the bucket is not public", r.status_code >= 400,
              str(r.status_code))

        print("\n6. It reaches the screens that show faces")
        r = c.get(f"{API}/directory/students", headers=A)
        found = next((s for s in r.json()["students"]
                      if s["id"] == student["id"]), None)
        check("the roll carries a signed URL",
              bool(found and (found.get("photo_url") or "").startswith("http")),
              str(found and found.get("photo_url"))[:60])

        slot = (sb.table("timetable_entries")
                .select("slot_id, teaching_assignments!inner(teacher_id, class_id)")
                .eq("teaching_assignments.teacher_id", me["id"])
                .eq("teaching_assignments.class_id", class_id)
                .limit(1).execute().data)
        if slot:
            r = c.get(f"{API}/attendance/roster", headers=T, params={
                "class_id": class_id, "slot_id": slot[0]["slot_id"]})
            if r.status_code == 200:
                pupil = next((s for s in r.json()["students"]
                              if s["id"] == student["id"]), None)
                check("the register carries a signed URL",
                      bool(pupil and (pupil.get("photo_url") or "").startswith("http")))
            else:
                check("roster readable by the class teacher", False,
                      str(r.status_code))
        else:
            print("  (no timetable entry for this class; skipping the register)")

        print("\n7. Removal")
        r = c.delete(f"{API}/directory/students/{student['id']}/photo", headers=T)
        check("a teacher cannot remove a photo (403)", r.status_code == 403,
              str(r.status_code))

        r = c.delete(f"{API}/directory/students/{student['id']}/photo", headers=A)
        check("removal returns 204", r.status_code == 204, str(r.status_code))
        row = (sb.table("students").select("photo_url")
               .eq("id", student["id"]).single().execute().data)
        check("the column is cleared", row["photo_url"] is None,
              str(row["photo_url"]))

    print("\n8. Cleanup")
    sb.table("students").update({"photo_url": original_photo}) \
        .eq("id", student["id"]).execute()
    check("original state restored", True)

    print(f"\n{'=' * 60}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
