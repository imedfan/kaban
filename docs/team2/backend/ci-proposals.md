# T14 — предложения по CI

Дата 2026-10-04. Ветка `team2/backend-t14-ci`, baseline `1d647ea`. Только документ: `.github/workflows/ci.yml`, Package.swift и тесты не менялись. Уверенность высокая для структуры, средняя для выигрыша во времени: GitHub Actions ещё не измерялся. Существующий CI: Linux `ubuntu-latest` + `swift:6.0`, macOS `macos-latest` с `continue-on-error: true`; оба выполняют `swift build`, затем `swift test`, сценарии `Scenarios/M1`.

## Рекомендуемый порядок

1. Сначала concurrency и логирование toolchain; это не сокращает покрытие.
2. Затем cache `.build` с ключом полного compiler/OS/arch/manifest identity; измерить cold/hit/partial-hit.
3. Закрепить Linux patch+distribution tag и затем digest, выбранный владельцем. Swift.org публикует `6.0.3-jammy`: это воспроизводимый кандидат для сохранения Swift 6.0 compatibility, не утверждение, что это самая новая Swift. Для macOS закрепить runner image и Xcode/Swift pair после smoke на целевом Mac.
4. Убрать отдельный `swift build` после проверки, что `swift test` строит все нужные package targets. Альтернатива — `swift build --build-tests`, затем `swift test --skip-build`; после обычного `swift build` вариант `--skip-build` не гарантирует наличие test executable.
5. Сделать macOS обязательным до подключения production launchd/XPC/Seatbelt/Git runtime; оставлять Darwin-only tests optional на этапе реального daemon рискованно. Для pure Swift changes Linux остаётся быстрым обязательным сигналом; полный macOS suite должен быть обязательным при изменении platform/runtime boundary.

## Готовые YAML-фрагменты

На уровне workflow (PR branch update отменяет устаревший run; protected main push не прерывается):

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
permissions:
  contents: read
```

Кандидат Linux job сохраняет существующее имя required check:

```yaml
linux:
  name: Linux (Swift 6)
  runs-on: ubuntu-24.04
  container:
    image: swift:6.0.3-jammy
  timeout-minutes: 15
  env:
    KABAN_SCENARIOS: Scenarios/M1
  steps:
    - uses: actions/checkout@v4
    - name: Toolchain identity
      id: toolchain
      shell: bash
      run: |
        swift --version
        git --version
        compiler_hash=$(swift --version | sha256sum | cut -d ' ' -f 1)
        echo "hash=$compiler_hash" >> "$GITHUB_OUTPUT"
    - name: Swift build cache
      uses: actions/cache@v4
      with:
        path: .build
        key: kaban-build-v1-${{ runner.os }}-${{ runner.arch }}-jammy-${{ steps.toolchain.outputs.hash }}-${{ hashFiles('Package.swift', 'Package.resolved') }}-${{ github.sha }}
        restore-keys: |
          kaban-build-v1-${{ runner.os }}-${{ runner.arch }}-jammy-${{ steps.toolchain.outputs.hash }}-${{ hashFiles('Package.swift', 'Package.resolved') }}-
    - name: Build and test
      run: swift test
```

Tag надо заменить на официальный digest после отдельного smoke и записи выбранного digest в owned CI change; здесь digest не выдумывается. `Package.resolved` сейчас отсутствует: ключ всё равно включает существующий Package.swift; при добавлении dependencies появившийся lockfile меняет hash. Cache — ускорение: `swift test` выполняется и при cache hit, тесты не пропускаются. Restore prefix не пересекает compiler/OS/arch/distribution/manifest boundary. Смена SwiftPM build backend или SDK требует increment `v1`; macOS key дополнительно должен включать Xcode version/SDK fingerprint.

macOS обязательность — минимальный фрагмент для существующего job после стабилизации:

```yaml
macos:
  name: macOS (optional) # сначала сохранить имя, если на него ссылаются rulesets
  runs-on: macos-15
  continue-on-error: false
  timeout-minutes: 15
  env:
    KABAN_SCENARIOS: Scenarios/M1
  steps:
    - uses: actions/checkout@v4
    - name: Toolchain identity
      run: |
        xcodebuild -version
        swift --version
        git --version
    - name: Build and test
      run: swift test
```

Это pin OS runner, не pin Xcode. Выбрать конкретную установленную Xcode через DEVELOPER_DIR можно только после проверки официального image manifest и совместимости с production SDK; затем проверять `swift --version`/`xcodebuild -version` на ожидаемую пару. При принятии решения переименовать check в `macOS (Swift 6)` и обновить branch protection/ruleset names одним согласованным изменением. Не делать macOS условным skipped job для protected main до определения aggregation check: required check должен появляться на каждом PR.

## Ускорение без потери сигналов

- Измерить B2 seeded fuzz и реальные Git tests отдельно и в полном прогоне. Локальный B4 full suite: 211 XCTest методов (32 Protocol +133 Kit +46 Board), 0 failures, 1 known-issue skip #30; KabanKit ≈33с на этом Mac. Linux timing не экстраполировать.
- Не включать `--parallel` автоматически: real Git tests независимы по temporary HOME, но parallelism нужно подтвердить под Linux/macOS (CPU/process limit и peak RSS). Сначала benchmark; fail/timeout не маскировать retry.
- Не превращать skip в pass в отчёте: видеть количество skips и ссылки на issues. Проверять conditional skip исчезновение после source fix.
- Не кэшировать synthetic Git HOME/config/credentials и не класть личные config в CI. Git fixture isolation остаётся внутри тестов. Упомянутые `/private/tmp` cache paths относятся к локальной sandbox session, не обязательная настройка GitHub-hosted runner.
- При появлении сторонних deps отдельно кэшировать SwiftPM downloads, не использовать широкие restore-keys между compiler/architecture для object files. Сейчас внешних deps нет, измеримый эффект dependency cache маловероятен.

## Как принять change

Owned PR сначала запускает cold Linux/macOS suite, затем тот же commit с cache hit, затем новый небольшой commit с partial restore. Сравнить test counts, skip count, exit statuses, ресурсные fixtures и время. Cache miss/error не должен быть причиной пропуска suite. Никакой CI запуск или изменение ruleset в T14 не выполнены. Открыто: конкретный digest/toolchain pair, budget macOS job и владелец required-check names.

Источники (проверены 2026-10-04): [Swift.org Linux releases](https://www.swift.org/install/linux/ubuntu/22_04/), [GitHub concurrency](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency), [cache reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching), [official actions/cache](https://github.com/actions/cache). YAML предназначен для отдельного CI PR, существующий workflow не заменялся.
