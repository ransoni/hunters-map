#!/usr/bin/env python3
"""Extract the list of Metsähallitus pienriista-alueet from the Eräluvat PDF.

The PDF ("Metsästysajat Metsähallituksen pienriista-alueilla") is a table where
every area row starts with the 4-digit lupa-alue number used on Eräluvat.fi,
followed by the area name, e.g. "6617 Kukko-Multia".

Output: a CSV with columns  code,name  (default: data/pienriista_alueet.csv).

Text extraction uses `pdftotext` (poppler) if it is installed, otherwise the
`pypdf` Python package.  macOS: `brew install poppler`  or  `pip install pypdf`.
"""
from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "data" / "pienriista_alueet.csv"

# "6617 Kukko-Multia         10.09.-10.11. ..."  -> code, name
# The name ends at the first run of 2+ spaces (column gap) or at end of line.
ROW_RE = re.compile(r"^\s*(\d{4})\s+(\S.*?)(?:\s{2,}|$)")


def pdf_text(pdf: Path) -> str:
    if shutil.which("pdftotext"):
        return subprocess.run(
            ["pdftotext", "-layout", str(pdf), "-"],
            check=True, capture_output=True, text=True,
        ).stdout
    try:
        from pypdf import PdfReader  # type: ignore
    except ImportError:
        sys.exit("Need either `pdftotext` (brew install poppler) or `pip install pypdf`.")
    reader = PdfReader(str(pdf))
    return "\n".join(p.extract_text(extraction_mode="layout") or "" for p in reader.pages)


def parse_areas(text: str) -> list[tuple[str, str]]:
    areas: dict[str, str] = {}
    for line in text.splitlines():
        m = ROW_RE.match(line)
        if not m:
            continue
        code, name = m.group(1), m.group(2).strip()
        # Skip anything that is not a name (e.g. a stray date column).
        if re.match(r"^\d", name):
            continue
        areas.setdefault(code, name)
    return sorted(areas.items())


def find_default_pdf() -> Path:
    # docs/ also holds the kanalintu quota PDFs, so look for the hunting-times PDF by name.
    pdfs = sorted((REPO / "docs").glob("Metsastysajat*.pdf"))
    if not pdfs:
        sys.exit("No Metsastysajat*.pdf found in docs/. Pass the path with --pdf.")
    return pdfs[-1]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pdf", type=Path, help="PDF to read (default: docs/Metsastysajat*.pdf)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"CSV to write (default: {DEFAULT_OUT.relative_to(REPO)})")
    args = ap.parse_args()

    pdf = args.pdf or find_default_pdf()
    areas = parse_areas(pdf_text(pdf))
    if not areas:
        sys.exit(f"No area rows found in {pdf}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["code", "name"])
        w.writerows(areas)
    print(f"{len(areas)} areas from {pdf.name} -> {args.out}")


if __name__ == "__main__":
    main()
