"""Emil Beats icon: the letter E lit on a 5x5 step-sequencer grid.
Writes assets/icon/icon.png (full, 1024) and foreground.png (adaptive icon
foreground, 1024 with safe-zone padding) next to this script's app dir."""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'icon')
E = ["XXXXX",
     "X....",
     "XXXX.",
     "X....",
     "XXXXX"]
ORANGE, ORANGE_HI = (245, 158, 61), (255, 196, 120)
OFF_A, OFF_B = (78, 88, 95), (110, 72, 80)   # FL-like alternate pad groups
BG_TOP, BG_BOT = (44, 52, 58), (24, 29, 33)

def grid(img, x0, y0, size):
    d = ImageDraw.Draw(img)
    cell = size / 5
    gap = cell * 0.14
    r = cell * 0.18
    glow = Image.new('RGBA', img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for row in range(5):
        for col in range(5):
            x, y = x0 + col * cell + gap / 2, y0 + row * cell + gap / 2
            box = [x, y, x + cell - gap, y + cell - gap]
            if E[row][col] == 'X':
                gd.rounded_rectangle([box[0] - 10, box[1] - 10, box[2] + 10, box[3] + 10], r + 10, fill=ORANGE + (150,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(size * 0.035)))
    for row in range(5):
        for col in range(5):
            x, y = x0 + col * cell + gap / 2, y0 + row * cell + gap / 2
            box = [x, y, x + cell - gap, y + cell - gap]
            if E[row][col] == 'X':
                d.rounded_rectangle(box, r, fill=ORANGE)
                # top highlight like a lit pad
                d.rounded_rectangle([box[0] + cell * 0.08, box[1] + cell * 0.07, box[2] - cell * 0.08, box[1] + cell * 0.28],
                                    r * 0.6, fill=ORANGE_HI)
            else:
                d.rounded_rectangle(box, r, fill=OFF_B if col == 4 or row == 4 and col > 2 else OFF_A)

def background():
    bg = Image.new('RGBA', (S, S))
    d = ImageDraw.Draw(bg)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOT)) + (255,))
    return bg

os.makedirs(OUT, exist_ok=True)
# full icon (iOS / macOS / legacy Android): grid fills ~70%
full = background()
grid(full, S * 0.15, S * 0.15, S * 0.70)
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], S * 0.22, fill=255)
rounded = Image.new('RGBA', (S, S), (0, 0, 0, 0))
rounded.paste(full, (0, 0), mask)
full.convert('RGB').save(os.path.join(OUT, 'icon.png'))
rounded.save(os.path.join(OUT, 'icon_rounded.png'))
# adaptive foreground: content inside the 66% safe zone
fg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
grid(fg, S * 0.22, S * 0.22, S * 0.56)
fg.save(os.path.join(OUT, 'foreground.png'))
print('ok')
