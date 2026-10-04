# Намеренно некорректные примеры

Все файлы синтаксически корректны. Коды сверены с spec v0.8.24 §4.1
и фактически получены от текущего KabanKit на baseline `1d647ea`.
`<model-id>` заменяли `composer-2` только в памяти harness.
Ожидание — наличие code, не полное совпадение списка/порядка issues.

| Файл | Обязательный code | Фактически дополнительные codes | Причина |
|---|---|---|---|
| model-missing.yaml | model_missing | — | agent без явной модели |
| model-auto.yaml | model_auto_forbidden | — | auto не допускается |
| returns-forward.yaml | returns_forward | no_return_target | dev возвращает в более поздний non-agent merge |
| merge-count.yaml | merge_count | — | нет merge |
| on-success-cycle.yaml | on_success_cycle | returns_forward; повтор on_success_cycle | dev ведёт обратно в backlog, граф цикличен |
| secret-in-env.yaml | secret_in_env | — | синтетический API_TOKEN внутри env; это не настоящий секрет |
| no-return-target.yaml | no_return_target | второй no_return_target | все agents read-only: merge и human некуда вернуть |

Не исправлять эти файлы ради зелёного smoke: семантическая невалидность
намеренная. Smoke T11 проверяет синтаксис/базовую форму, не Kaban validation.
