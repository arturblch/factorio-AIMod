#!/usr/bin/env node
/*
  Community blueprints kept for later (blueprints/found/catalog.lua), Node, no
  dependencies. The bot doesn't build them: the catalog is a shelf to pick
  library modules from (blueprints/library.lua), with what util/blueprint.lua
  makes of each one.

    node tools/found-blueprints.js fetch <dir> <id>...   download Factorio Prints entries
    node tools/found-blueprints.js build <dir>...        write the catalog from downloads
    node tools/found-blueprints.js checks <file>         add the bot's checks to it

  fetch: Factorio Prints (factorioprints.com, also factorio.school) serves an
  entry's JSON without signing in at
  https://factorio-blueprint-firebase-cdn.pages.dev/<first 3 chars of the id,
  lowercased>/<id>.json; ids come from its pages, or from Blueprint Atlas
  (factorio.menzies.io/?uses=entity:burner-mining-drill, links /prints/<id>).

  build: takes from every blueprint (books are walked) the burner-era ones
  (burner drills or stone furnaces, belts, burner inserters, chests; no
  power) and small steam plants (offshore pump, boiler, steam engine), up to
  MAX_ENTITIES; drops repeats; turns 1.x directions (8 to a turn) into 2.x
  (16); and adds each separate part of a blueprint (entities that touch) as
  an entry of its own, since a bot module mines one resource. Checks already
  in the catalog are kept for entries that are still there.

  checks: the unit test tests/unit/found_blueprints_test.lua writes what
  Blueprint.module says of every entry for iron ore, copper ore, coal and
  stone to script-output/found-checks.txt (in the run's work folder:
  <WorkDir>/data/script-output/); this puts it into the catalog.
*/
'use strict';
const fs = require('fs');
const path = require('path');
const https = require('https');
const { decode, encode } = require('./blueprint.js');

const ROOT = path.resolve(__dirname, '..');
const CATALOG = path.join(ROOT, 'blueprints', 'found', 'catalog.lua');
const MAX_ENTITIES = 400;
const BURNER = new Set(['burner-mining-drill', 'stone-furnace', 'burner-inserter', 'wooden-chest',
  'iron-chest', 'transport-belt', 'underground-belt', 'splitter', 'constant-combinator', 'pipe',
  'pipe-to-ground', 'stone-wall', 'inserter', 'long-handed-inserter']);
const STEAM = new Set([...BURNER, 'boiler', 'steam-engine', 'offshore-pump', 'small-electric-pole',
  'medium-electric-pole', 'lab', 'assembling-machine-1', 'electric-mining-drill', 'fast-inserter']);
const SIZES = { 'burner-mining-drill': [2, 2], 'stone-furnace': [2, 2], 'boiler': [3, 2],
  'steam-engine': [3, 5], 'offshore-pump': [1, 2], 'lab': [3, 3], 'assembling-machine-1': [3, 3],
  'electric-mining-drill': [3, 3], 'splitter': [2, 1] };

function versionText(v) {
  if (v === undefined) return '?';
  const n = BigInt(v);
  return [48n, 32n, 16n].map(s => String((n >> s) & 0xffffn)).join('.');
}

function fetchEntry(dir, id) {
  const url = `https://factorio-blueprint-firebase-cdn.pages.dev/${id.slice(0, 3).toLowerCase()}/${id}.json`;
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'aimod-found-blueprints' } }, res => {
      if (res.statusCode !== 200) { res.resume(); return reject(new Error(`${id}: HTTP ${res.statusCode}`)); }
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => { fs.writeFileSync(path.join(dir, id + '.json'), Buffer.concat(chunks)); resolve(id); });
    }).on('error', reject);
  });
}

// the tiles an entity covers (2.x directions)
function tiles(e) {
  let [w, h] = SIZES[e.name] || [1, 1];
  if ((e.direction || 0) % 8 === 4) [w, h] = [h, w];
  const x0 = Math.round(e.position.x - w / 2), y0 = Math.round(e.position.y - h / 2);
  const list = [];
  for (let x = x0; x < x0 + w; x++) for (let y = y0; y < y0 + h; y++) list.push(x + ',' + y);
  return list;
}

// groups of entities that touch each other
function parts(entities) {
  const owner = new Map();
  entities.forEach((e, i) => tiles(e).forEach(t => owner.set(t, i)));
  const group = entities.map((_, i) => i);
  const find = i => (group[i] === i ? i : (group[i] = find(group[i])));
  entities.forEach((e, i) => tiles(e).forEach(t => {
    const [x, y] = t.split(',').map(Number);
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const j = owner.get((x + dx) + ',' + (y + dy));
      if (j !== undefined) group[find(i)] = find(j);
    }
  }));
  const byRoot = new Map();
  entities.forEach((e, i) => { const r = find(i); if (!byRoot.has(r)) byRoot.set(r, []); byRoot.get(r).push(e); });
  return [...byRoot.values()];
}

// the same layout wherever it was drawn
function fingerprint(entities) {
  const minX = Math.min(...entities.map(e => e.position.x)), minY = Math.min(...entities.map(e => e.position.y));
  return entities.map(e => `${e.name}@${e.position.x - minX},${e.position.y - minY}/${e.direction || 0}/${e.type || ''}`)
    .sort().join(';');
}

function counts(entities) {
  const c = {};
  for (const e of entities) c[e.name] = (c[e.name] || 0) + 1;
  return Object.keys(c).sort().map(k => `${k} ${c[k]}`).join(', ');
}

function kind(entities) {
  const names = new Set(entities.map(e => e.name));
  if (!entities.length || entities.length > MAX_ENTITIES) return null;
  if ([...names].every(n => BURNER.has(n)) && (names.has('burner-mining-drill') || names.has('stone-furnace'))) return 'burner';
  if ([...names].every(n => STEAM.has(n)) && names.has('boiler') && names.has('steam-engine') && names.has('offshore-pump')
    && entities.length <= 60) return 'steam';
  return null;
}

function slug(text) {
  return text.toLowerCase().replace(/\[[^\]]*\]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'blueprint';
}

// A Lua 5.2 string literal (Factorio's Lua has no \u escapes: those become
// decimal byte escapes of their UTF-8).
function luaString(s) {
  return JSON.stringify(String(s)).replace(/\\u([0-9a-f]{4})/gi, (m, h) =>
    [...Buffer.from(String.fromCharCode(parseInt(h, 16)), 'utf8')].map(b => '\\' + String(b).padStart(3, '0')).join(''));
}

function readCatalog() {
  if (!fs.existsSync(CATALOG)) return new Map();
  const old = new Map();
  for (const m of fs.readFileSync(CATALOG, 'utf8').matchAll(/^\s*\{id="([^"]+)".*?(fits=\{[^}]*\}), note=("(?:[^"\\]|\\.)*")/gm)) {
    old.set(m[1], { fits: m[2], note: m[3] });
  }
  return old;
}

function build(dirs) {
  const old = readCatalog();
  const seen = new Set();
  const entries = [];
  const add = (meta, blueprint, entities, label, partOf) => {
    const k = kind(entities);
    if (!k) return null;
    const print = fingerprint(entities);
    if (seen.has(print)) return null;
    seen.add(print);
    let id = `${slug(meta.title)}--${slug(label)}`;
    for (let n = 2; entries.some(e => e.id === id); n++) id = `${slug(meta.title)}--${slug(label)}-${n}`;
    const numbered = entities.map((e, i) => Object.assign({}, e, { entity_number: i + 1 }));
    const bp = { item: 'blueprint', label, entities: numbered };
    if (blueprint.description && !partOf) bp.description = blueprint.description;
    if (blueprint.icons) bp.icons = blueprint.icons;
    entries.push({ id, kind: k, title: meta.title, source: meta.source, path: meta.path, version: meta.version,
      entities: counts(entities), part_of: partOf, string: encode({ blueprint: bp }) });
    return id;
  };
  for (const dir of dirs) {
    for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort()) {
      const entry = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      const fpId = file.replace(/\.json$/, '');
      let root;
      try { root = decode(entry.blueprintString); } catch (e) { continue; }
      const walk = (node, trail) => {
        if (node.blueprint) {
          const b = node.blueprint;
          const major = Number(BigInt(b.version || 0) >> 48n);
          const entities = (b.entities || []).map(e => {
            const o = { name: e.name, position: e.position };
            if (e.direction) o.direction = major < 2 ? e.direction * 2 : e.direction;
            if (e.type) o.type = e.type;
            return o;
          });
          const label = b.label || '(no label)';
          const meta = { title: entry.title, source: `https://factorioprints.com/view/${fpId}`,
            path: trail + label, version: versionText(b.version) };
          const whole = add(meta, b, entities, label, null);
          const split = parts(entities);
          if (kind(entities) && split.length > 1) {
            split.forEach((p, i) => {
              if (p.length >= 2) add(meta, b, p, `${label} (part ${i + 1} of ${split.length})`, whole || '(a repeat)');
            });
          }
        }
        if (node.blueprint_book) {
          const bk = node.blueprint_book;
          for (const x of bk.blueprints || []) walk(x, `${trail}${bk.label || 'book'} / `);
        }
      };
      walk(root, '');
    }
  }
  entries.sort((a, b) => (a.kind === b.kind ? a.id.localeCompare(b.id) : a.kind.localeCompare(b.kind)));
  const lines = [
    '--[[',
    '  Community blueprints kept for later: burner-era layouts and small steam',
    '  plants from Factorio Prints (factorioprints.com), found through Blueprint',
    '  Atlas (factorio.menzies.io) in 2026-11. The bot does not build them;',
    '  blueprints/library.lua lists what it builds. See blueprints/found/README.md.',
    '',
    '  Written by `node tools/found-blueprints.js build`; `checks` fills `fits`',
    '  and `note` from tests/unit/found_blueprints_test.lua. One entry a line:',
    '   - id: a name made of the entry\'s title and the blueprint\'s label',
    '   - kind: "burner" (no power) or "steam" (an offshore pump, boilers, engines)',
    '   - title, source: the Factorio Prints entry; path: the blueprint in its book',
    '   - version: the game version it was made in (1.x directions are turned',
    '     into 2.x ones here: blueprint holds a 2.x string)',
    '   - part_of: for one part of a bigger blueprint, that blueprint\'s id',
    '   - fits: {resource = score} for every resource Blueprint.module takes it',
    '     with no errors (score: ModuleLibrary.report, the plain drill and furnace',
    '     is 0.986); empty when it takes none, or not checked yet',
    '   - note: the outputs it makes, or what is wrong with it',
    '  The authors gave no license: credit the source when using a layout.',
    ']]',
    'return {',
  ];
  for (const e of entries) {
    const kept = old.get(e.id);
    const fields = [`id=${luaString(e.id)}`, `kind=${luaString(e.kind)}`, `title=${luaString(e.title)}`,
      `source=${luaString(e.source)}`, `path=${luaString(e.path)}`, `version=${luaString(e.version)}`,
      `entities=${luaString(e.entities)}`];
    if (e.part_of) fields.push(`part_of=${luaString(e.part_of)}`);
    fields.push(kept ? kept.fits : 'fits={}', `note=${kept ? kept.note : '""'}`, `blueprint=${luaString(e.string)}`);
    lines.push(`  {${fields.join(', ')}},`);
  }
  lines.push('}', '');
  fs.mkdirSync(path.dirname(CATALOG), { recursive: true });
  fs.writeFileSync(CATALOG, lines.join('\n'));
  const byKind = entries.reduce((m, e) => (m[e.kind] = (m[e.kind] || 0) + 1, m), {});
  return `${CATALOG}: ${entries.length} blueprints (${Object.entries(byKind).map(([k, n]) => `${n} ${k}`).join(', ')})`;
}

// lines "<id>\t<resource>\tOK\t<score>\t<outputs>" or "<id>\t<resource>\tERR\t<why>"
function checks(file) {
  const results = new Map();
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const [id, resource, status, a, b] = line.split('\t');
    if (!id || !status) continue;
    if (!results.has(id)) results.set(id, { fits: [], outputs: new Set(), errors: [] });
    const r = results.get(id);
    if (status === 'OK') { r.fits.push([resource, Number(a)]); if (b) b.split(',').forEach(o => r.outputs.add(o)); }
    else r.errors.push(`${resource}: ${a}`);
  }
  let text = fs.readFileSync(CATALOG, 'utf8');
  let fitting = 0, checked = 0;
  text = text.replace(/^(\s*\{id="([^"]+)".*?)fits=\{[^}]*\}, note=("(?:[^"\\]|\\.)*")/gm, (m, head, id) => {
    const r = results.get(id);
    if (!r) return m;
    checked++;
    if (r.fits.length) fitting++;
    const fits = r.fits.map(([res, s]) => `["${res}"]=${s.toFixed(3)}`).join(', ');
    // the commonest reason when nothing fits (iron ore, as the others mostly repeat it)
    const note = r.fits.length ? `makes ${[...r.outputs].sort().join(', ')}`
      : (r.errors.find(e => e.startsWith('iron-ore')) || r.errors[0] || '').replace(/^[a-z-]+: /, '').slice(0, 200);
    return `${head}fits={${fits}}, note=${luaString(note)}`;
  });
  fs.writeFileSync(CATALOG, text);
  return `${CATALOG}: ${checked} checked, ${fitting} fit the bot`;
}

async function main(argv) {
  const [command, ...args] = argv;
  if (command === 'fetch') {
    const [dir, ...ids] = args;
    fs.mkdirSync(dir, { recursive: true });
    for (const id of ids) {
      try { await fetchEntry(dir, id); console.log('fetched', id); } catch (e) { console.error(e.message); }
    }
    return `${ids.length} asked for`;
  }
  if (command === 'build') return build(args);
  if (command === 'checks') return checks(args[0]);
  return 'usage: node tools/found-blueprints.js fetch <dir> <id>... | build <dir>... | checks <found-checks.txt>';
}

if (require.main === module) {
  main(process.argv.slice(2)).then(out => console.log(out), e => { console.error('error: ' + e.message); process.exit(1); });
}
