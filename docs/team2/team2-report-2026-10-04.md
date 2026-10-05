# Team2 — отчёт 2026-10-04

Сессия выполнена от базы `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64` (`main`).
План по ролям: [work-plan-2026-10-04.md](work-plan-2026-10-04.md).
Координатор выполнял Analyst и интеграционную проверку; Backend, Architect/security
и Frontend работали параллельно. Субагенты: `gpt-6.1-sol`, reasoning `medium`.

## 0. Резюме для основной команды (5 строк)

1. Что сделано: 31 PR с исследованиями, тестами, аудитами, примерами и инструментами; Linux и macOS CI зелёные на SHA из таблицы; план и этот отчёт передаются отдельным PR.
2. Что главное узнали: совместно проходят 242 теста без ошибок; пять новых regression-проверок условно пропущены по issues; существенные пробелы есть в git-фильтре, identity, автомате и протоколе.
3. Что нужно от Артёма/команды: разобрать issues, принять решения по неоднозначностям спеки, провести целевые macOS 26 спайки; указать адреса/группу для чтения документов Drive.
4. Риски: зелёные тесты не доказывают завершение M1, работу headless под launchd или производственную изоляцию; фактический Mac — macOS 27 / Xcode 27.
5. Что дальше: основная команда проверяет и мержит выбранные PR, исправляет находки и повторяет условно пропущенные проверки; дизайнерские работы не берём и не будем брать.

## 1. PR

Ни один PR не смержен второй командой. Все ветки `team2/…`, база PR — `main`.
В таблице записаны полные последние SHA, а ссылки CI ведут на реальные jobs этих SHA.
Собственный SHA PR с этим отчётом следует брать из GitHub HEAD: включение его в файл
изменило бы сам SHA. Таблица ниже относится к 31 PR с результатами задач.

| Задача | PR (ссылка) | Ветка | Последний sha | Что сделано | Тесты/проверки | CI |
|---|---|---|---|---|---|---|
| T1 / B5 | [#15](https://github.com/imedfan/kaban/pull/15) | `team2/research-cursor-cli` | `019a33379430ced0258dcf5a4f0e37e5a4c9553a` | Headless CLI: runbook, ошибки, resume и отмена | 4 ограниченных CLI-пробы; shell-синтаксис; без запросов модели | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187540617/job/111392586491); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187540617/job/111392586547) |
| T2 | [#16](https://github.com/imedfan/kaban/pull/16) | `team2/research-mcp-isolation` | `8cd19d299b5ee8c84284f4acdbbaff1a580edf21` | Три варианта MCP-изоляции и протокол проверки | Синтаксис shell/Python; живое MCP-discovery остаётся спайку | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187540278/job/111392585829); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187540278/job/111392585773) |
| T3 | [#17](https://github.com/imedfan/kaban/pull/17) | `team2/research-seatbelt` | `ae11bbbfef06e843af0a16ccd751a6959a508aa7` | Seatbelt: защищённые пути, deny-кандидат и runbook | Синтетические write/unlink/rename/symlink-пробы на macOS 27 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187540275/job/111392585752); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187540275/job/111392585611) |
| AN4 / T8 | [#18](https://github.com/imedfan/kaban/pull/18) | `team2/analyst-an4-spec-review` | `39a860bc2a778fbfb106fab5c0e40f3d36e2e535` | Спека и все 37 ValidationCode | 37 кодов сверены; вопросы #9–11 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187540468/job/111392586169); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187540468/job/111392586067) |
| B2 | [#19](https://github.com/imedfan/kaban/pull/19) | `team2/backend-b2-fuzz` | `2eb0a1e861d7a85d6c5792f3789327d418996614` | Детерминированный fuzz MiniYAML/Validator | 8 новых тестов; 15 000 входов; Linux полный прогон 24,728 с | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187872778/job/111393603329); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187872778/job/111393603166) |
| A1 / T8 | [#20](https://github.com/imedfan/kaban/pull/20) | `team2/architect-a1-audit` | `e30d59157ae7857463d5f44e1c746c10aa9df4c1` | Аудит протокола и границ реализации | Все публичные семейства; 46 команд; issue #14 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187872533/job/111393602378); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187872533/job/111393602529) |
| A5 / T10 | [#21](https://github.com/imedfan/kaban/pull/21) | `team2/architect-a5-threat-model` | `89484a263bc3db8ad18fc668551b48e6d049f441` | STRIDE-модель угроз и границы изоляции | Разделены гипотезы и подтверждённые пробы #13 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187872415/job/111393602238); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187872415/job/111393602105) |
| F-T2-1 | [#22](https://github.com/imedfan/kaban/pull/22) | `team2/frontend-f1-card-states` | `565ab2fd56c507484867064d4569746464a560ed` | Состояния карточек по таблице 3.4 | 4 новых теста; 22 строки; отсутствие renderer API отмечено | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37187872380/job/111393602074); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37187872380/job/111393601847) |
| AN1 | [#26](https://github.com/imedfan/kaban/pull/26) | `team2/analyst-an1-traceability` | `ef0230aa06291a122412dfa5f71e659c486fe2df` | Матрица трассировки спеки и сценариев | 186 строк: UC-01…25 и правила §1/§4; full/partial/unchecked | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188228924/job/111394698865); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188228924/job/111394698699) |
| A2 | [#27](https://github.com/imedfan/kaban/pull/27) | `team2/architect-a2-compatibility` | `413a5afa2f26a28c48144babe1adfb2a6071f2f3` | Совместимость JSON/DTO/enum/tag | 10 новых тестов; обязательные, отсутствующие и лишние поля | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188229311/job/111394700370); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188229311/job/111394700222) |
| F-T2-3 | [#28](https://github.com/imedfan/kaban/pull/28) | `team2/frontend-f3-scenario-coverage` | `b71e5ce68134698b6636e35c64ec11cb65ce9f1d` | Покрытие карточек в 33 M1-сценариях | 1 новый тест; независимый oracle для 110 then.tasks | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188229170/job/111394699537); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188229170/job/111394699413) |
| F-T2-2 | [#29](https://github.com/imedfan/kaban/pull/29) | `team2/frontend-f2-projection-load` | `34330546ec1afc1db3c9293a1ab5f458bf21d594` | Нагрузка BoardProjection | 10 × 500 карточек, 20 000 событий × 5; Linux тест 1,643 с | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188229396/job/111394700227); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188229396/job/111394700291) |
| B3 | [#31](https://github.com/imedfan/kaban/pull/31) | `team2/backend-b3-command-corpus` | `fc4474894d28e4b3222f08f918b736a586d875da` | Корпус git-команд | 166 deny + 64 allow; 6 новых тестов; 3 пропуска #23–25 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188442157/job/111395352363); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188442157/job/111395352504) |
| AN2 | [#32](https://github.com/imedfan/kaban/pull/32) | `team2/analyst-an2-acceptance-delta` | `749d15de157f80ef30db2432fac36a2c07467db2` | Дельта критериев приёмки | 24 Given/When/Then с источниками и вехами | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188442370/job/111395352779); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188442370/job/111395352941) |
| F-T2-5 | [#33](https://github.com/imedfan/kaban/pull/33) | `team2/frontend-f5-plan-review` | `aefc12554a7a296868e068ac2bfb2f315ce67bb5` | План фронта против спеки/архитектуры/кода | Все 25 UC; блокеры и вопросы; issue #14 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37188442322/job/111395352848); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37188442322/job/111395352978) |
| AN3 | [#34](https://github.com/imedfan/kaban/pull/34) | `team2/analyst-an3-scenario-drafts` | `4f07ff78ff3b1bf46c45def5e93be6a821efe4e0` | Шесть сценариев для выявленных пробелов | ScenarioDecodeCheck: 1 тест без ошибок; без реплея ожиданий | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201116847/job/111432834996); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201116847/job/111432835112) |
| A3 | [#35](https://github.com/imedfan/kaban/pull/35) | `team2/architect-a3-reference` | `89fab1b08268f88f0d5204761e85d436740a22cc` | Справочник протокола и JSON-примеры | 1 новый тест; 175 samples; 46 команд / 24 journal / 9 ephemeral | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201116367/job/111432833845); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201116367/job/111432833730) |
| B4 | [#38](https://github.com/imedfan/kaban/pull/38) | `team2/backend-b4-daemon-git` | `0826b2b74faa6eff7d1e4352c61cd7b0e1299f1e` | DaemonGit/GitIdentity: реальные git-репозитории | 26 новых тестов; 1 пропуск CRLF #30; изолированные config/HOME | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201302698/job/111433379214); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201302698/job/111433379129) |
| F-T2-4 | [#39](https://github.com/imedfan/kaban/pull/39) | `team2/frontend-f4-russian-strings` | `392e95e7b296e6e0a5980c33a510e39829335841` | Каталог русских строк из плана и спеки | 377 точных цитат; 13 экранов; 37 кодов; макеты исключены | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201302519/job/111433378820); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201302519/job/111433378969) |
| T7 | [#40](https://github.com/imedfan/kaban/pull/40) | `team2/examples-t7-pipelines` | `0f195eac78ee499eca369d168177d28900a4fcb2` | Pipeline-шаблоны и invalid-примеры | 11 YAML: 4 positive после замены модели + 7 negative | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201371509/job/111433579957); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201371509/job/111433579825) |
| B1 | [#41](https://github.com/imedfan/kaban/pull/41) | `team2/backend-b1-audit` | `edca0d13742435570ae1430950e72f81470229c7` | Аудит KabanKit | 6 подтверждённых расхождений; новые issues #36/37 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201820611/job/111434909072); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201820611/job/111434908709) |
| A4 | [#42](https://github.com/imedfan/kaban/pull/42) | `team2/architect-a4-recovery` | `70ef0b0849a1c460761d2a557d688b28b6c1296c` | Матрица переходов, effect-ack и recovery | 9 статусов × 18 событий; crash points commit/merge; code/spec audit | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201890190/job/111435114698); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201890190/job/111435114518) |
| T15, остаток | [#43](https://github.com/imedfan/kaban/pull/43) | `team2/frontend-t15-a11y-l10n` | `ccc95bbbf5fead0cde9c1fff253b2a6f66cf47cd` | План доступности и локализации | VoiceOver/клавиатура/Reduce Transparency; без визуального аудита | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201420369/job/111433727583); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201420369/job/111433727521) |
| T11 | [#45](https://github.com/imedfan/kaban/pull/45) | `team2/tools-t11-smoke` | `ad66d95eca58fd4514b6e4770b7dba4e0dabe8ee` | Read-only smoke-инструменты | 11 YAML; 33 JSON / 67 steps; negative cases; hash входов сохранён | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201573244/job/111434172380); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201573244/job/111434172576) |
| T14 | [#46](https://github.com/imedfan/kaban/pull/46) | `team2/backend-t14-ci` | `590f4e38a2b9db28163391022d3a040b2254c431` | Предложения улучшения CI | Документ и fragments; действующий workflow не менялся | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201573519/job/111434173135); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201573519/job/111434173257) |
| T9 | [#47](https://github.com/imedfan/kaban/pull/47) | `team2/backend-t9-core-review` | `8b79a63c3f4e4e49fcb8f3e48dba12897cfd1aae` | Ревью публичных API трёх библиотек | Независимый probe BoardProjection; issue #44 | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201820998/job/111434910194); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201820998/job/111434910103) |
| T4 | [#48](https://github.com/imedfan/kaban/pull/48) | `team2/research-launchd-xpc` | `4a4711619b8f310c5548ff465cf3b3a0dd3bc147` | launchd, XPC и уведомления | Apple sources + SDK; plist разобран; службы не регистрировались | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201821112/job/111434910381); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201821112/job/111434910490) |
| T5 | [#49](https://github.com/imedfan/kaban/pull/49) | `team2/research-developer-id` | `a9077a899c6892c23a0188d86c1786dd40bbb064` | Developer ID и нотаризация | Apple sources; 5 shell-блоков zsh -n; подпись не выполнялась | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201820819/job/111434909437); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201820819/job/111434909279) |
| T6 | [#50](https://github.com/imedfan/kaban/pull/50) | `team2/docs-t6-getting-started` | `b9b3587f0d0aee842cf9c1a708893765209d2c51` | Getting started | Свежая сборка 5,75 с; baseline 185 тестов, 0 ошибок | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201820840/job/111434909247); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201820840/job/111434909447) |
| T13 | [#51](https://github.com/imedfan/kaban/pull/51) | `team2/docs-t13-contributing` | `458a533638c992216fb8f40d0bc2146b6a9deba1` | Правила участия и вкладов | Сверка чек-листа; только новый docs/contributing.md | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201821044/job/111434910140); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201821044/job/111434910234) |
| T12 | [#52](https://github.com/imedfan/kaban/pull/52) | `team2/docs-t12-license-options` | `f811348cab834f4e3b6729c3c8315a03c2befab3` | MIT / Apache-2.0 / MPL-2.0 | Первичные тексты лицензий; рекомендация и MIT draft; LICENSE не менялся | [Linux ✓](https://github.com/imedfan/kaban/actions/runs/37201952505/job/111435298442); [macOS ✓](https://github.com/imedfan/kaban/actions/runs/37201952505/job/111435298624) |

Проверки выполнения:

| Прогон | Результат | Практический предел |
|---|---|---|
| Исходная база | 185 тестов: Protocol 32 / Kit 107 / Board 46; 0 ошибок | SwiftPM-библиотеки, не приложение/демон |
| Совместный временный checkout всех восьми тестовых веток | 242 теста: Protocol 43 / Kit 147 / Board 52; 0 ошибок, 5 skips | Скопированы только 12 новых тестовых/fixture-файлов; ветки не мержились |
| Fuzz [Linux CI, PR #19](https://github.com/imedfan/kaban/actions/runs/37187913723/job/111393730243) | 193 теста, 0 ошибок, 1 skip; полный прогон 24,728 с | Входы ограничены глубиной/размером; это не доказательство для произвольных ресурсов |
| Projection [Linux CI, PR #29](https://github.com/imedfan/kaban/actions/runs/37188285203/job/111394877261) | Новый load-тест 1,643 с; пять apply loops 0,036–0,038 с | Проверяет core, не SwiftUI rendering/scroll |
| AN3 decode | Все шесть черновиков декодируются | Ожидания не проверялись исполнителем M1 |
| T7 semantic probe | Четыре positive и семь negative примеров дали ожидаемую классификацию | Для positive `<model-id>` заменялся на `composer-2`; модель не вызывалась |
| T11 smoke | 11 YAML / 0 failures; 33 JSON / 67 steps / 0 duplicates | 33 предупреждения final newline сохранены; входы read-only |

Пять пропусков: #12 (контракт корневого diagnostic path), #23/#24/#25
(git matcher), #30 (CRLF identity). Каждый skip находится только в новом Team2-тесте,
ссылается на issue и связан с воспроизводимым поведением, описанным в нём.
#12 требует решения по контракту diagnostic path; остальные четыре описывают
подтверждённые дефекты. Старые тесты не отключены.
Дополнительные #36/#37/#44 воспроизведены отдельными временными probes; аварийный
Double → Int64 probe запускался в дочернем процессе и не включён в общий suite.

## 2. Решения и допущения

- Источники: [чек-лист v2](https://docs.google.com/document/d/1oszVHm1jwJ6HvuQKCnr9Z-6PTICnfJ6_t3csqTWcpk0/edit), [архитектура v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view), [спека v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view), [план фронта v0.5.36](https://drive.google.com/file/d/1LXl5tv4Wjw6CNfNbs8vezjLSxgkZWtc_/view), [критерии приёмки v0.1 под старую v0.8.1](https://drive.google.com/file/d/14z297h5-6AOABSw-53kHCtnntKW_NxAv/view), [журнал решений](https://drive.google.com/file/d/1AGNwKUwZ_YcOzh0A3LAg2zUWx-_71wxx/view). Различия версий отражены в аудитах; старые локальные копии не обновлялись.
- T1/B5 объединены; T8 покрыт A1/AN4, T10 — A5; T9 дополняет отдельные аудиты. T15 содержит только остаток accessibility/l10n, каталог — F-T2-4, Designer полностью исключён.
- Противоречие требований оформляется вопросом, подтверждённая проблема — issue. Ни один найденный дефект не исправлен во второй команде.
- Реальные git-пробы выполнялись во временных репозиториях с изолированными HOME и config; локальный Git — 2.55.0. APFS не позволил создать invalid-byte filename; проверка tree использует raw Git tree-object, это явно отражено в B4.
- Целевые macOS 26 / Xcode 26 отделены от фактических macOS 27.0.1 / Xcode 27 / Apple Swift 6.4. `cursor-agent` версии `2026.09.23-86fc751` исследован ограниченными version/help-пробами; auth/resume/quota неизвестны до спайка.
- CLI и MCP исследованы по официальным источникам и подготовленным командам. Seatbelt дополнительно проверен синтетическими файлами; deny-кандидат пока не готовый production-профиль.
- Smoke-tools используют PyYAML 6.0.3 в отдельной временной venv. Package.swift, пользовательский Python, настройки системы и политика подтверждений не менялись.
- Крупные справочники/каталоги A3 и F-T2-4 превышают ориентир ~400 строк: они сохранены как цельные документы с проверяемыми примерами/цитатами. Размер не означает расширения доступа к занятым зонам.

## 3. Что НЕ сделано и почему

- **Все дизайнерские работы исключены по прямому указанию пользователя и браться за них не будем:** D-T2-1…5, контраст, stress/dark-макеты, визуальный аудит маскотов, сверка плана с макетами. Каталог F-T2-4 основан только на тексте плана и спеки.
- Не выполнены реальные запросы модели, проверка headless-auth/resume/quota под launchd, MCP-discovery с действующим CLI, сквозной run/build/network в deny-профиле. P0 содержит команды и критерии для понедельничных спайков; их должен прогнать владелец на целевом Mac.
- Не зарегистрированы службы, не открывались разрешения macOS, Keychain или credentials, не выполнялись Developer ID подпись и нотаризация. T4/T5 — исследования и runbook, поскольку в репозитории нет готового app/daemon пакета, а пользователь ограничил работу проектом.
- Нет DaemonCore/GRDB/scheduler/XPC executor/SwiftUI renderer в текущих targets. Recovery A4, часть A1/F1/F5 и VoiceOver T15 проверены документально; они не объявлены живыми интеграционными/UI-тестами.
- AN3 — шесть новых черновиков вне Scenarios/, только проверка декодирования. Feed/полная семантика default-return-to/manual-boundary и лимитов ожидают расширения исполнителя основной командой.
- Pipeline-файлы с `<model-id>` остаются шаблонами, лицензия не выбрана, предложения CI не применены. Эти решения принадлежат основной команде.
- Drive-документы не расшарены: адреса или группа второй команды не предоставлены. Публичный доступ по ссылке не включали; содержимое результатов доступно в PR, но это не заменяет доступ к исходным документам.
- Производственные дефекты из issues остаются открытыми; пять новых regression-checks имеют условные skips, а не подтверждение исправления.

## 4. Найденные проблемы и риски в коде основной команды

| Issue | Файл:строка / источник | Суть | Серьёзность |
|---|---|---|---|
| [#9](https://github.com/imedfan/kaban/issues/9) | Спека UC-06/F23; TaskMachine.swift:518–521 | answerHuman обещан для non-agent waiting_human, код запрещает; вопрос спецификации | medium |
| [#10](https://github.com/imedfan/kaban/issues/10) | Спека UC-13 / UC-18 | Изменение .kaban агентом: rollback/продолжение против incident/запрета; вопрос спецификации | high |
| [#11](https://github.com/imedfan/kaban/issues/11) | Спека §1.2 / Human Review | Исключение waiting_human из WIP против review WIP=5; вопрос спецификации | medium |
| [#12](https://github.com/imedfan/kaban/issues/12) | Sources/KabanKit/Pipeline/PipelineParser.swift:29 | Пустой diagnostic path для non-mapping root; уточнить root-контракт B2 | low |
| [#13](https://github.com/imedfan/kaban/issues/13) | spikes/backend/kaban-agent.sb:23,29–34,46–52 | Экспериментальный allow-default профиль разрешает защищённые clone write/unlink/rename | high для достоверности спайка |
| [#14](https://github.com/imedfan/kaban/issues/14) | Sources/KabanProtocol/Commands.swift:198–215 | TaskDetail не содержит durable artifacts/gitGrants/gitDenials из архитектуры | medium / P1 |
| [#23](https://github.com/imedfan/kaban/issues/23) | Sources/KabanKit/Git/GitPolicy.swift | Attached -B/-C с цифрами обходят foreign_refs matcher | high для статического фильтра |
| [#24](https://github.com/imedfan/kaban/issues/24) | Sources/KabanKit/Git/GitPolicy.swift | git long-option abbreviations обходят запрет branch mutation | high для статического фильтра |
| [#25](https://github.com/imedfan/kaban/issues/25) | Sources/KabanKit/Git/GitPolicy.swift | --onto=main пропускается в permissive policy | high для статического фильтра |
| [#30](https://github.com/imedfan/kaban/issues/30) | Sources/KabanKit/Git/GitIdentity+Project.swift:72 | CRLF как единый grapheme обходит single-line validation | major |
| [#36](https://github.com/imedfan/kaban/issues/36) | Sources/KabanKit/StateMachine/TaskMachine.swift:389 | Первый read-only violation получает gate_failed вместо readonly_violation | major |
| [#37](https://github.com/imedfan/kaban/issues/37) | Sources/KabanKit/Pipeline/PipelineConfig.swift:119 | max_file_mb=1e20 принят, последующий Double → Int64 приводит к trap | major |
| [#44](https://github.com/imedfan/kaban/issues/44) | Sources/KabanBoardCore/BoardProjection.swift:336 | ProjectSummary и глобальный openIncidentCount расходятся; порядок событий влияет на итог | major |

Все 13 находок/вопросов заведены как issues. Детальные baseline, источники,
точные места и минимальные воспроизведения находятся в самих issues и task PR.
Git-matcher issues доказывают дефекты фильтра, но не обход работающей production sandbox.

## 5. Открытые вопросы

- К Артёму: адреса/группа второй команды для чтения Drive; результаты целевых спайков 5 октября; выбор лицензии; выбор PR для мержа.
- К Analyst/Architect: решения #9–12, смысл root diagnostic path; обязательные поля TaskDetail #14; authoritative aggregate/event transaction ordering для #44.
- К Backend: исправления #23–25/#30/#36/#37; результаты CLI/MCP/Seatbelt на macOS 26; реализации scheduler/WIP/fairness/recovery из пробелов AN1.
- К Architect: допустимые XPC peer/signing checks на минимальной macOS 15 из Package.swift и на целевой macOS 26; пакетирование и доверие helper; persist/effect-ack границы из A4.
- К Frontend: доступные API начального snapshot/settings/catalog/history, отображение непокрытых состояний F1 и локализация недоопределённых ошибок F4; живой VoiceOver прогон после появления app target.
- Designer не назначен и не будет назначаться в рамках этой работы.

## 6. Изменения, влияющие на других

Нет.

Нет изменений существующих файлов, публичных типов, targets, зависимостей SwiftPM,
CI или системных настроек. Все 31 task diff проверены: 67 добавленных file entries
только в разрешённых местах; локальные SHA совпали с GitHub HEAD. Отдельный PR плана
и отчёта добавляет ещё два новых документа в docs/team2/.

Новые тесты только Team2*.swift; фикстуры только Tests/<Module>Tests/Fixtures/team2/.
Источники/старые тесты/Scenarios/spikes/design/README/действующие docs и оригиналы
Drive оставлены без правок. tools/requirements.txt относится только к optional
внешним smoke-инструментам; SwiftPM/CI его не устанавливают.

## 7. Как проверить (воспроизвести)

Проверять отдельные ветки из таблицы, не заменяя основной рабочий checkout:

```bash
git fetch origin
git worktree add --detach /tmp/kaban-review-b2 origin/team2/backend-b2-fuzz
cd /tmp/kaban-review-b2
swift build
KABAN_SCENARIOS=Scenarios/M1 swift test
```

AN3, после checkout его ветки:

```bash
KABAN_SCENARIOS=docs/team2/analyst/scenarios swift test --filter ScenarioDecodeCheck
```

Инструменты T11, после checkout его ветки (примеры берутся из отдельного T7 checkout):

```bash
python3 -m venv /tmp/kaban-tools-venv
/tmp/kaban-tools-venv/bin/python -m pip install -r tools/requirements.txt
/tmp/kaban-tools-venv/bin/python tools/lint-examples.py /path/to/t7-checkout/examples/pipelines
python3 tools/scenarios-report.py Scenarios/M1
```

Это smoke проверки; semantic pipeline validation выполнена отдельным временным
KabanKit probe и описана в T7 README. Сохранённый placeholder не заменён в коммитах.

Фактический совместный checkout этой сессии:
`/private/tmp/kaban-team2-combined-check`, база SHA выше + только новые файлы из
PR #19/#22/#27/#28/#29/#31/#35/#38. Для переноса результата можно создать чистый
временный worktree от базы и копировать только добавленные Team2/fixture-файлы
этих веток; не применять изменения Sources/Package.swift. Конкретные файлы видны
в каждом PR. Использованная команда с временными кэшами:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/kaban-team2-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kaban-team2-module-cache \
KABAN_SCENARIOS=Scenarios/M1 \
swift test --disable-sandbox \
  --cache-path /private/tmp/kaban-team2-spm-cache \
  --config-path /private/tmp/kaban-team2-spm-config \
  --security-path /private/tmp/kaban-team2-spm-security
```

Реальные git-тесты запускались с разрешённым доступом инструмента вне внешней
файловой песочницы: внутри неё macOS confstr(DARWIN_USER_TEMP_DIR) добавлял
предупреждение git в stdout и ломал существующие assertions. `--disable-sandbox`
отключает только SwiftPM sandbox. Успешный повтор не требует исправлять код проекта.

Локальные журналы, не вошедшие в репозиторий: `/private/tmp/kaban-team2-context/combined-tests.log`,
`PR19-linux.log`, `PR29-linux.log`, `scope-audit.json`, `T7-validation.log`;
они временные, проверяемые долговременные CI-логи доступны по ссылкам в таблице.
Команды спайков и ограничения исследования перечислены в каждом research-файле.


## Frontend-only design implementation — resumed session

The user continued the frontend phase after all previous M1 PRs merged. Immediate XPC work is superseded for this session. Only frontend application/assets/docs changed; backend, protocol, auth and designer work remain excluded. Implementing supplied approved designs does not create a new design.

The primary application now hosts the approved local HTML/CSS/SVG in WKWebView inside SwiftUI, with an allowlisted memory demo bridge; native prototype remains available. All 46 original sources retain their SHA256. Every one of 28 unique original frames has a menu route and own WK export, with two extra projected runtime board exports. General uses a documented deterministic-column compatibility adjustment. Platform font/emoji and snapshot backdrop-filter differences remain explicitly recorded; no pixel-perfect claim is made.

Evidence and remaining production integration are in [frontend parity](../development/frontend-design-parity-2026-10-04.md), [frontend feedback](../development/frontend-feedback-2026-10-04.md) and the source/reference SHA manifest. The unsigned app builds at `/tmp/kaban-parity-derived/Build/Products/Debug/Kaban.app`. Frontend DOM/model smoke passes 35 checks; parent package scenario suite passes 294 tests, no failures/skips. Final source exports live in `/tmp/kaban-source-final`; frames.json contains paths/themes/dimensions/SHA/findings. Root's paired review covers all 28 compositions.

Run the default app binary to inspect latest board21. Use macOS Демо menu for original read-only frames, native fallback and brand. Run binary `--demo-smoke /tmp/result.json` or `--export-design-frames /tmp/frames` for repeatable checks; failure exits nonzero. [App README](../../App/README.md) gives complete commands and scope. Memory actions do not perform repository/system/daemon work; production adaptation to existing typed BoardStore/KabanClient remains future integration. Root publishes PR against MAIN, checks CI and launches the final app; PR URL/SHA will be appended after publication.

Publication: [PR #67](https://github.com/imedfan/kaban/pull/67), base `main`, frontend implementation SHA `2b96459bec2146163bbff9e8c8160e2a97d2b228`. Publication was completed after midnight on 2026-10-05 (Europe/Kaliningrad); this report keeps the date of the session start. Root verified 46 unchanged originals, 30 export dimensions/hashes and the 35-check smoke result independently. PR remains unmerged; CI status is available on the PR.
