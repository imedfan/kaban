#!/usr/bin/env bash
# Общие функции для спайков бэка Kaban. Запускать на macOS (mbp).
#
# Совместимо с /bin/bash 3.2 (штатный bash macOS): без mapfile, ассоциативных
# массивов и ${x,,}; пустые массивы раскрываются через ${a[@]+"${a[@]}"}.
# В macOS нет `timeout`, поэтому все запуски с таймаутом идут через
# lib/kspike.py run (своя группа процессов, SIGTERM -> SIGKILL всей группе).
#
# Правила безопасности (для всех спайков):
#  - токены, секреты и значения из БД не печатаются и не сохраняются;
#  - всё временное — в mktemp-каталогах и ./out, временные каталоги чистятся;
#  - реальные репозитории, ~/.cursor, ~/.gitconfig и файлы Cursor IDE не меняются;
#  - перед завершением ./out прогоняется через scrub (маскирование токенов/почты).
#
# Перед подключением задать SPIKE_NAME. Переменные окружения:
#   KABAN_SPIKE_MODEL   — id дешёвой модели из `cursor-agent --list-models` (обязательно)
#   KABAN_CURSOR_AGENT  — путь к cursor-agent (иначе ищем cursor-agent / agent в PATH;
#                         CURSOR_AGENT учитывается, только если это путь к файлу)
#   KABAN_SPIKE_TIMEOUT — таймаут одного запуска агента, сек (по умолчанию 240)
#   KABAN_SPIKE_TRUST   — auto|1|0: добавлять ли --trust (auto: если флаг есть в --help)
#   OUT_ROOT            — куда класть out (по умолчанию spikes/backend/out)

set -u
SPIKE_NAME="${SPIKE_NAME:-spike}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SPIKES_DIR="$(cd "$LIB_DIR/.." && pwd -P)"
OUT_ROOT="${OUT_ROOT:-$SPIKES_DIR/out}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_ROOT/$SPIKE_NAME-$TS"
mkdir -p "$OUT"
SUMMARY="$OUT/SUMMARY.md"
: > "$SUMMARY"
echo "# $SPIKE_NAME — $(date '+%Y-%m-%d %H:%M %Z')" >> "$SUMMARY"
echo "" >> "$SUMMARY"
printf '%s\n' "$OUT" > "$OUT_ROOT/.last-$SPIKE_NAME"
# Отметка времени старта (для find -newer: что CLI поменял за время спайка)
START_MARK="$OUT/.start-marker"; : > "$START_MARK"

PY="${KABAN_PY:-$(command -v python3 || true)}"
KSPIKE="$LIB_DIR/kspike.py"
# Путь к CLI: KABAN_CURSOR_AGENT, иначе CURSOR_AGENT — но только если это исполняемый файл
# (в терминалах Cursor/агента CURSOR_AGENT=1 — это флаг, а не путь), иначе ищем в PATH.
resolve_ca() {
  if [ -n "${KABAN_CURSOR_AGENT:-}" ]; then echo "$KABAN_CURSOR_AGENT"; return; fi
  case "${CURSOR_AGENT:-}" in */*) [ -x "$CURSOR_AGENT" ] && { echo "$CURSOR_AGENT"; return; };; esac
  command -v cursor-agent || command -v agent || true
}
CA="$(resolve_ca)"
MODEL="${KABAN_SPIKE_MODEL:-}"
AGENT_TIMEOUT="${KABAN_SPIKE_TIMEOUT:-240}"
TRUST_ARG=""

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { echo "- ✅ $*" | tee -a "$SUMMARY"; }
fail() { echo "- ❌ $*" | tee -a "$SUMMARY"; }
info() { echo "- ℹ️ $*" | tee -a "$SUMMARY"; }
manual() { echo "- 👀 проверить вручную: $*" | tee -a "$SUMMARY"; }
section() { echo "" >> "$SUMMARY"; echo "## $*" >> "$SUMMARY"; log "$*"; }
# check COND_EXIT_CODE "текст при успехе" "текст при провале"
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$3"; fi; }

ks() { "$PY" "$KSPIKE" "$@"; }

# ---------------------------------------------------------------- очистка
# Реестр временных каталогов — файл, т.к. mktmp часто зовут внутри $(...) (подоболочка).
TMP_REGISTRY="$(mktemp "/tmp/kaban-spike-registry.XXXXXX")"
CLEANUP_CMDS=()
add_tmp() { printf '%s\n' "$1" >> "$TMP_REGISTRY"; }
# on_exit "команда" — выполнить при выходе (звать только из основного процесса скрипта)
on_exit() { CLEANUP_CMDS+=("$1"); }

# Удаляем только то, что явно похоже на наши временные каталоги.
safe_rm() {
  local p="$1"
  case "$p" in
    /tmp/kaban-spike*|/private/tmp/kaban-spike*|/var/folders/*/kaban-spike*|/private/var/folders/*/kaban-spike*|"$HOME"/.kaban-spike*)
      chmod -R u+w "$p" 2>/dev/null; rm -rf "$p" ;;
    *) echo "safe_rm: пропускаю подозрительный путь: $p" >&2 ;;
  esac
}

_cleanup() {
  local c d i
  # команды выхода — в обратном порядке (сначала то, что запущено последним)
  i=${#CLEANUP_CMDS[@]}
  while [ "$i" -gt 0 ]; do i=$((i - 1)); c="${CLEANUP_CMDS[$i]}"; eval "$c" >/dev/null 2>&1 || true; done
  if [ "${KABAN_SPIKE_KEEP_TMP:-0}" = 1 ]; then
    echo "KABAN_SPIKE_KEEP_TMP=1: временные каталоги оставлены, список: $TMP_REGISTRY"
    return
  fi
  if [ -f "$TMP_REGISTRY" ]; then
    while IFS= read -r d; do [ -n "$d" ] && [ -e "$d" ] && safe_rm "$d"; done < "$TMP_REGISTRY"
    rm -f "$TMP_REGISTRY"
  fi
}
trap _cleanup EXIT
trap 'echo "прервано"; exit 130' INT TERM

# mktmp SUFFIX — временный каталог /tmp/kaban-spike-<suffix>.XXXXXX (реальный путь, /private/tmp)
mktmp() {
  local d; d="$(mktemp -d "/tmp/kaban-spike-${1:-tmp}.XXXXXX")" || exit 3
  d="$(cd "$d" && pwd -P)"
  add_tmp "$d"; echo "$d"
}

# ---------------------------------------------------------------- проверки окружения
# KABAN_SPIKE_SELFTEST=1 — только для разработчика скриптов: прогон логики на Linux с фейковым
# агентом (KABAN_CURSOR_AGENT=<фейк>); macOS-проверки не валят скрипт. На Маке не использовать.
SELFTEST="${KABAN_SPIKE_SELFTEST:-0}"
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  [ "$SELFTEST" = 1 ] && { echo "SELFTEST: нет $1, продолжаем"; return 0; }
  echo "нужен $1"; exit 2
}

require_macos() {
  [ "$(uname)" = "Darwin" ] && return 0
  [ "$SELFTEST" = 1 ] && { echo "SELFTEST: не macOS, проверяем только логику скрипта"; return 0; }
  echo "Спайк запускается только на macOS"; exit 2
}

require_python() {
  [ -n "$PY" ] || { echo "нужен python3 (Xcode Command Line Tools: xcode-select --install)"; exit 2; }
  "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null \
    || { echo "нужен python3 >= 3.8"; exit 2; }
}

require_agent() {
  require_python
  [ -n "$CA" ] || { echo "cursor-agent не найден в PATH (или задай KABAN_CURSOR_AGENT=путь)"; exit 2; }
  [ -x "$CA" ] || { echo "cursor-agent: $CA не исполняемый"; exit 2; }
  [ -n "$MODEL" ] || { echo "Задай дешёвую модель: KABAN_SPIKE_MODEL=<id из cursor-agent --list-models>"; exit 2; }
  case "$MODEL" in auto|Auto|AUTO) echo "KABAN_SPIKE_MODEL=auto запрещён (Auto в Kaban запрещён), укажи явную модель"; exit 2;; esac
  # Абсолютный путь (LaunchAgent и sandbox-exec не знают PATH)
  case "$CA" in /*) ;; *) CA="$(cd "$(dirname "$CA")" && pwd -P)/$(basename "$CA")";; esac
  detect_trust
}

# --trust: «Trust the workspace without prompting (headless mode only)».
detect_trust() {
  local mode="${KABAN_SPIKE_TRUST:-auto}"
  TRUST_ARG=""
  case "$mode" in
    1|yes) TRUST_ARG="--trust" ;;
    0|no) TRUST_ARG="" ;;
    *)
      # Если спайк 1 в этом же прогоне выяснил, нужен ли --trust, берём его вывод.
      if [ -f "$OUT_ROOT/.trust-needed" ]; then
        [ "$(cat "$OUT_ROOT/.trust-needed")" = 1 ] && TRUST_ARG="--trust"
        return
      fi
      local h; h="$(mktemp "/tmp/kaban-spike-help.XXXXXX")"
      ks run --timeout 30 --out "$h" -- "$CA" --help >/dev/null 2>&1
      if grep -q -- '--trust' "$h.stdout" "$h.stderr" 2>/dev/null; then TRUST_ARG="--trust"; fi
      rm -f "$h" "$h".* ;;
  esac
}

# ---------------------------------------------------------------- запуски
# run_cap NAME CMD... — команда с таймаутом по умолчанию 120 с; $OUT/NAME.{stdout,stderr,exit,secs,meta.json}
run_cap() { local name="$1"; shift; run_cap_timeout 120 "$name" "$@"; }

# run_cap_timeout SECS NAME CMD... — то же с явным таймаутом (124 = таймаут)
run_cap_timeout() {
  local secs="$1" name="$2"; shift 2
  ks run --timeout "$secs" --out "$OUT/$name" -- "$@"
}

# arun NAME DIR [VAR=VAL ...] -- ARGS... — запуск cursor-agent в DIR с env-переменными.
#   Префикс env пишется в meta.json с маскированием значений *TOKEN*/*KEY*.
#   Переменная AGENT_PREFIX (строка) — обёртка перед CA, например "sandbox-exec -f prof.sb".
arun() {
  local name="$1" dir="$2"; shift 2
  local envs; envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  local pre; pre=()
  if [ -n "${AGENT_PREFIX:-}" ]; then
    # shellcheck disable=SC2206
    pre=($AGENT_PREFIX)
  fi
  # --trust добавляем только к headless-запускам (-p), не к подкомандам status/mcp
  local ta; ta=()
  if [ -n "$TRUST_ARG" ] && [ "${ARUN_NO_TRUST:-0}" != 1 ]; then
    local x; for x in "$@"; do case "$x" in -p|--print) ta=("$TRUST_ARG"); break;; esac; done
  fi
  ks run --timeout "${ARUN_TIMEOUT:-$AGENT_TIMEOUT}" --line-times --cwd "$dir" --out "$OUT/$name" -- \
    env ${envs[@]+"${envs[@]}"} ${pre[@]+"${pre[@]}"} "$CA" ${ta[@]+"${ta[@]}"} "$@"
}

# run_in DIR SECS NAME CMD... — как run_cap_timeout, но с рабочим каталогом DIR
run_in() {
  local dir="$1" secs="$2" name="$3"; shift 3
  ks run --timeout "$secs" --cwd "$dir" --out "$OUT/$name" -- "$@"
}

# save_fixture FIXNAME RUNNAME — копия запуска как фикстуры фейкового драйвера в $OUT/fixtures/FIXNAME
save_fixture() {
  local d="$OUT/fixtures/$1" r="$OUT/$2"
  mkdir -p "$d"
  cp "$r.stdout" "$d/stream.jsonl" 2>/dev/null
  cp "$r.stderr" "$d/stderr.txt" 2>/dev/null
  cp "$r.exit" "$d/exit_code" 2>/dev/null
  cp "$r.meta.json" "$d/meta.json" 2>/dev/null
  [ -f "$r.times.jsonl" ] && cp "$r.times.jsonl" "$d/times.jsonl"
  return 0
}

rc_of() { cat "$OUT/$1.exit" 2>/dev/null || echo "?"; }
secs_of() { cat "$OUT/$1.secs" 2>/dev/null || echo "?"; }
first_line() { strip_ansi_file "$1" | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-200; }
strip_ansi_file() { [ -f "$1" ] && "$PY" -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8",errors="replace").read(); sys.stdout.write(re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\r","",t))' "$1"; }

# ---------------------------------------------------------------- git
# Свой git без глобального конфига Артёма (подпись, хуки) — только для наших временных репо.
g() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git \
    -c user.name=kaban-spike -c user.email=kaban-spike@local \
    -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null \
    -c init.defaultBranch=main "$@"
}

# Временный git-репозиторий для запусков; печатает реальный путь.
make_repo() {
  local d; d="$(mktmp "${1:-repo}")"
  ( cd "$d" && g init -q -b main && printf '# kaban spike\n' > README.md && g add . && g commit -qm init ) >/dev/null 2>&1
  echo "$d"
}

# ---------------------------------------------------------------- stream-json
sj_get() { ks sj "$1" --get "$2" 2>/dev/null; }
init_model() { sj_get "$1" init.model; }
session_id() { local s; s="$(sj_get "$1" init.session_id)"; [ -n "$s" ] || s="$(sj_get "$1" result.session_id)"; echo "$s"; }
has_result() { [ -n "$(sj_get "$1" result.subtype)" ] || [ "$(sj_get "$1" result.is_error)" != "" ]; }
tool_calls() { local n; n="$(sj_get "$1" tool_calls.started)"; echo "${n:-0}"; }

# Сводка stream-json одного запуска: $OUT/NAME.summary.json + строка в SUMMARY
summarize_run() {
  local name="$1" f="$OUT/$1.stdout"
  ks sj "$f" --save "$OUT/$name.summary.json" >/dev/null 2>&1
  info "\`$name\`: exit=$(rc_of "$name"), ${2:-}время=$(secs_of "$name") с, init.model=\"$(init_model "$f")\", session_id=$( [ -n "$(session_id "$f")" ] && echo есть || echo нет ), result=$(sj_get "$f" result.subtype || true), tool_call=$(tool_calls "$f")"
}

# ---------------------------------------------------------------- финал
finish() {
  local n
  n="$(ks grep-limits "$OUT" "$OUT/limit-hits.txt" 2>/dev/null || echo "?")"
  section "Лимитные сообщения (grep по всему выводу)"
  if [ "$n" = "0" ]; then info "совпадений нет (\`limit-hits.txt\` пуст)"; else info "совпадений: $n — см. \`limit-hits.txt\`"; fi
  echo "" >> "$SUMMARY"
  echo "Сырой вывод: \`$OUT\`" >> "$SUMMARY"
  local s; s="$(ks scrub "$OUT" ${SCRUB_ENV:+--secret-env "$SCRUB_ENV"} 2>/dev/null || true)"
  echo "Маскирование вывода (scrub): \`$s\`" >> "$SUMMARY"
  log "Готово. Сводка: $SUMMARY"
  cat "$SUMMARY"
}
