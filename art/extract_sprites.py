#!/usr/bin/env python3
"""Writes art/table_sprites.txt from the game's own table sheet (needs Pillow).

usage: extract_sprites.py <Dwarf Fortress folder>

One 32x32 block per sprite, one character per pixel:
  .        transparent
  ~        the floor shadow: shade 0 at half strength
  0-8      a shade of the first ramp of the material's palette
  9, a-h   a shade of the second ramp (9 = shade 0 of it ... h = shade 8)
"""
import os, sys
from PIL import Image

game = sys.argv[1]
sheet = Image.open(os.path.join(game, 'data/vanilla/vanilla_items_graphics/graphics/images/item_table.png')).convert('RGBA').load()
pimg = Image.open(os.path.join(game, 'data/vanilla/vanilla_descriptors_graphics/graphics/images/palettes.png')).convert('RGBA')
pal = [pimg.getpixel((x, 0))[:3] for x in range(18)]
CH = '0123456789abcdefgh'

def nearest(rgb, lo):
    return min(range(lo, lo + 9), key=lambda i: sum((a - b) ** 2 for a, b in zip(pal[i], rgb)))

def char(c, ramp):
    if c[3] == 0:
        return '.'
    if c[3] != 255:
        assert c[:3] == pal[0], c
        return '~'
    # The game looks a pixel's colour up in the default palette and takes the first shade that has
    # it: the outline colour is both shade 0 and shade 9, and is drawn as shade 0.  A colour that
    # is not in the palette (one stray pixel on the stone table) gets the nearest shade of its ramp.
    if c[:3] in pal:
        return CH[pal.index(c[:3])]
    return CH[nearest(c[:3], 9 if ramp == 2 else 0)]

out = ['# made by extract_sprites.py from the game\'s item_table.png; see that script for the characters']
for name, (tx, ty), ramp in (('wood', (0, 0), 1), ('stone', (0, 1), 2), ('metal', (0, 2), 2), ('glass', (0, 3), 2), ('legs', (7, 0), 1)):
    out.append('# ' + name)
    for y in range(32):
        out.append(''.join(char(sheet[tx * 32 + x, ty * 32 + y], ramp) for x in range(32)))
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'table_sprites.txt')
open(path, 'w').write('\n'.join(out) + '\n')
print('wrote', path)
