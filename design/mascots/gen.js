// node gen.js — writes test-vectors.json, textures/*.svg, distribution stats (stdout). Pure, deterministic.
const fs = require('fs'), K = require('./mascot-kit.js');
const SEEDS = ['p-kaban', 'p-site', 'shop-api', 'mobile-app', 'docs-site', 'infra', '',
               '8a60b3cc-6141-80fc-8008-bbcd3bd40972', 'проект-кабан', 'p-kaban#1'];
const vectors = SEEDS.map(s => { const p = K.pick(s); return { seed: s, fnv1a64: '0x' + p.hash.toString(16).padStart(16, '0'),
  mascotIndex: p.mascot, textureIndex: p.texture, emoji: p.emoji, mascot: p.mascotKey, texture: p.textureKey }; });
// sanity: published FNV-1a 64 check values
const chk = { '': 'cbf29ce484222325', 'a': 'af63dc4c8601ec8c', 'foobar': '85944171f73967e8' };
for (const [s, v] of Object.entries(chk)) if (K.fnv1a64(s).toString(16) !== v) throw new Error('FNV mismatch for ' + JSON.stringify(s));
// collision demo: board added in this order
const board = [{ id: 'p-kaban', seed: 'p-kaban' }, { id: 'p-site', seed: 'p-site' }, { id: 'shop-api', seed: 'shop-api' }, { id: 'mobile-app', seed: 'mobile-app' }, { id: 'docs-site', seed: 'docs-site' }];
let clash = null;
const words = ['infra', 'billing', 'landing', 'analytics', 'auth', 'payments', 'search', 'admin', 'cli', 'sdk', 'ios', 'android', 'web', 'api', 'ml', 'etl', 'cms', 'crm', 'chat', 'maps'];
outer: for (let k = 0; k < 200; k++) for (const w of words) {
  const s = k ? `p-${w}-${k}` : `p-${w}`, i = K.indices(s);
  for (const b of board) { const j = K.indices(b.seed); if (i.mascot === j.mascot && i.texture === j.texture) { clash = { id: s, seed: s, with: b.id }; break outer; } }
}
const demo = [...board, { id: clash.id, seed: clash.seed }];
const resolved = K.resolveBoard(demo);
const picker = { projectId: 'p-kaban', want: { mascot: 1, texture: 1 }, seed: K.seedFor('p-kaban', 1, 1) };
picker.check = K.pick(picker.seed);
fs.writeFileSync('test-vectors.json', JSON.stringify({ kit: K.version, N: K.MASCOTS.length, textures: K.TEXTURES.length, vectors,
  collisionDemo: { addedOrder: demo.map(d => d.id), clash, resolved }, pickerDemo: { ...picker, check: { mascot: picker.check.mascot, texture: picker.check.texture, emoji: picker.check.emoji, textureKey: picker.check.textureKey } } }, null, 2) + '\n');
// textures: one-period tile and a 6×96 strip, light + dark
for (const t of K.TEXTURES) for (const mode of ['light', 'dark']) {
  const per = K.period(t), bg = mode === 'dark' ? '#2A2A2E' : '#FFFFFF';
  const H = t.kind === 'solid' ? 6 : per;
  fs.writeFileSync(`textures/${t.index}-${t.key}-${mode}-tile.svg`,
    `<svg xmlns="http://www.w3.org/2000/svg" width="${K.W}" height="${+H.toFixed(3)}" viewBox="0 0 ${K.W} ${+H.toFixed(3)}">${K.textureSVG(t, H, mode)}</svg>\n`);
  fs.writeFileSync(`textures/${t.index}-${t.key}-${mode}-strip.svg`,
    `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="96" viewBox="0 0 24 96"><rect width="24" height="96" rx="0" fill="${bg}"/>${K.textureSVG(t, 96, mode)}</svg>\n`);
}
// distribution over 240k synthetic seeds
const cm = new Array(30).fill(0), ct = new Array(8).fill(0), pair = new Array(240).fill(0); const M = 240000;
for (let i = 0; i < M; i++) { const x = K.indices(`p-${i.toString(36)}`); cm[x.mascot]++; ct[x.texture]++; pair[x.mascot * 8 + x.texture]++; }
const chi = (a, e) => a.reduce((s, v) => s + (v - e) ** 2 / e, 0);
console.log('vectors', vectors.length, 'clash', JSON.stringify(clash), 'picker', picker.seed);
console.log('mascot min/max', Math.min(...cm), Math.max(...cm), 'chi2(29df)', chi(cm, M / 30).toFixed(1));
console.log('texture min/max', Math.min(...ct), Math.max(...ct), 'chi2(7df)', chi(ct, M / 8).toFixed(1));
console.log('pairs min/max', Math.min(...pair), Math.max(...pair), 'chi2(239df)', chi(pair, M / 240).toFixed(1));
