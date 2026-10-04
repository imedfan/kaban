# AN2 — дельта критериев приёмки v0.8.1 → v0.8.24

Дата 2026-10-04; baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
S = [спецификация v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view),
A = [архитектура v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view),
AC = [критерии v0.1 под спеку v0.8.1](https://drive.google.com/file/d/14z297h5-6AOABSw-53kHCtnntKW_NxAv/view).
Это предложения новых проверяемых критериев, исходный AC не изменён.
Вехи: M1 чистая модель/validator/policy; M2 реальные процессы/git/MCP;
M3 UI; M4 merge/live quota; M5 signing. Unit test не закрывает другую веху.

## Identity: новые критерии UC-01

### ID-01 — источник и хранение (M2; S UC-01 п.2, A §8.2)
Given явный `identity` с именем и почтой и другие значения git config.
When `addProject` успешно выполняется.
Then сохранённая identity проекта равна введённой после trim; автор не записан
в `.kaban/`; последующие daemon/agent commits используют сохранённого автора.

### ID-02 — обычное разрешение git config (M2; S UC-01 п.2)
Given вызов без identity и непустая git identity из local/global/system scope.
When проект добавляется.
Then найденные значения читаются один раз по обычному precedence git,
сохраняются локально у демона; глобальный config не меняется и позже не влияет
на автора уже зарегистрированного проекта. IncludeIf fixture — только temp.

### ID-03 — missing/invalid partition (M1 проверки; M2 handler; S UC-01 альтернативы)
Given любая комбинация отсутствия, пробелов/табов, LF или NUL, корректного значения.
When проверяется identity.
Then LF/NUL проверяются до trim; `" \n "` invalid, пробелы/табы missing;
каждое поле ровно в одном из `params.missing`, `params.invalid`, `params.name/email`;
списки идут name,email; отклонённые значения в params не возвращаются.

### ID-04 — отказ атомарен (M2; S UC-01 альтернативы)
Given identity missing/invalid и репозиторий без `.kaban/`.
When `addProject` отклонён с `identity_required`.
Then проект не зарегистрирован, шаблон/коммит не создан, git config не изменён;
повтор с корректной identity создаёт ровно один проект.

### ID-05 — первый отказ, найденное значение (M3; S UC-01 первый отказ)
Given первый вызов без identity: name найден, email missing (или наоборот).
When пришёл `identity_required`.
Then найденное значение предзаполнено с «из настроек git», focus на первом
missing/invalid, missing без обводки; уточнение равно соответствующему тексту S.
Если второе поле invalid, уточнения «нашлось только…» нет.

### ID-06 — первый отказ, invalid (M3; S UC-01 первый отказ)
Given первый вызов без identity и invalid name/email из git config.
When показан лист добавления.
Then invalid поле пустое, текст о служебных символах виден сразу, обводки нет;
если ничего не найдено, дополнительного уточнения нет.

### ID-07 — повторный отказ сохраняет ввод (M3; S UC-01 отказ с identity)
Given человек ввёл значения и отправил вызов с identity.
When пришёл `identity_required` с missing/invalid.
Then оба введённых значения остаются в полях; только поля из списков получают
обводку и соответствующий «Укажите…»/«…в одну строку…» текст из S.
Не подменять ввод найденным git config, даже если params содержит найденное.

### ID-08 — legacy и изменение автора (M2/M3; S UC-01 п.2 и альтернативы)
Given старый демон без params/ProjectSummary.identity.
When UI показывает отказ/настройку автора.
Then только общий текст, без invented highlights; отсутствующая identity — «—».
Given зарегистрированный проект и `setProjectIdentity` с invalid identity.
When команда отклонена.
Then сохранённый автор не меняется; после успешного изменения новые commits
получают нового автора. На запуске зарегистрированного проекта identity_required нет.

## Возвраты: изменённые критерии §1.3 / UC-07

### RT-01 — допустимая цель (M1; S §1.3, A §3.1)
Given returns_to/on_fail/on_conflict с существующей readOnly agent либо non-agent целью.
When pipeline валидируется.
Then `no_return_target` с stageId исходной стадии; unknown_stage только для
отсутствующего id. Нельзя считать существующую readOnly цель unknown_stage.

### RT-02 — default resolution (M1; S §1.3)
Given нет явной цели.
When validator разрешает возврат.
Then gate идёт к ближайшему предыдущему writable agent по on_success,
merge и requestChanges к первому writable agent; default on_fail limit=3.
Нет writable agent и есть human/gate/merge → pipeline issue path=stages,
без stageId для глобального requestChanges default.

### RT-03 — ручной возврат и перенос (M1 handler; M3 UI; S §1.3)
Given ручной requestChanges или reject с readOnly/non-agent целью.
When команда выполняется.
Then invalid_state без мутации; reject.cancel разрешён, moveTask на readOnly
разрешён правилами переноса, человеческие возвраты не увеличивают bounce count.
При недопустимом текущем состоянии применяются остальные ограничения команд;
«разрешён всегда» здесь означает отсутствие запрета по readOnly цели cancel.

### RT-04 — UI использует resolved DTO (M3; S §1.3)
Given StageSummary.onFail/onConflict и PipelineSummary.defaultReturnStage от демона.
When открыт лист возврата.
Then UI не ищет ближайшую/первую стадию, не предлагает readOnly цели,
отправляет явный stage/target; nil default не превращает произвольную стадию в цель.
Красный gate не повторяется на месте. Поведение пустого списка целей уточнить
с Frontend без придумывания нового текста кнопки.

### RT-05 — причины лимитов (M3; S §1.3 подписи)
Given bounce_limit/conflict_limit/run_limit и соответствующие counters/limits DTO.
When показаны карточка, лента и настройки.
Then bounce title «Лимит возвратов», уточнение «общий, N из M»,
«<откуда> → <куда>, N из M», «при красном гейте, N из M» или «при конфликте, N из M»;
run_limit title «Лимит запусков на задачу», уточнение N из M.
Лента соединяет title и уточнение ` · `; имена стадий берутся из pipeline,
настройка bounce_limit_total называется «Общий лимит возвратов».
Это проверка текста и данных, аудит визуального расположения исключён.

## Git-политика: новые/уточнённые критерии UC-19

### GP-01 — последний изменивший слой (M1 resolver; M3 labels; S UC-19 п.3–4)
Given project rule повторяет preset, stage повторяет project без изменения решения.
When разрешена effective policy.
Then source остаётся последним действительно изменившим слой, повтор его не меняет.
UI preset/project показывает «унаследовано», stage allow/when «переопределено»,
stage deny «сужено»; source отсутствует → пометка отсутствует.

### GP-02 — deny и prefix (M1; S UC-19 п.3)
Given project deny restore, stage extend restore --staged.
When рассчитана policy и проверяется restore --staged.
Then project deny побеждает; обратный prefix (deny restore --staged)
не запрещает все restore. Stage не снимает project deny.

### GP-03 — readOnly projection (M1/M3; S UC-19 п.3–4)
Given readOnly stage, project разрешает add/commit, project deny reset,
stage содержит явный deny либо неизвестную extend команду.
When демон выдаёт effective policy.
Then project non-read commands и stage denies в denied source=stage,
label «сужено до чтения»; project deny source=project, label «унаследовано».
Команда вне policy проекта остаётся «нет в пресете»; UI ничего не вычисляет.

### GP-04 — readOnly extend validation (M1; S UC-19 п.3, §4.1)
Given readOnly agent extend известной пишущей команды с/без when.
When валидируется YAML.
Then error git_readonly_extend, cmd=первое слово, stageId и точный path.
Given неизвестное первое слово (rebsae).
Then только warning git_unknown_command, без git_readonly_extend;
resolved policy denied source=stage. Warning не блокирует сохранение.

### GP-05 — все семь инвариантов (M1 DTO/filter; M2 enforcement; M3 display; S §1.5)
Given любой preset, overrides и one-shot grant.
When демон выдаёт policy.
Then hardInvariants ровно push,remote,config,tag,force,foreign_refs,kaban_dir
в этом порядке; weakening отклонён. push --force возвращает push,
branch -f возвращает foreign_refs. Неизвестный id UI показывает raw monospace.
Обеспечение protected files и dynamic refs проверяется отдельно M2.

### GP-06 — force spelling и clean (M1; S §1.5 force)
Given --force* любого subcommand, указанные forced -f/short clusters,
clean без -n/--dry-run (включая -i).
When проверяет static filter.
Then force denial, кроме first-match более раннего invariant;
grep -f/blame -f/ls-files -f и clean --dry-run не ложно запрещены.
Git long abbreviations/attached flags проверять корпусом B3 (#23–25).
Семантические aliases, не перечисленные S, не объявлять новым правилом без решения.

### GP-07 — strict commit и следующие run (M2; S UC-19 п.5/альтернативы)
Given strict preset и зелёные gates/result check.
When завершается стадия с изменениями.
Then один daemon commit всех nonignored изменений, message=summary,
empty summary → `kaban: <стадия> <задача>`; агент не коммитит.
Given сохранение новой policy при активном run.
Then активный использует прежнюю policy; новый run получает новую.

## Suspicious files / readonly result / validation

### SF-01 — принять против попросить убрать (M1; M2 diff; S UC-25 п.4)
Given suspicious_files на agent stage и answerHuman с замечанием.
When команда принята.
Then набор не accepted, новый run, после gates тот же blob проверяется снова.
Given gate/merge requestChanges с текстом.
Then набор не accepted. MoveTask/return без текста принимают набор по UC-25;
stale набор acceptSuspiciousFiles → stale_suspicious_files без перехода.

### SF-02 — доступность отмены (M1/M3; S UC-25 п.4, UC-07)
Given suspicious_files на gate/merge, а не Human Review.
When UI показывает команды.
Then есть «Отменить» с опцией archive, нет «Отклонить» как review action.
Тексты «по шаблону» и «по размеру» заменяют старую эвристику «похоже на секрет».

### RO-01 — повтор нарушения (M1; M2 rollback; S UC-04)
Given readOnly stage меняет файлы в первый раз за заход.
When проверяется результат.
Then rollback и retry_wait:readonly_violation со списанием попытки;
повтор за тот же заход сразу waiting_human:invalid_result.

### VA-01 — семантика сообщений (M1 DTO/validator; M3 text; S §4.1)
Given known validation code и все нужные params/stageId/path.
When formatter показывает issue.
Then используются соответствующая строка S и metadata для stage/path;
если параметра нет — message без незаполненных placeholders;
unknown code → message и raw code. Severity, а не code, определяет блокировку.
Labels/durations переводятся только по таблице, неизвестное значение raw.
max_file_mb без min/max использует message; backoff_too_long max=число пауз.

## Что в старом AC изменить или уточнить

| AC v0.1 | Дельта / риск | Новый критерий |
|---|---|---|
| UC-01 без автора | Недостающие требования, не прежнее неверное поведение | ID-01…08 |
| UC-07 «выбранная стадия» | Нужен writable agent; иначе разрешает недопустимый возврат | RT-01…04 |
| UC-19 readOnly «до чтения» без источников | Неполон для четырёх labels и неизвестного extend | GP-01…05 |
| UC-25 «повтор, перенос, возврат…принимают набор» | Слишком широкое слово «возврат»: requestChanges с текстом не принимает | SF-01 |
| UC-25 не объясняет gate/merge vs review actions | Уточнить cancel/reject и naming | SF-02 |
| UC-04 readonly_violation | Уже соответствует новой S; нужен edge test, не замена | RO-01 |
| Инвариант attempt всегда 1…3 / autoRuns 0…12 | Утверждённые defaults настраиваемы (§1.3/1.4/4.1); критерий привязать к configured max и phase | отдельное решение Analyst |
| Инвариант «run с model_substituted не меняет…» | Согласован; kill-before-first-tool требует M2 evidence | сохранить |
| «Для каждого M1 критерия есть исполняемый сценарий» | UC-02/12/13/19 обещаны, но файлов нет; 13 из 33 partial | AN1/F3, не менять критерий на зеленоватый subset |

Открытые решения #9 (scope замечания), #10 (.kaban incident) и #11 (human WIP)
не разрешены новой редакцией критериев. Сохранить их pending, не выбирать поведение.
Изменения диапазонов/defaults вне новых требований не предложены.
Дизайнерские задачи, контраст, dark/stress layouts и маскоты не выполняются.

Проверка: каждый ID имеет Given/When/Then, конкретный S-пункт и веху;
сверены журнал версий S v0.8.2…24 и AC v0.1. Это document audit,
критерии не утверждены владельцем и новые runtime тесты этим PR не добавляются.
