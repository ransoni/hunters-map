"""Offline tests: python3 -m unittest discover -s tests"""
import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import build_web_data as bw  # noqa: E402
import fetch_pienriista as fp  # noqa: E402
import parse_kanalintu_quotas as kq  # noqa: E402
import parse_pdf_areas as pp  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
CAN_READ_PDF = bool(shutil.which("pdftotext") or importlib.util.find_spec("pypdf"))


def square(x0, y0, size, cw=False):
    r = [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size), (x0, y0)]
    return r[::-1] if cw else r


def kml_of(*rings):
    blocks = "".join(
        "<Placemark><MultiGeometry><LineString><coordinates>"
        + " ".join(f"{x},{y}" for x, y in r)
        + "</coordinates></LineString></MultiGeometry></Placemark>"
        for r in rings)
    return f"<kml><Document>{blocks}</Document></kml>"


class GeometryTests(unittest.TestCase):
    def test_real_single_ring(self):
        rings = fp.parse_kml_rings((FIXTURES / "5629_kantojarvi.kml").read_text())
        self.assertEqual(len(rings), 1)
        polys = fp.rings_to_polygons(rings)
        self.assertEqual(len(polys), 1)
        self.assertEqual(len(polys[0]), 1)
        self.assertGreater(fp.signed_area(polys[0][0]), 0)  # outer ring CCW
        lon, lat = polys[0][0][0]
        self.assertTrue(26 < lon < 27 and 64 < lat < 65)

    def test_holes_islands_and_duplicates(self):
        outer = square(0, 0, 10, cw=True)       # wrong winding on purpose
        hole = square(2, 2, 6)
        island = square(4, 4, 2)                 # island inside the hole
        separate = square(20, 0, 3)
        dupe = list(reversed(separate))          # same ring, other direction
        polys = fp.rings_to_polygons(fp.parse_kml_rings(kml_of(outer, hole, island, separate, dupe)))
        self.assertEqual(len(polys), 3)          # outer-with-hole, island, separate
        big = polys[0]
        self.assertEqual(len(big), 2)
        self.assertGreater(fp.signed_area(big[0]), 0)
        self.assertLess(fp.signed_area(big[1]), 0)
        self.assertTrue(all(len(p) == 1 for p in polys[1:]))

    def test_unclosed_ring_is_closed(self):
        rings = fp.parse_kml_rings(kml_of(square(0, 0, 1)[:-1]))
        self.assertEqual(rings[0][0], rings[0][-1])

    def test_kml_url(self):
        url = fp.kml_url("abc", [1, 2, 3, 4])
        self.assertIn("LAYERS=selected-feature", url)
        self.assertIn("global_id=abc", url)
        self.assertIn("kml%2Bxml", url)


class PdfTests(unittest.TestCase):
    def test_row_parsing(self):
        text = (
            "LUPA-ALUE                       METSO          TEERI\n"
            "6617 Kukko-Multia         10.09.-10.11.   10.09.-10.10.\n"
            "3613 Itäinen Pelkosenniemi    10.09.-10.11.\n"
            "                                          Ähtäri: 10.09.-10.11.\n"
            "7642 Kuora-Kontiovaara-Uimaharju   10.09.-10.12. + 10.01.-31.01.\n"
        )
        self.assertEqual(pp.parse_areas(text), [
            ("3613", "Itäinen Pelkosenniemi"),
            ("6617", "Kukko-Multia"),
            ("7642", "Kuora-Kontiovaara-Uimaharju"),
        ])

    @unittest.skipUnless(CAN_READ_PDF and list((REPO / "docs").glob("Metsastysajat*.pdf")),
                         "needs pdftotext or pypdf and docs/Metsastysajat*.pdf")
    def test_real_pdf(self):
        areas = dict(pp.parse_areas(pp.pdf_text(pp.find_default_pdf())))
        self.assertGreaterEqual(len(areas), 100)
        self.assertEqual(areas["6617"], "Kukko-Multia")
        self.assertTrue(all(len(c) == 4 and n for c, n in areas.items()))


class BuildWebDataTests(unittest.TestCase):
    def test_simplify_drops_collinear_keeps_corners(self):
        # 0.01° square near 65°N with extra points along every edge.
        edge = [i / 10 * 0.01 for i in range(10)]
        ring = ([(25 + d, 65) for d in edge] + [(25.01, 65 + d) for d in edge]
                + [(25.01 - d, 65.01) for d in edge] + [(25, 65.01 - d) for d in edge] + [(25, 65)])
        out = bw.simplify_ring(ring, 1.0)
        self.assertEqual(out[0], out[-1])
        self.assertEqual(sorted(set(out)), [(25, 65), (25, 65.01), (25.01, 65), (25.01, 65.01)])

    def test_simplify_keeps_tiny_rings(self):
        tri = [(25, 65), (25.00001, 65), (25, 65.00001), (25, 65)]
        self.assertEqual(bw.simplify_ring(tri, 100), tri)

    def test_polylabel_concave(self):
        # U shape: the centroid falls in the notch, the label must not.
        u = [(0, 0), (30, 0), (30, 30), (20, 30), (20, 10), (10, 10), (10, 30), (0, 30), (0, 0)]
        x, y = bw.polylabel([u], precision=0.1)
        self.assertTrue(fp.point_in_ring((x, y), u))
        self.assertFalse(10 < x < 20 and y > 10)

    def test_label_point_inside_real_area(self):
        polys = fp.rings_to_polygons(fp.parse_kml_rings((FIXTURES / "5629_kantojarvi.kml").read_text()))
        lon, lat = bw.label_point(polys)
        self.assertTrue(fp.point_in_ring((lon, lat), polys[0][0]))

    def test_area_info(self):
        polys = [[square(25, 65, 0.5)], [square(26, 66, 0.1)]]
        props = {"code": "1234", "name": "Testi", "province": "Lappi, Lappi", "municipality": "Inari, Utsjoki"}
        info = bw.area_info(props, polys)
        self.assertEqual(info["province"], "Lappi")
        self.assertEqual(info["municipality"], "Inari, Utsjoki")
        self.assertEqual(info["bbox"], [25, 65, 26.1, 66.1])
        self.assertTrue(fp.point_in_ring(tuple(info["label"]), square(25, 65, 0.5)))
        self.assertIsNone(info["kanalintu"])
        self.assertAlmostEqual(info["area_ha"], bw.area_m2(polys) / 1e4, delta=1)

    def test_parse_area_ha(self):
        self.assertEqual(bw.parse_area_ha("127.27 km2"), 12727.0)
        self.assertEqual(bw.parse_area_ha("535.59 ha"), 535.59)
        self.assertIsNone(bw.parse_area_ha(None))
        self.assertIsNone(bw.parse_area_ha("n/a"))

    def test_area_m2_with_hole(self):
        # 0.1° x 0.1° at the equator is ~11.1 km x 11.1 km; the hole is a quarter of it.
        outer, hole = square(0, 0, 0.1), square(0.025, 0.025, 0.05, cw=True)
        self.assertAlmostEqual(bw.area_m2([[outer]]) / 1e6, 123.6, delta=0.5)
        self.assertAlmostEqual(bw.area_m2([[outer, hole]]) / bw.area_m2([[outer]]), 0.75, places=3)

    def test_quotas_attached(self):
        with tempfile.TemporaryDirectory() as tmp:
            csv_path = Path(tmp) / "q.csv"
            csv_path.write_text(
                "code,name,year,phase1_days,phase1_max_per_day,phase2_days,phase2_max_per_day\n"
                "1234,Testi,2026,87,7,0,\n", encoding="utf-8")
            quotas = bw.load_quotas(csv_path)
        info = bw.area_info({"code": "1234", "name": "Testi", "area": "535.59 ha"}, [[square(25, 65, 0.1)]], quotas)
        self.assertEqual(info["area_ha"], 535.6)
        self.assertEqual(info["kanalintu"], {"year": 2026, "phase1_days": 87, "phase1_max_per_day": 7,
                                             "phase2_days": 0, "phase2_max_per_day": None})


class KanalintuQuotaTests(unittest.TestCase):
    JUNE = (
        "Kanalinnun metsästyksen vuorokausiluvat 2026\n"
        "Tässä lupamyynnin ensimmäisessä vaiheessa lupia voi ...\n"
        "LUPA-ALUEEN NUMERO JA NIMI        MYYTÄVIEN METSÄSTYSVUOROKAUSIEN KOKONAISKIINTIÖ\n"
        " 1605 Näätämö                          320                 60\n"
        " 5601 Paltamo                           87                  7\n"
        " 7680 Lohikoski-Likastenperä           386                 20\n"
    )
    AUGUST = (
        "Kanalinnun metsästyksen vuorokausiluvat 2026\n"
        "Metsähallituksen kanalintulupien myynnin toinen vaihe alkaa maanantaina 24. elokuuta.\n"
        "Lupamyynnin ensimmäinen vaihe alkoi kesäkuussa ...\n"
        "1605     Näätämö                     Ei lisämyyntiä\n"
        "5601     Paltamo                       128                  14\n"
        "7680     Lohikoski-Likastenperä        138                  30\n"
        "9999     Vain elokuussa                 10\n"
    )

    def test_detect_phase_and_year(self):
        self.assertEqual(kq.detect_phase(self.JUNE), 1)
        self.assertEqual(kq.detect_phase(self.AUGUST), 2)
        self.assertEqual(kq.detect_year(self.AUGUST), 2026)
        with self.assertRaises(ValueError):
            kq.detect_phase("jotain muuta")

    def test_parse_rows(self):
        self.assertEqual(kq.parse_rows(self.AUGUST), {
            "1605": ("Näätämö", 0, None),
            "5601": ("Paltamo", 128, 14),
            "7680": ("Lohikoski-Likastenperä", 138, 30),
            "9999": ("Vain elokuussa", 10, None),
        })

    def test_merge(self):
        rows = kq.merge({1: kq.parse_rows(self.JUNE), 2: kq.parse_rows(self.AUGUST)}, 2026)
        by_code = {r["code"]: r for r in rows}
        self.assertEqual(by_code["5601"], {"code": "5601", "year": 2026, "name": "Paltamo", "phase1_days": 87,
                                           "phase1_max_per_day": 7, "phase2_days": 128, "phase2_max_per_day": 14})
        self.assertEqual(by_code["1605"]["phase2_days"], 0)
        self.assertEqual(by_code["9999"]["phase1_days"], "")
        self.assertEqual(by_code["9999"]["name"], "Vain elokuussa")

    @unittest.skipUnless(CAN_READ_PDF and len(list((REPO / "docs").glob(kq.PDF_GLOB))) == 2,
                         "needs pdftotext or pypdf and both quota PDFs in docs/")
    def test_real_pdfs(self):
        phases = {}
        for pdf in (REPO / "docs").glob(kq.PDF_GLOB):
            text = pp.pdf_text(pdf)
            phases[kq.detect_phase(text)] = kq.parse_rows(text)
        self.assertEqual(sorted(phases), [1, 2])
        areas = {code for code, _ in pp.parse_areas(pp.pdf_text(pp.find_default_pdf()))}
        self.assertEqual(set(phases[1]), areas)
        self.assertEqual(set(phases[2]), areas)
        self.assertEqual(phases[1]["6642"], ("Virrat", 319, 11))  # digits run together in plain text
        self.assertEqual(phases[2]["1605"], ("Näätämö", 0, None))


if __name__ == "__main__":
    unittest.main()
