#!/usr/bin/env python3
"""Renders saved command output as terminal captures (PNG, light and dark).

    render-terminal.py <evidence-dir> <out-dir> [name ...]

Every <evidence-dir>/<name>.txt becomes <out-dir>/<name>.light.png and <name>.dark.png.
The text is shown exactly as saved: lines starting with "$ " are the commands that were run,
everything else is their output. Nothing is added, reordered or reformatted, so the picture and
the text file always say the same thing.

Needs Playwright's Chromium, as docs/diagrams/render.py does.
"""
import html
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

THEMES = {
    "light": {"page": "#f4f5f7", "bar": "#e3e6ea", "pane": "#ffffff", "text": "#1b1f24",
              "muted": "#5c6670", "prompt": "#0b6e63", "border": "#c9ced6", "dot": "#b3bac4"},
    "dark": {"page": "#0e1116", "bar": "#232830", "pane": "#161b22", "text": "#e3e8ee",
             "muted": "#9aa4af", "prompt": "#5fd3c4", "border": "#333a44", "dot": "#4a525d"},
}

PAGE = """<!doctype html><meta charset="utf-8">
<style>
  body {{ margin: 0; padding: 18px; background: {page}; }}
  .win {{ width: 1180px; border: 1px solid {border}; border-radius: 10px; overflow: hidden; background: {pane}; }}
  .bar {{ background: {bar}; padding: 9px 14px; font: 600 13px -apple-system, "Segoe UI", sans-serif; color: {muted};
          display: flex; align-items: center; gap: 7px; }}
  .dot {{ width: 11px; height: 11px; border-radius: 50%; background: {dot}; }}
  .title {{ margin-left: 10px; }}
  pre {{ margin: 0; padding: 14px 16px 16px; color: {text}; white-space: pre-wrap; overflow-wrap: anywhere;
         font: 13px/1.5 ui-monospace, "SF Mono", Menlo, Consolas, monospace; tab-size: 4; }}
  .cmd {{ color: {prompt}; font-weight: 600; }}
</style>
<div class="win" id="win">
  <div class="bar"><span class="dot"></span><span class="dot"></span><span class="dot"></span><span class="title">{title}</span></div>
  <pre>{body}</pre>
</div>"""


def body_html(text: str) -> str:
    out = []
    for line in text.rstrip("\n").split("\n"):
        escaped = html.escape(line)
        out.append(f'<span class="cmd">{escaped}</span>' if line.startswith("$ ") else escaped)
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    names = sys.argv[3:] or sorted(p.stem for p in src.glob("*.txt"))
    out.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for name in names:
            text = (src / f"{name}.txt").read_text()
            for theme, colors in THEMES.items():
                page = browser.new_page(viewport={"width": 1220, "height": 400}, device_scale_factor=1.5)
                page.set_content(PAGE.format(title=html.escape(f"{name}.txt"), body=body_html(text), **colors))
                target = out / f"{name}.{theme}.png"
                page.locator("#win").screenshot(path=str(target))
                page.close()
                print(f"wrote {target} ({target.stat().st_size} bytes)")
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
