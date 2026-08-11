"""A teacher cannot be on two overlapping leaves at once.

    python test_e2e_leave_clash.py

Overlapping approved leave would have the substitution matcher arranging cover
for the same periods twice, so this is checked on create, on approve, and by
the database itself. Cleans up after itself.
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

sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

passed = failed = 0
created: list[str] = []


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


def workday(offset: int) -> dt.date:
    d = dt.date.today() + dt.timedelta(days=offset)
    while d.isoweekday() == 7:
        d += dt.timedelta(days=1)
    return d


def file_leave(c, headers, start, end, reason="clash test"):
    return c.post(f"{API}/leave", headers=headers, json={
        "from_date": start.isoformat(),
        "to_date": end.isoformat(),
        "reason": reason,
    })


def main() -> int:
    T = {"Authorization": f"Bearer {token_for('teacher@school.test')}"}
    H = {"Authorization": f"Bearer {token_for('hod@school.test')}"}
    teacher = httpx.get(f"{API}/me", headers=T, timeout=30).json()

    # Far enough out not to collide with seeded history.
    d1, d2, d3 = workday(40), workday(41), workday(42)
    for d in sb.table("leave_requests").select("id").eq(
            "teacher_id", teacher["id"]).gte(
            "from_date", d1.isoformat()).execute().data:
        sb.table("leave_requests").delete().eq("id", d["id"]).execute()

    with httpx.Client(timeout=60) as c:
        print("\n1. The first request goes through")
        r = file_leave(c, T, d1, d1)
        if not check("filed (201)", r.status_code == 201, f"{r.status_code} {r.text[:160]}"):
            return 1
        first = r.json()
        created.append(first["id"])

        print("\n2. The same day again is refused")
        r = file_leave(c, T, d1, d1)
        check("exact duplicate rejected (409)", r.status_code == 409, str(r.status_code))
        msg = r.json().get("detail", "") if r.status_code == 409 else ""
        check("the message says when", d1.strftime("%d %b") in msg, msg[:110])
        check("and says it is awaiting approval",
              "awaiting approval" in msg.lower(), msg[:110])

        print("\n3. Partial overlaps are refused too")
        r = file_leave(c, T, d1, d3)
        check("a range starting on the booked day", r.status_code == 409, str(r.status_code))
        r = file_leave(c, T, workday(38), d1)
        check("a range ending on the booked day", r.status_code == 409, str(r.status_code))
        r = file_leave(c, T, workday(38), workday(45))
        check("a range swallowing the booked day", r.status_code == 409, str(r.status_code))

        print("\n4. Neighbouring days are still allowed")
        r = file_leave(c, T, d2, d3)
        check("the day after is fine (201)", r.status_code == 201,
              f"{r.status_code} {r.text[:120]}")
        if r.status_code == 201:
            created.append(r.json()["id"])
            r2 = file_leave(c, T, d2, d2)
            check("but now that one clashes too", r2.status_code == 409, str(r2.status_code))

        print("\n5. Approving does not change the answer")
        r = c.post(f"{API}/leave/{first['id']}/review", headers=H, json={"approve": True})
        check("HOD approves the first (200)", r.status_code == 200, str(r.status_code))

        r = file_leave(c, T, d1, d1)
        check("re-applying for approved dates rejected (409)",
              r.status_code == 409, str(r.status_code))
        msg = r.json().get("detail", "") if r.status_code == 409 else ""
        check("and now says 'already approved'",
              "already approved" in msg.lower(), msg[:110])

        print("\n6. A rejected request must not block re-applying")
        d4 = workday(50)
        r = file_leave(c, T, d4, d4)
        rejected_id = r.json()["id"] if r.status_code == 201 else None
        check("filed (201)", r.status_code == 201, str(r.status_code))
        if rejected_id:
            created.append(rejected_id)
            c.post(f"{API}/leave/{rejected_id}/review", headers=H, json={"approve": False})
            r = file_leave(c, T, d4, d4, "second attempt")
            check("the same dates can be filed again (201)",
                  r.status_code == 201, f"{r.status_code} {r.text[:120]}")
            if r.status_code == 201:
                created.append(r.json()["id"])

        print("\n7. The database refuses it even without the API")
        try:
            sb.table("leave_requests").insert({
                "teacher_id": teacher["id"],
                "from_date": d1.isoformat(),
                "to_date": d1.isoformat(),
                "reason": "bypassing the API",
                "status": "approved",
            }).execute()
            check("exclusion constraint blocks a direct insert", False,
                  "the row was accepted — apply db/005_no_overlapping_leave.sql")
        except Exception as e:
            check("exclusion constraint blocks a direct insert",
                  "no_overlapping_leave" in str(e) or "exclusion" in str(e).lower(),
                  type(e).__name__)

    print("\n8. Cleanup")
    for lid in created:
        sb.table("substitutions").delete().eq("leave_request_id", lid).execute()
        sb.table("leave_requests").delete().eq("id", lid).execute()
    check("test data removed", True)

    print(f"\n{'=' * 60}")
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
