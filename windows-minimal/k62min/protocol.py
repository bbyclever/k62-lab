"""FitCloudPro / TopStep wire protocol (K62 uses the same GATT layout).

Source of the command set: Gadgetbridge's open implementation for the AK102
(FitCloudPro family), which uses exactly the same service/characteristics
observed on the K62:

    service 000001ff-3c17-d293-8e48-14fe2e4da212
    write   0000ff02-0000-1000-8000-00805f9b34fb
    notify  0000ff03-0000-1000-8000-00805f9b34fb

Transport frame (8-byte header):
    [0xAB][flags][len_hi][len_lo][crc_hi][crc_lo][seq_hi][seq_lo] + payload
Payload:
    [cmdId][version][keyId][len_hi][len_lo][data...]  (several key blocks allowed)

Only commands listed in this module may be sent. There is deliberately no
generic "send raw bytes" helper.
"""
from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass, field

SERVICE = "000001ff-3c17-d293-8e48-14fe2e4da212"
CHAR_WRITE = "0000ff02-0000-1000-8000-00805f9b34fb"
CHAR_NOTIFY = "0000ff03-0000-1000-8000-00805f9b34fb"

MAGIC = 0xAB
HEADER_LEN = 8
FLAG_ACK = 0x10
FLAG_ACK_ERROR = 0x20
FLAG_ENCRYPTED = 0x40

# Command groups
CMD_SETTINGS = 2
CMD_AUTH = 3
CMD_NOTIFICATION = 4
CMD_CAMERA_MEDIA = 7
CMD_SPECIAL = 8

# Auth
KEY_BIND_REQUEST = 17
KEY_BIND_RESPONSE = 18
KEY_LOGIN_REQUEST = 19
KEY_LOGIN_RESPONSE = 20
AUTH_RESULTS = {0: "OK", 1: "NEED_BIND", 2: "BIND_CANCELLED", 3: "BIND_TIMEOUT", 5: "SHOULD_RESET"}

# Settings (phone -> watch)
KEY_SET_TIME = 1
KEY_BATTERY_REQUEST = 27
KEY_BATTERY_RESPONSE = 28
KEY_CONFIG_REQUEST = 32
KEY_CONFIG_RESPONSE = 33
KEY_FIND_DEVICE = 59
KEY_SDK_FUNCTION = 80
KEY_SET_MUSIC_STATE = 147
KEY_SET_MUSIC_INFO = 148
KEY_SET_VOLUME = 77  # CMD_SPECIAL

# Settings (watch -> phone pushes)
KEY_PUSH_FIND_PHONE = 60
KEY_PUSH_CONFIG_CHANGED = 81
KEY_PUSH_STOP_FIND_PHONE = 124
KEY_PUSH_AUDIO_DEVICE_MAC = 132
KEY_PUSH_MUSIC_REFRESH = 146
KEY_PUSH_QUICK_REPLY_SMS = 149
KEY_PUSH_BATTERY_CHANGED = 172
KEY_PUSH_QUICK_REPLY_FREE = 190
KEY_PUSH_TYPED_EVENT = 202

# Telephony (watch -> phone, CMD_NOTIFICATION)
KEY_PUSH_CALL_HANG_UP = 32
KEY_PUSH_CALL_ACCEPT = 70

# Camera / media (watch -> phone)
KEY_PUSH_MEDIA_CONTROL = 3
MEDIA_EVENTS = {0: "playpause", 1: "playpause", 2: "playpause", 3: "next", 4: "previous",
                5: "volume_up", 6: "volume_down"}

# Notification types (CMD_NOTIFICATION, keyId = type)
NOTIF_CALL_INCOMING = 1
NOTIF_CALL_ANSWERED = 2
NOTIF_CALL_REJECTED = 3
NOTIF_TYPES = {
    "sms": 4, "wechat": 6, "facebook": 7, "twitter": 8, "linkedin": 9, "instagram": 10,
    "whatsapp": 12, "line": 13, "messenger": 14, "skype": 16, "email": 17, "telegram": 18,
    "viber": 19, "calendar": 20, "snapchat": 21, "youtube": 34, "gmail": 38, "outlook": 39,
}

# Config TLV item types (KEY_CONFIG_RESPONSE)
CFG_DEVICE_INFO = 17
CFG_PAGE = 23
CFG_FUNCTION = 26
CFG_TURN_WRIST = 45
CFG_DND = 78
CFG_SCREEN_VIBRATE = 122

# PageConfig flag -> page name (flag 0 = time, always on)
PAGES = {1: "Pasos", 2: "Distancia", 3: "Calorías", 4: "Sueño", 5: "Ritmo cardiaco",
         6: "SpO2", 7: "Presión arterial", 8: "Clima", 9: "Buscar teléfono", 13: "Cronómetro"}

# Device feature bits (device-info blob)
FEATURE_LONG_NOTIFICATION = 267
FEATURE_CONTACTS = 271
FEATURE_POWER_SAVE = 302
FEATURE_STOP_FIND_DEVICE = 537
FEATURE_SYNC_VOLUME_INFO = 572
FEATURE_MUSIC_INFO = 597
NEGATED_FEATURES = {18, 23, 256, 294, 582, 592, 593, 597, 602, 604}
FEATURE_NAMES = {
    FEATURE_LONG_NOTIFICATION: "notificaciones largas",
    FEATURE_CONTACTS: "contactos",
    FEATURE_POWER_SAVE: "ahorro de energía",
    FEATURE_STOP_FIND_DEVICE: "detener 'buscar reloj'",
    FEATURE_SYNC_VOLUME_INFO: "volumen sincronizado",
    FEATURE_MUSIC_INFO: "título de música",
    4: "clima",
}


def crc16_arc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def encode(cmd: int, key: int, data: bytes | None, seq: int) -> bytes:
    data = data or b""
    payload = bytes([cmd, 0, key, (len(data) >> 8) & 0xFF, len(data) & 0xFF]) + data
    crc = crc16_arc(payload)
    header = bytes([MAGIC, 0, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF,
                    (crc >> 8) & 0xFF, crc & 0xFF, (seq >> 8) & 0xFF, seq & 0xFF])
    return header + payload


def encode_ack(seq: int, error: bool = False) -> bytes:
    return bytes([MAGIC, FLAG_ACK | (FLAG_ACK_ERROR if error else 0), 0, 0, 0, 0,
                  (seq >> 8) & 0xFF, seq & 0xFF])


@dataclass
class Packet:
    cmd: int
    key: int
    data: bytes


@dataclass
class Reassembler:
    """Rebuilds frames that arrive split across several FF03 notifications."""
    _buf: bytearray = field(default_factory=bytearray)
    _expect: int = 0
    _crc: int = 0
    _seq: int = 0
    _active: bool = False

    def feed(self, chunk: bytes) -> tuple[list[Packet], int | None, bool, str | None]:
        """Returns (packets, seq_to_ack, ack_is_error, note)."""
        if not self._active:
            if len(chunk) < HEADER_LEN or chunk[0] != MAGIC:
                return [], None, False, f"trama inesperada {chunk.hex(' ')}"
            flags = chunk[1]
            if flags & FLAG_ACK:
                return [], None, False, "ack" if not flags & FLAG_ACK_ERROR else "ack-error"
            if flags & FLAG_ENCRYPTED:
                return [], None, False, f"trama cifrada no soportada {chunk.hex(' ')}"
            self._expect = (chunk[2] << 8) | chunk[3]
            self._crc = (chunk[4] << 8) | chunk[5]
            self._seq = (chunk[6] << 8) | chunk[7]
            self._buf = bytearray(chunk[HEADER_LEN:])
        else:
            self._buf += chunk
        if len(self._buf) < self._expect:
            self._active = True
            return [], None, False, None
        payload = bytes(self._buf[: self._expect])
        seq, crc = self._seq, self._crc
        self._active, self._buf = False, bytearray()
        if crc16_arc(payload) != crc:
            return [], seq, True, f"CRC incorrecto {payload.hex(' ')}"
        return split_payload(payload), seq, False, None


def split_payload(payload: bytes) -> list[Packet]:
    if len(payload) < 5:
        return []
    cmd, off, out = payload[0], 2, []
    while off + 3 <= len(payload):
        key = payload[off]
        ln = (payload[off + 1] << 8) | payload[off + 2]
        off += 3
        if off + ln > len(payload):
            break
        out.append(Packet(cmd, key, payload[off: off + ln]))
        off += ln
    return out


# ---------------------------------------------------------------- payloads

def auth_payload(token: str) -> bytes:
    raw = token.encode("utf-8")[:28]
    return raw + bytes(32 - len(raw))


def time_payload(now: _dt.datetime | None = None) -> bytes:
    n = now or _dt.datetime.now()
    y, mo, d, h, mi, s = n.year - 2000, n.month, n.day, n.hour, n.minute, n.second
    return bytes([((y << 2) | (mo >> 2)) & 0xFF, ((mo << 6) | (d << 1) | (h >> 4)) & 0xFF,
                  ((h << 4) | (mi >> 2)) & 0xFF, ((mi << 6) | s) & 0xFF])


def notification_payload(name: str, content: str, long_supported: bool) -> bytes:
    nb, cb = name.encode("utf-8"), content.encode("utf-8")
    if long_supported:
        nb = _cut_utf8(nb, 64)
        cb = _cut_utf8(cb, 240 - len(nb))
        return bytes([len(nb)]) + nb + bytes([(len(cb) >> 8) & 0xFF, len(cb) & 0xFF]) + cb
    nb = _cut_utf8(nb, 20)
    cb = _cut_utf8(cb, 221)
    return nb + b" " * (20 - len(nb)) + bytes([(len(cb) >> 8) & 0xFF, len(cb) & 0xFF]) + cb


def content_capacity(name: str, long_supported: bool) -> int:
    if long_supported:
        return 240 - len(_cut_utf8(name.encode("utf-8"), 64))
    return 221


# Measured on the K62 (fw 9153.2370.104): the protocol accepts 240 bytes but
# the notification screen only shows ~60 characters ("01 02 … 20 2").
K62_VISIBLE_BYTES = 60
MAX_PAGES = 12


def paginate(name: str, text: str, long_supported: bool,
             page_bytes: int | None = None, max_pages: int = MAX_PAGES) -> list[str]:
    """Split a long text into watch-sized pages: '1/3 ...'.

    The K62 only displays ~60 bytes of each notification; sending several
    numbered notifications lets the full message be read on the watch.
    """
    limit = min(page_bytes or K62_VISIBLE_BYTES, content_capacity(name, long_supported))
    text = " ".join(text.split())  # newlines waste visible space
    if len(text.encode("utf-8")) <= limit:
        return [text]
    cap = limit - len("12/12 ".encode())
    words, pages, cur = text.split(" "), [], ""
    for w in words:
        cand = (cur + " " + w) if cur else w
        if len(cand.encode("utf-8")) <= cap:
            cur = cand
            continue
        if cur:
            pages.append(cur)
        while len(w.encode("utf-8")) > cap:  # very long token
            piece = _cut_utf8(w.encode("utf-8"), cap).decode("utf-8")
            pages.append(piece)
            w = w[len(piece):]
        cur = w
    if cur or not pages:
        pages.append(cur)
    if len(pages) == 1:
        return pages
    max_pages = max(1, min(max_pages, MAX_PAGES))
    if len(pages) > max_pages:
        pages = pages[:max_pages]
        pages[-1] = _cut_utf8(pages[-1].encode(), cap - 1).decode() + "…"
    return [f"{i}/{len(pages)} {p}" for i, p in enumerate(pages, 1)]


def music_info_payload(title: str, artist: str, duration_s: int = 0) -> bytes:
    t, a = _cut_utf8(title.encode(), 127), _cut_utf8(artist.encode(), 96)
    d = max(duration_s, 0)
    return bytes([len(t), len(a)]) + d.to_bytes(4, "big") + t + a


def music_state_payload(state: str, position_s: int = 0) -> bytes:
    st = {"playing": 1, "paused": 2}.get(state, 0)
    return bytes([st]) + max(position_s, 0).to_bytes(4, "big") + (100).to_bytes(2, "big")


def config_write_key(item_type: int) -> int:
    return item_type + 1 if item_type == CFG_SCREEN_VIBRATE else item_type - 2


def _cut_utf8(b: bytes, limit: int) -> bytes:
    if len(b) <= limit:
        return b
    b = b[:limit]
    while b and (b[-1] & 0xC0) == 0x80:  # drop trailing continuation bytes
        b = b[:-1]
    if b and b[-1] >= 0xC0:  # dangling lead byte
        b = b[:-1]
    return b


# ---------------------------------------------------------------- parsing

def parse_config(blob: bytes) -> dict[int, bytes]:
    items, off = {}, 0
    while off + 2 <= len(blob):
        t, ln = blob[off], blob[off + 1]
        off += 2
        if off + ln > len(blob):
            break
        items[t] = blob[off: off + ln]
        off += ln
    return items


def flag_get(b: bytes, flag: int) -> bool:
    i = (len(b) - 1) - flag // 8
    return 0 <= i < len(b) and bool(b[i] & (1 << (flag % 8)))


def flag_set(b: bytearray, flag: int, on: bool) -> None:
    i = (len(b) - 1) - flag // 8
    if 0 <= i < len(b):
        if on:
            b[i] |= 1 << (flag % 8)
        else:
            b[i] &= ~(1 << (flag % 8)) & 0xFF


def feature_supported(info: bytes | None, feature: int) -> bool:
    bit = False
    if info:
        if feature < 256:
            bit = feature <= 31 and _flag_desc(info, 9, feature)
        elif feature < 512:
            bit = (feature - 256) <= 47 and _flag_desc(info, 37, feature - 256)
        elif len(info) >= 40:
            idx, count = feature - 512, info[38]
            bi = idx // 8
            bit = bi < count and 39 + bi < len(info) and bool(info[39 + bi] & (1 << (idx % 8)))
    return (not bit) if feature in NEGATED_FEATURES else bit


def _flag_desc(data: bytes, offset: int, index: int) -> bool:
    bi = offset - index // 8
    return 0 <= bi < len(data) and bool(data[bi] & (1 << (index % 8)))


def firmware_from_info(info: bytes) -> str:
    if len(info) < 28:
        return "?"
    return f"{info[26]}.{info[27]:02d} ({info[4]:02X}{info[5]:02X})"
