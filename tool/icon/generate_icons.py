#!/usr/bin/env python3
"""Generate Deployment-Browser app icons for all target platforms.

Source design: rounded square with a vertical blue gradient + a stylised
white "rocket" silhouette and three pipeline dots, evoking "部署/发版"
(deploy/release).

Run from the repo root:

    python3 tool/icon/generate_icons.py

Re-run any time the source design changes; this script overwrites the
existing platform icons in place.
"""
from __future__ import annotations

import json
import os
import struct
import zlib
from pathlib import Path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PNG = REPO_ROOT / "tool" / "icon" / "app_icon_source_1024.png"


# ---------- 1. Source icon ----------

ACCENT_TOP = (76, 139, 245)      # #4C8BF5
ACCENT_BOTTOM = (37, 99, 235)    # #2563EB
WHITE = (255, 255, 255, 255)
WHITE_DIM = (255, 255, 255, 215)


def _gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """Vertical linear gradient at the requested size."""
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        grad.putpixel((0, y), (r, g, b))
    return grad.resize((size, size))


def _rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return mask


def _draw_rocket(canvas: Image.Image, *, size: int) -> None:
    """Centered rocket + flame + pipeline dots."""
    draw = ImageDraw.Draw(canvas, "RGBA")
    cx = size / 2

    # Coordinates in 1024 design space, scaled to current size.
    s = size / 1024

    # Rocket body — vertical capsule.
    body_w = 220 * s
    body_h = 480 * s
    body_top = 280 * s
    body_left = cx - body_w / 2
    body_right = cx + body_w / 2
    body_bottom = body_top + body_h
    draw.rounded_rectangle(
        (body_left, body_top, body_right, body_bottom),
        radius=body_w / 2,
        fill=WHITE,
    )

    # Rocket nose — pointed cap (triangle) covering the top of the capsule.
    nose_h = 150 * s
    nose_top = body_top - nose_h + 20 * s
    draw.polygon(
        [
            (cx, nose_top),
            (body_left + 10 * s, body_top + 90 * s),
            (body_right - 10 * s, body_top + 90 * s),
        ],
        fill=WHITE,
    )

    # Porthole — accent-colored circle on the body.
    win_r = 50 * s
    win_cy = body_top + 200 * s
    draw.ellipse(
        (cx - win_r, win_cy - win_r, cx + win_r, win_cy + win_r),
        fill=ACCENT_BOTTOM,
    )

    # Fins — left + right triangles at the rocket base.
    fin_top_y = body_bottom - 160 * s
    fin_bot_y = body_bottom + 30 * s
    fin_outset = 110 * s
    draw.polygon(
        [
            (body_left, fin_top_y),
            (body_left - fin_outset, fin_bot_y),
            (body_left + 4 * s, fin_bot_y),
        ],
        fill=WHITE,
    )
    draw.polygon(
        [
            (body_right, fin_top_y),
            (body_right + fin_outset, fin_bot_y),
            (body_right - 4 * s, fin_bot_y),
        ],
        fill=WHITE,
    )

    # Three pipeline dots beneath the rocket.
    dot_r = 24 * s
    dot_gap = 80 * s
    dot_cy = body_bottom + 95 * s
    for i in (-1, 0, 1):
        cxd = cx + i * dot_gap
        alpha = 220 if i == 0 else 150
        draw.ellipse(
            (cxd - dot_r, dot_cy - dot_r, cxd + dot_r, dot_cy + dot_r),
            fill=(255, 255, 255, alpha),
        )


def build_source(size: int = 1024) -> Image.Image:
    """Return the master icon image at [size]×[size] (RGBA).

    The rounded square is rendered inside [_INNER_RATIO] of the canvas so the
    icon visually matches Flutter's default templates (which leave transparent
    margin around the rounded square). Platforms that prefer edge-to-edge
    icons (e.g. iOS App Store 1024 entry, Android legacy) can opt out via
    [edge_to_edge=True].
    """
    return _compose(size, edge_to_edge=False)


def _compose(size: int, *, edge_to_edge: bool) -> Image.Image:
    inner = size if edge_to_edge else round(size * _INNER_RATIO)
    radius = round(inner * 0.22)  # iOS-style ~22% corner radius.

    bg_rgb = _gradient(inner, ACCENT_TOP, ACCENT_BOTTOM)
    bg = bg_rgb.convert("RGBA")

    # Subtle inner highlight: brighter spot at the top-left for depth.
    highlight = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).ellipse(
        (-inner * 0.2, -inner * 0.4, inner * 0.9, inner * 0.5),
        fill=(255, 255, 255, 38),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(inner * 0.05))
    bg.alpha_composite(highlight)

    # Rocket is drawn against the rounded-square canvas at [inner] size.
    _draw_rocket(bg, size=inner)

    # Clip to rounded corners.
    rounded_inner = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    rounded_inner.paste(bg, (0, 0), _rounded_mask(inner, radius))

    if edge_to_edge:
        return rounded_inner

    # Paste centered onto transparent canvas with margin.
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - inner) // 2
    canvas.paste(rounded_inner, (offset, offset), rounded_inner)
    return canvas


# Inner rounded-square occupies this fraction of the canvas; the rest is
# transparent margin (matches Flutter's default icon templates).
_INNER_RATIO = 0.84


def write_source() -> Image.Image:
    SOURCE_PNG.parent.mkdir(parents=True, exist_ok=True)
    img = build_source(1024)
    img.save(SOURCE_PNG, format="PNG", optimize=True)
    print(f"  wrote {SOURCE_PNG.relative_to(REPO_ROOT)}")
    return img


# ---------- 2. Helpers for resizing & writing ----------


def _resize(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


def _flatten_to_rgb(img: Image.Image, bg: tuple[int, int, int] | None = None) -> Image.Image:
    """For sinks that require an opaque PNG (iOS App Store icons)."""
    if img.mode != "RGBA":
        return img.convert("RGB")
    canvas = Image.new("RGB", img.size, bg or ACCENT_BOTTOM)
    canvas.paste(img, mask=img.split()[3])
    return canvas


def _write_png(img: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = _flatten_to_rgb(img) if opaque else img
    out.save(path, format="PNG", optimize=True)
    print(f"  wrote {path.relative_to(REPO_ROOT)}")


# ---------- 3. Platform pipelines ----------


def emit_ios(source: Image.Image) -> None:
    target = REPO_ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    # (display, scale, filename) — matches existing Contents.json entries.
    entries = [
        (20, 1, "Icon-App-20x20@1x.png"),
        (20, 2, "Icon-App-20x20@2x.png"),
        (20, 3, "Icon-App-20x20@3x.png"),
        (29, 1, "Icon-App-29x29@1x.png"),
        (29, 2, "Icon-App-29x29@2x.png"),
        (29, 3, "Icon-App-29x29@3x.png"),
        (40, 1, "Icon-App-40x40@1x.png"),
        (40, 2, "Icon-App-40x40@2x.png"),
        (40, 3, "Icon-App-40x40@3x.png"),
        (60, 2, "Icon-App-60x60@2x.png"),
        (60, 3, "Icon-App-60x60@3x.png"),
        (76, 1, "Icon-App-76x76@1x.png"),
        (76, 2, "Icon-App-76x76@2x.png"),
        (83.5, 2, "Icon-App-83.5x83.5@2x.png"),
        (1024, 1, "Icon-App-1024x1024@1x.png"),
    ]
    for display, scale, name in entries:
        px = round(display * scale)
        # App Store (1024) must be opaque; smaller icons opaque too for safety.
        _write_png(_resize(source, px), target / name, opaque=True)


def emit_macos(source: Image.Image) -> None:
    target = REPO_ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for px in sizes:
        _write_png(_resize(source, px), target / f"app_icon_{px}.png", opaque=False)


def emit_android(source: Image.Image) -> None:
    base = REPO_ROOT / "android" / "app" / "src" / "main" / "res"
    # mdpi = 48, hdpi = 72, xhdpi = 96, xxhdpi = 144, xxxhdpi = 192.
    densities = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, px in densities.items():
        _write_png(_resize(source, px), base / folder / "ic_launcher.png", opaque=False)


def emit_windows(source: Image.Image) -> None:
    """Build a multi-resolution .ico for Windows."""
    target = REPO_ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    target.parent.mkdir(parents=True, exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    # Save the largest variant first; Pillow downsamples for each entry in
    # `sizes`. Passing a small base image makes Pillow refuse to upscale and
    # we end up with only the one resolution embedded.
    base = _resize(source, max(sizes))
    base.save(target, format="ICO", sizes=[(s, s) for s in sizes])
    print(f"  wrote {target.relative_to(REPO_ROOT)}")


def emit_web(source: Image.Image) -> None:
    web = REPO_ROOT / "web"
    icons = web / "icons"
    _write_png(_resize(source, 16), web / "favicon.png", opaque=False)
    _write_png(_resize(source, 192), icons / "Icon-192.png", opaque=True)
    _write_png(_resize(source, 512), icons / "Icon-512.png", opaque=True)
    _write_png(_resize(source, 192), icons / "Icon-maskable-192.png", opaque=False)
    _write_png(_resize(source, 512), icons / "Icon-maskable-512.png", opaque=False)


# ---------- 4. Entrypoint ----------


def main() -> None:
    print("→ rendering source icon")
    source = write_source()
    print("→ ios")
    emit_ios(source)
    print("→ macos")
    emit_macos(source)
    print("→ android")
    emit_android(source)
    print("→ windows")
    emit_windows(source)
    print("→ web")
    emit_web(source)
    print("done.")


if __name__ == "__main__":
    main()
