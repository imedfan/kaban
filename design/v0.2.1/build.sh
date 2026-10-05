#!/bin/bash
# Render v0.2.1 screens into v0.2.1/png/ at 2x. Never writes to ../png (v0.1) or ../v0.2/png.
cd "$(dirname "$0")"
s() { timeout 90 node ../tools/shot.js "$1" "png/$2" ${3:-1440} ${4:-900}; }
if [ -n "$1" ]; then s "$@"; exit; fi
s cards.html 01-cards-suspicious.png
s cards-bounce-limits.html 01c-cards-bounce-limits.png 1440 720
s details-suspicious.html 02-details-suspicious.png
s details-suspicious-dark.html 02-details-suspicious-dark.png
s details-suspicious-stale.html 02b-details-suspicious-stale.png
s project-git.html 03-project-git-presets.png
s stage-git.html 04-stage-git-overrides.png
s return-sheet-gate.html 05-return-sheet-gate.png
s return-sheet-gate-dark.html 05-return-sheet-gate-dark.png
s return-sheet-merge.html 05b-return-sheet-merge.png
s add-project-identity.html 06-add-project-identity.png
s add-project-identity-dark.html 06-add-project-identity-dark.png
