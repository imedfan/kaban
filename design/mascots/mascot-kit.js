// Kaban mascot kit v1 — seed → (mascot, edge texture). Reference implementation (browser + Node).
// The ORDER of MASCOTS and TEXTURES is part of the spec: never reorder, insert or remove (that remaps every project).
// If the set must change, introduce a new kit version and migrate seeds explicitly.
(function (root) {
  const MASCOTS = [
    // Лес
    ['🦊', 'U+1F98A', 'fox', 'лиса', 'forest'],
    ['🐗', 'U+1F417', 'boar', 'кабан', 'forest'],
    ['🦉', 'U+1F989', 'owl', 'сова', 'forest'],
    ['🦔', 'U+1F994', 'hedgehog', 'ёж', 'forest'],
    ['🐺', 'U+1F43A', 'wolf', 'волк', 'forest'],
    ['🦌', 'U+1F98C', 'deer', 'олень', 'forest'],
    ['🦝', 'U+1F99D', 'raccoon', 'енот', 'forest'],
    ['🐰', 'U+1F430', 'rabbit', 'кролик', 'forest'],
    // Домашние
    ['🐱', 'U+1F431', 'cat', 'кошка', 'home'],
    ['🐶', 'U+1F436', 'dog', 'собака', 'home'],
    ['🦙', 'U+1F999', 'llama', 'лама', 'home'],
    // Север
    ['🐧', 'U+1F427', 'penguin', 'пингвин', 'north'],
    ['🐼', 'U+1F43C', 'panda', 'панда', 'north'],
    ['🐨', 'U+1F428', 'koala', 'коала', 'north'],
    ['🦭', 'U+1F9AD', 'seal', 'тюлень', 'north'],
    // Саванна
    ['🦁', 'U+1F981', 'lion', 'лев', 'savanna'],
    ['🦒', 'U+1F992', 'giraffe', 'жираф', 'savanna'],
    ['🦓', 'U+1F993', 'zebra', 'зебра', 'savanna'],
    ['🦛', 'U+1F99B', 'hippo', 'бегемот', 'savanna'],
    // Вода
    ['🐳', 'U+1F433', 'whale', 'кит', 'water'],
    ['🐬', 'U+1F42C', 'dolphin', 'дельфин', 'water'],
    ['🦈', 'U+1F988', 'shark', 'акула', 'water'],
    ['🐙', 'U+1F419', 'octopus', 'осьминог', 'water'],
    ['🐠', 'U+1F420', 'tropical-fish', 'рыбка', 'water'],
    ['🦦', 'U+1F9A6', 'otter', 'выдра', 'water'],
    // Рептилии и древние
    ['🐢', 'U+1F422', 'turtle', 'черепаха', 'reptiles'],
    ['🦖', 'U+1F996', 't-rex', 'тираннозавр', 'reptiles'],
    // Крылья и сказка
    ['🦋', 'U+1F98B', 'butterfly', 'бабочка', 'wings'],
    ['🦚', 'U+1F99A', 'peacock', 'павлин', 'wings'],
    ['🦄', 'U+1F984', 'unicorn', 'единорог', 'wings'],
  ].map(([emoji, cp, key, ru, group], index) => ({ index, emoji, cp, key, ru, group }));

  // Edge textures. Units: pt. Strip = x 0…W at the card's left edge, full card height, clipped by the card shape.
  // ink: light #000000, dark #FFFFFF, at `opacity`. Strokes: butt caps; joins as listed.
  const W = 6;
  const TEXTURES = [
    { index: 0, key: 'dots',       ru: 'точки',               kind: 'dots',       r: 1.0, pitch: 6, points: [[1.5, 1.5], [4.5, 4.5]], opacity: { light: 0.40, dark: 0.42 } },
    { index: 1, key: 'stripes',    ru: 'косые полосы',        kind: 'stripes',    angle: 45, stroke: 1.5, spacing: 4, opacity: { light: 0.30, dark: 0.34 } },
    { index: 2, key: 'crosshatch', ru: 'косая сетка',         kind: 'crosshatch', angle: 45, stroke: 0.9, spacing: 4, opacity: { light: 0.30, dark: 0.34 } },
    { index: 3, key: 'waves',      ru: 'волна',               kind: 'waves',      centerX: 3, amplitude: 1.75, wavelength: 8, stroke: 1.4, join: 'round', opacity: { light: 0.42, dark: 0.46 } },
    { index: 4, key: 'zigzag',     ru: 'зигзаг',              kind: 'zigzag',     xMin: 1, xMax: 5, period: 6, stroke: 1.25, join: 'miter', opacity: { light: 0.42, dark: 0.46 } },
    { index: 5, key: 'grid',       ru: 'сетка',               kind: 'grid',       pitch: 3, offset: 1.5, stroke: 0.75, opacity: { light: 0.32, dark: 0.36 } },
    { index: 6, key: 'chevrons',   ru: 'шевроны',             kind: 'chevrons',   xMin: 0.75, xMax: 5.25, depth: 2.25, period: 4, stroke: 1.25, join: 'miter', opacity: { light: 0.42, dark: 0.46 } },
    { index: 7, key: 'solid-thin', ru: 'сплошная',          kind: 'solid',      barWidth: 2, opacity: { light: 0.30, dark: 0.34 } },
  ];

  // ---- hash: FNV-1a 64 over the UTF-8 bytes of mascotSeed (no normalisation, no trimming) ----
  const OFFSET = 0xcbf29ce484222325n, PRIME = 0x100000001b3n, MASK = 0xffffffffffffffffn;
  function fnv1a64(seed) {
    let h = OFFSET;
    for (const b of new TextEncoder().encode(seed)) { h ^= BigInt(b); h = (h * PRIME) & MASK; }
    return h;
  }
  // N = 30 is deliberately NOT a power of two: h % 30 depends on all 64 bits
  // (the low 8 bits of FNV-1a are weak; never use h & mask).
  function indices(seed) {
    const h = fnv1a64(seed), n = BigInt(MASCOTS.length), t = BigInt(TEXTURES.length);
    return { hash: h, mascot: Number(h % n), texture: Number((h / n) % t) };
  }
  function pick(seed) {
    const i = indices(seed);
    return { ...i, emoji: MASCOTS[i.mascot].emoji, mascotKey: MASCOTS[i.mascot].key, textureKey: TEXTURES[i.texture].key };
  }
  // Display-only collision avoidance. `projects` = [{id, seed}] in the order they were added to the board
  // (BoardSetStore append order; NOT the current lane order). Later-added project bumps its texture +1, +2… (mod 8)
  // until (mascot, texture) is free. Mascot never changes. Nothing is persisted.
  function resolveBoard(projects) {
    const taken = new Set(), out = {};
    for (const p of projects) {
      const base = indices(p.seed);
      let tex = base.texture;
      for (let k = 0; k < TEXTURES.length; k++) {
        const t = (base.texture + k) % TEXTURES.length;
        if (!taken.has(base.mascot * 8 + t)) { tex = t; break; }
      }
      taken.add(base.mascot * 8 + tex);
      out[p.id] = { mascot: base.mascot, texture: tex, bumped: tex !== base.texture, baseTexture: base.texture };
    }
    return out;
  }
  // MascotPicker: the user chooses (mascot, texture); find a seed for setMascot(projectId, seed).
  // Smallest k ≥ 1 with indices(`${projectId}#${k}`) == target (≈240 tries on average).
  function seedFor(projectId, mascot, texture, maxTries = 100000) {
    for (let k = 1; k <= maxTries; k++) {
      const s = `${projectId}#${k}`, i = indices(s);
      if (i.mascot === mascot && i.texture === texture) return s;
    }
    return null;
  }

  // ---- texture geometry (same formulas the Swift Canvas uses) ----
  // returns SVG markup for the strip area [0,W]×[0,H] in `mode` ('light'|'dark')
  function textureSVG(t, H, mode, opts = {}) {
    const ink = mode === 'dark' ? '#FFFFFF' : '#000000', op = t.opacity[mode];
    const f = (v) => +v.toFixed(3);
    const parts = [];
    const S = (d) => `<path d="${d}" fill="none" stroke="${ink}" stroke-width="${t.stroke}" stroke-linejoin="${t.join || 'miter'}" stroke-linecap="butt"/>`;
    if (t.kind === 'dots') {
      for (let y = 0; y < H + t.pitch; y += t.pitch) for (const [x, dy] of t.points) parts.push(`<circle cx="${x}" cy="${f(y + dy)}" r="${t.r}" fill="${ink}"/>`);
    } else if (t.kind === 'stripes' || t.kind === 'crosshatch') {
      const step = t.spacing * Math.SQRT2; let d = '';
      for (let c = -W - step; c < H + W + step; c += step) {
        d += `M0 ${f(c + W)}L${W} ${f(c)}`;                       // "/" rising to the right
        if (t.kind === 'crosshatch') d += `M0 ${f(c)}L${W} ${f(c + W)}`; // "\"
      }
      parts.push(S(d));
    } else if (t.kind === 'waves') {
      let d = '';
      for (let y = -1; y <= H + 1; y += 0.5) d += (d ? 'L' : 'M') + `${f(t.centerX + t.amplitude * Math.sin(2 * Math.PI * y / t.wavelength))} ${f(y)}`;
      parts.push(S(d));
    } else if (t.kind === 'zigzag') {
      let d = '', half = t.period / 2, i = 0;
      for (let y = -half; y <= H + half; y += half, i++) d += (d ? 'L' : 'M') + `${i % 2 ? t.xMax : t.xMin} ${f(y)}`;
      parts.push(S(d));
    } else if (t.kind === 'grid') {
      let d = '';
      for (let x = t.offset; x < W; x += t.pitch) d += `M${x} 0V${H}`;
      for (let y = t.offset; y < H; y += t.pitch) d += `M0 ${y}H${W}`;
      parts.push(S(d));
    } else if (t.kind === 'chevrons') {
      let d = '';
      for (let y = -t.period; y < H + t.period; y += t.period) d += `M${t.xMin} ${f(y)}L${f((t.xMin + t.xMax) / 2)} ${f(y + t.depth)}L${t.xMax} ${f(y)}`;
      parts.push(S(d));
    } else if (t.kind === 'solid') {
      parts.push(`<rect x="0" y="0" width="${t.barWidth}" height="${H}" fill="${ink}"/>`);
    }
    const id = `c${t.index}${mode[0]}${Math.round(H)}${opts.uid || ''}`;
    return `<defs><clipPath id="${id}"><rect width="${W}" height="${H}"/></clipPath></defs><g clip-path="url(#${id})" opacity="${op}">${parts.join('')}</g>`;
  }
  // vertical repeat period of each texture (for tile export)
  function period(t) {
    return ({ dots: t.pitch, stripes: t.spacing * Math.SQRT2, crosshatch: t.spacing * Math.SQRT2, waves: t.wavelength,
              zigzag: t.period, grid: t.pitch, chevrons: t.period, solid: 1 })[t.kind];
  }

  const KIT = { version: 1, W, MASCOTS, TEXTURES, fnv1a64, indices, pick, resolveBoard, seedFor, textureSVG, period };
  if (typeof module !== 'undefined') module.exports = KIT; else root.MascotKit = KIT;
})(typeof window !== 'undefined' ? window : globalThis);
