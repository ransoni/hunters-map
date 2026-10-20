#!/usr/bin/env python3
"""Extract kanalintu (grouse) day-permit quotas from the Eräluvat PDFs in docs/.

Metsähallitus sells grouse hunting day permits in two phases, each with its own PDF
("Kanalinnun metsästyksen vuorokausiluvat <year>"):

  phase 1 (June)    total hunting days for sale per area in the first phase
  phase 2 (August)  hunting days for sale from late August, based on the August
                    game counts. Includes days left unsold in phase 1.
                    "Ei lisämyyntiä" = no additional days for the area.

Both tables also give the maximum number of permits valid on the same day.
The phase is detected from the PDF text, so file names do not matter.

Output: data/kanalintu_quotas.csv with columns
  code, name, year, phase1_days, phase1_max_per_day, phase2_days, phase2_max_per_day
"Ei lisämyyntiä" becomes phase2_days = 0. A phase with no PDF is left empty.

Text extraction as in parse_pdf_areas.py: `pdftotext` or the `pypdf` package.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

from parse_pdf_areas import pdf_text

REPO = Path(__file__).resolve().parent.parent
DOCS = REPO / "docs"
DEFAULT_OUT = REPO / "data" / "kanalintu_quotas.csv"
PDF_GLOB = "Kanalintulupien_kiintioet_*.pdf"

NO_EXTRA = "Ei lisämyyntiä"
# "5601     Paltamo        87        7"  /  "1605 Näätämö      Ei lisämyyntiä"
ROW_RE = re.compile(rf"^\s*(\d{{4}})\s+(\S.*?)\s{{2,}}(\d+|{NO_EXTRA})(?:\s+(\d+))?\s*$")
FIELDS = ["code", "name", "year", "phase1_days", "phase1_max_per_day", "phase2_days", "phase2_max_per_day"]


def detect_phase(text: str) -> int:
    t = text.lower()
    if re.search(r"\btoi(nen|sessa) vaihe", t):
        return 2
    if "ensimmäisessä vaiheessa" in t or "kokonaiskiintiö" in t:
        return 1
    raise ValueError("cannot tell whether this is the phase 1 (June) or phase 2 (August) quota PDF")


def detect_year(text: str) -> int | None:
    m = re.search(r"vuorokausiluvat\s+(\d{4})", text, re.I)
    return int(m.group(1)) if m else None


def parse_rows(text: str) -> dict[str, tuple[str, int, int | None]]:
    """code -> (name, days, max_per_day). "Ei lisämyyntiä" -> days 0, max None."""
    rows = {}
    for line in text.splitlines():
        m = ROW_RE.match(line)
        if not m:
            continue
        code, name, days, max_day = m.groups()
        if days == NO_EXTRA:
            rows[code] = (name.strip(), 0, None)
        else:
            rows[code] = (name.strip(), int(days), int(max_day) if max_day else None)
    return rows


def merge(phases: dict[int, dict], year: int | None) -> list[dict]:
    out = []
    for code in sorted(set().union(*phases.values())):
        row = {"code": code, "year": year or ""}
        for n in (1, 2):
            name, days, max_day = phases.get(n, {}).get(code, (None, None, None))
            row["name"] = row.get("name") or name
            row[f"phase{n}_days"] = "" if days is None else days
            row[f"phase{n}_max_per_day"] = "" if max_day is None else max_day
        out.append(row)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdfs", nargs="*", type=Path, help=f"quota PDFs (default: docs/{PDF_GLOB})")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"CSV to write (default: {DEFAULT_OUT.relative_to(REPO)})")
    args = ap.parse_args()

    pdfs = args.pdfs or sorted(DOCS.glob(PDF_GLOB))
    if not pdfs:
        sys.exit(f"No quota PDFs found (docs/{PDF_GLOB}). Pass the paths as arguments.")

    phases: dict[int, dict] = {}
    years = set()
    for pdf in pdfs:
        text = pdf_text(pdf)
        phase = detect_phase(text)
        if phase in phases:
            sys.exit(f"Two phase {phase} PDFs given; pass the ones to use as arguments.")
        phases[phase] = parse_rows(text)
        years.add(detect_year(text))
        print(f"phase {phase}: {len(phases[phase])} areas from {pdf.name}")
    if len(years - {None}) > 1:
        sys.exit(f"PDFs are from different years: {sorted(years - {None})}")
    if not any(phases.values()):
        sys.exit("No quota rows found.")

    rows = merge(phases, next(iter(years - {None}), None))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} areas -> {args.out}")


if __name__ == "__main__":
    main()
