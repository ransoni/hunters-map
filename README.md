# hunters-map
Map service to show Finnish game areas on map

## Pienriista-alueiden rajat

Metsähallituksen pienriista-alueiden (small-game hunting areas) rajat haetaan
Retkikartasta GeoJSONiksi. Vain Pythonin vakiokirjasto (3.9+), ei riippuvuuksia.

```sh
# 1. Aluelista Eräluvat-PDF:stä (docs/Metsastysajat*.pdf) -> data/pienriista_alueet.csv
#    Vaatii pdftotext (brew install poppler) tai pip install pypdf.
python3 scripts/parse_pdf_areas.py

# 2. Vertaa PDF-listaa Retkikarttaan hakematta geometrioita
python3 scripts/fetch_pienriista.py --list

# 3. Hae kaikki alueet (~1 s pyyntöjen välillä, noin 4–5 min)
python3 scripts/fetch_pienriista.py

# ...tai vain osa
python3 scripts/fetch_pienriista.py --codes 6617,6619
```

Tulokset (WGS84 / EPSG:4326):

| Tiedosto | Sisältö |
| --- | --- |
| `data/pienriista.geojson` | kaikki haetut alueet, yksi MultiPolygon-feature per alue |
| `data/areas/<koodi>.geojson` | yksittäinen alue |
| `data/raw/` | välimuisti API-vastauksista (`--refresh` hakee uudelleen) |

Featuren ominaisuudet: `code` (lupa-alueen numero, esim. 6617), `name` (PDF:n nimi),
`retkikartta_id`, `global_id`, `retkikartta_url`, `municipality`, `province`,
`area`, `species`, `seasonal_permit_species`, `daily_permit_species`,
`reindeer_herding_area` jne.

### Miten haku toimii

1. `retkikartta-api.anderscloud.com/api/search/?categories=901` listaa alueet
   (kategoria 901 = pienriista-alue).
2. `/api/small-game-hunting-areas/<global_id>/` antaa tiedot ja extentin.
3. Retkikartan MapServer-WMS (`LAYERS=selected-feature&global_id=…`,
   `FORMAT=application/vnd.google-earth.kml+xml`) palauttaa rajan
   yksinkertaistamattomina suljettuina viivoina, jotka skripti kokoaa
   polygoneiksi reikineen.

Rajat päivittyvät vuosittain (kiinteistökaupat), joten hae aineisto uudelleen
ennen jokaista metsästyskautta.

### Käyttöoikeus

Rajapinnat ovat Retkikartan sisäisiä ja dokumentoimattomia. Eräluvat.fi:n
käyttöehdot sallivat vain yksityisen, ei-kaupallisen käytön; muu käyttö vaatii
Metsähallituksen kirjallisen luvan (eraluvat@metsa.fi). Siksi haettu data on
`.gitignore`ssa.

## Kartta

Selainkartta (MapLibre GL JS), jossa pienriista-alueet näytetään
[OpenTopoMapin](https://opentopomap.org) maastokartan päällä. Ei build-työkaluja:
MapLibre ladataan CDN:stä, kartta-aineisto rakennetaan Pythonin vakiokirjastolla.

```sh
# 1. Kanalintulupien kiintiöt PDF:istä (docs/Kanalintulupien_kiintioet_*.pdf)
#    -> data/kanalintu_quotas.csv. Tarvitaan vain, kun PDF:t vaihtuvat.
#    Vaatii pdftotext (brew install poppler) tai pip install pypdf.
python3 scripts/parse_kanalintu_quotas.py

# 2. Kuntien maakunnat Tilastokeskukselta -> data/kunta_maakunta.csv.
#    Tarvitaan vain, kun kuntajako muuttuu (yleensä vuodenvaihteessa).
python3 scripts/fetch_regions.py

# 3. Kevennä rajat selaimelle ja liitä kiintiöt ja maakunnat (-> web/data/, ~20 s)
python3 scripts/build_web_data.py

# 4. Käynnistä paikallinen palvelin ja avaa http://localhost:8000
python3 -m http.server 8000 --directory web
```

- Hae alueita nimellä, numerolla, kunnalla tai maakunnalla. Kun haku on päällä,
  *Valitse löydetyt* / *Poista löydetyt* koskevat vain hakutuloksia.
- *Maakunta*-valinta rajaa listan ja kartan yhden maakunnan alueisiin ja kohdistaa
  kartan sinne. Usean maakunnan alueelle ulottuva alue näkyy jokaisessa niistä.
  Valinnat säilyvät, kun maakuntaa vaihtaa.
- Alueen nimen klikkaus listassa kohdistaa kartan alueeseen. Alueen klikkaus
  kartalla avaa tiedot (lajit, luvat, linkki Retkikarttaan).
- *Väritys → Kanalintulupatiheys* värittää alueet kanalintulupien tiheyden mukaan
  (ks. alla) ja järjestää listan tihein ensin.
- Valinta, maakunta ja väritys tallentuvat osoitteeseen, esim.
  `http://localhost:8000/#alueet=6617,6619&maakunta=Keski-Suomi&tiheys=yht`.
  Ilman `alueet`-osaa näytetään kaikki alueet.

`build_web_data.py` poistaa rajoista turhat pisteet (Douglas–Peucker, oletuksena
1 m toleranssi, `--tolerance`) ja pyöristää koordinaatit 6 desimaaliin:
4,5 M → 0,9 M pistettä, 110 MB → 20 MB. Lisäksi se laskee jokaiselle alueelle
rajauslaatikon ja nimiön paikan alueen sisältä.

| Tiedosto | Sisältö |
| --- | --- |
| `web/data/areas.geojson` | kevennetyt rajat (`code`, `name`) |
| `web/data/areas.json` | aluelista: tiedot, `regions`, `area_ha`, `kanalintu`-kiintiöt, `bbox`, `label` |

Alueen maakunnat päätellään sen kunnista Tilastokeskuksen kunta–maakunta-luokituksella
(`data/kunta_maakunta.csv`, CC BY 4.0). Retkikartan omat maakuntatiedot ovat osin
vanhentuneita (Heinävesi, Joroinen ja Kuhmoinen vaihtoivat maakuntaa 2021), joten
niitä käytetään vain kunnille, joita luokituksessa ei ole.

Pohjakartta: © OpenTopoMap (CC-BY-SA), © OpenStreetMap-tekijät, SRTM.
OpenTopoMapin palvelimet on tarkoitettu kevyeen käyttöön, joten kartta sopii
henkilökohtaiseen käyttöön, ei julkiseksi palveluksi.

### Kanalintulupatiheys

Metsähallitus myy kanalinnun vuorokausilupia kahdessa vaiheessa, ja kummastakin on
oma PDF `docs/`-kansiossa:

| Vaihe | Sisältö | CSV:n sarakkeet |
| --- | --- | --- |
| 1. vaihe, kesäkuu | ensimmäisen vaiheen kokonaiskiintiö (metsästysvuorokautta) | `phase1_days`, `phase1_max_per_day` |
| 2. vaihe, elokuu | elokuun riistalaskentoihin perustuva myyntimäärä; *Ei lisämyyntiä* = 0 | `phase2_days`, `phase2_max_per_day` |

`parse_kanalintu_quotas.py` tunnistaa vaiheen PDF:n tekstistä, joten tiedostonimillä
ei ole väliä. `*_max_per_day` = lupia enintään voimassa samana päivänä.

Kartan tiheys = myytävät metsästysvuorokaudet / alueen pinta-ala × 1000
(**vrk / 1000 ha**). Valittavana *yhteensä* (kesäkuu + elokuu), *kesäkuu* tai
*elokuu*. Alueet väritetään viidenneksiin (5 luokkaa, kussakin ~24 aluetta), ja
aluetiedoissa näkyy sijoitus kaikkien alueiden joukossa.

Tulkinta: Metsähallitus mitoittaa lupamäärät kanalintukannan mukaan, joten luku
kuvaa karkeasti kannan tiheyttä. Huomioita:

- Elokuun luku sisältää kesällä myymättä jääneet päivät, joten *yhteensä* on yläraja
  koko kauden luvuille.
- Pinta-ala on alueen kokonaispinta-ala Retkikartasta (kahdella alueella hehtaareina,
  muilla km²), ei pelkkä metsämaa.
- Lupamäärään vaikuttavat kannan lisäksi myös metsästyspaine ja aluekohtaiset
  linjaukset, ja pienillä alueilla luku heiluu helposti.

## iPhone-sovellus

`ios/` sisältää iPhone-sovelluksen (SwiftUI + [MapLibre Native](https://github.com/maplibre/maplibre-native),
iOS 17+). MVP:

- OpenTopoMap-maastokartta pohjana (`ios/HuntersMap/TopoStyle.json`; vaihdetaan
  myöhemmin MML:n vektorimaastokarttaan)
- GPS-sijainti kartalla; sijaintinappi kiertää *ei seurantaa → seuraa → seuraa suuntaa*
- Kanalintualueen valinta haettavasta listasta (nimi, numero, kunta tai maakunta).
  Valittu alue piirretään kartalle ja kartta kohdistuu siihen; valinta säilyy
  käynnistysten välillä. Kaikkien kanalintualueiden rajat näkyvät himmeinä katkoviivoina.
- Zoomausnapit (+/−) nipistyksen lisäksi, esim. hanskat kädessä
- Reitin tallennus (kävelijä-nappi): kuljettu reitti näkyy sinisenä jälkenä, joka
  haalistuu 15 minuutissa (`TrackRecorder.window`). Tallennus jatkuu näytön ollessa
  lukittuna (taustasijainti, `ios/HuntersMap-Info.plist`; iOS näyttää sinisen
  sijaintimerkin) ja jatkuu sovelluksen uudelleenkäynnistyksen jälkeen.
  Jatkuva GPS kuluttaa akkua, joten lopeta tallennus, kun et tarvitse sitä.

Sovellus käyttää samoja tiedostoja kuin selainkartta: Xcoden *Copy area data*
-vaihe kopioi `web/data/areas.json` ja `areas.geojson` sovellukseen, joten aja
ensin `python3 scripts/build_web_data.py`.

```sh
open ios/HuntersMap.xcodeproj
```

Valitse Xcodessa simulaattori ja paina ⌘R. Omalle iPhonelle:

1. Xcode → Settings → Accounts: lisää Apple ID.
2. Projektin *HuntersMap*-targetin *Signing & Capabilities*: valitse *Team*
   (ilmaisella Apple ID:llä "Personal Team"). Jos bundle id `fi.ridefree.huntersmap`
   on varattu, vaihda se.
3. Kytke iPhone, salli *Kehittäjätila* (Asetukset → Tietosuoja ja turvallisuus),
   valitse puhelin Xcoden kohteeksi ja paina ⌘R.

Ilmaisella tilillä asennus vanhenee 7 päivässä; TestFlight vaatii Apple Developer
Programin.

## Backend (jakaminen ja kirjautuminen)

`backend/` on Go-kielinen API (Cloud Run), joka hoitaa käyttäjäprofiilit, seurueet,
kutsukoodit ja sijainnin jakamisen. Tiedot ovat Firestoressa (tietokanta `hunters-map`),
ja kirjautuminen tehdään Firebase Authenticationilla (Google, myöhemmin Apple).
Infra on Terraformina `infra/`-kansiossa; käyttöönotto-ohjeet: [infra/README.md](infra/README.md).

## Testit

```sh
python3 -m unittest discover -s tests
```

PDF-testit ohitetaan, jos koneelta puuttuu sekä `pdftotext` että `pypdf`.
