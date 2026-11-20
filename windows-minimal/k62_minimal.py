"""K62 Minimal Control — arranque.

    .venv\\Scripts\\python.exe k62_minimal.py          # abre http://127.0.0.1:8762
"""
from __future__ import annotations

import argparse
import logging
import webbrowser

from aiohttp import web

from k62min.server import build

PORT = 8762


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO if a.v else logging.WARNING,
                        format="%(asctime)s %(name)s %(message)s")
    if not a.no_browser:
        webbrowser.open(f"http://127.0.0.1:{PORT}")
    web.run_app(build(), host="127.0.0.1", port=PORT, print=lambda *_: print(
        f"K62 Minimal Control en http://127.0.0.1:{PORT}  (Ctrl+C para salir)"))


if __name__ == "__main__":
    main()
