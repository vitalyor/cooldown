#!/usr/bin/env python3
"""Writes Cooldown's app icon as an Icon Composer document: Resources/AppIcon.icon.

    python3 scripts/make_icon.py

The artwork is flat, as Apple asks for Liquid Glass icons: no baked shadows, highlights or
background. Depth, glass, specular light, the dark and tinted (mono) looks all come from the
system, set up in icon.json. Open the result in Icon Composer (Xcode > Open Developer Tool) to
fine-tune it; build.sh and the iPhone project compile it with actool.

Back to front:
  1. Background  — a night-blue fill (darker in dark mode).
  2. Track       — the full gauge ring, frosted glass; inside it, the "cooldown" sweep: the spent
                   part of the dial dimmed, like an ability recharging in a game.
  3. Arc         — what is left of the limit: coral (Claude) through violet to cobalt (Codex).
  4. Lead        — the bright point at the end of the arc, the front-most glass piece.
"""
import json, math, os, shutil

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'Resources', 'AppIcon.icon')

C = 512.0          # canvas centre (1024 × 1024, Apple's iPhone/iPad/Mac canvas)
R = 300.0          # ring centre line
W = 104.0          # ring width
LEFT = 0.72        # share of the limit left
START = -90.0      # 12 o'clock, SVG angles (y down, clockwise)
SWEEP = 360.0 * LEFT


def point(angle, radius):
    a = math.radians(angle)
    return C + radius * math.cos(a), C + radius * math.sin(a)


def f(x):
    return f'{x:.2f}'.rstrip('0').rstrip('.')


def svg(body, defs=''):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + (f'<defs>{defs}</defs>' if defs else '') + body + '</svg>\n')


def track():
    ro, ri = R + W / 2, R - W / 2
    d = (f'M{f(C - ro)},{f(C)}a{f(ro)},{f(ro)} 0 1,0 {f(2 * ro)},0a{f(ro)},{f(ro)} 0 1,0 {f(-2 * ro)},0Z'
         f'M{f(C - ri)},{f(C)}a{f(ri)},{f(ri)} 0 1,0 {f(2 * ri)},0a{f(ri)},{f(ri)} 0 1,0 {f(-2 * ri)},0Z')
    return svg(f'<path fill="#FFFFFF" fill-rule="evenodd" d="{d}"/>')


def sweep():
    # The spent part of the dial, from the end of the arc back round to 12 o'clock.
    r = R - W / 2 - 20
    a0, a1 = START + SWEEP, START + 360
    x0, y0 = point(a0, r)
    x1, y1 = point(a1, r)
    large = 1 if a1 - a0 > 180 else 0
    d = f'M{f(C)},{f(C)}L{f(x0)},{f(y0)}A{f(r)},{f(r)} 0 {large},1 {f(x1)},{f(y1)}Z'
    return svg(f'<path fill="#000000" d="{d}"/>')


def arc():
    ro, ri, cap = R + W / 2, R - W / 2, W / 2
    a0, a1 = START, START + SWEEP
    large = 1 if SWEEP > 180 else 0
    os_, oe = point(a0, ro), point(a1, ro)
    ie, is_ = point(a1, ri), point(a0, ri)
    d = (f'M{f(os_[0])},{f(os_[1])}'
         f'A{f(ro)},{f(ro)} 0 {large},1 {f(oe[0])},{f(oe[1])}'
         f'A{f(cap)},{f(cap)} 0 0,1 {f(ie[0])},{f(ie[1])}'
         f'A{f(ri)},{f(ri)} 0 {large},0 {f(is_[0])},{f(is_[1])}'
         f'A{f(cap)},{f(cap)} 0 0,1 {f(os_[0])},{f(os_[1])}Z')
    # Coral at 12 o'clock, violet on the right, cobalt where the arc ends.
    defs = ('<linearGradient id="g" gradientUnits="userSpaceOnUse" x1="560" y1="150" x2="250" y2="760">'
            '<stop offset="0" stop-color="#FF8A5C"/><stop offset="0.5" stop-color="#B57BFF"/>'
            '<stop offset="1" stop-color="#5B8CFF"/></linearGradient>')
    return svg(f'<path fill="url(#g)" d="{d}"/>', defs)


def lead():
    x, y = point(START + SWEEP, R)
    r = W * 0.30
    return svg(f'<circle fill="#FFFFFF" cx="{f(x)}" cy="{f(y)}" r="{f(r)}"/>')


def p3(r, g, b, a=1.0):
    return f'display-p3:{r:.5f},{g:.5f},{b:.5f},{a:.5f}'


def hexp3(value, a=1.0):
    v = int(value.lstrip('#'), 16)
    return p3((v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255, a)


def varied(key, base, **by_appearance):
    """`key` with per-appearance values. Icon Composer reads appearance values only next to an entry
    without an appearance (the default), so the default goes into the same list, not beside it."""
    return {f'{key}-specializations': [{'value': base}] + [{'appearance': a, 'value': v} for a, v in by_appearance.items()]}


def document():
    glass_shadow = {'kind': 'neutral', 'opacity': 0.5}
    return {
        'color-space-for-untagged-svg-colors': 'display-p3',
        **varied('fill', {'automatic-gradient': hexp3('#1D2A66')}, dark={'automatic-gradient': hexp3('#121939')}),
        # Front to back, as Icon Composer lists them in its sidebar.
        'groups': [
            {
                'name': 'Lead',
                'layers': [{'name': '4 Lead', 'image-name': '4-lead.svg', 'glass': True,
                            # Dark mode would dim it to the background; it is the light of the dial.
                            **varied('fill', {'solid': p3(1, 1, 1, 1)}, dark={'solid': p3(1, 0.96, 0.9, 1)})}],
                'lighting': 'individual',
                'specular': True,
                'shadow': glass_shadow,
                'translucency': {'enabled': False, 'value': 0.5},
            },
            {
                'name': 'Arc',
                'layers': [{'name': '3 Arc', 'image-name': '3-arc.svg', 'glass': True}],
                'lighting': 'individual',
                'specular': True,
                'shadow': glass_shadow,
                'translucency': {'enabled': True, 'value': 0.15},
            },
            {
                'name': 'Track',
                'layers': [
                    {'name': '2 Sweep', 'image-name': '2-sweep.svg', 'glass': False, 
                     **varied('opacity', 0.26, dark=0.4), **varied('hidden', False, tinted=True)},
                    {'name': '1 Ring', 'image-name': '1-ring.svg', 'glass': True, 
                     **varied('opacity', 0.22, dark=0.16)},
                ],
                'lighting': 'combined',
                'specular': True,
                'shadow': {'kind': 'neutral', 'opacity': 0.35},
                'translucency': {'enabled': True, 'value': 0.5},
                'blur-material': 0.3,
            },
        ],
        'supported-platforms': {'squares': 'shared'},
    }


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, 'Assets'))
    for name, body in [('1-ring.svg', track()), ('2-sweep.svg', sweep()), ('3-arc.svg', arc()), ('4-lead.svg', lead())]:
        open(os.path.join(OUT, 'Assets', name), 'w').write(body)
    json.dump(document(), open(os.path.join(OUT, 'icon.json'), 'w'), indent=2)
    print('written', os.path.relpath(OUT, ROOT))


if __name__ == '__main__':
    main()
