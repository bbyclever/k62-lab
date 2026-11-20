"""Genera fondos de esfera minimalistas (OLED, negro real) para el K62.

Se usan como «esfera personalizada» en FitCloudPro: el reloj dibuja la hora
encima, así que el centro queda libre.

    .venv\\Scripts\\python.exe tools\\make_faces.py
"""
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent.parent / "watchfaces"
SIZES = {  # nombre: (ancho, alto, redonda)
    "redonda-466": (466, 466, True),
    "redonda-454": (454, 454, True),
    "rect-410x502": (410, 502, False),
    "rect-240x284": (240, 284, False),
}
SS = 4  # supersampling
BLACK = (0, 0, 0)
DIM = (46, 46, 46)
MINT = (94, 224, 181)
AMBER = (240, 180, 90)


def canvas(w, h):
    img = Image.new("RGB", (w * SS, h * SS), BLACK)
    return img, ImageDraw.Draw(img)


def frame_box(w, h, round_, inset):
    i = inset * SS
    return (i, i, w * SS - i, h * SS - i)


def finish(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


# ------------------------------------------------------------------ diseños

def noche(w, h, round_):
    """Negro absoluto: la pantalla solo muestra la hora."""
    img, _ = canvas(w, h)
    return finish(img, w, h)


def orbita(w, h, round_):
    """Un anillo finísimo y un punto de acento a las 12."""
    img, d = canvas(w, h)
    m = min(w, h)
    inset, lw = m * 0.06, max(2, int(m * 0.006)) * SS
    box = frame_box(w, h, round_, inset)
    if round_:
        d.ellipse(box, outline=DIM, width=lw)
    else:
        d.rounded_rectangle(box, radius=int(m * 0.16 * SS), outline=DIM, width=lw)
    r = m * 0.018 * SS
    cx, cy = w * SS / 2, box[1]
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=MINT)
    return finish(img, w, h)


def indices(w, h, round_):
    """12 índices mínimos; el de las 12 en acento."""
    img, d = canvas(w, h)
    m = min(w, h)
    cx, cy = w * SS / 2, h * SS / 2
    for k in range(12):
        a = math.radians(k * 30 - 90)
        if round_:
            rad = (m / 2 - m * 0.075) * SS
            x, y = cx + rad * math.cos(a), cy + rad * math.sin(a)
        else:  # proyectar sobre un rectángulo redondeado
            hx, hy = (w / 2 - m * 0.075) * SS, (h / 2 - m * 0.075) * SS
            t = min(hx / abs(math.cos(a)) if math.cos(a) else 1e9,
                    hy / abs(math.sin(a)) if math.sin(a) else 1e9)
            x, y = cx + t * math.cos(a), cy + t * math.sin(a)
        r = (m * (0.016 if k == 0 else 0.008)) * SS
        d.ellipse((x - r, y - r, x + r, y + r), fill=MINT if k == 0 else (90, 90, 90))
    return finish(img, w, h)


def horizonte(w, h, round_):
    """Una línea de horizonte que se desvanece hacia los bordes."""
    img, d = canvas(w, h)
    y = int(h * 0.66 * SS)
    lw = max(2, int(min(w, h) * 0.005)) * SS
    W = w * SS
    for x in range(0, W, SS):
        f = 1 - abs(x - W / 2) / (W / 2)
        f = max(0.0, f) ** 1.6
        c = tuple(int(v * f) for v in MINT)
        d.rectangle((x, y, x + SS, y + lw), fill=c)
    return finish(img, w, h)


def eclipse(w, h, round_):
    """Resplandor tenue bajo el horizonte: profundidad sin elementos."""
    small = Image.new("RGB", (w, h), BLACK)
    glow = Image.new("RGB", (w, h), BLACK)
    g = ImageDraw.Draw(glow)
    r = min(w, h) * 0.55
    cx, cy = w / 2, h * 1.05
    g.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(18, 70, 56))
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.12))
    small.paste(glow)
    d = ImageDraw.Draw(small)
    d.ellipse((cx - r * 0.92, cy - r * 0.92, cx + r * 0.92, cy + r * 0.92), fill=BLACK)
    return small.filter(ImageFilter.GaussianBlur(1))


def ambar(w, h, round_):
    """Versión cálida de 'orbita' para uso nocturno."""
    img, d = canvas(w, h)
    m = min(w, h)
    lw = max(2, int(m * 0.005)) * SS
    box = frame_box(w, h, round_, m * 0.06)
    start, end = 200, 340  # arco superior
    if round_:
        d.arc(box, start, end, fill=(70, 50, 25), width=lw)
    else:
        d.rounded_rectangle(box, radius=int(m * 0.16 * SS), outline=(45, 32, 16), width=lw)
    r = m * 0.016 * SS
    d.ellipse((w * SS / 2 - r, box[1] - r, w * SS / 2 + r, box[1] + r), fill=AMBER)
    return finish(img, w, h)


DESIGNS = {"1-noche": noche, "2-orbita": orbita, "3-indices": indices,
           "4-horizonte": horizonte, "5-eclipse": eclipse, "6-ambar": ambar}


def mask_round(img):
    w, h = img.size
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).ellipse((0, 0, w - 1, h - 1), fill=255)
    out = Image.new("RGB", (w, h), BLACK)
    out.paste(img, mask=m)
    return out


def preview(faces: dict[str, dict[str, Image.Image]]) -> Image.Image:
    """Hoja de contacto: fila redonda 466 y fila rectangular 410x502 con hora simulada."""
    rows = [("redonda-466", True), ("rect-410x502", False)]
    cell_w, cell_h, pad = 250, 310, 24
    sheet = Image.new("RGB", (pad + len(DESIGNS) * (cell_w + pad), pad + len(rows) * (cell_h + pad) + 10),
                      (24, 26, 30))
    d = ImageDraw.Draw(sheet)
    try:
        big = ImageFont.truetype("segoeuil.ttf", 54)
        small = ImageFont.truetype("segoeui.ttf", 15)
    except OSError:
        big = small = ImageFont.load_default()
    for ri, (size, rnd) in enumerate(rows):
        for ci, name in enumerate(DESIGNS):
            face = faces[size][name]
            face = mask_round(face) if rnd else face
            th = face.copy()
            th.thumbnail((cell_w - 20, cell_h - 50))
            td = ImageDraw.Draw(th)
            tw, tt = th.size
            col = (255, 214, 160) if "ambar" in name else (235, 238, 240)
            td.text((tw / 2, tt * 0.46), "10:42", font=big, fill=col, anchor="mm")
            x = pad + ci * (cell_w + pad) + (cell_w - tw) // 2
            y = pad + ri * (cell_h + pad)
            m = Image.new("L", th.size, 0)
            md = ImageDraw.Draw(m)
            if rnd:
                md.ellipse((0, 0, tw - 1, tt - 1), fill=255)
            else:
                md.rounded_rectangle((0, 0, tw - 1, tt - 1), radius=int(tw * 0.18), fill=255)
            sheet.paste(th, (x, y), mask=m)
            d.text((pad + ci * (cell_w + pad) + cell_w / 2, y + cell_h - 22), name[2:],
                   font=small, fill=(160, 168, 178), anchor="mm")
    return sheet


def main() -> None:
    faces: dict[str, dict[str, Image.Image]] = {}
    for size, (w, h, rnd) in SIZES.items():
        (OUT / size).mkdir(parents=True, exist_ok=True)
        faces[size] = {}
        for name, fn in DESIGNS.items():
            img = fn(w, h, rnd)
            img.save(OUT / size / f"{name}.png", optimize=True)
            faces[size][name] = img
    preview(faces).save(OUT / "preview.png")
    print(f"Esferas en {OUT}")


if __name__ == "__main__":
    main()
