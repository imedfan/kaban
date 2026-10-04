# T12 — варианты лицензии Kaban

Дата проверки первичных источников: **4 октября 2026**. Основание задачи — [чек-лист team2, T12](https://docs.google.com/document/d/1oszVHm1jwJ6HvuQKCnr9Z-6PTICnfJ6_t3csqTWcpk0/edit). Это предложение для решения Артёма; LICENSE не создаётся и лицензия проекта этим документом не устанавливается.

## Рекомендация — три строки

1. Для текущего публичного Swift-проекта предлагаю **MIT**: короткое разрешительное правило, без обязательного раскрытия модификаций.
2. Если приоритет — явно описанная лицензия на патенты участников, выбрать **Apache-2.0** вместо MIT. [Apache §3](https://www.apache.org/licenses/LICENSE-2.0)
3. **MPL-2.0** выбрать, если нужно сохранять открытость распространяемых изменений покрытых файлов; отдельные файлы Larger Work могут иметь другую лицензию. [MPL §3](https://www.mozilla.org/en-US/MPL/2.0/)

Первая строка — рекомендация team2, следующие две — альтернативы под разные цели владельца, а не обязательные этапы.

## Сравнение

| Вопрос | MIT | Apache-2.0 | MPL-2.0 |
|---|---|---|---|
| Использование/изменения | Разрешительная | Разрешительная; раскрытие исходников изменений не требуется | Copyleft на уровне покрытых файлов; коммерческое использование допустимо |
| Распространение | Сохранять copyright и permission notice | Передавать лицензию, отмечать изменённые файлы, сохранять применимые notices; если был NOTICE, сохранять применимую атрибуцию | Доступность исходников покрытых файлов, включая модификации; уведомление получателей, как получить исходники, сохранение notices |
| Патенты | Отдельного явного patent grant в тексте нет | Явный grant только на соответствующие патентные притязания contributor; прекращение patent license при указанном в §3 иске | Grant по §2.1 с ограничениями §2.3; при указанном в §5.2 патентном иске прекращаются права §2.1 |
| Закрытые дополнительные файлы | Допускаются | Допускаются при соблюдении условий лицензии | Larger Work может включать отдельные файлы под иными условиями; модификации покрытых файлов остаются MPL |
| Основной tradeoff для Kaban | Минимальный объём условий | Более явные патентные условия и дополнительные notices | Потребуется отслеживать покрытые файлы и доступность их исходников при дистрибуции |

Первичные тексты: [MIT — OSI](https://opensource.org/license/mit), [Apache License 2.0, §2–6](https://www.apache.org/licenses/LICENSE-2.0), [MPL 2.0, §1–3 и §5.2](https://www.mozilla.org/en-US/MPL/2.0/). Пояснение file-level copyleft и отдельных файлов: [Mozilla FAQ Q1, Q8–Q11](https://www.mozilla.org/en-US/MPL/2.0/FAQ/). Таблица — краткий пересказ условий, не самостоятельная лицензия.

Apache patent grant не является гарантией отсутствия патентов третьих лиц. У MPL §5.2 есть исключения для declaratory judgments/counterclaims/crossclaims; её условие прекращения отличается от Apache §3. Выбор одной из лицензий не заменяет права на чужие компоненты/торговые знаки. [Apache §3/§6](https://www.apache.org/licenses/LICENSE-2.0), [MPL §2.3/§5.2](https://www.mozilla.org/en-US/MPL/2.0/)

## GRDB и зависимости

В [Package.swift текущей базы](https://github.com/imedfan/kaban/blob/1d647ea/Package.swift) нет внешних зависимостей: только Protocol, Kit и BoardCore. GRDB планируется архитектурой v0.11.22 §2/§4, но ещё не подключён. [Свежая архитектура](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view)

Официальный [GRDB.swift/LICENSE](https://github.com/groue/GRDB.swift/blob/master/LICENSE), проверенный [raw-текст](https://raw.githubusercontent.com/groue/GRDB.swift/master/LICENSE), содержит MIT и copyright Gwendal Roué (2015–2025). Вывод для будущей интеграции: использование GRDB совместимо с выбранными здесь вариантами при сохранении её copyright/permission notice; изменение лицензии Kaban не заменяет MIT GRDB. Это вывод из разрешения GRDB использовать/распространять/sublicense и условий сохранения notice, а не аудит всей будущей dependency graph.

Для MPL интеграцию независимого MIT-компонента следует описать как часть Larger Work, а не объявлять GRDB перелицензированной в MPL. Новые файлы, содержащие покрытый MPL-код, входят в Modifications; просто отдельный независимый компонент — иной случай. [MPL §1.7/§1.10/§3.3](https://www.mozilla.org/en-US/MPL/2.0/)

После выбора и подключения конкретной версии GRDB сохранить notices именно выбранного release/commit и проверить фактический Package.resolved/дистрибутив. Сейчас нет зафиксированной версии GRDB, поэтому это не выполненный аудит поставки. Политика лицензирования design/assets и права на каждый артефакт здесь не проверялись: Designer исключён человеком.

## Готовый текст MIT для будущего LICENSE

Текст ниже — полный MIT, [источник OSI](https://opensource.org/license/mit); воспроизводится по предоставленному разрешению копирования и распространения. `<YEAR>` и `<COPYRIGHT HOLDER>` — placeholders; владельца прав и год выбирает Артём. Английский текст оставлен без изменения условий; имя/контакты человека не выдуманы. Этот блок находится только в документе, не в LICENSE.

```text
MIT License

Copyright <YEAR> <COPYRIGHT HOLDER>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Итог

Сделано: сравнение трёх вариантов, рекомендации в три строки, GRDB по первичному LICENSE и полный MIT с placeholders. Не выполнено: выбор владельца/лицензии, создание LICENSE, проверка будущего зафиксированного dependency graph и артефактов дизайна. Открытый вопрос к Артёму: цель — минимум условий, явный patent grant или сохранение открытости изменённых файлов? Уверенность высокая в прочитанных текстах лицензий; совместимость конкретного будущего дистрибутива требует фактического списка компонентов.
