# BE-04: полный планировщик и цикл демона

Дата: 5 октября 2026. Ветка `codex/backend-full-scheduler`, база после fetch —
`origin/main` `bc9abc9` (BE-03, PR #73 принят). Реализация —
[PR #74](https://github.com/imedfan/kaban/pull/74), открыт в main.
Очередь — [backend MVP](backend-mvp-tasks.md).

## Реализовано

Production-проекты участвуют в том же durable scheduler, что и managed fixtures.
Все допустимые stage kinds поддержаны; строгий общий validator не изменён.
Downstream определяется графом `on_success`, включая обратный порядок стадий
в YAML. Внутри стадии — её priority rules returned/answered/FIFO, затем card
priority и durable queue seq. Неготовый кандидат не удерживает очередь.
Сохранённый weighted cursor переживает reopen, учитываются личные agent ceilings.

Один tick выбирает один start/admission; projection, journal, RunSpec, outbox,
cursor и receipt коммитятся одной транзакцией. SQLite сериализует разные store
connections. Повтор tick token возвращает исходный receipt до сверки времени,
cooldown или генерации ID. До 32 изменившихся quota/model labels могут быть
записаны за tick; неизменные labels не создают journal/receipt churn.

Agent `.running` — reservation глобального/проектного слота. Gate/merge занимают
execution WIP; merge имеет лимит один и project mergeBlocked останавливает новую
попытку. Human review занимает explicit admission до stage exit/final, включая
pause/reopen. Уменьшение WIP и agent ceilings не вытесняет уже занятое; retry не
списывает своё место повторно. Review исключён из waiting_human intake, остальные
причины учитываются во всех kinds. Human/gate/merge/terminal не расходуют agent slot.

Host после recovery запускает `DaemonScheduler`: serial coalesced wake от wire
command и project observer плюс секундный timer. Pass ограничен восемью ticks;
idle wakes не накапливают строки tick. Backoff/cooldown проверяется по времени,
внутри transaction нет ожиданий. Shutdown ждёт текущий pass до освобождения
эксклюзивной lease БД. CLI и XPC входят через прежний DaemonService.

Production task-control, answers и Human Review используют существующие wire
DTO/автомат и объявлены supported. Invalid main блокирует новые starts и явно
отклоняет human stage exit; завершённый run сохраняет deferred exit BE-03.
Gate/merge attempts также получают immutable RunSpec и run ID в pending effect.
`deliverFake` продолжает отклонять production effects.

## Авторитетные runtime-факты

Additive migration v6 создаёт `scheduler_inputs`. Internal API принимает полный
набор runtime flags, model flags, model pool rules, quota sample и usage estimate
от будущих producers. Ручные паузы/intake остаются вычисляемыми факторами store;
API не позволяет подменить их. Snapshot возвращает сохранённые факты; service
коммитит journal до live model/quota delivery и wake. Сброс quota к nil очищает
retained sample и требует replacement, сохраняя unknown вместо старого значения.

Runner/rate/usage flags ограничивают agent launches и intake по первой agent
модели; gate/human/merge могут продолжать без Cursor. Flags с известным deadline
снимаются транзакционно; unknown reset не снимается произвольно. Model flag
останавливает только свою модель, pool exhaustion — только свой пул. Retry,
упершийся в quota/model, освобождает execution WIP и сохраняет контекст.

При включённой quota option используются явные model pool rules и sample не
старше 60 с: остаток минус reserve на текущие runs должен превышать threshold.
Reserve без истории — заданные требованиями 2% на run, при наличии используется
переданный estimate. Nil/stale percentage не превращается в ноль; работают
reactive flags. Реального запроса свежей квоты этот инкремент не делает — producer
и refresh-before-start принадлежат BE-11.

## Проверки

- FullPipelineSchedulerTests: production flow, frozen agent/gate/merge specs,
  отказ fake delivery, ceiling=3 и concurrent connections, personal caps,
  independent gate/human/merge capacity, pause/reopen/shrink, retry clock,
  model/pool/usage limits, unknown/stale quota, priority/FIFO, weighted fairness,
  arbitrary YAML order, invalid main, intent reservation, bounded labels,
  rollback receipt/spec/outbox/cursor и настоящий timer/wake.
- SessionContractTests: persisted producer facts, journal barrier/live delivery,
  replacement после clearing quota; nearby wire/managed/project regression suites.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 394 tests, 0 failures,
  включая 16 FullPipelineSchedulerTests; build и затронутые transport suites прошли.
- Linux Swift 6.1.3: `swift build`, полный прогон — 392 tests, 0 failures и process smoke.
- Process smoke настоящего host: автоматические три starts, четвёртая queued,
  pause/ceiling shrink сохраняют live reservations, RunSpec/outbox сохранены,
  HEAD/dirty checkout не меняются; прежние lifecycle/transport проверки сохранены.
- `tools/check-project-context.py`: working documents, links, 172 design originals,
  28 reference PNGs и 18 Drive originals проверены; `git diff --check` прошёл.

## Границы

Pending effects ещё не исполняются внешним executor. `.running` доказывает durable
reservation и создание эффекта, не живой процесс Cursor. Gate/merge flow проверен
invocation fixtures; subprocess smoke не запускает платные CLI или shell gates.
Claim/lease/fencing, реальные clones/processes/gates/merge и environment/catalog/
quota producers следуют в BE-05–11. Process reconciliation до kill/pgid ещё не
реализован. App остаётся на MockKabanClient; SwiftUI и визуальная приёмка здесь не
менялись. LaunchAgent registration/подпись и полный M1/MVP не заявляются готовыми.
