"""Environment configuration. Fails loudly at import if a required key is missing."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


class Settings:
    def __init__(self) -> None:
        self.supabase_url: str = self._require("SUPABASE_URL")
        self.supabase_anon_key: str = self._require("SUPABASE_ANON_KEY")
        self.supabase_service_key: str = self._require("SUPABASE_SERVICE_ROLE_KEY")
        self.gemini_api_key: str = os.getenv("GEMINI_API_KEY", "")

        # Flutter web dev server ports are assigned at random unless pinned;
        # we pin to 5000 in the run script so this list stays short.
        self.cors_origins: list[str] = [
            o.strip()
            for o in os.getenv(
                "CORS_ORIGINS",
                "http://localhost:5000,http://127.0.0.1:5000",
            ).split(",")
            if o.strip()
        ]

    @staticmethod
    def _require(name: str) -> str:
        val = os.getenv(name)
        if not val:
            raise RuntimeError(
                f"{name} is not set. Copy api/.env.example to api/.env and fill it in."
            )
        return val


@lru_cache
def get_settings() -> Settings:
    return Settings()
