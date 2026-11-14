#!/usr/bin/env python3
"""Writes scripts_modinstalled/internal/long-tables/template.lua from art/table_sprites.txt.

usage: make_template.py            write the template
       make_template.py --check    exit 1 if the template on disk is not what would be written

Needs only Python 3.  Everything is drawn in palette shades, not colours (see table_sprites.txt
for the characters, plus 'x' = halfway between shades e and f, 'y' = a quarter of the way
from f to g and 'z' = halfway from f to g), so the script in the game can
paint each material with its own palette.

For each class of material (wood, stone, metal, glass) the template holds:
  S       the game's own table: top sprite over the leg sprite
  L M R   the left end, middle and right end of a joined table.  Where a tile has a neighbour the
          table's edge is replaced by more table top and the leg under it by half a leg, so two
          tiles side by side share one leg that straddles the seam (3 pixels on each tile).
  strip   the surface of the top, rows r0..r1, STRIP pixels long.  A tile at phase p shows the
          32 pixels starting at p * 32, so the surface runs on from tile to tile.  On stone,
          metal and glass it includes the bright lines along the top and bottom edge of the
          top, softened: on one tile they are a highlight, along a long table a hard stripe.
  ends    (stone) extra speckles for the two ends of a joined table, four sets; each is a list of
          {pixels in from the end, row, shade}.
"""
import os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'scripts_modinstalled', 'internal', 'long-tables', 'template.lua')
TILE, PHASES = 32, 16
STRIP = TILE * PHASES
LEG_ROW = 26            # first row of the legs proper; row 25 is the outline under the table top


def read_sprites():
    sprites, name = {}, None
    for line in open(os.path.join(HERE, 'table_sprites.txt')):
        line = line.rstrip('\n')
        if line.startswith('# ') and line[2:] in ('wood', 'stone', 'metal', 'glass', 'legs'):
            name = line[2:]
            sprites[name] = []
        elif name and len(line) == TILE:
            sprites[name].append(line)
    assert all(len(rows) == TILE for rows in sprites.values()) and len(sprites) == 5, 'bad table_sprites.txt'
    return sprites


def single(top, legs):
    """The whole table: the top sprite with the leg sprite showing where the top is clear."""
    return [[t if t != '.' else l for t, l in zip(trow, lrow)] for trow, lrow in zip(top, legs)]


def piece(s, left, right):
    """The table tile with a neighbour on the left and/or right."""
    out = []
    for y in range(TILE):
        row = []
        for x in range(TILE):
            sx = x
            if y < LEG_ROW:
                # the edge (clear pixel, outline / outline, shadow) becomes table top
                if left and x < 3:
                    sx = 15 + x
                if right and x >= 29:
                    sx = 15 + (x - 29)
            else:
                # the leg on that side goes; what is under the middle of the table takes its place
                if left and x < 10:
                    sx = 12 + x
                if right and x >= 22:
                    sx = 12 + (x - 22)
                # and half a leg is put at the seam
                if left and x < 3:
                    sx = 6 + x
                if right and x >= 29:
                    sx = 3 + (x - 29)
            row.append(s[y][sx])
        out.append(row)
    return out


# How far each tile's worth of wood grain is shifted along the board, so no two tiles in a run of
# sixteen show the same grain.
WOOD_SHIFT = [0, 11, 19, 6, 15, 3, 22, 9, 13, 24, 5, 17, 1, 20, 8, 12]


def wood_strip(s):
    r0, r1 = 3, 18
    return r0, r1, [[s[y][3 + (X % TILE + WOOD_SHIFT[X // TILE]) % 26] for X in range(STRIP)] for y in range(r0, r1 + 1)]


def sheen_strip(seed):
    """Metal and glass: slanted streaks of light in uneven groups, as on the game's table, some
    as bright as the game's (g) and some faint (y)."""
    r = random.Random(seed)
    r0, r1 = 2, 20
    s = {(X, y): 'f' for X in range(STRIP) for y in range(r0, r1 + 1)}
    x = r.randrange(8, 16)
    while x < STRIP - 6:
        for _ in range(r.choice([2, 3, 3, 4])):
            w = r.choice([1, 2, 2, 3, 4])
            shade = 'g' if w >= 2 and r.random() < .7 else 'y'
            y0 = r.choice([2, 2, 2, 2, 5, 8])
            y1 = r.choice([21, 21, 21, 21, 17, 13])
            for y in range(y0, y1):
                for d in range(w):
                    s[(x + d - (y - 2)) % STRIP, y] = shade
            x += w + r.choice([1, 1, 2, 3])
        x += r.randrange(7, 15)
    return r0, r1, [[s[X, y] for X in range(STRIP)] for y in range(r0, r1 + 1)]


def stone_strip(seed):
    """Stone: blotches of a few pixels and loose specks, darker than the top."""
    r = random.Random(seed)
    r0, r1 = 3, 18
    s = {(X, y): 'f' for X in range(STRIP) for y in range(r0, r1 + 1)}
    blotch = ['e', 'e', 'e', 'x', 'x', 'f']

    def put(X, y, shade):
        if r0 <= y <= r1 and shade != 'f':
            s[X % STRIP, y] = shade
    for _ in range(11 * PHASES):
        X, y, shade = r.randrange(STRIP), r.randrange(3, 18), r.choice(blotch)
        for dx, dy in r.sample([(0, 0), (1, 0), (0, 1), (1, 1), (2, 0), (2, 1), (-1, 1), (1, 2)], r.choice([2, 3, 4, 5])):
            put(X + dx, y + dy, shade)
    for _ in range(14 * PHASES):
        put(r.randrange(STRIP), r.randrange(3, 19), r.choice(blotch))
    ends = []
    for _ in range(4):
        e = []
        for _ in range(9):
            off, y, shade = min(int(r.expovariate(1 / 3.5)), 13), r.randrange(3, 18), r.choice(['e', 'e', 'e', 'x'])
            for dx, dy in r.sample([(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2), (-1, 1)], r.choice([2, 3, 4])):
                if off + dx >= 0 and r0 <= y + dy <= r1:
                    e.append((off + dx, y + dy, shade))
        for _ in range(10):
            e.append((min(int(r.expovariate(1 / 5)), 16), r.randrange(3, 19), r.choice(['e', 'e', 'x'])))
        ends.append(e)
    return r0, r1, [[s[X, y] for X in range(STRIP)] for y in range(r0, r1 + 1)], ends


# The rows of the bright lines along the top and bottom edge of the table top.
EDGE_ROWS = {'stone': (1, 21), 'metal': (1, 23), 'glass': (1, 23)}


def soft_edges(name, s, r0, r1, strip):
    """Widens a strip to take in the edge rows.  The lines get shades close to the top's own (f);
    the rows between them and the old strip show the middle piece as before."""
    top, bottom = EDGE_ROWS[name]
    middle = piece(s, True, True)
    out = []
    for y in range(top, bottom + 1):
        if y in (top, bottom):
            r = random.Random(40 + y)
            out.append([r.choice('gyyz') for _ in range(STRIP)])
        elif r0 <= y <= r1:
            out.append(strip[y - r0])
        else:
            out.append([middle[y][X % TILE] for X in range(STRIP)])
    return top, bottom, out


def build():
    sprites = read_sprites()
    o = ['-- made by art/make_template.py from art/table_sprites.txt; do not edit', 'return {',
         ' phases=%d,' % PHASES]
    for name in ('wood', 'stone', 'metal', 'glass'):
        s = single(sprites[name], sprites['legs'])
        ends = None
        if name == 'wood':
            r0, r1, strip = wood_strip(s)
        elif name == 'stone':
            r0, r1, strip, ends = stone_strip(2)
        else:
            r0, r1, strip = sheen_strip(5 if name == 'metal' else 9)
        if name in EDGE_ROWS:
            r0, r1, strip = soft_edges(name, s, r0, r1, strip)
        o.append(' %s={r0=%d,r1=%d,' % (name, r0, r1))
        for key, p in (('S', s), ('L', piece(s, False, True)), ('M', piece(s, True, True)), ('R', piece(s, True, False))):
            o.append('  %s="%s",' % (key, ''.join(''.join(row) for row in p)))
        o.append('  strip="%s",' % ''.join(''.join(row) for row in strip))
        if ends:
            o.append('  ends={%s},' % ','.join('{%s}' % ','.join('{%d,%d,"%s"}' % t for t in e) for e in ends))
        o.append(' },')
    o.append('}')
    return '\n'.join(o) + '\n'


if __name__ == '__main__':
    text = build()
    if sys.argv[1:] == ['--check']:
        if not os.path.exists(OUT) or open(OUT).read() != text:
            sys.exit('template.lua is out of date: run art/make_template.py')
        print('template.lua is up to date')
    elif not sys.argv[1:]:
        open(OUT, 'w').write(text)
        print('wrote', os.path.normpath(OUT))
    else:
        sys.exit(__doc__)
