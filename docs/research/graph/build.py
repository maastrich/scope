#!/usr/bin/env python3
"""Mockups of the redesigned Graph sheet (docs/research/graph.md), rendered to PNG.

Reuses the tokens, icons and renderer of the Claude Desktop UI research, like the island mockups, so every set
stays in one design system. `src/<name>.html` fragments become `<name>.html` here, then `png/<name>-{light,dark}.png`
through headless Chrome.

    python3 build.py          # build + render
    python3 build.py --html   # build only
"""
import importlib.util, pathlib, sys

sys.dont_write_bytecode = True  # importing the base build must not leave a __pycache__ in its folder
HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent / "claude-desktop-ui" / "mockups"

spec = importlib.util.spec_from_file_location("base_build", BASE / "build.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

base.HERE = HERE
base.ICONS.update({
    "cards": '<rect x="2" y="2.5" width="5" height="5" rx="1"/><rect x="9" y="2.5" width="5" height="5" rx="1"/><rect x="2" y="9.5" width="5" height="4" rx="1"/><rect x="9" y="9.5" width="5" height="4" rx="1"/>',
    "graph": '<circle cx="4" cy="4" r="1.8"/><circle cx="12" cy="4" r="1.8"/><circle cx="8" cy="12" r="1.8"/><path d="M5.3 5.3l1.9 5M10.7 5.3l-1.9 5M5.8 4h4.4"/>',
    "code": '<path d="M5.5 4.5L2 8l3.5 3.5M10.5 4.5L14 8l-3.5 3.5"/>',
    "stack": '<path d="M8 2l6 3-6 3-6-3z"/><path d="M2 8l6 3 6-3M2 11l6 3 6-3"/>',
    "pencil": '<path d="M10.5 2.5l3 3L6 13H3v-3z"/>',
    "minus": '<path d="M3 8h10"/>',
    "fit": '<path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>',
    "filter": '<circle cx="8" cy="8" r="6"/><path d="M5 6.5h6M6 8.5h4M7 10.5h2"/>',
    "arrow-l": '<path d="M13 8H3M7 4L3 8l4 4"/>',
    "arrow-r": '<path d="M3 8h10M9 4l4 4-4 4"/>',
    "sort": '<path d="M5 6l3-3 3 3"/>',
})
base.HEAD = base.HEAD.replace('href="tokens.css"', 'href="../claude-desktop-ui/mockups/tokens.css"').replace(
    'href="ui.css"', 'href="../claude-desktop-ui/mockups/ui.css"').replace(
    '<style>{style}</style>', '<link rel="stylesheet" href="graph.css">\n<style>{style}</style>')

if __name__ == "__main__":
    pages = base.build()
    if "--html" not in sys.argv:
        base.render(pages)
