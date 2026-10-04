import Foundation
import Observation

struct ReferenceTask: Identifiable, Equatable {
    var id: String
    var title: String
    var status = "queued"
    var label = "В очереди"
    var meta = ""
    var badges: [String] = []
    var files: [String] = []
    var progress: Double? = nil
    var stage = "Backlog"
    var project = "shop-api"
    var emoji: String { project == "kaban" ? "🐗" : project == "mobile-app" ? "🐙" : project == "docs-site" ? "🦉" : "🦊" }
}

@MainActor @Observable final class ReferenceDemo {
    var tasks = ReferenceDemo.fixture
    var inspectedFrame: String?
    var projects = ["shop-api","kaban","mobile-app","docs-site"]
    var selected: String?
    var visible = ["shop-api","kaban","mobile-app","docs-site"]
    var collapsed = Set(["mobile-app","docs-site"])
    var route = "board"
    var sourcePage:String {
        if route=="board" {return selected=="SHOP-52" ? "v0.2.1/details-suspicious.html":selected=="SHOP-35" ? "v0.2/details-substituted.html":selected=="SHOP-31" ? "human-review.html":selected=="KBN-17" ? "task-details.html":"runtime-board.html"}
        return ["project-git":"v0.2.1/project-git.html","stage-git":"v0.2.1/stage-git.html","general":"column-settings-general.html","pipeline-invalid":"v0.2/pipeline-invalid.html","project-mcp":"v0.2/project-mcp.html","mac-quota":"v0.2/mac-quota.html","identity-settings":"v0.2.1/add-project-identity.html"][route] ?? "runtime-board.html"
    }
    var dark = false
    var mode = "Несколько"
    var compact = false
    var nativePrototype = CommandLine.arguments.contains("--native-demo")
    var search = ""
    var notice: String?
    var pending = Set<String>()
    var acceptedTaskIDs = Set<String>()
    var staleTaskIDs = Set<String>()
    var accepted: Bool { acceptedTaskIDs.contains("SHOP-52") }
    var stale: Bool { staleTaskIDs.contains("SHOP-52") }
    var logTab = "Лента"
    var returnNote = ""
    var returnTarget = "Dev"
    var keepBranch = false
    var preset = "Стандартный"
    var readonly = false
    var stageOverrides: [String: String] = ["stash":"Запретить","rebase":"Разрешить при условии"]
    var unsaved = true
    var identityMode = 0
    var identityName = "Артём Палкин"
    var identityEmail = ""
    var projectPath = "~/dev/shop-api"
    var template = true
    var identities: [String: (String,String)] = [:]
    var mcpServers: [String:Bool] = ["kaban":true,"figma":false,"jira":false,"github":false,"filesystem":false,"sentry":true,"context7":true,"postgres-local":false]
    var model = "composer-1"
    var quotaConsent = true
    var quotaInterval = "5 мин"
    var quotaThresholdCm = 10.0
    var quotaThresholdOm = 10.0
    var stageFields = ["Имя":"Разработка","WIP-лимит":"2","Попыток":"3","Таймаут зависания":"0 мин","Общий таймаут":"60 мин"]
    var flagsCleared = Set<String>()
    var savedPreset = "Стандартный"
    struct SettingsSnapshot {var preset:String;var readonly:Bool;var overrides:[String:String];var fields:[String:String];var mcp:[String:Bool];var model:String;var consent:Bool;var interval:String;var cm:Double;var om:Double}
    var savedSettings:SettingsSnapshot?
    func checkpointSettings(){savedSettings = .init(preset:preset,readonly:readonly,overrides:stageOverrides,fields:stageFields,mcp:mcpServers,model:model,consent:quotaConsent,interval:quotaInterval,cm:quotaThresholdCm,om:quotaThresholdOm)}
    func applySettings(){checkpointSettings();savedPreset=preset;unsaved=false}
    func cancelSettings(){if let s=savedSettings{preset=s.preset;readonly=s.readonly;stageOverrides=s.overrides;stageFields=s.fields;mcpServers=s.mcp;model=s.model;quotaConsent=s.consent;quotaInterval=s.interval;quotaThresholdCm=s.cm;quotaThresholdOm=s.om};unsaved=false}
    init(){checkpointSettings()}
    var selectedProject = "shop-api"
    var taskBodies: [String:String] = [:]
    var draftTitle = ""
    var draftBody = ""
    var webModal:String?
    var sheet: String?

    func action(_ label: String, taskID: String? = nil) {
        // Explicit frontend-only demo: never sends repo/system commands.
        notice = "Демо: \(label)"
        if label=="Открыть в Cursor" || label=="Открыть файл" {sheet="diff";notice=nil}
        if label=="Пауза Мака" {for i in tasks.indices where tasks[i].status=="running"{tasks[i].status="paused";tasks[i].label="На паузе"}}
        if let taskID, let index = tasks.firstIndex(where: { $0.id == taskID }) {
            switch label {
            case "Пауза": tasks[index].status = "paused"; tasks[index].label = "На паузе"
            case "Продолжить": tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Принять": tasks[index].stage = "Merge"; tasks[index].status = "gating"; tasks[index].label = "Rebase + гейты"
            case "В Backlog": tasks[index].stage = "Backlog"; tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Перезапустить", "Повторить", "Ещё попыток": tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Отправить замечание": tasks[index].status="queued";tasks[index].label="В очереди"
            case "Восстановить WIP": tasks[index].badges=["WIP восстановлен"]
            case "Разрешить git ×1": tasks[index].badges.append("git ×1 разрешено")
            case "Отменить": tasks[index].status = "cancelled"; tasks[index].label = "Отменена"
            default: break
            }
        }
    }
    func acceptFiles(taskID: String = "SHOP-52", staleResponse: Bool = false) async {
        guard !pending.contains("files:" + taskID) else { return }
        pending.insert("files:" + taskID)
        try? await Task.sleep(for: .milliseconds(600))
        pending.remove("files:" + taskID)
        if staleResponse { staleTaskIDs.insert(taskID); return }
        acceptedTaskIDs.insert(taskID)
        staleTaskIDs.remove(taskID)
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].files = []
            let next=tasks[index].stage=="Merge" ? "Done":tasks[index].stage=="Checks" ? "AI Review":"Test"
            tasks[index].stage=next;tasks[index].status=next=="Done" ? "done":"queued";tasks[index].label=next=="Done" ? "Готово":"В очереди"
        }
    }
    func returnTask(filled: Bool, merge: Bool) {
        notice = filled ? "Демо: вернуть с замечанием; набор не принят" : "Демо: принять файлы и вернуть"
        if let index = tasks.firstIndex(where: { $0.id == (selected ?? (merge ? "SHOP-29" : "SHOP-55")) }) {
            tasks[index].stage = returnTarget; tasks[index].status = "queued"; tasks[index].label = "В очереди"
            if !filled { tasks[index].files = [] }
        }
        sheet = nil
    }
    func addProject() {
        if identityMode == 0 { identityMode = 1; return }
        if identityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { identityMode = 2; return }
        if identityName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || identityName.contains("\r") || identityEmail.contains("\r") || identityName.contains("\n") || identityName.contains("\0") || identityEmail.contains("\n") || identityEmail.contains("\0") { identityMode = 3; return }
        let project = URL(fileURLWithPath:projectPath).lastPathComponent
        identities[project] = (identityName.trimmingCharacters(in:.whitespacesAndNewlines),identityEmail.trimmingCharacters(in:.whitespacesAndNewlines))
        if !projects.contains(project) { projects.append(project) }
        if !visible.contains(project) { visible.append(project) }
        notice = "Демо: проект и автор добавлены в память текущего запуска"
        sheet = nil
    }
    func saveTask() {
        if sheet=="edit",let index=tasks.firstIndex(where:{$0.id==selected}) {tasks[index].title=draftTitle;taskBodies[tasks[index].id]=draftBody}
        else {let id="DEMO-\(tasks.count+1)";tasks.append(.init(id:id,title:draftTitle,project:selectedProject));taskBodies[id]=draftBody;selected=id}
        sheet=nil;draftTitle="";draftBody=""
    }
    func moveSelected() {
        if let index=tasks.firstIndex(where:{$0.id==selected}) {tasks[index].stage=returnTarget;tasks[index].status="queued";tasks[index].label="В очереди"}
        sheet=nil
    }
    static let stages = ["Backlog","Dev","Test","AI Review","Human Review","Merge","Done"]
    static let fixture: [ReferenceTask] = [
        .init(id:"SHOP-58",title:"Экспорт заказов в CSV",badges:["фича"]),
        .init(id:"SHOP-61",title:"Rate limit на /auth/login"),
        .init(id:"SHOP-42",title:"Пагинация курсором в /orders",status:"running",label:"Работает",meta:"12 мин",badges:["↩ 2/3"],progress:55,stage:"Dev"),
        .init(id:"SHOP-44",title:"Цены в копейках во всём API",status:"retry",label:"Попытка 2/3",meta:"повтор через 1:45",badges:["gate_failed"],stage:"Dev"),
        .init(id:"SHOP-52",title:"Интеграция платёжного шлюза",status:"suspicious",label:"Подозрительные файлы: 3",files:[".env.local · по шаблону .env*","orders-dump.sql · больше 5 МБ  +1"],stage:"Dev"),
        .init(id:"SHOP-39",title:"Повтор вебхуков оплаты",label:"Ждёт квоту Om",meta:"сброс через 13д",stage:"Test"),
        .init(id:"SHOP-40",title:"Валидация адреса доставки",label:"Ждёт квоту Om",meta:"сброс через 13д",badges:["↩ 1/3"],stage:"Test"),
        .init(id:"SHOP-35",title:"Кэш каталога в Redis",status:"waiting",label:"Подмена модели",meta:"15:12",badges:["Подмена: Opus 4.5 → Sonnet 4"],stage:"AI Review"),
        .init(id:"SHOP-31",title:"Слияние гостевой корзины",status:"review",label:"На ревью",meta:"+128 −40",badges:["гейты ✓"],stage:"Human Review"),
        .init(id:"SHOP-29",title:"Индексы для поиска по SKU",status:"suspicious",label:"Подозрительные файлы: 1",files:["перед слиянием","seed-sku.sql · 6,8 МБ · больше 5 МБ"],stage:"Merge"),
        .init(id:"SHOP-27",title:"Health-check для балансировщика",status:"done",label:"Готово",stage:"Done"),
        .init(id:"KBN-21",title:"Справочник моделей: фильтр «проверь пул»",project:"kaban"),
        .init(id:"KBN-15",title:"Дорожки: закреплённые заголовки",status:"running",label:"Доигрывает",meta:"21 мин",progress:80,stage:"Dev",project:"kaban"),
        .init(id:"KBN-14",title:"Квота: свежесть данных перед стартом",meta:"ждёт пайплайн",stage:"Test",project:"kaban"),
        .init(id:"KBN-10",title:"XPC: досылка по seq",status:"review",label:"На ревью",meta:"+311 −52",stage:"Human Review",project:"kaban"),
        .init(id:"KBN-17",title:"Обёртка git: белый список флагов",status:"incident",label:"Инцидент",meta:"main откатан",stage:"Dev",project:"kaban"),
        .init(id:"SHOP-55",title:"Экспорт заказов в CSV",status:"suspicious",label:"Подозрительные файлы: 2",stage:"Checks")
    ]
}

@MainActor extension ReferenceDemo {
    static func smoke() async throws->[String] {
        var checks:[String]=[]
        func require(_ value:Bool,_ name:String)throws{guard value else{throw NSError(domain:"ReferenceDemoSmoke",code:1,userInfo:[NSLocalizedDescriptionKey:name])};checks.append(name)}
        let model=ReferenceDemo();model.sheet="create";model.draftTitle="Smoke";model.draftBody="## Критерии\n- [ ] exact\n";model.selectedProject="kaban";model.saveTask()
        let id=model.selected!;try require(model.tasks.last?.project=="kaban" && model.taskBodies[id]=="## Критерии\n- [ ] exact\n","create selected project + exact Markdown")
        model.sheet="edit";model.draftTitle="Edited";model.draftBody="";model.saveTask();try require(model.tasks.last?.title=="Edited" && model.taskBodies[id]=="","edit known empty body")
        model.returnTarget="Test";model.moveSelected();try require(model.tasks.last?.stage=="Test" && model.tasks.last?.status=="queued","move queues target; never restores running")
        model.action("Отменить",taskID:id);try require(model.tasks.last?.status=="cancelled","cancel selected task")
        model.identityMode=1;model.identityEmail="";model.projectPath="~/dev/smoke-project";model.addProject();try require(!model.projects.contains("smoke-project") && model.identityMode==2,"identity missing email does not add project")
        model.identityName=" ";model.identityEmail="test@example.com";model.addProject();try require(!model.projects.contains("smoke-project") && model.identityMode==3,"identity blank name does not add project")
        model.identityName="Smoke";model.addProject();try require(model.projects.contains("smoke-project") && model.visible.contains("smoke-project") && model.identities["smoke-project"]?.0=="Smoke","valid project + memory identity registered and visible")
        await model.acceptFiles(taskID:"SHOP-29");try require(model.acceptedTaskIDs.contains("SHOP-29") && !model.accepted && model.tasks.first{$0.id=="SHOP-29"}?.stage=="Done","accept specific task does not mutate SHOP52")
        await model.acceptFiles(taskID:"SHOP-52",staleResponse:true);try require(model.stale && !model.accepted && model.tasks.first{$0.id=="SHOP-52"}?.status=="suspicious","stale acceptance preserves task; pending clears")
        try require(model.pending.isEmpty,"pending correlated operations cleared")
        model.selected=nil;model.returnTarget="Dev";model.returnTask(filled:false,merge:false);try require(model.tasks.first{$0.id=="SHOP-55"}?.stage=="Dev" && model.tasks.first{$0.id=="SHOP-55"}?.files.isEmpty==true,"empty return accepts set and queues explicit target")
        let n=model.tasks.firstIndex{$0.id=="SHOP-29"}!;model.tasks[n].files=["seed-sku.sql"];model.selected="SHOP-29";model.returnTask(filled:true,merge:true);try require(model.tasks[n].files==["seed-sku.sql"] && model.tasks[n].stage=="Dev","filled return retains suspicious set")
        model.preset="Строгий";model.stageFields["Имя"]="Saved";model.applySettings();model.preset="Свободный";model.stageFields["Имя"]="Unsaved";model.mcpServers["figma"]=true;model.cancelSettings();try require(model.preset=="Строгий" && model.stageFields["Имя"]=="Saved" && model.mcpServers["figma"]==false,"apply/cancel restores full settings snapshot")
        return checks
    }
}
