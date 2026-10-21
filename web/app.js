// Pienriista-alueet on OpenTopoMap. Data comes from scripts/build_web_data.py:
//   data/areas.geojson  simplified boundaries (code, name)
//   data/areas.json     area details, area_ha, kanalintu quotas, bbox and label point
// View state is kept in the URL hash: #alueet=6617,6619&maakunta=Keski-Suomi&tiheys=yht
//   alueet    selected areas (missing = all)
//   maakunta  show only areas in this region, list and map (missing = whole country)
//   tiheys    colour areas by kanalintu day permits per 1000 ha (missing = plain view)

const FINLAND = [[19.1, 59.7], [31.6, 70.1]];
const AREA_LAYERS = ['areas-fill', 'areas-casing', 'areas-line', 'areas-label'];
const COLOR = '#e8430c';

// Kanalintu permit density: hunting days for sale per 1000 ha of area.
// The August count already includes days left unsold in June, so the total is an upper bound.
const METRICS = {
  yht: { label: 'yhteensä', days: (k) => sumOrNull(k.phase1_days, k.phase2_days) },
  kesa: { label: '1. vaihe, kesäkuu', days: (k) => k.phase1_days },
  elo: { label: '2. vaihe, elokuu', days: (k) => k.phase2_days },
};
// Quintile classes, low -> high. One hue, light -> dark (validated as an ordinal ramp).
const RAMP = ['#db9fde', '#c56fcb', '#a646ad', '#812688', '#59105e'];
const NO_DATA = '#9b9891';

const state = {
  areas: [],
  byCode: new Map(),
  selected: new Set(),
  region: null, // maakunta name, or null for the whole country
  regionCodes: new Map(), // maakunta -> Set of area codes touching it
  metric: null, // key of METRICS, or null for the plain area view
  sort: 'code', // 'code' | 'density'
  density: {}, // metric -> { byCode: Map(code -> {days, value, cls, rank}), breaks, count }
};

const $ = (sel) => document.querySelector(sel);
const listEl = $('#area-list');
const searchEl = $('#search');

const map = new maplibregl.Map({
  container: 'map',
  style: {
    version: 8,
    glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
    sources: {
      topo: {
        type: 'raster',
        tiles: ['a', 'b', 'c'].map((s) => `https://${s}.tile.opentopomap.org/{z}/{x}/{y}.png`),
        tileSize: 256,
        maxzoom: 17,
        attribution:
          'Kartta: © <a href="https://opentopomap.org" target="_blank">OpenTopoMap</a> (CC-BY-SA), ' +
          '© <a href="https://www.openstreetmap.org/copyright" target="_blank">OpenStreetMap</a>-tekijät, SRTM',
      },
    },
    layers: [{ id: 'topo', type: 'raster', source: 'topo' }],
  },
  bounds: FINLAND,
  maxZoom: 18,
  attributionControl: { compact: true },
});
// 'style.load', not 'load': 'load' waits for the base map tiles, which can be slow.
const styleLoaded = new Promise((resolve) => map.once('style.load', resolve));

map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
map.addControl(new maplibregl.GeolocateControl({
  positionOptions: { enableHighAccuracy: true },
  trackUserLocation: true,
}), 'top-right');
map.addControl(new maplibregl.ScaleControl(), 'bottom-left');

init();

async function init() {
  try {
    const res = await fetch('data/areas.json');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    state.areas = await res.json();
  } catch (err) {
    console.error(err);
    showStatus('Aluedataa ei löytynyt. Aja ensin: python3 scripts/build_web_data.py', true);
    return;
  }
  for (const a of state.areas) {
    state.byCode.set(a.code, a);
    for (const r of a.regions ?? []) {
      if (!state.regionCodes.has(r)) state.regionCodes.set(r, new Set());
      state.regionCodes.get(r).add(a.code);
    }
  }
  for (const key of Object.keys(METRICS)) state.density[key] = computeDensity(key);
  if (![...state.byCode.values()].some((a) => a.kanalintu)) $('#metric').disabled = true;

  readHash();
  renderRegionOptions();
  renderList();
  bindControls();
  applyView();
  await styleLoaded;
  addAreaLayers();
  applyView();
  if (state.region || state.selected.size < state.areas.length) zoomToView({ animate: false });
}

// ------------------------------------------------------------------ kanalintu density

function computeDensity(metric) {
  const byCode = new Map();
  for (const a of state.areas) {
    const days = a.kanalintu ? METRICS[metric].days(a.kanalintu) : null;
    if (days == null || !a.area_ha) continue;
    byCode.set(a.code, { days, value: (days / a.area_ha) * 1000 });
  }
  const values = [...byCode.values()].map((d) => d.value).sort((x, y) => x - y);
  const breaks = [0.2, 0.4, 0.6, 0.8].map((p) => quantile(values, p));
  for (const d of byCode.values()) {
    d.cls = breaks.filter((t) => d.value >= t).length; // 0..4
    d.rank = 1 + values.filter((v) => v > d.value).length;
  }
  return { byCode, breaks, count: values.length };
}

function quantile(sorted, p) {
  if (!sorted.length) return 0;
  const i = (sorted.length - 1) * p;
  const lo = Math.floor(i);
  return sorted[lo] + (sorted[Math.min(lo + 1, sorted.length - 1)] - sorted[lo]) * (i - lo);
}

function sumOrNull(...xs) {
  return xs.every((x) => x == null) ? null : xs.reduce((s, x) => s + (x ?? 0), 0);
}

// ------------------------------------------------------------------ map layers

function addAreaLayers() {
  map.addSource('areas', {
    type: 'geojson',
    data: 'data/areas.geojson',
    promoteId: 'code',
    attribution: 'Alueet ja luvat: © Metsähallitus',
  });
  map.addSource('labels', { type: 'geojson', data: labelData() });

  map.addLayer({ id: 'areas-fill', type: 'fill', source: 'areas' });
  map.addLayer({
    id: 'areas-casing',
    type: 'line',
    source: 'areas',
    paint: {
      'line-color': '#fff',
      'line-opacity': 0.75,
      'line-width': ['interpolate', ['linear'], ['zoom'], 6, 0, 9, 3, 13, 5],
    },
  });
  map.addLayer({
    id: 'areas-line',
    type: 'line',
    source: 'areas',
    paint: { 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 1, 12, 2.5] },
  });
  map.addLayer({
    id: 'areas-label',
    type: 'symbol',
    source: 'labels',
    minzoom: 5.5,
    layout: {
      'text-field': ['get', 'text'],
      'text-font': ['Open Sans Semibold'],
      'text-size': ['interpolate', ['linear'], ['zoom'], 6, 11, 11, 15],
      'text-max-width': 9,
      'text-padding': 6,
    },
    paint: {
      'text-halo-color': 'rgba(255, 255, 255, 0.95)',
      'text-halo-width': 1.6,
    },
  });

  map.on('sourcedata', (e) => {
    if (e.sourceId === 'areas' && e.isSourceLoaded) showStatus(null);
  });

  let hovered = null;
  const setHover = (code) => {
    if (code === hovered) return;
    if (hovered) map.setFeatureState({ source: 'areas', id: hovered }, { hover: false });
    hovered = code;
    if (hovered) map.setFeatureState({ source: 'areas', id: hovered }, { hover: true });
  };
  map.on('mousemove', 'areas-fill', (e) => {
    map.getCanvas().style.cursor = 'pointer';
    setHover(e.features[0].properties.code);
  });
  map.on('mouseleave', 'areas-fill', () => {
    map.getCanvas().style.cursor = '';
    setHover(null);
  });
  listEl.addEventListener('mouseover', (e) => setHover(e.target.closest('.area')?.dataset.code ?? null));
  listEl.addEventListener('mouseleave', () => setHover(null));

  map.on('click', 'areas-fill', (e) => openPopup(e.features[0].properties.code, e.lngLat));
}

function labelData() {
  const density = state.metric && state.density[state.metric].byCode;
  return {
    type: 'FeatureCollection',
    features: state.areas.map((a) => {
      const d = density && density.get(a.code);
      const text = d ? `${a.code} ${a.name}\n${formatDensity(d.value)} / 1000 ha` : `${a.code} ${a.name}`;
      return {
        type: 'Feature',
        properties: { code: a.code, text },
        geometry: { type: 'Point', coordinates: a.label },
      };
    }),
  };
}

function styleLayers() {
  if (!map.getLayer('areas-fill')) return;
  const hover = (on, off) => ['case', ['boolean', ['feature-state', 'hover'], false], on, off];
  if (state.metric) {
    const pairs = [...state.density[state.metric].byCode].flatMap(([code, d]) => [code, RAMP[d.cls]]);
    const classColor = pairs.length ? ['match', ['get', 'code'], ...pairs, NO_DATA] : NO_DATA;
    map.setPaintProperty('areas-fill', 'fill-color', classColor);
    map.setPaintProperty('areas-fill', 'fill-opacity', hover(0.85, 0.6));
    // Outline in the class colour too: at overview zoom the small areas are mostly outline.
    map.setPaintProperty('areas-line', 'line-color', classColor);
    map.setPaintProperty('areas-label', 'text-color', '#22201c');
  } else {
    map.setPaintProperty('areas-fill', 'fill-color', COLOR);
    map.setPaintProperty('areas-fill', 'fill-opacity', hover(0.32, 0.12));
    map.setPaintProperty('areas-line', 'line-color', COLOR);
    map.setPaintProperty('areas-label', 'text-color', '#8a2604');
  }
  map.getSource('labels').setData(labelData());
}

// ------------------------------------------------------------------ view state

function allCodes() {
  return new Set(state.areas.map((a) => a.code));
}

// Areas in the chosen region, or all of them.
function regionCodes() {
  return state.region ? state.regionCodes.get(state.region) : new Set(state.byCode.keys());
}

// Areas drawn on the map: selected and in the chosen region.
function mapCodes() {
  const inRegion = regionCodes();
  return [...state.selected].filter((c) => inRegion.has(c));
}

// Push the whole view (selection, region, colouring, sorting) to the map, list, legend and URL.
function applyView({ updateHash = true } = {}) {
  const shown = mapCodes();
  const filter = shown.length === state.areas.length ? null : ['in', ['get', 'code'], ['literal', shown]];
  for (const id of AREA_LAYERS) if (map.getLayer(id)) map.setFilter(id, filter);
  styleLayers();

  $('#count').textContent = `${shown.length} / ${regionCodes().size} aluetta kartalla`
    + (state.region ? ` (${state.region})` : '');
  $('#panel-toggle').textContent = `Alueet (${shown.length})`;
  $('#region').value = state.region ?? '';
  $('#metric').value = state.metric ?? '';
  $('#sort').value = state.sort;
  $('#sort').querySelector('[value=density]').disabled = !state.metric;
  $('#metric-hint').hidden = !state.metric;
  updateList();
  filterList();
  renderLegend();
  if (updateHash) writeHash();
}

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  const codes = params.get('alueet');
  state.selected = codes === null
    ? allCodes()
    : new Set(codes.split(',').map((s) => s.trim()).filter((c) => state.byCode.has(c)));
  state.region = state.regionCodes.has(params.get('maakunta')) ? params.get('maakunta') : null;
  state.metric = METRICS[params.get('tiheys')] ? params.get('tiheys') : null;
  state.sort = state.metric ? 'density' : 'code';
}

function writeHash() {
  const parts = [];
  if (state.selected.size < state.areas.length) parts.push(`alueet=${[...state.selected].sort().join(',')}`);
  if (state.region) parts.push(`maakunta=${encodeURIComponent(state.region)}`);
  if (state.metric) parts.push(`tiheys=${state.metric}`);
  history.replaceState(null, '', parts.length ? `#${parts.join('&')}` : location.pathname + location.search);
}

// Fit the map to what is shown: the selected areas of the region (or the whole
// region if none of it is selected), the selection, or the whole country.
function zoomToView({ animate = true } = {}) {
  const shown = mapCodes();
  if (state.region) zoomTo(shown.length ? shown : [...regionCodes()], { animate });
  else if (shown.length && shown.length < state.areas.length) zoomTo(shown, { animate });
  else map.fitBounds(FINLAND, { padding: 20, animate });
}

function zoomTo(codes, { animate = true } = {}) {
  const boxes = codes.map((c) => state.byCode.get(c)?.bbox).filter(Boolean);
  if (!boxes.length) return;
  const bounds = [
    [Math.min(...boxes.map((b) => b[0])), Math.min(...boxes.map((b) => b[1]))],
    [Math.max(...boxes.map((b) => b[2])), Math.max(...boxes.map((b) => b[3]))],
  ];
  map.fitBounds(bounds, { padding: 40, maxZoom: 13, animate });
}

// ------------------------------------------------------------------ sidebar

function renderList() {
  listEl.replaceChildren(...state.areas.map((a) => {
    const li = el('li', { className: 'area', dataset: { code: a.code } },
      el('input', { type: 'checkbox', ariaLabel: `${a.code} ${a.name}` }),
      el('button', { className: 'name', type: 'button', title: 'Näytä kartalla' },
        el('span', { className: 'title' }, el('span', { className: 'code' }, a.code), a.name),
        el('span', { className: 'muni' }, a.municipality ?? '')),
      el('span', { className: 'side' }));
    li.searchText = [a.code, a.name, a.municipality, ...(a.regions ?? [])].join(' ').toLowerCase();
    return li;
  }));
}

function renderRegionOptions() {
  const regions = [...state.regionCodes.keys()].sort((x, y) => x.localeCompare(y, 'fi'));
  $('#region').replaceChildren(
    el('option', { value: '' }, 'Kaikki maakunnat'),
    ...regions.map((r) => el('option', { value: r }, `${r} (${state.regionCodes.get(r).size})`)));
}

// Hide list rows outside the chosen region or not matching the search.
function filterList() {
  const q = searchEl.value.trim().toLowerCase();
  const inRegion = regionCodes();
  for (const li of listEl.children) li.hidden = !inRegion.has(li.dataset.code) || (!!q && !li.searchText.includes(q));
  $('#select-all').textContent = q ? 'Valitse löydetyt' : 'Valitse kaikki';
  $('#select-none').textContent = q ? 'Poista löydetyt' : 'Poista valinnat';
}

function updateList() {
  const density = state.metric && state.density[state.metric];
  const items = [...listEl.children];
  for (const li of items) {
    const a = state.byCode.get(li.dataset.code);
    li.querySelector('input').checked = state.selected.has(a.code);
    const side = li.querySelector('.side');
    const d = density && density.byCode.get(a.code);
    if (!density) {
      side.replaceChildren(formatArea(a.area_ha));
      side.title = '';
    } else if (d) {
      side.replaceChildren(swatch(RAMP[d.cls]), formatDensity(d.value));
      side.title = `${formatDensity(d.value)} vrk / 1000 ha, sija ${d.rank}/${density.count}`;
    } else {
      side.replaceChildren(swatch(NO_DATA), '–');
      side.title = 'Ei lupatietoa';
    }
  }
  const value = (li) => density?.byCode.get(li.dataset.code)?.value ?? -1;
  items.sort(state.sort === 'density' && density
    ? (x, y) => value(y) - value(x) || x.dataset.code.localeCompare(y.dataset.code)
    : (x, y) => x.dataset.code.localeCompare(y.dataset.code));
  listEl.append(...items);
}

function renderLegend() {
  const legend = $('#legend');
  legend.hidden = !state.metric;
  if (!state.metric) return;
  const { breaks, byCode } = state.density[state.metric];
  const counts = RAMP.map((_, i) => [...byCode.values()].filter((d) => d.cls === i).length);
  const fmt = formatDensity;
  const ranges = [`alle ${fmt(breaks[0])}`, ...breaks.slice(0, -1).map((b, i) => `${fmt(b)}–${fmt(breaks[i + 1])}`),
    `${fmt(breaks[3])} tai yli`];
  const year = state.areas.find((a) => a.kanalintu?.year)?.kanalintu.year ?? '';
  $('#legend-sub').textContent = `${METRICS[state.metric].label} ${year}`.trim();
  // Highest class first, like the list.
  $('#legend-items').replaceChildren(...RAMP.map((color, i) => el('li', {},
    swatch(color), el('span', { className: 'range' }, ranges[i]),
    el('span', { className: 'n' }, `${counts[i]} al.`))).reverse());
}

function bindControls() {
  listEl.addEventListener('change', (e) => {
    const code = e.target.closest('.area').dataset.code;
    if (e.target.checked) state.selected.add(code);
    else state.selected.delete(code);
    applyView();
  });

  listEl.addEventListener('click', (e) => {
    if (!e.target.closest('.name')) return;
    const code = e.target.closest('.area').dataset.code;
    if (!state.selected.has(code)) {
      state.selected.add(code);
      applyView();
    }
    zoomTo([code]);
    setPanelOpen(false);
  });

  searchEl.addEventListener('input', filterList);
  $('#region').addEventListener('change', (e) => {
    state.region = e.target.value || null;
    applyView();
    zoomToView();
  });

  // The buttons act on the listed areas only: those in the region and matching the search.
  const listedCodes = () => [...listEl.children].filter((li) => !li.hidden).map((li) => li.dataset.code);
  $('#select-all').addEventListener('click', () => {
    listedCodes().forEach((c) => state.selected.add(c));
    applyView();
  });
  $('#select-none').addEventListener('click', () => {
    listedCodes().forEach((c) => state.selected.delete(c));
    applyView();
  });
  $('#zoom-selected').addEventListener('click', () => {
    zoomToView();
    setPanelOpen(false);
  });

  $('#metric').addEventListener('change', (e) => {
    const was = state.metric;
    state.metric = e.target.value || null;
    // Switching the colouring on sorts by density; switching it off goes back to code order.
    if (!state.metric) state.sort = 'code';
    else if (!was) state.sort = 'density';
    applyView();
  });
  $('#sort').addEventListener('change', (e) => {
    state.sort = e.target.value;
    applyView({ updateHash: false });
  });

  $('#panel-toggle').addEventListener('click', () => {
    setPanelOpen(!document.body.classList.contains('panel-open'));
  });

  window.addEventListener('hashchange', () => {
    readHash();
    applyView({ updateHash: false });
    zoomToView();
  });
}

// Phone layout only: the sidebar is a bottom sheet toggled by #panel-toggle.
function setPanelOpen(open) {
  document.body.classList.toggle('panel-open', open);
  $('#panel-toggle').setAttribute('aria-expanded', open);
}

// ------------------------------------------------------------------ popup

let popup = null;

function openPopup(code, lngLat) {
  const a = state.byCode.get(code);
  if (!a) return;
  const rows = [
    ['Kunnat', a.municipality],
    [a.regions?.length > 1 ? 'Maakunnat' : 'Maakunta', a.regions?.join(', ')],
    ['Pinta-ala', formatArea(a.area_ha)],
    ['Riistalajit', a.species],
    ['Kausilupa', a.seasonal_permit_species],
    ['Vuorokausilupa', a.daily_permit_species],
    ['Suositellut', a.recommended_species],
    ['Poronhoitoalue', a.reindeer_herding_area],
    ['Rajoitukset', a.usage_restriction],
  ].filter(([, v]) => v);

  const hide = el('button', { type: 'button' }, 'Piilota alue');
  hide.addEventListener('click', () => {
    state.selected.delete(code);
    applyView();
    popup.remove();
  });
  const content = el('div', { className: 'popup' },
    el('h2', {}, `${a.code} ${a.name}`),
    el('dl', {}, ...rows.flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)])),
    kanalintuSection(a),
    el('div', { className: 'actions' },
      a.retkikartta_url
        ? el('a', { href: a.retkikartta_url, target: '_blank', rel: 'noopener' }, 'Avaa Retkikartassa ↗')
        : el('span'),
      hide));

  popup?.remove();
  popup = new maplibregl.Popup({ maxWidth: '340px' }).setLngLat(lngLat).setDOMContent(content).addTo(map);
}

function kanalintuSection(a) {
  const k = a.kanalintu;
  if (!k) return el('span');
  const phase = (days, max) => days == null ? '–'
    : days === 0 ? 'Ei lisämyyntiä'
    : `${days.toLocaleString('fi-FI')} vrk${max ? `, enintään ${max} / päivä` : ''}`;
  const metric = state.metric ?? 'yht';
  const { byCode, count } = state.density[metric];
  const d = byCode.get(a.code);
  const rows = [
    ['1. vaihe (kesäkuu)', phase(k.phase1_days, k.phase1_max_per_day)],
    ['2. vaihe (elokuu)', phase(k.phase2_days, k.phase2_max_per_day)],
    ['Yhteensä', `${(sumOrNull(k.phase1_days, k.phase2_days) ?? 0).toLocaleString('fi-FI')} vrk`],
  ];
  if (d) {
    rows.push(
      [`Tiheys (${METRICS[metric].label})`, `${formatDensity(d.value)} vrk / 1000 ha`],
      ['Sijoitus', el('span', {}, swatch(RAMP[d.cls]), `${d.rank}. / ${count} · luokka ${d.cls + 1}/5`)],
    );
  }
  return el('div', { className: 'kanalintu' },
    el('h3', {}, `Kanalinnun vuorokausiluvat ${k.year ?? ''}`.trim()),
    el('dl', {}, ...rows.flatMap(([key, v]) => [el('dt', {}, key), el('dd', {}, v)])));
}

// ------------------------------------------------------------------ helpers

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  const { dataset, ...rest } = props;
  Object.assign(node, rest);
  if (dataset) Object.assign(node.dataset, dataset);
  node.append(...children);
  return node;
}

function swatch(color) {
  const s = el('span', { className: 'swatch' });
  s.style.background = color;
  return s;
}

function formatArea(ha) {
  if (!ha) return '';
  return ha >= 1000
    ? `${Math.round(ha / 100).toLocaleString('fi-FI')} km²`
    : `${Math.round(ha).toLocaleString('fi-FI')} ha`;
}

function formatDensity(v) {
  return v.toLocaleString('fi-FI', { maximumFractionDigits: v < 10 ? 1 : 0, minimumFractionDigits: v < 10 ? 1 : 0 });
}

function showStatus(text, isError = false) {
  const s = $('#status');
  s.hidden = !text;
  s.textContent = text ?? '';
  s.classList.toggle('error', isError);
}
