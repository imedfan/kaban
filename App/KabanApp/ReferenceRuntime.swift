import SwiftUI
import KabanBoardCore
import WebKit

struct ReferenceRuntime: View {
    @Bindable var demo: ReferenceDemo
    private var theme: ReferenceTheme { .init(dark:demo.dark) }
    var body: some View {
        Group {
            if let id=demo.inspectedFrame,let frame=ReferenceFrame.all.first(where:{$0.id==id}) {
                ReferenceSourceWebView(demo:demo,source:frame.source,interactive:false)
            } else if demo.route=="board" {
                if demo.nativePrototype{ReferenceBoard(demo:demo,theme:theme)}else{ReferenceSourceWebView(demo:demo,source:demo.sourcePage,interactive:true)}
            } else if demo.route=="cards" || demo.route=="mascots" {
                ScrollView { if demo.route=="mascots" {mascots} else {ReferenceCardGallery(demo:demo,theme:theme,kind:"cards-suspicious")} }
            } else {if demo.nativePrototype{ReferenceSettings(demo:demo,theme:theme,kind:demo.route)}else{ReferenceSourceWebView(demo:demo,source:demo.sourcePage,interactive:true)}}
        }
        .sheet(isPresented:Binding(get:{demo.sheet != nil},set:{if !$0{demo.sheet=nil}})) {sheet.padding(24).frame(width:620)}
        .alert("Демонстрация",isPresented:Binding(get:{demo.notice != nil},set:{if !$0{demo.notice=nil}})){Button("Закрыть"){demo.notice=nil}}message:{Text(demo.notice ?? "")}
    }
    @ViewBuilder private var sheet: some View {
        switch demo.sheet {
        case "add":ReferenceAddProjectForm(demo:demo,theme:theme)
        case "return-gate","return-merge":ReferenceReturnForm(demo:demo,theme:theme,merge:demo.sheet=="return-merge")
        case "create","edit": editor
        case "move": move
        case "cancel","reject":VStack(alignment:.leading,spacing:16){Text(demo.sheet=="reject" ? "Отклонить задачу?":"Отменить задачу?").font(.title3.bold());Text("\(demo.selected ?? "SHOP-52") · текущий запуск будет остановлен");Toggle("Сохранить ветку",isOn:$demo.keepBranch);HStack{ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil};ReferenceButton(title:"Вернуть в стадию",theme:theme){demo.sheet="move"};ReferenceButton(title:"Отменить задачу",primary:true,theme:theme){demo.action("Отменить",taskID:demo.selected ?? "SHOP-52");demo.sheet=nil}}}
        case "task-menu":VStack(spacing:12){ForEach(["Изменить…","Перенести…","Отменить…"],id:\.self){label in ReferenceButton(title:label,theme:theme){demo.sheet=label=="Изменить…" ? "edit":label=="Перенести…" ? "move":"cancel";if let task=demo.tasks.first(where:{$0.id==demo.selected}){demo.draftTitle=task.title;demo.draftBody=demo.taskBodies[task.id] ?? ""}}}}
        case "search":TextField("Поиск задач",text:$demo.search).textFieldStyle(.roundedBorder)
        default:VStack(alignment:.leading,spacing:12){Text("Локальный просмотр · демо").font(.headline);Text("Системные команды и репозитории не меняются.");Text("diff --git a/src/payments.ts b/src/payments.ts\n+await gateway.authorize(order)\n-return false\n+return result.approved").font(.system(size:12,design:.monospaced));ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil}}
        }
    }
    private var editor:some View{VStack(alignment:.leading,spacing:12){Text(demo.sheet=="edit" ? "Изменить задачу":"Новая задача").font(.title3.bold());Picker("Проект",selection:$demo.selectedProject){ForEach(demo.visible,id:\.self){Text($0).tag($0)}};TextField("Заголовок",text:$demo.draftTitle).textFieldStyle(.roundedBorder);Text("Описание и критерии приёмки · Markdown").font(.headline);TextEditor(text:$demo.draftBody).frame(height:220).border(theme.line);HStack{Spacer();ReferenceButton(title:"Закрыть",theme:theme){demo.sheet=nil};ReferenceButton(title:"Сохранить",primary:true,theme:theme){demo.saveTask()}.disabled(demo.draftTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}}
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

/// The approved source DOM is the visual implementation; Swift owns demo state/actions.
@MainActor enum ReferenceSourceWeb {
    static var root:URL {Bundle.main.resourceURL!.appendingPathComponent("Resources/Design",isDirectory:true)}
    static func configuration(interactive:Bool)->WKWebViewConfiguration {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        if let compatibility=try? String(contentsOf:root.appendingPathComponent("macos-compatibility.js"),encoding:.utf8){config.userContentController.addUserScript(.init(source:compatibility,injectionTime:.atDocumentEnd,forMainFrameOnly:true))}
        if interactive,let bridge=try? String(contentsOf:root.appendingPathComponent("demo-bridge.js"),encoding:.utf8){config.userContentController.addUserScript(.init(source:bridge,injectionTime:.atDocumentEnd,forMainFrameOnly:true))}
        return config
    }
    static func execute(_ web:WKWebView,_ code:String,arguments:[String:Any]=[:]) async throws {
        try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
            web.callAsyncJavaScript(code,arguments:arguments,in:nil,in:.page,completionHandler:{result in
                switch result {case .success:continuation.resume();case .failure(let error):continuation.resume(throwing:error)}
            })
        }
    }
    static func blockNetwork(_ web:WKWebView) async throws {
        let rules="[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]"
        let list=try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"KabanLocalDesignOnly",encodedContentRuleList:rules)
        if let list {web.configuration.userContentController.add(list)}
    }
    static func allowed(_ url:URL?)->Bool {guard let url,url.isFileURL else{return false};return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/")}
}

enum ReferenceDemoAction:String {
    case selectTask,selectProject,addProjectForm,submitReturn,closeModal,board,byStage,create,edit,move,cancel,acceptFiles,retry,backlog,pause,resume,acceptReview,returnGate,returnMerge,settings,projectGit,stageGit,quota,mcp,identity,addProject,saveSettings,cancelSettings,clearFlag,localDiff,close,trafficClose,trafficMinimize,trafficZoom,answer,setField,setToggle
}

struct ReferenceSourceWebView:NSViewRepresentable {
    @Bindable var demo:ReferenceDemo
    let source:String
    let interactive:Bool
    // Reading these observable values makes SwiftUI update the bridge after mutations.
    private var projection:[String:Any]{demo.domProjection}
    func makeCoordinator()->Coordinator{Coordinator(demo:demo)}
    func makeNSView(context:Context)->WKWebView {
        let config=ReferenceSourceWeb.configuration(interactive:interactive)
        config.userContentController.add(context.coordinator,name:"kabanDemo")
        let web=WKWebView(frame:.zero,configuration:config);web.navigationDelegate=context.coordinator;context.coordinator.web=web
        return web
    }
    func updateNSView(_ web:WKWebView,context:Context){context.coordinator.demo=demo;context.coordinator.projection=projection;context.coordinator.load(source);context.coordinator.project()}
    @MainActor final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
        var demo:ReferenceDemo
        weak var web:WKWebView?
        var source=""
        var ready=false
        var projection:[String:Any]=[:]
        private var lastProjection:Data?
        init(demo:ReferenceDemo){self.demo=demo}
        func load(_ page:String){guard page != source,let web else{return};source=page;ready=false;lastProjection=nil
            Task{do{try await ReferenceSourceWeb.blockNetwork(web);let url=ReferenceSourceWeb.root.appendingPathComponent(page);guard ReferenceSourceWeb.allowed(url) else{return};web.loadFileURL(url,allowingReadAccessTo:ReferenceSourceWeb.root)}catch{demo.notice="Демо: локальный экран не загрузился: \(error.localizedDescription)"}}
        }
        func project(){guard ready,let web,let data=try? JSONSerialization.data(withJSONObject:projection,options:.sortedKeys),data != lastProjection else{return};lastProjection=data;Task{do{try await ReferenceSourceWeb.execute(web,"await window.kabanProject?.(state); return true",arguments:["state":projection])}catch{FileHandle.standardError.write(Data("DOM projection failed: \(error)\n".utf8))}}}
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){ready=true;lastProjection=nil;project()}
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor @Sendable (WKNavigationActionPolicy)->Void){decisionHandler(ReferenceSourceWeb.allowed(navigationAction.request.url) ? .allow:.cancel)}
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){guard message.frameInfo.isMainFrame,ReferenceSourceWeb.allowed(message.frameInfo.request.url),let payload=message.body as? [String:Any],let raw=payload["action"] as? String,let action=ReferenceDemoAction(rawValue:raw) else{return};handle(action,payload)}
        func handle(_ action:ReferenceDemoAction,_ payload:[String:Any]) {
            let id=(payload["taskID"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? demo.selected
            switch action {
            case .selectTask:if let id,demo.tasks.contains(where:{$0.id==id}){demo.selected=id;if !["SHOP-52","SHOP-35","SHOP-31","KBN-17"].contains(id){demo.sheet="task-menu"}}
            case .selectProject:if let project=payload["project"] as? String,demo.projects.contains(project){demo.selectedProject=project;if !demo.visible.contains(project){demo.visible.append(project)}}
            case .addProjectForm:demo.notice=nil;demo.identityMode=0;demo.webModal="add"
            case .board:demo.inspectedFrame=nil;demo.selected=nil;demo.route="board"
            case .byStage:demo.compact.toggle()
            case .create:demo.draftTitle="";demo.draftBody="";demo.sheet="create"
            case .edit:if let id,let task=demo.tasks.first(where:{$0.id==id}){demo.selected=id;demo.draftTitle=task.title;demo.draftBody=demo.taskBodies[id] ?? "";demo.sheet="edit"}
            case .move:demo.selected=id;demo.sheet="move"
            case .cancel:demo.selected=id;demo.sheet="cancel"
            case .acceptFiles:if let id {Task{await demo.acceptFiles(taskID:id)}}
            case .retry:demo.action("Перезапустить",taskID:id)
            case .backlog:demo.action("В Backlog",taskID:id)
            case .pause:demo.action(id==nil ? "Пауза Мака":"Пауза",taskID:id)
            case .resume:demo.action("Продолжить",taskID:id)
            case .acceptReview:demo.action("Принять",taskID:id)
            case .returnGate:demo.selected=id;demo.webModal="return-gate"
            case .returnMerge:demo.selected=id;demo.webModal="return-merge"
            case .settings:demo.route=(payload["label"] as? String)?.contains("Dev")==true ? "general":"pipeline-invalid"
            case .projectGit:demo.route="project-git"
            case .stageGit:demo.route="stage-git"
            case .quota:demo.route="mac-quota"
            case .mcp:demo.route="project-mcp"
            case .identity:demo.route="identity-settings"
            case .addProject:demo.notice=nil;demo.addProject();if demo.notice != nil{demo.webModal=nil}
            case .submitReturn:demo.returnTask(filled:!demo.returnNote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,merge:demo.webModal=="return-merge");demo.webModal=nil
            case .closeModal:demo.webModal=nil
            case .saveSettings:demo.applySettings();demo.notice="Демо: настройки применены в памяти текущего запуска"
            case .cancelSettings:demo.cancelSettings()
            case .clearFlag:demo.flagsCleared.insert(payload["label"] as? String ?? "flag")
            case .localDiff:demo.sheet="diff"
            case .close:demo.selected=nil;demo.inspectedFrame=nil;demo.route="board"
            case .trafficClose:web?.window?.performClose(nil)
            case .trafficMinimize:web?.window?.miniaturize(nil)
            case .trafficZoom:web?.window?.toggleFullScreen(nil)
            case .answer:demo.returnNote="Убери из ветки: .env.local, certs/stripe-test.pem, fixtures/orders-dump.sql";demo.sheet="move"
            case .setField:
                let field=payload["field"] as? String ?? "",value=payload["value"] as? String ?? ""
                let scope=payload["scope"] as? String ?? "settings"
                if field=="comments"{demo.returnNote=value}else if field=="target"{if ["Dev","Test","AI Review","Human Review","Merge","Backlog"].contains(value){demo.returnTarget=value}}else if field=="preset"{demo.preset=value}else if scope=="identity" && field.contains("Имя"){demo.identityName=value}else if scope=="identity" && field.contains("Почта"){demo.identityEmail=value}else if field.contains("Папка"){demo.projectPath=value}else if field=="comments"{demo.returnNote=value}else{demo.stageFields[field]=value};demo.unsaved=true
            case .setToggle:demo.stageFields[payload["field"] as? String ?? "toggle"]=(payload["value"] as? Bool ?? false) ? "on":"off";demo.unsaved=true
            }
        }
    }
}

@MainActor extension ReferenceDemo {
    var domProjection:[String:Any]{["selectedTaskID":selected ?? "","waitingCount":max(0,4+tasks.filter{!["SHOP-55","KBN-17"].contains($0.id) && ["waiting","review","suspicious"].contains($0.status)}.count-5),"webModal":webModal ?? "","identityMode":identityMode,"identityName":identityName,"identityEmail":identityEmail,"projectPath":projectPath,"returnNote":returnNote,"returnTarget":returnTarget,"compact":compact,"dark":dark,"projects":projects,"fields":stageFields,"preset":preset,"acceptedTaskIDs":Array(acceptedTaskIDs),"pending":Array(pending),"staleTaskIDs":Array(staleTaskIDs),"tasks":tasks.filter{!["SHOP-55","KBN-17"].contains($0.id) || $0.id==selected}.map{["id":$0.id,"title":$0.title,"project":$0.project,"status":$0.status,"label":$0.label,"stage":$0.stage]}]}
}
