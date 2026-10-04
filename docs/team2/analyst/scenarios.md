# AN3 — черновики сценариев для пробелов AN1

Дата 2026-10-04; baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
Источник: [spec v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view)
§1.3/1.4, UC-05/07/10/11/13 и
[архитектура v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view) §3.1/3.3.
Пробелы: [AN1 PR #26](https://github.com/imedfan/kaban/pull/26).
Формат — существующий `Scenarios/README.md`; исходные Scenarios не менялись.
Шесть новых JSON лежат только в `docs/team2/analyst/scenarios/`.

| ID | Ожидание из спеки | Прогноз для текущего Kit replay, без запуска |
|---|---|---|
| M1-T2-01 | requestChanges в readOnly ai_review → invalid_state без мутации | Pure machine поддерживает запрет; основной base pipeline fixture может отличаться, проверить при принятии |
| M1-T2-02 | reject.stage в readOnly ai_review → invalid_state | Аналогично, ожидаем поддержку в machine, не проверку UI списка целей |
| M1-T2-03 | reject.cancel из human review → cancelled, readOnly запрет не мешает | Machine поддерживает cancel; archive/clone removal не покрываются |
| M1-T2-04 | Нет writable agent → global no_return_target и defaultReturnStage nil | Replay остановится: validatePipeline handler/ephemeral относятся daemon; validator unit tests отдельно |
| M1-T2-05 | autoRuns=12, следующий tick → waiting_human:run_limit, runsStarted=0 | Pure start guard есть; runsStarted ещё не является oracle текущего Kit |
| M1-T2-06 | test_dev=3, следующий return → bounce_limit, stage/counter неизменны | Machine поддерживает pair boundary; feed qualifier не является Kit outcome |

Для M1-T2-04 content — настоящий YAML с explicit composer-2 и read-only,
а не словесная заглушка. Merge тоже может дать дополнительный no_return_target;
ожидание issues — подмножество, не обещание точного количества.
Nil default описан в note: существующий scenario decoder проверяет types,
но не умеет сверять resolved.defaultReturnStage. Нужен daemon acceptance oracle.

Тексты ленты для run_limit/returns_to сохранены в note M1-T2-05/06:
«Лимит запусков на задачу · 12 из 12» и
«Лимит возвратов · Test → Dev, 3 из 3».
Generic FeedItem не имеет typed reason-text formatter и сценарного feed oracle;
не добавляли выдуманный формат then.feed. Поэтому эти две **UI проверки ещё
не исполняются**; Frontend должен связать будущий formatter с данными сценария.
Другие варианты (non-agent target, explicit invalid returns_to, human reset)
остались вне шести drafts; соответствующие unit tests уже есть в ReturnRulesTests.

Проверка декодирования (выполнена, 1 тест, 0 failures/skips):

```sh
KABAN_SCENARIOS=docs/team2/analyst/scenarios swift test --filter ScenarioDecodeCheck
```

Каждый JSON имеет уникальный id, uc, title, note. Команды/состояния/ephemeral
payloads декодируются существующим KabanProtocol. Decode check не валидирует
YAML, ожидаемые переходы или тексты; replay drafts по правилам AN3 не запускался.
Дизайнерские задачи исключены. Новый production/test код не добавлен.
