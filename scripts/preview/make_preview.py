#!/usr/bin/env python3
"""Generates the README preview: docs/preview/journey.svg (animated) and
docs/preview/steps.html (static strip, rendered to steps.png by render.sh).

Mock-ups mirror the app's real island: black, concave "ears" into the menu bar,
square top / rounded bottom, 24pt controls, same copy. Sample content is fictional.
"""
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "docs" / "preview"
W, H = 720, 360            # one frame
K = 1.5                    # scene zoom so island text is legible on GitHub
MENU = 30                  # menu bar height (at 1x)
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
ACCENT, RED, GREEN = "#0A84FF", "#FF453A", "#30D158"


def island(width, height, bottom_radius, inner="", cx=W / 2):
    """Black island hanging from the menu bar, with concave ears (r=8)."""
    x0, x1, r, br, h = cx - width / 2, cx + width / 2, 8, bottom_radius, height
    path = (f"M{x0 - r},0 L{x1 + r},0 A{r},{r} 0 0 0 {x1},{r} L{x1},{h - br} "
            f"A{br},{br} 0 0 1 {x1 - br},{h} L{x0 + br},{h} A{br},{br} 0 0 1 {x0},{h - br} "
            f"L{x0},{r} A{r},{r} 0 0 0 {x0 - r},0 Z")
    shadow = '<ellipse cx="{}" cy="{}" rx="{}" ry="10" fill="#000" opacity=".35" filter="url(#blur)"/>'.format(
        cx, h + 6, width / 2.3) if height > 40 else ""
    return f'{shadow}<path d="{path}" fill="#000"/>{inner}'


def mic(cx, cy, color="#fff", s=1.0):
    return (f'<g transform="translate({cx},{cy}) scale({s})" fill="none" stroke="{color}" stroke-width="1.6" stroke-linecap="round">'
            f'<rect x="-3" y="-7" width="6" height="10" rx="3" fill="{color}" stroke="none"/>'
            f'<path d="M-5.5,0 a5.5,5.5 0 0 0 11,0"/><path d="M0,5.5 v2.5 M-3,8 h6"/></g>')


def chevron(cx, cy, up=False):
    d = "M-4,2 L0,-2 L4,2" if up else "M-4,-2 L0,2 L4,-2"
    return f'<path transform="translate({cx},{cy})" d="{d}" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'


def waveform(x, cy, animated=True):
    heights = [0.55, 0.8, 1.0, 0.8, 0.55]
    bars = []
    for i, k in enumerate(heights):
        cls = f' class="bar b{i}"' if animated else ""
        h = 14 * k
        bars.append(f'<rect{cls} x="{x + i * 4.5:.1f}" y="{cy - h / 2:.1f}" width="2.5" height="{h:.1f}" rx="1.25" fill="{RED}"/>')
    return "".join(bars)


def spinner(cx, cy, r=7, animated=True):
    cls = ' class="spin"' if animated else ""
    ticks = "".join(
        f'<line x1="0" y1="{-r * 0.45:.1f}" x2="0" y2="{-r:.1f}" stroke="#fff" stroke-width="1.6" stroke-linecap="round" '
        f'opacity="{0.25 + 0.75 * i / 7:.2f}" transform="rotate({i * 45})"/>' for i in range(8))
    return f'<g transform="translate({cx},{cy})"><g{cls}>{ticks}</g></g>'


def text(x, y, s, size=13, weight=400, fill="#fff", opacity=1, anchor="start"):
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" fill-opacity="{opacity}" text-anchor="{anchor}">{s}</text>')


def pill(x, y, w, label, prominent=False):
    bg = ACCENT if prominent else "#fff"
    op = 1 if prominent else 0.12
    return (f'<rect x="{x}" y="{y}" width="{w}" height="26" rx="13" fill="{bg}" fill-opacity="{op}"/>'
            + text(x + w / 2, y + 17.5, label, 12, 600, anchor="middle"))


def check(cx, cy, r=7):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{GREEN}"/>'
            f'<path d="M{cx - 3.2},{cy + .2} l2.2,2.2 l4.2,-4.4" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>')


def zoom(svg, k=K):
    """Scale the menu-bar scene around the top centre (the notch)."""
    return f'<g transform="translate({W / 2},0) scale({k}) translate({-W / 2},0)">{svg}</g>'


# ---------------------------------------------------------------- frames
EW = 330                      # expanded width
EX0 = W / 2 - EW / 2          # expanded left edge


def radio(cx, cy, on):
    if on:
        return (f'<circle cx="{cx}" cy="{cy}" r="7.25" fill="none" stroke="{ACCENT}" stroke-width="1.5"/>'
                f'<circle cx="{cx}" cy="{cy}" r="4" fill="{ACCENT}"/>')
    return f'<circle cx="{cx}" cy="{cy}" r="7.25" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="1.5"/>'


def glyph(kind, cx, cy):
    """Tiny stand-ins for the SF Symbols the rows use."""
    st = 'fill="none" stroke="#fff" stroke-opacity=".75" stroke-width="1.3" stroke-linejoin="round" stroke-linecap="round"'
    if kind == "notion":
        return (f'<rect x="{cx - 6}" y="{cy - 6}" width="12" height="12" rx="2.5" {st}/>'
                + text(cx, cy + 3.5, "N", 9, 700, opacity=.75, anchor="middle"))
    if kind == "clipboard":
        return (f'<rect x="{cx - 5}" y="{cy - 5.5}" width="10" height="12" rx="2" {st}/>'
                f'<rect x="{cx - 2.5}" y="{cy - 7}" width="5" height="3" rx="1" {st}/>')
    lines = "".join(f'<path d="M{cx - 2.5},{cy - 1 + i * 2.6} h5" {st}/>' for i in range(3 if kind == "md" else 2))
    return f'<path d="M{cx - 4.5},{cy - 6.5} h6 l3,3 v10 h-9 z" {st}/>' + lines


def f_choose(anim=True):
    """Outputs page: 'Send notes to' with the four destinations."""
    x, y = EX0 + 4, 32
    rows = [("notion", "Notion", None, True, None),
            ("gdocs", "Google Docs", "Folder: Meeting Notes", False, None),
            ("md", "Markdown file", "Folder: Meeting notes", False, "Directory"),
            ("clipboard", "Copy to clipboard", None, False, None)]
    inner = mic(EX0 + 16, 16) + chevron(EX0 + EW - 16, 16, up=True)
    inner += f'<text x="{x + 8}" y="{y + 16}" font-family="{FONT}" font-size="10" font-weight="600" letter-spacing="0.6" fill="#fff" fill-opacity=".45">SEND NOTES TO</text>'
    ry = y + 26
    for kind, title, cap, on, accessory in rows:
        h = 40 if cap else 32
        mid = ry + h / 2
        inner += radio(x + 16, mid, on) + glyph(kind, x + 43, mid)
        if cap:
            inner += text(x + 62, mid - 2, title, 13, 500) + text(x + 62, mid + 12, cap, 11, 400, opacity=.5)
        else:
            inner += text(x + 62, mid + 4.5, title, 13, 500)
        if accessory:
            inner += (f'<rect x="{EX0 + EW - 12 - 70}" y="{mid - 11}" width="70" height="22" rx="11" fill="#fff" fill-opacity=".12"/>'
                      + text(EX0 + EW - 12 - 35, mid + 4, accessory, 11, 600, opacity=.85, anchor="middle"))
        ry += h + 4
    return zoom(island(EW, ry + 8, 20, inner), 1.1)


def f_idle(anim=True):
    cw = 250
    x0 = W / 2 - cw / 2
    return zoom(island(cw, 32, 12, mic(x0 + 16, 16) + chevron(x0 + cw - 16, 16)))


def f_recording(anim=True):
    cw = 290
    x0 = W / 2 - cw / 2
    right = (f'<circle cx="{x0 + cw - 66}" cy="16" r="3" fill="{RED}"' + (' class="blink"' if anim else "") + '/>'
             + text(x0 + cw - 11, 20.5, "12:48", 13, 600, opacity=.92, anchor="end"))
    return zoom(island(cw, 32, 12, waveform(x0 + 15, 16, anim) + right))


def f_processing(anim=True):
    inner = (spinner(EX0 + 16, 16, 5.5, anim) + chevron(EX0 + EW - 16, 16, up=True)
             + spinner(EX0 + 20, 32 + 18, 7, anim) + text(EX0 + 36, 32 + 23, "Combining 6 parts…", 14, 600))
    return zoom(island(EW, 32 + 40, 20, inner))


def f_review(anim=True):
    y = 32
    inner = (mic(EX0 + 16, 16) + chevron(EX0 + EW - 16, 16, up=True)
             + check(EX0 + 19, y + 16) + text(EX0 + 34, y + 21, "Notes ready", 14, 600)
             + text(EX0 + 34, y + 40, "Q3 Launch Planning", 12, 400, opacity=.75)
             + text(EX0 + 34, y + 56, "7 key points · 3 action items · 2 decisions", 11, 400, opacity=.45)
             + pill(EX0 + 12, y + 70, 74, "Discard")
             + pill(EX0 + EW - 12 - 132, y + 70, 132, "Upload to Notion", prominent=True))
    return zoom(island(EW, 32 + 108, 20, inner))


def f_saved(anim=True):
    y = 32
    inner = (mic(EX0 + 16, 16) + chevron(EX0 + EW - 16, 16, up=True)
             + check(EX0 + 19, y + 16) + text(EX0 + 34, y + 21, "Saved to Notion", 14, 600)
             + f'<circle cx="{EX0 + EW - 23}" cy="{y + 16}" r="11" fill="#fff" fill-opacity=".1"/>'
             + f'<path transform="translate({EX0 + EW - 23},{y + 16})" d="M-3,3 L3,-3 M-1.5,-3 H3 V1.5" fill="none" stroke="#fff" stroke-opacity=".75" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>')
    return zoom(island(EW, 32 + 40, 20, inner))


def f_result(anim=True):
    """The minutes as they land in Notion / Google Docs (trimmed to what sells)."""
    cw = 250
    x0c = W / 2 - cw / 2
    x, y, w = W / 2 - 230, 56, 460
    ink = "#1d1d1f"
    def section(yy, title):
        return text(x + 26, yy, title, 13, 700, fill=ink)
    def bullet(yy, s):
        return f'<circle cx="{x + 32}" cy="{yy - 4}" r="2" fill="{ink}"/>' + text(x + 42, yy, s, 12, 400, fill=ink, opacity=.85)
    def todo(yy, s):
        return (f'<rect x="{x + 26}" y="{yy - 10.5}" width="12" height="12" rx="3" fill="none" stroke="{ink}" stroke-opacity=".5" stroke-width="1.2"/>'
                + text(x + 45, yy, s, 12, 400, fill=ink, opacity=.85))
    card = (f'<rect x="{x}" y="{y}" width="{w}" height="206" rx="12" fill="#fff"/>'
            + text(x + 26, y + 34, "Q3 Launch Planning", 19, 700, fill=ink)
            + text(x + 26, y + 53, "Purpose: agree the Q3 beta launch scope and owners.", 11.5, 400, fill=ink, opacity=.5)
            + section(y + 82, "Key Points")
            + bullet(y + 101, "Beta ships to 50 design partners first, public in October.")
            + bullet(y + 120, "Onboarding is the biggest risk; it needs a guided first run.")
            + section(y + 150, "Action Items")
            + todo(y + 169, "Send the revised forecast — Sarah · 21 Nov")
            + todo(y + 188, "Draft the onboarding checklist — Budi · 25 Nov"))
    return card + zoom(island(cw, 32, 12, mic(x0c + 16, 16) + chevron(x0c + cw - 16, 16)))


STEPS = [
    (f_choose, "Pick where notes go, then press record", "Notion · Google Docs · Markdown · clipboard — one free Groq key"),
    (f_recording, "It records the call and your mic", "Meet, Zoom, Teams — Bluetooth headsets too"),
    (f_processing, "Long meetings are summarised as you talk", "Every 10 minutes, in the background"),
    (f_review, "You decide what gets saved", "Upload, or discard for good"),
    (f_saved, "Saved where you work", "One click opens the page"),
    (f_result, "Clean meeting minutes", "Purpose · Key points · Decisions · Action items"),
]

DEFS = f"""<defs>
  <linearGradient id="menubar" x1="0" x2="1"><stop offset="0" stop-color="#5b21b6"/><stop offset="1" stop-color="#7c3aed"/></linearGradient>
  <linearGradient id="desk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1b1b22"/><stop offset="1" stop-color="#0e0e12"/></linearGradient>
  <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="8"/></filter>
</defs>"""


def backdrop():
    m = MENU * K
    icons = "".join(f'<rect x="{W - 34 - i * 30}" y="{m / 2 - 6}" width="14" height="12" rx="3.5" fill="#fff" fill-opacity=".55"/>'
                    for i in range(3))
    return (f'<rect width="{W}" height="{H}" fill="url(#desk)"/>'
            f'<rect width="{W}" height="{m}" fill="url(#menubar)"/>' + icons)


def caption(n, title, sub, y=296):
    dots = "".join(
        f'<circle cx="{W / 2 + (i - (len(STEPS) - 1) / 2) * 14}" cy="{y + 44}" r="3" '
        f'fill="#fff" fill-opacity="{0.9 if i == n - 1 else 0.22}"/>' for i in range(len(STEPS)))
    return (text(W / 2, y, title, 20, 600, anchor="middle")
            + text(W / 2, y + 24, sub, 14, 400, opacity=.55, anchor="middle") + dots)


def css(n, period):
    slot = 100 / n
    rules = []
    for i in range(n):
        a, b = i * slot, (i + 1) * slot
        fade = 1.2
        rules.append(f"@keyframes s{i}{{0%{{opacity:{1 if i == 0 else 0}}}"
                     f"{max(a - fade, 0):.2f}%{{opacity:{1 if i == 0 else 0}}}{a:.2f}%{{opacity:1}}"
                     f"{b - fade:.2f}%{{opacity:1}}{b:.2f}%{{opacity:0}}"
                     f"{'99.9%{opacity:0}100%{opacity:1}' if i == 0 else '100%{opacity:0}'}}}"
                     f".s{i}{{opacity:{1 if i == 0 else 0};animation:s{i} {period}s infinite}}")
    rules.append(".bar{transform-box:fill-box;transform-origin:center;animation:wave .9s ease-in-out infinite}"
                 ".b1{animation-delay:-.2s}.b2{animation-delay:-.45s}.b3{animation-delay:-.1s}.b4{animation-delay:-.6s}"
                 "@keyframes wave{0%,100%{transform:scaleY(.35)}50%{transform:scaleY(1)}}"
                 ".spin{animation:spin 1s steps(8) infinite}@keyframes spin{to{transform:rotate(360deg)}}"
                 ".blink{animation:blink 1s ease-in-out infinite alternate}@keyframes blink{from{opacity:.25}}"
                 "@media (prefers-reduced-motion:reduce){.bar,.spin,.blink{animation:none}}")
    return "".join(rules)


def animated_svg():
    period = 2.6 * len(STEPS)
    frames = "".join(f'<g class="s{i}">{fn(True)}{caption(i + 1, t, s)}</g>' for i, (fn, t, s) in enumerate(STEPS))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
            f'aria-label="Meeting Transcriber: press record in the notch, it records and summarises in the background, '
            f'you choose Upload or Discard, and clean meeting minutes land in Notion or Google Docs.">'
            f'<style>{css(len(STEPS), period)}</style>{DEFS}<clipPath id="c"><rect width="{W}" height="{H}" rx="18"/></clipPath>'
            f'<g clip-path="url(#c)">{backdrop()}{frames}</g></svg>')


def static_svg(fn, n, title, sub):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f'{DEFS}<clipPath id="c"><rect width="{W}" height="{H}" rx="18"/></clipPath>'
            f'<g clip-path="url(#c)">{backdrop()}{fn(False)}{caption(n, title, sub)}</g></svg>')


def steps_html():
    cells = "".join(f'<div class="cell">{static_svg(fn, i + 1, t, s)}</div>' for i, (fn, t, s) in enumerate(STEPS))
    return f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:#ffffff}}
.grid{{display:grid;grid-template-columns:repeat(3,{W}px);gap:24px;padding:24px;width:max-content}}
.cell svg{{display:block;border-radius:18px}}
</style><div class="grid">{cells}</div>"""


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "steps.html").write_text(steps_html())
    print("wrote", OUT / "steps.html")
