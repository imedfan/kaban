import Foundation
import AppKit
import KabanProtocol
import KabanBoardCore
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
    var tasks = ReferenceDemo.fixture.filter { $0.id != "SHOP-55" }
    var inspectedFrame: String?
    var projects = ["shop-api","kaban","mobile-app","docs-site"]
    var selected: String?
    var visible = ["shop-api","kaban","mobile-app","docs-site"]
    var collapsed = Set(["mobile-app","docs-site"])
    var route = "board"
    var dark = false
    var mode = "Несколько"
    var compact = false
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
    var identityDraft = IdentityDraft()
    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать проект"
        if await panel.begin() == .OK, let url = panel.url { projectPath = url.path }
    }
    func validateIdentity(submitted: Bool) -> Bool {
        var missing: [String] = [], invalid: [String] = []
        for (key, value) in [("name", identityName), ("email", identityEmail)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(key) }
            else if value.contains("\n") || value.contains("\r") || value.contains("\0") { invalid.append(key) }
        }
        guard !missing.isEmpty || !invalid.isEmpty else { return true }
        var params = ["missing": missing.joined(separator: ","), "invalid": invalid.joined(separator: ",")]
        if !missing.contains("name"), !invalid.contains("name") { params["name"] = identityName }
        if !missing.contains("email"), !invalid.contains("email") { params["email"] = identityEmail }
        identityDraft = IdentityDraft(name: identityName, email: identityEmail).refusing(
            CommandError(code: CommandError.identityRequiredCode, message: IdentityDraft.generalText, params: params),
            submitted: submitted ? GitIdentity(name: identityName, email: identityEmail) : nil)
        identityMode = submitted ? (invalid.isEmpty ? 2 : 3) : 1
        return false
    }

    var identityName = "Артём Палкин"
    var identityEmail = ""
    var projectPath = "~/dev/shop-api"
    var template = true
    var identities: [String: (String,String)] = [:]
    var mcpServers: [String:Bool] = ["kaban":true,"figma":false,"jira":false,"github":false,"filesystem":false,"sentry":true,"context7":true,"postgres-local":false]
    var model = ""
    var quotaConsent = true
    var quotaInterval = "5 мин"
    var quotaThresholdCm = 10.0
    var quotaThresholdOm = 10.0
    var stageFields = ["Имя":"Разработка","WIP-лимит":"2","Попыток":"3","Таймаут зависания":"0 мин","Общий таймаут":"60 мин"]
    var flagsCleared = Set<String>()
    var savedPreset = "Стандартный"
    struct SettingsSnapshot {var preset:String;var readonly:Bool;var overrides:[String:String];var fields:[String:String];var mcp:[String:Bool];var model:String;var consent:Bool;var interval:String;var cm:Double;var om:Double; var requested:String; var patterns:String; var maxFile:String; var allow:String}
    var savedSettings:SettingsSnapshot?
    var projectSettings: [String: SettingsSnapshot] = [:]
    var initialSettings: SettingsSnapshot?
    func checkpointSettings(){savedSettings = .init(preset:preset,readonly:readonly,overrides:stageOverrides,fields:stageFields,mcp:mcpServers,model:model,consent:quotaConsent,interval:quotaInterval,cm:quotaThresholdCm,om:quotaThresholdOm,requested:requestedModel,patterns:filePatterns,maxFile:maxFileMB,allow:fileAllow)}
    func applySettings(){
        checkpointSettings(); projectSettings[selectedProject] = savedSettings
        savedPreset=preset;unsaved=false
        if pipelineErrors.isEmpty, selectedProject == "kaban" { flagsCleared.insert("pipeline") }
        if selectedProject == "mobile-app", mcpServers["jira"] != true { flagsCleared.insert("mcp") }
    }
    func openSettings(_ destination: String, project: String) {
        if project != selectedProject {
            savedSettings = projectSettings[project] ?? initialSettings
            cancelSettings()
            selectedProject = project
            checkpointSettings()
        }
        route = destination
    }
    func cancelSettings(){if let s=savedSettings{preset=s.preset;readonly=s.readonly;stageOverrides=s.overrides;stageFields=s.fields;mcpServers=s.mcp;model=s.model;quotaConsent=s.consent;quotaInterval=s.interval;quotaThresholdCm=s.cm;quotaThresholdOm=s.om;requestedModel=s.requested;filePatterns=s.patterns;maxFileMB=s.maxFile;fileAllow=s.allow};unsaved=false}
    init() { checkpointSettings(); initialSettings = savedSettings }
    func prepareFrame(_ route: String) {
        tasks = Self.fixture.filter { $0.id != "SHOP-55" }
        projects = ["shop-api", "kaban", "mobile-app", "docs-site"]
        visible = projects
        collapsed = Set(["mobile-app", "docs-site"])
        selected = nil
        acceptedTaskIDs.removeAll(); staleTaskIDs.removeAll(); flagsCleared.removeAll()
        logTab = "Лента"
        selectedProject = "shop-api"
        if route == "return-gate", let task = Self.fixture.first(where: { $0.id == "SHOP-55" }) { tasks.append(task) }
        if ["board-base", "incident", "review"].contains(route) {
            tasks = Self.baseFixture
            projects = ["shop-api", "kaban", "mobile-app", "docs-site", "infra"]
            visible = route == "board-base" && !dark ? projects : projects.filter { $0 != "infra" }
            mode = visible.count == projects.count ? "Все" : "Несколько"
            collapsed.insert("infra")
            tasks.append(.init(id:"MOB-12",title:"Экран входа",status:"running",label:"Работает",progress:25,stage:"Dev",project:"mobile-app"))
            if let i = tasks.firstIndex(where: { $0.id == "SHOP-42" }) {
                if route != "board-base" { tasks[i].status="running";tasks[i].label="Работает";tasks[i].meta="12 мин";tasks[i].progress=55;tasks[i].badges=["возврат 1/3","opus"] }
                else if dark { tasks[i].label="Ждёт лимит";tasks[i].meta="16:40";tasks[i].badges=["возврат 1/3","rate_limit"] }
            }
        } else if ["board-v02", "substituted", "run-limit"].contains(route) {
            tasks = Self.fixture.filter { !["SHOP-52", "SHOP-55"].contains($0.id) }
            if let i = tasks.firstIndex(where: { $0.id == "SHOP-29" }) { tasks[i].status = "gating"; tasks[i].label = "Rebase"; tasks[i].files = []; tasks[i].progress = 40 }
            tasks.append(.init(id: "SHOP-47", title: "Импорт прайса из 1С", status: "waiting", label: "Лимит запусков", meta: "12/12", badges: ["WIP сохранён"], stage: "Dev"))
            tasks.append(.init(id: "SHOP-34", title: "Логи запросов без PII", label: "На модели флаг", meta: "Opus 4.5", stage: "AI Review"))
        } else if ["board", "suspicious", "stale"].contains(route) {
            tasks = Self.fixture.filter { $0.id != "SHOP-55" }
        }
        if ["general", "stage-git-base", "pipeline-invalid"].contains(route) { selectedProject = "kaban" }
        else if route == "project-mcp" { selectedProject = "mobile-app" }
        if route == "pipeline-invalid" { model = "" }
        selected = ["incident":"KBN-17", "review":"SHOP-31", "substituted":"SHOP-35", "run-limit":"SHOP-47", "suspicious":"SHOP-52", "stale":"SHOP-52", "return-gate":"SHOP-55", "return-merge":"SHOP-29"][route]
    }
    static let baseFixture: [ReferenceTask] = [
        .init(id: "SHOP-58", title: "Экспорт заказов в CSV", meta: "#1", badges: ["фича"]),
        .init(id: "SHOP-61", title: "Rate limit на /auth/login", label: "Не запустится", badges: ["без критериев приёмки"]),
        .init(id: "SHOP-42", title: "Пагинация в /orders", status: "retry", label: "Ждёт Cursor", badges: ["возврат 1/3", "runner_auth"], stage: "Dev"),
        .init(id: "SHOP-44", title: "Цены в копейках", status: "gating", label: "Гейты", meta: "swift test · 2/3", badges: ["пересечение файлов"], progress: 66, stage: "Dev"),
        .init(id: "SHOP-36", title: "Скидки по промокодам", meta: "первая", badges: ["возврат: конфликт 1/2"], stage: "Dev"),
        .init(id: "SHOP-39", title: "Повтор вебхуков оплаты", status: "running", label: "Работает", meta: "4 мин", badges: ["sonnet"], progress: 30, stage: "Test"),
        .init(id: "SHOP-40", title: "Валидация адреса доставки", status: "waiting", label: "Попытки исчерпаны", meta: "3/3", badges: ["stall 10 мин"], stage: "Test"),
        .init(id: "SHOP-35", title: "Кэш каталога в Redis", status: "waiting", label: "Вопрос агента", meta: "18 м", badges: ["request_human"], stage: "AI Review"),
        .init(id: "SHOP-34", title: "Логи запросов без PII", status: "retry", label: "Повтор", meta: "1:40 · 2/3", badges: ["краш процесса"], stage: "AI Review"),
        .init(id: "SHOP-31", title: "Слияние гостевой корзины", status: "review", label: "На ревью", meta: "+128 −40", badges: ["после конфликта", "гейты ✓"], stage: "Human Review"),
        .init(id: "SHOP-29", title: "Индексы для поиска по SKU", status: "gating", label: "Rebase + гейты", meta: "#1", progress: 40, stage: "Merge"),
        .init(id: "SHOP-30", title: "Убрать устаревший /v1/cart", status: "blocked", label: "Заблокирована", badges: ["main грязная"], stage: "Merge"),
        .init(id: "SHOP-27", title: "Health-check для балансировщика", status: "done", label: "Готово", meta: "14:05 → main", stage: "Done"),
        .init(id: "SHOP-25", title: "GraphQL-шлюз (отклонено)", status: "cancelled", label: "Отменена", meta: "вчера", stage: "Done"),
        .init(id: "KBN-19", title: "Сводка ревью: список коммитов ветки", meta: "#1", project: "kaban"),
        .init(id: "KBN-17", title: "Обёртка git: белый список флагов", status: "incident", label: "Инцидент", meta: "main откатан", stage: "Dev", project: "kaban"),
        .init(id: "KBN-15", title: "Дорожки: закреплённые заголовки", status: "running", label: "Работает", meta: "21 мин", badges: ["git ×1 разрешено", "gpt-5"], progress: 70, stage: "Dev", project: "kaban"),
        .init(id: "KBN-18", title: "Ротация логов run", status: "waiting", label: "Политика git", meta: "5/5 отказов", badges: ["5 отказов"], stage: "AI Review", project: "kaban"),
        .init(id: "KBN-13", title: "Счётчик в менюбаре", label: "Ждёт места", badges: ["Human Review 2/2"], stage: "AI Review", project: "kaban"),
        .init(id: "KBN-10", title: "XPC: досылка по seq", status: "review", label: "На ревью", meta: "+311 −52", badges: ["гейты ✓"], stage: "Human Review", project: "kaban"),
        .init(id: "KBN-11", title: "Маскот: «Уменьшить движение»", status: "review", label: "На ревью", meta: "+96 −8", stage: "Human Review", project: "kaban"),
        .init(id: "KBN-8", title: "Снимок refs до и после run", status: "done", label: "Готово", meta: "12:40 → main", stage: "Done", project: "kaban")
    ]
    var selectedProject = "shop-api"
    var taskBodies: [String:String] = [:]
    var draftTitle = ""
    var draftBody = ""
    var previewFile = "src/payments.ts"
    private let sampleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KabanDemo-" + UUID().uuidString)
    func sampleContents(_ path: String) -> String {
        switch path {
        case ".env.local", ".env.seed": return "GATEWAY_MODE=test\nSTRIPE_KEY=fixture-value\n"
        case "certs/stripe-test.pem": return "-----BEGIN TEST FIXTURE-----\nKaban payment gateway test certificate\n-----END TEST FIXTURE-----\n"
        default: return "await gateway.authorize(order)\nreturn result.approved\n"
        }
    }
    func openSampleFile(_ path: String, reveal: Bool) {
        previewFile = path
        guard reveal else { sheet = "diff"; return }
        do {
            let url = sampleDirectory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(count:path.contains("seed") ? 6_800_000 : 12_400_000).write(to:url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { notice = error.localizedDescription }
    }
    func openInCursor() async {
        do {
            let projectDirectory = sampleDirectory.appendingPathComponent(selectedTask?.project ?? selectedProject)
            let sample = projectDirectory.appendingPathComponent("src/payments.ts")
            try FileManager.default.createDirectory(at:sample.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(sampleContents("src/payments.ts").utf8).write(to:sample)
            let applications = [URL(fileURLWithPath:"/Applications/Cursor.app"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Cursor.app")]
            guard let cursor = applications.first(where:{FileManager.default.fileExists(atPath:$0.path)}) else { notice = "Cursor не найден в папке Applications"; return }
            _ = try await NSWorkspace.shared.open([projectDirectory],withApplicationAt:cursor,configuration:.init())
        } catch { notice = error.localizedDescription }
    }
    var sheet: String?
    var activeSettingsTab = "Основное"
    var sidebarHidden = false
    var macPaused = false
    private var macPausedTaskIDs = Set<String>()
    var taskNotes: [String: [String]] = [:]
    var requestedModel = "auto"
    var filePatterns = ".env*, *.pem, *.p12"
    var maxFileMB = "5"
    var fileAllow = ""
    var selectedTask: ReferenceTask? { tasks.first { $0.id == selected } }
    var waitingCount: Int { tasks.filter { ["waiting", "review", "suspicious"].contains($0.status) }.count }
    var incidentCount: Int { tasks.filter { $0.status == "incident" }.count }
    var runningCount: Int { tasks.filter { $0.status == "running" }.count }
    var detailKind: String {
        guard let task = selectedTask else { return "generic" }
        if task.status == "suspicious" { return task.stage == "Merge" ? "merge" : task.stage == "Checks" ? "gate" : "suspicious" }
        if task.status == "incident" { return "incident" }
        if task.status == "review" { return "review" }
        if task.id == "SHOP-35", task.status == "waiting" { return "substituted" }
        if task.id == "SHOP-47", task.status == "waiting" { return "run-limit" }
        return "generic"
    }
    func moveTask(_ id: String, to stage: String, in project: String? = nil) -> Bool {
        guard (Self.stages + ["Checks", "Lint"]).contains(stage) else { return false }
        guard let i = tasks.firstIndex(where: { $0.id == id }), project == nil || tasks[i].project == project else { return false }
        tasks[i].stage = stage
        tasks[i].status = stage == "Done" ? "done" : "queued"
        tasks[i].label = stage == "Done" ? "Готово" : "В очереди"
        tasks[i].progress = nil
        return true
    }
    func showProject(_ name: String) {
        guard projects.contains(name) else { return }
        selectedProject = name
        if !visible.contains(name) { visible.append(name) }
    }
    func editSelected() {
        guard let task = selectedTask else { return }
        draftTitle = task.title
        draftBody = taskBodies[task.id] ?? ""
        selectedProject = task.project
        sheet = "edit"
    }
    func presentReturn(merge: Bool) {
        returnNote = ""
        returnTarget = "Dev"
        sheet = merge ? "return-merge" : "return-gate"
    }
    func pauseMac() {
        macPaused.toggle()
        for i in tasks.indices {
            if macPaused && tasks[i].status == "running" {
                macPausedTaskIDs.insert(tasks[i].id)
                tasks[i].status = "paused"; tasks[i].label = "На паузе"; tasks[i].progress = nil
            } else if !macPaused && macPausedTaskIDs.contains(tasks[i].id) && tasks[i].status == "paused" {
                tasks[i].status = "queued"; tasks[i].label = "В очереди"
            }
        }
        if !macPaused { macPausedTaskIDs.removeAll() }
    }
    var pipelineErrors: [String] {
        var errors: [String] = []
        if model.isEmpty { errors.append("У агентской стадии Test нет модели") }
        if requestedModel == "auto" { errors.append("AI Review: auto запрещён — нужна явная модель") }
        return errors
    }
    var stallValid: Bool { (1...120).contains(Int((stageFields["Таймаут зависания"] ?? "0").components(separatedBy: " ")[0]) ?? 0) }


    func action(_ label: String, taskID: String? = nil) {
        // Explicit frontend-only demo: never sends repo/system commands.
        notice = "Демо: \(label)"
        if label=="Открыть в Cursor" {notice=nil;Task{await openInCursor()}}
        if label=="Открыть файл" {sheet="diff";notice=nil}
        if label=="Пауза Мака" { pauseMac(); notice = nil }
        if let taskID, let index = tasks.firstIndex(where: { $0.id == taskID }) {
            switch label {
            case "Пауза": tasks[index].status = "paused"; tasks[index].label = "На паузе"; tasks[index].progress = nil
            case "Продолжить": tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Принять": tasks[index].stage = "Merge"; tasks[index].status = "gating"; tasks[index].label = "Rebase + гейты"
            case "В Backlog": tasks[index].stage = "Backlog"; tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Перезапустить", "Повторить", "Ещё попыток": tasks[index].status = "queued"; tasks[index].label = "В очереди"
            case "Отправить замечание":
                guard !returnNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = nil; return }
                taskNotes[taskID, default: []].append(returnNote)
                tasks[index].status = "queued"; tasks[index].label = "В очереди"; returnNote = ""
            case "Восстановить WIP": tasks[index].badges=["WIP восстановлен"]
            case "Разрешить git ×1": tasks[index].badges.append("git ×1 разрешено")
            case "Отменить": tasks[index].status = "cancelled"; tasks[index].label = "Отменена"; tasks[index].progress = nil
            default: break
            }
            if ["Перезапустить", "В Backlog", "Отменить"].contains(label), !tasks[index].files.isEmpty {
                acceptedTaskIDs.insert(taskID); tasks[index].files = []
            }
            if !["Разрешить git ×1", "Восстановить WIP"].contains(label) { notice = nil }

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
        notice = nil
        if let index = tasks.firstIndex(where: { $0.id == (selected ?? (merge ? "SHOP-29" : "SHOP-55")) }) {
            tasks[index].stage = returnTarget; tasks[index].status = "queued"; tasks[index].label = "В очереди"
            tasks[index].progress = nil
            if !filled { acceptedTaskIDs.insert(tasks[index].id); tasks[index].files = [] }
            else { taskNotes[tasks[index].id, default: []].append(returnNote) }

        }
        sheet = nil
    }
    func addProject() {
        guard validateIdentity(submitted: identityMode > 0) else { return }
        guard !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "Укажите папку проекта"; return }
        let project = URL(fileURLWithPath:projectPath).lastPathComponent
        identities[project] = (identityName.trimmingCharacters(in:.whitespacesAndNewlines),identityEmail.trimmingCharacters(in:.whitespacesAndNewlines))
        if !projects.contains(project) { projects.append(project) }
        if !visible.contains(project) { visible.append(project) }
        notice = "Демо: проект и автор добавлены в память текущего запуска"
        sheet = nil
    }
    func saveTask() {
        guard !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if sheet=="edit",let index=tasks.firstIndex(where:{$0.id==selected}) {tasks[index].title=draftTitle;taskBodies[tasks[index].id]=draftBody}
        else {let id="DEMO-\(tasks.count+1)";tasks.append(.init(id:id,title:draftTitle,project:selectedProject));taskBodies[id]=draftBody;selected=id}
        sheet=nil;draftTitle="";draftBody=""
    }
    func moveSelected() {
        if let selected { _ = moveTask(selected, to: returnTarget) }
        sheet = nil
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
        .init(id:"SHOP-55",title:"Экспорт заказов в CSV",status:"suspicious",label:"Подозрительные файлы: 2",files:["orders-dump.sql · больше 5 МБ", ".env.local · по шаблону .env*"],stage:"Checks")
    ]
}

@MainActor extension ReferenceDemo {
    static func smoke() async throws->[String] {
        var checks:[String]=[]
        func require(_ value:Bool,_ name:String)throws{guard value else{throw NSError(domain:"ReferenceDemoSmoke",code:1,userInfo:[NSLocalizedDescriptionKey:name])};checks.append(name)}
        let model=ReferenceDemo();model.tasks=Self.fixture;model.sheet="create";model.draftTitle="Smoke";model.draftBody="## Критерии\n- [ ] exact\n";model.selectedProject="kaban";model.saveTask()
        let id=model.selected!;try require(model.tasks.last?.project=="kaban" && model.taskBodies[id]=="## Критерии\n- [ ] exact\n","create selected project + exact Markdown")
        model.sheet="edit";model.draftTitle="Edited";model.draftBody="";model.saveTask();try require(model.tasks.last?.title=="Edited" && model.taskBodies[id]=="","edit known empty body")
        model.returnTarget="Test";model.moveSelected();try require(model.tasks.last?.stage=="Test" && model.tasks.last?.status=="queued","move queues target; never restores running")
        model.action("Отменить",taskID:id);try require(model.tasks.last?.status=="cancelled","cancel selected task")
        model.identityMode=1;model.identityEmail="";model.projectPath="~/dev/smoke-project";model.addProject();try require(!model.projects.contains("smoke-project") && model.identityMode==2,"identity missing email does not add project")
        model.identityName=" ";model.identityEmail="test@example.com";model.addProject();try require(!model.projects.contains("smoke-project") && model.identityDraft.name.highlighted && model.identityDraft.name.caption != nil,"identity blank name does not add project")
        model.identityName="Smoke";model.addProject();try require(model.projects.contains("smoke-project") && model.visible.contains("smoke-project") && model.identities["smoke-project"]?.0=="Smoke","valid project + memory identity registered and visible")
        await model.acceptFiles(taskID:"SHOP-29");try require(model.acceptedTaskIDs.contains("SHOP-29") && !model.accepted && model.tasks.first{$0.id=="SHOP-29"}?.stage=="Done","accept specific task does not mutate SHOP52")
        await model.acceptFiles(taskID:"SHOP-52",staleResponse:true);try require(model.stale && !model.accepted && model.tasks.first{$0.id=="SHOP-52"}?.status=="suspicious","stale acceptance preserves task; pending clears")
        try require(model.pending.isEmpty,"pending correlated operations cleared")
        model.selected=nil;model.returnTarget="Dev";model.returnTask(filled:false,merge:false);try require(model.tasks.first{$0.id=="SHOP-55"}?.stage=="Dev" && model.tasks.first{$0.id=="SHOP-55"}?.files.isEmpty==true,"empty return accepts set and queues explicit target")
        let n=model.tasks.firstIndex{$0.id=="SHOP-29"}!;model.tasks[n].files=["seed-sku.sql"];model.selected="SHOP-29";model.returnTask(filled:true,merge:true);try require(model.tasks[n].files==["seed-sku.sql"] && model.tasks[n].stage=="Dev","filled return retains suspicious set")
        model.preset="Строгий";model.stageFields["Имя"]="Saved";model.applySettings();model.preset="Свободный";model.stageFields["Имя"]="Unsaved";model.mcpServers["figma"]=true;model.cancelSettings();try require(model.preset=="Строгий" && model.stageFields["Имя"]=="Saved" && model.mcpServers["figma"]==false,"apply/cancel restores full settings snapshot")
        model.identityName="Invalid\nName"; model.identityEmail="test@example.com"; try require(!model.validateIdentity(submitted:true) && model.identityDraft.name.highlighted,"identity control characters rejected in submitted field")
        try require(!model.moveTask("SHOP-42",to:"Merge",in:"kaban") && model.tasks.first{$0.id=="SHOP-42"}?.stage=="Dev","drop rejects another project")
        try require(!model.moveTask("SHOP-42",to:"Unknown"),"drop rejects unknown stage")
        model.action("Пауза",taskID:"SHOP-42"); model.pauseMac(); try require(model.runningCount==0,"Mac pause stops all running agents")
        model.pauseMac(); try require(model.tasks.first{$0.id=="SHOP-42"}?.status=="paused" && model.tasks.first{$0.id=="KBN-15"}?.status=="queued","Mac resume preserves individually paused tasks")
        try require(model.tasks.first{$0.id=="KBN-15"}?.progress==nil,"queued task has no stale progress")
        model.selected="SHOP-31"; try require(model.detailKind=="review","review task opens native review actions")
        model.returnNote="Исправить тест"; model.returnTarget="Dev"; model.returnTask(filled:true,merge:false); try require(model.taskNotes["SHOP-31"]==["Исправить тест"] && model.selectedTask?.stage=="Dev","review return stores comments and explicit target")
        model.model="composer-1";model.requestedModel="sonnet-4.5";try require(model.pipelineErrors.isEmpty,"explicit agent models resolve pipeline errors")
        model.stageFields["Таймаут зависания"]="10 мин";try require(model.stallValid,"valid stall timeout resolves validation")
        model.stageFields["Таймаут зависания"]="121 мин";try require(!model.stallValid,"stall timeout above maximum rejected")
        let taskCount=model.tasks.count;model.sheet="create";model.draftTitle="  ";model.saveTask();try require(model.tasks.count==taskCount,"blank task title cannot create task")
        model.selectedProject="shop-api";model.stageFields["WIP-лимит"]="4";model.applySettings();model.openSettings("general",project:"kaban");try require(model.stageFields["WIP-лимит"]=="2","project settings switch restores its own draft")
        model.openSettings("general",project:"shop-api");try require(model.stageFields["WIP-лимит"]=="4","project settings retain applied values independently")
        model.prepareFrame("board-base");model.prepareFrame("cards-suspicious");try require(model.tasks.contains{$0.id=="SHOP-52"},"switching reference scenes restores required fixture")
        model.openSampleFile(".env.local",reveal:false);try require(model.previewFile==".env.local" && model.sheet=="diff" && model.sampleContents(model.previewFile).contains("GATEWAY_MODE=test"),"native file preview follows selected sample path")
        return checks
    }
}
