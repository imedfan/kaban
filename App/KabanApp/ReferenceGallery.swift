import SwiftUI
import KabanBoardCore

struct ReferenceFrame: Identifiable, Codable {
    let id: String
    let width: Double
    let height: Double
    let dark: Bool
    let route: String
    static let all: [ReferenceFrame] = [
        .init(id:"base/01-board",width:1440,height:900,dark:false,route:"board-base"),
        .init(id:"base/01-board-dark",width:1440,height:900,dark:true,route:"board-base"),
        .init(id:"base/02-cards",width:1440,height:2070,dark:false,route:"cards-base"),
        .init(id:"base/03-task-details",width:1440,height:900,dark:false,route:"incident"),
        .init(id:"base/03b-human-review",width:1440,height:900,dark:false,route:"review"),
        .init(id:"base/04-column-settings-git",width:1440,height:900,dark:false,route:"stage-git-base"),
        .init(id:"base/05-column-settings-general",width:1440,height:900,dark:false,route:"general"),
        .init(id:"v0.2/01-board-limits-flags",width:1440,height:900,dark:false,route:"board-v02"),
        .init(id:"v0.2/01-board-limits-flags-dark",width:1440,height:900,dark:true,route:"board-v02"),
        .init(id:"v0.2/02-cards-states",width:1440,height:1060,dark:false,route:"cards-v02"),
        .init(id:"v0.2/03-details-model-substituted",width:1440,height:900,dark:false,route:"substituted"),
        .init(id:"v0.2/03-details-model-substituted-dark",width:1440,height:900,dark:true,route:"substituted"),
        .init(id:"v0.2/03b-details-run-limit",width:1440,height:900,dark:false,route:"run-limit"),
        .init(id:"v0.2/04-pipeline-invalid",width:1440,height:900,dark:false,route:"pipeline-invalid"),
        .init(id:"v0.2/05-project-mcp",width:1440,height:900,dark:false,route:"project-mcp"),
        .init(id:"v0.2/06-mac-quota-menubar",width:1440,height:900,dark:false,route:"mac-quota"),
        .init(id:"v0.2.1/01-cards-suspicious",width:1440,height:900,dark:false,route:"cards-suspicious"),
        .init(id:"v0.2.1/01c-cards-bounce-limits",width:1440,height:720,dark:false,route:"cards-bounce"),
        .init(id:"v0.2.1/02-details-suspicious",width:1440,height:900,dark:false,route:"suspicious"),
        .init(id:"v0.2.1/02-details-suspicious-dark",width:1440,height:900,dark:true,route:"suspicious"),
        .init(id:"v0.2.1/02b-details-suspicious-stale",width:1440,height:900,dark:false,route:"stale"),
        .init(id:"v0.2.1/03-project-git-presets",width:1440,height:900,dark:false,route:"project-git"),
        .init(id:"v0.2.1/04-stage-git-overrides",width:1440,height:900,dark:false,route:"stage-git"),
        .init(id:"v0.2.1/05-return-sheet-gate",width:1440,height:900,dark:false,route:"return-gate"),
        .init(id:"v0.2.1/05-return-sheet-gate-dark",width:1440,height:900,dark:true,route:"return-gate"),
        .init(id:"v0.2.1/05b-return-sheet-merge",width:1440,height:900,dark:false,route:"return-merge"),
        .init(id:"v0.2.1/06-add-project-identity",width:1440,height:900,dark:false,route:"add-project"),
        .init(id:"v0.2.1/06-add-project-identity-dark",width:1440,height:900,dark:true,route:"add-project")
    ]
}

struct ReferenceFrameView: View {
    @Bindable var demo:ReferenceDemo
    let frame:ReferenceFrame
    private var theme:ReferenceTheme{.init(dark:frame.dark)}
    var body:some View {
        Group {
            switch frame.route {
            case "board": ReferenceBoard(demo:demo,theme:theme)
            case "board-base","board-v02":ReferenceBoard(demo:demo,theme:theme,version:frame.route == "board-base" ? "base" : "v02")
            case "incident","review","substituted","run-limit","suspicious","stale":ReferenceBoard(demo:demo,theme:theme,overlay:frame.route,version:["incident","review"].contains(frame.route) ? "base" : ["substituted","run-limit"].contains(frame.route) ? "v02" : "latest")
            case "return-gate","return-merge":returnPage
            case "add-project":addProjectPage
            case "cards-base","cards-v02":ReferenceHistoricalCards(demo:demo,theme:theme,version2:frame.route=="cards-v02")
            case "cards-suspicious","cards-bounce":ReferenceCardGallery(demo:demo,theme:theme,kind:frame.route)
            default:ReferenceSettings(demo:demo,theme:theme,kind:frame.route)
            }
        }.frame(width:frame.width,height:frame.height).environment(\.colorScheme,frame.dark ? .dark:.light).foregroundStyle(theme.text)
    }
    private var returnPage:some View {
        let merge=frame.route=="return-merge"
        return VStack(alignment:.leading,spacing:12){Text("Kaban v0.2.1 · «Вернуть…» на \(merge ? "merge":"gate")-стадии · подозрительные файлы").font(.system(size:21,weight:.bold));Text("Задача \(merge ? "SHOP-29 на Merge":"SHOP-55 на Checks") в waiting_human · suspicious_files. На gate и merge «Попросить убрать» — это «Вернуть с замечанием»: одна кнопка «Вернуть…» открывает лист. Подпись основной кнопки зависит от поля замечания; лист — стекло окна, акцент — янтарь, без красного.").font(.system(size:11.5)).foregroundStyle(theme.secondary)
            HStack(alignment:.top,spacing:22){ForEach([false,true],id:\.self){filled in VStack(alignment:.leading,spacing:7){HStack{ReferenceChip(title:filled ? "б":"а",theme:theme);Text(filled ? "Вписано замечание → «Вернуть с замечанием»":"Поле пустое → «Принять файлы и вернуть»").font(.system(size:12.5,weight:.bold))};ZStack(alignment:.top){ReferenceDetails(demo:demo,theme:theme,kind:merge ? "merge":"gate");theme.text.opacity(theme.dark ? 0.38:0.11);ReferenceReturnFixture(theme:theme,merge:merge,filled:filled).padding(.horizontal,20).padding(.top,122)}.frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:18));Text(filled ? "Замечание вписано. requestChanges(taskId, comments, target: dev). Набор не принят: после гейтов Dev проверка пройдёт заново. Возврат ручной, счётчики не растут.":"Пустое поле. moveTask(stage: dev): пары «путь + blob» пишутся в task_accepted_file, идёт suspiciousFilesAccepted. Попытка не списывается. «Подставить…» переключит кнопку.").font(.system(size:10.5)).foregroundStyle(theme.secondary)}}}.frame(maxHeight:.infinity)
        }.padding(.horizontal,32).padding(.top,22).padding(.bottom,18).background(theme.content)
    }
    private var addProjectPage: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Kaban v0.2.1 · «Добавить проект» · автор коммитов").font(.system(size:21,weight:.bold))
            Text("Все коммиты демона и агента подписаны автором проекта GitIdentity { name, email } через -c user.name=… -c user.email=…; глобальный конфиг в работе демона не участвует (арх. v0.11.21 §5, §8.2, спека v0.8.23 UC-01). addProject(path, createTemplate, identity?): нет автора или имя / почта пустые (одни пробелы — тоже) → identity_required, проект не создаётся; детали — CommandError.params: missing, invalid (name | email | name,email), найденные name / email. Каждое поле — ровно в одном виде; отклонённое значение не возвращается. Ошибки оранжевые.")
                .font(.system(size:11.5)).foregroundStyle(theme.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(alignment: .top, spacing: 18) {
                ForEach(0...2, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { ReferenceChip(title:["а","б","в"][mode],theme:theme); Text(["Обычный путь · автор из git","Ответ identity_required","Повтор с пустой почтой"][mode]).font(.system(size:12.5,weight:.bold)) }
                        ZStack(alignment: .top) {
                            miniWindow
                            theme.text.opacity(theme.dark ? 0.42:0.16)
                            ReferenceAddProjectFixture(theme:theme,mode:mode).padding(.horizontal,16).padding(.top,30)
                        }.frame(height:466).clipShape(RoundedRectangle(cornerRadius:18))
                        Text(["Без identity. Демон читает git -C <repo> config (репозиторий, глобальный, системный). Есть имя и почта — проект добавлен, автор сохранён у демона.","Первый отказ без identity: missing=email, name=Артём Палкин. Имя подставлено («из настроек git»), уточнение «нашлось только имя», фокус в первом поле из missing / invalid, без подсветки.","Отказ вызову с identity: поля из missing / invalid с обводкой, здесь «Укажите почту». Без ключей — только общий текст."][mode])
                            .font(.system(size:10.5)).foregroundStyle(theme.secondary).fixedSize(horizontal:false,vertical:true)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            HStack(alignment:.top,spacing:18) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Настройки проекта · «Автор коммитов»").font(.system(size:12.5,weight:.bold))
                    authorSettingsPreview
                }.frame(width:640)
                VStack(alignment:.leading,spacing:6) {
                    Text("г  Первый отказ, invalid: name").font(.system(size:12.5,weight:.bold))
                    ReferenceAddProjectFixture(theme:theme,mode:3,inset:true).padding(.horizontal,12)
                        .frame(height:198,alignment:.top).background(theme.lane,in:RoundedRectangle(cornerRadius:18)).clipShape(RoundedRectangle(cornerRadius:18))
                }.frame(maxWidth:.infinity)
                VStack(alignment:.leading,spacing:6) {
                    Text("Старый демон").font(.system(size:12,weight:.semibold))
                    ReferenceBox(title:"Старый демон        nil",theme:theme) {
                        Text("Имя     —\nПочта   —").font(.system(size:12))
                        ReferenceButton(title:"Изменить…",small:true,theme:theme) { demo.route="identity-settings" }
                    }
                    Text("ProjectSummary.identity = nil → «—»; «Изменить…» доступна, те же проверки и тексты, что в листе.").font(.system(size:10.5)).foregroundStyle(theme.secondary).fixedSize(horizontal:false,vertical:true)
                }.frame(width:236)
            }
            Spacer(minLength:0)
        }.padding(.horizontal,32).padding(.top,20).padding(.bottom,16).background(theme.content)
    }
    private var authorSettingsPreview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { ReferenceMascot(emoji: "🦊", theme: theme, state: "waiting", size: 22); VStack(alignment: .leading) { Text("shop-api").font(.system(size: 12, weight: .semibold)); Text("~/dev/shop-api · main").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(theme.faint) } }
                Text("Стадии · Проект · .kaban/ …").font(.system(size: 10.5)).foregroundStyle(theme.faint)
                Text("Проект · на этом Маке").font(.system(size: 10.5)).foregroundStyle(theme.faint)
                Label("MCP для запусков", systemImage: "powerplug")
                Label("Вес и личный максимум", systemImage: "cpu")
                Label("Маскот", systemImage: "sparkles")
                Label("Автор коммитов", systemImage: "person").frame(maxWidth: .infinity, alignment: .leading).padding(5).foregroundStyle(.white).background(theme.accent,in:RoundedRectangle(cornerRadius:6))
            }.font(.system(size: 11)).padding(8).frame(width: 214).background(theme.lane)
            VStack(alignment: .leading, spacing: 7) {
                Text("Автор коммитов").font(.system(size: 14, weight: .bold))
                Text("shop-api · хранится у демона на этом Маке, не в .kaban/").font(.system(size: 10.5)).foregroundStyle(theme.faint)
                ReferenceBox(title: "Имя и почта", theme: theme) {
                    HStack { Text("Имя").frame(width:70,alignment:.leading).foregroundStyle(theme.secondary); Text("Артём Палкин") }
                    HStack { Text("Почта").frame(width:70,alignment:.leading).foregroundStyle(theme.secondary); Text("artem@example.com").font(.system(size:11,design:.monospaced)) }
                    HStack { ReferenceButton(title:"Изменить…",small:true,theme:theme) { demo.route="identity-settings" }; Text("→ setProjectIdentity").font(.system(size:9.5,design:.monospaced)).foregroundStyle(theme.faint); Spacer(); ReferenceChip(title:"✓ с новых коммитов",theme:theme,tone:"done") }
                }.font(.system(size:12))
            }.padding(.horizontal,14).frame(maxWidth:.infinity)
        }.frame(height:198).background(theme.content,in:RoundedRectangle(cornerRadius:18)).clipShape(RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(theme.line,lineWidth:0.5))
    }
    private var miniWindow:some View{VStack(spacing:0){HStack{Text("● ● ●").foregroundStyle(theme.faint);Text("Kaban").font(.system(size:11.5,weight:.semibold));Spacer()}.padding(.horizontal,12).frame(height:30);HStack(alignment:.top,spacing:0){VStack(alignment:.leading,spacing:10){Text("Проекты").font(.system(size:10));Text("🐗 kaban\n🐙 mobile-app\n🦉 docs-site").font(.system(size:11)).lineSpacing(8);Spacer()}.padding(8).frame(width:118).background(theme.lane);VStack(spacing:10){ForEach(0..<2,id:\.self){_ in HStack(alignment:.top,spacing:8){ForEach([3,2,1,2],id:\.self){n in VStack(spacing:5){theme.line.frame(height:7);ForEach(0..<n,id:\.self){_ in RoundedRectangle(cornerRadius:8).fill(theme.card).frame(height:34)}}}}.padding(8).background(theme.lane,in:RoundedRectangle(cornerRadius:12))};Spacer()}.padding(12)}}.background(theme.content)}
}

struct ReferenceCardGallery:View {
    @Bindable var demo:ReferenceDemo
    let theme:ReferenceTheme
    let kind:String
    private var cards:[ReferenceTask]{
        if kind=="cards-suspicious" {return [demo.tasks.first{$0.id=="SHOP-52"}!,ReferenceTask(id:"KBN-23",title:"Подпись релизной сборки",status:"suspicious",label:"Подозрительные файлы: 1",meta:"13:10",files:["release.p12 · по шаблону *.p12"],project:"kaban"),ReferenceTask(id:"MOB-31",title:"Видео для экрана онбординга",status:"suspicious",label:"Подозрительные файлы: 1",meta:"12:40",files:["onboarding.mov · больше 5 МБ"],project:"mobile-app"),ReferenceTask(id:"DOC-12",title:"Скриншоты для гайда по API",status:"suspicious",label:"Подозрительные файлы: 5",meta:"11:05",files:["hero@3x.png · больше 5 МБ","flow-demo.gif · больше 5 МБ +3"],project:"docs-site"),demo.tasks.first{$0.id=="SHOP-29"}!,ReferenceTask(id:"MOB-33",title:"Конфиг staging для CI",status:"suspicious",label:"Подозрительные файлы: 1",meta:"10:22",files:[".env.staging · по шаблону .env*"],project:"mobile-app")]}
        if kind=="cards-bounce"{return [ReferenceTask(id:"SHOP-36",title:"Скидки по промокодам",status:"waiting",label:"Лимит возвратов",meta:"при конфликте, 2 из 2",stage:"Merge"),ReferenceTask(id:"KBN-21",title:"Проверка схемы API",status:"waiting",label:"Лимит возвратов",meta:"при красном гейте, 3 из 3",stage:"Checks",project:"kaban"),ReferenceTask(id:"SHOP-42",title:"Пагинация в /orders",status:"waiting",label:"Лимит возвратов",meta:"Test → Dev, 3 из 3"),ReferenceTask(id:"MOB-27",title:"Кэш запросов",status:"waiting",label:"Лимит возвратов",meta:"AI Review → Dev, 2 из 2",project:"mobile-app"),ReferenceTask(id:"SHOP-44",title:"Цены в копейках",status:"waiting",label:"Лимит возвратов",meta:"общий, 5 из 5"),ReferenceTask(id:"DOC-14",title:"Генератор документации",status:"waiting",label:"Лимит запусков на задачу",meta:"12 из 12",project:"docs-site")]}
        return ["queued","running","gating","retry","waiting","review","paused","blocked","incident","done","cancelled","conflict"].enumerated().map{i,status in ReferenceTask(id:"SHOP-\(42+i)",title:["Пагинация в /orders","Цены в копейках","Кэш каталога в Redis","Повтор вебхуков оплаты"][i%4],status:status,label:["В очереди","Работает","Гейты","Попытка 2/3","Вопрос агента","На ревью","На паузе","Заблокирована","Инцидент","Готово","Отменена","Возврат: конфликт"][i],meta:i==3 ? "повтор через 1:45":"12 мин",progress:status=="running" ? 55:nil)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16){Text(kind=="cards-suspicious" ? "Kaban v0.2.1 · подозрительные файлы":kind=="cards-bounce" ? "Kaban v0.2.1 · лимиты возвратов и запусков":kind=="cards-v02" ? "Kaban v0.2 · состояния карточек, модели и квота":"Kaban · карточка: все состояния").font(.system(size:kind=="cards-base" ? 26:22,weight:.bold));Text(kind=="cards-suspicious" ? "waiting_human · suspicious_files (UC-25, F29). Это не инцидент: refs не откатываются, в «Инциденты» и openIncidentCount не попадает, попытка не списывается. Карточка янтарная, но со своим значком — щит с восклицательным знаком.":"Цвет означает статус, проект узнаётся по маскоту и фактуре. Статус внизу карточки; максимум два бейджа. Красный — только инцидент безопасности.").font(.system(size:12)).foregroundStyle(theme.secondary)
            Text("Карточки · статус, причина, строки под заголовком").font(.system(size:13,weight:.bold))
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.top),count:6),alignment:.leading,spacing:16){ForEach(cards){task in VStack(alignment:.leading,spacing:6){ReferenceTaskCard(task:task,theme:theme,selected:task.id=="MOB-33" || task.id=="SHOP-36"){demo.selected=task.id;demo.route="board"};Text("\(task.status) · \(task.stage)\n\(task.meta.isEmpty ? "Подробности и действия — в панели задачи":task.meta)").font(.system(size:10.5)).foregroundStyle(theme.secondary)}}}
            if kind=="cards-suspicious" {Text("Жизненный цикл «Принять файлы»").font(.system(size:13,weight:.bold));HStack(alignment:.top,spacing:18){ForEach(["Показан","Отправлено…","taskUpdated","Ошибка / stale_suspicious_files"],id:\.self){s in ReferenceBox(title:s,theme:theme){ReferenceButton(title:s=="Отправлено…" ? s:"Принять файлы (3)",icon:"checkmark",primary:true,theme:theme){Task{await demo.acceptFiles(staleResponse:s.hasPrefix("Ошибка"))}}.disabled(s=="Отправлено…");Text(s=="taskUpdated" ? "Тот же commandId · набор пуст · задача в Test":"Карточка не меняется до authoritative события; ошибки возвращают доступность действия").font(.system(size:10.5)).foregroundStyle(theme.secondary)}}}}
            HStack(alignment:.top,spacing:28){ReferenceBox(title:"Лента",theme:theme){ForEach(["Найдены подозрительные файлы: 3 · suspiciousFilesFound","Файлы приняты человеком · suspiciousFilesAccepted","Перезапустить стадию · текущий набор принят","Замечание агенту · набор не принят","Повторная находка после гейтов","Проверка перед слиянием"],id:\.self){s in Text("⛨  \(s)").font(.system(size:11.5)).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).overlay(alignment:.bottom){theme.line.frame(height:0.5)}}};ReferenceBox(title:"Токен, значок и правила",theme:theme){HStack{Image(systemName:"exclamationmark.shield").font(.system(size:30)).foregroundStyle(theme.status("waiting").0);VStack(alignment:.leading){Text("suspicious_files = waiting_human").font(.system(size:12,weight:.semibold));Text("--st-suspicious → --st-waiting\nСвой значок; отдельного цвета нет").font(.system(size:11)).foregroundStyle(theme.secondary)}};Text("pattern  → по шаблону .env*\nsize        → больше 5 МБ\nдифф      → isText && size < max_file_mb\nиначе     → Показать в Finder").font(.system(size:11,design:.monospaced));Text("Лимит возвратов · при конфликте, 2 из 2\nЛимит возвратов · при красном гейте, 3 из 3\nЛимит запусков на задачу · 12 из 12").font(.system(size:11)).foregroundStyle(theme.secondary)}.frame(width:520)}
            if kind=="cards-v02" || kind=="cards-base" {Text("Флаги планировщика · флаги модели · модификаторы").font(.system(size:13,weight:.bold));HStack(spacing:12){ForEach(["Om исчерпан · 2 стадии","Cm исчерпан · 1 стадия","Нет данных · весь Мак","Opus 4.1 недоступен"],id:\.self){s in ReferenceBox(title:s,theme:theme){ReferenceQuotaBars(theme:theme,unknown:s.hasPrefix("Нет"))}}};ReferenceHardRules(theme:theme);LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:6),spacing:16){ForEach(cards){task in VStack(alignment:.leading,spacing:6){ReferenceTaskCard(task:task,theme:theme);Text("WIP-слот: \(["running","gating","retry"].contains(task.status) ? "занимает":"нет") · процесс: \(task.status=="running" ? "да":"нет")").font(.system(size:10.5)).foregroundStyle(theme.secondary)}}}}
            Spacer(minLength:0)
        }.padding(kind=="cards-base" ? 40:26).background(theme.content)
    }
}

/// Historical source sheets retain their own card fixtures and composition.
struct ReferenceHistoricalCards:View {
    @Bindable var demo:ReferenceDemo
    let theme:ReferenceTheme
    let version2:Bool
    private var grid:[GridItem]{Array(repeating:GridItem(.flexible(),alignment:.topLeading),count:6)}
    var body:some View {
        VStack(alignment:.leading,spacing:version2 ? 18:24){
            if version2 {Text("Kaban v0.2 · карточки, баннеры, плашки").font(.system(size:22,weight:.bold));lead("Новые состояния по журналу решений 3 окт, архитектуре v0.10.1 и спеке v0.7.1. Правила прежние: цвет карточки — только статус, проект — маскот и фактура края, не больше двух бейджей. Янтарный — нужно внимание, серый — спокойное ожидание; красный остаётся только у инцидентов безопасности. Флаги Мака и пулов — баннер над доской, флаги моделей — тонкий баннер и знак в шапке столбца; задачи под флагом остаются queued.")
                section("Карточки · статус · reason · подпись в статус-строке",tasks:Self.v02)
                Text("Баннеры над доской · один на флаг · текущие запуски доигрывают").font(.system(size:13,weight:.bold))
                VStack(spacing:6){flag("Пул · usage_exhausted: om","Om исчерпан · 2 стадии · до 17.10, 05:40","стоят стадии на моделях Om, composer-* работают","Сменить модель стадии…");flag("Пул · usage_exhausted: cm","Cm исчерпан · 1 стадия · до 17.10, 05:40","стоят стадии на composer-*, именные модели работают","Сменить модель стадии…");flag("Мак · usage_exhausted: unknown","Квота Cursor исчерпана до 01.11","неизвестно, какой пул: новые запуски не стартуют во всех проектах","Снять флаг");flag("Модель · unavailable","Opus 4.1 недоступен · 2 стадии","пропал из --list-models, задачи ждут в queued","Повторить пробу");flag("Модель · substituted","Cursor подменяет Opus 4.5 · 1 стадия","запрошена Opus 4.5, ответила Sonnet 4","Снять флаг")}
                HStack(alignment:.top,spacing:28){ReferenceBox(title:"Шапка дорожки · флаги проекта",theme:theme){projectFlag("🐗 kaban","Пайплайн не запустится: нет модели у Test, AI Review","Указать модели");lead("unavailable: pipeline_invalid — редактор открывается на первой стадии с ошибкой. Backlog принимает задачи.");projectFlag("🐙 mobile-app","Запуски остановлены: лишний MCP-сервер «jira»","Настройки MCP");lead("unavailable: mcp_unexpected — fail closed, CLI видит сервер вне собранного конфига.")};ReferenceBox(title:"Знак в шапке столбца · модель стадии и её пул",theme:theme){LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:6){ForEach(["Dev|1/3|composer-1 · Cm","Test|0/2|sonnet-4.5 · Om · исчерпан","AI Review|0/2|opus-4.5 · Om · подмена","Docs Review|0/1|opus-4.1 · недоступен","Test|0/2|нет модели","AI Review|0/1|auto — запрещено"],id:\.self){row in let parts=row.split(separator:"|");VStack(alignment:.leading,spacing:5){HStack{Text(parts[0]).bold();Spacer();Text(parts[1])};Text(parts[2]).font(.system(size:9.5,design:.monospaced)).foregroundStyle(row.hasPrefix("Dev") ? theme.faint:theme.status("waiting").2).frame(height:20)}.font(.system(size:11)).padding(7).background(theme.column,in:RoundedRectangle(cornerRadius:8))}};lead("Серая строка — модель и пул. Янтарь — стадия стоит и нужно решение. Серая рамка — модель недоступна, ждём пробу.")}}
                HStack(alignment:.top,spacing:28){ReferenceBox(title:"Строки ленты",theme:theme){feedRow("Остановлено: Cursor ответил не той моделью","запрошена Opus 4.5, ответила Sonnet 4 · запуск 7 · попытка не списана","15:12");feedRow("Модель не подтверждена","system/init нет в справочнике · запуск продолжен","13:40");feedRow("Состояние клона сохранено перед откатом","refs/kaban/wip/r-0412 · 7 файлов, +184 −22 · после краша","12:58")};ReferenceBox(title:"Виджет квоты · % израсходовано",theme:theme){HStack(alignment:.top,spacing:10){ForEach(0..<4){n in VStack(alignment:.leading,spacing:5){ReferenceQuotaBars(theme:theme,compact:true,unknown:n>=2,cm:n==3 ? nil:46,om:n==0 ? 62:n==1 ? 93:nil);lead(["Норма. Чёрточка — доля цикла; пунктир — порог.","Om ниже порога: стадии ждут queued.","Нет данных (nil, не 0%).","Токен протух — реактивная схема."][n])}}}}}
            } else {
                HStack(alignment:.top,spacing:32){VStack(alignment:.leading,spacing:8){Text("Kaban · карточка: все состояния").font(.system(size:26,weight:.bold));lead("Статус — единственный цвет карточки. Проект узнаётся по маскоту и фактуре края. Статус-строка внизу, максимум два бейджа; счётчики попыток и возвратов не смешиваются.");LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8){ForEach(["Спокойно","Активно","Внимание","Тревога"],id:\.self){level in HStack{RoundedRectangle(cornerRadius:5).fill(theme.status(level=="Активно" ? "running":level=="Внимание" ? "waiting":level=="Тревога" ? "incident":"queued").0).frame(width:26,height:18);VStack(alignment:.leading){Text(level).bold();Text(level=="Спокойно" ? "queued, paused, done, cancelled":level=="Активно" ? "running, gating, retry_wait":level=="Внимание" ? "waiting_human, blocked":"waiting_human · incident")}.font(.system(size:11))}.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(theme.card,in:RoundedRectangle(cornerRadius:10))}}};ReferenceBox(title:"Анатомия карточки",theme:theme){HStack(alignment:.top,spacing:20){ReferenceTaskCard(task:Self.active[5],theme:theme).frame(width:200);VStack(alignment:.leading,spacing:9){ForEach(Array(["Маскот + ID","Заголовок · до 2 строк","Бейджи · не больше двух","Статус внизу","Причина / время","Прогресс · тонкая линия"].enumerated()),id:\.offset){i,label in HStack{ReferenceChip(title:String(i+1),theme:theme);Text(label).font(.system(size:11))}}}}}.frame(width:500)}
                section("Активные и ожидающие запуска · WIP и процесс — разные счётчики",tasks:Self.active)
                section("Нужно решение человека · причина в статус-строке",tasks:Self.waiting)
                section("Спокойные состояния · не занимают слот и процесс",tasks:Self.calm)
                Text("Флаги планировщика · не перекрашивают карточки").font(.system(size:13,weight:.bold))
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:10){ForEach(["main грязный · merge не стартует","проект на паузе · текущие доигрывают","репозиторий недоступен · проект полупрозрачный","нет критерия готовности · Backlog","вопрос агента · ответ первым в очередь","ждёт WIP · Human Review 5/5","квота · повтор без списания попытки"],id:\.self){flag in HStack{Image(systemName:"info.circle");Text(flag);Spacer();ReferenceButton(title:"Подробнее",small:true,theme:theme){demo.notice="Демо: \(flag)"}}.font(.system(size:11.5)).padding(10).background(theme.lane,in:RoundedRectangle(cornerRadius:10))}}
                Text("Модификаторы · независимо от статуса").font(.system(size:13,weight:.bold))
                LazyVGrid(columns:grid,spacing:16){VStack{ReferenceChip(title:"Test",theme:theme);lead("Стадия — в режиме по типу стадии")};VStack{ReferenceTaskCard(task:Self.active[6],theme:theme,selected:true);lead("Выбрана · акцентная рамка")};VStack{ReferenceTaskCard(task:.init(id:"MOB-3",title:"Тёмная тема оплаты",project:"mobile-app"),theme:theme).rotationEffect(.degrees(-2.5));lead("Перетаскивание")};VStack(alignment:.leading){ForEach(["🦊 solid","🐗 diagonal","🐙 dots","🦉 cross"],id:\.self){Text($0).font(.system(size:12)).padding(6)};lead("Фактура проекта")};VStack{ReferenceTaskCard(task:Self.active[0],theme:theme).opacity(0.6);lead("Репозиторий недоступен")};VStack(alignment:.leading){lead("Приоритет бейджей");Text("1 возврат → 2 rebase → 3 git ×1 → 4 тег").font(.system(size:11));lead("Только первые два; полное — в панели задачи")}}
                Text("Токены статусов").font(.system(size:13,weight:.bold));HStack(spacing:8){ForEach(["queued","running","gating","retry","waiting","review","incident","paused","blocked","done","cancelled"],id:\.self){status in VStack(alignment:.leading,spacing:0){theme.status(status).0.frame(height:22);Text(status).font(.system(size:10,weight:.semibold)).foregroundStyle(theme.status(status).2).padding(6).frame(maxWidth:.infinity,alignment:.leading).background(theme.status(status).1);Text("--st-\(status)").font(.system(size:9,design:.monospaced)).padding(6)}.background(theme.card,in:RoundedRectangle(cornerRadius:8))}}
            }
            Spacer(minLength:0)
        }.padding(.horizontal,version2 ? 26:48).padding(.vertical,version2 ? 24:40).background(theme.content)
    }
    private func lead(_ text:String)->some View{Text(text).font(.system(size:version2 ? 10.5:11)).foregroundStyle(theme.secondary).fixedSize(horizontal:false,vertical:true)}
    private func section(_ title:String,tasks:[ReferenceTask])->some View{VStack(alignment:.leading,spacing:10){Text(title).font(.system(size:13,weight:.bold));LazyVGrid(columns:grid,alignment:.leading,spacing:16){ForEach(Array(tasks.enumerated()),id:\.offset){_,task in VStack(alignment:.leading,spacing:7){ReferenceTaskCard(task:task,theme:theme);lead("\(task.status) · \(task.meta.isEmpty ? task.label:task.meta)");HStack(spacing:4){ReferenceChip(title:"WIP: \(["running","gating","retry"].contains(task.status) ? "занимает":"нет")",theme:theme);ReferenceChip(title:"процесс: \(task.status=="running" ? "да":"нет")",theme:theme)}}}}}
    }
    private func flag(_ kind:String,_ title:String,_ detail:String,_ button:String)->some View{HStack(spacing:12){lead(kind).frame(width:150,alignment:.leading);HStack(spacing:7){Image(systemName:"hourglass");Text(title).bold();Text(detail).foregroundStyle(theme.secondary);Spacer(minLength:0);ReferenceButton(title:button,small:true,theme:theme){demo.flagsCleared.insert(kind)}}.font(.system(size:11)).padding(.horizontal,10).frame(height:30).background(theme.status("waiting").1,in:RoundedRectangle(cornerRadius:8))}.frame(maxWidth:1180)}
    private func projectFlag(_ name:String,_ text:String,_ button:String)->some View{HStack{Text(name).font(.system(size:12,weight:.semibold));Spacer();Text(text).font(.system(size:10.5)).foregroundStyle(theme.status("waiting").2);ReferenceButton(title:button,small:true,theme:theme){demo.route=name.contains("kaban") ? "pipeline-invalid":"project-mcp"}}}
    private func feedRow(_ title:String,_ detail:String,_ time:String)->some View{HStack(alignment:.top){Image(systemName:"info.circle").foregroundStyle(theme.faint);VStack(alignment:.leading,spacing:3){Text(title).font(.system(size:11.5,weight:.semibold));lead(detail)};Spacer();Text(time).font(.system(size:10)).foregroundStyle(theme.faint)}.padding(.vertical,6).overlay(alignment:.bottom){theme.line.frame(height:0.5)}}
    static let v02:[ReferenceTask]=[
        .init(id:"SHOP-44",title:"Цены в копейках во всём API",status:"retry",label:"Попытка 2/3",meta:"повтор через 1:45",badges:["gate_failed"]),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",status:"running",label:"Работает",meta:"12 мин",badges:["↩ 2/3"],progress:55),
        .init(id:"SHOP-47",title:"Импорт прайса из 1С",status:"waiting",label:"Лимит запусков",meta:"12/12",badges:["WIP сохранён"]),
        .init(id:"SHOP-35",title:"Кэш каталога в Redis",status:"waiting",label:"Подмена модели",meta:"15:12",badges:["Подмена: Opus 4.5 → Sonnet 4"]),
        .init(id:"SHOP-39",title:"Повтор вебхуков оплаты",label:"Ждёт квоту Om",meta:"сброс через 13д"),
        .init(id:"SHOP-34",title:"Логи запросов без PII",label:"На модели флаг",meta:"Opus 4.5")]
    static let active:[ReferenceTask]=[
        .init(id:"SHOP-58",title:"Экспорт заказов в CSV",meta:"#2",badges:["фича"]),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",meta:"возвращена ↑",badges:["↩ 1/3 · Test"]),
        .init(id:"KBN-13",title:"Менюбар: сводка очереди",meta:"ждёт места",badges:["Human Review 5/5"],project:"kaban"),
        .init(id:"SHOP-36",title:"Скидки по промокодам",meta:"возврат: конфликт",badges:["↩ конфликт 1/2","rebase"]),
        .init(id:"SHOP-61",title:"Rate limit на /auth/login",label:"Не запустится",meta:"нет критериев"),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",status:"running",label:"Работает",meta:"12 мин",badges:["↩ 1/3","opus-4.1"],progress:55),
        .init(id:"KBN-15",title:"Дорожки: закреплённые заголовки",status:"running",label:"Работает",meta:"21 мин",badges:["git ×1"],progress:70,project:"kaban"),
        .init(id:"SHOP-44",title:"Цены в копейках во всём API",status:"gating",label:"Гейты",meta:"Test 2/3",progress:66),
        .init(id:"SHOP-29",title:"Индексы для поиска по SKU",status:"gating",label:"Rebase + гейты",meta:"Merge #1",progress:40),
        .init(id:"SHOP-34",title:"Логи запросов без PII",status:"retry",label:"Попытка 2/3",meta:"повтор через 1:40",badges:["crash"]),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",status:"retry",label:"Ждёт квоту",meta:"до 16:40",badges:["rate_limit"]),
        .init(id:"KBN-15",title:"Дорожки: закреплённые заголовки",status:"retry",label:"Cursor недоступен",meta:"runner_auth",project:"kaban")]
    static let waiting:[ReferenceTask]=[
        .init(id:"SHOP-35",title:"Кэш каталога в Redis",status:"waiting",label:"Вопрос агента",meta:"18 мин",badges:["Human"]),
        .init(id:"SHOP-31",title:"Слияние гостевой корзины",status:"review",label:"На ревью",meta:"+128 −40",badges:["гейты ✓","6 файлов"]),
        .init(id:"SHOP-31",title:"Слияние гостевой корзины",status:"review",label:"После конфликта",meta:"+142 −40",badges:["Δ 2"]),
        .init(id:"SHOP-40",title:"Валидация адреса доставки",status:"waiting",label:"Попытки исчерпаны",meta:"3/3 · stall 10 мин"),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",status:"waiting",label:"Лимит возвратов",meta:"Test → Dev 3/3",badges:["всего 5/5"]),
        .init(id:"SHOP-36",title:"Скидки по промокодам",status:"conflict",label:"Лимит конфликтов",meta:"2/2"),
        .init(id:"KBN-18",title:"Ротация логов демона",status:"waiting",label:"Git-политика",meta:"отказов 5/5",project:"kaban"),
        .init(id:"KBN-17",title:"Обёртка git: белый список флагов",status:"incident",label:"Инцидент",meta:"main откатан",project:"kaban"),
        .init(id:"KBN-12",title:"Read-only для AI Review",status:"waiting",label:"Результат не принят",meta:"изменения откатаны",project:"kaban")]
    static let calm:[ReferenceTask]=[
        .init(id:"MOB-9",title:"Тёмная тема оплаты",status:"paused",label:"На паузе",meta:"сессия сохранена",project:"mobile-app"),
        .init(id:"SHOP-30",title:"Удаление старой корзины",status:"blocked",label:"Заблокирована",meta:"main грязный"),
        .init(id:"SHOP-27",title:"Health-check для балансировщика",status:"done",label:"Готово",meta:"14:05 · main"),
        .init(id:"SHOP-25",title:"GraphQL для каталога",status:"cancelled",label:"Отменена",meta:"вчера")]
}
