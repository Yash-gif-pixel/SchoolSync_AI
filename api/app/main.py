"""Smart School Ops API.

Phase 0 surface: health, schema check, and an authenticated /me that proves
JWT verification and the profiles join both work end to end.
Later phases add /documents, /timetable, /leave and /forecast.
"""

from __future__ import annotations

import time

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .auth import CurrentUser, get_current_user
from .config import get_settings
from .db import admin
from .routers import (
    attendance,
    directory,
    documents,
    events,
    forecast,
    leave,
    seating,
    substitutions,
    templates,
    timetable,
)

settings = get_settings()

app = FastAPI(
    title="SchoolSync AI API",
    version="1.0.0",
    description=(
        "AI-powered school operations platform. Document extraction, "
        "constraint-solved timetabling, live substitution matching, staffing "
        "forecasts and exam seating.\n\n"
        "Every endpoint requires a Supabase JWT — an unauthenticated request "
        "returns 401."
    ),
    # Nulling openapi_url matters as much as the two pages: without it the
    # same information is still served as JSON, just without the nice front
    # end. See Settings.docs_enabled for when to turn this off.
    docs_url="/docs" if settings.docs_enabled else None,
    redoc_url="/redoc" if settings.docs_enabled else None,
    openapi_url="/openapi.json" if settings.docs_enabled else None,
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
app.include_router(events.router)
app.include_router(directory.router)
app.include_router(seating.router)


@app.get("/", tags=["system"], include_in_schema=False)
def root() -> dict:
    """A signpost, because this is the address people try first.

    Without it the root returns a bare `{"detail":"Not Found"}`, which reads
    as a broken deployment rather than as an API with no page at `/`. Anyone
    pasting the bare URL into a browser deserves to be told where to go.

    Hidden from the schema: it documents nothing, and listing it in /docs
    alongside the real endpoints would only add noise.
    """
    return {
        "service": app.title,
        "version": app.version,
        "status": "ok",
        "docs": "/docs" if settings.docs_enabled else "disabled",
        "health": "/health/db",
        "note": "This is the API. The school app is a separate web address.",
    }


@app.get("/health", tags=["system"])
def health() -> dict:
    return {"status": "ok", "service": "schoolsync-ai-api", "version": app.version}


@app.get("/health/db", tags=["system"])
def health_db() -> dict:
    """Row count per table — the fastest way to confirm schema + seed landed.

    Seventeen tables means seventeen separate round trips, and the API and the
    database are not in the same place. About one call in ten saw a single
    table fail with a transient httpx ReadError — a dropped connection, not a
    missing table — which surfaced on the dashboard as "ERROR: ReadError"
    where a number belonged, and flipped `connected` to false.

    So each table gets one retry. A genuine problem — a table that does not
    exist, a bad key — fails identically twice and is still reported. A
    dropped socket does not.
    """
    counts: dict[str, object] = {}
    for t in EXPECTED_TABLES:
        for attempt in (1, 2):
            try:
                res = (admin().table(t).select("id", count="exact")
                       .limit(1).execute())
                counts[t] = res.count
                break
            except Exception as e:
                if attempt == 2:
                    counts[t] = f"ERROR: {type(e).__name__}"
                else:
                    time.sleep(0.15)
    missing = [t for t, v in counts.items() if isinstance(v, str)]
    return {
        "connected": not missing,
        "missing_or_broken": missing,
        "row_counts": counts,
    }


@app.get("/me", tags=["auth"])
def me(user: CurrentUser = Depends(get_current_user)) -> dict:
    """Who the caller is, and every post they hold.

    All four responsibility flags are returned, not just `is_approver`. Leave
    routes on them — a head of department's own leave goes to the Vice
    Principal, and theirs to the Principal — so a client that can only see
    `is_approver` cannot tell which queue to show, and has no way to find out
    short of querying `profiles` directly and defeating the point of /me.
    """
    return {
        "id": user.id,
        "email": user.email,
        "full_name": user.full_name,
        "role": user.role,
        "department_id": user.department_id,
        "is_approver": user.is_approver,
        "is_vice_principal": user.is_vice_principal,
        "is_principal": user.is_principal,
        "is_admin": user.is_admin,
    }
