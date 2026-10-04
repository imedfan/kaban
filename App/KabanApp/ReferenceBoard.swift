import SwiftUI
import KabanBoardCore

struct ReferenceMascot: View {
    let emoji: String
    let theme: ReferenceTheme
    var state = "running"
    var size: CGFloat = 24
    var body: some View {
        Text(emoji).font(.system(size: size * 0.66)).frame(width:size,height:size)
            .background(theme.dark ? Color.white.opacity(0.1) : Color.white.opacity(0.75),in: RoundedRectangle(cornerRadius:size * 0.3))
            .overlay(RoundedRectangle(cornerRadius:size * 0.3).stroke(theme.line,lineWidth:0.5))
            .overlay(alignment:.bottomTrailing) {
                Circle().fill(theme.status(state).0).frame(width:8,height:8).overlay(Circle().stroke(theme.window,lineWidth:2)).offset(x:3,y:3)
            }
    }
}

struct ReferenceTaskCard: View {
    let task: ReferenceTask
    let theme: ReferenceTheme
    var selected = false
    var action: () -> Void = {}
    private var symbol: String {
        switch task.status {
        case "running": "play.fill"
        case "gating": "checklist"
        case "retry": "arrow.clockwise"
        case "suspicious": "exclamationmark.shield"
        case "review": "person.badge.shield.checkmark"
        case "incident": "light.beacon.max"
        case "paused": "pause"
        case "done": "checkmark.circle"
        case "cancelled": "xmark.circle"
        default: "clock"
        }
    }
    var body: some View {
        let colors = theme.status(task.status)
        let attention = ["suspicious","waiting","review","blocked"].contains(task.status)
        Button(action:action) {
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:3) {
                    HStack(spacing:5) {
                        Text(task.emoji).font(.system(size:12))
                        Text(task.id).font(.system(size:10.5,design:.monospaced)).foregroundStyle(theme.faint).fixedSize()
                        Spacer(minLength:0)
                    }.frame(height:14)
                    Text(task.title).font(.system(size:12,weight:.medium)).lineSpacing(1).lineLimit(2)
                        .strikethrough(task.status == "cancelled").foregroundStyle(task.status == "done" || task.status == "cancelled" ? theme.secondary : theme.text)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    ForEach(task.files,id:\.self) { file in
                        Text(file).font(.system(size:10,design:.monospaced)).foregroundStyle(file == "перед слиянием" ? theme.faint : colors.2).lineLimit(1).padding(.top,2)
                    }
                    if task.id=="SHOP-35" {
                        Label("Подмена: Opus 4.5 → Sonnet 4",systemImage:"exclamationmark.triangle").font(.system(size:10.5,weight:.semibold)).foregroundStyle(colors.2).lineLimit(1).padding(.top,2)
                    } else if !task.badges.isEmpty {
                        HStack(spacing:3) { ForEach(Array(task.badges.prefix(2)),id:\.self) { ReferenceChip(title:$0,theme:theme,tone:$0.contains("гейты") ? "done" : nil) } }.padding(.top,2)
                    }
                }.padding(.init(top:7,leading:11,bottom:6,trailing:8))
                HStack(spacing:5) {
                    Image(systemName:symbol).font(.system(size:10))
                    Text(task.label).font(.system(size:10.5,weight:.semibold)).lineLimit(1)
                    Spacer(minLength:0)
                    Text(task.meta).font(.system(size:10)).foregroundStyle(attention ? colors.2.opacity(0.8):theme.faint).lineLimit(1)
                }.padding(.leading,11).padding(.trailing,8).frame(height:22)
                    .foregroundStyle(task.status == "incident" ? .white : attention ? colors.2 : colors.0)
                    .background(task.status == "incident" ? colors.0 : attention ? colors.1 : Color.clear)
                    .overlay(alignment:.top) { theme.line.frame(height:0.5) }
                if let progress = task.progress {
                    GeometryReader { g in Rectangle().fill(colors.0).frame(width:g.size.width * progress / 100) }.frame(height:2).background(colors.1)
                }
            }.background(theme.card,in:RoundedRectangle(cornerRadius:10))
                .overlay(alignment:.leading) { EdgeTextureView(texture: task.project == "shop-api" ? .solid : .diagonal, color:theme.faint).frame(width:4).clipShape(UnevenRoundedRectangle(topLeadingRadius:10,bottomLeadingRadius:10)) }
                .clipShape(RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(selected ? theme.accent : attention ? colors.0.opacity(0.3) : theme.line,lineWidth:selected ? 2 : 0.5))
                .shadow(color:.black.opacity(theme.dark ? 0.25 : 0.06),radius:1,y:1)
        }.buttonStyle(.plain).accessibilityLabel("\(task.id), \(task.title), \(task.label)")
    }
}

struct EdgeTextureView: View {
    enum Texture { case solid, diagonal, dots, bars }
    let texture: Texture
    let color: Color
    var body: some View {
        Canvas { context,size in
            switch texture {
            case .solid: context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(color.opacity(0.75)))
            case .diagonal:
                for y in stride(from: -4.0, to: size.height + 4, by:4) {
                    var p=Path();p.move(to:.init(x:0,y:y));p.addLine(to:.init(x:size.width,y:y+size.width));context.stroke(p,with:.color(color),lineWidth:2)
                }
            case .dots:
                for y in stride(from:0.0,to:size.height,by:4) { context.fill(Path(ellipseIn:.init(x:1,y:y,width:2,height:2)),with:.color(color)) }
            case .bars:
                for y in stride(from:0.0,to:size.height,by:5) { context.fill(Path(CGRect(x:0,y:y,width:size.width,height:3)),with:.color(color)) }
            }
        }
    }
}

struct ReferenceBoard: View {
    @Bindable var demo: ReferenceDemo
    let theme: ReferenceTheme
    var overlay: String? = nil
    var latest = true
    var body: some View {
        ZStack(alignment:.topLeading) {
            surface
            if overlay != nil || demo.selected != nil {
                surface.blur(radius:30).mask {
                    RoundedRectangle(cornerRadius:18).frame(width:600).padding(.top,58).padding(.bottom,8).padding(.trailing,8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.trailing)
                }
            }
            if let overlay {
                theme.text.opacity(0.06).ignoresSafeArea()
                ReferenceDetails(demo:demo,theme:theme,kind:overlay)
                    .frame(width:600).padding(.top,58).padding(.bottom,8).padding(.trailing,8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.trailing)
            } else if let selected = demo.selected {
                ReferenceDetails(demo:demo,theme:theme,kind:selected == "KBN-17" ? "incident" : selected == "SHOP-31" ? "review" : selected == "SHOP-35" ? "substituted" : "suspicious",selectedTaskID:selected)
                    .frame(width:600).padding(.top,58).padding(.bottom,8).padding(.trailing,8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.trailing)
            }
        }.foregroundStyle(theme.text)
    }
    private var surface:some View {ZStack(alignment:.topLeading){
            ReferenceBackdrop(theme:theme)
            sidebar.frame(width:232).padding(8)
            VStack(spacing:0) {
                toolbar.frame(height:56)
                ScrollView {
                    VStack(spacing:8) {
                        banner("Om исчерпан · 2 стадии · до 17.10, 05:40",icon:"gauge.with.dots.needle.67percent",caption:"стоят стадии на моделях Om (знак в шапке), composer-* работают, текущие доигрывают",tone:"waiting")
                        banner("Opus 4.1 недоступен · 2 стадии",icon:"exclamationmark.triangle",caption:"пропал из --list-models, задачи этих стадий ждут в queued",tone:"blocked")
                        banner("Cursor подменяет Opus 4.5 · 1 стадия",icon:"arrow.triangle.2.circlepath",caption:"запрошена Opus 4.5, ответила Sonnet 4; 1 задача у вас, 1 ждёт в queued",tone:"waiting")
                        ForEach(demo.visible,id:\.self) { project in lane(project) }
                    }.padding(.leading,8).padding(.trailing,12).padding(.bottom,12)
                }.scrollIndicators(.hidden)
            }.padding(.leading,248)
    }}
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                ForEach([UInt32(0xff5f57),0xfebc2e,0x28c840],id:\.self) { Circle().fill(Color(hex:$0)).frame(width:12,height:12) }
                Spacer();Image(systemName:"sidebar.left").font(.system(size:15)).foregroundStyle(theme.secondary)
            }.padding(.horizontal,6).frame(height:18).padding(.bottom,14)
            sideRow("Доска",icon:"rectangle.split.3x1",selected:true) { demo.selected=nil;demo.route="board" }
            sideRow("Ждут человека",icon:"hand.raised",count:String(demo.tasks.filter{["waiting","review","suspicious"].contains($0.status) && $0.id != "SHOP-55"}.count),tone:"waiting") { demo.selected="SHOP-52" }
            sideRow("Инциденты",icon:"light.beacon.max",count:String(demo.tasks.filter{$0.status=="incident"}.count),tone:"incident") { demo.selected="KBN-17" }
            HStack { Text("Проекты").font(.system(size:11,weight:.semibold));Spacer();Button { demo.sheet="add" } label:{ Image(systemName:"plus") }.buttonStyle(.plain) }.foregroundStyle(theme.faint).padding(.horizontal,8).padding(.top,10).padding(.bottom,4)
            ForEach(demo.projects,id:\.self) { p in
                Button { if !demo.visible.contains(p) { demo.visible.append(p) } } label: {
                    HStack(spacing:8) {
                        ReferenceMascot(emoji:emoji(p),theme:theme,state:p=="shop-api" ? "waiting" : "paused",size:22)
                        VStack(alignment:.leading,spacing:0) { Text(p).font(.system(size:13));Text(p=="shop-api" ? "ждут 3" : p=="kaban" ? "пайплайн не запустится" : p=="mobile-app" ? "лишний MCP" : "спит").font(.system(size:11)).foregroundStyle(theme.faint) }
                        Spacer();if p=="shop-api" { ReferenceChip(title:"3",theme:theme,tone:"waiting") }
                    }.padding(.horizontal,8).padding(.vertical,5)
                }.buttonStyle(.plain)
                .contextMenu { Button("Настройки проекта") { demo.route="project-git" };Button("Показать на доске") { if !demo.visible.contains(p) {demo.visible.append(p)} };Button("Скрыть с доски") { demo.visible.removeAll{$0==p} } }
            }
            Text("Перетащите проект на доску").font(.system(size:10.5)).foregroundStyle(theme.faint).padding(.horizontal,8).padding(.top,6)
            Spacer()
            VStack(alignment:.leading,spacing:7) {
                HStack { Label("Этот Мак",systemImage:"cpu").font(.system(size:12,weight:.semibold));Spacer();Text("потолок 4").font(.system(size:11)).foregroundStyle(theme.faint) }
                HStack(spacing:3) { ForEach(["🦊","🐗","",""],id:\.self) { e in Text(e).font(.system(size:15)).frame(width:46,height:26).background(theme.control,in:RoundedRectangle(cornerRadius:7)) } }
                HStack { Text("Процессы агентов");Spacer();Text("2 / 4").bold() }.font(.system(size:11))
                ReferenceQuotaBars(theme:theme,compact:true)
                ReferenceButton(title:"Настройки Мака",icon:"gearshape",small:true,theme:theme) {demo.route="mac-quota"}
            }.padding(10).background(theme.lane,in:RoundedRectangle(cornerRadius:12))
        }.padding(.init(top:14,leading:10,bottom:10,trailing:10)).background(theme.glass,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(theme.line,lineWidth:0.5)).shadow(color:.black.opacity(0.1),radius:16,y:8)
    }
    private func sideRow(_ title:String,icon:String,selected:Bool=false,count:String?=nil,tone:String="queued",action:@escaping()->Void) -> some View {
        Button(action:action) { HStack(spacing:8) { Image(systemName:icon).font(.system(size:14)).foregroundStyle(theme.accent);Text(title).font(.system(size:13));Spacer();if let count {ReferenceChip(title:count,theme:theme,tone:tone)} }.padding(.horizontal,8).frame(height:26).background(selected ? theme.control : .clear,in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
    }
    private var toolbar: some View {
        HStack(spacing:8) {
            VStack(alignment:.leading,spacing:1) {Text("Доска").font(.system(size:15,weight:.bold));Text("\(demo.visible.count) проекта на доске").font(.system(size:11)).foregroundStyle(theme.faint)}.padding(.horizontal,8)
            HStack(spacing:2) { ReferenceButton(title:"Дорожки",icon:"rectangle.split.3x1",theme:theme) {demo.compact=false};ReferenceButton(title:"По типу стадии",icon:"square.grid.2x2",theme:theme) {demo.compact.toggle()} }.padding(4).background(theme.glass,in:Capsule())
            Spacer()
            HStack(spacing:7) { Image(systemName:"cpu");Text("Агенты");Text("▮▮▯▯").foregroundStyle(theme.accent);Text("2/4").font(.system(size:12,weight:.bold,design:.monospaced)) }.font(.system(size:12)).padding(.horizontal,12).frame(height:34).background(theme.glass,in:Capsule())
            HStack(spacing:12) { Button {demo.sheet="search"}label:{Image(systemName:"magnifyingglass")};Button {demo.route="cards"}label:{Image(systemName:"bell")};Button {demo.action("Пауза Мака")}label:{Image(systemName:"pause")} }.buttonStyle(.plain).padding(.horizontal,12).frame(height:34).background(theme.glass,in:Capsule())
            ReferenceButton(title:"Задача",icon:"plus",primary:true,theme:theme){demo.sheet="create"}.padding(4).background(theme.glass,in:Capsule())
        }.padding(.leading,8).padding(.trailing,12)
    }
    private func banner(_ title:String,icon:String,caption:String,tone:String) -> some View {
        HStack(spacing:6) {Image(systemName:icon).font(.system(size:12));Text(title).font(.system(size:11.5,weight:.semibold));Text(caption).font(.system(size:11));Spacer();ReferenceButton(title:"Настройки",small:true,theme:theme){demo.route=tone=="waiting" ? "mac-quota" : "pipeline-invalid"} }.padding(.horizontal,10).frame(height:tone=="blocked" ? 26:30).foregroundStyle(tone=="blocked" ? theme.secondary:theme.status(tone).2).background((tone=="blocked" ? theme.card.opacity(0.7):theme.status(tone).1),in:RoundedRectangle(cornerRadius:8))
    }
    private func lane(_ project:String) -> some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Button {if demo.collapsed.contains(project){demo.collapsed.remove(project)}else{demo.collapsed.insert(project)}}label:{Image(systemName:demo.collapsed.contains(project) ? "chevron.right" : "chevron.down").font(.system(size:10))}.buttonStyle(.plain)
                ReferenceMascot(emoji:emoji(project),theme:theme,state:project=="shop-api" ? "waiting" : "paused")
                Text(project).font(.system(size:13,weight:.semibold));ReferenceChip(title:"⑂ main",theme:theme,mono:true)
                Text(project=="shop-api" ? "ждут человека · 3" : project=="kaban" ? "новые запуски не стартуют" : "стоит").font(.system(size:11.5)).foregroundStyle(theme.faint)
                Spacer(minLength:0)
                if project=="kaban" || project=="mobile-app" {ReferenceChip(title:project=="kaban" ? "⚠ Пайплайн не запустится: нет модели у Test, AI Review" : "⚠ Запуски остановлены: лишний MCP-сервер «jira»",theme:theme,tone:"waiting")}
                ReferenceChip(title:"1 процесс",theme:theme)
                Button{demo.route="stage-git"}label:{Image(systemName:"slider.horizontal.3")}.buttonStyle(.plain)
                Button{demo.visible.removeAll{$0==project}}label:{Image(systemName:"xmark").font(.system(size:10))}.buttonStyle(.plain)
            }.padding(.horizontal,4).frame(height:36)
            if !demo.collapsed.contains(project) {
                ReferenceColumns {
                    ForEach(ReferenceDemo.stages,id:\.self) { stage in
                        VStack(spacing:6) {
                            HStack(spacing:4) { Image(systemName:stageSymbol(stage)).font(.system(size:11)).foregroundStyle(theme.status(stage=="Dev" ? "running" : stage=="Human Review" ? "review" : "queued").0);Text(stage).font(.system(size:11.5,weight:.semibold)).fixedSize();Spacer(minLength:0);Text(columnCount(stage,project:project)).fixedSize().font(.system(size:10.5,weight:.semibold)).foregroundStyle(theme.secondary) }.frame(height:28).padding(.horizontal,3)
                            if ["Dev","Test","AI Review"].contains(stage) { Text(columnModel(stage,project:project)).font(.system(size:9.5,weight:stage=="Dev" ? .regular:.semibold,design:.monospaced)).foregroundStyle(stage=="Dev" ? theme.secondary:theme.status("waiting").2).frame(maxWidth:.infinity,alignment:.leading).frame(height:18).padding(.horizontal,4).background(stage=="Dev" ? Color.clear:theme.status("waiting").1,in:RoundedRectangle(cornerRadius:6)) }
                            let tasks=demo.tasks.filter{$0.project==project && $0.stage==stage && $0.id != "KBN-17" && (demo.search.isEmpty || $0.title.localizedCaseInsensitiveContains(demo.search))}
                            if tasks.isEmpty { Text("Пусто").font(.system(size:11)).foregroundStyle(theme.faint).frame(maxWidth:.infinity).frame(height:50).overlay(RoundedRectangle(cornerRadius:9).strokeBorder(theme.line,style:StrokeStyle(lineWidth:1,dash:[3,3]))) }
                            ForEach(tasks) { card in ReferenceTaskCard(task:card,theme:theme,selected:demo.selected==card.id){demo.selected=card.id} }
                            Spacer(minLength:0)
                        }.padding(.horizontal,5).padding(.bottom,6).background(theme.column,in:RoundedRectangle(cornerRadius:10))
                    }
                }.padding(.bottom,8)
            }
        }.padding(.horizontal,8).background(theme.lane,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(theme.line,lineWidth:0.5))
    }
    private func columnCount(_ stage:String,project:String)->String {
        let counts = project=="shop-api" ? ["2","2/3","0/2","0/2","1/5","1","24"] : ["3","1/2","0/2","0/1","1/2","0","9"]
        return counts[ReferenceDemo.stages.firstIndex(of:stage) ?? 0]
    }
    private func columnModel(_ stage:String,project:String)->String {
        if stage=="Dev" {return "♧ composer-1  Cm"}
        if project=="kaban" {return stage=="Test" ? "⚠ нет модели":"⚠ auto — запрещено"}
        return stage=="Test" ? "⌛ sonnet-4.5  Om  исчерпан":"⌛ opus-4.5  Om  подмена"
    }
    private func emoji(_ p:String)->String { p=="shop-api" ? "🦊" : p=="kaban" ? "🐗" : p=="mobile-app" ? "🐙" : p=="infra" ? "🐢" : "🦉" }
    private func stageSymbol(_ s:String)->String {switch s {case "Backlog":"tray";case "Dev":"hammer";case "Test":"flask";case "AI Review":"eye";case "Human Review":"person.badge.shield.checkmark";case "Merge":"arrow.triangle.merge";default:"checkmark.circle"}}
}

/// Source col2 flex values. Each column measures its actual content at its allocated width.
struct ReferenceColumns: Layout {
    var weights: [CGFloat] = [0.65,1.35,1.45,1.3,1.0,0.6,0.5]
    var spacing: CGFloat = 6
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let width=proposal.width ?? 1164
        let widths=columnWidths(width,count:subviews.count)
        let height=subviews.enumerated().map{$0.element.sizeThatFits(.init(width:widths[$0.offset],height:nil)).height}.max() ?? 0
        return .init(width:width,height:height)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let widths=columnWidths(bounds.width,count:subviews.count)
        var x=bounds.minX
        for (i,view) in subviews.enumerated(){view.place(at:.init(x:x,y:bounds.minY),anchor:.topLeading,proposal:.init(width:widths[i],height:bounds.height));x+=widths[i]+spacing}
    }
    private func columnWidths(_ width:CGFloat,count:Int)->[CGFloat]{let used=Array(weights.prefix(count));let total=used.reduce(0,+);return used.map{max(0,width-spacing*CGFloat(max(0,count-1)))*$0/total}}
}
