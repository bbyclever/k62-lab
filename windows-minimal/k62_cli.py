"""K62 Minimal Control — CLI de verificación.

    .venv\\Scripts\\python.exe k62_cli.py probe      # conectar + login (nunca bind)
"""
from __future__ import annotations

import argparse
import asyncio
import logging

from k62min import settings
from k62min.link import K62Link


async def probe(listen: float, token: str | None) -> None:
    cfg = settings.load()
    if token:
        cfg["token"] = token

    def show(kind, data):
        print(f"[{data.pop('t', '')}] {kind}: {data}")

    link = K62Link(on_event=show)
    if not await link.connect():
        return
    try:
        res = await link.login(cfg["token"])
        print(f"\nLOGIN -> {res}")
        if res == "OK" and token:
            settings.save(cfg)
        if res == "OK":
            await asyncio.sleep(3)
            s = link.state
            print(f"batería={s.battery}% cargando={s.charging} firmware={s.firmware}")
            print(f"funciones={s.features}")
            print(f"páginas={s.pages}")
            print(f"items de config={s.config_types}")
        elif res == "NEED_BIND":
            print("El reloj exige 'bind' para este usuario. NO se ha enviado bind "
                  "(puede desvincular FitCloudPro del iPhone).")
        if listen:
            print(f"Escuchando eventos {listen:.0f}s… (usa música/llamadas/respuestas en el reloj)")
            await asyncio.sleep(listen)
    finally:
        await link.disconnect()


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--listen", type=float, default=0)
    p.add_argument("--token", help="ID de usuario FitCloudPro a probar")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.v else logging.WARNING)
    if a.cmd == "probe":
        asyncio.run(probe(a.listen, a.token))


if __name__ == "__main__":
    main()
