#!/usr/bin/env python3
"""Turns square, full-bleed artwork into a macOS app icon set.

Applies Apple's icon layout (824 pt rounded-square body on a 1024 pt canvas, continuous
"squircle" corners, soft drop shadow) and writes every size the asset catalog needs.

    python3 Scripts/make_app_icon.py Design/AppIcon-artwork.png Murmur/Resources/Assets.xcassets/AppIcon.appiconset
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

CANVAS = 1024
BODY = 824            # icon body size inside the canvas (Apple macOS template)
EXPONENT = 5.0        # superellipse exponent approximating Apple's continuous corners
SUPERSAMPLE = 4


def squircle_mask(size: int) -> Image.Image:
    n = size * SUPERSAMPLE
    coords = (np.arange(n) + 0.5) / n * 2 - 1
    x, y = np.meshgrid(coords, coords)
    inside = (np.abs(x) ** EXPONENT + np.abs(y) ** EXPONENT) <= 1.0
    mask = Image.fromarray((inside * 255).astype(np.uint8), "L")
    return mask.resize((size, size), Image.LANCZOS)


def build_master(artwork_path: str) -> Image.Image:
    art = Image.open(artwork_path).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
    mask = squircle_mask(BODY)
    body = Image.new("RGBA", (BODY, BODY))
    body.paste(art, (0, 0), mask)

    # Hairline highlight along the top edge for a touch of depth.
    edge = mask.filter(ImageFilter.FIND_EDGES).point(lambda v: min(255, v * 2))
    gradient = Image.linear_gradient("L").resize((BODY, BODY)).transpose(Image.FLIP_TOP_BOTTOM)
    highlight_alpha = Image.fromarray((np.asarray(edge, dtype=np.float32) * np.asarray(gradient, dtype=np.float32) / 255 * 0.18).astype(np.uint8))
    highlight = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 0))
    highlight.putalpha(highlight_alpha)
    body = Image.alpha_composite(body, highlight)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_mask.paste(mask, (offset, offset + 10))
    shadow.putalpha(shadow_mask.point(lambda v: int(v * 0.32)).filter(ImageFilter.GaussianBlur(14)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def main() -> None:
    artwork, output = sys.argv[1], sys.argv[2]
    master = build_master(artwork)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "" if scale == 1 else "@2x"
            image = master if pixels == CANVAS else master.resize((pixels, pixels), Image.LANCZOS)
            if pixels <= 64:
                image = image.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
            image.save(f"{output}/icon_{points}x{points}{suffix}.png", optimize=True)
    print("wrote icon set to", output)


if __name__ == "__main__":
    main()
