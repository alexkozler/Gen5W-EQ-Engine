#!/usr/bin/env python3
"""EQ Engine's package icon (NEMESIS descriptor 1.2 `favicon`), in the app's own colours
(app/src/com/eqengine/app/Ui.java). Variants:
  faders  five mixer-style faders, each track filled in blue below its flat cap (no curve);
  plain   a small copy of the EQ page (EqPanel): thin tracks filled in blue from the 0 dB line to
          their knobs, white pill knobs with a dash, the thin amber response curve through them;
  live    plain with the live view's dark teal area behind, as on the EQ page.

NEMESIS Manager decodes a favicon down to about 96 px (Icons.EDGE), so it is written at 192 x 192
(one clean halving). Drawn 4x larger and scaled down, for smooth edges.
Usage: make_favicon.py <out.png> [faders|plain|live] [preview.png]
"""
import sys
from PIL import Image, ImageDraw

SIZE = 192
SS = 4                      # supersampling
W = SIZE * SS

SURFACE = (24, 29, 36)      # Ui.SURFACE
OUTLINE = (52, 61, 73)      # Ui.OUTLINE
TRACK = (43, 50, 61)        # Ui.SURFACE_TOP
GRID = (52, 61, 73)         # the 0 dB line
PRIMARY = (79, 195, 247)    # Ui.PRIMARY (a slider's fill)
LIVE = (19, 66, 89)         # the live view's area, as it looks on the dark surface
KNOB = (236, 239, 243)
DASH = (90, 98, 110)
CURVE = (255, 183, 77)      # Ui.SECONDARY (Ui.CURVE)

# the five bands' gains, -1..+1 of the track's half height: bass and treble up, a dip in the middle
GAINS = [0.80, 0.10, -0.55, 0.20, 0.85]
# the live view's level at each slider, -1..+1, a little below the curve
LIVE_AT = [0.30, 0.05, -0.35, 0.10, 0.20, 0.45, -0.10, 0.35, 0.05]


def catmull(points, steps=40):
    """A smooth curve through points (Catmull-Rom, ends repeated)."""
    pts = [points[0]] + points + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[k]) + (-p0[k] + p2[k]) * t
                                    + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                                    + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3) for k in range(2)))
    out.append(points[-1])
    return out


def stroke(d, path, width, fill):
    """A thick line stamped as round dots along the path (a wide polyline of many short segments
    leaves stripes in Pillow); round ends."""
    step = width / 8
    for (x0, y0), (x1, y1) in zip(path, path[1:]):
        n = max(1, int(((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 / step))
        for i in range(n + 1):
            x, y = x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n
            d.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=fill)


def draw(live):
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(W * 0.22)
    border = int(W * 0.016)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=radius, fill=OUTLINE)
    d.rounded_rectangle([border, border, W - 1 - border, W - 1 - border], radius=radius - border, fill=SURFACE)

    top, bottom = W * 0.20, W * 0.80
    mid, half = (top + bottom) / 2, (bottom - top) / 2
    left, right = W * 0.20, W * 0.80
    xs = [left + (right - left) * i / (len(GAINS) - 1) for i in range(len(GAINS))]
    # the curve as an EQ's response is: the sum of a smooth bump per band (the end bands as
    # shelves), so it has no corners; the knobs sit on it, as on the Easy page
    spacing = xs[1] - xs[0]

    def response(x):
        import math
        v = 0.0
        for i, (xi, g) in enumerate(zip(xs, GAINS)):
            u = (x - xi) / spacing
            if i == 0:
                v += g / (1 + math.exp(4.0 * u))            # low shelf
            elif i == len(xs) - 1:
                v += g / (1 + math.exp(-4.0 * u))           # high shelf
            else:
                v += g * math.exp(-1.6 * u * u)             # peak
        return v

    curve = [(x, mid - response(x) * half) for x in [W * 0.12 + W * 0.76 * k / 200 for k in range(201)]]
    knobs = [(x, mid - response(x) * half) for x in xs]

    if live:
        lx = [W * 0.12 + (W * 0.76) * i / (len(LIVE_AT) - 1) for i in range(len(LIVE_AT))]
        edge = catmull([(x, mid - v * half) for x, v in zip(lx, LIVE_AT)], steps=20)
        d.polygon(edge + [(lx[-1], bottom), (lx[0], bottom)], fill=LIVE)

    d.line([(W * 0.12, mid), (W * 0.88, mid)], fill=GRID, width=int(W * 0.008))

    track_w = W * 0.036
    for (x, y) in knobs:
        d.rounded_rectangle([x - track_w / 2, top, x + track_w / 2, bottom], radius=track_w / 2, fill=TRACK)
        y0, y1 = min(y, mid), max(y, mid)
        d.rectangle([x - track_w / 2, y0, x + track_w / 2, y1], fill=PRIMARY)

    # the curve, behind the knobs
    stroke(d, curve, W * 0.022, CURVE)

    kw, kh = W * 0.128, W * 0.054
    for (x, y) in knobs:
        d.rounded_rectangle([x - kw / 2, y - kh / 2, x + kw / 2, y + kh / 2], radius=kh / 2, fill=KNOB)
        d.line([(x - kw * 0.22, y), (x + kw * 0.22, y)], fill=DASH, width=int(W * 0.010))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


CAP = (230, 234, 240)       # Ui.ON_SURFACE (a fader cap)
# fader positions for "faders", 0 = top of the track, 1 = bottom
FADERS = [0.30, 0.52, 0.62, 0.45, 0.25]


def draw_faders():
    """Five mixer-style faders, no curve: each track filled in blue below its flat cap."""
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(W * 0.22)
    border = int(W * 0.016)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=radius, fill=OUTLINE)
    d.rounded_rectangle([border, border, W - 1 - border, W - 1 - border], radius=radius - border, fill=SURFACE)
    top, bottom = W * 0.19, W * 0.81
    left, right = W * 0.22, W * 0.78
    xs = [left + (right - left) * i / (len(FADERS) - 1) for i in range(len(FADERS))]
    track_w = W * 0.060
    cap_w, cap_h = W * 0.118, W * 0.052
    for x, f in zip(xs, FADERS):
        y = top + (bottom - top) * f
        d.rounded_rectangle([x - track_w / 2, top, x + track_w / 2, bottom], radius=track_w / 2, fill=TRACK)
        d.rounded_rectangle([x - track_w / 2, y, x + track_w / 2, bottom], radius=track_w / 2, fill=PRIMARY)
        d.rounded_rectangle([x - cap_w / 2, y - cap_h / 2, x + cap_w / 2, y + cap_h / 2],
                            radius=cap_h * 0.3, fill=CAP)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


VARIANTS = {"faders": draw_faders, "plain": lambda: draw(False), "live": lambda: draw(True)}


def preview(icons, path):
    """Each icon at 192, 96 and 72 px (about what a 48 dp list row shows at this unit's density),
    on Manager's dark background, one icon per row."""
    sizes = [192, 96, 72]
    pad = 24
    width = pad + sum(s + pad for s in sizes)
    rows = [(icon, (13, 16, 20)) for icon in icons]
    out = Image.new("RGB", (width, pad + len(rows) * (192 + pad)), (255, 255, 255))
    for r, (icon, bg) in enumerate(rows):
        y0 = pad + r * (192 + pad)
        ImageDraw.Draw(out).rectangle([0, y0 - pad // 2, width, y0 + 192 + pad // 2], fill=bg)
        x = pad
        for s in sizes:
            im = icon if s == SIZE else icon.resize((s, s), Image.LANCZOS)
            out.paste(im, (x, y0 + (192 - s) // 2), im)
            x += s + pad
    out.save(path)


if __name__ == "__main__":
    variant = sys.argv[2] if len(sys.argv) > 2 else "faders"
    VARIANTS[variant]().save(sys.argv[1], optimize=True)
    if len(sys.argv) > 3:
        preview([VARIANTS[v]() for v in ("faders", "plain", "live")], sys.argv[3])
