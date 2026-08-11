"""Request authentication.

The API verifies the caller's Supabase JWT by asking Supabase to resolve it,
rather than validating the signature locally. That costs one round-trip per
request but avoids holding the project's JWT secret as a fourth credential,
and it keeps working if the project moves to asymmetric signing keys.
"""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import Depends, Header, HTTPException, status

from .db import admin


@dataclass(frozen=True)
class CurrentUser:
    id: str
    email: str | None
    role: str
    full_name: str
    department_id: str | None
    is_approver: bool
    is_vice_principal: bool
    is_principal: bool
    access_token: str

    @property
    def is_admin(self) -> bool:
        return self.role == "admin"

    @property
    def reviews_hod_leave(self) -> bool:
        """A head of department cannot approve their own leave, and nobody
        inside their department outranks them. The Vice Principal is who
        that request is meant for."""
        return self.is_vice_principal or self.is_admin


async def get_current_user(
    authorization: str | None = Header(default=None),
) -> CurrentUser:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "Missing bearer token"
        )
    token = authorization.split(" ", 1)[1].strip()

    try:
        res = admin().auth.get_user(token)
    except Exception:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")

    if not res or not res.user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")

    uid = res.user.id
    prof = (
        admin()
        .table("profiles")
        .select("full_name, role, department_id, is_approver, is_vice_principal, "
        "is_principal")
        .eq("id", uid)
        .maybe_single()
        .execute()
    )
    if not prof or not prof.data:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Authenticated but no profile row exists for this user",
        )

    p = prof.data
    return CurrentUser(
        id=uid,
        email=res.user.email,
        role=p["role"],
        full_name=p["full_name"],
        department_id=p.get("department_id"),
        is_approver=bool(p.get("is_approver")),
        is_vice_principal=bool(p.get("is_vice_principal")),
        is_principal=bool(p.get("is_principal")),
        access_token=token,
    )


async def require_admin(
    user: CurrentUser = Depends(get_current_user),
) -> CurrentUser:
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin role required")
    return user
