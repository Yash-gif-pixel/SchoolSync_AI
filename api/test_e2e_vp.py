"""Vice Principal approval routing, and event-aware substitution.

    python test_e2e_vp.py

Two behaviours that only matter together:

  * A head of department's leave goes UP to the Vice Principal, not sideways
    to another head in the same department.
  * A teacher committed to Annual Day is not offered as cover, because they
    are in the building but not available.
"""

from __future__ import annotations

import datetime as dt
import sys

import httpx

from app.config import get_settings
from app.db import admin

API = "http://127.0.0.1:8000"
PASSWORD = "Demo@12345"

GREEN, RED, RESET = "\033[92m", "\033[91m", "\033[0m"
passed = failed = 0


def check(label: str, ok: bool, detail: str = "") -> bool:
    global passed, failed
    colour = GREEN if ok else RED
    print(f"  {colour}[{'PASS' if ok else 'FAIL'}]{RESET} {label}"
          f"{'  -- ' + detail if detail else ''}")
    if ok:
        passed += 1
    else:
        failed += 1
    return ok


def token(email: str) -> str:
    s = get_settings()
    r = httpx.post(
        f"{s.supabase_url}/auth/v1/token?grant_type=password",
        headers={"apikey": s.supabase_anon_key},
        json={"email": email, "password": PASSWORD},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def main() -> int:
    sb = admin()

    vp = (sb.table("profiles").select("id, full_name")
          .eq("is_vice_principal", True).maybe_single().execute())
    if not vp or not vp.data:
        print("! No Vice Principal exists — run `python make_leadership.py` first.")
        return 1
    print(f"Vice Principal: {vp.data['full_name']}")

    admin_row = (sb.table("profiles").select("full_name")
                 .eq("role", "admin").limit(1).execute().data or [{}])
    check("the admin is not named Principal anything",
          "Principal" not in (admin_row[0].get("full_name") or ""),
          admin_row[0].get("full_name", "?"))
    check("exactly one Vice Principal",
          len(sb.table("profiles").select("id")
              .eq("is_vice_principal", True).execute().data) == 1)

    hod = (sb.table("profiles").select("id, full_name, department_id")
           .eq("is_approver", True).eq("role", "teacher")
           .limit(1).execute().data or [])
    if not hod:
        print("! No HOD found in the seed data.")
        return 1
    hod = hod[0]
    hod_email = (sb.auth.admin.get_user_by_id(hod["id"])).user.email
    print(f"Head of department: {hod['full_name']} <{hod_email}>\n")

    vp_hdr = {"Authorization": f"Bearer {token('vp@school.test')}"}
    hod_hdr = {"Authorization": f"Bearer {token(hod_email)}"}

    leave_id = event_id = None
    start = dt.date.today() + dt.timedelta(days=45)
    end = start + dt.timedelta(days=1)

    with httpx.Client(timeout=120) as c:
        try:
            print("The HOD files leave…")
            r = c.post(f"{API}/leave", headers=hod_hdr, json={
                "from_date": start.isoformat(),
                "to_date": end.isoformat(),
                "reason": "E2E vice-principal routing",
            })
            if not check("HOD can file leave", r.status_code in (200, 201),
                         f"{r.status_code} {r.text[:200]}"):
                return 1
            leave_id = r.json()["id"]

            print("\nWhose desk does it land on?")
            vp_queue = c.get(f"{API}/leave/pending", headers=vp_hdr).json()
            check("it appears in the Vice Principal's queue",
                  any(x["id"] == leave_id for x in vp_queue),
                  f"{len(vp_queue)} pending")

            own_queue = c.get(f"{API}/leave/pending", headers=hod_hdr).json()
            check("it does NOT appear in the HOD's own queue",
                  not any(x["id"] == leave_id for x in own_queue),
                  f"{len(own_queue)} pending")

            check("an HOD cannot approve their own leave",
                  c.post(f"{API}/leave/{leave_id}/review", headers=hod_hdr,
                         json={"approve": True}).status_code == 403)

            print("\nAn event takes staff off the board…")
            staff = c.get(f"{API}/directory/staff", headers=vp_hdr).json()
            busy_ids = [p["id"] for p in staff
                        if p["role"] == "teacher" and p["id"] != hod["id"]][:40]
            r = c.post(f"{API}/events", headers={
                "Authorization": f"Bearer {token('admin@school.test')}"
            }, json={
                "name": "E2E Annual Day Rehearsal",
                "starts_on": start.isoformat(),
                "ends_on": end.isoformat(),
                "teacher_ids": busy_ids,
            })
            if not check("event created", r.status_code == 201,
                         f"{r.status_code} {r.text[:160]}"):
                return 1
            event_id = r.json()["id"]

            print("\nThe VP approves, and the matcher runs…")
            r = c.post(f"{API}/leave/{leave_id}/review", headers=vp_hdr,
                       json={"approve": True})
            if not check("the Vice Principal may approve it",
                         r.status_code == 200,
                         f"{r.status_code} {r.text[:200]}"):
                return 1

            subs = (sb.table("substitutions")
                    .select("substitute_teacher_id, rationale")
                    .eq("leave_request_id", leave_id).execute().data or [])
            check("suggestions were generated", bool(subs), f"{len(subs)} rows")

            suggested = {s["substitute_teacher_id"] for s in subs
                         if s["substitute_teacher_id"]}
            overlap = suggested & set(busy_ids)
            check("nobody at the event was offered as cover", not overlap,
                  f"{len(overlap)} committed teachers suggested")

            uncovered = [s for s in subs if not s["substitute_teacher_id"]]
            if uncovered:
                explains = [s for s in uncovered
                            if "committed to" in (s["rationale"] or "")]
                check("uncovered periods say the event is why",
                      bool(explains),
                      f"{len(explains)} of {len(uncovered)} explained")
            else:
                print("  (every period still had cover — no gap to explain)")

        finally:
            print("\nCleaning up…")
            if leave_id:
                sb.table("substitutions").delete().eq(
                    "leave_request_id", leave_id).execute()
                sb.table("leave_requests").delete().eq(
                    "id", leave_id).execute()
            if event_id:
                sb.table("calendar_events").delete().eq(
                    "id", event_id).execute()
            check("test data removed", True)

    print(f"\n{'=' * 70}\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
