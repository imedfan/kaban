#!/usr/bin/env bash
# Прогон спайков бэка Kaban 1 → 2 → 6 и сводный отчёт.
#   KABAN_SPIKE_MODEL=<id дешёвой модели> ./run-all.sh
# Необязательно: KABAN_SPIKE_REPO=~/path/to/repo (замеры клона в спайке 6, только чтение),
#                KABAN_SPIKE_WARM=node_modules,.build   KABAN_SPIKE_ONLY="1 6" (выборочно).
# Итог: out/REPORT-<время>.md и out/kaban-spikes-<время>.zip (его и прислать).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
OUT_ROOT="${OUT_ROOT:-$HERE/out}"; export OUT_ROOT
mkdir -p "$OUT_ROOT"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_ROOT/REPORT-$TS.md"
ONLY="${KABAN_SPIKE_ONLY:-1 2 6}"

[ "$(uname)" = "Darwin" ] || { echo "Только macOS"; exit 2; }
[ -n "${KABAN_SPIKE_MODEL:-}" ] || {
  echo "Задай дешёвую модель: KABAN_SPIKE_MODEL=<id>. Список: cursor-agent --list-models"; exit 2; }
command -v python3 >/dev/null || { echo "нужен python3: xcode-select --install"; exit 2; }

rm -f "$OUT_ROOT/.trust-needed"   # спайк 1 выяснит заново, нужен ли --trust
T0=$(date +%s)
declare_rc() { eval "RC_$1=$2"; }
for n in $ONLY; do
  case "$n" in
    1) s=spike1-cursor-agent ;;
    2) s=spike2-mcp ;;
    6) s=spike6-seatbelt ;;
    *) echo "неизвестный спайк $n"; continue ;;
  esac
  echo; echo "################ $s ################"
  t=$(date +%s)
  "$HERE/$s.sh"
  declare_rc "$n" "$?"
  echo "$s: $(( $(date +%s) - t )) с"
done

{
  echo "# Kaban: спайки бэка — сводный отчёт"
  echo
  echo "- Дата: $(date '+%Y-%m-%d %H:%M %Z'), Мак: $(scutil --get ComputerName 2>/dev/null || hostname -s), macOS $(sw_vers -productVersion), $(uname -m)"
  CA="${KABAN_CURSOR_AGENT:-$(command -v cursor-agent || command -v agent || echo '?')}"
  echo "- cursor-agent: $("$CA" --version 2>/dev/null | head -n 1), модель спайков: \`$KABAN_SPIKE_MODEL\`"
  echo "- Длительность: $(( ($(date +%s) - T0) / 60 )) мин"
  echo "- Легенда: ✅ проверка прошла, ❌ не прошла (это тоже ответ), ℹ️ факт для архитектуры, 👀 нужен ответ человека"
  echo
  for n in $ONLY; do
    case "$n" in 1) s=spike1-cursor-agent;; 2) s=spike2-mcp;; 6) s=spike6-seatbelt;; *) continue;; esac
    d="$(cat "$OUT_ROOT/.last-$s" 2>/dev/null)"
    eval "rc=\${RC_$n:-?}"
    echo
    if [ -n "$d" ] && [ -f "$d/SUMMARY.md" ]; then
      sed '1s/^# /## /; 2,$s/^## /### /' "$d/SUMMARY.md"
      echo
      echo "_(код выхода скрипта: $rc, каталог: \`$(basename "$d")\`)_"
    else
      echo "## $s — нет SUMMARY.md (код выхода $rc)"
    fi
  done
  echo
  echo "## Ответы человека (👀)"
  echo
  echo "Допиши ответы на строки 👀 выше прямо в этот файл перед отправкой."
} > "$REPORT"

# Финальное маскирование всего out/ (повторно — на случай ручных фикстур capture-run)
python3 "$HERE/lib/kspike.py" scrub "$OUT_ROOT" >/dev/null 2>&1
ZIP="$OUT_ROOT/kaban-spikes-$TS.zip"
if command -v zip >/dev/null 2>&1; then
  ( cd "$OUT_ROOT" && zip -qr "$(basename "$ZIP")" . -x '*.zip' -x '.last-*' -x '.trust-needed' -x '*/.start-marker' )
else
  ZIP="$OUT_ROOT/kaban-spikes-$TS.tar.gz"
  ( cd "$OUT_ROOT" && tar --exclude='*.zip' --exclude='*.tar.gz' -czf "$(basename "$ZIP")" . )
fi
echo
echo "Отчёт: $REPORT"
echo "Архив для отправки: $ZIP ($(du -h "$ZIP" | cut -f1))"
