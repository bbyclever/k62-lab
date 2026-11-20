"""K62 Minimal Control — local server (http://127.0.0.1:8762)."""
from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import deque
from pathlib import Path

from aiohttp import web

from . import protocol as P
from . import settings
from .link import K62Link
from .winbridge import MediaBridge, NotificationSource, Toast

STATIC = Path(__file__).resolve().parent / "static"
log = logging.getLogger("k62.server")


class App:
    def __init__(self) -> None:
        self.cfg = settings.load()
        self.events: deque[dict] = deque(maxlen=200)
        self.clients: set[asyncio.Queue] = set()
        self.link = K62Link(on_event=self.on_link_event)
        self.link.page_bytes = int(self.cfg.get("page_bytes", 60))
        self.link.max_pages = int(self.cfg.get("max_pages", 3))
        if self.cfg.get("pages_original"):
            self.link.page_backup = bytes.fromhex(self.cfg["pages_original"])
        self.media = MediaBridge()
        self.notifs = NotificationSource(self.on_toast)
        self.forward = False
        self.music_bridge = False
        self.forwarded: deque[dict] = deque(maxlen=20)
        self.replies: deque[dict] = deque(maxlen=20)
        self.last_track: tuple | None = None
        self._music_task: asyncio.Task | None = None

    # ------------------------------------------------------------ events
    def push(self, kind: str, data: dict) -> None:
        ev = {"kind": kind, **data}
        ev.setdefault("t", time.strftime("%H:%M:%S"))
        self.events.append(ev)
        for q in list(self.clients):
            q.put_nowait(ev)

    async def on_link_event(self, kind: str, data: dict) -> None:
        self.push(kind, dict(data))
        if kind == "config" and self.link.page_backup and not self.cfg.get("pages_original"):
            # Persist the watch's original page layout so "Restaurar" survives restarts.
            self.cfg["pages_original"] = self.link.page_backup.hex()
            settings.save(self.cfg)
        if kind == "musica" and self.music_bridge:
            ok = await self.media.action(data["accion"])
            self.push("musica_windows", {"accion": data["accion"], "ok": ok})
        elif kind == "respuesta_rapida":
            self.replies.appendleft(dict(data))
        elif kind == "musica_refrescar" and self.music_bridge:
            self.last_track = None

    async def on_toast(self, t: Toast) -> None:
        item = {"t": time.strftime("%H:%M:%S"), "app": t.app, "tipo": t.kind,
                "titulo": t.title, "texto": t.body, "enviado": False, "paginas": 0}
        if self.forward and t.kind in self.cfg["forward_apps"] and self.link.in_session:
            try:
                item["paginas"] = await self.link.notify(t.kind, t.title, t.body or t.title,
                                                         paginate=self.cfg["paginate"])
                item["enviado"] = True
            except Exception as e:  # noqa: BLE001
                item["error"] = str(e)
        self.forwarded.appendleft(item)
        self.push("toast", {"app": t.app, "tipo": t.kind, "enviado": item["enviado"]})

    async def music_loop(self) -> None:
        while True:
            try:
                if self.music_bridge and self.link.in_session:
                    np = await self.media.now_playing()
                    if np:
                        key = (np["title"], np["artist"], np["playing"])
                        if key != self.last_track:
                            self.last_track = key
                            await self.link.music(np["title"], np["artist"], np["playing"],
                                                  np["duration"], np["position"])
                            self.push("musica_info", {"titulo": np["title"], "reproduciendo": np["playing"]})
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                log.warning("music loop: %s", e)
            await asyncio.sleep(3)

    # ------------------------------------------------------------ state
    async def snapshot(self) -> dict:
        s = self.link.state
        np = None
        try:
            np = await self.media.now_playing()
        except Exception:  # noqa: BLE001
            pass
        return {
            "watch": {"stage": s.stage, "rssi": s.rssi, "auth": s.auth, "battery": s.battery,
                      "charging": s.charging, "firmware": s.firmware, "features": s.features,
                      "pages": s.pages, "error": s.error, "session": self.link.in_session,
                      "page_backup": self.link.page_backup is not None,
                      "long_notifications": self.link.long_notifications if s.features else None},
            "bridge": {"forward": self.forward, "music": self.music_bridge,
                       "notif_access": self.notifs.access(), "listener": self.notifs.status,
                       "paginate": self.cfg["paginate"], "max_pages": self.link.max_pages,
                       "forward_apps": self.cfg["forward_apps"]},
            "now_playing": np,
            "forwarded": list(self.forwarded),
            "replies": list(self.replies),
            "events": list(self.events)[-60:],
            "token_hint": self.cfg["token"][:4] + "…",
        }


def build() -> web.Application:
    a = App()
    app = web.Application()
    r = web.RouteTableDef()

    async def guarded(fn):
        try:
            res = await fn()
            return web.json_response({"ok": True, **(res or {})})
        except Exception as e:  # noqa: BLE001
            a.push("error", {"mensaje": f"{type(e).__name__}: {e}"})
            return web.json_response({"ok": False, "error": str(e)}, status=400)

    @r.get("/")
    async def index(_):
        return web.FileResponse(STATIC / "index.html")

    @r.get("/api/state")
    async def state(_):
        return web.json_response(await a.snapshot())

    @r.get("/api/events")
    async def sse(req):
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream",
                                           "Cache-Control": "no-cache"})
        await resp.prepare(req)
        q: asyncio.Queue = asyncio.Queue()
        a.clients.add(q)
        try:
            while True:
                ev = await q.get()
                await resp.write(f"data: {json.dumps(ev, ensure_ascii=False)}\n\n".encode())
        except (asyncio.CancelledError, ConnectionResetError):
            pass
        finally:
            a.clients.discard(q)
        return resp

    @r.post("/api/connect")
    async def connect(_):
        async def go():
            if await a.link.connect():
                return {"auth": await a.link.login(a.cfg["token"])}
            return {"auth": None}
        return await guarded(go)

    @r.post("/api/disconnect")
    async def disconnect(_):
        async def go():
            a.forward = a.music_bridge = False
            await a.notifs.stop()
            await a.link.disconnect()
        return await guarded(go)

    @r.post("/api/login")
    async def login(req):
        body = await req.json()
        async def go():
            token = (body.get("token") or "").strip()
            if not token:
                raise ValueError("ID vacío")
            res = await a.link.login(token)
            if res == "OK":
                a.cfg["token"] = token
                settings.save(a.cfg)
            return {"auth": res}
        return await guarded(go)

    @r.post("/api/bind")
    async def bind(req):
        body = await req.json()
        async def go():
            if body.get("confirm") != "VINCULAR":
                raise PermissionError("Escribe VINCULAR para confirmar")
            a.cfg["bind_approved"] = True
            settings.save(a.cfg)
            return {"auth": await a.link.bind(a.cfg["token"])}
        return await guarded(go)

    @r.post("/api/bridge")
    async def bridge(req):
        body = await req.json()
        async def go():
            if "forward" in body:
                a.forward = bool(body["forward"])
                if a.forward:
                    await a.notifs.start()
                else:
                    await a.notifs.stop()
            if "music" in body:
                a.music_bridge = bool(body["music"])
                a.last_track = None
            if "paginate" in body:
                a.cfg["paginate"] = bool(body["paginate"])
                settings.save(a.cfg)
            if "max_pages" in body:
                a.cfg["max_pages"] = a.link.max_pages = max(1, min(int(body["max_pages"]), 12))
                settings.save(a.cfg)
            if "forward_apps" in body:
                a.cfg["forward_apps"] = [x for x in body["forward_apps"] if x in P.NOTIF_TYPES]
                settings.save(a.cfg)
        return await guarded(go)

    @r.post("/api/test/notification")
    async def test_notif(req):
        body = await req.json()
        async def go():
            n = await a.link.notify(body.get("app", "whatsapp"), body.get("sender", "K62 Minimal"),
                                    body.get("text", ""),
                                    paginate=body.get("paginate", a.cfg["paginate"]))
            return {"paginas": n}
        return await guarded(go)

    @r.post("/api/test/call")
    async def test_call(req):
        body = await req.json()
        return await guarded(lambda: a.link.call_state(body.get("state", "entrante"),
                                                       body.get("name", "Prueba"),
                                                       body.get("number", "")))

    @r.post("/api/media/{action}")
    async def media(req):
        action = req.match_info["action"]
        async def go():
            return {"done": await a.media.action(action)}
        return await guarded(go)

    @r.post("/api/pages")
    async def pages(req):
        body = await req.json()
        async def go():
            await a.link.set_pages({int(k): bool(v) for k, v in body.get("pages", {}).items()})
        return await guarded(go)

    @r.post("/api/pages/restore")
    async def pages_restore(_):
        return await guarded(a.link.restore_pages)

    @r.post("/api/find")
    async def find(_):
        return await guarded(a.link.find_watch)

    @r.post("/api/refresh")
    async def refresh(_):
        return await guarded(a.link.refresh)

    async def on_start(_app):
        a._music_task = asyncio.create_task(a.music_loop())

    async def on_stop(_app):
        if a._music_task:
            a._music_task.cancel()
        await a.notifs.stop()
        await a.link.disconnect()

    app.add_routes(r)
    app.on_startup.append(on_start)
    app.on_cleanup.append(on_stop)
    app["state"] = a
    return app
