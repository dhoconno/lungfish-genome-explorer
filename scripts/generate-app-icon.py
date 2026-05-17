#!/usr/bin/env python3
"""
Generate Lungfish app icon assets from the current orange-on-cream brand mark.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


BRAND_COLORS = {
    "orange": (212, 123, 58),   # #D47B3A
    "cream": (250, 244, 234),   # #FAF4EA
    "warm_grey": (138, 132, 122),
    "deep_ink": (31, 26, 23),
}

DEFAULT_BACKGROUND = (252, 252, 252)
DEFAULT_FOREGROUND = (238, 139, 79)
ABOUT_LOGO_SIZE = 2048


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def default_source_logo_path() -> Path:
    return project_root() / "scripts" / "app-icon-source.png"


def load_source_logo(source_path: Path | None = None) -> Image.Image:
    path = source_path or default_source_logo_path()
    return Image.open(path).convert("RGBA")


def iter_pixels(image: Image.Image):
    data = image.tobytes()
    for index in range(0, len(data), 4):
        yield data[index], data[index + 1], data[index + 2], data[index + 3]


def estimate_source_background(source: Image.Image) -> tuple[int, int, int]:
    samples: list[tuple[int, int, int]] = []
    for r, g, b, a in iter_pixels(source.resize((256, 256), Image.Resampling.LANCZOS)):
        if a == 0:
            continue
        spread = max(r, g, b) - min(r, g, b)
        if max(r, g, b) >= 235 and spread <= 12:
            samples.append((r, g, b))
    if not samples:
        return DEFAULT_BACKGROUND
    return tuple(round(sum(pixel[index] for pixel in samples) / len(samples)) for index in range(3))


def estimate_source_foreground(source: Image.Image) -> tuple[int, int, int]:
    samples: list[tuple[int, int, int]] = []
    for r, g, b, a in iter_pixels(source.resize((256, 256), Image.Resampling.LANCZOS)):
        if a == 0:
            continue
        spread = max(r, g, b) - min(r, g, b)
        if spread >= 28 and r > g > b:
            samples.append((r, g, b))
    if not samples:
        return DEFAULT_FOREGROUND
    return tuple(round(sum(pixel[index] for pixel in samples) / len(samples)) for index in range(3))


def color_distance_squared(left: tuple[int, int, int], right: tuple[int, int, int]) -> int:
    return sum((left[index] - right[index]) ** 2 for index in range(3))


def extract_brand_mark(source: Image.Image) -> Image.Image:
    background = estimate_source_background(source)
    foreground = estimate_source_foreground(source)

    mark = Image.new("RGBA", source.size, (0, 0, 0, 0))
    mark_pixels = mark.load()
    source_pixels = source.load()

    for y in range(source.height):
        for x in range(source.width):
            r, g, b, a = source_pixels[x, y]
            if a == 0:
                continue

            observed = (r, g, b)
            foreground_distance = color_distance_squared(observed, foreground)
            background_distance = color_distance_squared(observed, background)
            if foreground_distance * 1.15 >= background_distance:
                continue

            mark_pixels[x, y] = (*BRAND_COLORS["orange"], a)

    return mark


def add_drop_shadow(canvas: Image.Image, bounds: tuple[int, int, int, int], radius: int) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    x1, y1, x2, y2 = bounds
    shadow_draw.rounded_rectangle(
        (x1, y1 + max(2, radius // 12), x2, y2 + max(2, radius // 12)),
        radius=radius,
        fill=(*BRAND_COLORS["deep_ink"], 28),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(2, radius // 8)))
    canvas.alpha_composite(shadow)


def compose_icon(size: int, brand_mark: Image.Image) -> Image.Image:
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    tile_inset = round(size * 0.085)
    tile_bounds = (tile_inset, tile_inset, size - tile_inset, size - tile_inset)
    tile_radius = round((tile_bounds[2] - tile_bounds[0]) * 0.28)

    add_drop_shadow(icon, tile_bounds, tile_radius)

    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile_draw = ImageDraw.Draw(tile)
    tile_draw.rounded_rectangle(tile_bounds, radius=tile_radius, fill=(*BRAND_COLORS["cream"], 255))
    tile_draw.rounded_rectangle(tile_bounds, radius=tile_radius, outline=(*BRAND_COLORS["warm_grey"], 48), width=max(1, size // 128))
    icon.alpha_composite(tile)

    cropped_mark = brand_mark.crop(brand_mark.getbbox())
    mark_max_extent = tile_bounds[2] - tile_bounds[0]
    mark_scale = 0.78 if size <= 32 else 0.74
    mark_target = round(mark_max_extent * mark_scale)
    resized_mark = cropped_mark.resize((mark_target, mark_target), Image.Resampling.LANCZOS)

    mark_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mark_position = ((size - resized_mark.width) // 2, (size - resized_mark.height) // 2)
    mark_layer.alpha_composite(resized_mark, dest=mark_position)
    icon.alpha_composite(mark_layer)
    return icon


def create_icon(size: int, source_logo: Image.Image | None = None) -> Image.Image:
    source = source_logo or load_source_logo()
    brand_mark = extract_brand_mark(source)
    return compose_icon(size, brand_mark)


def generate_all_icons(output_dir: Path, source_logo: Image.Image) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)

    sizes = [
        (16, 1, 16),
        (16, 2, 32),
        (32, 1, 32),
        (32, 2, 64),
        (128, 1, 128),
        (128, 2, 256),
        (256, 1, 256),
        (256, 2, 512),
        (512, 1, 512),
        (512, 2, 1024),
    ]

    generated_files: list[Path] = []
    brand_mark = extract_brand_mark(source_logo)
    for points, scale, pixels in sizes:
        filename = f"icon_{points}x{points}.png" if scale == 1 else f"icon_{points}x{points}@2x.png"
        icon = compose_icon(pixels, brand_mark)
        destination = output_dir / filename
        icon.save(destination, "PNG")
        generated_files.append(destination)
        print(f"Saved {destination}")
    return generated_files


def write_about_logo(output_path: Path, source_logo: Image.Image) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    create_icon(ABOUT_LOGO_SIZE, source_logo).save(output_path, "PNG")
    print(f"Saved {output_path}")


def create_icns(png_dir: Path, output_path: Path) -> None:
    iconset_dir = output_path.with_suffix(".iconset")
    if iconset_dir.exists():
        shutil.rmtree(iconset_dir)
    iconset_dir.mkdir(parents=True, exist_ok=True)

    for png_path in png_dir.glob("*.png"):
        shutil.copy2(png_path, iconset_dir / png_path.name)

    try:
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(output_path)],
            check=True,
        )
        print(f"Saved {output_path}")
    finally:
        shutil.rmtree(iconset_dir, ignore_errors=True)


def main() -> None:
    root = project_root()
    source_logo = load_source_logo()

    png_output_dir = root / "Sources" / "LungfishApp" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
    about_logo_output = root / "Sources" / "LungfishApp" / "Resources" / "Images" / "about-logo.png"
    icns_output = root / "Sources" / "Lungfish" / "AppIcon.icns"

    print("Generating Lungfish app icon assets...")
    generate_all_icons(png_output_dir, source_logo)
    write_about_logo(about_logo_output, source_logo)
    create_icns(png_output_dir, icns_output)


if __name__ == "__main__":
    main()
