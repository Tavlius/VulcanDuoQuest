"""Draws the Vulcan Suite add-on icons: a charcoal disc, an ember ring and a white glyph.

    python3 make_icon.py <glyph> <out.tga> [<out.svg>]

Glyphs: stopwatch (GrindWatch), book (RunBook), duo (DuoQuest), anvil (SimBench).
The same shapes go to a 64x64 32-bit TGA (what WoW loads; anti-aliased by 4x4
supersampling, transparent outside the disc) and to an SVG for viewing. Forge
imagery only. No dependencies beyond Python 3.
"""
import math
import struct
import sys

SIZE = 64
CHARCOAL = (0x26, 0x27, 0x2C)
EMBER = (0xE8, 0x79, 0x2B)
WHITE = (0xF4, 0xF1, 0xEC)


# Shapes, in a 64x64 space: ('circle', cx, cy, r), ('ring', cx, cy, r_in, r_out),
# ('poly', [(x, y), ...]), ('capsule', x1, y1, x2, y2, half_width).
def glyph_shapes(name):
    if name == 'stopwatch':
        return [('ring', 32, 35, 11.5, 15), ('poly', [(28.5, 15), (35.5, 15), (35.5, 18.5), (28.5, 18.5)]),
                ('capsule', 32, 18, 32, 21, 1.6), ('capsule', 32, 35, 32, 26, 1.7), ('capsule', 32, 35, 38, 31, 1.5),
                ('circle', 32, 35, 2.4), ('capsule', 43, 22, 46, 19, 1.5)]
    if name == 'book':
        return [('poly', [(13, 22), (30.5, 25), (30.5, 46), (13, 43)]),
                ('poly', [(33.5, 25), (51, 22), (51, 43), (33.5, 46)])]
    if name == 'duo':
        return [('circle', 23, 24, 6), ('circle', 41, 24, 6),
                ('poly', [(13, 47), (15, 37), (19, 33), (27, 33), (31, 37), (32, 47)]),
                ('poly', [(32, 47), (33, 37), (37, 33), (45, 33), (49, 37), (51, 47)])]
    if name == 'anvil':
        return [('poly', [(9, 25), (17, 21), (50, 21), (53, 25), (45, 28.5), (40, 28.5), (40, 35.5), (47, 38), (47, 43),
                          (17, 43), (17, 38), (24, 35.5), (24, 28.5), (19, 28.5)])]
    raise SystemExit('unknown glyph ' + name)


# Dark details drawn over the glyph (page lines on the book).
def detail_shapes(name):
    if name == 'book':
        out = []
        for i, y in enumerate((30, 34.5, 39)):
            out.append(('capsule', 16.5, y - 1.2 + 0.3 * i, 27.5, y + 0.6 + 0.3 * i, 0.9))
            out.append(('capsule', 36.5, y + 0.6 + 0.3 * i, 47.5, y - 1.2 + 0.3 * i, 0.9))
        return out
    return []


def inside(shape, x, y):
    kind = shape[0]
    if kind == 'circle':
        _, cx, cy, r = shape
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    if kind == 'ring':
        _, cx, cy, r1, r2 = shape
        d = (x - cx) ** 2 + (y - cy) ** 2
        return r1 * r1 <= d <= r2 * r2
    if kind == 'capsule':
        _, x1, y1, x2, y2, hw = shape
        dx, dy = x2 - x1, y2 - y1
        t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy or 1)))
        px, py = x1 + t * dx, y1 + t * dy
        return (x - px) ** 2 + (y - py) ** 2 <= hw * hw
    if kind == 'poly':
        pts, hit = shape[1], False
        for i in range(len(pts)):
            (ax, ay), (bx, by) = pts[i], pts[i - 1]
            if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
                hit = not hit
        return hit
    raise ValueError(kind)


def color_at(name, x, y):
    """(r, g, b, a) of one sample point."""
    d = math.hypot(x - 32, y - 32)
    if d > 30:
        return (0, 0, 0, 0)
    if d > 26.5:
        return EMBER + (255,)
    if any(inside(s, x, y) for s in detail_shapes(name)):
        return CHARCOAL + (255,)
    if any(inside(s, x, y) for s in glyph_shapes(name)):
        return WHITE + (255,)
    return CHARCOAL + (255,)


def render(name, ss=4):
    rows = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    r, g, b, a = color_at(name, px + (sx + 0.5) / ss, py + (sy + 0.5) / ss)
                    acc[0] += r * a; acc[1] += g * a; acc[2] += b * a; acc[3] += a
            a = acc[3] / (ss * ss)
            if acc[3]:
                row.append((round(acc[0] / acc[3]), round(acc[1] / acc[3]), round(acc[2] / acc[3]), round(a)))
            else:
                row.append((0, 0, 0, 0))
        rows.append(row)
    return rows


def write_tga(rows, path):
    # Uncompressed true-colour, 32 bits, 8 alpha bits, origin top-left.
    header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    body = bytearray()
    for row in rows:
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(path, 'wb') as f:
        f.write(header + bytes(body))


def svg_shape(s, fill):
    kind = s[0]
    if kind == 'circle':
        return '<circle cx="%g" cy="%g" r="%g" fill="%s"/>' % (s[1], s[2], s[3], fill)
    if kind == 'ring':
        mid, w = (s[3] + s[4]) / 2, s[4] - s[3]
        return '<circle cx="%g" cy="%g" r="%g" fill="none" stroke="%s" stroke-width="%g"/>' % (s[1], s[2], mid, fill, w)
    if kind == 'capsule':
        return '<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="%g" stroke-linecap="round"/>' % (
            s[1], s[2], s[3], s[4], fill, 2 * s[5])
    return '<polygon points="%s" fill="%s"/>' % (' '.join('%g,%g' % p for p in s[1]), fill)


def write_svg(name, path):
    hexc = lambda c: '#%02x%02x%02x' % c
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="256" height="256">',
             '<circle cx="32" cy="32" r="30" fill="%s"/>' % hexc(EMBER), '<circle cx="32" cy="32" r="26.5" fill="%s"/>' % hexc(CHARCOAL)]
    parts += [svg_shape(s, hexc(WHITE)) for s in glyph_shapes(name)]
    parts += [svg_shape(s, hexc(CHARCOAL)) for s in detail_shapes(name)]
    parts.append('</svg>')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(parts) + '\n')


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    glyph = sys.argv[1]
    write_tga(render(glyph), sys.argv[2])
    if len(sys.argv) > 3:
        write_svg(glyph, sys.argv[3])
    print('wrote', ' and '.join(sys.argv[2:]))
