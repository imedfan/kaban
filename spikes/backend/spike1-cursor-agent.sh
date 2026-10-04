#!/usr/bin/env bash
# Спайк 1 (§14 п.1 архитектуры): cursor-agent headless.
#
# Что выясняем: флаги и подкоманды CLI; формат --list-models; запись без
# подтверждения с --force и без него; поля system/init и result (usage);
# совпадает ли init.model с названием из каталога; --resume в -p; ошибочные
# фикстуры (плохая модель, без --model); соблюдение deny-правил под --force;
# SIGTERM группе процессов; отдельный HOME / CURSOR_CONFIG_DIR и логин; где
# лежит токен CLI (только имена); `mcp list` в чистом репо; запуск из-под
# временного LaunchAgent (PATH, авторизация, read-only count в state.vscdb).
#
# Запуск: KABAN_SPIKE_MODEL=<id> ./spike1-cursor-agent.sh
# Стоимость: ~7 коротких запусков дешёвой модели (+1 из-под LaunchAgent).
SPIKE_NAME=spike1-cursor-agent
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/common.sh"
require_macos
require_agent
need git
need launchctl

CHEAP_PROMPT='Reply with the single word OK. Do not use any tools.'
WRITE_PROMPT='Create a file named hello.txt in the current directory containing exactly the text: hello kaban
Then run this shell command exactly: echo shell-ok > shell.txt
Do nothing else. When finished, reply with the single word DONE.'
RESUME_PROMPT='What exact text did you write into hello.txt earlier in this conversation? Answer from memory with only that text. Do not use any tools.'
DENY_PROMPT='Run these two shell commands one after another, exactly as written: first `touch denied.txt`, then `echo allowed > allowed.txt`. If a command is rejected, do not retry it and do not work around it. Then reply with the single word DONE.'
SLEEP_PROMPT='Run this exact shell command and wait for it to finish: sleep 25; echo late > late.txt
Then reply with the single word DONE.'
STATE_DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
TA=(); [ -n "$TRUST_ARG" ] && TA=("$TRUST_ARG")

# ------------------------------------------------------------------------
section "0. Окружение"
info "macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m)), bash $BASH_VERSION, python $("$PY" -c 'import platform;print(platform.python_version())')"
info "cursor-agent: \`$CA\` → \`$("$PY" -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CA")\`"
info "модель спайка: \`$MODEL\`, таймаут запуска: ${AGENT_TIMEOUT} с"

# ------------------------------------------------------------------------
section "1. --version / --help / подкоманды"
run_cap_timeout 30 version "$CA" --version
info "версия: \`$(first_line "$OUT/version.stdout")\` (exit $(rc_of version))"
run_cap_timeout 30 help "$CA" --help
cat "$OUT/help.stdout" "$OUT/help.stderr" > "$OUT/help-all.txt" 2>/dev/null
ks help-flags "$OUT/help-all.txt" > "$OUT/help-flags.txt"
present=""; missing=""
for f in --print --output-format --model --force --approve-mcps --resume --list-models --sandbox --trust --workspace --api-key --stream-partial-output; do
  if grep -q -- "$f" "$OUT/help-all.txt"; then present="$present $f"; else missing="$missing $f"; fi
done
if grep -qE '(^|[[:space:]])-p[,[:space:]]' "$OUT/help-all.txt"; then present="-p$present"; else missing="-p$missing"; fi
[ -n "$present" ] && pass "в --help есть:$present"
[ -n "$missing" ] && fail "в --help НЕТ:$missing"
dbg="$(grep -E -- '--(debug|verbose|log[a-z-]*|trace)' "$OUT/help-all.txt" | tr -s ' ' | head -n 5 | tr '\n' ' ')"
if [ -n "$dbg" ]; then info "опции отладки/логов в --help: \`$dbg\`"; else info "опций --debug/--verbose/--log* в --help нет (capture-run пишет только stream-json+stderr)"; fi
for sub in mcp sandbox status models; do
  run_cap_timeout 30 "help-$sub" "$CA" "$sub" --help
done
info "сохранены: help-all.txt, help-flags.txt, help-{mcp,sandbox,status,models}.stdout"
mcpflags="$(grep -iE -- '--[a-z-]*mcp[a-z-]*' "$OUT/help-all.txt" | tr -s ' ' | tr '\n' ' ' | cut -c1-300)"
info "флаги про MCP в --help: \`${mcpflags:-нет}\`"

# ------------------------------------------------------------------------
section "2. status"
run_cap_timeout 30 status "$CA" status
st="$(ks login-state "$OUT/status.stdout" "$OUT/status.stderr")"
check "$([ "$st" = logged_in ] && echo 0 || echo 1)" "status: CLI залогинен (exit $(rc_of status))" "status: состояние логина = $st (exit $(rc_of status)) — см. status.stdout"
run_cap_timeout 30 status-json "$CA" status --format json
keys="$("$PY" - "$OUT/status-json.stdout" <<'PY' 2>/dev/null
import json, sys
try:
    o = json.load(open(sys.argv[1]))
    print(", ".join(sorted(o.keys())) if isinstance(o, dict) else type(o).__name__)
except Exception as e:
    print("не JSON")
PY
)"
info "status --format json: exit $(rc_of status-json), ключи: ${keys:-—} (значения не выводим)"

# ------------------------------------------------------------------------
section "3. --list-models"
run_cap_timeout 90 list-models "$CA" --list-models
ks models "$OUT/list-models.stdout" --save "$OUT/models.json"
n="$(ks models "$OUT/list-models.stdout" --count)"
check "$([ "${n:-0}" -gt 0 ] && echo 0 || echo 1)" "--list-models: распознано строк \`id - название\`: $n (models.json)" "--list-models: строки \`id - название\` не распознаны (exit $(rc_of list-models)), см. list-models.stdout"
unp="$("$PY" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["unparsed"]))' "$OUT/models.json" 2>/dev/null)"
info "нераспознанных строк (заголовки/подсказки): ${unp:-?}; пометки у строк: $("$PY" -c 'import json,sys;r=json.load(open(sys.argv[1]))["rows"];print(sorted({f for x in r for f in x["flags"]}) or "нет")' "$OUT/models.json" 2>/dev/null)"
MODEL_NAME="$(ks models "$OUT/list-models.stdout" --find "$MODEL" || true)"
if [ -n "$MODEL_NAME" ]; then pass "модель \`$MODEL\` есть в каталоге, название: \"$MODEL_NAME\""; else fail "модели \`$MODEL\` нет в --list-models — остальные запуски, скорее всего, упадут"; fi
run_cap_timeout 90 models-cmd "$CA" models
same="$("$PY" - "$OUT/list-models.stdout" "$OUT/models-cmd.stdout" "$KSPIKE" <<'PY' 2>/dev/null
import sys, importlib.util
spec = importlib.util.spec_from_file_location("k", sys.argv[3]); k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
a = k.parse_models(open(sys.argv[1], errors="replace").read())["rows"]
b = k.parse_models(open(sys.argv[2], errors="replace").read())["rows"]
print("совпадает" if [(x["id"], x["name"]) for x in a] == [(x["id"], x["name"]) for x in b] else "отличается (%d vs %d строк)" % (len(a), len(b)))
PY
)"
info "\`cursor-agent models\` vs \`--list-models\`: ${same:-не сравнить}"

# ------------------------------------------------------------------------
section "4. Базовый запуск: -p --output-format stream-json --model M --force (запись файла)"
R1="$(make_repo basic)"
ARUN_NO_TRUST=1 arun basic-force "$R1" -- -p --output-format stream-json --model "$MODEL" --force "$WRITE_PROMPT"
BASIC=basic-force; NEED_TRUST=0
if [ "$(rc_of basic-force)" != 0 ] && grep -qi 'trust' "$OUT/basic-force.stdout" "$OUT/basic-force.stderr" 2>/dev/null; then
  NEED_TRUST=1
  info "без --trust запуск упал с упоминанием trust: \`$(grep -hi trust "$OUT/basic-force.stderr" "$OUT/basic-force.stdout" | head -n1 | cut -c1-200)\` → повтор с --trust"
  if grep -q -- '--trust' "$OUT/help-all.txt"; then
    TRUST_ARG="--trust"; TA=("--trust")
    ( cd "$R1" && g reset -q --hard && g clean -qfdx ) >/dev/null 2>&1
    arun basic-force-trust "$R1" -- -p --output-format stream-json --model "$MODEL" --force "$WRITE_PROMPT"
    BASIC=basic-force-trust
  fi
else
  TRUST_ARG=""; TA=()
fi
echo "$NEED_TRUST" > "$OUT_ROOT/.trust-needed"
info "нужен ли --trust для -p в новом каталоге: $([ $NEED_TRUST = 1 ] && echo ДА || echo нет)"
summarize_run "$BASIC"
F="$OUT/$BASIC.stdout"
check "$(rc_of "$BASIC")" "exit 0" "exit $(rc_of "$BASIC") — см. $BASIC.stderr: \`$(first_line "$OUT/$BASIC.stderr")\`"
[ "$(cat "$R1/hello.txt" 2>/dev/null | tr -d '\r\n')" = "hello kaban" ]
check $? "--force: hello.txt записан без подтверждения" "--force: hello.txt не записан или содержимое другое"
[ "$(cat "$R1/shell.txt" 2>/dev/null | tr -d '\r\n')" = "shell-ok" ]
check $? "--force: shell-команда выполнена без подтверждения (shell.txt)" "--force: shell.txt не создан"
has_result "$F"; check $? "есть терминальное событие result (subtype=$(sj_get "$F" result.subtype), is_error=$(sj_get "$F" result.is_error))" "нет события result"
INIT_MODEL="$(init_model "$F")"
mm="$(ks name-match --catalog "$MODEL_NAME" --init "$INIT_MODEL")"
case "$mm" in
  exact) pass "init.model совпал с названием из каталога: \"$INIT_MODEL\"" ;;
  casefold|normalized) info "init.model совпал с каталогом с точностью до регистра/пробелов ($mm): init=\"$INIT_MODEL\", каталог=\"$MODEL_NAME\"" ;;
  *) fail "init.model ≠ названию каталога ($mm): init=\"$INIT_MODEL\", каталог=\"$MODEL_NAME\" — сверка модели по имени потребует таблицы соответствий" ;;
esac
SID="$(session_id "$F")"
[ -n "$SID" ]; check $? "session_id есть в init/result" "session_id не найден"
info "поля system/init: \`$(sj_get "$F" init.fields)\`; apiKeySource=\`$(sj_get "$F" init.apiKeySource)\`, permissionMode=\`$(sj_get "$F" init.permissionMode)\`; прочие поля init: \`$(sj_get "$F" init.extra)\`"
info "поля result: \`$(sj_get "$F" result.fields)\`"
u="$(sj_get "$F" result.usage_like)"
if [ -n "$u" ] && [ "$u" != "{}" ]; then pass "в result есть usage-подобные поля: \`$u\`"; else info "usage в result НЕТ (поля usage/token/cost не найдены)"; fi
info "типы событий: \`$(sj_get "$F" event_kinds)\`; виды tool_call: \`$(sj_get "$F" tool_calls.kinds)\`"
info "все имена полей по типам событий: \`$BASIC.summary.json\` → field_names"

# ------------------------------------------------------------------------
section "5. Тот же запуск без --force"
R2="$(make_repo noforce)"
ARUN_TIMEOUT=150 arun noforce "$R2" -- -p --output-format stream-json --model "$MODEL" "$WRITE_PROMPT"
summarize_run noforce
if [ "$(rc_of noforce)" = 124 ]; then info "без --force запуск ЗАВИС до таймаута (ждал подтверждения?)"; fi
if [ -f "$R2/hello.txt" ]; then info "без --force hello.txt ЗАПИСАН (запись файлов в -p не требует --force)"; else info "без --force hello.txt НЕ записан"; fi
if [ -f "$R2/shell.txt" ]; then info "без --force shell-команда ВЫПОЛНЕНА"; else info "без --force shell-команда НЕ выполнена"; fi
info "результаты tool_call без --force (ключи result): \`$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print([(t["kind"],t.get("result_keys")) for t in d["tool_calls"]["details"] if t.get("subtype")=="completed"])' "$OUT/noforce.summary.json" 2>/dev/null)\`"

# ------------------------------------------------------------------------
section "6. --resume <session_id> в -p"
if [ -n "$SID" ]; then
  arun resume "$R1" -- -p --output-format stream-json --model "$MODEL" --resume "$SID" "$RESUME_PROMPT"
  summarize_run resume
  FR="$OUT/resume.stdout"
  grep -qi 'hello kaban' <<<"$(sj_get "$FR" result.result_text)"
  check $? "--resume помнит контекст (ответ содержит 'hello kaban')" "--resume: ответ не содержит 'hello kaban': \`$(sj_get "$FR" result.result_text | head -c 200)\`"
  RSID="$(session_id "$FR")"
  [ "$RSID" = "$SID" ]; check $? "session_id после --resume тот же" "session_id после --resume другой (было/стало: $( [ -n "$RSID" ] && echo 'разные' || echo 'нет нового' ))"
  RIM="$(init_model "$FR")"
  if [ -n "$RIM" ]; then info "после --resume снова есть system/init, init.model=\"$RIM\" ($(ks name-match --catalog "$MODEL_NAME" --init "$RIM"))"; else info "после --resume события system/init НЕТ — сверка модели при resume невозможна"; fi
else
  fail "session_id нет — --resume пропущен"
fi

# ------------------------------------------------------------------------
section "7. Ошибочные фикстуры: плохой id модели и запуск без --model"
R3="$(make_repo errors)"
ARUN_TIMEOUT=90 arun bad-model "$R3" -- -p --output-format stream-json --model kaban-no-such-model-0000 "$CHEAP_PROMPT"
summarize_run bad-model
info "плохая модель: exit=$(rc_of bad-model), stderr: \`$(first_line "$OUT/bad-model.stderr")\`, stdout: \`$(first_line "$OUT/bad-model.stdout")\`"
save_fixture spike1-bad-model bad-model
ARUN_TIMEOUT=120 arun no-model "$R3" -- -p --output-format stream-json "$CHEAP_PROMPT"
summarize_run no-model
info "без --model: init.model=\"$(init_model "$OUT/no-model.stdout")\" (это то, что CLI называет Auto/дефолтом)"
save_fixture spike1-no-model no-model
save_fixture spike1-success "$BASIC"
info "фикстуры: \`fixtures/spike1-{success,bad-model,no-model}\`"

# ------------------------------------------------------------------------
section "8. Deny-правило проекта (.cursor/cli.json) под --force"
R4="$(make_repo deny)"
mkdir -p "$R4/.cursor"
printf '%s\n' '{"version":1,"permissions":{"allow":[],"deny":["Shell(touch)"]}}' > "$R4/.cursor/cli.json"
arun deny-rule "$R4" -- -p --output-format stream-json --model "$MODEL" --force "$DENY_PROMPT"
summarize_run deny-rule
[ ! -e "$R4/denied.txt" ]; check $? "deny Shell(touch) соблюдён под --force (denied.txt не создан)" "deny Shell(touch) НЕ сработал под --force (denied.txt создан)"
if [ -f "$R4/allowed.txt" ]; then info "разрешённая команда выполнена (allowed.txt есть)"; else info "allowed.txt нет (агент остановился после отказа?)"; fi
info "как выглядит отказ в stream-json (ключи result shell-вызовов): \`$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print([{k:v for k,v in t.items() if k.startswith(("kind","arg_command","result"))} for t in d["tool_calls"]["details"] if t.get("subtype")=="completed"])' "$OUT/deny-rule.summary.json" 2>/dev/null | cut -c1-600)\`"

# ------------------------------------------------------------------------
section "9. SIGTERM группе процессов после первого tool_call"
R5="$(make_repo sigterm)"
ks killtest --timeout 180 --delay 2 --out "$OUT/sigterm" --cwd "$R5" --sentinel "$R5/late.txt" --wait-after 30 -- \
  "$CA" ${TA[@]+"${TA[@]}"} -p --output-format stream-json --model "$MODEL" --force "$SLEEP_PROMPT" > "$OUT/sigterm.result.txt" 2>&1
KM="$OUT/sigterm"
seen="$(ks meta "$KM" tool_call_seen)"
if [ "$seen" = "True" ] || [ "$seen" = "true" ]; then
  info "убит на первом tool_call ($(ks meta "$KM" trigger_kind)), шаги: $(ks meta "$KM" kill_steps), exit=$(ks meta "$KM" exit) через $(ks meta "$KM" exit_after_ms) мс"
  tree="$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));t=d["tree_before_kill"];print("%d потомков, вне группы: %d" % (len(t), sum(1 for x in t if not x["same_group"])))' "$KM.meta.json" 2>/dev/null)"
  info "дерево процессов перед kill: $tree (подробно: sigterm.meta.json)"
  sv="$("$PY" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["survivors_3s"]))' "$KM.meta.json" 2>/dev/null)"
  [ "${sv:-1}" = 0 ]; check $? "после killpg живых потомков нет" "после killpg живы $sv потомков (вышли из группы?) — см. sigterm.meta.json survivors_3s"
  le="$(ks meta "$KM" sentinel_exists_after_wait)"
  if [ "$le" = "True" ] || [ "$le" = "true" ]; then fail "late.txt появился через 30 с — дочерняя команда пережила SIGTERM группы"; else pass "late.txt не появился — дочерняя shell-команда убита вместе с группой"; fi
else
  fail "tool_call не дождались за 180 с (exit $(ks meta "$KM" exit)) — см. sigterm.stdout/stderr"
fi

# ------------------------------------------------------------------------
section "10. Отдельный HOME и CURSOR_CONFIG_DIR: сохраняется ли логин"
TH="$(mktmp home)"
R6="$(make_repo clean)"
run_in "$R6" 30 home-status env HOME="$TH" "$CA" status
hs="$(ks login-state "$OUT/home-status.stdout" "$OUT/home-status.stderr")"
check "$([ "$hs" = logged_in ] && echo 0 || echo 1)" "HOME=<пустой temp>: status = залогинен" "HOME=<пустой temp>: status = $hs (\`$(first_line "$OUT/home-status.stdout")\`)"
run_in "$R6" 90 home-list-models env HOME="$TH" "$CA" --list-models
hn="$(ks models "$OUT/home-list-models.stdout" --count)"
check "$([ "${hn:-0}" -gt 0 ] && echo 0 || echo 1)" "HOME=<temp>: --list-models работает ($hn моделей)" "HOME=<temp>: --list-models не работает (exit $(rc_of home-list-models)): \`$(first_line "$OUT/home-list-models.stderr")\`"
run_in "$R6" 60 home-mcp-list env HOME="$TH" "$CA" mcp list
info "HOME=<temp>: \`mcp list\` exit $(rc_of home-mcp-list): \`$(first_line "$OUT/home-mcp-list.stdout")\`"
( cd "$TH" && find . -type f 2>/dev/null | sort ) > "$OUT/home-created-files.txt"
info "что CLI создал в пустом HOME (только имена): $(wc -l < "$OUT/home-created-files.txt" | tr -d ' ') файлов, \`$(head -n 12 "$OUT/home-created-files.txt" | tr '\n' ' ')\`"
TC="$(mktmp cfgdir)"
run_in "$R6" 30 cfgdir-status env CURSOR_CONFIG_DIR="$TC" "$CA" status
cs="$(ks login-state "$OUT/cfgdir-status.stdout" "$OUT/cfgdir-status.stderr")"
info "CURSOR_CONFIG_DIR=<пустой temp>: status = $cs; создано файлов: $(find "$TC" -type f 2>/dev/null | wc -l | tr -d ' ') (\`$(cd "$TC" && find . -type f | head -n 8 | tr '\n' ' ')\`)"

# ------------------------------------------------------------------------
section "11. Где лежит токен CLI (только имена файлов и атрибутов Keychain)"
ks keychain-scan > "$OUT/keychain-cursor-items.txt" 2>&1
info "Keychain (security dump-keychain без -d, только элементы с 'cursor'): \`$(tail -n 1 "$OUT/keychain-cursor-items.txt")\`; атрибуты: \`$(grep -v '^items_with' "$OUT/keychain-cursor-items.txt" | head -n 6 | tr -s ' ' | tr '\n' '|' | cut -c1-600)\`"
for svc in cursor-access-token cursor-refresh-token cursor-api-key cursor-agent; do
  r="$(ks keychain-scan --service "$svc" 2>&1 | tail -n 1)"
  case "$r" in *"rc=0"*) info "Keychain: generic password с service=\`$svc\` ЕСТЬ (секрет не читали)";; *) : ;; esac
done
{
  for d in "$HOME/.cursor" "$HOME/.config/cursor" "$HOME/.local/share/cursor-agent" "$HOME/Library/Application Support/cursor-agent" "$HOME/Library/Application Support/Cursor" "$HOME/Library/Caches/cursor-agent"; do
    rel="~/${d#"$HOME"/}"
    if [ -d "$d" ]; then echo "[есть] $rel"; else echo "[нет]  $rel"; fi
  done
  echo "--- ~/.cursor (глубина 1, только имена)"
  [ -d "$HOME/.cursor" ] && ( cd "$HOME/.cursor" && ls -1A )
  echo "--- имена файлов с auth/token/cred/session/key (глубина ≤3)"
  for d in "$HOME/.cursor" "$HOME/.config/cursor" "$HOME/.local/share/cursor-agent"; do
    [ -d "$d" ] && find "$d" -maxdepth 3 -type f -not -path '*/extensions/*' \( -iname '*auth*' -o -iname '*token*' -o -iname '*cred*' -o -iname '*session*' -o -iname '*key*' \) 2>/dev/null | sed "s|^$HOME|~|" | grep -v '/chats/' | head -n 30
  done
  echo "--- json-файлы, где встречаются ИМЕНА ключей accessToken/refreshToken/apiKey (значения не читаются)"
  for d in "$HOME/.cursor" "$HOME/.config/cursor"; do
    [ -d "$d" ] && find "$d" -maxdepth 2 -type f -not -path '*/extensions/*' -name '*.json' -size -2048k -print0 2>/dev/null | xargs -0 grep -l -E '"(accessToken|refreshToken|apiKey|access_token|refresh_token)"' 2>/dev/null | sed "s|^$HOME|~|"
  done
} > "$OUT/token-location.txt" 2>&1
info "файлы-кандидаты (только имена): \`token-location.txt\`; json с ключами токенов: \`$(sed -n '/значения не читаются/,$p' "$OUT/token-location.txt" | tail -n +2 | tr '\n' ' ' | cut -c1-300)\`"
manual "по keychain-cursor-items.txt и token-location.txt реши, где токен CLI: Keychain (service=…) или файл в HOME"

# ------------------------------------------------------------------------
section "12. \`mcp list\` в чистом репозитории (реальный HOME)"
R7="$(make_repo mcpclean)"
run_in "$R7" 60 mcp-list-clean "$CA" mcp list
info "exit $(rc_of mcp-list-clean), строк: $(grep -c . "$OUT/mcp-list-clean.stdout" 2>/dev/null), первая: \`$(first_line "$OUT/mcp-list-clean.stdout")\`"
if [ -f "$HOME/.cursor/mcp.json" ]; then
  GNAMES="$("$PY" -c 'import json,sys;print(",".join(sorted((json.load(open(sys.argv[1])).get("mcpServers") or {}).keys())))' "$HOME/.cursor/mcp.json" 2>/dev/null)"
  info "в ~/.cursor/mcp.json серверы (только имена): \`${GNAMES:-—}\`"
  if [ -n "$GNAMES" ]; then
    chk="$(ks mcp-check "$OUT/mcp-list-clean.stdout" --expect "$GNAMES")"
    info "видит ли \`mcp list\` глобальные серверы: \`$chk\`"
    manual "если глобальные серверы видны — fail closed (§9) в реальном HOME всегда сработает; нужен отдельный HOME (см. п.10 и спайк 2)"
  fi
else
  info "~/.cursor/mcp.json нет — глобальных серверов нет"
fi

# ------------------------------------------------------------------------
section "13. Из-под временного LaunchAgent: PATH, status, --list-models, state.vscdb, короткий запуск"
if [ -f "$STATE_DB" ]; then
  info "state.vscdb из Terminal (read-only count ключа cursorAuth/accessToken): \`$(ks sqlite-count "$STATE_DB" cursorAuth/accessToken)\`"
else
  info "state.vscdb не найден (Cursor IDE не установлен?) — проверка из LaunchAgent покажет absent"
fi
LA_DIR="$(mktmp launchd)"
LA_OUT="$LA_DIR/out"; mkdir -p "$LA_OUT"
LA_REPO="$(make_repo larun)"
LABEL="com.kaban.spike1.$$.$RANDOM"
cp "$KSPIKE" "$LA_DIR/kspike.py"   # LaunchAgent не должен читать файлы из каталога спайков (он может быть под TCC)
{
  echo '#!/bin/bash'
  echo '# Временный LaunchAgent спайка 1 Kaban. Пишет только в свой temp-каталог.'
  printf 'O=%q\nPYB=%q\nKS=%q\nCA=%q\nDB=%q\nREPO=%q\nMODEL=%q\nPROMPT=%q\nTRUST=%q\nTMO=%q\n' \
    "$LA_OUT" "$PY" "$LA_DIR/kspike.py" "$CA" "$STATE_DB" "$LA_REPO" "$MODEL" "$CHEAP_PROMPT" "$TRUST_ARG" "$AGENT_TIMEOUT"
  cat <<'LAEOF'
{ echo "PATH=$PATH"; echo "HOME=$HOME"; echo "USER=$(id -un)"; echo "SHELL=${SHELL:-}"; echo "TMPDIR=${TMPDIR:-}"; echo "LANG=${LANG:-}"; } > "$O/env.txt"
/bin/sh -c 'for c in git node python3 swift cursor-agent agent brew; do printf "%s=%s\n" "$c" "$(command -v $c || echo -)"; done' > "$O/which.txt" 2>&1
"$PYB" "$KS" run --timeout 60 --out "$O/status" -- "$CA" status
"$PYB" "$KS" run --timeout 90 --out "$O/list-models" -- "$CA" --list-models
"$PYB" "$KS" sqlite-count "$DB" cursorAuth/accessToken > "$O/sqlite-count.txt" 2>&1
if [ -n "$TRUST" ]; then T="$TRUST"; else T=""; fi
"$PYB" "$KS" run --timeout "$TMO" --cwd "$REPO" --out "$O/run" -- "$CA" $T -p --output-format stream-json --model "$MODEL" "$PROMPT"
touch "$O/done"
LAEOF
} > "$LA_DIR/la.sh"
chmod 700 "$LA_DIR/la.sh"
ks plist --out "$LA_DIR/agent.plist" --label "$LABEL" --stdout "$LA_OUT/launchd.stdout" --stderr "$LA_OUT/launchd.stderr" --workdir "$LA_DIR" /bin/bash "$LA_DIR/la.sh"
DOMAIN="gui/$(id -u)"
on_exit "launchctl bootout $DOMAIN/$LABEL"
if launchctl bootstrap "$DOMAIN" "$LA_DIR/agent.plist" > "$OUT/launchctl-bootstrap.txt" 2>&1; then
  info "LaunchAgent \`$LABEL\` загружен из временного plist; ждём до $((AGENT_TIMEOUT + 200)) с"
  waited=0
  while [ ! -f "$LA_OUT/done" ] && [ "$waited" -lt $((AGENT_TIMEOUT + 200)) ]; do sleep 5; waited=$((waited + 5)); done
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  sleep 1
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then fail "LaunchAgent всё ещё загружен после bootout!"; else pass "LaunchAgent выгружен (bootout)"; fi
  mkdir -p "$OUT/launchd"; cp -R "$LA_OUT/." "$OUT/launchd/" 2>/dev/null
  L="$OUT/launchd"
  [ -f "$L/done" ]; check $? "скрипт LaunchAgent отработал за ${waited} с" "скрипт LaunchAgent не завершился за ${waited} с (см. launchd/launchd.stderr)"
  info "PATH под launchd: \`$(sed -n 's/^PATH=//p' "$L/env.txt" 2>/dev/null)\`; which: \`$(tr '\n' ' ' < "$L/which.txt" 2>/dev/null)\`"
  ls_="$(ks login-state "$L/status.stdout" "$L/status.stderr" 2>/dev/null)"
  check "$([ "$ls_" = logged_in ] && echo 0 || echo 1)" "из-под LaunchAgent status = залогинен" "из-под LaunchAgent status = $ls_ (exit $(cat "$L/status.exit" 2>/dev/null)): \`$(first_line "$L/status.stdout")\` \`$(first_line "$L/status.stderr")\`"
  ln="$(ks models "$L/list-models.stdout" --count 2>/dev/null)"
  check "$([ "${ln:-0}" -gt 0 ] && echo 0 || echo 1)" "из-под LaunchAgent --list-models: $ln моделей" "из-под LaunchAgent --list-models не работает (exit $(cat "$L/list-models.exit" 2>/dev/null))"
  info "из-под LaunchAgent state.vscdb read-only count(cursorAuth/accessToken): \`$(cat "$L/sqlite-count.txt" 2>/dev/null)\`"
  if [ -f "$L/run.stdout" ]; then
    ks sj "$L/run.stdout" --save "$L/run.summary.json" >/dev/null 2>&1
    [ "$(cat "$L/run.exit" 2>/dev/null)" = 0 ] && [ -n "$(sj_get "$L/run.stdout" result.subtype)" ]
    check $? "из-под LaunchAgent -p запуск прошёл (init.model=\"$(init_model "$L/run.stdout")\", apiKeySource=$(sj_get "$L/run.stdout" init.apiKeySource))" "из-под LaunchAgent -p запуск не прошёл (exit $(cat "$L/run.exit" 2>/dev/null)): \`$(first_line "$L/run.stderr")\`"
  fi
else
  fail "launchctl bootstrap не удался: \`$(head -n 2 "$OUT/launchctl-bootstrap.txt" | tr '\n' ' ')\`"
fi
manual "появлялся ли во время шага 13 системный запрос macOS (доступ к данным других приложений, Keychain «cursor-agent хочет использовать…», уведомление «Добавлен фоновый объект»)? Допиши ответ сюда"

# ------------------------------------------------------------------------
section "Коды выхода всех запусков"
for f in "$OUT"/*.exit; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .exit)"
  case "$n" in help-*|version) continue;; esac
  echo "  - \`$n\`: exit $(cat "$f"), $(cat "$OUT/$n.secs" 2>/dev/null || echo '?') с" >> "$SUMMARY"
done

finish
