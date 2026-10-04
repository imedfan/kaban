#!/usr/bin/env bash
# capture-run.sh — один headless-запуск cursor-agent с полным захватом в фикстуру
# для фейкового драйвера Kaban (§6.4 архитектуры: лимитные ошибки, молчаливый выход).
#
# Использование:
#   ./capture-run.sh <имя> [--cwd DIR] [--timeout SEC] [--no-debug] -- <аргументы cursor-agent...>
#
# Примеры (три реальных лимитных случая, когда они случатся в обычной работе):
#   ./capture-run.sh usage-exhausted -- -p --output-format stream-json --model gpt-5 --force "Reply OK"
#   ./capture-run.sh resource-exhausted-silent -- -p --output-format stream-json --model <id> --force "Reply OK"
#   ./capture-run.sh peak-throttle -- -p --output-format stream-json --model <id> "Reply OK"
#
# Если среди аргументов нет -p/--print, добавляется "-p"; если нет --output-format —
# добавляется "--output-format stream-json". Без --cwd запуск идёт во временном git-репо
# (реальные репозитории не трогаем). Результат: out/fixtures/<имя>[-<время>]/
#   stream.jsonl   stdout как есть           stderr.txt   stderr как есть
#   times.jsonl    время прихода каждой строки (мс от старта) и тип события
#   exit_code      код выхода (124 = таймаут) meta.json   argv (маскирован), длительность, хвост
#   summary.json   разбор stream-json          limit-hits.txt  совпадения лимитных шаблонов
#   debug.log      если в --help есть флаг лог-файла/отладки (иначе нет)
#   context.txt    версия CLI, логин (да/нет), каталог моделей до/после, время и часовой пояс
#   new-log-files.txt  ИМЕНА лог-файлов CLI, изменённых во время запуска (содержимое не копируется,
#                      KABAN_CAPTURE_COPY_LOGS=1 — скопировать и замаскировать)
# Вся папка в конце прогоняется через scrub (маскирование токенов/почты).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
KSPIKE="$HERE/lib/kspike.py"
PY="${KABAN_PY:-$(command -v python3 || true)}"
[ -n "$PY" ] || { echo "нужен python3 (xcode-select --install)"; exit 2; }
# KABAN_CURSOR_AGENT; CURSOR_AGENT — только если это путь (в терминалах Cursor CURSOR_AGENT=1)
CA="${KABAN_CURSOR_AGENT:-}"
if [ -z "$CA" ]; then case "${CURSOR_AGENT:-}" in */*) [ -x "$CURSOR_AGENT" ] && CA="$CURSOR_AGENT";; esac; fi
[ -n "$CA" ] || CA="$(command -v cursor-agent || command -v agent || true)"
[ -n "$CA" ] || { echo "cursor-agent не найден (или задай KABAN_CURSOR_AGENT=путь)"; exit 2; }
ks() { "$PY" "$KSPIKE" "$@"; }

usage() { sed -n '2,30p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; shift
case "$NAME" in -*|"") usage;; esac
echo "$NAME" | grep -qE '^[A-Za-z0-9._-]+$' || { echo "имя фикстуры: только [A-Za-z0-9._-]"; exit 2; }
CWD=""; TMO="${KABAN_SPIKE_TIMEOUT:-600}"; DEBUG=1
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2;;
    --timeout) TMO="$2"; shift 2;;
    --no-debug) DEBUG=0; shift;;
    *) echo "неизвестная опция: $1"; usage;;
  esac
done
[ "${1:-}" = "--" ] && shift
[ $# -ge 1 ] || { echo "после -- нужны аргументы cursor-agent (как минимум промпт)"; exit 2; }

OUT_ROOT="${OUT_ROOT:-$HERE/out}"
D="$OUT_ROOT/fixtures/$NAME"
[ -e "$D" ] && D="$D-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$D"

TMPD=""
cleanup() { [ -n "$TMPD" ] && case "$TMPD" in /tmp/kaban-spike*|/private/tmp/kaban-spike*) rm -rf "$TMPD";; esac; }
trap cleanup EXIT
if [ -z "$CWD" ]; then
  TMPD="$(mktemp -d /tmp/kaban-spike-capture.XXXXXX)"; TMPD="$(cd "$TMPD" && pwd -P)"
  CWD="$TMPD"
  ( cd "$CWD" && GIT_CONFIG_GLOBAL=/dev/null git -c user.name=kaban-spike -c user.email=kaban-spike@local \
      -c commit.gpgsign=false init -q -b main && echo '# capture' > README.md && \
    GIT_CONFIG_GLOBAL=/dev/null git -c user.name=kaban-spike -c user.email=kaban-spike@local -c commit.gpgsign=false add . && \
    GIT_CONFIG_GLOBAL=/dev/null git -c user.name=kaban-spike -c user.email=kaban-spike@local -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
else
  echo "ВНИМАНИЕ: запуск в $CWD (не временный каталог). С --force агент может менять файлы."
fi

# Дополняем -p и --output-format, если их нет
has_p=0; has_fmt=0
for a in "$@"; do
  case "$a" in -p|--print) has_p=1;; --output-format|--output-format=*) has_fmt=1;; esac
done
EXTRA=()
[ $has_p = 0 ] && EXTRA+=("-p")
[ $has_fmt = 0 ] && EXTRA+=("--output-format" "stream-json")

# Отладочный лог — только если CLI его заявляет в --help
ks run --timeout 30 --out "$D/.help" -- "$CA" --help >/dev/null 2>&1
DBG=()
DBG_NOTE="нет флага отладки в --help"
if [ "$DEBUG" = 1 ]; then
  H="$D/.help.stdout"
  if grep -qE -- '--log-file' "$H"; then DBG=(--log-file "$D/debug.log"); DBG_NOTE="--log-file debug.log"
  elif grep -qE -- '--debug-log' "$H"; then DBG=(--debug-log "$D/debug.log"); DBG_NOTE="--debug-log debug.log"
  elif grep -qE -- '(^|[[:space:],])--debug([[:space:],]|$)' "$H"; then DBG=(--debug); DBG_NOTE="--debug (вывод в stderr)"
  elif grep -qE -- '(^|[[:space:],])--verbose([[:space:],]|$)' "$H"; then DBG=(--verbose); DBG_NOTE="--verbose (вывод в stderr)"
  fi
fi
rm -f "$D"/.help.*

# Контекст до запуска (без секретов)
{
  echo "date: $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
  echo "host: $(uname -sm), macOS $(sw_vers -productVersion 2>/dev/null || echo '-')"
  ks run --timeout 30 --out "$D/.ver" -- "$CA" --version >/dev/null 2>&1
  echo "cursor-agent: $(head -n 1 "$D/.ver.stdout" 2>/dev/null)"
  ks run --timeout 30 --out "$D/.st" -- "$CA" status >/dev/null 2>&1
  echo "login: $(ks login-state "$D/.st.stdout" "$D/.st.stderr")"
  echo "debug: $DBG_NOTE"
  echo "cwd: $CWD"
} > "$D/context.txt"
ks run --timeout 90 --out "$D/.lm" -- "$CA" --list-models >/dev/null 2>&1
cp "$D/.lm.stdout" "$D/models-before.txt" 2>/dev/null
rm -f "$D"/.ver.* "$D"/.st.* "$D"/.lm.*

MARK="$D/.marker"; touch "$MARK"; sleep 1
echo "Запуск: $CA ${EXTRA[*]+${EXTRA[*]}} ${DBG[*]+${DBG[*]}} $* (таймаут $TMO с) → $D"
ks run --timeout "$TMO" --line-times --cwd "$CWD" --out "$D/run" -- \
  "$CA" ${EXTRA[@]+"${EXTRA[@]}"} ${DBG[@]+"${DBG[@]}"} "$@"
RC=$?
mv "$D/run.stdout" "$D/stream.jsonl"; mv "$D/run.stderr" "$D/stderr.txt"; mv "$D/run.exit" "$D/exit_code"
mv "$D/run.meta.json" "$D/meta.json"; [ -f "$D/run.times.jsonl" ] && mv "$D/run.times.jsonl" "$D/times.jsonl"
rm -f "$D/run.secs"

ks run --timeout 90 --out "$D/.lm2" -- "$CA" --list-models >/dev/null 2>&1
cp "$D/.lm2.stdout" "$D/models-after.txt" 2>/dev/null; rm -f "$D"/.lm2.*
if cmp -s "$D/models-before.txt" "$D/models-after.txt"; then echo "models: каталог до/после одинаковый" >> "$D/context.txt"; else echo "models: каталог ИЗМЕНИЛСЯ за время запуска" >> "$D/context.txt"; fi

# Имена логов CLI, изменённых за время запуска (содержимое не копируем без явного согласия)
for d in "$HOME/.cursor" "$HOME/Library/Logs" "$HOME/Library/Application Support/cursor-agent" "$HOME/.local/share/cursor-agent" "$HOME/Library/Caches/cursor-agent"; do
  [ -d "$d" ] && find "$d" -maxdepth 4 -type f -newer "$MARK" \( -name '*.log' -o -name '*.log.*' -o -name '*.txt' -o -path '*log*' \) 2>/dev/null | grep -v '/chats/'
done > "$D/new-log-files.txt"
if [ "${KABAN_CAPTURE_COPY_LOGS:-0}" = 1 ] && [ -s "$D/new-log-files.txt" ]; then
  mkdir -p "$D/cli-logs"
  while IFS= read -r f; do cp "$f" "$D/cli-logs/$(echo "${f#"$HOME"/}" | tr '/ ' '__')" 2>/dev/null; done < "$D/new-log-files.txt"
fi
sed -i '' "s|^$HOME|~|" "$D/new-log-files.txt" 2>/dev/null || sed -i "s|^$HOME|~|" "$D/new-log-files.txt" 2>/dev/null
rm -f "$MARK"

ks sj "$D/stream.jsonl" --save "$D/summary.json" >/dev/null 2>&1
NH="$(ks grep-limits "$D" "$D/limit-hits.txt" --skip models-before.txt --skip models-after.txt)"
"$PY" - "$D" "$RC" "${NH:-0}" <<'PY' >> "$D/context.txt"
import json, os, sys
d, rc, nh = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = json.load(open(os.path.join(d, "summary.json")))
m = json.load(open(os.path.join(d, "meta.json")))
res, tools = s.get("result"), s["tool_calls"]["started"]
if m.get("timed_out"):
    hint = "timeout (завис до таймаута)"
elif res and not res.get("is_error"):
    hint = "success"
elif nh > 0:
    hint = "limit (есть совпадения лимитных шаблонов, см. limit-hits.txt)"
elif rc == 0 and not res and tools == 0:
    hint = "silent_exit (exit 0, ни result, ни tool_call)"
elif rc != 0 and not res:
    hint = "error_exit (exit != 0, без result)"
else:
    hint = "unknown"
tail = None
if m.get("last_stdout_ms") is not None:
    tail = m["duration_ms"] - m["last_stdout_ms"]
print("exit: %s, длительность: %s мс, строк stdout: %s, первая строка через: %s мс, тишина перед выходом: %s мс"
      % (rc, m.get("duration_ms"), m.get("stdout_lines"), m.get("first_stdout_ms"), tail))
print("init.model: %s, события: %s, tool_call: %s" % ((s.get("init") or {}).get("model"), s.get("event_kinds"), tools))
print("подсказка классификатору: " + hint)
PY
S="$(ks scrub "$D")"
echo "scrub: $S" >> "$D/context.txt"
echo
cat "$D/context.txt"
echo
echo "Фикстура: $D"
exit 0
