#!/usr/bin/env python3
"""Mockups of the browser research (docs/research/browser.md), rendered to PNG.

Reuses the tokens, components, icon sheet and renderer of the Claude Desktop UI research, so both
sets stay in one design system. `src/<name>.html` fragments become `<name>.html` here, then
`png/<name>-{light,dark}.png` through headless Chrome.

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
base.HEAD = base.HEAD.replace('href="tokens.css"', 'href="../claude-desktop-ui/mockups/tokens.css"').replace(
    'href="ui.css"', 'href="../claude-desktop-ui/mockups/ui.css"')
base.ICONS.update({
    "back": '<path d="M10 3L5 8l5 5"/>',
    "fwd": '<path d="M6 3l5 5-5 5"/>',
    "camera": '<path d="M2.5 5h2.5l1.2-1.5h3.6L11 5h2.5v7.5h-11z"/><circle cx="8" cy="8.5" r="2.2"/>',
    "split": '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M8 3v10"/>',
    "robot": '<rect x="3" y="5" width="10" height="8" rx="2"/><path d="M8 2.5V5M6 9h.1M10 9h.1"/>',
    "shield": '<path d="M8 2l5 2v4c0 3-2.2 5.2-5 6-2.8-.8-5-3-5-6V4z"/>',
})

if __name__ == "__main__":
    pages = base.build()
    if "--html" not in sys.argv:
        base.render(pages)
