#!/usr/bin/env bash
# Спайк 2 (§14 п.2, §9 архитектуры): MCP-сервер доски из клона задачи.
#
# Поднимаем две заглушки mcp_stub_server.py на 127.0.0.1 со случайными портами:
#   kaban-board   — «доска», требует Bearer = $KABAN_RUN_TOKEN (токен только в env);
#   project-dummy — «чужой» сервер проекта, без авторизации (смотрим, подключается ли он).
# Каждый HTTP-запрос заглушки пишут в stub-*.jsonl (метод, инструмент, совпал ли Bearer).
#
# (a) .cursor/mcp.json в клоне с "Authorization": "Bearer ${env:KABAN_RUN_TOKEN}":
#     подхват, интерполяция env, приходят ли tools/call с верным Bearer,
#     нужен ли --approve-mcps в -p (с ним / без него / без --force), сохраняется ли одобрение.
# (b) подключение БЕЗ записи в репозиторий: отдельный HOME с ~/.cursor/mcp.json
#     (и жив ли логин), CURSOR_CONFIG_DIR, mcp.json в родительском каталоге клона, флаги CLI.
# (c) в проекте закоммичен свой .cursor/mcp.json с project-dummy: что показывает
#     `mcp list`, одобряет ли его --approve-mcps; подмена файла демоном и возврат из main.
# (d) формат `mcp list` для fail-closed сравнения.
#
# Запуск: KABAN_SPIKE_MODEL=<id> ./spike2-mcp.sh      Стоимость: 5–8 коротких запусков.
SPIKE_NAME=spike2-mcp
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/common.sh"
require_macos
require_agent
need git
need curl

STUB="$SPIKES_DIR/mcp_stub_server.py"
# Тестовый токен запуска: случайный, живёт только в env этого скрипта; в файлы не пишется,
# scrub в конце дополнительно маскирует его значение, если оно где-то всплывёт.
KABAN_RUN_TOKEN="$("$PY" -c 'import secrets; print(secrets.token_hex(24))')"
export KABAN_RUN_TOKEN
SCRUB_ENV=KABAN_RUN_TOKEN
ACK="KABAN-ACK-$("$PY" -c 'import secrets; print(secrets.token_hex(4))')"
BOARD=kaban-board
DUMMY=project-dummy

MCP_PROMPT="You have MCP tools from the server named $BOARD. First call its tool report_progress with text \"spike2 progress\". Then call its tool complete_stage with summary \"spike2 done\". Reply with the exact text returned by complete_stage and nothing else. Do not run shell commands and do not edit files."

# ---------------------------------------------------------------- заглушки
STUB_DIR="$(mktmp stubs)"
start_stub() { # start_stub NAME LOG [--no-auth] -> печатает порт
  local name="$1" logf="$2"; shift 2
  "$PY" "$STUB" --port 0 --port-file "$STUB_DIR/$name.port" --log "$logf" --name "$name" --ack "$ACK" "$@" \
    >/dev/null 2> "$OUT/stub-$name.stderr" &
  echo $! > "$STUB_DIR/$name.pid"
  local i=0
  while [ ! -s "$STUB_DIR/$name.port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  cat "$STUB_DIR/$name.port" 2>/dev/null
}
BLOG="$OUT/stub-board.jsonl"; DLOG="$OUT/stub-dummy.jsonl"
: > "$BLOG"; : > "$DLOG"
BPORT="$(start_stub "$BOARD" "$BLOG")"
on_exit "kill $(cat "$STUB_DIR/$BOARD.pid")"
DPORT="$(start_stub "$DUMMY" "$DLOG" --no-auth)"
on_exit "kill $(cat "$STUB_DIR/$DUMMY.pid")"
BURL="http://127.0.0.1:$BPORT/mcp"; DURL="http://127.0.0.1:$DPORT/mcp"

section "0. Заглушки MCP"
if [ -n "$BPORT" ] && [ -n "$DPORT" ]; then pass "заглушки подняты: $BOARD на :$BPORT (Bearer), $DUMMY на :$DPORT (без auth)"; else fail "заглушки не стартовали — см. stub-*.stderr"; finish; exit 1; fi
c="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $KABAN_RUN_TOKEN" -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' "$BURL")"
check "$([ "$c" = 200 ] && echo 0 || echo 1)" "самопроверка доски curl'ом: ping с верным Bearer → 200" "самопроверка доски: ping → $c"
c="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer wrong" -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' "$BURL")"
check "$([ "$c" = 401 ] && echo 0 || echo 1)" "самопроверка доски: неверный Bearer → 401" "самопроверка доски: неверный Bearer → $c"
info "версия CLI: \`$(ks run --timeout 30 --out "$OUT/version" -- "$CA" --version >/dev/null 2>&1; first_line "$OUT/version.stdout")\`"

# Отметка позиции в логах заглушек и статистика фазы
mark() { wc -l < "$1" | tr -d ' '; }
stats() { ks stub-stats "$1" --from-line "$2" ${3:+--get "$3"}; }
calls_ok() { # calls_ok LOG FROM -> число tools/call c auth=match
  "$PY" - "$1" "$2" <<'PY'
import json, sys
n = 0
for i, l in enumerate(open(sys.argv[1], errors="replace"), 1):
    if i <= int(sys.argv[2]):
        continue
    try:
        o = json.loads(l)
    except Exception:
        continue
    if o.get("tool") and o.get("auth") == "match" and o.get("status") == 200:
        n += 1
print(n)
PY
}
phase_report() { # phase_report LABEL LOG FROM
  local s; s="$(stats "$2" "$3")"
  echo "$s" > "$OUT/phase-$(echo "$1" | tr -c 'A-Za-z0-9' '_').stub.json"
  info "$1 → заглушка: запросов $(echo "$s" | "$PY" -c 'import json,sys;d=json.load(sys.stdin);print("%d, rpc=%s, auth=%s, tools=%s" % (d["requests"], d["rpc"], d["auth"], [t["tool"] + ":" + str(t["auth"]) for t in d["tools_called"]]))')"
}
mcp_json_board() { ks mcpjson --out "$1" --server "$BOARD=$BURL,auth"; }
ack_in_result() { sj_get "$OUT/$1.stdout" result.result_text | grep -q "$ACK"; }

# ------------------------------------------------------------------------
section "a. .cursor/mcp.json в клоне + \${env:KABAN_RUN_TOKEN}"
RA="$(make_repo mcp-a)"
mcp_json_board "$RA/.cursor/mcp.json"
grep -qF -- "$KABAN_RUN_TOKEN" "$RA/.cursor/mcp.json"
check "$([ $? = 1 ] && echo 0 || echo 1)" "в mcp.json токена нет, только \${env:KABAN_RUN_TOKEN}" "ТОКЕН ПОПАЛ В ФАЙЛ (ошибка скрипта)"
cp "$RA/.cursor/mcp.json" "$OUT/mcp.json.example"
echo ".cursor/mcp.json" >> "$RA/.git/info/exclude"

m="$(mark "$BLOG")"
run_in "$RA" 90 a-mcp-list "$CA" mcp list
info "\`mcp list\` (exit $(rc_of a-mcp-list)): \`$(strip_ansi_file "$OUT/a-mcp-list.stdout" | tr -s ' \n' ' ' | cut -c1-300)\`"
ck="$(ks mcp-check "$OUT/a-mcp-list.stdout" --expect "$BOARD")"
case "$ck" in *'"missing": []'*) pass "\`mcp list\` видит $BOARD из .cursor/mcp.json клона";; *) fail "\`mcp list\` НЕ показывает $BOARD: $ck";; esac
phase_report "a0 mcp list" "$BLOG" "$m"
au="$(stats "$BLOG" "$m" auth)"
case "$au" in
  *'"match"'*) pass "CLI ходил в доску с верным Bearer — интерполяция \${env:...} в headers работает (при mcp list)";;
  *literal_placeholder*) fail "CLI прислал буквальный \${env:KABAN_RUN_TOKEN} — интерполяции нет";;
  *empty*) fail "CLI прислал пустой Bearer";;
  '{}'|'') info "при \`mcp list\` CLI в доску не ходил (список без подключения)";;
  *) info "auth при mcp list: $au";;
esac

m="$(mark "$BLOG")"
run_in "$RA" 90 a-mcp-list-tools "$CA" mcp list-tools "$BOARD"
info "\`mcp list-tools $BOARD\` (exit $(rc_of a-mcp-list-tools)): \`$(strip_ansi_file "$OUT/a-mcp-list-tools.stdout" | tr -s ' \n' ' ' | cut -c1-300)\`"
grep -q complete_stage "$OUT/a-mcp-list-tools.stdout"; check $? "list-tools вернул инструменты доски" "list-tools не показал complete_stage"
phase_report "a1 mcp list-tools" "$BLOG" "$m"

m="$(mark "$BLOG")"
run_in "$RA" 90 a-mcp-list-noenv env -u KABAN_RUN_TOKEN "$CA" mcp list-tools "$BOARD"
info "без KABAN_RUN_TOKEN в env: \`mcp list-tools\` exit $(rc_of a-mcp-list-noenv): \`$(strip_ansi_file "$OUT/a-mcp-list-noenv.stdout" | tr -s ' \n' ' ' | cut -c1-200)\`; auth в заглушке: \`$(stats "$BLOG" "$m" auth)\`"

# a2: -p БЕЗ --approve-mcps (свежий клон, одобрения ещё не было)
m="$(mark "$BLOG")"
arun a-run-noapprove "$RA" -- -p --output-format stream-json --model "$MODEL" --force "$MCP_PROMPT"
summarize_run a-run-noapprove
n="$(calls_ok "$BLOG" "$m")"
if [ "$n" -gt 0 ]; then info "БЕЗ --approve-mcps tools/call дошли до доски ($n) — одобрение в -p не требуется"; else info "БЕЗ --approve-mcps вызовов доски нет — в -p нужен --approve-mcps"; fi
phase_report "a2 -p без --approve-mcps" "$BLOG" "$m"

# a3: -p С --approve-mcps (другой свежий клон)
RB="$(make_repo mcp-b)"; mcp_json_board "$RB/.cursor/mcp.json"; echo ".cursor/mcp.json" >> "$RB/.git/info/exclude"
m="$(mark "$BLOG")"
arun a-run-approve "$RB" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps "$MCP_PROMPT"
summarize_run a-run-approve
n="$(calls_ok "$BLOG" "$m")"
check "$([ "$n" -gt 0 ] && echo 0 || echo 1)" "С --approve-mcps: tools/call пришли в доску с верным Bearer ($n)" "С --approve-mcps вызовов доски с верным Bearer нет — см. phase_a3*.stub.json и a-run-approve.stderr"
ack_in_result a-run-approve; check $? "ответ complete_stage ($ACK) дошёл до агента и в result" "ACK в result не найден"
info "как MCP-вызов выглядит в stream-json: \`$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print([{k:v for k,v in t.items() if k!="call_id"} for t in d["tool_calls"]["details"] if t.get("subtype")=="started"][:2])' "$OUT/a-run-approve.summary.json" 2>/dev/null | cut -c1-500)\`"
phase_report "a3 -p с --approve-mcps" "$BLOG" "$m"

# a4: --approve-mcps БЕЗ --force (read-only стадия должна уметь вызвать complete_stage)
RE="$(make_repo mcp-e)"; mcp_json_board "$RE/.cursor/mcp.json"; echo ".cursor/mcp.json" >> "$RE/.git/info/exclude"
m="$(mark "$BLOG")"
ARUN_TIMEOUT=150 arun a-run-approve-noforce "$RE" -- -p --output-format stream-json --model "$MODEL" --approve-mcps "$MCP_PROMPT"
summarize_run a-run-approve-noforce
n="$(calls_ok "$BLOG" "$m")"
check "$([ "$n" -gt 0 ] && echo 0 || echo 1)" "--approve-mcps без --force: вызовы доски проходят ($n) — read-only стадии могут закончить через complete_stage" "--approve-mcps без --force: вызовов доски нет (exit $(rc_of a-run-approve-noforce)) — read-only стадиям нужен другой режим"
phase_report "a4 --approve-mcps без --force" "$BLOG" "$m"

# a5: сохраняется ли одобрение: снова БЕЗ --approve-mcps в клоне, где уже одобряли
m="$(mark "$BLOG")"
arun a-run-persist "$RB" -- -p --output-format stream-json --model "$MODEL" --force "$MCP_PROMPT"
summarize_run a-run-persist
n="$(calls_ok "$BLOG" "$m")"
if [ "$n" -gt 0 ]; then info "одобрение СОХРАНИЛОСЬ: повторный запуск без --approve-mcps в том же клоне вызвал доску ($n)"; else info "одобрение не сохраняется между запусками (или не требовалось) — без --approve-mcps вызовов нет"; fi
phase_report "a5 повтор без --approve-mcps" "$BLOG" "$m"

# ------------------------------------------------------------------------
section "b. Подключение доски без записи в репозиторий"
# b1: отдельный HOME с ~/.cursor/mcp.json
TH="$(mktmp home)"
mcp_json_board "$TH/.cursor/mcp.json"
RC_="$(make_repo mcp-c)"
run_in "$RC_" 30 b1-status env HOME="$TH" "$CA" status
hs="$(ks login-state "$OUT/b1-status.stdout" "$OUT/b1-status.stderr")"
info "HOME=<temp с ~/.cursor/mcp.json>: status = $hs"
m="$(mark "$BLOG")"
run_in "$RC_" 90 b1-mcp-list env HOME="$TH" "$CA" mcp list
ck="$(ks mcp-check "$OUT/b1-mcp-list.stdout" --expect "$BOARD")"
info "HOME=<temp>: \`mcp list\` → $ck"
m2="$(mark "$BLOG")"
arun b1-run "$RC_" HOME="$TH" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps "$MCP_PROMPT"
summarize_run b1-run
n="$(calls_ok "$BLOG" "$m2")"
if [ "$n" -gt 0 ] && [ "$(rc_of b1-run)" = 0 ]; then
  pass "отдельный HOME: логин жив и доска из \$HOME/.cursor/mcp.json вызвана ($n) — в репозиторий писать не нужно"
else
  fail "отдельный HOME: exit $(rc_of b1-run), вызовов доски $n (\`$(first_line "$OUT/b1-run.stderr")\`)"
fi
phase_report "b1 отдельный HOME" "$BLOG" "$m"
info "что CLI создал во временном HOME (имена): \`$(cd "$TH" && find . -type f | sort | head -n 15 | tr '\n' ' ')\`"

# b2: CURSOR_CONFIG_DIR с mcp.json
TC="$(mktmp cfgdir)"
mcp_json_board "$TC/mcp.json"
RD="$(make_repo mcp-d)"
run_in "$RD" 90 b2-mcp-list env CURSOR_CONFIG_DIR="$TC" "$CA" mcp list
ck="$(ks mcp-check "$OUT/b2-mcp-list.stdout" --expect "$BOARD")"
case "$ck" in
  *'"missing": []'*)
    pass "CURSOR_CONFIG_DIR: \`mcp list\` видит $BOARD из \$CURSOR_CONFIG_DIR/mcp.json"
    run_in "$RD" 30 b2-status env CURSOR_CONFIG_DIR="$TC" "$CA" status
    info "CURSOR_CONFIG_DIR: status = $(ks login-state "$OUT/b2-status.stdout" "$OUT/b2-status.stderr")"
    m="$(mark "$BLOG")"
    arun b2-run "$RD" CURSOR_CONFIG_DIR="$TC" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps "$MCP_PROMPT"
    summarize_run b2-run
    info "CURSOR_CONFIG_DIR: вызовов доски с верным Bearer: $(calls_ok "$BLOG" "$m")" ;;
  *) info "CURSOR_CONFIG_DIR: mcp.json оттуда не читается ($ck)" ;;
esac

# b3: mcp.json в РОДИТЕЛЬСКОМ каталоге клона (Workspaces/<project>/.cursor/mcp.json)
PP="$(mktmp parent)"
mcp_json_board "$PP/.cursor/mcp.json"
( cd "$PP" && mkdir task && cd task && g init -q -b main && echo '# t' > README.md && g add . && g commit -qm init ) >/dev/null 2>&1
run_in "$PP/task" 90 b3-mcp-list "$CA" mcp list
ck="$(ks mcp-check "$OUT/b3-mcp-list.stdout" --expect "$BOARD")"
case "$ck" in
  *'"missing": []'*)
    pass "mcp.json в родительском каталоге клона ВИДЕН из клона (поиск вверх выходит за корень git)"
    m="$(mark "$BLOG")"
    arun b3-run "$PP/task" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps "$MCP_PROMPT"
    summarize_run b3-run
    info "родительский mcp.json: вызовов доски с верным Bearer: $(calls_ok "$BLOG" "$m")" ;;
  *) info "mcp.json в родительском каталоге клона не виден ($ck)" ;;
esac

# b4: флаги CLI
run_cap_timeout 30 help "$CA" --help
fl="$(cat "$OUT/help.stdout" "$OUT/help.stderr" 2>/dev/null | grep -iE -- '--[a-z-]*(mcp|config)[a-z-]*'  | tr -s ' ' | tr '\n' ' ' | cut -c1-400)"
info "флаги CLI про mcp/config в --help: \`${fl:-нет}\`"
run_cap_timeout 30 help-mcp "$CA" mcp --help
info "\`mcp --help\`: \`$(strip_ansi_file "$OUT/help-mcp.stdout" | tr -s ' \n' ' ' | cut -c1-400)\`"
manual "если в --help есть флаг вида --mcp-config/--config — проверить его отдельно (скрипт пробует только HOME, CURSOR_CONFIG_DIR и родительский каталог)"

# ------------------------------------------------------------------------
section "c. В проекте закоммичен свой .cursor/mcp.json (project-dummy)"
RP="$(make_repo mcp-proj)"
ks mcpjson --out "$RP/.cursor/mcp.json" --server "$DUMMY=$DURL"
( cd "$RP" && g add .cursor/mcp.json && g commit -qm "project mcp" ) >/dev/null 2>&1
# c1: HOME с доской + закоммиченный dummy в проекте
dm="$(mark "$DLOG")"
run_in "$RP" 90 c1-mcp-list env HOME="$TH" "$CA" mcp list
ck="$(ks mcp-check "$OUT/c1-mcp-list.stdout" --expect "$BOARD,$DUMMY")"
info "c1 (HOME с доской + закоммиченный $DUMMY): \`mcp list\` → $ck"
bm="$(mark "$BLOG")"; dm2="$(mark "$DLOG")"
arun c1-run "$RP" HOME="$TH" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps "$MCP_PROMPT"
summarize_run c1-run
dreq="$(stats "$DLOG" "$dm2" rpc)"
if [ -n "$dreq" ] && [ "$dreq" != "{}" ]; then fail "--approve-mcps одобрил и ПОДКЛЮЧИЛ чужой $DUMMY (rpc: $dreq) — fail closed по mcp list обязателен"; else pass "чужой $DUMMY не подключался при запуске (rpc: ${dreq:-—})"; fi
info "c1: вызовов доски с верным Bearer: $(calls_ok "$BLOG" "$bm")"
phase_report "c1 dummy" "$DLOG" "$dm"
# c2: демон подменяет файл проекта своим (доска), затем возвращает из main
ks mcpjson --out "$RP/.cursor/mcp.json" --server "$BOARD=$BURL,auth"
run_in "$RP" 90 c2-mcp-list env HOME="$TH" "$CA" mcp list
ck="$(ks mcp-check "$OUT/c2-mcp-list.stdout" --expect "$BOARD" --absent "$DUMMY")"
case "$ck" in *'"absent_violated": []'*'"missing": []'*|*'"missing": []'*'"absent_violated": []'*) pass "после подмены файла \`mcp list\` показывает только $BOARD ($ck)";; *) fail "после подмены: $ck";; esac
run_in "$RP" 90 c2-mcp-list-realhome "$CA" mcp list
info "после подмены, реальный HOME: \`mcp list\` → $(ks mcp-check "$OUT/c2-mcp-list-realhome.stdout" --expect "$BOARD" --absent "$DUMMY")"
st="$(cd "$RP" && g status --porcelain)"
info "git status после подмены: \`${st:-чисто}\`"
( cd "$RP" && g checkout -q main -- .cursor/mcp.json )
st="$(cd "$RP" && g status --porcelain)"
[ -z "$st" ]; check $? "\`git checkout main -- .cursor/mcp.json\` вернул файл проекта, клон чистый" "после возврата клон грязный: $st"

# ------------------------------------------------------------------------
section "d. Формат \`mcp list\` для fail closed"
for f in a-mcp-list b1-mcp-list c1-mcp-list c2-mcp-list; do
  [ -f "$OUT/$f.stdout" ] && { echo "### $f (exit $(rc_of "$f"))"; strip_ansi_file "$OUT/$f.stdout"; echo; echo "stderr:"; strip_ansi_file "$OUT/$f.stderr"; echo; } >> "$OUT/mcp-list-formats.txt"
done
info "сырые выводы \`mcp list\` без ANSI: \`mcp-list-formats.txt\`"
run_cap_timeout 30 help-mcp-list "$CA" mcp list --help
jf="$(grep -iE -- '--(json|format|output)' "$OUT/help-mcp-list.stdout" 2>/dev/null | tr -s ' ' | head -n 3 | tr '\n' ' ')"
if [ -n "$jf" ]; then info "у \`mcp list\` есть машинный формат: \`$jf\`"; else info "у \`mcp list\` машинного формата (--json/--format) нет — парсим текст"; fi
manual "по mcp-list-formats.txt: как выглядят имя сервера, статус и источник (project/global); стабильно ли для парсинга"

# ------------------------------------------------------------------------
section "Что CLI менял в ~/.cursor за время спайка (только имена файлов)"
find "$HOME/.cursor" -type f -newer "$START_MARK" -not -path '*/chats/*' -not -path '*/extensions/*' 2>/dev/null | sed "s|^$HOME|~|" | sort > "$OUT/home-cursor-changed.txt"
info "изменено файлов (без chats/): $(wc -l < "$OUT/home-cursor-changed.txt" | tr -d ' '): \`$(head -n 15 "$OUT/home-cursor-changed.txt" | tr '\n' ' ')\` — здесь же ищем, где хранится одобрение MCP"

finish
