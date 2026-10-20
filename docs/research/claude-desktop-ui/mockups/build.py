#!/usr/bin/env python3
"""Assemble the mockup pages and render them to PNG.

Each `src/<name>.html` fragment is wrapped in the shared head (tokens.css, icon symbols,
theme switch) and written next to this file as `<name>.html`. Then every page is
screenshotted in light and dark with headless Chrome into `png/<name>-<theme>.png`.

    python3 build.py          # build + render
    python3 build.py --html   # build only
"""
import pathlib, re, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

ICONS = {
    "chev-d": '<path d="M4 6l4 4 4-4"/>',
    "chev-r": '<path d="M6 4l4 4-4 4"/>',
    "chev-l": '<path d="M10 4L6 8l4 4"/>',
    "terminal": '<path d="M3 4l4 4-4 4M8 12h5"/>',
    "diff": '<path d="M8 2v6M5 5h6M5 12h6"/>',
    "branch": '<circle cx="4" cy="3" r="1.6"/><circle cx="4" cy="13" r="1.6"/><circle cx="12" cy="5" r="1.6"/><path d="M4 4.6v6.8M12 6.6c0 3-8 2-8 4.8"/>',
    "pr": '<circle cx="4" cy="3" r="1.6"/><circle cx="4" cy="13" r="1.6"/><circle cx="12" cy="13" r="1.6"/><path d="M4 4.6v6.8M12 11.4V7a2 2 0 0 0-2-2H8"/><path d="M9.5 3.5L8 5l1.5 1.5"/>',
    "merge": '<circle cx="4" cy="3" r="1.6"/><circle cx="4" cy="13" r="1.6"/><circle cx="12" cy="9" r="1.6"/><path d="M4 4.6v6.8M4 5c0 3 6.4 4 6.4 4"/>',
    "folder": '<path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h3l1.5 1.5h4.5A1.5 1.5 0 0 1 14 6v5.5A1.5 1.5 0 0 1 12.5 13h-9A1.5 1.5 0 0 1 2 11.5z"/>',
    "file": '<path d="M4 2h5l3 3v9H4z"/><path d="M9 2v3h3"/>',
    "doc": '<path d="M4 2h5l3 3v9H4z"/><path d="M9 2v3h3M6 8h4M6 10.5h4"/>',
    "dots": '<circle cx="8" cy="3" r="1.1" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r="1.1" fill="currentColor" stroke="none"/><circle cx="8" cy="13" r="1.1" fill="currentColor" stroke="none"/>',
    "check": '<path d="M3 8.5l3 3 7-7"/>',
    "x": '<path d="M4 4l8 8M12 4l-8 8"/>',
    "clock": '<circle cx="8" cy="8" r="5.5"/><path d="M8 5v3l2 1.5"/>',
    "play": '<path d="M5 3.5v9l7-4.5z"/>',
    "flag": '<path d="M4 14V2.5M4 3h8l-2 3 2 3H4"/>',
    "hand": '<path d="M6 8V3.5a1 1 0 0 1 2 0V8M8 7.5V3a1 1 0 0 1 2 0v5M10 8V4.5a1 1 0 0 1 2 0V10a4 4 0 0 1-4 4H7.5a3 3 0 0 1-2.4-1.2L3 9.5a1 1 0 0 1 1.6-1.2L6 10"/>',
    "search": '<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/>',
    "plug": '<path d="M6 2v3M10 2v3M4 5h8v2a4 4 0 0 1-8 0zM8 11v3"/>',
    "sparkle": '<path d="M8 2l1.4 3.6L13 7l-3.6 1.4L8 12l-1.4-3.6L3 7l3.6-1.4z"/>',
    "tray": '<path d="M2 9h3.5l1 2h3l1-2H14M2 9l1.5-5h9L14 9v4H2z"/>',
    "tag": '<path d="M2 2h6l6 6-6 6-6-6z"/><circle cx="5" cy="5" r="1" fill="currentColor" stroke="none"/>',
    "copy": '<rect x="5" y="5" width="8" height="8" rx="1.5"/><path d="M3 10V4a1 1 0 0 1 1-1h6"/>',
    "ext": '<path d="M7 3H3.5A.5.5 0 0 0 3 3.5v9a.5.5 0 0 0 .5.5h9a.5.5 0 0 0 .5-.5V9M9 3h4v4M13 3L7.5 8.5"/>',
    "archive": '<path d="M2 3h12v3H2zM3 6v7h10V6M6.5 9h3"/>',
    "refresh": '<path d="M13 8a5 5 0 1 1-1.5-3.6M13 2.5V5h-2.5"/>',
    "eye": '<path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>',
    "info": '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M5 6.5h2M5 9.5h2M9 6.5h2.5M9 9.5h2.5"/>',
    "globe": '<circle cx="8" cy="8" r="5.5"/><path d="M2.5 8h11M8 2.5c2 2 2 9 0 11M8 2.5c-2 2-2 9 0 11"/>',
    "laptop": '<rect x="3" y="3.5" width="10" height="6.5" rx="1"/><path d="M1.5 12.5h13"/>',
    "cpu": '<rect x="4" y="4" width="8" height="8" rx="1"/><rect x="6.5" y="6.5" width="3" height="3"/><path d="M6 1.5v2.5M10 1.5v2.5M6 12v2.5M10 12v2.5M1.5 6h2.5M1.5 10h2.5M12 6h2.5M12 10h2.5"/>',
    "asterisk": '<path d="M8 2v12M2.8 5l10.4 6M2.8 11l10.4-6"/>',
    "cursor": '<path d="M3 2.5l10 4.5-4.5 1.5L7 13z"/>',
    "plus": '<path d="M8 3v10M3 8h10"/>',
    "bubble": '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/>',
    "question": '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/><path d="M6.8 6a1.3 1.3 0 1 1 1.9 1.1c-.5.3-.7.6-.7 1.1M8 9.8v.1"/>',
    "warn": '<path d="M8 2.5l6 11H2z"/><path d="M8 7v3M8 11.5v.1"/>',
    "gear": '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.8M8 12.4v1.8M1.8 8h1.8M12.4 8h1.8M3.6 3.6l1.3 1.3M11.1 11.1l1.3 1.3M3.6 12.4l1.3-1.3M11.1 4.9l1.3-1.3"/>',
    "port": '<circle cx="8" cy="8" r="2"/><path d="M8 1.5V6M8 10v4.5M1.5 8H6M10 8h4.5"/>',
    "pin": '<path d="M9.5 2l4.5 4.5-2 .5-2.5 2.5v3L8 11 5 14M8 11L5 8H2l2.5-2.5.5-2z"/>',
    "milestone": '<path d="M3 2v12M3 3h8l2 2.5-2 2.5H3"/>',
    "skills": '<path d="M3 4h10v8H3zM3 7h10M6.5 7v5"/>',
    "model": '<circle cx="8" cy="8" r="2"/><path d="M8 1.8v1.8M8 12.4v1.8M1.8 8h1.8M12.4 8h1.8"/><circle cx="8" cy="8" r="5.5" stroke-dasharray="2 2.5"/>',
    "list": '<path d="M5 4h8M5 8h8M5 12h8M2.5 4h.1M2.5 8h.1M2.5 12h.1"/>',
    "send": '<path d="M2 8l12-5.5L9.5 14 8 9z"/>',
    "shell": '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M4.5 6.5l2 1.5-2 1.5M8 10h3.5"/>',
    "lock": '<rect x="4" y="7" width="8" height="7" rx="1.2"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>',
    "sidebar": '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10"/>',
    "inspector": '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M10 3v10"/>',
    "bolt": '<path d="M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z"/>',
    "box": '<path d="M8 1.5l6 3.2v6.6L8 14.5l-6-3.2V4.7z"/><path d="M2.2 4.8L8 8l5.8-3.2M8 8v6.5"/>',
}


def symbol_sheet():
    body = "".join(
        f'<symbol id="i-{k}" viewBox="0 0 16 16">{v}</symbol>' for k, v in ICONS.items()
    )
    return f'<svg width="0" height="0" style="position:absolute" aria-hidden="true">{body}</svg>'


HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<link rel="stylesheet" href="tokens.css">
<link rel="stylesheet" href="ui.css">
<style>{style}</style>
<script>
  // ?theme=dark renders the Midnight palette; the default is Daylight.
  var q = new URLSearchParams(location.search);
  document.documentElement.dataset.theme = q.get('theme') === 'dark' ? 'dark' : 'light';
</script>
</head>
<body>
{icons}
{body}
</body>
</html>
"""


def build():
    pages = []
    for src in sorted((HERE / "src").glob("*.html")):
        text = src.read_text()
        title = re.search(r"<!--\s*title:\s*(.*?)\s*-->", text).group(1)
        size = re.search(r"<!--\s*size:\s*(\d+)x(\d+)\s*-->", text)
        style = re.search(r"<style>(.*?)</style>", text, re.S)
        body = re.sub(r"<style>.*?</style>", "", text, flags=re.S)
        body = re.sub(r"<!--\s*(title|size):.*?-->\n?", "", body)
        # {i:name} or {i:name:extra classes} is an inline icon from the symbol sheet.
        body = re.sub(
            r"\{i:([\w-]+)(?::([\w -]+))?\}",
            lambda m: f'<svg class="icon {m.group(2) or ""}"><use href="#i-{m.group(1)}"/></svg>',
            body,
        )
        out = HERE / (src.stem + ".html")
        out.write_text(
            HEAD.format(
                title=title,
                style=style.group(1) if style else "",
                icons=symbol_sheet(),
                body=body.strip(),
            )
        )
        pages.append((src.stem, int(size.group(1)), int(size.group(2))))
    return pages


def render(pages):
    png = HERE / "png"
    png.mkdir(exist_ok=True)
    for name, w, h in pages:
        for theme in ("light", "dark"):
            out = png / f"{name}-{theme}.png"
            url = f"file://{HERE}/{name}.html?theme={theme}"
            subprocess.run(
                [
                    CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", f"--window-size={w},{h}",
                    f"--screenshot={out}", url,
                ],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            print("rendered", out.relative_to(HERE))


if __name__ == "__main__":
    pages = build()
    if "--html" not in sys.argv:
        render(pages)
