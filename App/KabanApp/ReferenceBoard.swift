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
                        Text(task.id).font(.system(size:10,design:.monospaced)).foregroundStyle(theme.faint).fixedSize()
                        Spacer(minLength:0)
                        if task.id == "SHOP-36" { Text("↑").font(.system(size:10,weight:.bold)).foregroundStyle(theme.status("incident").2) }
                    }.frame(height:14)
                    Text(task.title).font(.system(size:12,weight:.medium)).lineSpacing(1).lineLimit(2)
                        .strikethrough(task.status == "cancelled").foregroundStyle(task.status == "done" || task.status == "cancelled" ? theme.secondary : theme.text)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    ForEach(task.files,id:\.self) { file in
                        Text(file).font(.system(size:10,design:.monospaced)).foregroundStyle(file == "перед слиянием" ? theme.faint : colors.2).lineLimit(1).padding(.top,2)
                    }
                    if task.id=="SHOP-35" && task.label == "Подмена модели" {
                        Label("Подмена: Opus 4.5 → Sonnet 4",systemImage:"exclamationmark.triangle").font(.system(size:10.5,weight:.semibold)).foregroundStyle(colors.2).lineLimit(1).padding(.top,2)
                    } else if !task.badges.isEmpty {
                        ReferenceFlow(spacing:3) { ForEach(Array(task.badges.prefix(2)),id:\.self) { ReferenceCardBadge(title:$0,theme:theme) } }.padding(.top,2)
                    }
                }.padding(.init(top:7,leading:11,bottom:6,trailing:8))
                HStack(spacing:5) {
                    Image(systemName:symbol).font(.system(size:10))
                    Text(task.label).font(.system(size:10.5,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength:0)
                    Text(task.meta).font(.system(size:10)).foregroundStyle(attention ? colors.2.opacity(0.8):theme.faint).lineLimit(1)
                }.padding(.leading,11).padding(.trailing,8).frame(height:22)
                    .foregroundStyle(task.status == "incident" ? .white : attention ? colors.2 : task.status == "queued" ? theme.secondary : colors.2)
                    .background(task.status == "incident" ? colors.0 : attention ? colors.1 : Color.clear)
                    .overlay(alignment:.top) { theme.line.frame(height:0.5) }
                if let progress = task.progress {
                    GeometryReader { g in Rectangle().fill(colors.0).frame(width:g.size.width * progress / 100) }.frame(height:2).background(colors.1)
                }
            }.background(theme.card,in:RoundedRectangle(cornerRadius:10))
                .overlay(alignment:.leading) { EdgeTextureView(texture: task.project == "shop-api" ? .solid : task.project == "kaban" ? .diagonal : task.project == "mobile-app" ? .dots : .bars, color:theme.faint).frame(width:4).clipShape(UnevenRoundedRectangle(topLeadingRadius:10,bottomLeadingRadius:10)) }
                .clipShape(RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(selected ? theme.accent : attention ? colors.0.opacity(0.3) : theme.line,lineWidth:selected ? 2 : 0.5))
                .shadow(color:.black.opacity(theme.dark ? 0.25 : 0.06),radius:1,y:1)
        }.buttonStyle(.plain).accessibilityLabel("\(task.id), \(task.title), \(task.label)")
    }
}

private struct ReferenceCardBadge: View {
    let title: String
    let theme: ReferenceTheme
    private var appearance: (tone: String?, symbol: String?) {
        if title.contains("гейты") { return ("done", nil) }
        if title.contains("возврат") { return ("running", title.contains("конфликт") ? "arrow.triangle.merge" : "arrow.uturn.backward") }
        if title == "после конфликта" { return ("running", "arrow.triangle.merge") }
        if title == "git ×1 разрешено" { return ("done", "key") }
        if title == "без критериев приёмки" || title == "main грязная" { return ("retry", "exclamationmark.triangle") }
        if title == "пересечение файлов" { return ("retry", "square.3.layers.3d") }
        if title.hasPrefix("stall") { return ("incident", "timer") }
        if title == "5 отказов" { return ("incident", "nosign") }
        if title == "runner_auth" { return (nil, "key") }
        if title == "rate_limit" { return (nil, "bolt") }
        if title == "request_human" { return (nil, "bubble") }
        if title.hasPrefix("Human Review") { return (nil, "hourglass") }
        return (nil, nil)
    }
    var body: some View {
        let style = appearance
        HStack(spacing:3) {
            if let symbol = style.symbol { Image(systemName:symbol).font(.system(size:9)) }
            Text(title).font(.system(size:10,weight:.semibold))
        }.fixedSize().padding(.horizontal,5).frame(height:16)
            .foregroundStyle(style.tone.map { theme.status($0).2 } ?? theme.secondary)
            .background(style.tone.map { theme.status($0).1 } ?? theme.control,in:RoundedRectangle(cornerRadius:5))
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
    var version = "latest"
    private var base: Bool { version == "base" }
    private var sidebarWidth: CGFloat { demo.sidebarHidden ? 0 : 248 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            surface
            if overlay != nil || demo.selected != nil {
                ReferenceDetails(demo: demo, theme: theme, kind: overlay ?? demo.detailKind,
                    selectedTaskID: overlay == nil ? demo.selected : nil)
                    .frame(width: 600).padding(.top, 58).padding(.bottom, 8).padding(.trailing, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }.foregroundStyle(theme.text)
    }
    private var surface: some View {
        ZStack(alignment: .topLeading) {
            ReferenceBackdrop(theme: theme)
            if !demo.sidebarHidden { sidebar.frame(width: 232).padding(8) }
            GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar.frame(height: 60)
                ScrollView(geometry.size.width >= 1184 ? [.vertical] : [.horizontal, .vertical]) {
                    VStack(spacing: 8) {
                        flags
                        if demo.visible.isEmpty {
                            ContentUnavailableView("Доска пуста", systemImage: "rectangle.split.3x1",
                                description: Text("Добавьте проект из боковой панели"))
                        } else if demo.compact { groupedStages }
                        else { ForEach(demo.visible, id: \.self) { lane($0) } }
                    }.frame(width: max(1164, geometry.size.width - 20)).padding(.leading, 8).padding(.trailing, 12).padding(.bottom, 12)
                }.scrollIndicators(.hidden)
                .dropDestination(for: String.self) { values, _ in
                    guard let project = values.first, demo.projects.contains(project) else { return false }
                    demo.showProject(project); return true
                }
            }
            }.padding(.leading, sidebarWidth)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ReferenceTrafficLights()
                Spacer()
                Button { demo.sidebarHidden.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 15)) }
                    .buttonStyle(.plain).help("Скрыть боковую панель")
            }.foregroundStyle(theme.secondary).padding(.horizontal, 6).frame(height: 18).padding(.bottom, 14)
            sideRow("Доска", icon: "rectangle.split.3x1", selected: true) { demo.selected = nil }
            sideRow("Ждут человека", icon: "hand.raised", count: String(demo.waitingCount), tone: "waiting") {
                demo.selected = demo.tasks.first { ["waiting", "review", "suspicious"].contains($0.status) }?.id
            }
            sideRow("Инциденты", icon: "light.beacon.max", count: String(demo.incidentCount), tone: "incident") {
                demo.selected = demo.tasks.first { $0.status == "incident" }?.id
            }
            HStack {
                Text("Проекты").font(.system(size: 11, weight: .semibold)); Spacer()
                Button { demo.identityMode = 0; demo.sheet = "add" } label: { Image(systemName: "plus") }.buttonStyle(.plain)
            }.foregroundStyle(theme.faint).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            ForEach(demo.projects, id: \.self) { project in
                Button { demo.showProject(project) } label: {
                    HStack(spacing: 8) {
                        if base { Image(systemName: demo.visible.contains(project) ? "checkmark.square.fill" : "square").foregroundStyle(theme.accent) }
                        ReferenceMascot(emoji: emoji(project), theme: theme, state: projectState(project), size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(project).font(.system(size: 13))
                            Text(projectSubtitle(project)).font(.system(size: 11)).foregroundStyle(theme.faint)
                        }
                        Spacer(minLength: 0)
                        if project == "shop-api", !base { ReferenceChip(title: "3", theme: theme, tone: "waiting") }
                        if base {
                            if project == "kaban" { ReferenceChip(title:"1",theme:theme,tone:"incident") }
                            else if project == "mobile-app" { ReferenceChip(title:"3",theme:theme,tone:"waiting") }
                            else if project == "shop-api" || project == "docs-site" { Text(project == "shop-api" ? "⌘1" : "⌘4").font(.system(size:10)).foregroundStyle(theme.faint) }
                            else if project == "infra" { Image(systemName:"folder").font(.system(size:11)).foregroundStyle(theme.secondary) }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                }.buttonStyle(.plain).draggable(project)
                .contextMenu {
                    Button("Настройки проекта") { demo.openSettings("project-git", project: project) }
                    Button("Показать на доске") { demo.showProject(project) }
                    Button("Скрыть с доски") { demo.visible.removeAll { $0 == project } }
                }
            }
            if !base { Text("Перетащите проект на доску, чтобы добавить дорожку").font(.system(size: 10.5)).foregroundStyle(theme.faint).padding(.horizontal, 8).padding(.top, 6) }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Label("Этот Мак", systemImage: "cpu").font(.system(size: 12, weight: .semibold)); Spacer(); Text("потолок 4").font(.system(size: 11)).foregroundStyle(theme.faint) }
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Text((base ? (demo.runningCount >= 4 ? ["🦊", "🦊", "🐗", "🐙"] : ["🦊", "", "🐗", "🐙"]) : ["🦊", "🐗", "", ""])[index])
                            .font(.system(size: 15)).frame(maxWidth: .infinity).frame(height: 26)
                            .background(theme.control, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                HStack { Text("Процессы агентов"); Spacer(); Text("\(demo.runningCount) / 4").bold() }.font(.system(size: 11))
                if base { HStack { Text("Веса"); Spacer(); Text("🦊 2 · 🐗 1 · 🐙 1 · 🦉 1").foregroundStyle(theme.faint) }.font(.system(size:11)) }
                HStack { Label("Cursor", systemImage: "bolt"); Spacer(); Text(base ? (overlay != nil ? "в норме" : theme.dark ? "cooldown до 16:40" : "нет входа") : "Om исчерпан").foregroundStyle(theme.status(base ? (overlay != nil ? "done" : theme.dark ? "retry" : "incident") : "waiting").2) }.font(.system(size: 11))
                if !base { theme.line.frame(height: 0.5); ReferenceQuotaBars(theme: theme, compact: true) }
            }.padding(10).background(theme.lane, in: RoundedRectangle(cornerRadius: 12))
        }.padding(.init(top: 14, leading: 10, bottom: 10, trailing: 10))
            .background(theme.glass, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 16, y: 8)
    }
    private func sideRow(_ title: String, icon: String, selected: Bool = false, count: String? = nil, tone: String = "queued", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(theme.accent)
                Text(title).font(.system(size: 13)); Spacer()
                if let count { ReferenceChip(title: count, theme: theme, tone: count == "0" ? nil : tone) }
            }.padding(.horizontal, 8).frame(height: 26).background(selected ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            if demo.sidebarHidden { Button { demo.sidebarHidden = false } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Доска").font(.system(size: 15, weight: .bold))
                Text(base ? (demo.visible.count == demo.projects.count ? "все 5 проектов" : "4 из 5 проектов") : "\(demo.visible.count) проекта на доске").font(.system(size: 11)).foregroundStyle(theme.faint)
            }.padding(.horizontal, 8)
            if base {
                HStack(spacing: 8) {
                Picker("Проекты", selection: $demo.mode) {
                    ForEach(["Один", "Несколько", "Все"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).frame(width: 182)
                .onChange(of: demo.mode) { _, value in demo.visible = value == "Один" ? [demo.selectedProject] : value == "Все" ? demo.projects : demo.projects.filter { $0 != "infra" } }
                Menu {
                    ForEach(demo.projects, id: \.self) { project in
                        Button((demo.visible.contains(project) ? "✓ " : "") + project) { if demo.visible.contains(project) { demo.visible.removeAll { $0 == project } } else { demo.showProject(project) } }
                    }
                } label: { Text(demo.visible.map { emoji($0) }.joined()).font(.system(size: 12)) }.menuStyle(.borderlessButton).fixedSize()
                }.padding(4).background(theme.glass, in: Capsule())
            }
            HStack(spacing: 2) {
                toolbarTab("Дорожки", icon: "rectangle.split.3x1", selected: !demo.compact) { demo.compact = false }
                toolbarTab("По типу стадии", icon: "square.grid.2x2", selected: demo.compact) { demo.compact = true }
            }.padding(4).background(theme.glass, in: Capsule())
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "cpu"); Text("Агенты")
                HStack(spacing: 3) { ForEach(0..<4) { index in RoundedRectangle(cornerRadius: 1).fill(index < demo.runningCount ? theme.accent : theme.control).frame(width: 5, height: 11) } }
                Text("\(demo.runningCount)/4").font(.system(size: 12, weight: .bold, design: .monospaced))
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 34).background(theme.glass, in: Capsule())
            HStack(spacing: 12) {
                Button { demo.sheet = "search" } label: { Image(systemName: "magnifyingglass") }.help("Поиск · ⌘F")
                Button { demo.sheet = "notifications" } label: { Image(systemName: "bell") }.help("Уведомления")
                Button { demo.pauseMac() } label: { Image(systemName: demo.macPaused ? "play" : "pause") }.help(demo.macPaused ? "Продолжить" : "Пауза Мака")
            }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: 34).background(theme.glass, in: Capsule())
            ReferenceButton(title: "Задача", icon: "plus", primary: true, theme: theme) { demo.draftTitle = ""; demo.draftBody = ""; demo.sheet = "create" }
                .padding(4).background(theme.glass, in: Capsule())
        }.padding(.leading, 8).padding(.trailing, 12)
    }
    private func toolbarTab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.horizontal, 10).frame(height: 26).background(selected ? theme.card : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
    @ViewBuilder private var flags: some View {
        if base {
            if overlay == nil && !demo.flagsCleared.contains("runner") {
                if theme.dark { flag("Лимит Cursor",icon:"bolt",caption:"новые запуски не стартуют во всех проектах до 16:40 (cooldown 30 мин), текущие доигрывают",tone:"retry",buttons:["Снять cooldown сейчас"]) }
                else { flag("Cursor недоступен: не выполнен вход", icon: "exclamationmark.triangle", caption: "runner_auth · новые запуски не стартуют во всех проектах, текущие доигрывают. Выполните cursor-agent login", tone: "incident", buttons: ["Проверить снова"]) }
            }
        } else {
            if !demo.flagsCleared.contains("quota") { flag("Om исчерпан · 2 стадии · до 17.10, 05:40", icon: "hourglass", caption: "· стоят стадии на моделях Om (знак в шапке), composer-* работают, текущие доигрывают", tone: "waiting", buttons: ["Сменить модель стадии…"]) }
            if !demo.flagsCleared.contains("unavailable") { flag("Opus 4.1 недоступен · 2 стадии", icon: "nosign", caption: "· пропал из --list-models, задачи этих стадий ждут в queued", tone: nil, buttons: ["Сменить модель", "Снять флаг"]) }
            if !demo.flagsCleared.contains("substituted") { flag("Cursor подменяет Opus 4.5 · 1 стадия", icon: "exclamationmark.triangle", caption: "· запрошена Opus 4.5, ответила Sonnet 4; 1 задача у вас, 1 ждёт в queued", tone: nil, buttons: ["Показать задачи", "Снять флаг"]) }
        }
    }
    private func flag(_ title: String, icon: String, caption: String, tone: String?, buttons: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)); Text(title).font(.system(size: 11.5, weight: .semibold)).fixedSize()
            Text(caption).font(.system(size: 11)).lineLimit(1); Spacer(minLength: 0)
            ForEach(buttons, id: \.self) { label in
                ReferenceButton(title: label, small: true, theme: theme) {
                    if label == "Снять флаг" { demo.flagsCleared.insert(title.contains("недоступен") ? "unavailable" : "substituted") }
                    else if label == "Показать задачи" { demo.selected = "SHOP-35" }
                    else if base { demo.flagsCleared.insert("runner") }
                    else { demo.openSettings("pipeline-invalid",project:"kaban") }
                }
            }
        }.padding(.horizontal, 10).frame(height: tone == nil ? 26 : 30)
            .foregroundStyle(tone.map { theme.status($0).2 } ?? theme.secondary)
            .background(tone.map { theme.status($0).1 } ?? theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
    private func lane(_ project: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { if !demo.collapsed.insert(project).inserted { demo.collapsed.remove(project) } } label: { Image(systemName: demo.collapsed.contains(project) ? "chevron.right" : "chevron.down").font(.system(size: 10)) }.buttonStyle(.plain)
                ReferenceMascot(emoji: emoji(project), theme: theme, state: projectState(project))
                Text(project).font(.system(size: 13, weight: .semibold)); ReferenceChip(title: "⑂ main", theme: theme, mono: true)
                Text(base ? (project == "kaban" ? "инцидент в KBN-17" : project == "mobile-app" ? "машет · ждут человека" : project == "docs-site" ? "спит · очередь пуста" : project == "infra" ? "недоступен" : (overlay != nil ? "работает · 2 агента" : "работает · 1 агент")) : project == "shop-api" ? "ждут человека · 3" : project == "kaban" ? "новые запуски не стартуют" : project == "docs-site" ? "спит · очередь пуста" : "стоит").font(.system(size:11.5)).foregroundStyle(base && project == "kaban" ? theme.status("incident").2 : theme.faint)
                Spacer(minLength: 0)
                if base && project == "shop-api" && !demo.flagsCleared.contains("merge") {
                    ReferenceChip(title:"⑂ Слияние остановлено: правки в рабочей копии main пересекаются с SHOP-30",theme:theme,tone:"blocked")
                    ReferenceButton(title:"Проверить снова",small:true,theme:theme) { demo.flagsCleared.insert("merge") }
                }
                if base && project == "docs-site" && !demo.flagsCleared.contains("docs-pause") {
                    ReferenceChip(title:"Ⅱ Проект на паузе — новые запуски не стартуют",theme:theme)
                    ReferenceButton(title:"Возобновить",small:true,theme:theme) { demo.flagsCleared.insert("docs-pause") }
                }
                if base && project == "infra" && !demo.flagsCleared.contains("infra") {
                    ReferenceChip(title:"Проект недоступен: папка ~/dev/infra не найдена, задачи стоят в queued",theme:theme,tone:"blocked")
                    ReferenceButton(title:"Указать путь…",small:true,theme:theme) { Task { await demo.chooseFolder(); demo.flagsCleared.insert("infra") } }
                    ReferenceButton(title:"Проверить снова",small:true,theme:theme) { demo.flagsCleared.insert("infra") }
                }
                if !base, project == "kaban", !demo.flagsCleared.contains("pipeline") {
                    ReferenceChip(title: "⚠ Пайплайн не запустится: нет модели у Test, AI Review", theme: theme, tone: "waiting")
                    ReferenceButton(title: "Указать модели", small: true, theme: theme) { demo.openSettings("pipeline-invalid", project: "kaban") }
                } else if project == "mobile-app", !demo.flagsCleared.contains("mcp") {
                    ReferenceChip(title: base ? "3/3 ждут человека — новые задачи из Backlog не берутся" : "Запуски остановлены: лишний MCP-сервер «jira»", theme: theme, tone: "waiting")
                    if !base { ReferenceButton(title: "Настройки MCP", small: true, theme: theme) { demo.openSettings("project-mcp", project: "mobile-app") } }
                }
                if project == "shop-api" || base && project == "kaban" { ReferenceChip(title: project == "shop-api" ? "вес 2" : "вес 1", theme: theme) }
                if base && project == "mobile-app" { ReferenceChip(title:"в работе 1",theme:theme) }
                if !base || project != "infra" {
                    ReferenceChip(title: project == "docs-site" ? "готово 31" : project == "mobile-app" && !base ? "в очереди 4" : project == "shop-api" && base && overlay != nil ? "2 процесса" : "1 процесс", theme: theme)
                }
                Button { demo.openSettings("general", project: project) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("Настройки проекта")
                if !base { Button { demo.visible.removeAll { $0 == project } } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Убрать дорожку") }
            }.padding(.horizontal, 4).frame(height: 36)
            if !demo.collapsed.contains(project) {
                let stages = base && project == "kaban" ? ["Backlog", "Dev", "Lint", "AI Review", "Human Review", "Merge", "Done"] : ReferenceDemo.stages
                ReferenceColumns(weights: base ? (project == "kaban" ? [1, 1, 0.18, 1, 1, 1, 1] : Array(repeating: 1, count: 7)) : [0.65, 1.35, 1.45, 1.3, 1, 0.6, 0.5]) {
                    ForEach(stages, id: \.self) { stage in
                        if stage == "Lint" { VStack(spacing: 8) { Image(systemName: "checklist"); Text("Lint").rotationEffect(.degrees(90)).frame(height: 36); Text("1").padding(4).background(theme.card, in: RoundedRectangle(cornerRadius: 8)); Spacer() }.font(.system(size: 11)).foregroundStyle(theme.status("gating").2).padding(.top, 8).background(theme.status("gating").1, in: RoundedRectangle(cornerRadius: 10)) }
                        else { column(stage, project: project) }
                    }
                }.padding(.bottom, 8)
            }
        }.padding(.horizontal, 8).background(theme.lane, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(base && project == "kaban" ? theme.status("incident").0.opacity(0.35) : theme.line, lineWidth: 0.5))
    }
    private func column(_ stage: String, project: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: stageSymbol(stage)).font(.system(size: 11)).foregroundStyle(theme.status(stage == "Dev" || stage == "Test" ? "running" : stage == "Human Review" ? "review" : stage == "Merge" ? "conflict" : stage == "Done" ? "done" : "queued").0)
                Text(stage).font(.system(size: 11.5, weight: .semibold)).fixedSize(); Spacer(minLength: 0)
                if let project { ReferenceChip(title: columnCount(stage, project: project), theme: theme) }
            }.frame(height: 28).padding(.horizontal, 3)
            if !base, ["Dev", "Test", "AI Review"].contains(stage), let project { Text(columnModel(stage, project: project)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(stage == "Dev" ? theme.secondary : theme.status("waiting").2).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18).padding(.horizontal, 4).background(stage == "Dev" ? .clear : theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 6)).padding(.top,-4).padding(.bottom,5) }
            let tasks = demo.tasks.filter { (project == nil ? demo.visible.contains($0.project) : $0.project == project) && $0.stage == stage && (demo.search.isEmpty || $0.title.localizedCaseInsensitiveContains(demo.search) || $0.id.localizedCaseInsensitiveContains(demo.search)) }
            VStack(spacing:6) {
                if tasks.isEmpty { Text("Пусто").font(.system(size: 11)).foregroundStyle(theme.faint).frame(maxWidth: .infinity).frame(height: 50).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))) }
                ForEach(tasks) { task in
                    ReferenceTaskCard(task: task, theme: theme, selected: demo.selected == task.id) { demo.selected = task.id }
                        .draggable(task.id).contextMenu {
                            Button("Изменить…") { demo.selected = task.id; demo.editSelected() }
                            Button("Перенести…") { demo.selected = task.id; demo.sheet = "move" }
                            Button("Отменить…") { demo.selected = task.id; demo.sheet = "cancel" }
                        }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 5).padding(.bottom, 6).background(theme.column, in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: String.self) { values, _ in guard let id = values.first else { return false }; return demo.moveTask(id, to: stage, in: project) }
    }
    private var groupedStages: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 6) { ForEach(ReferenceDemo.stages, id: \.self) { stage in column(stage, project: nil).frame(width: 220) } }
        }
    }
    private func columnCount(_ stage: String, project: String) -> String {
        let count = demo.tasks.filter { $0.project == project && $0.stage == stage }.count
        let used = demo.tasks.filter { $0.project == project && $0.stage == stage && ["running", "gating", "retry"].contains($0.status) }.count
        let limits = ["Dev": project == "shop-api" ? 3 : 2, "Test": 2, "AI Review": project == "shop-api" ? 2 : 1, "Human Review": project == "shop-api" ? 5 : 2]
        if let limit = stage == "Dev" ? Int(demo.projectSettings[project]?.fields["WIP-лимит"] ?? "") ?? limits[stage] : limits[stage] { return "\(stage == "Human Review" ? count : used)/\(limit)" }
        // The supplied mockups show aggregate history counts alongside the visible sample cards.
        let extras: Int
        if stage == "Done" { extras = project == "shop-api" ? (base ? 22 : 23) : project == "kaban" && base ? 8 : 0 }
        else if stage == "Backlog", project == "kaban" { extras = base ? 4 : 2 }
        else { extras = 0 }
        return String(count + extras)
    }
    private func columnModel(_ stage: String, project: String) -> String {
        if stage == "Dev" { return "♧ \(demo.projectSettings[project]?.fields["Модель"] ?? "composer-1")  Cm" }
        if let settings = demo.projectSettings[project] {
            let model = stage == "Test" ? settings.model : settings.requested
            if !model.isEmpty && model != "auto" { return "♧ " + model }
        }
        if project == "kaban" { return stage == "Test" ? "⚠ нет модели" : "⚠ auto — запрещено" }
        return stage == "Test" ? "⌛ sonnet-4.5  Om  исчерпан" : "⚠ opus-4.5  Om  подмена"
    }
    private func projectState(_ project: String) -> String { project == "shop-api" ? "waiting" : base && project == "kaban" ? "incident" : "paused" }
    private func projectSubtitle(_ project: String) -> String { project == "shop-api" ? (base ? "работает" : "ждут 3") : project == "kaban" ? (base ? "тревожится" : "пайплайн некорректен") : project == "mobile-app" ? (base ? "машет · 3 ждут" : "лишний MCP") : project == "infra" ? "недоступен" : "спит" }
    private func emoji(_ project: String) -> String { project == "shop-api" ? "🦊" : project == "kaban" ? "🐗" : project == "mobile-app" ? "🐙" : project == "infra" ? "🐢" : "🦉" }
    private func stageSymbol(_ stage: String) -> String { switch stage { case "Backlog": "tray"; case "Dev": "hammer"; case "Test": "flask"; case "AI Review": "eye"; case "Human Review": "person.badge.shield.checkmark"; case "Merge": "arrow.triangle.merge"; default: "checkmark.circle" } }
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
