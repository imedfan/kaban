# Порядок принятия PR после передачи управления

2026-10-04. Управление разработкой передано текущей команде пользователем.
Прежние ограничения team2 на production-код, Package.swift, исправления и
существующие документы отменены. Сохраняются отдельные ветки и PR; мерж выполняет
Артём. Готовый дизайн используем для SwiftUI; дизайнерские работы не берём.

## Как принимать

Для каждого PR: проверить diff и актуальный HEAD, дождаться зелёного Linux и macOS
CI, затем принимать следующий. Исходные 32 PR были независимы от одной базы
`1d647ea`; при изменении main GitHub пересчитает mergeability, а CI ветки сам по
себе не доказывает совместный результат. Совместная проверка выполняется в
временном checkout; если появляется конфликт, обновление готовит координатор.
Не требуется принимать все исследовательские документы до начала кодирования.

| Очередь | PR в порядке принятия | Почему |
|---|---|---|
| 1. Контекст и инструкции | [#53](https://github.com/imedfan/kaban/pull/53), [#50](https://github.com/imedfan/kaban/pull/50), [#51](https://github.com/imedfan/kaban/pull/51), затем этот PR | Отчёт прошлой сессии, build guide и исторические правила team2. Новое поручение и этот документ разрешают production-разработку |
| 2. Исследования | [#15](https://github.com/imedfan/kaban/pull/15), [#16](https://github.com/imedfan/kaban/pull/16), [#17](https://github.com/imedfan/kaban/pull/17), [#21](https://github.com/imedfan/kaban/pull/21), [#48](https://github.com/imedfan/kaban/pull/48), [#49](https://github.com/imedfan/kaban/pull/49) | Cursor/MCP/Seatbelt, threat model, упаковка и подпись. Это исследования и runbook, не выполненные целевые спайки |
| 3. Аудиты и требования | [#18](https://github.com/imedfan/kaban/pull/18), [#20](https://github.com/imedfan/kaban/pull/20), [#26](https://github.com/imedfan/kaban/pull/26), [#32](https://github.com/imedfan/kaban/pull/32), [#34](https://github.com/imedfan/kaban/pull/34), [#33](https://github.com/imedfan/kaban/pull/33), [#41](https://github.com/imedfan/kaban/pull/41), [#42](https://github.com/imedfan/kaban/pull/42), [#47](https://github.com/imedfan/kaban/pull/47) | Traceability → новые сценарии; остальные аудиты независимы. Их находки исторические: текущие решения находятся в журнале решений |
| 4. Регрессионная база | [#19](https://github.com/imedfan/kaban/pull/19), [#27](https://github.com/imedfan/kaban/pull/27), [#35](https://github.com/imedfan/kaban/pull/35), [#22](https://github.com/imedfan/kaban/pull/22), [#28](https://github.com/imedfan/kaban/pull/28), [#29](https://github.com/imedfan/kaban/pull/29), [#31](https://github.com/imedfan/kaban/pull/31), [#38](https://github.com/imedfan/kaban/pull/38) | Сначала фиксируем совместимость и воспроизведения. #19 обновлён после решения #12: root-path skip снят |
| 5. Прикладные материалы | [#39](https://github.com/imedfan/kaban/pull/39), [#40](https://github.com/imedfan/kaban/pull/40), [#45](https://github.com/imedfan/kaban/pull/45), [#43](https://github.com/imedfan/kaban/pull/43), [#46](https://github.com/imedfan/kaban/pull/46), [#52](https://github.com/imedfan/kaban/pull/52) | Примеры #40 перед tools #45. CI и лицензия — предложения, не применение |
| 6. Рабочие контракты | [#56](https://github.com/imedfan/kaban/pull/56) | Durable TaskDetail, initial settings и архитектурные уточнения. Старые пустые wire shapes сохраняются |
| 7. Исправления | [#54](https://github.com/imedfan/kaban/pull/54), [#55](https://github.com/imedfan/kaban/pull/55), затем Kit identity/size/readonly | Git-policy исправления независимы; следующая Kit ветка stacked поверх #54. Board aggregates зависят от принятого authoritative contract #56 |
| 8. Начало M1 и frontend | GRDB/DaemonCore store, SwiftUI app foundation | Store после Kit fixes; приложение независимо от store на mock-клиенте. Полноценный live daemon/XPC/agent ещё не реализован |

Это полный inventory 32 старых PR, а не требование 32 последовательных этапов
разработки. Новые PR с кодом публикуются параллельно.

Kit identity/size/readonly — [#57](https://github.com/imedfan/kaban/pull/57),
GRDB store — [#58](https://github.com/imedfan/kaban/pull/58), SwiftUI app —
[#59](https://github.com/imedfan/kaban/pull/59). Экспериментальный профиль
[#60](https://github.com/imedfan/kaban/pull/60) принимать после #17.
#57 сейчас имеет base `codex/kit-git-policy-fixes`, #58 —
`codex/kit-identity-size-readonly-fixes`. После принятия родителя поменять base
дочернего PR на `main`, проверить diff и повторить CI.

## Политика issues

Решения #9–12 записаны в обновлённой спецификации/журнале. Исправления #14/#23–25/
#30/#36/#37/#44 проходят review и CI. Пока PR не принят, production-issue остаётся
открытым; `Fixes #N` связывает закрытие с мержем. #13 относится к экспериментальному
профилю спайка: синтетические защищённые пути проверяем отдельно, готовность
production confinement не объявляем.

Архитектура, спецификация, frontend/backend планы, приёмка и журнал решений
обновлены также в Drive по прежним IDs после восстановления подключения.
Перед записью сверены исходники, после записи — SHA-256 полного содержимого.
Ссылки, папки и права доступа сохранены. Эти документы описывают принятые
решения и работу в PR; код в main появится после review и мержа Артёмом.
