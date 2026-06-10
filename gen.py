#!/usr/bin/env python3
"""Generate the 'astra' boot-splash theme + app assets (1280x800).

Outputs
  plymouth/themes/astra/       background.png, sat.png, marker.png,
                               astra.script, astra.plymouth
  plymouth/plymouthd.defaults  Theme=astra
  qml/images/                  splashbg.png (= background), sat.png
  qml/OrbitTrace.js            the SAME baked orbit table the script uses

Design: deep-space background with faint stars, a shaded planet, and a dim
cyan elliptical orbit; a glowing satellite dot with a fading tail sweeps the
orbit as the boot-progress indicator. A near-invisible 8x3 marker on the
bottom edge encodes the sweep position (x = head * (W-8)/(N-1)) so the app
can read the frozen frame back from KMS and continue the sweep seamlessly.
"""
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
TS = os.path.join(HERE, "plymouth", "themes", "astra")
QI = os.path.join(HERE, "qml", "images")
os.makedirs(TS, exist_ok=True)
os.makedirs(QI, exist_ok=True)

W, H = 1280, 800
N = 240                                   # baked orbit samples
BASE = (0x0a, 0x0e, 0x1a)                 # deep space navy
EDGE = (0x04, 0x06, 0x0e)
CYAN = (0x4d, 0xd0, 0xe1)                 # accent
CYAN_HI = (0xb2, 0xeb, 0xf2)
PLANET = (0x3a, 0x4a, 0x8a)               # indigo planet

OCX, OCY = 640.0, 390.0                   # orbit centre
ORX, ORY = 430.0, 150.0                   # orbit radii
TILT = math.radians(-8)                   # slight tilt
PCX, PCY, PR = 640, 395, 100              # planet


def font(size, bold=False):
    from PIL import ImageFont
    cands = [
        os.path.join(HERE, "qml", "fonts",
                     "Jost-Medium.ttf" if bold else "Jost-Regular.ttf"),
        "/usr/share/fonts/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
        "/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
    ]
    for p in cands:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def glow(layer, radius, gain=1.0):
    g = layer.filter(ImageFilter.GaussianBlur(radius))
    if gain != 1.0:
        a = np.asarray(g).astype(np.float32)
        a[:, :, 3] = np.clip(a[:, :, 3] * gain, 0, 255)
        g = Image.fromarray(a.astype(np.uint8), "RGBA")
    return g


def orbit_path():
    """Closed tilted ellipse, N points, starting right of the planet going up."""
    pts = []
    ct, st = math.cos(TILT), math.sin(TILT)
    for i in range(N):
        a = 2 * math.pi * i / N
        ex, ey = ORX * math.cos(a), ORY * math.sin(a)
        pts.append((OCX + ex * ct - ey * st, OCY + ex * st + ey * ct))
    return pts


def build_background(pts):
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.sqrt(((xx - W / 2) / (W * 0.72)) ** 2 + ((yy - H * 0.42) / (H * 0.80)) ** 2)
    t = np.clip(d, 0, 1) ** 1.4 * 0.65
    rgb = (np.array(BASE, np.float32) * (1 - t)[..., None]
           + np.array(EDGE, np.float32) * t[..., None])
    bg = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

    # stars (seeded -> reproducible), kept away from the text bands
    rng = random.Random(7)
    stars = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stars)
    for _ in range(140):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        if 540 < y < 680:
            continue
        r = rng.choice((0.6, 0.8, 1.0, 1.4))
        a = rng.randint(40, 140)
        sd.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, a))
    bg.alpha_composite(stars)

    # planet: shaded sphere with a soft terminator, light from upper-left
    pl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    py, px = np.mgrid[0:H, 0:W]
    rr = np.sqrt((px - PCX) ** 2 + (py - PCY) ** 2)
    inside = rr <= PR
    lx, ly = (px - (PCX - 55)), (py - (PCY - 70))
    shade = np.clip(1.15 - np.sqrt(lx ** 2 + ly ** 2) / (PR * 2.1), 0.18, 1.0)
    col = np.zeros((H, W, 4), np.float32)
    for c in range(3):
        col[:, :, c] = PLANET[c] * shade
    col[:, :, 3] = np.where(inside, 255, 0)
    edge_soft = np.clip((PR - rr) / 1.5, 0, 1)
    col[:, :, 3] = col[:, :, 3] * edge_soft
    bg.alpha_composite(Image.fromarray(col.astype(np.uint8), "RGBA"))

    # dim orbit line
    line = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(line).line(pts + [pts[0]], fill=CYAN + (60,), width=3, joint="curve")
    bg.alpha_composite(glow(line, 5, 1.1))
    bg.alpha_composite(line)

    dr = ImageDraw.Draw(bg)
    ttl = font(30, bold=True)
    s = "A S T R A   G R O U N D   C O N T R O L"
    dr.text((W / 2 - dr.textlength(s, font=ttl) / 2, 96), s, font=ttl,
            fill=(255, 255, 255, 170))
    f1 = font(32)
    s1 = "Establishing uplink…"
    dr.text((W / 2 - dr.textlength(s1, font=f1) / 2, H * 0.745), s1,
            font=f1, fill=(255, 255, 255, 195))
    f2 = font(26)
    s2 = "Do not power off."
    dr.text((W / 2 - dr.textlength(s2, font=f2) / 2, H * 0.835), s2,
            font=f2, fill=(255, 255, 255, 130))

    bg.convert("RGB").save(os.path.join(TS, "background.png"))
    bg.convert("RGB").save(os.path.join(QI, "splashbg.png"))


def build_map(pts):
    """Transparent planet+orbit layer for the dashboard's ORBIT TRACK card."""
    m = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    py, px = np.mgrid[0:H, 0:W]
    rr = np.sqrt((px - PCX) ** 2 + (py - PCY) ** 2)
    lx, ly = (px - (PCX - 55)), (py - (PCY - 70))
    shade = np.clip(1.15 - np.sqrt(lx ** 2 + ly ** 2) / (PR * 2.1), 0.18, 1.0)
    col = np.zeros((H, W, 4), np.float32)
    for c in range(3):
        col[:, :, c] = PLANET[c] * shade
    col[:, :, 3] = np.clip((PR - rr) / 1.5, 0, 1) * 255
    m.alpha_composite(Image.fromarray(col.astype(np.uint8), "RGBA"))
    line = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(line).line(pts + [pts[0]], fill=CYAN + (90,), width=4, joint="curve")
    m.alpha_composite(line)
    m.save(os.path.join(QI, "map.png"))


def build_sprites():
    C = 72
    sat = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(sat).ellipse([C/2-6, C/2-6, C/2+6, C/2+6], fill=CYAN_HI + (255,))
    sat = glow(sat, 4, 1.25)
    ImageDraw.Draw(sat).ellipse([C/2-3.5, C/2-3.5, C/2+3.5, C/2+3.5],
                                fill=(255, 255, 255, 255))
    sat.save(os.path.join(TS, "sat.png"))
    sat.save(os.path.join(QI, "sat.png"))

    # phase marker: x position on the bottom edge encodes the head index;
    # ~10 LSB above the bottom-row vignette — invisible, exact for read-back
    Image.new("RGBA", (8, 3), (0x12, 0x14, 0x1e, 255)).save(os.path.join(TS, "marker.png"))


def build_script(pts):
    L = [
        "# ASTRA boot splash — satellite sweeping an orbit (generated, 1280x800)",
        "# Plymouth 'script' plugin.",
        "screen.w = Window.GetWidth();",
        "screen.h = Window.GetHeight();",
        "",
        'bg = Sprite(Image("background.png"));',
        "bg.SetX(0); bg.SetY(0); bg.SetZ(-100);",
        "",
        'sat_img = Image("sat.png");',
        "sw = sat_img.GetWidth()/2;",
        f"N = {N};",
        "",
        "# near-invisible phase marker for the app's KMS read-back (see gen.py)",
        'marker = Sprite(Image("marker.png"));',
        "marker.SetZ(30);",
        "",
    ]
    for i, (x, y) in enumerate(pts):
        L.append(f"trace_x[{i}]={x:.1f}; trace_y[{i}]={y:.1f};")
    L += [
        "",
        "tail_n = 6;",
        "for (i = 0; i < tail_n; i++) {",
        "    dot[i] = Sprite(sat_img);",
        "    dot[i].SetZ(5);",
        "}",
        "",
        "accum = 0;",
        "fun refresh_cb() {",
        "    accum = accum + 1;",
        "    head = Math.Int(accum * 2.2) % N;",
        f"    marker.SetPosition(Math.Int(head * {W - 8} / (N - 1)), {H - 3}, 30);",
        "    for (i = 0; i < tail_n; i++) {",
        "        idx = head - i * 3;",
        "        if (idx < 0) { idx = idx + N; }",
        "        op = 1.0 - (i * 1.0) / tail_n;",
        "        dot[i].SetPosition(trace_x[idx] - sw, trace_y[idx] - sw, 5);",
        "        dot[i].SetOpacity(op * op);",
        "    }",
        "}",
        "Plymouth.SetRefreshFunction(refresh_cb);",
    ]
    with open(os.path.join(TS, "astra.script"), "w") as f:
        f.write("\n".join(L) + "\n")

    with open(os.path.join(TS, "astra.plymouth"), "w") as f:
        f.write("[Plymouth Theme]\n"
                "Name=ASTRA Ground Control\n"
                "Description=Satellite ground-control demo boot splash.\n"
                "ModuleName=script\n\n"
                "[script]\n"
                "ImageDir=/usr/share/plymouth/themes/astra\n"
                "ScriptFile=/usr/share/plymouth/themes/astra/astra.script\n")

    with open(os.path.join(HERE, "plymouth", "plymouthd.defaults"), "w") as f:
        f.write("[Daemon]\nTheme=astra\nShowDelay=0\nDeviceTimeout=15\n")

    # the same table for the QML splash, so both sides stay in sync
    xs = ",".join(f"{x:.1f}" for x, _ in pts)
    ys = ",".join(f"{y:.1f}" for _, y in pts)
    with open(os.path.join(HERE, "qml", "OrbitTrace.js"), "w") as f:
        f.write("// Generated by gen.py — the SAME baked orbit table the Plymouth\n"
                "// theme uses, so the app continues the sweep seamlessly.\n"
                ".pragma library\n"
                f"var n = {N};\n"
                f"var tx = [{xs}];\n"
                f"var ty = [{ys}];\n")


def main():
    pts = orbit_path()
    build_background(pts)
    build_map(pts)
    build_sprites()
    build_script(pts)
    print("generated:", os.path.relpath(TS, HERE), "and qml assets")


if __name__ == "__main__":
    main()
