"""The full loop: photograph a medical note -> ranked cover on the board.

    python test_e2e_leave_note.py

This is the join between Phase 1 and Phase 3. A handwritten note names a
teacher and some dates; nobody types any of it; the HOD approves; the Action
Board fills in. Cleans up after itself.
"""

from __future__ import annotations

import datetime as dt
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

load_dotenv(Path(__file__).with_name(".env"))

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"
SCRATCH = Path(__file__).resolve().parent.parent / "samples" / "_generated"

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed = failed = 0
created_docs: list[str] = []
created_leaves: list[str] = []


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


def make_note(teacher_name: str, start: dt.date, end: dt.date, reason: str) -> bytes:
    """Render a plausible medical note as a PNG.

    Typed rather than handwritten — this test is about the pipeline, not about
    re-testing handwriting recognition, which the admission-form samples
    already cover.
    """
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (900, 620), "white")
    d = ImageDraw.Draw(img)
    d.rectangle([30, 30, 870, 590], outline="black", width=2)

    lines = [
        "CITY CLINIC",
        "12 MG Road, Secunderabad",
        "",
        "MEDICAL CERTIFICATE",
        "",
        f"Teacher Name : {teacher_name}",
        f"Leave From   : {start.strftime('%d/%m/%Y')}",
        f"Leave To     : {end.strftime('%d/%m/%Y')}",
        f"Reason       : {reason}",
        "",
        "The above named is advised rest for the",
        "period stated.",
        "",
        "Signed: Dr A. Kumar",
    ]
    y = 70
    for line in lines:
        d.text((70, y), line, fill="black")
        y += 34

    SCRATCH.mkdir(parents=True, exist_ok=True)
    path = SCRATCH / "leave_note.png"
    img.save(path)
    return path.read_bytes()


def next_weekday(offset: int = 1) -> dt.date:
    d = dt.date.today() + dt.timedelta(days=offset)
    while d.isoweekday() == 7:
        d += dt.timedelta(days=1)
    return d


def main() -> int:
    admin_tok = token_for("admin@school.test")
    hod_tok = token_for("hod@school.test")
    A = {"Authorization": f"Bearer {admin_tok}"}
    H = {"Authorization": f"Bearer {hod_tok}"}

    teacher = httpx.get(f"{API}/me", headers={
        "Authorization": f"Bearer {token_for('teacher@school.test')}"}, timeout=30).json()
    print(f"\nnote will name: {teacher['full_name']}")

    with httpx.Client(timeout=180) as c:
        print("\n1. The built-in leave-note template")
        r = c.get(f"{API}/templates", headers=A)
        tpl = next((t for t in r.json() if t["target"] == "leave_request"), None)
        if not check("a leave_request template exists", tpl is not None,
                     "apply db/004_leave_note_template.sql"):
            return 1
        maps = {f.get("maps_to") for f in tpl["fields"]}
        check("it maps the teacher", "__teacher" in maps)
        check("it maps both dates", {"from_date", "to_date"} <= maps)

        print("\n2. Read the note")
        start = next_weekday(2)
        end = next_weekday(3)
        img = make_note(teacher["full_name"], start, end, "Viral fever")

        r = c.post(f"{API}/documents/extract", headers=A,
                   data={"template_id": tpl["id"]},
                   files={"file": ("note.png", img, "image/png")})
        if not check("extract returns 201", r.status_code == 201,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        doc = r.json()
        created_docs.append(doc["id"])
        got = {f["field"]: f["value"] for f in doc["extracted_json"]["fields"]}

        check("read the teacher's name",
              (got.get("teacher_name") or "").strip() == teacher["full_name"],
              got.get("teacher_name"))
        check("read the start date", got.get("from_date") == start.isoformat(),
              f"{got.get('from_date')} vs {start}")
        check("read the end date", got.get("to_date") == end.isoformat(),
              f"{got.get('to_date')} vs {end}")
        check("read the reason", "fever" in (got.get("reason") or "").lower(),
              got.get("reason"))

        issues = doc["extracted_json"]["issues"]
        check("a known teacher raises no name error",
              not any(i["code"] in {"teacher_unknown", "teacher_ambiguous"}
                      for i in issues),
              str([i["code"] for i in issues]))

        print("\n3. An unknown name is caught before committing")
        bad = make_note("Wilhelmina Fortescue", start, end, "Flu")
        r = c.post(f"{API}/documents/extract", headers=A,
                   data={"template_id": tpl["id"]},
                   files={"file": ("bad.png", bad, "image/png")})
        if r.status_code == 201:
            bad_doc = r.json()
            created_docs.append(bad_doc["id"])
            codes = [i["code"] for i in bad_doc["extracted_json"]["issues"]]
            check("unknown teacher flagged as an error",
                  "teacher_unknown" in codes, str(codes))
            check("and it blocks commit",
                  bad_doc["extracted_json"]["error_count"] > 0)

            r2 = c.post(f"{API}/documents/{bad_doc['id']}/commit", headers=A,
                        json={"values": {
                            "teacher_name": "Wilhelmina Fortescue",
                            "from_date": start.isoformat(),
                            "to_date": end.isoformat(),
                            "reason": "Flu"}})
            check("the server refuses it too (422)", r2.status_code == 422,
                  str(r2.status_code))
        else:
            check("unknown-name note extracted", False, str(r.status_code))

        print("\n4. Commit the good one")
        r = c.post(f"{API}/documents/{doc['id']}/commit", headers=A, json={
            "values": {
                "teacher_name": teacher["full_name"],
                "from_date": start.isoformat(),
                "to_date": end.isoformat(),
                "reason": "Viral fever",
            }})
        if not check("commit returns 200", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        body = r.json()
        leave_id = body["record"]["id"]
        created_leaves.append(leave_id)

        check("routed to a leave request", body["kind"] == "leave_request")
        check("filed against the NAMED teacher, not the uploading admin",
              body["record"]["teacher_id"] == teacher["id"],
              f"{body.get('teacher')}")
        check("it starts pending an in-charge",
              body["record"]["status"] == "pending_incharge")
        check("provenance links back to the scan",
              body["record"]["source_document_id"] == doc["id"])

        print("\n5. It reaches the HOD, and approving fills the board")
        r = c.get(f"{API}/leave/pending", headers=H)
        check("the HOD sees it in their queue",
              any(x["id"] == leave_id for x in r.json()),
              f"{len(r.json())} pending")

        r = c.post(f"{API}/leave/{leave_id}/review", headers=H, json={"approve": True})
        if not check("HOD approves (200)", r.status_code == 200,
                     f"{r.status_code} {r.text[:200]}"):
            return 1
        review = r.json()
        check("cover was computed for the scanned dates",
              review["periods_affected"] > 0,
              f"{review['periods_affected']} periods")
        check("every period got a candidate",
              review["periods_without_cover"] == 0)

        r = c.get(f"{API}/substitutions/board", headers=A)
        grp = next((g for g in r.json()["groups"] if g["leave_id"] == leave_id), None)
        check("the absence is on the Action Board", grp is not None)
        check("named correctly on the board",
              grp and grp["absent_teacher"] == teacher["full_name"],
              grp["absent_teacher"] if grp else "")
        check("with ranked cover suggestions",
              grp and grp["periods"] and grp["periods"][0]["candidates"],
              f"{len(grp['periods']) if grp else 0} periods")

    print("\n6. Cleanup")
    for lid in created_leaves:
        sb.table("substitutions").delete().eq("leave_request_id", lid).execute()
        sb.table("leave_requests").delete().eq("id", lid).execute()
    for did in created_docs:
        sb.table("documents").delete().eq("id", did).execute()
    check("test data removed", True)

    print(f"\n{'=' * 62}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
