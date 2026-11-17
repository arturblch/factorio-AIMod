#!/usr/bin/env node
/*
  Blueprint strings for AIMod, outside the game (Node, no dependencies).

    node tools/blueprint.js show   <string | @file>   map and entity list
    node tools/blueprint.js decode <string | @file>   the JSON inside
    node tools/blueprint.js encode <json file>        a blueprint string
    node tools/blueprint.js viewer                    copy blueprints/library.lua
                                                      into tools/blueprint-viewer.html

  A blueprint string is "0" + base64(zlib(JSON)). `encode` stamps the
  version of Factorio 2.1.24 when the JSON has none. The bot reads the same
  strings in game (util/blueprint.lua); blueprints/library.lua lists the
  ones it uses.
*/
'use strict';
const fs = require('fs');
const zlib = require('zlib');

// tile size of the entities early blueprints use; anything else counts as 1x1
const SIZES = {
  'burner-mining-drill': [2, 2], 'electric-mining-drill': [3, 3], 'stone-furnace': [2, 2],
  'steel-furnace': [2, 2], 'electric-furnace': [3, 3], 'assembling-machine-1': [3, 3],
  'assembling-machine-2': [3, 3], 'lab': [3, 3], 'boiler': [3, 2], 'steam-engine': [3, 5],
  'offshore-pump': [1, 2], 'radar': [3, 3], 'medium-electric-pole': [1, 1],
};
const LETTERS = {
  'burner-mining-drill': 'D', 'electric-mining-drill': 'E', 'stone-furnace': 'F', 'steel-furnace': 'F',
  'burner-inserter': 'i', 'inserter': 'i', 'long-handed-inserter': 'l', 'wooden-chest': 'c', 'iron-chest': 'c',
  'transport-belt': 'b', 'underground-belt': 'u', 'splitter': 's', 'assembling-machine-1': 'A',
  'assembling-machine-2': 'A', 'lab': 'L', 'boiler': 'O', 'steam-engine': 'S', 'offshore-pump': 'W',
  'small-electric-pole': 'p', 'pipe': '=', 'pipe-to-ground': '~',
};
// mining radius of drills, for the ore their area needs
const MINING_RADIUS = { 'burner-mining-drill': 0.99, 'electric-mining-drill': 2.49 };
const ARROWS = { 0: '^', 4: '>', 8: 'v', 12: '<' };
const DIRECTIONS = { 0: 'north', 4: 'east', 8: 'south', 12: 'west' };
const VERSION_2_1_24 = (2n << 48n) + (1n << 32n) + (24n << 16n);

function readArg(arg) {
  if (!arg) throw new Error('missing argument');
  return arg.startsWith('@') ? fs.readFileSync(arg.slice(1), 'utf8') : arg;
}

function decode(text) {
  text = text.trim();
  if (text[0] !== '0') throw new Error('not a blueprint string (it starts with "0")');
  return JSON.parse(zlib.inflateSync(Buffer.from(text.slice(1), 'base64')).toString('utf8'));
}

function encode(object) {
  if (object.blueprint && object.blueprint.version === undefined) {
    object.blueprint.version = Number(VERSION_2_1_24);
  }
  return '0' + zlib.deflateSync(Buffer.from(JSON.stringify(object), 'utf8'), { level: 9 }).toString('base64');
}

function size(entity) {
  const [w, h] = SIZES[entity.name] || [1, 1];
  const d = entity.direction || 0;
  return d === 4 || d === 12 ? [h, w] : [w, h];
}

// tiles x0..x1, y0..y1 an entity covers, from its center
function footprint(entity) {
  const [w, h] = size(entity);
  const x0 = Math.round(entity.position.x - w / 2), y0 = Math.round(entity.position.y - h / 2);
  return { x0, y0, x1: x0 + w - 1, y1: y0 + h - 1 };
}

function show(object) {
  const blueprint = object.blueprint;
  if (!blueprint) {
    const kind = Object.keys(object)[0];
    return `not a single blueprint but a ${kind}` +
      (object.blueprint_book ? ` with ${object.blueprint_book.blueprints.length} blueprints` : '');
  }
  const entities = blueprint.entities || [];
  const cells = new Map();
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const mark = (x, y, ch, weak) => {
    const key = x + ',' + y;
    if (weak && cells.has(key)) return;
    cells.set(key, ch);
    minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  };
  for (const e of entities) {
    const r = MINING_RADIUS[e.name];
    if (r) {
      for (let x = Math.floor(e.position.x - r); x <= Math.ceil(e.position.x + r) - 1; x++)
        for (let y = Math.floor(e.position.y - r); y <= Math.ceil(e.position.y + r) - 1; y++) mark(x, y, '.', true);
    }
  }
  for (const e of entities) {
    const f = footprint(e);
    const ch = LETTERS[e.name] || '?';
    for (let x = f.x0; x <= f.x1; x++) for (let y = f.y0; y <= f.y1; y++) mark(x, y, ch);
    if (e.direction !== undefined && ARROWS[e.direction] && (f.x1 > f.x0 || ch === 'i' || ch === 'b')) {
      mark(Math.floor(e.position.x), Math.floor(e.position.y), ARROWS[e.direction]);
    }
  }
  const lines = [];
  lines.push(`"${blueprint.label || '(no label)'}": ${entities.length} entities, ` +
    `${maxX - minX + 1} x ${maxY - minY + 1} tiles` +
    (blueprint.version ? `, made in ${versionText(blueprint.version)}` : ''));
  lines.push('');
  for (let y = minY; y <= maxY; y++) {
    let row = '  ';
    for (let x = minX; x <= maxX; x++) row += cells.get(x + ',' + y) || ' ';
    lines.push(row);
  }
  lines.push('');
  lines.push('  letters: ' + [...new Set(entities.map(e => (LETTERS[e.name] || '?') + ' ' + e.name))].join(', ') +
    '; . = ore the drills mine; ^ > v < = facing');
  for (const e of entities) {
    lines.push(`  ${e.entity_number}. ${e.name} at (${e.position.x}, ${e.position.y})` +
      (e.direction ? ` facing ${DIRECTIONS[e.direction] || e.direction}` : ''));
  }
  return lines.join('\n');
}

function versionText(v) {
  const n = BigInt(v);
  return [48n, 32n, 16n].map(s => String((n >> s) & 0xffffn)).join('.');
}

// The blueprints and modules of blueprints/library.lua, read with patterns
// (the file keeps to one entry per line).
function readLibrary(file) {
  const text = fs.readFileSync(file, 'utf8');
  const blueprints = {};
  for (const m of text.matchAll(/\["([^"]+)"\]\s*=\s*"(0[^"]+)"/g)) blueprints[m[1]] = m[2];
  const modules = [];
  for (const m of text.matchAll(/^\s*\{([^\n]*name\s*=[^\n]*)\},?\s*(?:--.*)?$/gm)) {
    const fields = {};
    for (const f of m[1].matchAll(/(\w+)\s*=\s*("([^"]*)"|true|false)/g)) fields[f[1]] = f[3] !== undefined ? f[3] : f[2] === 'true';
    if (fields.name) modules.push(fields);
  }
  return { blueprints, modules };
}

function viewer(root) {
  const library = readLibrary(root + '/blueprints/library.lua');
  const page = root + '/tools/blueprint-viewer.html';
  const html = fs.readFileSync(page, 'utf8').replace(/\/\*LIBRARY-START\*\/[\s\S]*?\/\*LIBRARY-END\*\//,
    '/*LIBRARY-START*/' + JSON.stringify(library) + '/*LIBRARY-END*/');
  fs.writeFileSync(page, html);
  return `${page}: ${Object.keys(library.blueprints).length} blueprints, ${library.modules.length} modules`;
}

function main(argv) {
  const [command, arg] = argv;
  if (command === 'decode') return JSON.stringify(decode(readArg(arg)), null, 2);
  if (command === 'show') return show(decode(readArg(arg)));
  if (command === 'encode') return encode(JSON.parse(fs.readFileSync(arg, 'utf8')));
  if (command === 'viewer') return viewer(require('path').resolve(__dirname, '..'));
  return 'usage: node tools/blueprint.js show|decode <string | @file>, encode <json file>, viewer';
}

if (require.main === module) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (e) {
    console.error('error: ' + e.message);
    process.exit(1);
  }
}
module.exports = { decode, encode, show, readLibrary };
