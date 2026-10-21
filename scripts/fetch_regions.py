#!/usr/bin/env python3
"""Fetch the official municipality -> region (kunta -> maakunta) table from Statistics Finland.

Retkikartta gives each hunting area a region per municipality, but some of those are
out of date (e.g. Heinävesi, Joroinen and Kuhmoinen changed region in 2021).
build_web_data.py uses this table instead, falling back to Retkikartta for any
municipality it does not know.

Source: Tilastokeskus classification service, correspondence table
kunta_1_<year>0101#maakunta_1_<year>0101 (CC BY 4.0).

Output: data/kunta_maakunta.csv with columns
  municipality_code, municipality, region_code, region

Standard library only (Python 3.9+).
"""
from __future__ import annotations

import argparse
import csv
import datetime
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "data" / "kunta_maakunta.csv"
API = "https://data.stat.fi/api/classifications/v2/correspondenceTables/{table}/maps"
FIELDS = ["municipality_code", "municipality", "region_code", "region"]


def table_url(year: int) -> str:
    table = urllib.parse.quote(f"kunta_1_{year}0101#maakunta_1_{year}0101", safe="")
    return API.format(table=table) + "?content=data&meta=max&lang=fi&format=json"


def item_name(item: dict, lang: str = "fi") -> str:
    names = item["classificationItemNames"]
    return next((n["name"] for n in names if n.get("lang") == lang), names[0]["name"])


def parse_table(data: list[dict]) -> list[dict]:
    rows = [{
        "municipality_code": r["sourceItem"]["code"],
        "municipality": item_name(r["sourceItem"]),
        "region_code": r["targetItem"]["code"],
        "region": item_name(r["targetItem"]),
    } for r in data]
    return sorted(rows, key=lambda r: r["municipality_code"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--year", type=int, default=datetime.date.today().year,
                    help="classification year (default: this year)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"CSV to write (default: {DEFAULT_OUT.relative_to(REPO)})")
    args = ap.parse_args()

    url = table_url(args.year)
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            data = json.load(r)
    except (urllib.error.URLError, TimeoutError) as e:
        sys.exit(f"GET failed: {url}\n  {e}\nThe {args.year} table may not be published yet; try --year {args.year - 1}.")
    rows = parse_table(data)
    if not rows:
        sys.exit(f"Empty table for {args.year}; try --year {args.year - 1}.")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} municipalities in {len({r['region'] for r in rows})} regions ({args.year}) -> {args.out}")


if __name__ == "__main__":
    main()
