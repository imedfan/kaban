#!/usr/bin/env bash
# Спайк 6 (§14 п.6, §8.1–8.2, §13 архитектуры): Seatbelt-профиль и клоны.
#
# Seatbelt (kaban-agent.sb): запись только в клон задачи, temp и служебные каталоги
# cursor-agent (находим: прогон без песочницы + журнал отказов Sandbox); запрет чтения
# ~/.ssh и Cursor/User/globalStorage; loopback только на порт MCP. Проверяем:
#   1) профиль компилируется; имена хостов в правилах сети SBPL не принимает;
#   2) пробы напрямую под sandbox-exec (без агента): отказы и разрешения;
#   3) cursor-agent внутри sandbox-exec: работает ли, его shell-команды упираются в профиль,
#      MCP доски на разрешённом порту доступен (итерации: добавляем найденные каталоги CLI);
#   4) эксперимент «CLI вне песочницы, песочница только для инструментов»: --sandbox enabled
#      и `cursor-agent sandbox run` (в т. ч. --sb-debug, чтобы увидеть их профиль);
#   5) git и тривиальная сборка (swift build / make) под профилем.
# Клоны: git clone --local (время, место, хардлинки), fetch ветки демоном, cp -c (APFS
# clonefile) warm_paths: время и реальная дельта df.
#
# Пробы никогда не печатают содержимое файлов: только коды выхода (dd в /dev/null).
# Переменные: KABAN_SPIKE_MODEL (обяз.), KABAN_SPIKE_REPO (репо для замеров клона; только
# чтение, по умолчанию генерируется репо на 2000 файлов), KABAN_SPIKE_WARM (через запятую,
# относительные пути warm_paths; по умолчанию ищем node_modules,.build,DerivedData,build,Pods,target,.venv).
# Стоимость: 3–6 коротких запусков дешёвой модели.
SPIKE_NAME=spike6-seatbelt
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/common.sh"
require_macos
require_agent
need git
need sandbox-exec
need curl

TEMPLATE="$SPIKES_DIR/kaban-agent.sb"
STUB="$SPIKES_DIR/mcp_stub_server.py"
HOMER="$(cd "$HOME" && pwd -P)"
STATE_DB="$HOMER/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
GSTORE="$HOMER/Library/Application Support/Cursor/User/globalStorage"
TMPR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
CACHER="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"; CACHER="$(cd "${CACHER:-$TMPR}" && pwd -P)"
KABAN_RUN_TOKEN="$("$PY" -c 'import secrets; print(secrets.token_hex(24))')"; export KABAN_RUN_TOKEN
SCRUB_ENV=KABAN_RUN_TOKEN
DB_EXISTS=0; [ -f "$STATE_DB" ] && DB_EXISTS=1
SBX_FLAG_OK=0; ks run --timeout 30 --out "$OUT/help" -- "$CA" --help >/dev/null 2>&1
grep -q -- '--sandbox' "$OUT/help.stdout" "$OUT/help.stderr" 2>/dev/null && SBX_FLAG_OK=1

# База всех клонов — в HOME (не в /tmp), чтобы «основной репозиторий» был вне разрешённой записи
BASE="$(mktemp -d "$HOMER/.kaban-spike6.XXXXXX")"; add_tmp "$BASE"
MAIN="$BASE/main"
OUTSIDE="$HOMER/.kaban-spike6-outside-$$"
PROF_DIR="$(mktmp sb)"

# ---------------------------------------------------------------- заглушки MCP
STUB_DIR="$(mktmp stubs)"
start_stub() { # start_stub NAME LOG [args] -> порт
  local name="$1" logf="$2"; shift 2
  "$PY" "$STUB" --port 0 --port-file "$STUB_DIR/$name.port" --log "$logf" --name "$name" "$@" >/dev/null 2> "$OUT/stub-$name.stderr" &
  echo $! > "$STUB_DIR/$name.pid"
  local i=0; while [ ! -s "$STUB_DIR/$name.port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  cat "$STUB_DIR/$name.port" 2>/dev/null
}
BLOG="$OUT/stub-board.jsonl"; OLOG="$OUT/stub-other.jsonl"; : > "$BLOG"; : > "$OLOG"
MCP_PORT="$(start_stub kaban-board "$BLOG" --ack KABAN-ACK-sb)"; on_exit "kill $(cat "$STUB_DIR/kaban-board.pid")"
OTHER_PORT="$(start_stub other-local "$OLOG" --no-auth)"; on_exit "kill $(cat "$STUB_DIR/other-local.pid")"
mark() { wc -l < "$1" | tr -d ' '; }
reqs_since() { ks stub-stats "$1" --from-line "$2" --get requests; }

# ---------------------------------------------------------------- вспомогательное
render() { # render OUTFILE [write-paths...]
  local o="$1" clone="$2"; shift 2
  local a; a=()
  local p; for p in "$@"; do a+=(--write-path "$p"); done
  ks render-sb "$TEMPLATE" "$o" --set "HOME=$HOMER" --set "CLONE=$clone" --set "TMPDIR=$TMPR" \
    --set "CACHEDIR=$CACHER" --set "MCP_PORT=$MCP_PORT" ${a[@]+"${a[@]}"}
}
new_clone() { # new_clone NAME -> путь клона main
  local c="$BASE/$1"
  g clone -q --local "$MAIN" "$c" >/dev/null 2>&1
  echo "$c"
}
write_probe() { # write_probe DIR
  {
    echo '#!/bin/bash'
    echo '# Пробы спайка 6 Kaban: печатают только коды выхода; содержимое файлов не выводится.'
    printf 'DB=%q\nDB_EXISTS=%q\nMAIN=%q\nOUTSIDE=%q\nMCP_PORT=%q\nOTHER_PORT=%q\n' \
      "$STATE_DB" "$DB_EXISTS" "$MAIN" "$OUTSIDE" "$MCP_PORT" "$OTHER_PORT"
    cat <<'PROBE'
RES="${1:-probe-result.txt}"
{
if [ "$DB_EXISTS" = 1 ]; then dd if="$DB" of=/dev/null bs=1 count=1 2>/dev/null; echo "READ_STATE_VSCDB=$?"; else echo "READ_STATE_VSCDB=absent"; fi
if [ -d "$HOME/.ssh" ] || [ "$DB_EXISTS" = 1 ]; then ls "$HOME/.ssh" >/dev/null 2>&1; echo "LIST_SSH=$?"; fi
( echo x > "$OUTSIDE" ) 2>/dev/null; echo "WRITE_OUTSIDE=$?"; rm -f "$OUTSIDE" 2>/dev/null
( echo x > "$MAIN/kaban-probe.txt" ) 2>/dev/null; echo "WRITE_MAIN_REPO=$?"; rm -f "$MAIN/kaban-probe.txt" 2>/dev/null
( echo x > ./probe-inside.txt ) 2>/dev/null; echo "WRITE_CLONE=$?"; rm -f ./probe-inside.txt 2>/dev/null
( echo x > "${TMPDIR:-/tmp}/kaban-probe-$$" ) 2>/dev/null; echo "WRITE_TMPDIR=$?"; rm -f "${TMPDIR:-/tmp}/kaban-probe-$$" 2>/dev/null
curl -s -m 5 -o /dev/null "http://127.0.0.1:$MCP_PORT/mcp"; echo "CURL_MCP_PORT=$?"
curl -s -m 5 -o /dev/null "http://127.0.0.1:$OTHER_PORT/mcp"; echo "CURL_OTHER_LOCAL_PORT=$?"
curl -s -m 10 -o /dev/null https://api2.cursor.sh/; echo "CURL_INTERNET=$?"
git status --porcelain >/dev/null 2>&1; echo "GIT_STATUS=$?"
} > "$RES" 2>/dev/null
cat "$RES"
PROBE
  } > "$1/probe.sh"
  chmod +x "$1/probe.sh"
  echo "probe.sh" >> "$1/.git/info/exclude"; echo "probe-result*.txt" >> "$1/.git/info/exclude"
}
pval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
# judge_probe FILE LABEL MODE — MODE=sandbox (ждём запреты) | baseline (ждём, что всё можно)
judge_probe() {
  local f="$1" L="$2" mode="$3" v
  if [ ! -s "$f" ]; then fail "$L: файла с результатами проб нет ($f)"; return; fi
  cp "$f" "$OUT/$(basename "$f" .txt)-$(echo "$L" | tr -c 'A-Za-z0-9' '_').txt"
  if [ "$mode" = baseline ]; then info "$L: $(tr '\n' ' ' < "$f")"; return; fi
  v="$(pval "$f" READ_STATE_VSCDB)"
  case "$v" in absent) info "$L: state.vscdb нет — запрет чтения не проверить";; 0) fail "$L: чтение state.vscdb РАЗРЕШЕНО";; *) pass "$L: чтение state.vscdb запрещено (код $v)";; esac
  v="$(pval "$f" LIST_SSH)"; [ -n "$v" ] && { [ "$v" != 0 ] && pass "$L: ~/.ssh не читается (код $v)" || fail "$L: ~/.ssh читается"; }
  v="$(pval "$f" WRITE_OUTSIDE)"; [ "$v" != 0 ] && pass "$L: запись вне клона ($OUTSIDE) запрещена" || fail "$L: запись вне клона РАЗРЕШЕНА"
  v="$(pval "$f" WRITE_MAIN_REPO)"; [ "$v" != 0 ] && pass "$L: запись в «основной репозиторий» запрещена" || fail "$L: запись в основной репозиторий РАЗРЕШЕНА"
  v="$(pval "$f" WRITE_CLONE)"; [ "$v" = 0 ] && pass "$L: запись в клон есть" || fail "$L: запись в клон запрещена (код $v)"
  v="$(pval "$f" WRITE_TMPDIR)"; [ "$v" = 0 ] && pass "$L: запись в \$TMPDIR есть" || fail "$L: запись в \$TMPDIR запрещена"
  v="$(pval "$f" CURL_MCP_PORT)"; [ "$v" = 0 ] && pass "$L: 127.0.0.1:$MCP_PORT (MCP) доступен" || fail "$L: MCP-порт недоступен (curl $v)"
  v="$(pval "$f" CURL_OTHER_LOCAL_PORT)"; [ "$v" != 0 ] && pass "$L: другой loopback-порт :$OTHER_PORT запрещён (curl $v)" || fail "$L: другой loopback-порт ДОСТУПЕН"
  v="$(pval "$f" CURL_INTERNET)"; [ "$v" = 0 ] && info "$L: интернет (api2.cursor.sh) доступен" || info "$L: интернет недоступен (curl $v)"
  v="$(pval "$f" GIT_STATUS)"; [ "$v" = 0 ] && pass "$L: git status в клоне работает" || fail "$L: git status в клоне не работает ($v)"
}
log_sandbox() { # log_sandbox START_STR NAME — отказы Sandbox с момента START
  ks run --timeout 180 --out "$OUT/$2" -- log show --start "$1" --style compact \
    --predicate 'sender == "Sandbox" OR subsystem == "com.apple.sandbox.reporting"' >/dev/null 2>&1
  grep -i 'deny' "$OUT/$2.stdout" > "$OUT/$2.deny.txt" 2>/dev/null
  rm -f "$OUT/$2.stdout"
}
now_log() { date '+%Y-%m-%d %H:%M:%S'; }
nlines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
EXPECTED_DENY=(--exclude "$OUTSIDE" --exclude "$MAIN" --exclude "$GSTORE" --exclude "$HOMER/.ssh")
# Наши процессы в журнале Sandbox (точное имя или префикс*), чтобы не ловить отказы системных демонов
OUR_PROCS=(--procs "node*" "cursor*" "agent*" bash sh zsh env "git*" curl dd ls rm cat mkdir mv cp touch tee sed grep find head tail rg make cc "clang*" ld "swift*" xcrun "python*" "ripgrep*")

# ---------------------------------------------------------------- основной репозиторий для проб
mkdir -p "$MAIN"
( cd "$MAIN" && g init -q -b main && printf '# main\n' > README.md && printf 'all:\n\t@echo build-ok\n' > Makefile && g add . && g commit -qm init ) >/dev/null 2>&1

# ========================================================================
section "1. Профиль компилируется; ограничения SBPL"
render "$PROF_DIR/v0.sb" "$BASE/probe-clone"
cp "$PROF_DIR/v0.sb" "$OUT/profile-v0.sb"
ks run --timeout 30 --out "$OUT/sb-compile" -- sandbox-exec -f "$PROF_DIR/v0.sb" /usr/bin/true >/dev/null 2>&1
check "$(rc_of sb-compile)" "профиль kaban-agent.sb компилируется (sandbox-exec /usr/bin/true)" "профиль не компилируется: \`$(first_line "$OUT/sb-compile.stderr")\`"
printf '(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "api2.cursor.sh:443"))\n' > "$PROF_DIR/host.sb"
ks run --timeout 30 --out "$OUT/sb-hostname" -- sandbox-exec -f "$PROF_DIR/host.sb" /usr/bin/true >/dev/null 2>&1
if [ "$(rc_of sb-hostname)" != 0 ]; then info "правило с именем хоста SBPL отвергает (\`$(first_line "$OUT/sb-hostname.stderr")\`) → allowlist хостов только через прокси"; else info "SBPL принял (remote ip \"api2.cursor.sh:443\") — проверить, работает ли он на деле"; fi

# ========================================================================
section "2. Пробы напрямую под sandbox-exec (без агента)"
PC="$(new_clone probe-clone)"
write_probe "$PC"
( cd "$PC" && bash probe.sh probe-result-baseline.txt ) >/dev/null 2>&1
judge_probe "$PC/probe-result-baseline.txt" "контроль без песочницы" baseline
om="$(mark "$OLOG")"
T0="$(now_log)"
run_in "$PC" 60 direct-probe sandbox-exec -f "$PROF_DIR/v0.sb" /bin/bash probe.sh probe-result-direct.txt
judge_probe "$PC/probe-result-direct.txt" "sandbox-exec напрямую" sandbox
[ "$(reqs_since "$OLOG" "$om")" = 0 ] && pass "заглушка на другом порту не получила ни одного запроса из песочницы" || fail "заглушка на другом порту получила запросы из песочницы"
sleep 2; log_sandbox "$T0" sblog-direct
info "строк отказов Sandbox в журнале за пробу: $(nlines "$OUT/sblog-direct.deny.txt") (sblog-direct.deny.txt; если 0 — журнал не пишет отказы или предикат не тот)"

# ========================================================================
section "3. Где cursor-agent пишет (прогон без песочницы)"
DC="$(new_clone disc-clone)"
DISC_PROMPT='Create a file named sb-hello.txt containing exactly: ok
Then run the shell command: git status --short
Then reply with the single word DONE.'
DMARK="$PROF_DIR/disc.marker"; : > "$DMARK"; sleep 1
arun disc-run "$DC" -- -p --output-format stream-json --model "$MODEL" --force "$DISC_PROMPT"
summarize_run disc-run
{
  for d in "$HOMER/.cursor" "$HOMER/.config" "$HOMER/.local" "$HOMER/Library/Caches" "$HOMER/Library/Application Support" "$HOMER/Library/Logs" "$HOMER/Library/Preferences" "$HOMER/Library/HTTPStorages" "$HOMER/Library/Saved Application State"; do
    [ -d "$d" ] && find "$d" -maxdepth 4 -newer "$DMARK" -not -path '*/chats/*/*' 2>/dev/null
  done
  find "$HOMER" -maxdepth 1 -newer "$DMARK" 2>/dev/null
} | grep -v -F "$BASE" | sort -u > "$OUT/disc-changed-all.txt"
grep -iE 'cursor|agent|node|kaban|anysphere' "$OUT/disc-changed-all.txt" | grep -v -F "$OUTSIDE" > "$OUT/disc-changed.txt"
info "изменено за прогон (по шаблону cursor|agent|node|anysphere): $(wc -l < "$OUT/disc-changed.txt" | tr -d ' ') путей, прочее (шум других программ): $(( $(wc -l < "$OUT/disc-changed-all.txt") - $(wc -l < "$OUT/disc-changed.txt") )) — disc-changed*.txt"
ks suggest-write "$OUT/disc-changed.txt" --home "$HOMER" --skipped-out "$OUT/disc-skipped.txt" > "$OUT/write-paths-discovered.txt"
info "служебные каталоги CLI (кандидаты в EXTRA_WRITE): \`$(tr '\n' ' ' < "$OUT/write-paths-discovered.txt")\`"
[ -s "$OUT/disc-skipped.txt" ] && info "НЕ добавлены в профиль (слишком широко/секретно): \`$(tr '\n' ' ' < "$OUT/disc-skipped.txt")\`"

# ========================================================================
section "4. cursor-agent внутри sandbox-exec (итерации профиля)"
SB_PROMPT="Do these steps in order:
1. Run this exact shell command: bash probe.sh probe-result-agent.txt
2. Create a file named sb-hello.txt containing exactly: ok
3. Call the MCP tool report_progress of the server kaban-board with text \"sandbox ok\".
Then reply with the single word DONE."
WP=()
while IFS= read -r l; do [ -n "$l" ] && WP+=("$l"); done < "$OUT/write-paths-discovered.txt"
SBX_ARGS=(); [ "$SBX_FLAG_OK" = 1 ] && SBX_ARGS=(--sandbox disabled)
FINAL_OK=0; IT=0
for IT in 1 2 3; do
  C="$(new_clone "sb-clone-$IT")"
  write_probe "$C"
  ks mcpjson --out "$C/.cursor/mcp.json" --server "kaban-board=http://127.0.0.1:$MCP_PORT/mcp,auth"; echo ".cursor/" >> "$C/.git/info/exclude"
  render "$PROF_DIR/it$IT.sb" "$C" ${WP[@]+"${WP[@]}"}
  cp "$PROF_DIR/it$IT.sb" "$OUT/profile-it$IT.sb"
  bm="$(mark "$BLOG")"; T0="$(now_log)"
  AGENT_PREFIX="sandbox-exec -f $PROF_DIR/it$IT.sb" arun "sb-run-$IT" "$C" -- -p --output-format stream-json --model "$MODEL" --force --approve-mcps ${SBX_ARGS[@]+"${SBX_ARGS[@]}"} "$SB_PROMPT"
  summarize_run "sb-run-$IT"
  sleep 2; log_sandbox "$T0" "sblog-it$IT"
  ks sblog "$OUT/sblog-it$IT.deny.txt" --home "$HOMER" "${EXPECTED_DENY[@]}" "${OUR_PROCS[@]}" --save "$OUT/sblog-it$IT.json" --suggest > "$PROF_DIR/new-$IT.txt" 2>/dev/null
  ok=0
  [ "$(rc_of "sb-run-$IT")" = 0 ] && [ -n "$(sj_get "$OUT/sb-run-$IT.stdout" result.subtype)" ] && [ -f "$C/sb-hello.txt" ] && ok=1
  info "итерация $IT: exit=$(rc_of "sb-run-$IT"), sb-hello.txt=$([ -f "$C/sb-hello.txt" ] && echo есть || echo нет), отказов в журнале: $(nlines "$OUT/sblog-it$IT.deny.txt"), новых кандидатов на запись: \`$(tr '\n' ' ' < "$PROF_DIR/new-$IT.txt")\`"
  added=0
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    dup=0; for x in ${WP[@]+"${WP[@]}"}; do [ "$x" = "$l" ] && dup=1; done
    [ $dup = 0 ] && { WP+=("$l"); added=1; }
  done < "$PROF_DIR/new-$IT.txt"
  if [ $ok = 1 ]; then FINAL_OK=1; break; fi
  [ $added = 0 ] && break
done
LAST="sb-run-$IT"
if [ $FINAL_OK = 1 ]; then pass "cursor-agent работает внутри sandbox-exec (итерация $IT, profile-it$IT.sb)"; else fail "cursor-agent внутри sandbox-exec не отработал за $IT итерац. — см. $LAST.stderr: \`$(first_line "$OUT/$LAST.stderr")\` и sblog-it*.json"; fi
cp "$PROF_DIR/it$IT.sb" "$OUT/kaban-agent.final.sb"
info "итоговые служебные каталоги записи CLI: \`${WP[*]+${WP[*]}}\` (kaban-agent.final.sb)"
judge_probe "$C/probe-result-agent.txt" "shell-команда агента в песочнице" sandbox
bn="$("$PY" -c 'import json,sys
n=0
for i,l in enumerate(open(sys.argv[1]),1):
    if i<=int(sys.argv[2]): continue
    o=json.loads(l)
    n+= 1 if (o.get("tool") and o.get("auth")=="match") else 0
print(n)' "$BLOG" "$bm" 2>/dev/null)"
[ "${bn:-0}" -gt 0 ] && pass "MCP доски на разрешённом loopback-порту работает из песочницы ($bn вызовов)" || fail "MCP доски из песочницы не вызван (см. stub-board.jsonl)"
if [ "$SBX_FLAG_OK" = 1 ]; then
  C="$(new_clone sb-clone-nested)"; write_probe "$C"
  AGENT_PREFIX="sandbox-exec -f $PROF_DIR/it$IT.sb" arun sb-run-default-cli-sandbox "$C" -- -p --output-format stream-json --model "$MODEL" --force "Run this exact shell command: bash probe.sh probe-result-agent.txt
Then reply with the single word DONE."
  summarize_run sb-run-default-cli-sandbox
  if [ -s "$C/probe-result-agent.txt" ]; then info "без --sandbox disabled (настройка CLI по умолчанию) shell-команды внутри sandbox-exec тоже работают"; else info "без --sandbox disabled shell-команды внутри sandbox-exec НЕ отработали (вложенная песочница CLI?) — демону нужен --sandbox disabled"; fi
fi
manual "Kaban-демон: argv = sandbox-exec -f <профиль> cursor-agent ... — сверить с итоговым профилем и списком WP выше"

# ========================================================================
section "5. Эксперимент: CLI вне песочницы, песочница только для его инструментов"
run_cap_timeout 30 help-sandbox "$CA" sandbox --help
run_cap_timeout 30 help-sandbox-run "$CA" sandbox run --help
info "\`sandbox --help\`: \`$(strip_ansi_file "$OUT/help-sandbox.stdout" | tr -s ' \n' ' ' | cut -c1-300)\`"
if [ "$SBX_FLAG_OK" = 1 ]; then pass "в --help есть --sandbox (enabled|disabled) — песочница инструментов встроена в CLI"; else info "флага --sandbox в --help нет"; fi
SC="$(new_clone clisb-clone)"; write_probe "$SC"
run_in "$SC" 60 clisb-default "$CA" sandbox run bash probe.sh probe-result-clisb-default.txt
info "\`cursor-agent sandbox run\` (по умолчанию): exit $(rc_of clisb-default); пробы: \`$(tr '\n' ' ' < "$SC/probe-result-clisb-default.txt" 2>/dev/null)\`"
run_in "$SC" 60 clisb-network "$CA" sandbox run --network bash probe.sh probe-result-clisb-network.txt
info "\`sandbox run --network\`: \`$(tr '\n' ' ' < "$SC/probe-result-clisb-network.txt" 2>/dev/null)\`"
run_in "$SC" 60 clisb-blocked "$CA" sandbox run --blocked-patterns "$GSTORE/**" bash probe.sh probe-result-clisb-blocked.txt
info "\`sandbox run --blocked-patterns <globalStorage>/**\`: \`$(tr '\n' ' ' < "$SC/probe-result-clisb-blocked.txt" 2>/dev/null)\`"
for f in default network blocked; do [ -f "$SC/probe-result-clisb-$f.txt" ] && cp "$SC/probe-result-clisb-$f.txt" "$OUT/"; done
v="$(pval "$SC/probe-result-clisb-default.txt" READ_STATE_VSCDB)"
case "$v" in 0) info "встроенная песочница CLI по умолчанию НЕ запрещает чтение state.vscdb";; absent|"") :;; *) info "встроенная песочница CLI запрещает чтение state.vscdb (код $v)";; esac
run_in "$SC" 60 clisb-debug "$CA" sandbox run --sb-debug /usr/bin/true
mkdir -p "$OUT/cli-sb-debug"
for p in $(cat "$OUT/clisb-debug.stdout" "$OUT/clisb-debug.stderr" 2>/dev/null | grep -oE '/[^[:space:]"'"'"']+' | sort -u); do
  case "$p" in /private/var/folders/*|/var/folders/*|/tmp/*|/private/tmp/*) [ -e "$p" ] && cp -R "$p" "$OUT/cli-sb-debug/" 2>/dev/null;; esac
done
info "\`sandbox run --sb-debug\`: exit $(rc_of clisb-debug), скопировано в cli-sb-debug/: $(find "$OUT/cli-sb-debug" -type f | wc -l | tr -d ' ') файлов (там их сгенерированный профиль, если CLI его пишет)"
if [ "$SBX_FLAG_OK" = 1 ]; then
  AC="$(new_clone clisb-agent)"; write_probe "$AC"
  arun clisb-agent "$AC" -- -p --output-format stream-json --model "$MODEL" --force --sandbox enabled "Run this exact shell command: bash probe.sh probe-result-agent.txt
Then reply with the single word DONE."
  summarize_run clisb-agent
  if [ -s "$AC/probe-result-agent.txt" ]; then
    cp "$AC/probe-result-agent.txt" "$OUT/probe-result-clisb-agent.txt"
    info "агент с --sandbox enabled (CLI вне sandbox-exec), пробы его shell-команды: \`$(tr '\n' ' ' < "$AC/probe-result-agent.txt")\`"
  else
    info "агент с --sandbox enabled: результатов проб нет (exit $(rc_of clisb-agent))"
  fi
fi
manual "вывод: можно ли держать CLI вне sandbox-exec, а его shell-команды — в песочнице CLI (--sandbox enabled + sandbox.* в cli-config / --blocked-patterns), и закрывает ли это чтение токена CLI и state.vscdb из команд агента"

# ========================================================================
section "6. git и тривиальная сборка под профилем"
BC="$(new_clone build-clone)"
render "$PROF_DIR/build.sb" "$BC" ${WP[@]+"${WP[@]}"}
cat > "$PROF_DIR/git-test.sh" <<'GT'
set -e
G="git -c user.name=kaban-spike -c user.email=kaban-spike@local -c commit.gpgsign=false"
$G checkout -q -b kaban/sb-test
echo "sandbox" >> README.md
$G commit -qam "sandbox commit"
$G log --oneline -1 >/dev/null
echo GIT_OK
GT
run_in "$BC" 60 sb-git sandbox-exec -f "$PROF_DIR/build.sb" /bin/bash "$PROF_DIR/git-test.sh"
grep -q GIT_OK "$OUT/sb-git.stdout"; check $? "git checkout -b / commit в клоне под профилем работают" "git под профилем: \`$(first_line "$OUT/sb-git.stderr")\`"
if command -v make >/dev/null 2>&1 && command -v cc >/dev/null 2>&1; then
  printf 'int main(void){return 0;}\n' > "$BC/hello.c"
  printf 'hello: hello.c\n\tcc -o hello hello.c\n' > "$BC/Makefile.sb"
  T0="$(now_log)"
  run_in "$BC" 300 sb-make sandbox-exec -f "$PROF_DIR/build.sb" make -f Makefile.sb
  check "$(rc_of sb-make)" "make + cc под профилем: сборка прошла" "make + cc под профилем: exit $(rc_of sb-make) \`$(first_line "$OUT/sb-make.stderr")\`"
  sleep 2; log_sandbox "$T0" sblog-make
  ks sblog "$OUT/sblog-make.deny.txt" --home "$HOMER" "${EXPECTED_DENY[@]}" "${OUR_PROCS[@]}" --save "$OUT/sblog-make.json" >/dev/null 2>&1
fi
if command -v swift >/dev/null 2>&1; then
  mkdir -p "$BC/tinypkg/Sources/tiny"
  cat > "$BC/tinypkg/Package.swift" <<'SW'
// swift-tools-version:5.7
import PackageDescription
let package = Package(name: "tiny", targets: [.executableTarget(name: "tiny", path: "Sources/tiny")])
SW
  echo 'print("tiny ok")' > "$BC/tinypkg/Sources/tiny/main.swift"
  T0="$(now_log)"
  # --disable-sandbox: SwiftPM сам использует sandbox-exec для манифестов, вложенная песочница невозможна
  run_in "$BC/tinypkg" 900 sb-swift sandbox-exec -f "$PROF_DIR/build.sb" swift build --disable-sandbox
  sleep 2; log_sandbox "$T0" sblog-swift
  ks sblog "$OUT/sblog-swift.deny.txt" --home "$HOMER" "${EXPECTED_DENY[@]}" "${OUR_PROCS[@]}" --save "$OUT/sblog-swift.json" --suggest > "$OUT/swift-extra-write.txt" 2>/dev/null
  if [ "$(rc_of sb-swift)" = 0 ]; then
    pass "swift build --disable-sandbox под профилем прошёл ($(secs_of sb-swift) с)"
  else
    fail "swift build под профилем: exit $(rc_of sb-swift) — \`$(grep -m1 -iE 'error|denied|not permitted' "$OUT/sb-swift.stderr" "$OUT/sb-swift.stdout" | cut -c1-200)\`"
  fi
  # SwiftPM кладёт lock-файлы в /tmp и $TMPDIR с именем пути пакета — убираем свои
  find /private/tmp /tmp "$TMPR" -maxdepth 1 -name '*kaban-spike6*.lock' -exec rm -f {} + 2>/dev/null
  [ -s "$OUT/swift-extra-write.txt" ] && info "swift хотел писать ещё в: \`$(tr '\n' ' ' < "$OUT/swift-extra-write.txt")\` (кэши SwiftPM/ModuleCache — кандидаты в профиль гейтов)"
else
  info "swift не найден — сборку SwiftPM не проверяли"
fi

# ========================================================================
section "7. Клоны: git clone --local, fetch демоном, cp -c (APFS clonefile) для warm_paths"
df_avail() { df -k "$1" | awk 'NR==2 {print $4}'; }
ms_of() { ks meta "$OUT/$1" duration_ms; }
if [ -n "${KABAN_SPIKE_REPO:-}" ]; then
  SRC="$(cd "$KABAN_SPIKE_REPO" && pwd -P)" || { fail "KABAN_SPIKE_REPO не найден"; finish; exit 1; }
  [ -d "$SRC/.git" ] || { fail "KABAN_SPIKE_REPO=$SRC — не git-репозиторий (нужен каталог с .git)"; finish; exit 1; }
  info "репозиторий для замеров: \`$SRC\` (только чтение)"
else
  SRC="$BASE/gen-repo"; mkdir -p "$SRC"
  ks mkfiles "$SRC" 2000 --prefix src
  ( cd "$SRC" && g init -q -b main && printf 'node_modules/\n' > .gitignore && g add . && g commit -qm "2000 files" \
    && echo more >> src/d000/f00000.txt && g commit -qam second ) >/dev/null 2>&1
  mkdir -p "$SRC/node_modules"
  ks mkfiles "$SRC/node_modules" 3000 --prefix pkg --ext js --min-size 200 --max-size 4000 --seed 7
  for i in 1 2 3; do dd if=/dev/urandom of="$SRC/node_modules/blob$i.bin" bs=1m count=10 2>/dev/null; done
  info "сгенерирован репозиторий: 2000 файлов, 2 коммита; node_modules (игнор.): 3000 файлов + 30 МБ"
fi
info "исходник: $(du -sk "$SRC" | awk '{print $1}') КБ, из них .git: $(du -sk "$SRC/.git" | awk '{print $1}') КБ; файлов в рабочей копии (без .git): $(find "$SRC" -path "$SRC/.git" -prune -o -type f -print | wc -l | tr -d ' ')"
CL="$BASE/clone-measure"
a0="$(df_avail "$BASE")"
run_cap_timeout 3600 clone-local git clone -q --local "$SRC" "$CL"
a1="$(df_avail "$BASE")"
check "$(rc_of clone-local)" "git clone --local: $(ms_of clone-local) мс, df: −$((a0 - a1)) КБ" "git clone --local упал: \`$(first_line "$OUT/clone-local.stderr")\`"
tot="$(find "$CL/.git/objects" -type f | wc -l | tr -d ' ')"; hl="$(find "$CL/.git/objects" -type f -links +1 | wc -l | tr -d ' ')"
inc="$(du -sk "$SRC" "$CL" | awk 'NR==2 {print $1}')"
info "клон: du=$(du -sk "$CL" | awk '{print $1}') КБ, прирост к исходнику (du учитывает хардлинки один раз)=$inc КБ; .git/objects: $(du -sk "$CL/.git/objects" | awk '{print $1}') КБ, файлов-объектов $tot, из них хардлинков $hl"
# fetch ветки задачи демоном во временный клон слияния (исходник не трогаем)
( cd "$CL" && g checkout -q -b kaban/measure && echo "task change" >> kaban-measure.txt && g add kaban-measure.txt && g commit -qm "task commit" ) >/dev/null 2>&1
MG="$BASE/merge-clone"
run_cap_timeout 3600 merge-clone git clone -q --local --no-checkout "$SRC" "$MG"
run_in "$MG" 600 fetch-branch git fetch -q "$CL" kaban/measure:refs/heads/kaban/measure
check "$(rc_of fetch-branch)" "git fetch ветки из клона задачи в клон слияния: $(ms_of fetch-branch) мс (клон слияния --no-checkout: $(ms_of merge-clone) мс)" "fetch ветки упал: \`$(first_line "$OUT/fetch-branch.stderr")\`"
# Альтернатива: APFS-клон всего каталога
CP="$BASE/cpc-whole"
a0="$(df_avail "$BASE")"
run_cap_timeout 3600 cpc-whole cp -c -R "$SRC" "$CP"
a1="$(df_avail "$BASE")"
info "для сравнения \`cp -c -R\` всего репозитория (APFS clonefile): exit $(rc_of cpc-whole), $(ms_of cpc-whole) мс, df: −$((a0 - a1)) КБ"
rm -rf "$CP"
# warm_paths
WARM="${KABAN_SPIKE_WARM:-}"
if [ -z "$WARM" ]; then
  for p in node_modules .build DerivedData build Pods target .venv; do [ -d "$SRC/$p" ] && WARM="${WARM:+$WARM,}$p"; done
fi
if [ -z "$WARM" ]; then
  info "warm_paths не найдены в исходнике (node_modules/.build/DerivedData/build/Pods/target/.venv) — задай KABAN_SPIKE_WARM"
else
  OLDIFS="$IFS"; IFS=','; set -- $WARM; IFS="$OLDIFS"
  for wp in "$@"; do
    [ -d "$SRC/$wp" ] || { info "warm_path \`$wp\` нет в исходнике"; continue; }
    sz="$(du -sk "$SRC/$wp" | awk '{print $1}')"; nf="$(find "$SRC/$wp" -type f | wc -l | tr -d ' ')"
    nm="warm-$(echo "$wp" | tr -c 'A-Za-z0-9' '_')"
    mkdir -p "$CL/$(dirname "$wp")"
    a0="$(df_avail "$BASE")"
    run_cap_timeout 3600 "$nm-cpc" cp -c -R "$SRC/$wp" "$CL/$wp"
    a1="$(df_avail "$BASE")"
    check "$(rc_of "$nm-cpc")" "warm_path \`$wp\` ($sz КБ, $nf файлов): \`cp -c -R\` за $(ms_of "$nm-cpc") мс, df: −$((a0 - a1)) КБ" "\`cp -c -R $wp\` упал: \`$(first_line "$OUT/$nm-cpc.stderr")\`"
    if [ "$sz" -lt 307200 ]; then
      a0="$(df_avail "$BASE")"
      run_cap_timeout 3600 "$nm-cp" cp -R "$SRC/$wp" "$CL/$wp.plaincopy"
      a1="$(df_avail "$BASE")"
      info "для сравнения обычный \`cp -R\` \`$wp\`: $(ms_of "$nm-cp") мс, df: −$((a0 - a1)) КБ"
      rm -rf "$CL/$wp.plaincopy"
    else
      info "обычный cp -R для \`$wp\` пропущен (больше 300 МБ)"
    fi
  done
fi
info "df на APFS шумный (параллельная запись других программ, снапшоты) — смотри порядок величин"

finish
