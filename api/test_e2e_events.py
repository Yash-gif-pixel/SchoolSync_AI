"""End-to-end check of school events.

    python test_e2e_events.py

Creates a multi-day event with real teachers on it, confirms the roster comes
back, that `teachers_required` is derived rather than typed, and — the point
of the whole feature — that the staffing forecast counts the event on EVERY
day it runs rather than only the first.
"""

from __future__ import annotations

import datetime as dt
import sys

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


def main() -> int:
    print("Signing in as admin…")
    hdr = {"Authorization": f"Bearer {token()}"}
    event_id = None
    start = dt.date.today() + dt.timedelta(days=3)
    end = start + dt.timedelta(days=2)          # three days inclusive

    with httpx.Client(timeout=120) as c:
        try:
            print("\nFetching the staff list…")
            r = c.get(f"{API}/directory/staff", headers=hdr)
            if not check("staff list returns 200", r.status_code == 200,
                         str(r.status_code)):
                return 1
            staff = r.json()
            check("staff list is populated", len(staff) > 10,
                  f"{len(staff)} people")
            check("each entry has a name",
                  all(p.get("full_name") for p in staff))

            picked = [p["id"] for p in staff if p["role"] == "teacher"][:12]
            check("found teachers to assign", len(picked) == 12,
                  f"{len(picked)}")

            print(f"\nCreating a 3-day event with {len(picked)} teachers…")
            r = c.post(f"{API}/events", headers=hdr, json={
                "name": "E2E Annual Day",
                "starts_on": start.isoformat(),
                "ends_on": end.isoformat(),
                "event_type": "annual_day",
                "teacher_ids": picked,
            })
            if not check("create returns 201", r.status_code == 201,
                         f"{r.status_code} {r.text[:200]}"):
                return 1
            event = r.json()
            event_id = event["id"]

            check("spans three days", event["days"] == 3, str(event["days"]))
            check("roster came back", len(event["teachers"]) == 12,
                  f"{len(event['teachers'])}")
            check("teachers are named",
                  all(t.get("full_name") for t in event["teachers"]))

            row = admin().table("calendar_events").select(
                "teachers_required, ends_on").eq(
                    "id", event_id).single().execute().data
            check("teachers_required derived from the roster",
                  row["teachers_required"] == 12,
                  str(row["teachers_required"]))
            check("end date stored", row["ends_on"] == end.isoformat())

            print("\nValidation…")
            check("end before start is rejected",
                  c.post(f"{API}/events", headers=hdr, json={
                      "name": "Backwards",
                      "starts_on": end.isoformat(),
                      "ends_on": start.isoformat(),
                  }).status_code == 422)
            check("an unknown teacher is rejected",
                  c.post(f"{API}/events", headers=hdr, json={
                      "name": "Ghost",
                      "starts_on": start.isoformat(),
                      "teacher_ids": ["00000000-0000-0000-0000-000000000000"],
                  }).status_code == 400)
            check("unauthenticated create is rejected",
                  c.post(f"{API}/events", json={
                      "name": "nope", "starts_on": start.isoformat(),
                  }).status_code in (401, 403))

            print("\nWho is busy mid-event…")
            middle = start + dt.timedelta(days=1)
            r = c.get(f"{API}/events/busy",
                      params={"on": middle.isoformat()}, headers=hdr)
            busy = r.json()
            check("busy returns 200", r.status_code == 200)
            check("all 12 are busy on the middle day",
                  len(busy["teachers"]) >= 12, f"{len(busy['teachers'])}")
            check("the event is named", any(
                e["name"] == "E2E Annual Day" for e in busy["events"]))

            after = end + dt.timedelta(days=1)
            r = c.get(f"{API}/events/busy",
                      params={"on": after.isoformat()}, headers=hdr)
            check("nobody is busy the day after it ends",
                  not any(e["name"] == "E2E Annual Day"
                          for e in r.json()["events"]))

            print("\nThe forecast must see all three days…")
            r = c.get(f"{API}/forecast/staffing",
                      params={"horizon_days": 14}, headers=hdr)
            if not check("forecast returns 200", r.status_code == 200,
                         f"{r.status_code} {r.text[:200]}"):
                return 1
            blob = str(r.json())
            # Counted once per day it runs, not once per event — the whole
            # reason the forecast router expands date ranges.
            mentions = blob.count("E2E Annual Day")
            check("the forecast counts the event on all three days",
                  mentions >= 3, f"{mentions} mention(s)")

        finally:
            if event_id:
                print("\nCleaning up…")
                c.delete(f"{API}/events/{event_id}", headers=hdr)
                sb = admin()
                check("event deleted",
                      not sb.table("calendar_events").select("id")
                      .eq("id", event_id).execute().data)
                check("its roster went with it",
                      not sb.table("event_teachers").select("event_id")
                      .eq("event_id", event_id).execute().data)

    print(f"\n{'=' * 70}\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
