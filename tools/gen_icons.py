"""Generates every OpenSpeak icon (app, tray, Windows .ico, Android mipmaps)."""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024


def gradient(size, c1, c2):
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img


def glyph(draw, s, color=(255, 255, 255), wave=True):
    """Microphone capsule + holder + stand, with optional sound waves."""
    cx = s / 2
    w = s * 0.115
    top, bot = s * 0.17, s * 0.55
    draw.rounded_rectangle([cx - w, top, cx + w, bot], radius=w, fill=color)
    lw = max(2, int(s * 0.042))
    hw = w * 1.85
    draw.arc([cx - hw, s * 0.30, cx + hw, s * 0.66], 0, 180, fill=color, width=lw)
    draw.line([cx, s * 0.655, cx, s * 0.78], fill=color, width=lw)
    draw.rounded_rectangle([cx - s * 0.13, s * 0.78 - lw / 2, cx + s * 0.13, s * 0.78 + lw / 2],
                           radius=lw / 2, fill=color)
    if wave:
        cy = s * 0.40
        for k, r in enumerate([0.31, 0.40]):
            box = [cx - s * r, cy - s * r, cx + s * r, cy + s * r]
            a = (255, 255, 255, 190 - k * 80)
            draw.arc(box, -32, 32, fill=a, width=lw)
            draw.arc(box, 148, 212, fill=a, width=lw)


def app_icon(size=S, pad=0.0):
    base = gradient(size, (91, 91, 214), (142, 78, 198)).convert('RGBA')
    mask = Image.new('L', (size, size), 0)
    m = int(size * pad)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, size - m, size - m], radius=int(size * 0.23), fill=255)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    glyph(ImageDraw.Draw(layer), size)
    out.alpha_composite(layer)
    return out


def tray_icon(rec=False, size=64):
    img = Image.new('RGBA', (size * 4, size * 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size * 4
    d.ellipse([0, 0, s - 1, s - 1], fill=(229, 72, 77) if rec else (91, 91, 214))
    glyph(d, s, wave=False)
    return img.resize((size, size), Image.LANCZOS)


def save(img, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print('wrote', os.path.relpath(path, ROOT))


icon = app_icon()
save(icon, 'assets', 'icon.png')
save(icon.resize((512, 512), Image.LANCZOS), 'docs', 'assets', 'icon.png')
save(icon.resize((256, 256), Image.LANCZOS), 'linux', 'runner', 'openspeak.png')
icon.save(os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico'),
          sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
for rec in (False, True):
    t = tray_icon(rec)
    name = 'tray_rec' if rec else 'tray'
    save(t, 'assets', 'tray', name + '.png')
    t.save(os.path.join(ROOT, 'assets', 'tray', name + '.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64)])

# Android launcher icons (legacy square-ish) and bubble asset.
dens = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
small = app_icon(S, pad=0.06)
for k, px in dens.items():
    save(small.resize((px, px), Image.LANCZOS), 'android', 'app', 'src', 'main', 'res', f'mipmap-{k}', 'ic_launcher.png')
