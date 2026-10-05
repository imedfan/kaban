#!/bin/bash
# Render v0.2 screens into v0.2/png/ at 2x. Never writes to ../png (v0.1).
cd "$(dirname "$0")"
s() { timeout 90 node ../tools/shot.js "$1" "png/$2" ${3:-1440} ${4:-900}; }
if [ -n "$1" ]; then s "$@"; exit; fi
s board.html 01-board-limits-flags.png
s board-dark.html 01-board-limits-flags-dark.png
s cards.html 02-cards-states.png 1440 1060
s details-substituted.html 03-details-model-substituted.png
s details-substituted-dark.html 03-details-model-substituted-dark.png
s details-run-limit.html 03b-details-run-limit.png
s pipeline-invalid.html 04-pipeline-invalid.png
s project-mcp.html 05-project-mcp.png
s mac-quota.html 06-mac-quota-menubar.png
