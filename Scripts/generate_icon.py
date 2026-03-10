#!/usr/bin/env python3
"""Generate the SequelPG app icon at all required macOS sizes."""

from PIL import Image, ImageDraw, ImageFont
import math
import os

ICON_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "SequelPGApp", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

# macOS icon sizes: (filename, pixel size)
SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def draw_rounded_rect(draw, bbox, radius, fill):
    """Draw a rounded rectangle."""
    x0, y0, x1, y1 = bbox
    draw.rounded_rectangle(bbox, radius=radius, fill=fill)


def lerp_color(c1, c2, t):
    """Linearly interpolate between two RGB colors."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def generate_icon(size):
    """Generate the icon at the given pixel size."""
    # Work at 4x for anti-aliasing, then downscale
    s = max(size * 4, 1024)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = int(s * 0.03)
    corner_radius = int(s * 0.22)

    # Background gradient: deep navy to rich blue-purple
    c_top = (20, 30, 70)
    c_bottom = (60, 40, 120)
    for y in range(margin, s - margin):
        t = (y - margin) / max(1, (s - 2 * margin))
        color = lerp_color(c_top, c_bottom, t)
        draw.line([(margin, y), (s - margin - 1, y)], fill=color + (255,))

    # Apply rounded corners by masking
    mask = Image.new("L", (s, s), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [margin, margin, s - margin, s - margin],
        radius=corner_radius,
        fill=255,
    )
    img.putalpha(mask)

    # Re-get draw after alpha manipulation
    draw = ImageDraw.Draw(img)

    # --- Draw stylized elephant silhouette ---
    cx, cy = s * 0.5, s * 0.42
    head_r = s * 0.22

    # Elephant color - soft teal/cyan
    el_color = (100, 210, 230, 255)
    el_light = (160, 235, 245, 255)

    # Head (circle)
    draw.ellipse(
        [cx - head_r, cy - head_r, cx + head_r, cy + head_r],
        fill=el_color,
    )

    # Ears (larger circles to the sides, partially behind head)
    ear_r = head_r * 0.65
    ear_offset_x = head_r * 0.85
    ear_offset_y = head_r * 0.1
    # Left ear
    draw.ellipse(
        [
            cx - ear_offset_x - ear_r,
            cy - ear_offset_y - ear_r,
            cx - ear_offset_x + ear_r,
            cy - ear_offset_y + ear_r,
        ],
        fill=el_light,
    )
    # Right ear
    draw.ellipse(
        [
            cx + ear_offset_x - ear_r,
            cy - ear_offset_y - ear_r,
            cx + ear_offset_x + ear_r,
            cy - ear_offset_y + ear_r,
        ],
        fill=el_light,
    )

    # Redraw head on top of ears
    draw.ellipse(
        [cx - head_r, cy - head_r, cx + head_r, cy + head_r],
        fill=el_color,
    )

    # Trunk (curved downward)
    trunk_w = head_r * 0.25
    trunk_top = cy + head_r * 0.5
    trunk_bottom = cy + head_r * 1.5
    trunk_cx = cx

    # Draw trunk as a series of ellipses going down and curving right
    steps = 20
    for i in range(steps):
        t = i / steps
        ty = trunk_top + (trunk_bottom - trunk_top) * t
        tx = trunk_cx + math.sin(t * 2.5) * head_r * 0.3
        tw = trunk_w * (1.0 - t * 0.3)
        draw.ellipse(
            [tx - tw, ty - tw * 0.5, tx + tw, ty + tw * 0.5],
            fill=el_color,
        )

    # Eyes (small dark circles)
    eye_r = head_r * 0.08
    eye_y = cy - head_r * 0.1
    eye_x_offset = head_r * 0.35
    # White of eye
    draw.ellipse(
        [
            cx - eye_x_offset - eye_r * 1.5,
            eye_y - eye_r * 1.5,
            cx - eye_x_offset + eye_r * 1.5,
            eye_y + eye_r * 1.5,
        ],
        fill=(255, 255, 255, 255),
    )
    draw.ellipse(
        [
            cx + eye_x_offset - eye_r * 1.5,
            eye_y - eye_r * 1.5,
            cx + eye_x_offset + eye_r * 1.5,
            eye_y + eye_r * 1.5,
        ],
        fill=(255, 255, 255, 255),
    )
    # Pupil
    draw.ellipse(
        [
            cx - eye_x_offset - eye_r,
            eye_y - eye_r,
            cx - eye_x_offset + eye_r,
            eye_y + eye_r,
        ],
        fill=(20, 25, 50, 255),
    )
    draw.ellipse(
        [
            cx + eye_x_offset - eye_r,
            eye_y - eye_r,
            cx + eye_x_offset + eye_r,
            eye_y + eye_r,
        ],
        fill=(20, 25, 50, 255),
    )

    # --- Draw "SQL" text below the elephant ---
    text_y = s * 0.72
    # Try to use a nice font, fall back to default
    font_size = int(s * 0.14)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompact.ttf", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype(
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf", font_size
            )
        except (OSError, IOError):
            try:
                font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
            except (OSError, IOError):
                font = ImageFont.load_default()

    text = "SQL"
    text_bbox = draw.textbbox((0, 0), text, font=font)
    text_w = text_bbox[2] - text_bbox[0]
    text_x = (s - text_w) / 2

    # Text with subtle glow
    glow_color = (100, 210, 230, 80)
    for offset in range(3, 0, -1):
        o = offset * int(s * 0.003)
        draw.text((text_x - o, text_y - o), text, fill=glow_color, font=font)
        draw.text((text_x + o, text_y - o), text, fill=glow_color, font=font)
        draw.text((text_x - o, text_y + o), text, fill=glow_color, font=font)
        draw.text((text_x + o, text_y + o), text, fill=glow_color, font=font)

    # Main text
    draw.text((text_x, text_y), text, fill=(255, 255, 255, 255), font=font)

    # --- Subtle chevron brackets around SQL: < > ---
    bracket_color = (100, 210, 230, 180)
    bracket_font_size = int(s * 0.10)
    try:
        bracket_font = ImageFont.truetype(
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf", bracket_font_size
        )
    except (OSError, IOError):
        try:
            bracket_font = ImageFont.truetype(
                "/System/Library/Fonts/Helvetica.ttc", bracket_font_size
            )
        except (OSError, IOError):
            bracket_font = font

    bracket_y = text_y + font_size * 0.15
    left_bracket_x = text_x - s * 0.09
    right_bracket_x = text_x + text_w + s * 0.04
    draw.text((left_bracket_x, bracket_y), "<", fill=bracket_color, font=bracket_font)
    draw.text((right_bracket_x, bracket_y), ">", fill=bracket_color, font=bracket_font)

    # Downscale with high-quality resampling
    img = img.resize((size, size), Image.LANCZOS)
    return img


def main():
    os.makedirs(ICON_DIR, exist_ok=True)

    # Generate Contents.json
    images = []
    size_map = {
        16: "16x16",
        32: "32x32",
        128: "128x128",
        256: "256x256",
        512: "512x512",
    }

    for filename, pixel_size in SIZES:
        print(f"Generating {filename} ({pixel_size}x{pixel_size})...")
        icon = generate_icon(pixel_size)
        icon.save(os.path.join(ICON_DIR, filename), "PNG")

    # Write Contents.json
    contents = {
        "images": [
            {"filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
            {"filename": "icon_16x16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
            {"filename": "icon_32x32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
            {"filename": "icon_32x32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
            {"filename": "icon_128x128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
            {"filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
            {"filename": "icon_256x256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
            {"filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
            {"filename": "icon_512x512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
            {"filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
        ],
        "info": {"author": "xcode", "version": 1},
    }

    import json

    with open(os.path.join(ICON_DIR, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")

    print("Done! All icons generated.")


if __name__ == "__main__":
    main()
