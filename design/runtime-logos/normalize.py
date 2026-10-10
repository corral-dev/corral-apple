#!/usr/bin/env python3
"""把官方 SVG 归一成同一画布的透明 PNG，写入 Asset Catalog。禁止改色或重绘轮廓。"""

from __future__ import annotations

import io
import json
from pathlib import Path

import cairosvg
from PIL import Image

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "source"
NORMALIZED = HERE / "normalized"
ASSET_ROOT = HERE.parent.parent / "Corral" / "Assets.xcassets"

CANVAS = 256
PAD_RATIO = 0.16  # 四周留白，让各家在 36pt 方块里视觉重量接近
SCALES = (("1x", 36), ("2x", 72), ("3x", 108))

# (asset 名, 浅色底源, 深色底源；深色为 None 表示深浅共用)
ITEMS: list[tuple[str, str, str | None]] = [
    ("RuntimeClaude", "claude.svg", None),
    ("RuntimeCodex", "codex-light.svg", "codex-dark.svg"),
    ("RuntimeCursor", "cursor-light.svg", "cursor-dark.svg"),
    ("RuntimeKimi", "kimi-light.svg", "kimi-dark.svg"),
    ("RuntimeOpenCode", "opencode-light.svg", "opencode-dark.svg"),
    ("RuntimePi", "pi-light.svg", "pi-dark.svg"),
]


def render_svg(path: Path, px: int = 1024) -> Image.Image:
    # 只钉长边，避免把非正方形官方标拉变形。
    png = cairosvg.svg2png(url=str(path), output_width=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def normalize(im: Image.Image, canvas: int = CANVAS, pad_ratio: float = PAD_RATIO) -> Image.Image:
    bbox = im.getbbox()
    if bbox is None:
        raise ValueError("图是全透明的，无法归一化")
    trimmed = im.crop(bbox)
    inner = int(round(canvas * (1 - 2 * pad_ratio)))
    ratio = min(inner / trimmed.width, inner / trimmed.height)
    new_w = max(1, int(round(trimmed.width * ratio)))
    new_h = max(1, int(round(trimmed.height * ratio)))
    scaled = trimmed.resize((new_w, new_h), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(scaled, ((canvas - new_w) // 2, (canvas - new_h) // 2), scaled)
    return out


def write_imageset(name: str, light: Image.Image, dark: Image.Image | None) -> None:
    folder = ASSET_ROOT / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("*.png"):
        old.unlink()

    images: list[dict] = []
    for scale_name, px in SCALES:
        light_name = f"{name.lower()}-light@{scale_name}.png"
        light.resize((px, px), Image.Resampling.LANCZOS).save(folder / light_name, "PNG")
        images.append({"idiom": "universal", "scale": scale_name, "filename": light_name})
        if dark is not None:
            dark_name = f"{name.lower()}-dark@{scale_name}.png"
            dark.resize((px, px), Image.Resampling.LANCZOS).save(folder / dark_name, "PNG")
            images.append({
                "idiom": "universal",
                "scale": scale_name,
                "filename": dark_name,
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
            })

    (folder / "Contents.json").write_text(
        json.dumps(
            {
                "images": images,
                "info": {"author": "xcode", "version": 1},
                "properties": {"template-rendering-intent": "original", "preserves-vector-representation": False},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    NORMALIZED.mkdir(parents=True, exist_ok=True)
    for name, light_file, dark_file in ITEMS:
        light = normalize(render_svg(SOURCE / light_file))
        light.save(NORMALIZED / f"{name}-light.png", "PNG")
        dark = None
        if dark_file:
            dark = normalize(render_svg(SOURCE / dark_file))
            dark.save(NORMALIZED / f"{name}-dark.png", "PNG")
        write_imageset(name, light, dark)
        print(f"ok {name}")


if __name__ == "__main__":
    main()
