"""Supabase clients.

`admin` uses the service_role key and bypasses RLS -- use it only for work the
backend is trusted to do (solving timetables, seeding, batch writes). Anything
acting on behalf of a signed-in user should go through `user_client` so RLS
still applies.
"""

from __future__ import annotations

from functools import lru_cache

from supabase import Client, create_client

from .config import get_settings


@lru_cache
def admin() -> Client:
    s = get_settings()
    return create_client(s.supabase_url, s.supabase_service_key)


def user_client(access_token: str) -> Client:
    """A client scoped to the caller's JWT, so RLS policies are enforced."""
    s = get_settings()
    c = create_client(s.supabase_url, s.supabase_anon_key)
    c.postgrest.auth(access_token)
    return c
