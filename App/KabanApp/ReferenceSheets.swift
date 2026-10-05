import SwiftUI
import KabanBoardCore

struct ReferenceReturnForm: View {
    @Bindable var demo: ReferenceDemo
    let theme: ReferenceTheme
    var merge=false
    var filled=false
    var gallery=false
    private var note:Binding<String>{$demo.returnNote}
    private var hasNote:Bool{!note.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    var body:some View {
        VStack(alignment:.leading,spacing:11){
            HStack(alignment:.top,spacing:10){Image(systemName:"arrow.uturn.backward").font(.system(size:15)).frame(width:30,height:30).foregroundStyle(theme.status("waiting").0).background(theme.status("waiting").1,in:RoundedRectangle(cornerRadius:9));VStack(alignment:.leading,spacing:2){Text("Вернуть \(demo.selectedTask?.id ?? (merge ? "SHOP-29" : "SHOP-55")) из \(demo.selectedTask?.stage ?? (merge ? "Merge" : "Checks"))").font(.system(size:14,weight:.bold));Text("\(merge ? "merge":"gate")-стадия · waiting_human · suspicious_files · \(merge ? "1 файл":"2 файла") в наборе").font(.system(size:11)).foregroundStyle(theme.secondary)};Spacer();Button{demo.sheet=nil}label:{Image(systemName:"xmark").font(.system(size:11))}.buttonStyle(.plain)}
            row("Куда") {VStack(alignment:.leading,spacing:5){HStack{Picker("",selection:$demo.returnTarget){Text("Dev").tag("Dev");Text("Test").tag("Test")}.labelsHidden().frame(width:90);Text(merge ? "из on_conflict · первая стадия, которая правит код":"из on_fail · можно Test · только стадии, которые правят код").font(.system(size:10.5)).foregroundStyle(theme.faint)};Text("Заполнено из StageSummary.\(merge ? "onConflict":"onFail"); обе кнопки шлют выбранную стадию явно. Read-only стадий в списке нет.").font(.system(size:10.5)).foregroundStyle(theme.faint)}}
            row("Возвраты"){VStack(alignment:.leading,spacing:5){HStack{ReferenceChip(title:"Всего возвратов 4/5",theme:theme);ReferenceChip(title:merge ? "при конфликте 1/2":"Checks → Dev 1/3  on_fail.limit",theme:theme,tone:merge ? "conflict":nil)};Text("Всего — сумма bounceByReason против общего лимита возвратов, 5. Ручной возврат счётчики не меняет.").font(.system(size:10.5)).foregroundStyle(theme.faint)}}
            row("Замечание агенту"){VStack(alignment:.leading,spacing:5){TextEditor(text:note).font(.system(size:12)).scrollContentBackground(.hidden).padding(4).frame(height:64).background(theme.card,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(hasNote ? theme.accent:theme.strongLine,lineWidth:0.8));if hasNote{Text("Замечание уйдёт агенту Dev в промпт (comments), задача встанет первой в очередь.").font(.system(size:10.5)).foregroundStyle(theme.faint)}else{Button("＋ Подставить «Убери из ветки: \(merge ? "seed-sku.sql":"fixtures/orders-dump.sql, .env.local")»"){demo.returnNote="Убери из ветки: \(merge ? "seed-sku.sql":"fixtures/orders-dump.sql, .env.local")"}.buttonStyle(.plain).font(.system(size:10.5)).foregroundStyle(theme.accent)}}}
            row("Файлы"){VStack(spacing:0){ForEach(merge ? ["seed-sku.sql"]:["fixtures/orders-dump.sql",".env.local"],id:\.self){file in HStack(spacing:6){Image(systemName:"doc").font(.system(size:10));Text(file).font(.system(size:10.5,design:.monospaced)).lineLimit(1);Spacer();Text(file.hasPrefix(".env") ? "412 Б":merge ? "6,8 МБ":"12,4 МБ").font(.system(size:11));ReferenceChip(title:file.hasPrefix(".env") ? "по шаблону .env*":"больше 5 МБ",theme:theme,tone:file.hasPrefix(".env") ? "waiting":nil);Text(hasNote ? "⛨ останется помеченным":"✓ в принятые").font(.system(size:10.5,weight:.semibold)).foregroundStyle(hasNote ? theme.status("waiting").2:theme.secondary)}.padding(.horizontal,9).frame(height:27).overlay(alignment:.top){theme.line.frame(height:0.5)}}}.background(theme.card.opacity(0.7),in:RoundedRectangle(cornerRadius:8))}
            HStack(alignment:.top,spacing:9){Image(systemName:hasNote ? "exclamationmark.shield":"checkmark.circle").foregroundStyle(theme.status(hasNote ? "waiting":"done").0);Text(hasNote ? "Набор не принимается. Файлы остаются помеченными: после запуска агента в Dev и его гейтов проверка повторится, а файл, оставшийся в ветке, сработает снова. Возврат ручной — в лимиты не идёт.":"Набор принимается. Файлы уйдут в принятые (acceptedFiles): с этим содержимым больше не сработают. Попытка не списывается, задача вернётся в Dev без замечания; ручной возврат в лимиты не идёт.").font(.system(size:11)).foregroundStyle(theme.secondary)}.padding(10).background(hasNote ? theme.status("waiting").1:theme.control,in:RoundedRectangle(cornerRadius:9))
            theme.line.frame(height:0.5)
            HStack(spacing:8){Text(hasNote ? "requestChanges(taskId, comments, target: \"\(demo.returnTarget.lowercased())\")":"moveTask(taskId, stage: \"\(demo.returnTarget.lowercased())\")").font(.system(size:9.5,design:.monospaced)).foregroundStyle(theme.faint);Spacer();ReferenceButton(title:"Отмена",theme:theme){demo.sheet=nil};ReferenceButton(title:hasNote ? "Вернуть с замечанием":"Принять файлы и вернуть",icon:hasNote ? "message":"checkmark",primary:true,theme:theme){demo.returnTask(filled:hasNote,merge:merge)}}
        }.padding(.horizontal,16).padding(.vertical,14).foregroundStyle(theme.text).background(theme.dark ? Color(hex:0x24242a).opacity(0.72):Color(hex:0xfafafc).opacity(0.74),in:RoundedRectangle(cornerRadius:14)).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius:14).stroke(theme.strongLine,lineWidth:0.5)).shadow(color:.black.opacity(0.15),radius:20,y:10)
    }
    private func row<V:View>(_ label:String,@ViewBuilder value:()->V)->some View{HStack(alignment:.top,spacing:10){Text(label).font(.system(size:11,weight:.semibold)).foregroundStyle(theme.secondary).frame(width:96,alignment:.leading).padding(.top,4);value().frame(maxWidth:.infinity,alignment:.leading)}}
}

struct ReferenceAddProjectForm:View {
    @Bindable var demo:ReferenceDemo
    let theme:ReferenceTheme
    var mode:Int?=nil
    var inset=false
    @FocusState private var focusedField: IdentityField?
    private var current:Int{mode ?? demo.identityMode}
    var body:some View {
        VStack(alignment:.leading,spacing:inset ? 8 : 10){
            if !inset {HStack(alignment:.top,spacing:10){Image(systemName:"folder").font(.system(size:15)).frame(width:30,height:30).foregroundStyle(theme.accent).background(theme.accent.opacity(0.14),in:RoundedRectangle(cornerRadius:9));VStack(alignment:.leading,spacing:2){Text("Добавить проект").font(.system(size:14,weight:.bold));Text("Папка git-репозитория на этом Маке").font(.system(size:11)).foregroundStyle(theme.secondary)};Spacer();Button{demo.sheet=nil}label:{Image(systemName:"xmark").font(.system(size:11))}.buttonStyle(.plain)}}
            if current>0{HStack(alignment:.top,spacing:9){Image(systemName:"exclamationmark.triangle").foregroundStyle(theme.status("waiting").0);VStack(alignment:.leading,spacing:2){if inset {
                    HStack(spacing:4) { Text("Не задан автор коммитов: укажите имя и почту").font(.system(size:10.5,weight:.semibold)); Text("identity_required").font(.system(size:8.5,design:.monospaced)).padding(3).background(theme.status("waiting").0.opacity(0.12),in:RoundedRectangle(cornerRadius:4)) }.foregroundStyle(theme.status("waiting").2)
                } else { Text("Не задан автор коммитов: укажите имя и почту").font(.system(size:11.5,weight:.semibold)).foregroundStyle(theme.status("waiting").2);ReferenceChip(title:"identity_required",theme:theme,tone:"waiting",mono:true) };Text(current==1 ? "В настройках git нашлось только имя, почты нет. Проект не создан.":"Проект не создан.").font(.system(size:10.5)).fixedSize(horizontal:false,vertical:true).foregroundStyle(theme.secondary)}}.padding(inset ? 6 : 9).background(theme.status("waiting").1,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(theme.status("waiting").0.opacity(0.45),lineWidth:0.5))}
            if !inset {
                row("Папка"){VStack(alignment:.leading,spacing:4){HStack{TextField("~/dev/shop-api",text:$demo.projectPath).textFieldStyle(.plain).font(.system(size:11,design:.monospaced)).padding(.horizontal,7).frame(height:25).background(theme.card,in:RoundedRectangle(cornerRadius:6));ReferenceButton(title:"Выбрать…",theme:theme){Task { await demo.chooseFolder() }}};Text("git-репозиторий · ветка main · .kaban/pipeline.yaml нет").font(.system(size:10.5)).foregroundStyle(theme.faint)}}
                row("Шаблон"){VStack(alignment:.leading,spacing:4){Toggle("Создать шаблон .kaban/ и закоммитить",isOn:$demo.template).toggleStyle(.checkbox).font(.system(size:12));Text("Демон положит шаблон по умолчанию и закоммитит только .kaban/.").font(.system(size:10.5)).foregroundStyle(theme.faint)}}
            }
            if current==0 {row("Автор"){HStack(alignment:.top,spacing:8){Image(systemName:"info.circle").foregroundStyle(theme.faint);Text("Возьмём из настроек git. Демон один раз выполнит git -C ~/dev/shop-api config user.name и user.email — это конфиг репозитория, глобальный и системный. Пробелы по краям обрежутся. Автор сохранится у демона на этом Маке; сменить — в настройках проекта.").font(.system(size:10.5)).foregroundStyle(theme.secondary)}.padding(9).background(theme.control,in:RoundedRectangle(cornerRadius:9))}}
            else {row("Имя") { VStack(alignment: .leading, spacing: 4) {
                    input(demo.identityName, label: current == 1 && !demo.identityName.isEmpty ? "из настроек git" : nil, error: demo.identityDraft.name.highlighted, binding: $demo.identityName).focused($focusedField, equals: .name)
                    if let caption = demo.identityDraft.name.caption { Text(caption).font(.system(size: inset ? 9.5 : 10.5)).foregroundStyle(theme.status("waiting").2).fixedSize(horizontal:false,vertical:true) }
                } };row("Почта"){VStack(alignment:.leading,spacing:4){input(demo.identityEmail,label:current==3 ? "из настроек git":nil,error:demo.identityDraft.email.highlighted || current==2,binding:$demo.identityEmail).focused($focusedField, equals: .email);if current==2 || demo.identityDraft.email.caption != nil {Label(demo.identityDraft.email.caption ?? "Укажите почту",systemImage:"exclamationmark.triangle").font(.system(size:10.5)).foregroundStyle(theme.status("waiting").2)};if !inset { Text("Автор сохранится в настройках проекта на этом Маке (не в .kaban/) и пойдёт в git демона через -c user.name/email. Сменить — в настройках проекта.").font(.system(size:10.5)).foregroundStyle(theme.faint).fixedSize(horizontal:false,vertical:true) }}}}
            theme.line.frame(height:0.5)
            HStack{Spacer();ReferenceButton(title:"Отмена",theme:theme){demo.sheet=nil};ReferenceButton(title:"Добавить",icon:"plus",primary:true,theme:theme){demo.addProject()}}
            Text("→ addProject(path, createTemplate\(current>0 ? ", identity":""))\(current>0 ? " → identity_required":"")").font(.system(size:9.5,design:.monospaced)).foregroundStyle(theme.faint).frame(maxWidth:.infinity,alignment:.trailing)
        }.padding(.horizontal,inset ? 13 : 15).padding(.vertical,inset ? 10 : 13).foregroundStyle(theme.text).background(theme.dark ? Color(hex:0x24242a).opacity(0.72):Color(hex:0xfafafc).opacity(0.74),in:RoundedRectangle(cornerRadius:14)).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius:14).stroke(theme.strongLine,lineWidth:0.5)).shadow(color:.black.opacity(0.12),radius:20,y:10).onAppear { focusedField = demo.identityDraft.focus }.onChange(of: demo.identityDraft.focus) { _, field in focusedField = field }
    }
    private func input(_ value:String,label:String?,error:Bool,binding:Binding<String>)->some View{HStack{TextField("",text:binding).textFieldStyle(.plain).font(.system(size:12));if let label{ReferenceChip(title:label,theme:theme)}}.padding(.horizontal,7).frame(height:25).background(theme.card,in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).stroke(error ? theme.status("waiting").0:theme.strongLine,lineWidth:error ? 1.5:0.5))}
    private func row<V:View>(_ label:String,@ViewBuilder value:()->V)->some View{HStack(alignment:.top,spacing:8){Text(label).font(.system(size:11,weight:.semibold)).foregroundStyle(theme.secondary).frame(width:inset ? 44 : 62,alignment:.leading).padding(.top,5);value().frame(maxWidth:.infinity,alignment:.leading)}}
}

// Each comparison cell owns its fixture state, so editing one panel cannot change another.
struct ReferenceReturnFixture:View {
    @State private var demo:ReferenceDemo
    let theme:ReferenceTheme
    let merge:Bool
    init(theme:ReferenceTheme,merge:Bool,filled:Bool){self.theme=theme;self.merge=merge;let model=ReferenceDemo();if filled{model.returnNote=merge ? "Убери seed-sku.sql из ветки; генерируй данные в тесте.":"Убери fixtures/orders-dump.sql из ветки, генерируй фикстуру в тесте. И .env.local тоже не коммить — ключи бери из .env.example."};_demo=State(initialValue:model)}
    var body:some View{ReferenceReturnForm(demo:demo,theme:theme,merge:merge,gallery:true)}
}
struct ReferenceAddProjectFixture:View {
    @State private var demo:ReferenceDemo
    let theme:ReferenceTheme
    let inset:Bool
    init(theme:ReferenceTheme,mode:Int,inset:Bool=false) {
        self.theme=theme; self.inset=inset
        let model=ReferenceDemo(); model.identityMode=mode
        if mode==3 {
            model.identityName=""; model.identityEmail="artem@example.com"
            model.identityDraft=IdentityDraft().refusing(.init(code:"identity_required", message:IdentityDraft.generalText, params:["invalid":"name", "email":"artem@example.com"]), submitted:nil)
        }
        if mode==1 {
            model.identityDraft=IdentityDraft().refusing(.init(code:"identity_required",message:IdentityDraft.generalText,params:["missing":"email","name":"Артём Палкин"]),submitted:nil)
            model.identityEmail="artem@example.com"
        }
        if mode==2 { _ = model.validateIdentity(submitted:true) }
        _demo=State(initialValue:model)
    }
    var body:some View{ReferenceAddProjectForm(demo:demo,theme:theme,inset:inset)}
}
