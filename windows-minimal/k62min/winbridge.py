"""Windows-side sources/sinks for the bridge.

* Notifications: reads Windows toasts (incl. Phone Link, which mirrors iPhone
  notifications such as WhatsApp) via UserNotificationListener.
* Media: controls whatever is playing on Windows (GSMTC) when the watch sends
  play/pause/next/previous, and reports title/artist back to the watch.

Everything here only works while this notebook is on and connected to the K62.
"""
from __future__ import annotations

import asyncio
import ctypes
import logging
from dataclasses import dataclass
from typing import Awaitable, Callable

log = logging.getLogger("k62.win")

try:
    from winrt.windows.ui.notifications import KnownNotificationBindings, NotificationKinds
    from winrt.windows.ui.notifications.management import UserNotificationListener
except Exception:  # noqa: BLE001
    UserNotificationListener = None  # type: ignore[assignment]

try:
    from winrt.windows.media.control import (
        GlobalSystemMediaTransportControlsSessionManager as MediaManager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
    )
except Exception:  # noqa: BLE001
    MediaManager = None  # type: ignore[assignment]

APP_HINTS = [("whatsapp", "whatsapp"), ("telegram", "telegram"), ("instagram", "instagram"),
             ("messenger", "messenger"), ("outlook", "outlook"), ("gmail", "gmail"),
             ("mail", "email"), ("correo", "email"), ("mensajes", "sms"), ("messages", "sms"),
             ("imessage", "sms"), ("calendar", "calendar"), ("calendario", "calendar")]


@dataclass
class Toast:
    id: int
    app: str          # Windows app display name (e.g. "Enlace Móvil")
    kind: str         # FitCloud type key (whatsapp, sms, ...)
    title: str
    body: str


def classify(app: str, texts: list[str]) -> str:
    hay = " ".join([app, *texts]).lower()
    for needle, kind in APP_HINTS:
        if needle in hay:
            return kind
    return "sms"


class NotificationSource:
    def __init__(self, on_toast: Callable[[Toast], Awaitable[None]]) -> None:
        self._on_toast = on_toast
        self._seen: set[int] = set()
        self._task: asyncio.Task | None = None
        self.status = "inactivo"

    def access(self) -> str:
        if UserNotificationListener is None:
            return "no disponible"
        st = UserNotificationListener.current.get_access_status()
        return {0: "sin decidir", 1: "permitido", 2: "denegado"}.get(int(st), str(st))

    async def start(self) -> None:
        if self._task:
            return
        if self.access() != "permitido":
            listener = UserNotificationListener.current
            await listener.request_access_async()
        self._seen = {n.id for n in await self._fetch()}  # ignore backlog
        self._task = asyncio.create_task(self._loop())
        self.status = "activo"

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            self._task = None
        self.status = "inactivo"

    async def _fetch(self):
        return list(await UserNotificationListener.current.get_notifications_async(NotificationKinds.TOAST))

    async def _loop(self) -> None:
        while True:
            try:
                for n in await self._fetch():
                    if n.id in self._seen:
                        continue
                    self._seen.add(n.id)
                    t = _toast_from(n)
                    if t:
                        await self._on_toast(t)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                log.warning("lectura de notificaciones: %s", e)
            await asyncio.sleep(1.5)


def _toast_from(n) -> Toast | None:
    try:
        app = n.app_info.display_info.display_name
    except Exception:  # noqa: BLE001
        app = "?"
    binding = n.notification.visual.get_binding(KnownNotificationBindings.toast_generic)
    if binding is None:
        return None
    texts = [e.text for e in binding.get_text_elements() if e.text]
    if not texts:
        return None
    title, body = texts[0], "\n".join(texts[1:])
    return Toast(n.id, app, classify(app, texts), title, body)


MEDIA_KEYS = {"playpause": 0xB3, "next": 0xB0, "previous": 0xB1}


def _tap(vk: int) -> None:
    ctypes.windll.user32.keybd_event(vk, 0, 0, 0)
    ctypes.windll.user32.keybd_event(vk, 0, 2, 0)


class MediaBridge:
    """Executes watch music buttons on Windows and reports now-playing."""

    def __init__(self) -> None:
        self._mgr = None

    async def _session(self):
        if MediaManager is None:
            return None
        if self._mgr is None:
            self._mgr = await MediaManager.request_async()
        return self._mgr.get_current_session()

    async def action(self, what: str) -> bool:
        if what in ("volume_up", "volume_down"):
            _tap(0xAF if what == "volume_up" else 0xAE)
            return True
        s = await self._session()
        ok = False
        if s:
            if what == "playpause":
                ok = bool(await s.try_toggle_play_pause_async())
            elif what == "next":
                ok = bool(await s.try_skip_next_async())
            elif what == "previous":
                ok = bool(await s.try_skip_previous_async())
        if not ok and what in MEDIA_KEYS:
            # No controllable session: fall back to the global media keys
            # (also wakes up e.g. Spotify / browser players).
            _tap(MEDIA_KEYS[what])
            ok = True
        return ok

    async def now_playing(self) -> dict | None:
        s = await self._session()
        if not s:
            return None
        props = await s.try_get_media_properties_async()
        info = s.get_playback_info()
        tl = s.get_timeline_properties()
        return {
            "app": s.source_app_user_model_id,
            "title": props.title or "",
            "artist": props.artist or "",
            "playing": info.playback_status == PlaybackStatus.PLAYING,
            "duration": int(tl.end_time.total_seconds()) if tl else 0,
            "position": int(tl.position.total_seconds()) if tl else 0,
        }
