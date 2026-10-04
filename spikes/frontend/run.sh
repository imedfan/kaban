#!/bin/bash
# Генерирует KabanSpikes.xcodeproj и собирает спайки. macOS + Xcode 26.
# Bash 3.2 (то, что стоит в /bin/bash на macOS).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

MODE="build"
DEVELOPER_ID=0

usage() {
  echo "Использование: ./run.sh [--generate-only | --open | --developer-id]"
  echo "  DEVELOPMENT_TEAM=XXXXXXXXXX ./run.sh"
  echo "  DEVELOPMENT_TEAM=XXXXXXXXXX CODE_SIGN_IDENTITY='Developer ID Application: …' ./run.sh --developer-id"
}

for arg in "$@"; do
  case "$arg" in
    --generate-only) MODE="generate" ;;
    --open) MODE="open" ;;
    --developer-id) DEVELOPER_ID=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Неизвестный аргумент: $arg"
      usage
      exit 2
      ;;
  esac
done

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Нет xcodebuild. Нужен полный Xcode 26, не только Command Line Tools."
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

XCODE_OUT="$(xcodebuild -version)"
XCODE_LINE="${XCODE_OUT%%$'\n'*}"
echo "$XCODE_LINE"
case "$XCODE_LINE" in
  "Xcode 26"*) ;;
  *) echo "Предупреждение: ожидается Xcode 26. glassEffect / GlassEffectContainer есть только в этом SDK." ;;
esac

if [[ "$MODE" != "open" ]]; then
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "Задайте DEVELOPMENT_TEAM — 10 символов Team ID."
    echo "  Xcode → Settings → Accounts, или хвост строки:"
    echo "  security find-identity -v -p codesigning"
    echo "  export DEVELOPMENT_TEAM=XXXXXXXXXX"
    exit 1
  fi
fi

if [[ "$DEVELOPER_ID" -eq 1 && -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "Для --developer-id задайте CODE_SIGN_IDENTITY, например:"
  echo "  export CODE_SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'"
  echo "Если Мака нет в сети, timestamp подписи может не пройти. Тогда пропустите этот прогон и запишите это в RESULTS.md."
  exit 1
fi

if [[ "$MODE" == "open" ]]; then
  APP="$(ls -d "$ROOT"/build/DerivedData/Build/Products/*/KabanSpikes.app 2>/dev/null | head -n 1 || true)"
  if [[ -z "${APP}" || ! -d "${APP}" ]]; then
    echo "Собранного .app ещё нет. Сначала ./run.sh"
    exit 1
  fi
  echo "Открываю $APP"
  open "$APP"
  exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Нет xcodegen. Пока Мак в сети: brew install xcodegen"
  exit 1
fi
echo "XcodeGen $(xcodegen --version)"

mkdir -p "$ROOT/Config" "$ROOT/build" "$ROOT/results"

if [[ "$DEVELOPER_ID" -eq 1 ]]; then
  CONFIG="Release"
  cat > "$ROOT/Config/Signing.xcconfig" <<EOF
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = ${CODE_SIGN_IDENTITY}
EOF
  echo "Подпись: Developer ID (Manual). Не проверено в этой среде, что такой набор флагов проходит нотаризацию."
else
  CONFIG="Debug"
  cat > "$ROOT/Config/Signing.xcconfig" <<EOF
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}
CODE_SIGN_STYLE = Automatic
EOF
fi

echo "Проверка точечной правки YAML (swiftc)…"
xcrun swiftc -parse-as-library -D SPIKE_YAML_MAIN \
  -o "$ROOT/build/yaml-self-check" \
  "$ROOT/Shared/PipelineYamlEditor.swift"
"$ROOT/build/yaml-self-check" "$ROOT/Resources/pipeline.yaml"

echo "Генерация проекта…"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
if [[ "$MODE" == "generate" ]]; then
  echo "Проект: $ROOT/KabanSpikes.xcodeproj"
  echo "Сборка не запускалась (--generate-only)."
  exit 0
fi

echo "Сборка ($CONFIG)…"
xcodebuild \
  -project "$ROOT/KabanSpikes.xcodeproj" \
  -scheme KabanSpikes \
  -configuration "$CONFIG" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  build

APP="$ROOT/build/DerivedData/Build/Products/$CONFIG/KabanSpikes.app"
if [[ ! -d "$APP" ]]; then
  echo "Не найден $APP"
  find "$ROOT/build/DerivedData/Build/Products" -name '*.app' -maxdepth 3 || true
  exit 1
fi

ok=1
if [[ ! -x "$APP/Contents/MacOS/KabanSpikeAgent" ]]; then
  echo "В бандле нет Contents/MacOS/KabanSpikeAgent."
  find "$APP" -name 'KabanSpikeAgent' || true
  ok=0
fi
if [[ ! -f "$APP/Contents/Library/LaunchAgents/app.kaban.spikes.agent.plist" ]]; then
  echo "В бандле нет Contents/Library/LaunchAgents/app.kaban.spikes.agent.plist."
  echo "Если plist лежит глубже (Contents/Contents/…), в project.yml замените subpath на Library/LaunchAgents и снова ./run.sh."
  find "$APP" -name '*.plist' || true
  ok=0
fi
if [[ "$ok" -ne 1 ]]; then
  exit 1
fi

echo "---- подпись приложения ----"
codesign -dv "$APP" 2>&1 | head -n 20 || true
echo "---- подпись агента ----"
codesign -dv "$APP/Contents/MacOS/KabanSpikeAgent" 2>&1 | head -n 20 || true

echo ""
echo "Собрано: $APP"
echo "FS-1 и FS-7 запускайте из стабильного пути, не из DerivedData:"
echo "  mkdir -p \"\$HOME/Applications\""
echo "  ditto \"$APP\" \"\$HOME/Applications/KabanSpikes.app\""
echo "  open \"\$HOME/Applications/KabanSpikes.app\""
echo "Остальные спайки можно открыть и собранной копией:"
echo "  open \"$APP\""
echo "Журнал сессии: \$HOME/Library/Logs/KabanSpikes/session.log"
echo "Шаблон отчёта: $ROOT/RESULTS.md"
echo "Скриншоты и копии логов кладите в: $ROOT/results/"
echo "В приложении слева список FS-1 … FS-9."
