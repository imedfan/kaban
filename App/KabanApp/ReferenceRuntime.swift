import SwiftUI
import KabanBoardCore

struct ReferenceRuntime: View {
    @Bindable var demo: ReferenceDemo
    private var theme: ReferenceTheme { .init(dark:demo.dark) }
    private var inlineReturn: Bool { ["return-gate", "return-merge"].contains(demo.sheet ?? "") }
    var body: some View {
        Group {
            if let id = demo.inspectedFrame, let frame = ReferenceFrame.all.first(where: { $0.id == id }) {
                ReferenceFrameView(demo: demo, frame: frame)
            } else if demo.route == "board" {
                ReferenceBoard(demo: demo, theme: theme)
            } else if demo.route == "cards" || demo.route == "mascots" {
                ScrollView {
                    if demo.route == "mascots" { mascots }
                    else { ReferenceCardGallery(demo: demo, theme: theme, kind: "cards-suspicious") }
                }
            } else {
                ReferenceSettings(demo: demo, theme: theme, kind: demo.route)
            }
        }
        .preferredColorScheme(demo.dark ? .dark : .light)
        .tint(theme.accent)
        .onChange(of: demo.route) { _, _ in demo.inspectedFrame = nil }
        .onChange(of: demo.selected) { _, selected in
            if selected != nil, let frameID = demo.inspectedFrame,
               ReferenceFrame.all.first(where: { $0.id == frameID })?.route.hasPrefix("cards") == true {
                demo.inspectedFrame = nil; demo.route = "board"
            }
        }
        .overlay(alignment: .topTrailing) {
            if inlineReturn {
                ZStack(alignment: .topTrailing) {
                    theme.text.opacity(theme.dark ? 0.38 : 0.11).frame(width: 600)
                    ScrollView {
                        ReferenceReturnForm(demo: demo, theme: theme, merge: demo.sheet == "return-merge")
                    }.scrollIndicators(.hidden).frame(width:560).padding(.trailing,20).padding(.top,122)
                }.frame(width: 600).padding(.trailing, 8).padding(.top, 58).padding(.bottom, 8)
            }
        }
        .sheet(isPresented:Binding(get:{demo.sheet != nil && !inlineReturn},set:{if !$0{demo.sheet=nil}})) {sheet.padding(24).frame(width:620)}
        .alert("Демонстрация",isPresented:Binding(get:{demo.notice != nil},set:{if !$0{demo.notice=nil}})){Button("Закрыть"){demo.notice=nil}}message:{Text(demo.notice ?? "")}
    }
    @ViewBuilder private var sheet: some View {
        switch demo.sheet {
        case "add":ReferenceAddProjectForm(demo:demo,theme:theme)
        case "return-gate","return-merge":ReferenceReturnForm(demo:demo,theme:theme,merge:demo.sheet=="return-merge")
        case "create","edit": editor
        case "move": move
        case "review-return": reviewReturn
        case "cancel","reject":VStack(alignment:.leading,spacing:16){Text(demo.sheet=="reject" ? "Отклонить задачу?":"Отменить задачу?").font(.title3.bold());Text("\(demo.selected ?? "") · текущий запуск будет остановлен");Toggle("Сохранить ветку",isOn:$demo.keepBranch);HStack{ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil};ReferenceButton(title:"Вернуть в стадию",theme:theme){demo.sheet="move"};ReferenceButton(title:"Отменить задачу",primary:true,theme:theme){demo.action("Отменить",taskID:demo.selected);demo.sheet=nil}}}
        case "task-menu":VStack(spacing:12){ForEach(["Изменить…","Перенести…","Отменить…"],id:\.self){label in ReferenceButton(title:label,theme:theme){demo.sheet=label=="Изменить…" ? "edit":label=="Перенести…" ? "move":"cancel";if let task=demo.tasks.first(where:{$0.id==demo.selected}){demo.draftTitle=task.title;demo.draftBody=demo.taskBodies[task.id] ?? ""}}}}
        case "search": VStack(alignment: .leading, spacing: 12) {
            TextField("Поиск по названию или номеру задачи", text: $demo.search).textFieldStyle(.roundedBorder)
            ScrollView { ForEach(demo.tasks.filter { demo.search.isEmpty || $0.title.localizedCaseInsensitiveContains(demo.search) || $0.id.localizedCaseInsensitiveContains(demo.search) }) { task in
                Button { demo.showProject(task.project); demo.collapsed.remove(task.project); demo.selected = task.id; demo.sheet = nil } label: {
                    HStack { Text(task.emoji); Text(task.id).font(.system(size: 11, design: .monospaced)); Text(task.title); Spacer() }.padding(8)
                }.buttonStyle(.plain)
            } }.frame(height: 260)
            HStack { ReferenceButton(title: "Сбросить", theme: theme) { demo.search = "" }; Spacer(); ReferenceButton(title: "Закрыть", theme: theme) { demo.sheet = nil } }
        }
        case "notifications": VStack(alignment: .leading, spacing: 12) {
            Text("Уведомления").font(.title3.bold())
            ForEach(demo.tasks.filter { ["waiting", "review", "suspicious", "incident"].contains($0.status) }) { task in
                Button { demo.showProject(task.project); demo.selected = task.id; demo.sheet = nil } label: { HStack { Text(task.id); Text(task.label); Spacer(); Image(systemName: "chevron.right") } }.buttonStyle(.plain)
            }
            ReferenceButton(title: "Закрыть", theme: theme) { demo.sheet = nil }
        }
        case "yaml": VStack(alignment: .leading, spacing: 12) {
            Text("pipeline.yaml").font(.title3.bold())
            Text("git:\n  preset: \(demo.preset)\nstages:\n  - id: dev\n    model: \(demo.stageFields["Модель"] ?? "composer-1")\n  - id: test\n    model: \(demo.model)\n  - id: ai-review\n    model: \(demo.requestedModel)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            ReferenceButton(title: "Закрыть", theme: theme) { demo.sheet = nil }
        }
        default: VStack(alignment:.leading,spacing:12) {
            Text(demo.previewFile).font(.system(size:14,weight:.semibold,design:.monospaced))
            ScrollView {
                Text("diff --git a/\(demo.previewFile) b/\(demo.previewFile)\nnew file mode 100644\n" + demo.sampleContents(demo.previewFile).split(separator:"\n").map { "+" + $0 }.joined(separator:"\n"))
                    .font(.system(size:12,design:.monospaced)).foregroundStyle(theme.status("done").2).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }.frame(height:240)
            ReferenceButton(title:"Закрыть",theme:theme) { demo.sheet=nil }
        }
        }
    }
    private var editor:some View{VStack(alignment:.leading,spacing:12){Text(demo.sheet=="edit" ? "Изменить задачу":"Новая задача").font(.title3.bold());Picker("Проект",selection:$demo.selectedProject){ForEach(demo.projects,id:\.self){Text($0).tag($0)}}.disabled(demo.sheet=="edit");TextField("Заголовок",text:$demo.draftTitle).textFieldStyle(.roundedBorder);Text("Описание и критерии приёмки · Markdown").font(.headline);TextEditor(text:$demo.draftBody).font(.system(size:12,design:.monospaced)).frame(height:220).border(theme.line);HStack{Spacer();ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil};ReferenceButton(title:"Сохранить",primary:true,theme:theme){demo.saveTask()}.disabled(demo.draftTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}}
    private var reviewReturn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вернуть \(demo.selected ?? "задачу") с замечанием").font(.title3.bold())
            Picker("Куда", selection: $demo.returnTarget) { Text("Dev").tag("Dev"); Text("Test").tag("Test") }
            Text("Замечание агенту").font(.headline)
            TextEditor(text: $demo.returnNote).font(.system(size: 12)).frame(height: 120).border(theme.line)
            HStack { Spacer(); ReferenceButton(title: "Отмена", theme: theme) { demo.sheet = nil }; ReferenceButton(title: "Вернуть с замечанием", primary: true, theme: theme) { demo.returnTask(filled: true, merge: false) }.disabled(demo.returnNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
    }
    private var move:some View{VStack(alignment:.leading,spacing:12){Text("Перенести задачу").font(.title3.bold());Picker("Стадия",selection:$demo.returnTarget){ForEach(ReferenceDemo.stages,id:\.self){Text($0).tag($0)}};Text("Перенос назад прерывает текущий запуск; попытка не списывается.").font(.caption);HStack{ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil};ReferenceButton(title:"Перенести",primary:true,theme:theme){demo.moveSelected()}}}}
    private var mascots:some View{VStack(alignment:.leading,spacing:20){HStack(spacing:18){if let url=Bundle.main.url(forResource:"Kaban",withExtension:"icns",subdirectory:"Resources"),let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().frame(width:96,height:96)};VStack(alignment:.leading){ReferenceWordmark().fill(theme.dark ? .white:Color(hex:0x2a170b)).frame(width:180,height:46);Text("Оригинальный логотип · кит маскотов v1").foregroundStyle(theme.secondary)}};LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:6),spacing:16){ForEach(Array(MascotKit.mascots.enumerated()),id:\.offset){_,mascot in ReferenceMascot(emoji:mascot,theme:theme,state:"running",size:56)}};HStack{ForEach(["running","waiting","paused","done","incident"],id:\.self){state in VStack{ReferenceMascot(emoji:"🐗",theme:theme,state:state,size:48);Text(state).font(.caption)}}}}.padding(32)}
}

struct ReferenceWindowChrome:NSViewRepresentable {
    final class ChromeView:NSView {
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{window?.standardWindowButton(kind)?.isHidden=true}}
    }
    func makeNSView(context:Context)->NSView{ChromeView()}
    func updateNSView(_ view:NSView,context:Context){}
}


struct ReferenceMenuBar: View {
    @Bindable var demo: ReferenceDemo
    @Environment(\.openWindow) private var openWindow
    private var theme: ReferenceTheme { .init(dark: demo.dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Kaban").font(.headline); Spacer(); Text("\(demo.runningCount) / 4 агента").foregroundStyle(theme.secondary) }
            ReferenceQuotaBars(theme: theme)
            Divider()
            Text("Ждут человека · \(demo.waitingCount)\nИнциденты · \(demo.incidentCount)").font(.system(size: 12))
            ReferenceButton(title: "Открыть доску", theme: theme) { demo.inspectedFrame = nil; demo.route = "board"; openWindow(id: "board"); NSApp.activate() }
            ReferenceButton(title: "Настройки квоты", theme: theme) { demo.inspectedFrame = nil; demo.route = "mac-quota"; openWindow(id: "board"); NSApp.activate() }
            ReferenceButton(title: demo.macPaused ? "Продолжить" : "Пауза", theme: theme) { demo.pauseMac() }
        }.padding(16).frame(width: 300).foregroundStyle(theme.text).preferredColorScheme(demo.dark ? .dark : .light)
    }
}
