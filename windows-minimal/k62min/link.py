"""BLE link to the K62 from Windows (Bleak / WinRT backend)."""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

from . import protocol as P

log = logging.getLogger("k62.link")
EventCb = Callable[[str, dict[str, Any]], Awaitable[None] | None]


@dataclass
class WatchState:
    stage: str = "desconectado"  # desconectado|buscando|anunciado|conectado|sesion|error
    rssi: int | None = None
    auth: str | None = None
    battery: int | None = None
    charging: bool | None = None
    firmware: str | None = None
    features: dict[str, bool] = field(default_factory=dict)
    pages: dict[str, bool] = field(default_factory=dict)
    config_types: list[int] = field(default_factory=list)
    error: str | None = None
    mtu: int | None = None


class K62Link:
    def __init__(self, on_event: EventCb | None = None) -> None:
        self.state = WatchState()
        self._on_event = on_event
        self._device: BLEDevice | None = None
        self._client: BleakClient | None = None
        self._write_char = None
        self._write_response = True
        self._seq = 0
        self._rx = P.Reassembler()
        self._waiters: dict[tuple[int, int], asyncio.Future] = {}
        self._lock = asyncio.Lock()
        self.config: dict[int, bytes] = {}
        self.page_backup: bytes | None = None
        self.page_bytes: int = P.K62_VISIBLE_BYTES
        self.max_pages: int = 3
        self.force_legacy_notifications = True
        self._last_rx_seq: int | None = None
        self._last_rx_t = 0.0
        self._last_media: tuple[int, float] = (-1, 0.0)

    # ------------------------------------------------------------ events
    async def _emit(self, kind: str, **data: Any) -> None:
        data.setdefault("t", time.strftime("%H:%M:%S"))
        log.info("%s %s", kind, data)
        if self._on_event:
            r = self._on_event(kind, data)
            if asyncio.iscoroutine(r):
                await r

    @property
    def connected(self) -> bool:
        return bool(self._client and self._client.is_connected)

    @property
    def in_session(self) -> bool:
        return self.connected and self.state.auth == "OK"

    # ------------------------------------------------------------ connect
    async def find(self, timeout: float = 10.0) -> BLEDevice | None:
        self.state.stage = "buscando"
        await self._emit("estado", stage="buscando")
        found = await BleakScanner.discover(timeout=timeout, return_adv=True)
        best = None
        for dev, adv in found.values():
            name = adv.local_name or dev.name or ""
            if name.upper().startswith("K62") and (best is None or adv.rssi > best[1].rssi):
                best = (dev, adv)
        if not best:
            self.state.stage = "desconectado"
            self.state.error = "K62 no encontrado en el escaneo BLE"
            await self._emit("estado", stage="desconectado", error=self.state.error)
            return None
        self._device, self.state.rssi = best[0], best[1].rssi
        self.state.stage = "anunciado"
        await self._emit("estado", stage="anunciado", rssi=self.state.rssi)
        return self._device

    async def connect(self) -> bool:
        if self.connected:
            return True
        # Always rescan: a BLEDevice from an older scan can go stale on WinRT
        # and make connect() time out.
        self._device = None
        if not await self.find():
            return False
        stage = "connect"
        try:
            self._client = BleakClient(self._device, disconnected_callback=self._on_disconnect,
                                       timeout=20.0)
            await self._client.connect()
            stage = "discover"
            svc = self._client.services.get_service(P.SERVICE)
            if svc is None:
                raise RuntimeError("servicio 01FF(D293) no expuesto")
            wc = svc.get_characteristic(P.CHAR_WRITE)
            nc = svc.get_characteristic(P.CHAR_NOTIFY)
            if not wc or not nc:
                raise RuntimeError("FF02/FF03 no encontrados en 01FF(D293)")
            self._write_char = wc
            self._write_response = "write" in wc.properties
            self.state.mtu = self._client.mtu_size
            stage = "notify"
            await self._client.start_notify(nc, self._on_notify)
            self.state.stage, self.state.error = "conectado", None
            await self._emit("estado", stage="conectado", mtu=self.state.mtu,
                             write_props=wc.properties, notify_props=nc.properties)
            return True
        except Exception as e:  # noqa: BLE001
            self.state.stage = "error"
            self.state.error = f"{stage}: {type(e).__name__}: {e}"
            await self._emit("estado", stage="error", error=self.state.error)
            await self.disconnect()
            return False

    async def disconnect(self) -> None:
        c, self._client = self._client, None
        if c:
            try:
                await c.disconnect()
            except Exception:  # noqa: BLE001
                pass
        self.state.stage, self.state.auth = "desconectado", None

    def _on_disconnect(self, _client: BleakClient) -> None:
        self.state.stage, self.state.auth = "desconectado", None
        for f in self._waiters.values():
            if not f.done():
                f.set_exception(ConnectionError("desconectado"))
        asyncio.get_event_loop().create_task(self._emit("estado", stage="desconectado"))

    # ------------------------------------------------------------ transport
    async def _write(self, frame: bytes) -> None:
        if not self.connected:
            raise ConnectionError("K62 no conectado")
        chunk = max(20, (self._client.mtu_size or 23) - 3)
        for i in range(0, len(frame), chunk):
            await self._client.write_gatt_char(self._write_char, frame[i:i + chunk],
                                               response=self._write_response)

    async def _send(self, cmd: int, key: int, data: bytes | None = None) -> None:
        async with self._lock:
            frame = P.encode(cmd, key, data, self._seq)
            self._seq = (self._seq + 1) & 0xFFFF
            await self._write(frame)

    async def _request(self, cmd: int, key: int, data: bytes | None, resp_key: int,
                       timeout: float = 8.0) -> bytes:
        fut = asyncio.get_running_loop().create_future()
        self._waiters[(cmd, resp_key)] = fut
        try:
            await self._send(cmd, key, data)
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._waiters.pop((cmd, resp_key), None)

    def _on_notify(self, _sender: Any, data: bytearray) -> None:
        packets, seq, err, note = self._rx.feed(bytes(data))
        loop = asyncio.get_event_loop()
        if note and note not in ("ack",):
            loop.create_task(self._emit("rx_nota", nota=note))
        if seq is not None:
            loop.create_task(self._ack(seq, err))
        # The watch retransmits a frame (same seq) when our ACK is late; dispatch
        # it only once, otherwise play/pause toggles twice and cancels itself.
        now = time.monotonic()
        if seq is not None and not err and seq == self._last_rx_seq and now - self._last_rx_t < 3:
            return
        if seq is not None and not err:
            self._last_rx_seq, self._last_rx_t = seq, now
        for p in packets:
            loop.create_task(self._dispatch(p))

    async def _ack(self, seq: int, err: bool) -> None:
        try:
            async with self._lock:
                await self._write(P.encode_ack(seq, err))
        except Exception as e:  # noqa: BLE001
            log.warning("ack falló: %s", e)

    async def _dispatch(self, p: P.Packet) -> None:
        fut = self._waiters.get((p.cmd, p.key))
        if fut and not fut.done():
            fut.set_result(p.data)
        c, k, d = p.cmd, p.key, p.data
        if c == P.CMD_SETTINGS and k == P.KEY_BATTERY_RESPONSE and len(d) >= 3:
            self.state.charging, self.state.battery = d[0] == 1, d[2]
            await self._emit("bateria", nivel=d[2], cargando=d[0] == 1)
        elif c == P.CMD_SETTINGS and k == P.KEY_CONFIG_RESPONSE:
            self._apply_config(d)
            await self._emit("config", tipos=self.state.config_types)
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_BATTERY_CHANGED:
            await self.request_battery(wait=False)
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_CONFIG_CHANGED:
            await self._send(P.CMD_SETTINGS, P.KEY_CONFIG_REQUEST)
        elif c == P.CMD_SETTINGS and k in (P.KEY_PUSH_QUICK_REPLY_SMS, P.KEY_PUSH_QUICK_REPLY_FREE):
            await self._emit("respuesta_rapida", **_parse_quick_reply(k, d))
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_FIND_PHONE:
            await self._emit("buscar_telefono", activo=True)
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_STOP_FIND_PHONE:
            await self._emit("buscar_telefono", activo=False)
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_MUSIC_REFRESH:
            await self._emit("musica_refrescar")
        elif c == P.CMD_CAMERA_MEDIA and k == P.KEY_PUSH_MEDIA_CONTROL and d:
            # Play/pause arrives as two frames ~0.2-0.6 s apart (different seq):
            # collapse repeats of the same play/pause subtype family.
            action = P.MEDIA_EVENTS.get(d[0], f"?{d[0]}")
            last_a, last_t = self._last_media
            now = time.monotonic()
            self._last_media = (d[0], now)
            if action == "playpause" and P.MEDIA_EVENTS.get(last_a) == "playpause" and now - last_t < 1.0:
                return
            await self._emit("musica", accion=action, sub=d[0])
        elif c == P.CMD_NOTIFICATION and k == P.KEY_PUSH_CALL_ACCEPT:
            await self._emit("llamada", accion="contestar")
        elif c == P.CMD_NOTIFICATION and k == P.KEY_PUSH_CALL_HANG_UP:
            await self._emit("llamada", accion="rechazar")
        elif c == P.CMD_SETTINGS and k == P.KEY_PUSH_AUDIO_DEVICE_MAC:
            # Bluetooth Classic (calls/audio) side exists; never log the address.
            await self._emit("audio_clasico", disponible=True, mac="…" + d[-2:].hex(":"))
        elif c == P.CMD_AUTH:
            pass  # handled by waiters
        else:
            await self._emit("rx", cmd=c, key=k, hex=d.hex(" ")[:120])

    def _apply_config(self, blob: bytes) -> None:
        self.config.update(P.parse_config(blob))
        self.state.config_types = sorted(self.config)
        info = self.config.get(P.CFG_DEVICE_INFO)
        if info and len(info) >= 38:
            self.state.firmware = P.firmware_from_info(info)
            self.state.features = {n: P.feature_supported(info, f) for f, n in P.FEATURE_NAMES.items()}
        pages = self.config.get(P.CFG_PAGE)
        if pages:
            if self.page_backup is None:
                self.page_backup = bytes(pages)
            self.state.pages = {name: P.flag_get(pages, f) for f, name in P.PAGES.items()}

    # ------------------------------------------------------------ session
    async def login(self, token: str) -> str:
        """Application-layer login. Never binds by itself."""
        d = await self._request(P.CMD_AUTH, P.KEY_LOGIN_REQUEST, P.auth_payload(token),
                                P.KEY_LOGIN_RESPONSE)
        self.state.auth = P.AUTH_RESULTS.get(d[0], f"codigo {d[0]}") if d else "vacío"
        await self._emit("auth", resultado=self.state.auth, raw=d.hex(" "))
        if self.state.auth == "OK":
            self.state.stage = "sesion"
            await self.refresh()
        return self.state.auth

    async def bind(self, token: str) -> str:
        """Bind a new user id. MAY UNLINK FitCloudPro on the iPhone: caller must
        have explicit owner approval. Requires confirmation on the watch."""
        d = await self._request(P.CMD_AUTH, P.KEY_BIND_REQUEST, P.auth_payload(token),
                                P.KEY_BIND_RESPONSE, timeout=60.0)
        self.state.auth = P.AUTH_RESULTS.get(d[0], f"codigo {d[0]}") if d else "vacío"
        await self._emit("auth", resultado=self.state.auth, via="bind")
        if self.state.auth == "OK":
            self.state.stage = "sesion"
            await self.refresh()
        return self.state.auth

    async def refresh(self) -> None:
        await self._send(P.CMD_SETTINGS, P.KEY_CONFIG_REQUEST)
        await self.request_battery(wait=False)

    async def request_battery(self, wait: bool = True) -> int | None:
        if wait:
            await self._request(P.CMD_SETTINGS, P.KEY_BATTERY_REQUEST, None, P.KEY_BATTERY_RESPONSE)
        else:
            await self._send(P.CMD_SETTINGS, P.KEY_BATTERY_REQUEST)
        return self.state.battery

    # ------------------------------------------------------------ features
    def _need_session(self) -> None:
        if not self.in_session:
            raise PermissionError("Sin sesión FitCloud (login OK) con el reloj")

    @property
    def long_notifications(self) -> bool:
        # Verified on the K62 (19-11-2026): the device-info blob advertises the
        # long format (feature 267) but the firmware parses the legacy layout
        # (20-byte name + len + text). Long format showed text shifted by 16 bytes.
        if self.force_legacy_notifications:
            return False
        return P.feature_supported(self.config.get(P.CFG_DEVICE_INFO), P.FEATURE_LONG_NOTIFICATION)

    async def notify(self, app: str, sender: str, text: str, paginate: bool = True) -> int:
        self._need_session()
        typ = P.NOTIF_TYPES.get(app, P.NOTIF_TYPES["sms"])
        pages = (P.paginate(sender, text, self.long_notifications, self.page_bytes, self.max_pages)
                 if paginate else [text])
        # Newest notification is listed first on the watch: send the last page
        # first so that "1/n" ends up on top.
        for i, page in enumerate(reversed(pages)):
            await self._send(P.CMD_NOTIFICATION, typ,
                             P.notification_payload(sender, page, self.long_notifications))
            if i + 1 < len(pages):
                await asyncio.sleep(1.2)
        await self._emit("notificacion_enviada", app=app, paginas=len(pages))
        return len(pages)

    async def call_state(self, state: str, name: str, number: str = "") -> None:
        self._need_session()
        key = {"entrante": P.NOTIF_CALL_INCOMING, "contestada": P.NOTIF_CALL_ANSWERED,
               "rechazada": P.NOTIF_CALL_REJECTED, "terminada": P.NOTIF_CALL_ANSWERED}[state]
        await self._send(P.CMD_NOTIFICATION, key, P.notification_payload(name, number, self.long_notifications))

    async def music(self, title: str, artist: str, playing: bool, duration_s: int = 0,
                    position_s: int = 0) -> None:
        self._need_session()
        await self._send(P.CMD_SETTINGS, P.KEY_SET_MUSIC_INFO, P.music_info_payload(title, artist, duration_s))
        await self._send(P.CMD_SETTINGS, P.KEY_SET_MUSIC_STATE,
                         P.music_state_payload("playing" if playing else "paused", position_s))

    async def find_watch(self) -> None:
        self._need_session()
        await self._send(P.CMD_SETTINGS, P.KEY_FIND_DEVICE)

    async def set_pages(self, enabled: dict[int, bool]) -> None:
        """Reversible: original PageConfig is kept in page_backup."""
        self._need_session()
        cur = self.config.get(P.CFG_PAGE)
        if not cur:
            raise RuntimeError("El reloj no informó PageConfig (item 23); no se modifica")
        b = bytearray(cur)
        P.flag_set(b, 0, True)  # time page always on
        for flag, on in enabled.items():
            if flag in P.PAGES:
                P.flag_set(b, flag, on)
        await self._send(P.CMD_SETTINGS, P.config_write_key(P.CFG_PAGE), bytes(b))
        self._apply_config(bytes([P.CFG_PAGE, len(b)]) + bytes(b))
        await self._emit("paginas", estado=self.state.pages)

    async def restore_pages(self) -> None:
        self._need_session()
        if self.page_backup is None:
            raise RuntimeError("No hay copia de PageConfig")
        await self._send(P.CMD_SETTINGS, P.config_write_key(P.CFG_PAGE), self.page_backup)
        self._apply_config(bytes([P.CFG_PAGE, len(self.page_backup)]) + self.page_backup)
        await self._emit("paginas", estado=self.state.pages, restaurado=True)


def _parse_quick_reply(key: int, d: bytes) -> dict[str, Any]:
    if key == P.KEY_PUSH_QUICK_REPLY_SMS and d:
        n = min(d[0], len(d) - 1)
        return {"tipo": "rechazo_llamada_sms", "numero": None,
                "texto": d[1:1 + n].decode("utf-8", "replace")}
    if len(d) >= 2:
        nl = min(d[0], len(d) - 1)
        num = d[1:1 + nl].decode("utf-8", "replace")
        p = 1 + nl
        cl = min(d[p], len(d) - p - 1) if p < len(d) else 0
        return {"tipo": "libre", "numero": num, "texto": d[p + 1:p + 1 + cl].decode("utf-8", "replace")}
    return {"tipo": "desconocido", "hex": d.hex(" ")}
