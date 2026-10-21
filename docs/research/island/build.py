#!/usr/bin/env python3
"""Mockups of the island under the notch (docs/research/island.md), rendered to PNG.

Reuses the tokens, components and renderer of the Claude Desktop UI research, like the browser mockups, so every
set stays in one design system. `src/<name>.html` fragments become `<name>.html` here, then
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
    'href="ui.css"', 'href="../claude-desktop-ui/mockups/ui.css"').replace(
    '<style>{style}</style>', '<link rel="stylesheet" href="island.css">\n<style>{style}</style>')

if __name__ == "__main__":
    pages = base.build()
    if "--html" not in sys.argv:
        base.render(pages)
