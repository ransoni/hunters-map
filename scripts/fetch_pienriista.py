#!/usr/bin/env python3
"""Fetch Metsähallitus pienriista-alue (small-game hunting area) boundaries from Retkikartta.

How it works (no official API exists, this mirrors what the Retkikartta map does):

1. Area list:  GET https://retkikartta-api.anderscloud.com/api/search/?categories=901
   Category 901 = "Pienriista-alue". Names look like "6617 Kukko-Multia"; the
   4-digit prefix is the lupa-alue number used on Eräluvat.fi and in the PDF.
2. Details:    GET .../api/small-game-hunting-areas/<global_id>/
   Municipalities, species, contacts and the extent (EPSG:3067 bbox).
3. Geometry:   WMS GetMap on https://retkikartta-map.anderscloud.com/wms/ with
   LAYERS=selected-feature&global_id=<uuid>&FORMAT=application/vnd.google-earth.kml+xml.
   MapServer returns the full, unsimplified boundary as closed LineStrings in WGS84.
   This script turns those rings back into (Multi)Polygons with holes.

The list of areas to fetch comes from data/pienriista_alueet.csv, which is
generated from the Eräluvat PDF in docs/ by scripts/parse_pdf_areas.py.

Outputs (default under data/):
  pienriista.geojson          all fetched areas, one Feature per area (EPSG:4326)
  areas/<code>.geojson        one file per area
  raw/<code>.json, .kml       cached API responses (re-used unless --refresh)

Standard library only (Python 3.9+).

NOTE: these are undocumented internal Retkikartta endpoints. Eräluvat.fi terms
allow private, non-commercial use only; anything else needs written permission
from Metsähallitus (eraluvat@metsa.fi).
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA = REPO / "data"
AREA_CSV = DATA / "pienriista_alueet.csv"

API = "https://retkikartta-api.anderscloud.com/api/"
WMS = "https://retkikartta-map.anderscloud.com/wms/"
SMALL_GAME_CATEGORY = 901
RETKIKARTTA_URL = "https://www.retkikartta.fi/?featureClass=small-game-hunting-areas&id={id}"
USER_AGENT = "hunters-map/0.1 (private, non-commercial; github.com/ridefree)"

DETAIL_FIELDS = [
    "municipality", "province", "area", "species", "recommended_species",
    "seasonal_permit_species", "daily_permit_species", "reindeer_herding_area",
    "division_area", "usage_restriction",
]


# --------------------------------------------------------------------------- HTTP

class Fetcher:
    def __init__(self, delay: float, retries: int = 3, timeout: float = 60):
        self.delay, self.retries, self.timeout = delay, retries, timeout
        self._last = 0.0

    def get(self, url: str) -> bytes:
        for attempt in range(1, self.retries + 1):
            wait = self.delay - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    return r.read()
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt == self.retries:
                    raise RuntimeError(f"GET failed after {attempt} tries: {url}\n  {e}") from e
                time.sleep(2 ** attempt)
        raise AssertionError("unreachable")

    def json(self, url: str):
        return json.loads(self.get(url))


def api_url(path: str, **params) -> str:
    return API + path + ("?" + urllib.parse.urlencode(params) if params else "")


def kml_url(global_id: str, extent: list[float]) -> str:
    params = {
        "SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap",
        "LAYERS": "selected-feature", "STYLES": "", "global_id": global_id,
        "CRS": "EPSG:3067", "BBOX": ",".join(f"{v:.2f}" for v in extent),
        "WIDTH": "1024", "HEIGHT": "1024", "TRANSPARENT": "true",
        "FORMAT": "application/vnd.google-earth.kml+xml",
    }
    return WMS + "?" + urllib.parse.urlencode(params)


def list_retkikartta_areas(f: Fetcher) -> dict[str, dict]:
    """All pienriista areas in Retkikartta, keyed by 4-digit code."""
    url = api_url("search/", categories=SMALL_GAME_CATEGORY, page_size=500, lang="fi")
    out: dict[str, dict] = {}
    while url:
        page = f.json(url)
        for r in page["results"]:
            if r.get("feature_class") != "small-game-hunting-areas":
                continue
            m = re.match(r"(\d{4})\s+(.*)", r["name"])
            if m:
                out[m.group(1)] = r
        url = page.get("next")
    return out


# --------------------------------------------------------------------------- geometry

Ring = list[tuple[float, float]]


def parse_kml_rings(kml: str) -> list[Ring]:
    """All <coordinates> blocks as rings of (lon, lat); closes and de-duplicates them."""
    rings: list[Ring] = []
    seen: set[frozenset] = set()
    for block in re.findall(r"<coordinates>(.*?)</coordinates>", kml, re.S):
        pts: Ring = []
        for tok in block.split():
            lon, lat = tok.split(",")[:2]
            pt = (float(lon), float(lat))
            if not pts or pts[-1] != pt:
                pts.append(pt)
        if len(pts) < 3:
            continue
        if pts[0] != pts[-1]:
            pts.append(pts[0])
        if len(pts) < 4:
            continue
        key = frozenset(pts)
        if key in seen:
            continue
        seen.add(key)
        rings.append(pts)
    return rings


def signed_area(r: Ring) -> float:
    return 0.5 * sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(r, r[1:]))


def bbox(r: Ring) -> tuple[float, float, float, float]:
    xs, ys = zip(*r)
    return min(xs), min(ys), max(xs), max(ys)


def point_in_ring(p: tuple[float, float], r: Ring) -> bool:
    x, y = p
    inside = False
    for (x1, y1), (x2, y2) in zip(r, r[1:]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def ring_inside(inner: Ring, outer: Ring, ib, ob) -> bool:
    if not (ob[0] <= ib[0] and ob[1] <= ib[1] and ob[2] >= ib[2] and ob[3] >= ib[3]):
        return False
    # Majority vote over a few vertices: robust when rings touch at a vertex.
    step = max(1, (len(inner) - 1) // 5)
    samples = inner[:-1:step][:5]
    return sum(point_in_ring(p, outer) for p in samples) * 2 > len(samples)


def rings_to_polygons(rings: list[Ring]) -> list[list[Ring]]:
    """Even nesting depth = outer ring, odd = hole of the smallest enclosing outer ring."""
    n = len(rings)
    areas = [abs(signed_area(r)) for r in rings]
    boxes = [bbox(r) for r in rings]
    parents: list[list[int]] = [
        [j for j in range(n) if j != i and areas[j] > areas[i]
         and ring_inside(rings[i], rings[j], boxes[i], boxes[j])]
        for i in range(n)
    ]
    depth = [len(p) for p in parents]

    polys: dict[int, list[Ring]] = {}
    for i in range(n):
        if depth[i] % 2 == 0:
            shell = rings[i] if signed_area(rings[i]) > 0 else rings[i][::-1]  # CCW
            polys[i] = [shell]
    for i in range(n):
        if depth[i] % 2 == 1:
            owners = [j for j in parents[i] if depth[j] == depth[i] - 1]
            owner = min(owners, key=lambda j: areas[j])
            hole = rings[i] if signed_area(rings[i]) < 0 else rings[i][::-1]  # CW
            polys[owner].append(hole)
    return [polys[k] for k in sorted(polys, key=lambda k: -areas[k])]


def round_coords(polys: list[list[Ring]], nd: int = 7) -> list:
    return [[[[round(x, nd), round(y, nd)] for x, y in ring] for ring in poly] for poly in polys]


# --------------------------------------------------------------------------- main

def load_area_list(path: Path) -> dict[str, str]:
    if not path.exists():
        sys.exit(f"{path} not found. Run scripts/parse_pdf_areas.py first.")
    with path.open(encoding="utf-8") as fh:
        return {row["code"]: row["name"] for row in csv.DictReader(fh)}


def cached(path: Path, refresh: bool, produce) -> str:
    if path.exists() and not refresh:
        return path.read_text(encoding="utf-8")
    text = produce()
    path.write_text(text, encoding="utf-8")
    return text


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--codes", help="comma-separated area codes to fetch, e.g. 6617,6619 (default: all in the CSV)")
    ap.add_argument("--areas-csv", type=Path, default=AREA_CSV, help="area list (default: data/pienriista_alueet.csv)")
    ap.add_argument("--include-unlisted", action="store_true",
                    help="also fetch areas found in Retkikartta but missing from the PDF list")
    ap.add_argument("--out-dir", type=Path, default=DATA, help="output directory (default: data/)")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests (default: 1.0)")
    ap.add_argument("--refresh", action="store_true", help="ignore cached responses in raw/")
    ap.add_argument("--list", action="store_true", help="only compare the PDF list with Retkikartta, fetch nothing else")
    args = ap.parse_args()

    wanted = load_area_list(args.areas_csv)
    f = Fetcher(delay=args.delay)

    print("Listing pienriista areas in Retkikartta ...")
    rk = list_retkikartta_areas(f)
    print(f"  Retkikartta: {len(rk)} areas, PDF list: {len(wanted)} areas")

    missing = sorted(set(wanted) - set(rk))
    unlisted = sorted(set(rk) - set(wanted))
    renamed = [(c, wanted[c], rk[c]["name"][5:]) for c in sorted(set(wanted) & set(rk))
               if wanted[c].casefold() != rk[c]["name"][5:].casefold()]
    for c in missing:
        print(f"  ! {c} {wanted[c]}: in the PDF but not found in Retkikartta")
    for c in unlisted:
        print(f"  + {rk[c]['name']}: in Retkikartta but not in the PDF"
              + ("" if args.include_unlisted else " (skipped, use --include-unlisted)"))
    for c, a, b in renamed:
        print(f"  ~ {c}: PDF '{a}' vs Retkikartta '{b}'")
    if args.list:
        return

    codes = sorted(set(wanted) & set(rk)) + (unlisted if args.include_unlisted else [])
    if args.codes:
        req = [c.strip() for c in args.codes.split(",") if c.strip()]
        bad = [c for c in req if c not in rk]
        if bad:
            sys.exit(f"Unknown area code(s): {', '.join(bad)}")
        codes = req

    raw = args.out_dir / "raw"
    per_area = args.out_dir / "areas"
    raw.mkdir(parents=True, exist_ok=True)
    per_area.mkdir(parents=True, exist_ok=True)

    features, failed = [], []
    for i, code in enumerate(sorted(codes), 1):
        hit = rk[code]
        label = f"[{i}/{len(codes)}] {hit['name']}"
        try:
            detail = json.loads(cached(raw / f"{code}.json", args.refresh, lambda: f.get(
                api_url(f"small-game-hunting-areas/{hit['global_id']}/", lang="fi")).decode()))
            kml = cached(raw / f"{code}.kml", args.refresh, lambda: f.get(
                kml_url(hit["global_id"], detail["extent"])).decode())
            rings = parse_kml_rings(kml)
            if not rings:
                raise ValueError("no geometry in KML response")
            polys = rings_to_polygons(rings)
        except Exception as e:  # keep going, report at the end
            print(f"{label}: FAILED ({e})")
            failed.append(code)
            continue

        holes = sum(len(p) - 1 for p in polys)
        print(f"{label}: {len(polys)} polygon(s), {holes} hole(s), {sum(map(len, rings))} points")

        props = {
            "code": code,
            "name": wanted.get(code, hit["name"][5:]),
            "retkikartta_name": hit["name"],
            "retkikartta_id": hit["feature_id"],
            "global_id": hit["global_id"],
            "retkikartta_url": RETKIKARTTA_URL.format(id=hit["feature_id"]),
            "in_pdf_list": code in wanted,
            **{k: detail.get(k) for k in DETAIL_FIELDS},
        }
        feature = {
            "type": "Feature",
            "id": code,
            "properties": props,
            "geometry": {"type": "MultiPolygon", "coordinates": round_coords(polys)},
        }
        features.append(feature)
        (per_area / f"{code}.geojson").write_text(
            json.dumps({"type": "FeatureCollection", "features": [feature]}, ensure_ascii=False),
            encoding="utf-8")

    # The combined file is rebuilt from every per-area file, so fetching a
    # subset with --codes updates those areas without dropping the others.
    all_features = []
    for p in sorted(per_area.glob("*.geojson")):
        all_features += json.loads(p.read_text(encoding="utf-8"))["features"]
    fc = {
        "type": "FeatureCollection",
        "name": "pienriista-alueet",
        "attribution": "Metsähallitus / Retkikartta.fi",
        "features": all_features,
    }
    out = args.out_dir / "pienriista.geojson"
    out.write_text(json.dumps(fc, ensure_ascii=False), encoding="utf-8")
    print(f"\nFetched {len(features)} areas; {out} now has {len(all_features)} areas"
          + (f"; {len(failed)} failed: {', '.join(failed)}" if failed else ""))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
