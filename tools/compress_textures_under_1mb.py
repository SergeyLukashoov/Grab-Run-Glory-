#!/usr/bin/env python3
"""
Shrink PNG/TGA/PSD/TIFF sources under Assets/ to <= 1 MiB when possible.
Preserves channels as much as Pillow allows; 16-bit greyscale textures become 8-bit.
"""

from __future__ import annotations

import io
import os
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / "Assets"
MAX_BYTES = 1024 * 1024
EXTS = {".png", ".tif", ".tiff", ".tga", ".psd"}


def png_bytes(im: Image.Image, *, compress_level: int = 9) -> bytes:
    buf = io.BytesIO()
    im.save(buf, format="PNG", compress_level=compress_level, optimize=True)
    return buf.getvalue()


def prepare_image(im: Image.Image) -> Image.Image:
    if im.mode == "I;16":
        arr = np.asarray(im, dtype=np.uint32)
        scaled = np.clip(np.rint(arr * (255.0 / 65535.0)), 0, 255).astype(np.uint8)
        if scaled.ndim != 2:
            scaled = np.squeeze(scaled)
        return Image.fromarray(scaled, mode="L")
    if im.mode == "I":
        mapped = im.point(lambda p: max(0, min(255, int(p))))
        return mapped.convert("L")
    if im.mode == "P":
        im = im.convert("RGBA")
    if im.mode in ("RGBA", "RGB", "L", "LA"):
        return im
    return im.convert("RGBA")


def load_flat(path: Path) -> Image.Image:
    with Image.open(path) as img:
        try:
            img.seek(0)
        except EOFError:
            pass
        return prepare_image(img.copy())


def fit_under_limit(im: Image.Image, max_bytes: int) -> tuple[Image.Image, int]:
    """Return (image, output PNG size) possibly downscaled (few PNG encodes)."""
    cur = im
    for _ in range(40):
        blob = png_bytes(cur)
        if len(blob) <= max_bytes:
            return cur, len(blob)
        w, h = cur.size
        factor = float(max_bytes) / len(blob)
        shrink = factor**0.5 * 0.92
        shrink = max(0.55, min(0.88, shrink))
        nw = max(1, int(w * shrink))
        nh = max(1, int(h * shrink))
        if (nw, nh) == (w, h):
            nw = max(1, int(w * 0.85))
            nh = max(1, int(h * 0.85))
        if max(nw, nh) < 256:
            raise RuntimeError(f"cannot fit under {max_bytes} bytes without going below 256 px")
        cur = cur.resize((nw, nh), Image.Resampling.LANCZOS)
    raise RuntimeError("iteration limit resizing texture")


def process_regular(path: Path) -> tuple[int, int, str]:
    before = path.stat().st_size
    base = load_flat(path)
    orig_size = base.size

    fitted, nbytes = fit_under_limit(base, MAX_BYTES)
    png_data = png_bytes(fitted)

    suffix = path.suffix.lower()
    target = path
    if suffix == ".psd":
        target = path.with_suffix(".png")
        if target.exists():
            raise RuntimeError(f"refusing to overwrite existing {target}")

    tmp = target.with_suffix(target.suffix + ".compress_tmp")
    try:
        tmp.write_bytes(png_data)
        os.replace(tmp, target)
    finally:
        if tmp.exists():
            tmp.unlink()

    if suffix == ".psd":
        meta = path.parent / (path.name + ".meta")
        path.unlink(missing_ok=True)
        meta.unlink(missing_ok=True)

    if suffix == ".psd":
        detail = "psd→png"
    elif fitted.size != orig_size:
        detail = f"{fitted.size[0]}x{fitted.size[1]}"
    else:
        detail = "re-encoded"

    return before, nbytes, detail


def main() -> None:
    files: list[Path] = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in EXTS:
            continue
        if p.name.endswith(".compress_tmp"):
            continue
        if p.stat().st_size <= MAX_BYTES:
            continue
        files.append(p)

    files.sort(key=lambda p: -p.stat().st_size)
    print(f"Found {len(files)} oversize raster sources (> {MAX_BYTES // 1024} KiB).\n", flush=True)

    for path in files:
        rel = path.relative_to(ROOT)
        print(f"-- {rel} ...", flush=True)
        try:
            before, after, detail = process_regular(path)
            print(f"OK {rel}: {before/1024/1024:.2f} MB -> {after/1024/1024:.2f} MB ({detail})", flush=True)
        except Exception as e:
            print(f"FAIL {rel}: {e}", flush=True)


if __name__ == "__main__":
    main()
