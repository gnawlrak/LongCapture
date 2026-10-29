#!/usr/bin/env python3
"""Generate local-only Safari/TextEdit acceptance documents, without private content."""
from html import escape
from pathlib import Path
import random

root = Path(__file__).resolve().parent.parent / "build" / "Fixtures"
root.mkdir(parents=True, exist_ok=True)
randomizer = random.Random(20261027)
words = "cedar harbor amber meadow linen copper ocean maple silver compass violet orchard".split()
paragraphs = []
rows = []
for row in range(1, 241):
    identifier = f"{randomizer.getrandbits(40):010X}"
    sentence = " ".join(randomizer.choices(words, k=28))
    paragraph = f"{row:03d} | {identifier} | {sentence}."
    paragraphs.append(paragraph)
    color = f"#{randomizer.randrange(0x202020, 0xB0B0B0):06x}"
    rows.append(f'<p style="border-left-color:{color}"><b>{row:03d} &middot; {identifier}</b><br>{escape(sentence)}.</p>')
(root / "LongCapture-test.txt").write_text("LongCapture non-sensitive test document\n\n" + "\n\n".join(paragraphs) + "\n", encoding="utf-8")
html = """<!doctype html><html lang="en"><meta charset="utf-8"><title>LongCapture Local Test</title>
<style>body{margin:40px auto;max-width:820px;padding:0 32px;font:18px/1.7 Georgia,serif;background:#f7f4ed;color:#202b2c}
h1{font-size:36px}p{border-left:9px solid;padding:12px 18px;margin:0 0 20px;background:white}b{font:16px Menlo,monospace}</style>
<h1>LongCapture local scroll test</h1><div>240 numbered paragraphs. No network requests or private content. Select the paragraph area, excluding browser chrome and scrollbars. Test both directions, reverse visits, slow scrolling and recovery.</div><hr>
""" + "\n".join(rows) + "</html>\n"
(root / "LongCapture-test.html").write_text(html, encoding="utf-8")
cards = "\n".join(f'<section><h2>{index:03d} &middot; {escape(paragraphs[index - 1])}</h2>'
                  f'<p>{escape(paragraphs[index % len(paragraphs)])}</p>'
                  f'<p>{escape(paragraphs[(index + 1) % len(paragraphs)])}</p></section>' for index in range(1, 101))
horizontal = """<!doctype html><html lang="en"><meta charset="utf-8"><title>LongCapture Horizontal Local Test</title>
<style>html{background:#f7f4ed;color:#202b2c}body{display:flex;gap:24px;width:max-content;margin:40px;font:18px/1.6 Georgia,serif}
section{box-sizing:border-box;width:480px;height:540px;padding:24px;background:white;border-top:8px solid #178b80}
h2{font:18px/1.6 Menlo,monospace}p{margin:20px 0}</style>
""" + cards + "</html>\n"
(root / "LongCapture-horizontal-test.html").write_text(horizontal, encoding="utf-8")
print(root)
