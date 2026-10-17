#!/usr/bin/env python3
"""Draws the tvOS app icon and top shelf images into Runner/Assets.xcassets/AppIcon.brandassets.

App Store validation wants every layer at 1x and 2x, plus both top shelf images, so they are drawn here from the
app's own icon (assets/icon/icon_foreground.png) instead of being kept as a pile of hand-exported files.
Run after changing the icon:  python3 tvos/scripts/generate_brand_assets.py   (needs Pillow)
"""
import os
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CATALOG = os.path.join(ROOT, 'tvos/Runner/Assets.xcassets/AppIcon.brandassets')
BLUE = (24, 90, 160, 255)

mark = Image.open(os.path.join(ROOT, 'assets/icon/icon_foreground.png')).convert('RGBA')
mark = mark.crop(mark.getchannel('A').getbbox())


def canvas(size, background):
    return Image.new('RGBA', size, background)


def with_mark(size, height_fraction, background=(0, 0, 0, 0)):
    img = canvas(size, background)
    h = round(size[1] * height_fraction)
    w = round(mark.width * h / mark.height)
    scaled = mark.resize((w, h), Image.LANCZOS)
    img.alpha_composite(scaled, ((size[0] - w) // 2, (size[1] - h) // 2))
    return img


def save(img, *parts, opaque=False):
    path = os.path.join(CATALOG, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    (img.convert('RGB') if opaque else img).save(path)


# Layered icons: a flat background, an empty middle layer (kept for the parallax stack) and the mark in front.
for name, (w, h) in {'Large': (1280, 768), 'Small': (400, 240)}.items():
    lower = name.lower()
    for scale, suffix in ((1, ''), (2, '@2x')):
        size = (w * scale, h * scale)
        stack = f'App Icon - {name}.imagestack'
        save(canvas(size, BLUE), stack, 'Back.imagestacklayer', 'Content.imageset', f'{lower}_back{suffix}.png', opaque=True)
        save(canvas(size, (0, 0, 0, 0)), stack, 'Middle.imagestacklayer', 'Content.imageset', f'{lower}_middle{suffix}.png')
        save(with_mark(size, 0.577), stack, 'Front.imagestacklayer', 'Content.imageset', f'{lower}_front{suffix}.png')

# Top shelf: the same blue with the mark, normal and wide.
for folder, stem, (w, h) in (
    ('Top Shelf Image.imageset', 'top_shelf', (1920, 720)),
    ('Top Shelf Image Wide.imageset', 'top_shelf_wide', (2320, 720)),
):
    for scale, suffix in ((1, ''), (2, '@2x')):
        save(with_mark((w * scale, h * scale), 0.5, BLUE), folder, f'{stem}{suffix}.png', opaque=True)
print('tvOS brand assets written')
