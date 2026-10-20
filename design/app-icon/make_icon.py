#!/usr/bin/env python3
"""Draws the app icon: the bird from base.svg, in a nest of twigs laid out
from SEED. Writes AppIcon.svg here and the 1024 px PNG into the app's asset
catalog. Needs rsvg-convert (brew install librsvg).

    python3 design/app-icon/make_icon.py
"""
import math, random, subprocess
from pathlib import Path

# The twigs' layout. Another seed gives another nest.
SEED = 11

HERE = Path(__file__).resolve().parent
OUTPUT_PNG = HERE.parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

random.seed(SEED)
CX, CY, RX, RY = 512, 595, 305, 50
BROWNS = ["#B07A4A", "#C68F59", "#9A6439", "#D9A46C", "#8A5631", "#BF8550"]

def lip(x):  # front edge of the rim
    x = min(max(x, CX - RX), CX + RX)
    t = max(0, 1 - ((x - CX) / RX) ** 2); return CY + RY * math.sqrt(t)
def back(x):
    x = min(max(x, CX - RX), CX + RX)
    t = max(0, 1 - ((x - CX) / RX) ** 2); return CY - RY * math.sqrt(t)
def bottom(x):
    x = min(max(x, CX - 300), CX + 300)
    t = max(0, 1 - ((x - CX) / 300) ** 2); return CY + 200 * math.sqrt(t)

def twig(x0, y0, x1, y1, w, color=None, bend=None):
    color = color or random.choice(BROWNS)
    bend = random.uniform(-10, 10) if bend is None else bend
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    dx, dy = x1 - x0, y1 - y0; L = math.hypot(dx, dy) or 1
    cx, cy = mx - dy / L * bend, my + dx / L * bend
    d = f"M{x0:.0f} {y0:.0f} Q{cx:.0f} {cy:.0f} {x1:.0f} {y1:.0f}"
    out = f'<path d="{d}" stroke="#6B4628" stroke-width="{w+4:.0f}"/><path d="{d}" stroke="{color}" stroke-width="{w:.0f}"/>'
    # a little forked sprig now and then
    if random.random() < 0.08:
        f = random.uniform(0.3, 0.7); fx, fy = x0 + dx * f, y0 + dy * f
        ang = math.atan2(dy, dx) + random.choice([-1, 1]) * random.uniform(0.5, 0.9)
        l = random.uniform(30, 55); ex, ey = fx + math.cos(ang) * l, fy + math.sin(ang) * l
        out += f'<path d="M{fx:.0f} {fy:.0f} L{ex:.0f} {ey:.0f}" stroke="#6B4628" stroke-width="{w+3:.0f}"/><path d="M{fx:.0f} {fy:.0f} L{ex:.0f} {ey:.0f}" stroke="{color}" stroke-width="{max(3,w-4):.0f}"/>'
    return out

def along(curve, x0, x1, jitter, w):
    a, b = random.uniform(x0, x1 - 120), 0
    b = min(x1, a + random.uniform(140, 260))
    return twig(a, curve(a) + random.uniform(-jitter, jitter), b, curve(b) + random.uniform(-jitter, jitter), w)

back_svg = []
for _ in range(12):
    back_svg.append(along(back, CX - RX - 40, CX + RX + 40, 12, random.uniform(9, 13)))
# stray twigs poking out at the sides
for side in (-1, 1):
    for k in range(0):
        x = CX + side * (RX - 20); y = CY + random.uniform(-30, 60)
        back_svg.append(twig(x, y, x + side * random.uniform(90, 150), y + random.uniform(-70, 40), random.uniform(8, 11)))

front_svg = []
# the body: twigs woven in bands that follow the bowl's curve
for band in range(7):
    f = (band + 0.5) / 7
    def curve(x, f=f): return lip(x) + f * (bottom(x) - lip(x))
    half = RX * math.sqrt(max(0.05, 1 - (0.75 * f) ** 2)) - 5
    reach_l = random.uniform(25, 55) if random.random() < 0.5 else 0
    reach_r = random.uniform(25, 55) if random.random() < 0.5 else 0
    x = CX - half - reach_l
    while x < CX + half:
        L = random.uniform(150, 230)
        x1 = min(CX + half + reach_r, x + L)
        tilt = random.choice([-1, 1]) * random.uniform(4, 14)
        front_svg.append(twig(x, curve(x) + tilt, x1, curve(x1) - tilt, random.uniform(11, 15), bend=random.uniform(-6, 6)))
        if x1 >= CX + half + reach_r: break
        x = x1 - random.uniform(50, 80)
# twigs hanging off the bottom edge
for _ in range(0):
    x = random.uniform(CX - 230, CX + 230); y = bottom(x) - 10
    front_svg.append(twig(x, y, x + random.uniform(-90, 90), y + random.uniform(20, 55), random.uniform(7, 10)))
# the lip: twigs laid along the front edge, drawn last so it reads twiggy
for _ in range(8):
    front_svg.append(along(lip, CX - RX - 35, CX + RX + 35, 7, random.uniform(12, 16)))

back_group = f'''  <!-- the nest's back rim and hollow, behind the bird -->
  <g filter="url(#wobble)" fill="none" stroke-linecap="round" stroke-linejoin="round">
    <path d="M{CX-RX} {CY} C{CX-RX} {CY-40} {CX-170} {CY-62} {CX} {CY-62} C{CX+170} {CY-62} {CX+RX} {CY-40} {CX+RX} {CY} C{CX+RX} {CY+40} {CX+170} {CY+60} {CX} {CY+60} C{CX-170} {CY+60} {CX-RX} {CY+40} {CX-RX} {CY} Z" fill="#5A3820" stroke="none"/>
    {"".join(back_svg)}
    <path d="M{CX-RX+40} {CY+2} C{CX-RX+40} {CY-22} {CX-150} {CY-35} {CX} {CY-35} C{CX+150} {CY-35} {CX+RX-40} {CY-22} {CX+RX-40} {CY+2} C{CX+RX-40} {CY+25} {CX+150} {CY+38} {CX} {CY+38} C{CX-150} {CY+38} {CX-RX+40} {CY+25} {CX-RX+40} {CY+2} Z" fill="#4A2D19" stroke="none"/>
  </g>

'''
front_group = f'''  <!-- the nest's front, twig over twig, over the bird -->
  <g filter="url(#wobble)" fill="none" stroke-linecap="round" stroke-linejoin="round">
    <path d="M{CX-RX+5} {CY+5} C{CX-RX+5} {CY+40} {CX-170} {CY+52} {CX} {CY+52} C{CX+170} {CY+52} {CX+RX-5} {CY+40} {CX+RX-5} {CY+5} C{CX+RX-30} {CY+110} {CX+170} {CY+175} {CX} {CY+175} C{CX-170} {CY+175} {CX-RX+30} {CY+110} {CX-RX+5} {CY+5} Z" fill="#7A4E2D" stroke="none"/>
    {"".join(front_svg)}
  </g>
'''
svg = (HERE / "base.svg").read_text()
svg = svg.replace("  <!-- NEST_BACK -->\n", back_group).replace("  <!-- NEST_FRONT -->\n", front_group)
(HERE / "AppIcon.svg").write_text(svg)
subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", "-b", "white", str(HERE / "AppIcon.svg"), "-o", str(OUTPUT_PNG)], check=True)
print(f"Wrote {OUTPUT_PNG}")
