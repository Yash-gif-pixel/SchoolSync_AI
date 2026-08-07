"""Confirm the schema applied. Run after 001_schema.sql (and again after 002_rls.sql)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from supabase import create_client

load_dotenv(Path(__file__).with_name(".env"))
sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])

EXPECTED = [
    "departments", "subjects", "rooms", "classes", "time_slots", "profiles",
    "students", "teaching_assignments", "timetable_versions",
    "timetable_entries", "attendance", "leave_requests", "substitutions",
    "documents", "calendar_events",
]

print(f"{'table':<24} {'rows':>6}   status")
print("-" * 48)
missing = []
for t in EXPECTED:
    try:
        res = sb.table(t).select("id", count="exact").limit(1).execute()
        print(f"{t:<24} {res.count:>6}   ok")
    except Exception as e:
        missing.append(t)
        print(f"{t:<24} {'-':>6}   MISSING ({type(e).__name__})")

print("-" * 48)
if missing:
    print(f"FAIL: {len(missing)} table(s) missing: {', '.join(missing)}")
    sys.exit(1)
print(f"OK: all {len(EXPECTED)} tables present")

try:
    buckets = [b.id for b in sb.storage.list_buckets()]
    print(f"storage buckets: {buckets}  {'ok' if 'documents' in buckets else 'MISSING documents'}")
except Exception as e:
    print(f"storage check failed: {e}")
