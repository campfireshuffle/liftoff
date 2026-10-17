#!/usr/bin/env python3
"""Renders the demo wallpaper: a night test track, black sky, a red light strip on the far edge of
the tarmac, and a few distant floodlights, like the Roadster demo's set.

Usage: scripts/make-wallpaper.py [output.png] [width] [height]
Needs numpy and ffmpeg.
"""
import subprocess
import sys

import numpy as np

out = sys.argv[1] if len(sys.argv) > 1 else "assets/wallpaper-night-track.png"
W = int(sys.argv[2]) if len(sys.argv) > 2 else 5120
H = int(sys.argv[3]) if len(sys.argv) > 3 else 2880
rng = np.random.default_rng(7)
y = np.linspace(0, 1, H)[:, None]
x = np.linspace(0, 1, W)[None, :]
y3 = y[..., None]  # for multiplying RGB triples


def box_blur(a, r, axis):
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis)
    hi = np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis)
    lo = np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)
    return (hi - lo) / (2 * r + 1)


def glow(mask, radius):
    """Soft bloom: three box blurs approximate a gaussian."""
    for _ in range(3):
        mask = box_blur(box_blur(mask, radius, 0), radius, 1)
    return mask


horizon = 0.86  # where the tarmac meets the sky; the light strip sits here

# Sky: near-black with a faint cold haze just above the horizon.
img = np.zeros((H, W, 3))
img += np.array([0.0016, 0.0018, 0.0026]) * (1 - 0.5 * y3)
haze = np.exp(-(((y - horizon) / 0.07) ** 2)) * np.exp(-(((x - 0.45) / 0.5) ** 2))
img += haze[..., None] * np.array([0.004, 0.005, 0.008])

# Tarmac: slightly lifted, with grain and a faint sheen toward the viewer.
ground = (y > horizon).astype(float)
grain = rng.normal(0, 1, (H, W))
grain = box_blur(grain, 1, 0) * 0.7 + grain * 0.3
img += ground[..., None] * (np.array([0.0045, 0.0046, 0.005]) * (0.6 + 0.4 * (y3 - horizon) / (1 - horizon))
                            + (grain * 0.0012)[..., None])

# The red light strip: bright on the left, fading out toward the right, like the set's LED line.
strip = np.zeros((H, W))
row = int(H * horizon)
fade_in = np.clip((x[0] - 0.03) / 0.02, 0, 1)
fade_out = np.clip(1 - (x[0] - 0.05) / 0.8, 0, 1) ** 2.2
strip[row - 2:row + 2, :] = (fade_in * fade_out)[None, :]
red = np.array([1.0, 0.10, 0.08])
img += strip[..., None] * red * 1.4
img += glow(strip, max(2, W // 900))[..., None] * red * 3.0
img += glow(strip, max(4, W // 160))[..., None] * red * 6.0

# Its reflection smeared across the wet tarmac below.
reflection = glow(np.roll(strip, int(H * 0.012), axis=0), max(4, W // 300)) * ground
reflection = box_blur(reflection, max(4, H // 80), 0) * np.exp(-np.clip(y - horizon, 0, 1) / 0.045)
img += reflection[..., None] * red * 1.6

# A few distant floodlights along the horizon.
lights = np.zeros((H, W))
for lx in rng.uniform(0.05, 0.95, 9):
    ly = int(H * (horizon - rng.uniform(0.004, 0.012)))
    lights[ly - 3:ly + 3, int(lx * W) - 3:int(lx * W) + 3] = rng.uniform(0.3, 1.0)
img += lights[..., None] * 0.9
img += glow(lights, max(3, W // 600))[..., None] * np.array([0.9, 0.95, 1.0]) * 5.0
img += glow(lights, max(8, W // 120))[..., None] * np.array([0.8, 0.88, 1.0]) * 3.0

# Vignette, then a whisper of noise everywhere so gradients don't band.
vignette = 1 - 0.55 * (((x - 0.5) / 0.75) ** 2 + ((y - 0.55) / 0.9) ** 2)
img *= np.clip(vignette, 0.3, 1)[..., None]
img += np.abs(rng.normal(0, 0.0012, (H, W, 1)))

pixels = (np.clip(img, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
subprocess.run(
    ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-i", "-",
     "-frames:v", "1", out],
    input=pixels.tobytes(), check=True)
print(out)
