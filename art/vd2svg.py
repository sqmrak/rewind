#!/usr/bin/env python3
# android vector drawable to a white svg mask; convert() returns None for what is not a flat one-colour vector
import re, sys, xml.etree.ElementTree as ET
A = '{http://schemas.android.com/apk/res/android}'

def num(v, default=0.0):
    if v is None: return default
    m = re.match(r'^\s*(-?[0-9.]+)', v)
    return float(m.group(1)) if m else default

def mono(color):
    """True when the paint is a tint-able single colour (white, black, theme attribute); False for real colours"""
    if color is None: return True
    c = color.strip().lower()
    if c.startswith('?') or c.startswith('@android:color/white') or c.startswith('@android:color/black') \
       or c.startswith('@android:color/transparent'): return True
    if c.startswith('@'): return None
    m = re.match(r'^#([0-9a-f]{3,8})$', c)
    if not m: return None
    h = m.group(1)
    if len(h) in (3, 4): h = ''.join(x * 2 for x in h)
    rgb = h[-6:]
    return rgb in ('000000', 'ffffff') or None

def convert(path):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    if root.tag != 'vector': return None
    vw = num(root.get(A + 'viewportWidth')); vh = num(root.get(A + 'viewportHeight'))
    if vw <= 0 or vh <= 0: return None
    out = []
    ok = [True]

    def walk(node):
        parts = []
        for el in node:
            if el.tag == 'group':
                px, py = num(el.get(A + 'pivotX')), num(el.get(A + 'pivotY'))
                tx, ty = num(el.get(A + 'translateX')), num(el.get(A + 'translateY'))
                sx, sy = num(el.get(A + 'scaleX'), 1), num(el.get(A + 'scaleY'), 1)
                rot = num(el.get(A + 'rotation'))
                t = 'translate(%g %g) translate(%g %g) rotate(%g) scale(%g %g) translate(%g %g)' % (tx, ty, px, py, rot, sx, sy, -px, -py)
                parts.append('<g transform="%s">%s</g>' % (t, walk(el)))
            elif el.tag == 'clip-path':
                ok[0] = False
            elif el.tag == 'path':
                d = el.get(A + 'pathData')
                if not d: continue
                fill, stroke = el.get(A + 'fillColor'), el.get(A + 'strokeColor')
                if mono(fill) is None or mono(stroke) is None: ok[0] = False
                attrs = ['d="%s"' % d]
                if fill is None and stroke is None:
                    attrs.append('fill="#fff"')
                else:
                    attrs.append('fill="%s"' % ('#fff' if fill is not None and not fill.lower().startswith('@android:color/transparent') else 'none'))
                    fa = num(el.get(A + 'fillAlpha'), 1)
                    if fa != 1: attrs.append('fill-opacity="%g"' % fa)
                if stroke is not None:
                    attrs.append('stroke="#fff" stroke-width="%g"' % num(el.get(A + 'strokeWidth'), 1))
                    for k, s in (('strokeLineCap', 'stroke-linecap'), ('strokeLineJoin', 'stroke-linejoin')):
                        if el.get(A + k): attrs.append('%s="%s"' % (s, el.get(A + k)))
                    sa = num(el.get(A + 'strokeAlpha'), 1)
                    if sa != 1: attrs.append('stroke-opacity="%g"' % sa)
                if el.get(A + 'fillType') == 'evenOdd': attrs.append('fill-rule="evenodd"')
                parts.append('<path %s/>' % ' '.join(attrs))
            else:
                ok[0] = False
        return ''.join(parts)

    body = walk(root)
    if not ok[0] or not body: return None
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %g %g" width="%g" height="%g">%s</svg>' % (vw, vh, vw, vh, body)

if __name__ == '__main__':
    svg = convert(sys.argv[1])
    if svg is None: sys.exit(1)
    print(svg)
