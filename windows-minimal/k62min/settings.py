"""Local, git-ignored settings (token, quick replies, preferences)."""
from __future__ import annotations

import json
import secrets
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL = ROOT / "local"
FILE = LOCAL / "settings.json"

DEFAULTS = {
    # User id used for the FitCloud login. If the FitCloudPro (iPhone) user id
    # is known, put it here so the watch accepts the session without re-binding.
    "token": "",
    "bind_approved": False,
    "paginate": True,
    "page_bytes": 60,  # visible characters per notification, measured on the K62
    "max_pages": 3,    # each page = one vibration; 3 pages ~ 170 characters
    "forward_apps": ["whatsapp", "telegram", "sms", "email", "instagram", "messenger"],
}


def load() -> dict:
    data = dict(DEFAULTS)
    if FILE.exists():
        data.update(json.loads(FILE.read_text(encoding="utf-8")))
    if not data["token"]:
        data["token"] = "k62min" + secrets.token_hex(6)
        save(data)
    return data


def save(data: dict) -> None:
    LOCAL.mkdir(exist_ok=True)
    FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
