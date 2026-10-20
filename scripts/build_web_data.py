#!/usr/bin/env python3
"""Build the map's data files from data/pienriista.geojson (see fetch_pienriista.py).

The fetched boundaries are unsimplified (~4.5 M vertices, 110 MB), too heavy for a
browser. This script removes redundant vertices with Douglas-Peucker (default
tolerance 1 m, invisible on a topo map) and rounds coordinates to 6 decimals.
MapLibre then simplifies further per zoom level on its own.

Kanalintu day-permit quotas from data/kanalintu_quotas.csv (parse_kanalintu_quotas.py)
are attached to each area when that file exists.

Outputs (default under web/data/):
  areas.geojson   one MultiPolygon per area, properties: code, name
  areas.json      area list for the sidebar and popups: details, area_ha, kanalintu
                  quotas, bbox, label point

Standard library only (Python 3.9+).
"""
from __future__ import annotations

import argparse
import csv
import heapq
import json
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "data" / "pienriista.geojson"
QUOTAS = REPO / "data" / "kanalintu_quotas.csv"
OUT = REPO / "web" / "data"

EARTH_RADIUS = 6371008.8
M_PER_DEG = EARTH_RADIUS * math.pi / 180

INFO_FIELDS = [
    "municipality", "province", "species", "recommended_species",
    "seasonal_permit_species", "daily_permit_species", "reindeer_herding_area",
    "usage_restriction", "retkikartta_url",
]
LIST_FIELDS = {"municipality", "province"}  # "Lappi, Lappi" -> "Lappi"

Ring = list  # [[lon, lat], ...], closed


# --------------------------------------------------------------------------- geometry

def simplify_ring(ring: Ring, tolerance_m: float) -> Ring:
    """Douglas-Peucker in a local equirectangular projection (metres). Keeps rings closed."""
    n = len(ring)
    if n <= 4 or tolerance_m <= 0:
        return ring
    kx = math.cos(math.radians(ring[0][1])) * M_PER_DEG
    xs = [p[0] * kx for p in ring]
    ys = [p[1] * M_PER_DEG for p in ring]
    keep = bytearray(n)
    keep[0] = keep[-1] = 1
    tol2 = tolerance_m * tolerance_m
    # A closed ring has first == last, so split it at the farthest vertex first.
    far = max(range(1, n - 1), key=lambda i: (xs[i] - xs[0]) ** 2 + (ys[i] - ys[0]) ** 2)
    keep[far] = 1
    stack = [(0, far), (far, n - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = xs[a], ys[a]
        dx, dy = xs[b] - ax, ys[b] - ay
        seg2 = dx * dx + dy * dy
        best, best_i = -1.0, -1
        for i in range(a + 1, b):
            px, py = xs[i] - ax, ys[i] - ay
            t = 0.0 if seg2 == 0 else max(0.0, min(1.0, (px * dx + py * dy) / seg2))
            ex, ey = px - t * dx, py - t * dy
            d2 = ex * ex + ey * ey
            if d2 > best:
                best, best_i = d2, i
        if best > tol2:
            keep[best_i] = 1
            stack += [(a, best_i), (best_i, b)]
    out = [ring[i] for i in range(n) if keep[i]]
    return out if len(out) >= 4 else ring


def simplify_multipolygon(polys: list, tolerance_m: float, nd: int = 6) -> list:
    return [[[[round(x, nd), round(y, nd)] for x, y in simplify_ring(r, tolerance_m)] for r in poly]
            for poly in polys]


def area_m2(polys: list) -> float:
    """Polygon area in a local equirectangular projection; good to ~0.1 % for one area."""
    lat0 = math.radians(sum(p[1] for poly in polys for p in poly[0]) / sum(len(poly[0]) for poly in polys))
    kx = math.cos(lat0) * M_PER_DEG
    rings = (abs(ring_area(r)) * (1 if i == 0 else -1) for poly in polys for i, r in enumerate(poly))
    return sum(rings) * kx * M_PER_DEG


def bbox(polys: list) -> list[float]:
    xs = [p[0] for poly in polys for p in poly[0]]
    ys = [p[1] for poly in polys for p in poly[0]]
    return [min(xs), min(ys), max(xs), max(ys)]


def ring_area(ring: Ring) -> float:
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(ring, ring[1:])) / 2


def _point_to_polygon_dist(x: float, y: float, poly: list) -> float:
    """Signed distance from (x, y) to the polygon outline: positive inside, negative outside."""
    inside = False
    best = math.inf
    for ring in poly:
        for (ax, ay), (bx, by) in zip(ring, ring[1:]):
            if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
                inside = not inside
            dx, dy = bx - ax, by - ay
            seg2 = dx * dx + dy * dy
            t = 0.0 if seg2 == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / seg2))
            ex, ey = x - ax - t * dx, y - ay - t * dy
            best = min(best, ex * ex + ey * ey)
    return math.sqrt(best) * (1 if inside else -1)


def polylabel(poly: list, precision: float) -> tuple[float, float]:
    """Pole of inaccessibility (mapbox/polylabel): the interior point farthest from the edge.

    Works in the polygon's own units; pass projected (metric) coordinates.
    """
    outer = poly[0]
    minx, miny = min(p[0] for p in outer), min(p[1] for p in outer)
    maxx, maxy = max(p[0] for p in outer), max(p[1] for p in outer)
    size = min(maxx - minx, maxy - miny)
    if size == 0:
        return outer[0][0], outer[0][1]

    def cell(x, y, h):
        d = _point_to_polygon_dist(x, y, poly)
        return (-(d + h * math.sqrt(2)), d, x, y, h)  # heap key = -max possible distance

    heap = []
    h = size / 2
    x = minx
    while x < maxx:
        y = miny
        while y < maxy:
            heapq.heappush(heap, cell(x + h, y + h, h))
            y += size
        x += size
    # Seed with the centroid of the outer ring.
    a = ring_area(outer) or 1e-12
    cx = sum((x0 + x1) * (x0 * y1 - x1 * y0) for (x0, y0), (x1, y1) in zip(outer, outer[1:])) / (6 * a)
    cy = sum((y0 + y1) * (x0 * y1 - x1 * y0) for (x0, y0), (x1, y1) in zip(outer, outer[1:])) / (6 * a)
    best = cell(cx, cy, 0)
    bbox_center = cell(minx + (maxx - minx) / 2, miny + (maxy - miny) / 2, 0)
    if bbox_center[1] > best[1]:
        best = bbox_center

    while heap:
        c = heapq.heappop(heap)
        if c[1] > best[1]:
            best = c
        if -c[0] - best[1] <= precision:
            continue
        h = c[4] / 2
        for dx in (-h, h):
            for dy in (-h, h):
                heapq.heappush(heap, cell(c[2] + dx, c[3] + dy, h))
    return best[2], best[3]


def label_point(polys: list) -> list[float]:
    """Label position inside the largest polygon of the area, as [lon, lat]."""
    lat0 = (bbox(polys)[1] + bbox(polys)[3]) / 2
    kx = math.cos(math.radians(lat0)) * M_PER_DEG
    largest = max(polys, key=lambda p: abs(ring_area(p[0])))
    # A coarse outline is plenty for finding a label spot and keeps this fast.
    coarse = [[(x * kx, y * M_PER_DEG) for x, y in simplify_ring(r, 50)] for r in largest]
    x, y = polylabel(coarse, precision=100)
    return [round(x / kx, 5), round(y / M_PER_DEG, 5)]


# --------------------------------------------------------------------------- properties

def dedupe_list(value: str | None) -> str | None:
    if not value:
        return value
    seen = []
    for part in (s.strip() for s in value.split(",")):
        if part and part not in seen:
            seen.append(part)
    return ", ".join(seen)


def parse_area_ha(value: str | None) -> float | None:
    """Retkikartta area string -> hectares: "953.30 km2" -> 95330.0, "535.59 ha" -> 535.59."""
    m = re.match(r"\s*([\d.]+)\s*(km2|km²|ha)\s*$", value or "")
    if not m:
        return None
    return float(m.group(1)) * (100 if m.group(2).startswith("km") else 1)


def load_quotas(path: Path) -> dict[str, dict]:
    """data/kanalintu_quotas.csv -> code -> {year, phase1_days, ...} with ints (None if empty)."""
    with path.open(newline="", encoding="utf-8") as f:
        return {
            r["code"]: {k: int(v) if v else None for k, v in r.items() if k not in ("code", "name")}
            for r in csv.DictReader(f)
        }


def area_info(props: dict, polys: list, quotas: dict[str, dict] | None = None) -> dict:
    info = {"code": props["code"], "name": props["name"]}
    for k in INFO_FIELDS:
        v = props.get(k)
        info[k] = dedupe_list(v) if k in LIST_FIELDS else v
    area_ha = parse_area_ha(props.get("area"))
    info["area_ha"] = round(area_ha if area_ha is not None else area_m2(polys) / 1e4, 1)
    info["kanalintu"] = (quotas or {}).get(props["code"])
    info["bbox"] = [round(v, 5) for v in bbox(polys)]
    info["label"] = label_point(polys)
    return info


# --------------------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=SRC, help="input GeoJSON (default: data/pienriista.geojson)")
    ap.add_argument("--out-dir", type=Path, default=OUT, help="output directory (default: web/data/)")
    ap.add_argument("--quotas", type=Path, default=QUOTAS,
                    help="kanalintu quota CSV (default: data/kanalintu_quotas.csv, skipped if missing)")
    ap.add_argument("--tolerance", type=float, default=1.0,
                    help="simplification tolerance in metres (default: 1.0, 0 = keep every vertex)")
    args = ap.parse_args()

    if not args.src.exists():
        sys.exit(f"{args.src} not found, run scripts/fetch_pienriista.py first")
    src = json.loads(args.src.read_text(encoding="utf-8"))
    quotas = load_quotas(args.quotas) if args.quotas.exists() else {}
    if not quotas:
        print(f"no kanalintu quotas ({args.quotas} missing), run scripts/parse_kanalintu_quotas.py")

    features, infos = [], []
    before = after = 0
    for f in sorted(src["features"], key=lambda f: f["properties"]["code"]):
        props, polys = f["properties"], f["geometry"]["coordinates"]
        simple = simplify_multipolygon(polys, args.tolerance)
        before += sum(len(r) for p in polys for r in p)
        after += sum(len(r) for p in simple for r in p)
        features.append({
            "type": "Feature",
            "properties": {"code": props["code"], "name": props["name"]},
            "geometry": {"type": "MultiPolygon", "coordinates": simple},
        })
        infos.append(area_info(props, polys, quotas))
        print(f"\r{len(features)}/{len(src['features'])} {props['code']} {props['name']:<30}", end="", flush=True)
    print()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    geo_path = args.out_dir / "areas.geojson"
    geo_path.write_text(json.dumps({"type": "FeatureCollection", "features": features},
                                   ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    info_path = args.out_dir / "areas.json"
    info_path.write_text(json.dumps(infos, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"{len(features)} areas, {before:,} -> {after:,} vertices (tolerance {args.tolerance} m)")
    if quotas:
        missing = [i["code"] for i in infos if not i["kanalintu"]]
        print(f"kanalintu quotas for {len(infos) - len(missing)} areas" + (f", missing: {', '.join(missing)}" if missing else ""))
    for p in (geo_path, info_path):
        print(f"  {p.relative_to(REPO) if p.is_relative_to(REPO) else p}  {p.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
