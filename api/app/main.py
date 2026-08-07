"""Smart School Ops API.

Phase 0 surface: health, schema check, and an authenticated /me that proves
JWT verification and the profiles join both work end to end.
Later phases add /documents, /timetable, /leave and /forecast.
"""

from __future__ import annotations

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .auth import CurrentUser, get_current_user
from .config import get_settings
from .db import admin
from .routers import (
    attendance,
    documents,
    forecast,
    leave,
    substitutions,
    templates,
    timetable,
)

settings = get_settings()

app = FastAPI(
    title="SchoolSync AI API",
    version="0.2.0",
    description="AI-powered school operations platform — Phase 1: AI Document Reader",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Tables Phase 0 is expected to create, with the row counts seed.py produces.
EXPECTED_TABLES = [
    "departments", "subjects", "rooms", "classes", "time_slots", "profiles",
    "students", "teaching_assignments", "timetable_versions",
    "timetable_entries", "attendance", "leave_requests", "substitutions",
    "documents", "calendar_events", "document_templates", "extracted_records",
]


app.include_router(templates.router)
app.include_router(documents.router)
app.include_router(timetable.router)
app.include_router(attendance.router)
app.include_router(leave.router)
app.include_router(substitutions.router)
app.include_router(forecast.router)


@app.get("/health", tags=["system"])
def health() -> dict:
    return {"status": "ok", "service": "schoolsync-ai-api", "version": app.version}


@app.get("/health/db", tags=["system"])
def health_db() -> dict:
    """Row count per table — the fastest way to confirm schema + seed landed."""
    counts: dict[str, object] = {}
    for t in EXPECTED_TABLES:
        try:
            res = admin().table(t).select("id", count="exact").limit(1).execute()
            counts[t] = res.count
        except Exception as e:
            counts[t] = f"ERROR: {type(e).__name__}"
    missing = [t for t, v in counts.items() if isinstance(v, str)]
    return {
        "connected": not missing,
        "missing_or_broken": missing,
        "row_counts": counts,
    }


@app.get("/me", tags=["auth"])
def me(user: CurrentUser = Depends(get_current_user)) -> dict:
    return {
        "id": user.id,
        "email": user.email,
        "full_name": user.full_name,
        "role": user.role,
        "department_id": user.department_id,
        "is_approver": user.is_approver,
    }
