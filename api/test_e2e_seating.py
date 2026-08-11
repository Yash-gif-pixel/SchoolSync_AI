"""End-to-end check of the exam calendar and seating API.

    python test_e2e_seating.py

Drives the real HTTP surface as the seeded admin: create an exam spanning two
weeks, schedule sittings on specific days for specific grades, generate seating
for one day, and verify on the stored rows that only that day's grades left
their rooms.
"""

from __future__ import annotations

import datetime as dt
import sys
from collections import defaultdict

import httpx

from app.config import get_settings
from app.db import admin

API = "http://127.0.0.1:8000"
ADMIN_EMAIL = "admin@school.test"
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


def token() -> str:
    s = get_settings()
    r = httpx.post(
        f"{s.supabase_url}/auth/v1/token?grant_type=password",
        headers={"apikey": s.supabase_anon_key},
        json={"email": ADMIN_EMAIL, "password": PASSWORD},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def codes(diags: list[dict]) -> set[str]:
    return {d["code"] for d in diags}


def main() -> int:
    print("Signing in as admin…")
    hdr = {"Authorization": f"Bearer {token()}"}
    exam_id = None
    # A Monday, so the weekday arithmetic below is predictable.
    monday = dt.date(2026, 9, 7)

    with httpx.Client(timeout=180) as c:
        try:
            print("\nCreating a two-week exam for grades 1, 2 and 3…")
            r = c.post(f"{API}/exams", headers=hdr, json={
                "name": "E2E Half-Yearly",
                "grades": [1, 2, 3],
            })
            if not check("create returns 201", r.status_code == 201,
                         f"{r.status_code} {r.text[:200]}"):
                return 1
            exam = r.json()
            exam_id = exam["id"]
            check("grades on the roster", exam["grades"] == [1, 2, 3])
            check("starts with an empty calendar", exam["sittings"] == [])

            check("unauthenticated create is rejected",
                  c.post(f"{API}/exams",
                         json={"name": "nope", "grades": [1]}).status_code
                  in (401, 403))

            print("\nScheduling days…")
            plan = [
                (monday,                       "Mathematics", [1, 2]),
                (monday + dt.timedelta(days=2), "Science",     [1, 2]),
                (monday + dt.timedelta(days=3), "English",     [1]),
                (monday + dt.timedelta(days=8), "Hindi",       [3]),
            ]
            for day, paper, grades in plan:
                r = c.post(f"{API}/exams/{exam_id}/sittings", headers=hdr,
                           json={"sits_on": day.isoformat(),
                                 "paper": paper, "grades": grades})
                if not check(f"scheduled {paper} on {day:%d/%m}",
                             r.status_code == 201,
                             f"{r.status_code} {r.text[:160]}"):
                    return 1

            print("\nReviewing the calendar…")
            r = c.get(f"{API}/exams/{exam_id}/schedule", headers=hdr)
            if not check("schedule returns 200", r.status_code == 200,
                         str(r.status_code)):
                return 1
            sched = r.json()
            check("all four days come back",
                  len(sched["sittings"]) == 4, str(len(sched["sittings"])))
            check("sittings are in date order",
                  [s["sits_on"] for s in sched["sittings"]]
                  == sorted(s["sits_on"] for s in sched["sittings"]))

            found = codes(sched["diagnostics"])
            # The gap rule was removed on purpose: the admin picks the days,
            # and a threshold nobody set should not produce warnings.
            check("no gap-rule warning is invented",
                  "gap_too_short" not in found, str(sorted(found)))
            check("the season span is reported", "span" in found)
            check("no false 'unscheduled grade' warning",
                  "grade_unscheduled" not in found, str(sorted(found)))

            # Grade 3 has one paper, so removing it should raise the warning.
            print("\nChecking the unscheduled-grade warning…")
            g3 = next(s for s in sched["sittings"] if s["grades"] == [3])
            c.delete(f"{API}/sittings/{g3['id']}", headers=hdr)
            after = c.get(f"{API}/exams/{exam_id}/schedule",
                          headers=hdr).json()
            check("grade with no dates is now flagged",
                  "grade_unscheduled" in codes(after["diagnostics"]))
            check("that day is gone from the calendar",
                  len(after["sittings"]) == 3)

            print("\nSeating Monday (grades 1 and 2)…")
            monday_sitting = next(
                s for s in after["sittings"] if s["sits_on"] == monday.isoformat())
            r = c.post(f"{API}/sittings/{monday_sitting['id']}/seating",
                       headers=hdr)
            if not check("generate returns 201", r.status_code == 201,
                         f"{r.status_code} {r.text[:300]}"):
                return 1
            stats = r.json()["stats"]
            print(f"    {stats['seated']}/{stats['students']} seated, "
                  f"{stats['rooms_used']} rooms, "
                  f"{stats['adjacent_same_class']} adjacent, "
                  f"{stats.get('wall_seconds')}s")
            check("everyone seated", stats["unseated"] == 0)
            check("no same-class neighbours",
                  stats["adjacent_same_class"] == 0)
            check("the plan records its date",
                  stats.get("sits_on") == monday.isoformat(),
                  str(stats.get("sits_on")))

            print("\nReading the stored plan…")
            r = c.get(f"{API}/sittings/{monday_sitting['id']}/seating",
                      headers=hdr)
            rooms = r.json()["rooms"]
            check("read returns 200", r.status_code == 200)
            check("plan has rooms", bool(rooms), f"{len(rooms)} rooms")

            sb = admin()
            classes = sb.table("classes").select(
                "id, grade, home_room_id").execute().data
            allowed = {c_["home_room_id"] for c_ in classes
                       if c_["grade"] in (1, 2)}
            others = {c_["home_room_id"] for c_ in classes
                      if c_["grade"] not in (1, 2)}
            used = {room["room_id"] for room in rooms}

            check("only Monday's grades' rooms were used", used <= allowed,
                  f"{len(used - allowed)} foreign rooms")
            check("grade 3 keeps its classrooms that day",
                  not (used & others))

            breaches = 0
            for room in rooms:
                grid = {(s["seat_row"], s["seat_col"]): s["class_name"]
                        for s in room["seats"]}
                for (rr, cc), cls in grid.items():
                    for dr, dc in ((0, 1), (1, 0)):
                        if grid.get((rr + dr, cc + dc)) == cls:
                            breaches += 1
            check("stored plan has no same-class neighbours", breaches == 0,
                  f"{breaches} breaches")

            per_room = defaultdict(set)
            for room in rooms:
                for s in room["seats"]:
                    per_room[room["room_name"]].add(s["class_name"])
            solo = [k for k, v in per_room.items() if len(v) < 2]
            check("every room mixes at least two classes", not solo, str(solo))

            print("\nRegenerating must replace, not accumulate…")
            c.post(f"{API}/sittings/{monday_sitting['id']}/seating",
                   headers=hdr)
            plans = sb.table("seating_plans").select("id").eq(
                "sitting_id", monday_sitting["id"]).execute().data
            check("still exactly one plan for the day", len(plans) == 1,
                  f"{len(plans)} plans")

            print("\nOther days are untouched by Monday's plan…")
            wed = next(s for s in after["sittings"]
                       if s["sits_on"] != monday.isoformat())
            body = c.get(f"{API}/sittings/{wed['id']}/seating",
                         headers=hdr).json()
            check("an unseated day reports no plan", body["plan"] is None)

        finally:
            if exam_id:
                print("\nCleaning up…")
                c.delete(f"{API}/exams/{exam_id}", headers=hdr)
                sb = admin()
                check("exam deleted",
                      not sb.table("exams").select("id")
                      .eq("id", exam_id).execute().data)
                check("its sittings went with it",
                      not sb.table("exam_sittings").select("id")
                      .eq("exam_id", exam_id).execute().data)

    print(f"\n{'=' * 70}\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
