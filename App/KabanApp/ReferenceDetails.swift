import SwiftUI

struct ReferenceDetails: View {
    @Bindable var demo: ReferenceDemo
    let theme: ReferenceTheme
    var kind = "suspicious"
    var selectedTaskID: String? = nil
    var nativeContainer = false
    private var runtimeTask:ReferenceTask? {selectedTaskID.flatMap {id in demo.tasks.first{$0.id==id}}}
    private var isSuspicious: Bool { kind == "suspicious" || kind == "stale" || kind == "gate" || kind == "merge" }
    private var taskID: String {runtimeTask?.id ?? (kind=="incident" ? "KBN-17" : kind=="review" ? "SHOP-31" : kind=="substituted" ? "SHOP-35" : kind=="run-limit" ? "SHOP-47" : kind=="gate" ? "SHOP-55" : kind=="merge" ? "SHOP-29" : "SHOP-52")}
    private var title: String {runtimeTask?.title ?? (kind=="incident" ? "Обёртка git: белый список флагов" : kind=="review" ? "Слияние гостевой корзины" : kind=="substituted" ? "Кэш каталога в Redis" : kind=="run-limit" ? "Импорт прайса из 1С" : kind=="gate" ? "Экспорт заказов в CSV" : kind=="merge" ? "Индексы для поиска по SKU" : "Интеграция платёжного шлюза")}
    private var stage:String {runtimeTask?.stage ?? (kind=="review" ? "Human Review" : kind=="substituted" ? "AI Review" : kind=="gate" ? "Checks" : kind=="merge" ? "Merge" : "Dev")}
    private var runLabel:String {kind=="incident" ? "попытка 2 из 3" : kind=="substituted" ? "запуск 7" : kind=="run-limit" ? "запуски 12/12" : "запуск 4"}
    private var modelLabel:String {kind=="incident" ? "gpt-5" : kind=="substituted" ? "opus-4.5  Om" : "composer-1  Cm"}
    private var branch:String { if let runtimeTask, kind == "generic" { return "kaban/" + runtimeTask.id.lowercased() }; return kind=="incident" ? "kaban/17-git-shim-flags" : kind=="substituted" ? "kaban/shop-35-redis-cache" : kind=="run-limit" ? "kaban/shop-47-price-import" : kind=="gate" ? "kaban/shop-55-orders-csv" : kind=="merge" ? "kaban/shop-29-sku-index" : "kaban/shop-52-payment-gateway"}
    private var pathStages:[String] {kind=="incident" ? ["Backlog","Dev","Lint","AI Review","Human Review","Merge","Done"] : kind=="gate" ? ["Backlog","Dev","Test","Checks","AI Review","Human Review","Merge","Done"] : ReferenceDemo.stages}
    private var tone: String {runtimeTask?.status ?? (kind=="incident" ? "incident" : kind=="review" ? "review" : "waiting")}
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            header
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if kind == "generic" || (runtimeTask != nil && !["suspicious","waiting","incident","review"].contains(runtimeTask!.status)) {genericTaskBlock}
                    else if isSuspicious { suspiciousBlock }
                    else if kind=="incident" { incidentBlock }
                    else if kind=="review" { reviewBlock }
                    else if kind=="substituted" { modelBlock }
                    else { runLimitBlock }
                }.padding(.horizontal,16).padding(.top,12)
            }.scrollIndicators(.hidden).frame(height:isSuspicious ? 452 : kind=="incident" ? 242 : kind=="review" ? 208 : kind=="run-limit" ? 410 : 346)
            Picker("Сведения о задаче", selection: $demo.logTab) {
                ForEach(kind == "incident" ? ["Лента", "Живой лог", "Сводка", "Попытки", "Разрешения git"] : ["Лента", "Живой лог", "Сводка", kind == "run-limit" ? "Запуски" : "Попытки"], id: \.self) { tab in Text(tab).tag(tab) }
            }.pickerStyle(.segmented).controlSize(.small).padding(12)
            ScrollView {
                VStack(spacing:0) {
                    if demo.logTab=="Лента" { feed }
                    else if demo.logTab=="Живой лог" {Text("14:52 system: stage completed\n14:52 git diff --numstat\n14:52 suspicious files found\n14:53 waiting for human").font(.system(size:11,design:.monospaced)).foregroundStyle(theme.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(12)}
                    else if demo.logTab=="Сводка" {Text(kind == "generic" ? "\(taskID) · \(title)\nСтадия: \(stage) · \(runtimeTask?.label ?? "В очереди")\n\(demo.taskBodies[taskID] ?? "Описание пока пустое")" : "Добавлена интеграция платёжного шлюза. Гейты пройдены: npm test ✓ (318), eslint ✓. Изменения: +412 −36. Требуется решение человека.").font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading).padding(12)}
                    else {ForEach(1...4,id:\.self){run in event("Запуск Dev · \(run)",detail:"composer-1 · \(run==4 ? "остановлен для человека" : "завершён")",time:"14:22",symbol:"play",tone:nil)}}
                }.padding(.horizontal,16).padding(.top,4)
            }.scrollIndicators(.hidden)
            if !["gate", "merge"].contains(kind) {
            HStack(spacing:8) {
                Label("Замечание агенту",systemImage:"message").font(.system(size:12,weight:.semibold)).foregroundStyle(theme.text)
                TextField(isSuspicious ? "«Попросить убрать» подставит: «Убери из ветки…»" : "Напишите замечание агенту…",text:$demo.returnNote).textFieldStyle(.roundedBorder).font(.system(size:12))
                ReferenceButton(title:"Отправить и продолжить",primary:true,small:true,theme:theme){demo.action("Отправить замечание",taskID:taskID)}.disabled(demo.returnNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal,10).frame(height:38).background(theme.card,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(theme.line,lineWidth:0.5)).padding(12)
            }
        }.foregroundStyle(theme.text)
            .background(nativeContainer ? Color(nsColor: .windowBackgroundColor) : theme.content)

    }
    private var header: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:8) {
                ReferenceMascot(emoji:runtimeTask?.emoji ?? (kind=="incident" ? "🐗" : "🦊"),theme:theme,state:tone,size:22)
                Text(taskID).font(.system(size:11.5,design:.monospaced)).foregroundStyle(theme.secondary)
                Text("\(runtimeTask?.project ?? (kind=="incident" ? "kaban" : "shop-api")) · \(stage)").font(.system(size:11.5)).foregroundStyle(theme.faint)
                Spacer();ReferenceButton(title:"Открыть в Cursor",icon:"arrow.up.right.square",theme:theme){demo.action("Открыть в Cursor")}
                Menu {
                    Button("Изменить…") { demo.selected = taskID; demo.editSelected() }
                    Button("Перенести…") { demo.selected = taskID; demo.sheet = "move" }
                    Button("Отменить…") { demo.selected = taskID; demo.sheet = "cancel" }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                Button{demo.selected=nil;demo.inspectedFrame=nil;demo.route="board"}label:{Image(systemName:"xmark")}.buttonStyle(.borderless)
            }
            Text(title).font(.system(size:18,weight:.bold)).tracking(-0.25)
            ReferenceFlow(spacing: 6) {
                Label(statusLabel, systemImage: statusSymbol).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20)
                    .foregroundStyle(kind == "generic" ? theme.status(tone).2 : theme.dark && !["incident","review"].contains(kind) ? Color(hex:0x1c1c1f) : .white)
                    .background(kind == "generic" ? theme.status(tone).1 : theme.status(tone).0, in: RoundedRectangle(cornerRadius: 6))
                ReferenceChip(title: "▷ \(runLabel)", theme: theme)
                ReferenceChip(title: "♧ \(modelLabel)", theme: theme)
                ReferenceChip(title: "⑂ \(branch)", theme: theme, mono: true)
            }
            HStack(spacing:3) {
                ForEach(Array(pathStages.enumerated()),id:\.offset) { index,stageName in
                    Text(stageName).font(.system(size:10.5,weight:.semibold)).padding(.horizontal,7).padding(.vertical,2).foregroundStyle(index==0 ? theme.status("done").2 : stage==stageName ? .white : theme.faint).background(index==0 ? theme.status("done").1 : stage==stageName ? theme.status(tone).0 : theme.control,in:RoundedRectangle(cornerRadius:5))
                    if index<pathStages.count-1 {Image(systemName:"chevron.right").font(.system(size:8)).foregroundStyle(theme.faint)}
                }
            }.padding(.top,2)
        }.padding(.init(top:14,leading:16,bottom:10,trailing:16)).overlay(alignment:.bottom){theme.line.frame(height:0.5)}
    }
    private var statusLabel: String {
        if kind == "generic" { return runtimeTask?.label ?? "В очереди" }
        return "waiting_human · " + (kind == "incident" ? "incident" : kind == "review" ? "review" : kind == "substituted" ? "model_substituted" : kind == "run-limit" ? "run_limit" : "suspicious_files")
    }
    private var statusSymbol: String { kind == "incident" ? "light.beacon.max" : kind == "review" ? "person.crop.circle.badge.checkmark" : isSuspicious ? "exclamationmark.shield" : "hand.raised" }
    private var genericTaskBlock:some View {
        ReferenceBox(title:"Описание и критерии приёмки",theme:theme){
            Text(demo.taskBodies[taskID] ?? "Описание пока пустое").font(.system(size:12)).textSelection(.enabled)
            HStack{ReferenceButton(title:"Изменить…",theme:theme){demo.selected=taskID;demo.draftTitle=title;demo.draftBody=demo.taskBodies[taskID] ?? "";demo.sheet="edit"};ReferenceButton(title:"Перенести…",theme:theme){demo.selected=taskID;demo.sheet="move"};ReferenceButton(title:"Отменить…",theme:theme){demo.selected=taskID;demo.sheet="cancel"}}
            if runtimeTask?.status=="running" {ReferenceButton(title:"Пауза",theme:theme){demo.action("Пауза",taskID:taskID)}}
            else if runtimeTask?.status=="paused" {ReferenceButton(title:"Продолжить",theme:theme){demo.action("Продолжить",taskID:taskID)}}
        }
    }
    private var suspiciousBlock: some View {
        let stale = kind=="stale" || demo.staleTaskIDs.contains(taskID)
        return VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7) {Image(systemName:"exclamationmark.shield");Text(demo.acceptedTaskIDs.contains(taskID) ? "Файлы приняты" : "В ветке подозрительные файлы: \(fileCount)").bold();Spacer();Text(stale ? "набор обновлён 15:03 · запуск 4" : "14:52 · после гейтов Dev · запуск 4").font(.system(size:10.5))}.font(.system(size:12.5)).padding(.horizontal,12).frame(height:32).foregroundStyle(theme.status("waiting").2).background(theme.status("waiting").1)
            VStack(alignment:.leading,spacing:7) {
                if stale {
                    HStack(alignment:.top,spacing:9){Image(systemName:"info.circle").foregroundStyle(theme.status("waiting").0);Text("Набор файлов изменился — ничего не принято. Пока вы смотрели, ветка изменилась (правка в клоне, другое окно или CLI), и демон ответил stale_suspicious_files. Список перечитан через getTaskDetail: убран .env.local, изменён orders-dump.sql (новый blob), новый .env.seed. Проверьте его и примите ещё раз.").font(.system(size:11)).foregroundStyle(theme.secondary)}.padding(10).background(theme.status("waiting").1.opacity(0.55),in:RoundedRectangle(cornerRadius:10))
                } else {Label("Весь diff ветки от базы main@a41c9e2 · не инцидент, refs не откатывались · попытка не списана",systemImage:"info.circle").font(.system(size:10.5)).foregroundStyle(theme.faint).lineLimit(1)}
                ReferenceFileTable(theme:theme,stale:stale,accepted:demo.acceptedTaskIDs.contains(taskID),taskID:taskID,
                    action: { path, reveal in demo.openSampleFile(path, reveal:reveal) },
                    exceptions: { demo.openSettings("suspicious-settings",project:runtimeTask?.project ?? demo.selectedProject) })
                HStack(alignment:.center,spacing:10) {
                    ReferenceButton(title:demo.pending.contains("files:" + taskID) ? "Отправлено…" : "Принять файлы (\(fileCount))",icon:"checkmark",primary:true,theme:theme){Task{await demo.acceptFiles(taskID:taskID)}}.disabled(demo.pending.contains("files:" + taskID) || demo.acceptedTaskIDs.contains(taskID)).frame(width:154,alignment:.leading)
                    Text("Примет ровно эти \(fileCount) файла (acceptSuspiciousFiles). Kaban сразу перепроверит ветку и продолжит \(stage) → \(stage == "Merge" ? "Done" : stage == "Checks" ? "AI Review" : "Test") без нового запуска агента; попытка не списывается.").font(.system(size:10.5)).foregroundStyle(theme.secondary)
                }
                HStack(alignment:.center,spacing:10) {
                    ReferenceButton(title: ["gate", "merge"].contains(kind) ? "Вернуть…" : "Попросить убрать", icon: "message", theme: theme) {
                        demo.selected = taskID
                        if ["gate", "merge"].contains(kind) { demo.presentReturn(merge: kind == "merge") }
                        else { demo.returnNote = "Убери из ветки: .env.local, certs/stripe-test.pem, fixtures/orders-dump.sql" }
                    }.frame(width:154,alignment:.leading)
                    Text("Набор не принимается. Замечание агенту (answerHuman) → новый запуск Dev; после его гейтов проверка заново. На gate/merge — «Вернуть с замечанием» (requestChanges), тоже без принятия.").font(.system(size:10.5)).foregroundStyle(theme.secondary)
                }
                theme.line.frame(height:0.5)
                Label("Эти действия тоже примут текущий набор — изменённый или новый файл сработает снова:",systemImage:"info.circle").font(.system(size:10.5)).foregroundStyle(theme.secondary)
                HStack(spacing:5) {
                    ReferenceButton(title:"Перезапустить",icon:"arrow.clockwise",small:true,theme:theme){demo.action("Перезапустить",taskID:taskID)}
                    ReferenceButton(title:"В Backlog",icon:"tray",small:true,theme:theme){demo.action("В Backlog",taskID:taskID)}
                    ReferenceButton(title:"Отменить…",icon:"xmark",small:true,theme:theme){demo.selected = taskID; demo.sheet="cancel"}
                    Toggle("Сохранить ветку → kaban/archive/\(taskID)",isOn:$demo.keepBranch).toggleStyle(.checkbox).font(.system(size:10.5)).lineLimit(1)
                }
                Text("retryStage · moveTask · cancelTask(keepBranch) · «Отклонить» — только в Human Review").font(.system(size:9.5,design:.monospaced)).foregroundStyle(theme.faint)
                theme.line.frame(height:0.5)
                HStack {Label("Принятые ранее  2",systemImage:"clock.arrow.circlepath").font(.system(size:11,weight:.semibold));Spacer();Text("TaskDetail.acceptedFiles · повторно не срабатывают, пока не изменятся").font(.system(size:10)).lineLimit(1).foregroundStyle(theme.faint)}
                acceptedRow("docs/payment-flow.pdf",blob:"52e1a90",time:"3 окт, 18:20")
                acceptedRow(".env.test",blob:"0b77f3d",time:"3 окт, 18:21")
            }.padding(12)
        }.background(theme.card,in:RoundedRectangle(cornerRadius:12)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(theme.status("waiting").0.opacity(0.65),lineWidth:0.8))
    }
    private func acceptedRow(_ path:String,blob:String,time:String)->some View {HStack(spacing:8){Image(systemName:"checkmark").foregroundStyle(theme.status("done").0).frame(width:14);Text(path).font(.system(size:10.5,design:.monospaced));Spacer();Text(blob).font(.system(size:10,design:.monospaced)).foregroundStyle(theme.faint).frame(width:66);Text("вы").font(.system(size:11));Text(time).font(.system(size:11)).foregroundStyle(theme.faint).frame(width:92)}.frame(height:17)}
    private var incidentBlock: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack{Label("Инцидент: агент сдвинул main",systemImage:"light.beacon.max").bold();Spacer();Text("Открыт 14:32 · high").font(.system(size:10.5))}.foregroundStyle(.white).padding(10).background(theme.status("incident").0)
            VStack(alignment:.leading,spacing:6){
            Text("Refs изменены в обход обёртки git. Демон откатил их и остановил задачу; отправлено уведомление высокого приоритета.").font(.system(size:11.5))
            Text("Изменено   refs/heads/main · a41c9e2 → 7f90b31\nОткат       a41c9e2 · демон, 14:32\nЗапуск      Dev · попытка 2 · 14:21–14:32\nОбход       git update-ref · запись вне обёртки").font(.system(size:11,design:.monospaced)).foregroundStyle(theme.secondary)
            HStack(spacing:6){ReferenceButton(title:"Вернуть с замечанием",icon:"message",primary:true,theme:theme){demo.sheet="move"};ReferenceButton(title:"Модель",icon:"cpu",theme:theme){demo.route="pipeline-invalid"};ReferenceButton(title:"Ужесточить политику",icon:"shield",theme:theme){demo.route="stage-git"};ReferenceButton(title:"Отменить…",icon:"xmark",theme:theme){demo.sheet="cancel"}}
            VStack(alignment:.leading,spacing:6){HStack{Text("Отменить задачу?").font(.system(size:12,weight:.bold));Text("клон удаляется, задача → cancelled").font(.system(size:11)).foregroundStyle(theme.faint);Spacer();ReferenceButton(title:"Не отменять",small:true,theme:theme){demo.sheet=nil};Button("Отменить задачу"){demo.action("Отменить",taskID:taskID)}.buttonStyle(.borderedProminent).tint(theme.status("incident").0).controlSize(.small)};HStack{Toggle("Сохранить ветку → kaban/archive/KBN-17",isOn:$demo.keepBranch).toggleStyle(.checkbox).font(.system(size:10.5));Spacer()}}.padding(8).background(theme.card,in:RoundedRectangle(cornerRadius:8))
        }.padding(12)
        }.background(theme.status("incident").1,in:RoundedRectangle(cornerRadius:12)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(theme.status("incident").0,lineWidth:1.5))
    }
    private var reviewBlock: some View {
        ReferenceBox(title:"Human Review · после конфликта",theme:theme) {
            Text("Изменено при разрешении конфликта").font(.system(size:12,weight:.semibold))
            Text("src/cart/merge.ts                 +48 −12\nsrc/cart/guest.ts                  +21 −8\ntests/cart-merge.test.ts            +59 −20").font(.system(size:11,design:.monospaced)).foregroundStyle(theme.secondary)
            Text("Гейты зелёные · npm test ✓ · eslint ✓").font(.system(size:11)).foregroundStyle(theme.status("done").2)
            HStack {ReferenceButton(title:"Принять",icon:"checkmark",primary:true,theme:theme){demo.action("Принять",taskID:taskID)};ReferenceButton(title:"Вернуть с замечанием",icon:"arrow.uturn.backward",theme:theme){demo.selected = taskID; demo.returnNote = ""; demo.returnTarget = "Dev"; demo.sheet = "review-return"};ReferenceButton(title:"Отклонить…",icon:"xmark",theme:theme){demo.sheet="reject"}}
            Text("Слияние выполнит демон. Просмотрите diff ветки от main.").font(.system(size:11)).foregroundStyle(theme.faint)
        }
    }
    private var modelBlock: some View {
        ReferenceBox(title:"Остановлено: Cursor ответил не той моделью · 15:12",theme:theme) {
            HStack(spacing:10){ReferenceBox(title:"Запрошена",theme:theme){Text("Opus 4.5").font(.system(size:15,weight:.bold));Text("opus-4.5 · Om\nстадия AI Review · старт 15:12:03").font(.system(size:10.5,design:.monospaced)).foregroundStyle(theme.faint)};ReferenceBox(title:"Ответила",theme:theme){Text("Sonnet 4").font(.system(size:15,weight:.bold));Text("sonnet-4 · system/init\nClaude Sonnet 4 · fallbackModel: sonnet-4").font(.system(size:10.5,design:.monospaced)).foregroundStyle(theme.status("waiting").2)}}
            Text("✓ Процесс остановлен до первого вызова инструмента\n✓ Клон чистый — откатывать нечего\n✓ Попытка не списана\n✓ Запуск не входит в max_runs_per_task\n✓ Результат не принят").font(.system(size:11)).foregroundStyle(theme.secondary).lineSpacing(3)
            HStack{ReferenceButton(title:"Лог запуска 7",icon:"terminal",small:true,theme:theme){demo.logTab="Живой лог"};ReferenceChip(title:"model_substituted",theme:theme,tone:"waiting",mono:true);Spacer()}
            HStack{ReferenceButton(title:"Повторить",icon:"arrow.clockwise",primary:true,theme:theme){demo.action("Повторить",taskID:taskID)};ReferenceButton(title:"Другая модель",icon:"cpu",theme:theme){demo.route="pipeline-invalid"};ReferenceButton(title:"В Backlog",icon:"tray",theme:theme){demo.action("В Backlog",taskID:taskID)}}
            HStack{Text("На Opus 4.5 флаг · ещё 1 задача ждёт в queued").font(.system(size:11));Spacer();ReferenceButton(title:"Снять флаг",small:true,theme:theme){demo.flagsCleared.insert("substituted")}}
        }
    }
    private var runLimitBlock: some View {
        ReferenceBox(title:"Лимит автоматических запусков: 12 из 12 · 14:58",theme:theme) {
            Text("max_runs_per_task · автостарт остановлен. Любое ручное действие сбросит счётчик; текущий WIP сохранён перед откатом.").font(.system(size:11)).foregroundStyle(theme.secondary)
            HStack(spacing:3){ForEach(0..<12){i in RoundedRectangle(cornerRadius:3).fill(theme.status(i<7 ? "running":i<10 ? "gating":"review").0).frame(height:9)}}
            HStack{Text("Dev ×7   Test ×3   AI Review ×2");Spacer();Text("12 / 12").bold()}.font(.system(size:10.5)).foregroundStyle(theme.faint)
            Text("Не считаются: rate_limit, недоступный runner, подмена модели, перезапуск демона.").font(.system(size:10.5)).foregroundStyle(theme.faint)
            VStack(spacing:0){ForEach(["12|Dev|2/3|crash · WIP сохранён|14:57","11|Dev|1/3|stall · 10 мин|14:41","10|Test|1/3|возврат Dev ↩3/3 · пустой артикул|14:22","9|Dev|1/3|завершён · гейты зелёные|14:05"],id:\.self){row in let parts=row.split(separator:"|");HStack{ForEach(Array(parts.enumerated()),id:\.offset){i,text in Text(text).font(.system(size:10.5,design:i==0 ? .monospaced:.default)).frame(maxWidth:i==3 ? .infinity:nil,alignment:.leading)}}.padding(.vertical,5).overlay(alignment:.bottom){theme.line.frame(height:0.5)}}}
            Text("refs/kaban/wip/r-0412 · 7 файлов · +184 −22").font(.system(size:10.5,design:.monospaced))
            Text("Sources/Import/PriceParser.swift       +121 −9\nSources/Import/OneCClient.swift         +48 −13\nTests/PriceImportTests.swift            +15\nещё 4 файла").font(.system(size:10,design:.monospaced)).foregroundStyle(theme.secondary)
            HStack{ReferenceButton(title:"Восстановить в клон",small:true,theme:theme){demo.action("Восстановить WIP",taskID:taskID)};ReferenceButton(title:"Дифф",small:true,theme:theme){demo.sheet="diff"};Spacer()}
            HStack{ReferenceButton(title:"Перезапустить стадию",primary:true,theme:theme){demo.action("Перезапустить",taskID:taskID)};ReferenceButton(title:"Модель",theme:theme){demo.route="pipeline-invalid"};ReferenceButton(title:"В Backlog",theme:theme){demo.action("В Backlog",taskID:taskID)};ReferenceButton(title:"Отменить…",theme:theme){demo.sheet="cancel"}}
            Text("Любое действие сбросит 12 → 0. Ручной запуск не восстановит старый running.").font(.system(size:10.5)).foregroundStyle(theme.faint)
        }
    }
    private var fileCount: Int { taskID == "SHOP-29" ? 1 : taskID == "SHOP-55" ? 2 : 3 }
    @ViewBuilder private var feed: some View {
        if kind == "generic" {
            ForEach(Array((demo.taskNotes[taskID] ?? []).enumerated()), id: \.offset) { _, note in event("Замечание человека", detail: note, time: "сейчас", symbol: "message", tone: nil) }
            event(runtimeTask?.label ?? "В очереди", detail: "\(stage) · \(title)", time: "сейчас", symbol: "clock", tone: nil)
        } else if kind=="incident" {
            HStack(spacing:4){Image(systemName:"nosign");Text("Отказы git за запуск: 4/5").font(.system(size:11.5,weight:.semibold));ForEach(0..<5){i in RoundedRectangle(cornerRadius:2).fill(i<4 ? theme.status("waiting").0:theme.control).frame(width:16,height:6)};Spacer();Text("На 5-м — стоп: waiting_human · git_denials").font(.system(size:10.5)).foregroundStyle(theme.faint)}.padding(8).background(theme.control,in:RoundedRectangle(cornerRadius:9))
            event("Обход обёртки: git update-ref refs/heads/main",detail:"tool_call · refs изменены; main откатан, запуск остановлен",time:"14:31",symbol:"light.beacon.max",tone:"incident")
            event("Отказ 4: rebase main",detail:"политика стадии · нужен человек",time:"14:29",symbol:"nosign",tone:"waiting")
            HStack{ReferenceButton(title:"Разрешить один раз",icon:"key",small:true,theme:theme){demo.action("Разрешить git ×1",taskID:taskID)};ReferenceButton(title:"Добавить в политику",small:true,theme:theme){demo.route="stage-git"}}.padding(.vertical,5)
            event("Отказ 3: push origin main",detail:"hard_invariant: push · всегда запрещено, разрешение недоступно",time:"14:28",symbol:"lock",tone:nil)
            event("Отказ 2: git stash",detail:"Dev · обёртка git · нет в списке разрешённых · отказ 2 из 5",time:"14:25",symbol:"key",tone:nil)
            VStack(alignment:.leading,spacing:4){Text("● Разрешено один раз · вы, 14:26       gitGrantCreated");Text("● Агент узнал · в ответе MCP, 14:27     gitGrantDelivered");Text("● Использовано · повтор прошёл, 14:27  gitGrantConsumed")}.font(.system(size:10.5)).foregroundStyle(theme.status("done").2).padding(.leading,34).padding(.vertical,4)
            event("Отказ 1: checkout main",detail:"отказ политики · разовое разрешение до конца задачи",time:"14:23",symbol:"nosign",tone:nil)
            event("Запуск Dev · попытка 2",detail:"gpt-5 · прогрев .build 2,1 с",time:"14:21",symbol:"play",tone:nil)
        } else if kind=="substituted" {
            event("Подмена модели: Opus 4.5 → Sonnet 4",detail:"model_substituted · остановлено до инструментов · попытка не списана",time:"15:12",symbol:"exclamationmark.triangle",tone:"waiting")
            event("Запуск AI Review · запуск 7",detail:"cursor-agent --model opus-4.5 · Om",time:"15:12",symbol:"play",tone:nil)
            event("Dev завершена · гейты зелёные",detail:"+96 −14 · swift build ✓ · swift test ✓ (212)",time:"15:09",symbol:"checkmark",tone:nil)
            event("Модель не подтверждена",detail:"model_unconfirmed · composer-preview · неизвестна в справочнике",time:"14:31",symbol:"info.circle",tone:nil)
            event("Запуск Dev · запуск 6",detail:"composer-1 · клон задачи",time:"14:31",symbol:"play",tone:nil)
        } else if kind=="run-limit" {
            event("Лимит запусков на задачу: 12 из 12",detail:"max_runs_per_task · автостарт остановлен",time:"14:58",symbol:"hand.raised",tone:"waiting")
            event("Состояние клона сохранено перед откатом",detail:"refs/kaban/wip/r-0412 · 7 файлов, +184 −22",time:"14:57",symbol:"clock.arrow.circlepath",tone:nil)
            event("Запуск Dev завершился с ошибкой",detail:"crash · попытка 2/3 · клон откатан к последнему checkpoint",time:"14:57",symbol:"xmark",tone:nil)
        } else {
            event(isSuspicious ? "Найдены подозрительные файлы: \(fileCount)  suspiciousFilesFound" : kind=="review" ? "Требуется Human Review · после конфликта" : kind=="substituted" ? "Подмена модели: Opus 4.5 → Sonnet 4" : "Лимит запусков на задачу, 12 из 12",detail:"после гейтов Dev, запуск 4 · переход Dev → Test остановлен · не инцидент, попытка не списана",time:"14:52",symbol:isSuspicious ? "exclamationmark.shield" : "info.circle",tone:"waiting")
            event("Dev завершена · гейты зелёные",detail:"complete_stage · npm test ✓ (318) · eslint ✓ · +412 −36",time:"14:51",symbol:"checkmark",tone:nil)
            event("Запуск Dev · запуск 4",detail:"cursor-agent --model composer-1 · ↩ из Test: «нет теста на отказ 3-D Secure»",time:"14:22",symbol:"play",tone:nil)
            if kind=="substituted" {event("Модель не подтверждена",detail:"model_unconfirmed · CLI не сообщил model",time:"14:21",symbol:"info.circle",tone:nil)}
        }
    }
    private func event(_ title:String,detail:String,time:String,symbol:String,tone:String?)->some View {
        HStack(alignment:.top,spacing:8){Image(systemName:symbol).font(.system(size:12)).frame(width:22,height:22).foregroundStyle(tone.map{theme.status($0).0} ?? theme.faint).background(tone.map{theme.status($0).1} ?? theme.control,in:RoundedRectangle(cornerRadius:7));VStack(alignment:.leading,spacing:2){Text(title).font(.system(size:12,weight:tone==nil ? .regular:.semibold)).foregroundStyle(tone.map{theme.status($0).2} ?? theme.text);Text(detail).font(.system(size:11)).foregroundStyle(theme.faint)};Spacer(minLength:0);Text(time).font(.system(size:10.5)).foregroundStyle(theme.faint).frame(width:40)}.padding(.vertical,6).overlay(alignment:.bottom){theme.line.frame(height:0.5)}
    }
}

struct ReferenceFileTable: View {
    let theme: ReferenceTheme
    var stale = false
    var accepted = false
    var taskID = "SHOP-52"
    var action: (String, Bool) -> Void = { _, _ in }
    var exceptions: () -> Void = {}
    private var rows: [(String,String,String,Bool)] {
        if taskID == "SHOP-29" { return [("seed-sku.sql", "6,8 МБ", "больше 5 МБ", true)] }
        if taskID == "SHOP-55" { return [("fixtures/orders-dump.sql", "12,4 МБ", "больше 5 МБ", true), (".env.local", "412 Б", "по шаблону .env*", false)] }
        return stale ? [("certs/stripe-test.pem","3,2 КБ","по шаблону *.pem",false),("fixtures/orders-dump.sql  изменён","9,8 МБ","больше 5 МБ",true),("scripts/seed/.env.seed  новый","268 Б","по шаблону .env*",false)] : [(".env.local","412 Б","по шаблону .env*",false),("certs/stripe-test.pem","3,2 КБ","по шаблону *.pem",false),("fixtures/orders-dump.sql","12,4 МБ","больше 5 МБ",true)]
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:8){Text("Файл · весь diff ветки от базы").frame(maxWidth:.infinity,alignment:.leading);Text("Размер").frame(width:58,alignment:.trailing);Text("Правило").frame(width:128,alignment:.leading);Text("").frame(width:104)}.font(.system(size:10,weight:.semibold)).foregroundStyle(theme.faint).padding(.leading,34).padding(.trailing,10).frame(height:22)
            if !accepted {ForEach(Array(rows.enumerated()),id:\.offset){index,row in
                HStack(spacing:8){Image(systemName:"doc").font(.system(size:11)).foregroundStyle(theme.faint).frame(width:16);Text(row.0).font(.system(size:10.5,design:.monospaced)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading);Text(row.1).font(.system(size:11,weight:row.3 ? .semibold:.regular)).frame(width:58,alignment:.trailing);ReferenceChip(title:row.2,theme:theme,tone:row.3 ? nil:"waiting").frame(width:128,alignment:.leading);Button { action(row.0.components(separatedBy:"  ")[0],row.3) } label: {Label(row.3 ? "Показать в Finder":"дифф",systemImage:row.3 ? "folder":"chevron.left.forwardslash.chevron.right").font(.system(size:11)).foregroundStyle(theme.accent)}.buttonStyle(.plain).frame(width:104,alignment:.trailing)}.padding(.horizontal,10).frame(height:28).background(stale && index>0 ? theme.accent.opacity(0.07):.clear).overlay(alignment:.top){theme.line.frame(height:0.5)}
            }}
            HStack{Text(stale ? "подсвечены новые и изменённые · прежний blob дампа c71b5e0" : "дифф — при isText и размере < max_file_mb, в Cursor из clonePath; иначе Finder").font(.system(size:10)).foregroundStyle(theme.faint).lineLimit(1);Spacer(minLength:0);Button("В исключения проекта…",action:exceptions).buttonStyle(.plain).font(.system(size:10.5)).foregroundStyle(theme.accent)}.padding(.horizontal,10).frame(height:23).overlay(alignment:.top){theme.line.frame(height:0.5)}
        }.background(theme.content,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(theme.line,lineWidth:0.5))
    }
}
