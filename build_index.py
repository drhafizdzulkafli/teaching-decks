#!/usr/bin/env python3
"""
Scan the decks/ folder and refresh the deck list inside index.html.

Usage:
    python3 build_index.py            # rebuild once
    python3 build_index.py --watch    # keep running; rebuild whenever decks/ changes

No extra packages needed (standard library only).

How each deck's card is filled in (first match wins):
  1. A sidecar JSON file next to the deck with the same name,
     e.g. decks/Trauma/Primary Survey.pptx  +  decks/Trauma/Primary Survey.json
     (for a folder deck, put deck.json inside the folder)
  2. Information inside the file itself:
       - .html  -> <title>, <meta name="description">, <meta name="deck:category|audience|date|tags">
       - .pptx  -> File > Properties (Title, Subject/Comments, Keywords, Created date)
  3. Sensible guesses: title from the file name, category from the sub-folder
     name, date from when the file was created.

Sidecar JSON fields (all optional):
  {
    "title": "Sepsis: Early Recognition",
    "category": "Resuscitation",
    "audience": "Undergraduate (Year 5)",
    "date": "2026-09-12",
    "summary": "One or two sentences about the session.",
    "tags": ["sepsis", "qSOFA"]
  }
"""
from __future__ import annotations

import json
import re
import sys
import time
import zipfile
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent
DECKS = ROOT / "decks"
INDEX = ROOT / "index.html"

DECK_EXTS = {".html", ".htm", ".pdf", ".pptx", ".ppt", ".key", ".odp"}
START = "<!-- DECKS:START"
END = "<!-- DECKS:END -->"


# ---------- metadata readers ----------

class _HtmlMeta(HTMLParser):
    def __init__(self):
        super().__init__()
        self.meta: dict[str, str] = {}
        self._in_title = False
        self.title = ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title":
            self._in_title = True
        elif tag == "meta" and a.get("name") and a.get("content") is not None:
            self.meta[a["name"].lower()] = a["content"].strip()

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def read_html(path: Path) -> dict:
    p = _HtmlMeta()
    try:
        p.feed(path.read_text(encoding="utf-8", errors="ignore")[:200_000])
    except Exception:
        return {}
    m = p.meta
    out = {
        "title": p.title.strip(),
        "summary": m.get("description", ""),
        "category": m.get("deck:category", ""),
        "audience": m.get("deck:audience", ""),
        "date": m.get("deck:date", ""),
        "tags": m.get("deck:tags", "") or m.get("keywords", ""),
    }
    return {k: v for k, v in out.items() if v}


def read_pptx(path: Path) -> dict:
    ns = {
        "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
        "dc": "http://purl.org/dc/elements/1.1/",
        "dcterms": "http://purl.org/dc/terms/",
    }
    try:
        with zipfile.ZipFile(path) as z:
            root = ET.fromstring(z.read("docProps/core.xml"))
    except Exception:
        return {}

    def get(tag):
        el = root.find(tag, ns)
        return (el.text or "").strip() if el is not None and el.text else ""

    out = {
        "title": get("dc:title"),
        "summary": get("dc:description") or get("dc:subject"),
        "tags": get("cp:keywords"),
        "category": get("cp:category"),
        "date": get("dcterms:created")[:10],
    }
    return {k: v for k, v in out.items() if v}


def read_sidecar(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"  ! could not read {path.relative_to(ROOT)}: {e}")
        return {}


# ---------- helpers ----------

def pretty_title(stem: str) -> str:
    s = re.sub(r"^\d{4}[-_.]\d{2}[-_.]\d{2}[ _-]*", "", stem)  # drop leading dates
    s = re.sub(r"[_-]+", " ", s).strip()
    return s[:1].upper() + s[1:] if s else stem


def file_date(path: Path) -> str:
    st = path.stat()
    ts = getattr(st, "st_birthtime", None) or st.st_mtime
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def norm_tags(v) -> list[str]:
    if isinstance(v, str):
        v = re.split(r"[,;]", v)
    return [t.strip() for t in (v or []) if str(t).strip()]


def norm_date(v: str, fallback: str) -> str:
    v = (v or "").strip()[:10]
    return v if re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) else fallback


# ---------- scan ----------

def find_decks() -> list[tuple[Path, Path, Path]]:
    """Return (deck_path, open_target, sidecar) tuples."""
    found = []
    if not DECKS.exists():
        return found
    folder_decks = set()
    for idx in DECKS.rglob("index.html"):
        if any(part.startswith(".") for part in idx.relative_to(DECKS).parts):
            continue
        folder = idx.parent
        if folder == DECKS:
            continue
        folder_decks.add(folder)
        found.append((folder, idx, folder / "deck.json"))
    for f in sorted(DECKS.rglob("*")):
        rel = f.relative_to(DECKS)
        if any(part.startswith((".", "~$")) for part in rel.parts):
            continue
        if not f.is_file() or f.suffix.lower() not in DECK_EXTS:
            continue
        if any(folder in f.parents or folder == f.parent for folder in folder_decks):
            continue
        found.append((f, f, f.with_suffix(".json")))
    return found


def build_entry(deck: Path, target: Path, sidecar: Path) -> dict:
    ext = target.suffix.lower()
    embedded = read_html(target) if ext in {".html", ".htm"} else read_pptx(target) if ext == ".pptx" else {}
    meta = {**embedded, **read_sidecar(sidecar)}

    rel = deck.relative_to(DECKS)
    folder_cat = rel.parts[0] if len(rel.parts) > 1 else ""
    if deck.is_dir() and len(rel.parts) == 1:
        folder_cat = ""
    name = deck.name if deck.is_dir() else deck.stem

    return {
        "title": str(meta.get("title") or pretty_title(name)),
        "category": str(meta.get("category") or folder_cat or "General"),
        "audience": str(meta.get("audience") or ""),
        "date": norm_date(meta.get("date", ""), file_date(target)),
        "summary": str(meta.get("summary") or ""),
        "tags": norm_tags(meta.get("tags")),
        "type": "WEB" if ext in {".html", ".htm"} else ext.lstrip(".").upper(),
        "file": str(rel),
        "href": quote(target.relative_to(ROOT).as_posix()),
    }


def build() -> int:
    if not INDEX.exists():
        sys.exit(f"index.html not found at {INDEX}")
    page = INDEX.read_text(encoding="utf-8")
    s, e = page.find(START), page.find(END)
    if s == -1 or e == -1:
        sys.exit("index.html is missing the DECKS:START / DECKS:END markers.")

    decks = [build_entry(*d) for d in find_decks()]
    decks.sort(key=lambda d: d["date"], reverse=True)
    payload = {"generated": datetime.now().strftime("%d %b %Y, %H:%M"), "decks": decks}
    data = json.dumps(payload, indent=1, ensure_ascii=False).replace("</", "<\\/")

    block = (
        "<!-- DECKS:START — this block is rewritten by build_index.py; edit decks, not this JSON -->\n"
        f'<script id="deck-data" type="application/json">\n{data}\n</script>\n'
    )
    INDEX.write_text(page[:s] + block + page[e:], encoding="utf-8")
    print(f"✓ index.html updated with {len(decks)} deck(s)")
    return len(decks)


def snapshot() -> tuple:
    if not DECKS.exists():
        return ()
    return tuple(sorted(
        (str(p), p.stat().st_mtime) for p in DECKS.rglob("*")
        if p.is_file() and not p.name.startswith((".", "~$"))
    ))


def watch(interval: float = 2.0):
    print(f"Watching {DECKS.relative_to(ROOT)}/ for changes (Ctrl+C to stop)…")
    last = None
    while True:
        snap = snapshot()
        if snap != last:
            if last is not None:
                print(time.strftime("[%H:%M:%S] change detected"), end=" → ")
            build()
            last = snap
        time.sleep(interval)


if __name__ == "__main__":
    DECKS.mkdir(exist_ok=True)
    if "--watch" in sys.argv:
        try:
            watch()
        except KeyboardInterrupt:
            print("\nStopped.")
    else:
        build()
