#!/usr/bin/env python3
"""Render README contact sheets from one camera RAW through the shipping engine."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
sys.path.insert(0, str(ENGINE / "tests"))

from spk_ctypes import Engine, EngineError  # noqa: E402

SRGB_TO_PROPHOTO = np.array([
    [0.7977666, 0.1351813, 0.0313477],
    [0.2880748, 0.7118352, 0.0000899],
    [0.0, 0.0, 0.8252100],
], dtype=np.float32)


def decode_raw(path: Path, work: Path) -> np.ndarray:
    jpeg = work / "apple-raw-preview.jpg"
    subprocess.run([
        "sips", "-s", "format", "jpeg", "--resampleHeightWidthMax", "360",
        str(path), "--out", str(jpeg),
    ], check=True, stdout=subprocess.DEVNULL)
    rgb = np.asarray(Image.open(jpeg).convert("RGB"), dtype=np.float32) / 255.0
    linear = np.where(rgb <= 0.04045, rgb / 12.92,
                      np.power((rgb + 0.055) / 1.055, 2.4)).astype(np.float32)
    return np.ascontiguousarray(linear @ SRGB_TO_PROPHOTO.T)


def profile_catalog(resources: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str]], list[tuple[str, str]]]:
    films, papers, slides = [], [], []
    for path in sorted((resources / "profiles").glob("*.json")):
        data = json.loads(path.read_text())
        info = data.get("info", {})
        support = info.get("support")
        kind = info.get("type")
        if data.get("derived_from") and not support:
            support, kind = "film", "negative"
        item = (path.stem, info.get("name", path.stem))
        if support == "paper":
            papers.append(item)
        elif support == "film" and kind == "positive":
            slides.append(item)
        elif support == "film":
            films.append(item)
    return films, papers, slides


def stage_resources(work: Path) -> Path:
    staged = work / "resources"
    shutil.copytree(ENGINE / "resources", staged)
    product = ENGINE / "resources_product"
    for profile in (product / "profiles").glob("*.json"):
        shutil.copy2(profile, staged / "profiles" / profile.name)
    shutil.copy2(ENGINE / "build" / "spektrafilm.metallib", staged / "spektrafilm.metallib")
    return staged


def render(engine: Engine, frame: np.ndarray, film: str, paper: str) -> Image.Image:
    delta = {
        "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
        "output_color_space": "sRGB", "output_cctf_encoding": True,
        "film_stock": film, "print_stock": paper, "auto_exposure": True,
        "grain_active": True, "grain_amount": 0.35,
        "halation_active": True, "halation_amount": 0.25,
        "glare_active": True, "glare_amount": 0.15,
        "density_curve_gamma": 0.45,
    }
    with engine.open(frame, delta) as session:
        session.solve("both")
        rgba, _ = session.render("live")
    return Image.fromarray((rgba[..., :3] / 257).astype(np.uint8), "RGB")


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    path = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def sheet(title: str, items: list[tuple[str, Image.Image]], output: Path) -> None:
    columns, image_w, image_h, label_h = 4, 300, 200, 48
    rows = (len(items) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * image_w, 66 + rows * (image_h + label_h)), "#f3f3f1")
    draw = ImageDraw.Draw(canvas)
    draw.text((18, 18), title, fill="#151515", font=font(25))
    label_font = font(15)
    for index, (name, image) in enumerate(items):
        x = (index % columns) * image_w
        y = 66 + (index // columns) * (image_h + label_h)
        canvas.paste(image.resize((image_w, image_h), Image.Resampling.LANCZOS), (x, y))
        draw.text((x + 9, y + image_h + 10), name, fill="#202020", font=label_font)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, quality=84, optimize=True, progressive=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "docs" / "stock-previews")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="spektralab-previews-") as tmp:
        work = Path(tmp)
        frame = decode_raw(args.raw, work)
        resources = stage_resources(work)
        films, papers, slides = profile_catalog(resources)
        with Engine(library=ENGINE / "build" / "libspektrafilm_engine.dylib",
                    resources=resources) as engine:
            for paper_id, paper_name in papers:
                rendered = []
                for film_id, film_name in films:
                    try:
                        rendered.append((film_name, render(engine, frame, film_id, paper_id)))
                        print(f"rendered {film_id} + {paper_id}")
                    except EngineError as error:
                        print(f"skipped {film_id} + {paper_id}: {error}", file=sys.stderr)
                sheet(f"Paper: {paper_name}", rendered, args.output / f"{paper_id}.jpg")
            slide_items = [(name, render(engine, frame, stock, papers[0][0]))
                           for stock, name in slides]
            sheet("Reversal films (no paper print stage)", slide_items,
                  args.output / "reversal-films.jpg")


if __name__ == "__main__":
    main()
