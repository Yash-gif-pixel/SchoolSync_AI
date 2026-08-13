"""A confirmed substitute can take the register for the period they cover.

    python test_e2e_cover_attendance.py

The admin confirms cover on the Action Board as before — nothing about that
changes. What this checks is that the confirmation reaches the classroom: the
substitute can open that period's register, sees it on their Today list, and
gains no access to anything else.
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
        json={"email": email, "password": PASSWORD}, timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def main() -> int:
    sb = admin()

    # The school runs Mon-Sat; a Sunday would test the weekend guard instead.
    day = dt.date.today() + dt.timedelta(days=61)
    while day.isoweekday() == 7:
        day += dt.timedelta(days=1)

    entry = (sb.table("timetable_entries")
             .select("id, slot_id, time_slots!inner(day_of_week), "
                     "teaching_assignments!inner(teacher_id, class_id)")
             .eq("time_slots.day_of_week", day.isoweekday())
             .limit(1).execute().data or [])
    if not entry:
        print("! No timetable entry on that weekday — generate a timetable.")
        return 1
    entry = entry[0]
    a = entry["teaching_assignments"]
    class_id, slot_id, owner_id = a["class_id"], entry["slot_id"], a["teacher_id"]

    stand_in = (sb.table("profiles").select("id, full_name")
                .eq("role", "teacher").neq("id", owner_id)
                .limit(1).execute().data or [])[0]
    sub_email = sb.auth.admin.get_user_by_id(stand_in["id"]).user.email
    h = {"Authorization": f"Bearer {token(sub_email)}"}
    print(f"{stand_in['full_name']} will cover a class they do not teach\n")

    # They must genuinely not teach it, or the test proves nothing.
    own = (sb.table("teaching_assignments").select("id")
           .eq("teacher_id", stand_in["id"]).eq("class_id", class_id)
           .execute().data)
    if own:
        print("! Picked a teacher who already teaches that class.")
        return 1

    leave = sb.table("leave_requests").insert({
        "teacher_id": owner_id,
        "from_date": day.isoformat(), "to_date": day.isoformat(),
        "reason": "E2E cover attendance", "status": "approved",
    }).execute().data[0]

    sub = None
    try:
        with httpx.Client(timeout=60) as c:
            r = c.get(f"{API}/attendance/roster", headers=h, params={
                "class_id": class_id, "slot_id": slot_id,
                "date": day.isoformat()})
            check("without cover, the register is refused",
                  r.status_code == 403, str(r.status_code))

            sub = sb.table("substitutions").insert({
                "leave_request_id": leave["id"],
                "timetable_entry_id": entry["id"],
                "substitute_teacher_id": stand_in["id"],
                "date": day.isoformat(), "rank": 1,
                "status": "suggested", "rationale": "E2E",
            }).execute().data[0]

            r = c.get(f"{API}/attendance/roster", headers=h, params={
                "class_id": class_id, "slot_id": slot_id,
                "date": day.isoformat()})
            check("a merely SUGGESTED substitute still cannot",
                  r.status_code == 403, str(r.status_code))

            print("\nAdmin confirms the cover…")
            sb.table("substitutions").update(
                {"status": "confirmed"}).eq("id", sub["id"]).execute()

            r = c.get(f"{API}/attendance/roster", headers=h, params={
                "class_id": class_id, "slot_id": slot_id,
                "date": day.isoformat()})
            check("now the register opens", r.status_code == 200,
                  str(r.status_code))

            students = r.json().get("students", [])
            check("the roster has students", bool(students),
                  f"{len(students)}")

            if students:
                r = c.post(f"{API}/attendance/mark", headers=h, json={
                    "class_id": class_id, "slot_id": slot_id,
                    "date": day.isoformat(),
                    "marks": [{"student_id": students[0]["id"],
                               "status": "absent"}],
                })
                check("and marks can be written", r.status_code == 200,
                      str(r.status_code))
                sb.table("attendance").delete().eq(
                    "class_id", class_id).eq("slot_id", slot_id).eq(
                        "date", day.isoformat()).execute()

            print("\nAccess is scoped to that one period…")
            other = (day + dt.timedelta(days=1))
            while other.isoweekday() == 7:
                other += dt.timedelta(days=1)
            r = c.get(f"{API}/attendance/roster", headers=h, params={
                "class_id": class_id, "slot_id": slot_id,
                "date": other.isoformat()})
            check("same class, different day is still refused",
                  r.status_code == 403, str(r.status_code))

            other_slot = (sb.table("time_slots").select("id")
                          .eq("day_of_week", day.isoweekday())
                          .neq("id", slot_id).eq("is_break", False)
                          .limit(1).execute().data or [])
            if other_slot:
                r = c.get(f"{API}/attendance/roster", headers=h, params={
                    "class_id": class_id, "slot_id": other_slot[0]["id"],
                    "date": day.isoformat()})
                check("same day, different period is still refused",
                      r.status_code == 403, str(r.status_code))

            print("\nAnd it is findable…")
            r = c.get(f"{API}/attendance/today", headers=h,
                      params={"date": day.isoformat()})
            covering = [p for p in r.json().get("periods", [])
                        if p.get("covering_for")]
            check("the covered period is on their Today list", bool(covering),
                  covering[0]["covering_for"] if covering else "not listed")

    finally:
        print("\nCleaning up…")
        sb.table("substitutions").delete().eq(
            "leave_request_id", leave["id"]).execute()
        sb.table("leave_requests").delete().eq("id", leave["id"]).execute()
        check("test data removed", True)

    print(f"\n{'=' * 70}\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
