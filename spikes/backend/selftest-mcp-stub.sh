#!/usr/bin/env bash
# Самопроверка заглушки MCP (кроссплатформенно: macOS/Linux, нужны python3 и curl).
# Не трогает cursor-agent. Пишет итог в stdout, код выхода 0 = все проверки прошли.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
T="$(mktemp -d "/tmp/kaban-spike-stubtest.XXXXXX")"
trap 'kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; rm -rf "$T"' EXIT
KABAN_RUN_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export KABAN_RUN_TOKEN
python3 "$HERE/mcp_stub_server.py" --port 0 --port-file "$T/port" --log "$T/log.jsonl" --ack KABAN-ACK-selftest 2>"$T/stub.err" &
SP=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "заглушка не стартовала"; cat "$T/stub.err"; exit 1; }
U="http://127.0.0.1:$(cat "$T/port")/mcp"
FAILS=0
ok() { echo "✅ $*"; }
ko() { echo "❌ $*"; FAILS=$((FAILS + 1)); }
post() { # post AUTH_HEADER BODY -> "<code> <body>"
  curl -s -w '\n%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    ${1:+-H "$1"} -d "$2" "$U"
}
GOOD="Authorization: Bearer $KABAN_RUN_TOKEN"
r="$(post "$GOOD" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"selftest","version":"1"}}}')"
case "$r" in *'"protocolVersion": "2025-06-18"'*200) ok "initialize 200";; *) ko "initialize: $r";; esac
r="$(post "$GOOD" '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
[ "$(echo "$r" | tail -n 1)" = 202 ] && ok "notifications/initialized 202" || ko "initialized: $r"
r="$(post "$GOOD" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
case "$r" in *report_progress*complete_stage*200) ok "tools/list: report_progress, complete_stage";; *) ko "tools/list: $r";; esac
r="$(post "$GOOD" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"report_progress","arguments":{"text":"hi"}}}')"
case "$r" in *'ok: progress recorded'*200) ok "tools/call report_progress";; *) ko "report_progress: $r";; esac
r="$(post "$GOOD" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"complete_stage","arguments":{"summary":"done"}}}')"
case "$r" in *KABAN-ACK-selftest*200) ok "tools/call complete_stage -> ACK";; *) ko "complete_stage: $r";; esac
r="$(post "Authorization: Bearer wrong-token" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"complete_stage","arguments":{"summary":"x"}}}')"
[ "$(echo "$r" | tail -n 1)" = 401 ] && ok "неверный Bearer -> 401" || ko "wrong bearer: $r"
r="$(post "" '{"jsonrpc":"2.0","id":6,"method":"tools/list"}')"
[ "$(echo "$r" | tail -n 1)" = 401 ] && ok "без Authorization -> 401" || ko "no auth: $r"
r="$(post 'Authorization: Bearer ${env:KABAN_RUN_TOKEN}' '{"jsonrpc":"2.0","id":7,"method":"tools/list"}')"
[ "$(echo "$r" | tail -n 1)" = 401 ] && ok "неподставленный \${env:...} -> 401" || ko "literal: $r"
c="$(curl -s -o /dev/null -w '%{http_code}' -H "$GOOD" "$U")"
[ "$c" = 405 ] && ok "GET /mcp -> 405" || ko "GET: $c"
sleep 0.2
st="$(python3 "$HERE/lib/kspike.py" stub-stats "$T/log.jsonl" --get auth)"
echo "лог заглушки, auth: $st"
case "$st" in *'"match": 6'*'"mismatch": 1'*) ok "лог: 6 match, 1 mismatch";; *'"mismatch": 1'*) ok "лог: есть mismatch";; *) ko "лог auth: $st";; esac
if grep -qF -- "$KABAN_RUN_TOKEN" "$T/log.jsonl"; then ko "токен попал в лог!"; else ok "токен в лог не попал"; fi
grep -q '"literal_placeholder"' "$T/log.jsonl" && ok "лог различает literal_placeholder" || ko "нет literal_placeholder"
echo "итого провалов: $FAILS"
exit "$FAILS"
