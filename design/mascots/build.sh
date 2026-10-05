#!/bin/bash
# Mascot kit: regenerate vectors + texture SVGs, check Swift == JS (if swiftc exists), render mascots-sheet.png at 2x.
# Never writes outside design/mascots.
set -e
cd "$(dirname "$0")"
node gen.js
if command -v swiftc >/dev/null; then
  swiftc -O ref/MascotKit.swift ref/main.swift -o /tmp/kaban-mkcheck && /tmp/kaban-mkcheck > /tmp/kaban-mk-swift.txt
  node -e "const v=require('./test-vectors.json'),K=require('./mascot-kit.js');const r=v.collisionDemo.resolved[v.collisionDemo.clash.id];
  const l=v.vectors.map(x=>[x.seed,x.fnv1a64,x.mascotIndex,x.textureIndex,x.emoji,x.texture].join('\t'));
  l.push('bump '+v.collisionDemo.clash.id+' -> '+r.mascot+' '+K.TEXTURES[r.texture].key);l.push('picker '+v.pickerDemo.seed);
  require('fs').writeFileSync('/tmp/kaban-mk-js.txt',l.join('\n')+'\n')"
  diff /tmp/kaban-mk-js.txt /tmp/kaban-mk-swift.txt && echo "Swift == JS"
fi
H=2015   # sheet height in pt (measured scrollHeight of the root element)
timeout 120 node ../tools/shot.js mascots.html mascots-sheet.png 1440 "${1:-$H}"
