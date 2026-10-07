import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static let taskBody = "# Markdown\r\n\r\n**Точный текст**  \r\n- [ ] Пункт\r\n\n## Критерии приёмки\n- [ ] Сохранить пробелы  \n"
    static let editedTaskBody = taskBody + "\n~~~swift\nlet value = 42\n~~~\n"
    static func taskSmoke(_ store: BoardStore) async throws -> [String] {
        if argument("--task-projects") == "yes" { return try await taskProjectDraftSmoke(store) }
        guard let project = store.projection?.projectOrder.first else { throw failure("Task smoke project missing") }
        if argument("--task-smoke-reopen") == "yes" {
            let tasks = store.projection?.tasks.values.filter { $0.title == "Edited task editor smoke" } ?? []
            guard tasks.count == 1, let card = tasks.first, card.priority == 42 else { throw failure("Task or priority not durable / duplicated") }
            await store.select(card.id)
            guard store.detail?.body?.utf8.elementsEqual(editedTaskBody.utf8) == true,
                  store.session.drafts?.record(for: .create(project))?.exactBody == "Unsent draft  \r\n" else {
                throw failure("Exact body or unsubmitted draft lost across application restart")
            }
            return ["real daemon restores one created task, exact edited Markdown and priority 42", "separate UserDefaults suite restores unsent draft without sending it"]
        }
        let main = try await mainTaskWindow()
        store.beginCreation(project)
        let createSheet = try await taskSheet(main)
        try await replaceField(in: createSheet, with: "Task editor smoke")
        try await replaceBody(in: createSheet, with: taskBody)
        try await waitUntil("native create input saved") {
            store.session.drafts?.record(for: .create(project))?.exactBody?.utf8.elementsEqual(taskBody.utf8) == true
        }
        try submitTaskSheet(createSheet)
        try await waitUntil("native create confirmed") { store.createdTaskID != nil && store.creation.commandID == nil && store.canSend && main.attachedSheet == nil }
        guard let id = store.createdTaskID else { throw failure("No correlated created task") }
        await store.select(id)
        guard store.selectedID == id, store.detail?.body?.utf8.elementsEqual(taskBody.utf8) == true else { throw failure("Native create lost exact Markdown or selection") }
        let creations = store.commandJournal?.records.filter { if case .createTask = $0.envelope.command { return true }; return false } ?? []
        guard creations.count == 1, creations.first?.phase == .applied else { throw failure("One create must yield one applied envelope") }
        guard let detail = store.detail else { throw failure("No task detail") }
        store.sheet = .edit(detail.task, detail.body)
        let editSheet = try await taskSheet(main)
        try await replaceField(in: editSheet, with: "Edited task editor smoke")
        try await replaceBody(in: editSheet, with: editedTaskBody)
        try await waitUntil("native edit input saved") { store.session.drafts?.record(for: .edit(id))?.exactBody?.utf8.elementsEqual(editedTaskBody.utf8) == true }
        try submitTaskSheet(editSheet)
        try await waitUntil("native edit confirmed") { store.projection?.tasks[id]?.title == "Edited task editor smoke" && store.projection?.isSent(id) == false && store.canSend && main.attachedSheet == nil }
        guard let card = store.projection?.tasks[id] else { throw failure("Edited card missing") }
        store.sheet = .priority(card)
        let prioritySheet = try await taskSheet(main)
        try await replaceField(in: prioritySheet, with: "42")
        try await waitUntil("native priority draft") { store.session.drafts?.record(for: .priority(id))?.priorityText == "42" }
        try submitTaskSheet(prioritySheet)
        try await waitUntil("native priority confirmation") { store.projection?.tasks[id]?.priority == 42 && store.projection?.isSent(id) == false && store.canSend && main.attachedSheet == nil }
        try store.session.drafts?.save(.init(key: .create(project), draft: .init(title: "Unsent draft"), exactBody: "Unsent draft  \r\n"))
        return ["Return in real SwiftUI create, edit and priority sheets sends typed commands", "taskCreated selects one task after correlation; lost reply uses exact replay", "native TextEditor preserves CRLF, trailing whitespace and Markdown byte for byte", "priority changes on taskUpdated; unsent draft remains separate"]
    }
    private static func taskProjectDraftSmoke(_ store: BoardStore) async throws -> [String] {
        guard store.usesFixture, let projects = store.projection?.projectOrder, projects.count > 1,
              let first = projects.first, let second = projects.dropFirst().first else { throw failure("Two fixture projects required") }
        let main = try await mainTaskWindow()
        store.beginCreation(first)
        var sheet = try await taskSheet(main)
        try await replaceField(in: sheet, with: "First project draft")
        try await replaceBody(in: sheet, with: "First body  \r\n")
        try await waitUntil("first project draft saved") { store.session.drafts?.record(for: .create(first))?.exactBody == "First body  \r\n" }
        func choose(_ project: ProjectID, in sheet: NSWindow) {
            // Programmatic route change checks native remount and saved input.
            // It does not claim pointer/AX activation of the SwiftUI Picker.
            store.beginCreation(project)
        }
        choose(second, in: sheet)
        try await waitUntil("second project form") { if case .create(let id) = store.sheet { return id == second }; return false }
        sheet = try await taskSheet(main)
        try await replaceField(in: sheet, with: "Second project draft")
        try await replaceBody(in: sheet, with: "Second exact body")
        try await waitUntil("second project draft saved") { store.session.drafts?.record(for: .create(second))?.exactBody == "Second exact body" }
        choose(first, in: sheet)
        try await waitUntil("first project restored") { if case .create(let id) = store.sheet { return id == first }; return false }
        sheet = try await taskSheet(main)
        guard let root = sheet.contentView,
              descendants(root).compactMap({ $0 as? NSTextField }).contains(where: { $0.isEditable && $0.stringValue == "First project draft" }),
              descendants(root).compactMap({ $0 as? NSTextView }).contains(where: { !$0.isFieldEditor && $0.string == "First body  \r\n" }) else { throw failure("Project switch lost native draft input") }
        choose(second, in: sheet)
        try await waitUntil("second project restored") { if case .create(let id) = store.sheet { return id == second }; return false }
        sheet = try await taskSheet(main)
        try submitTaskSheet(sheet)
        try await waitUntil("selected project creation confirmed") { store.createdTaskID != nil && main.attachedSheet == nil && store.canSend }
        guard let id = store.createdTaskID, store.projection?.tasks[id]?.projectId == second,
              store.session.drafts?.record(for: .create(first))?.exactBody == "First body  \r\n",
              store.session.drafts?.record(for: .create(second)) == nil else { throw failure("Creation used wrong project or discarded another draft") }
        return ["native editor restores separate title and exact Markdown after programmatic project route changes", "Return creates in selected project; correlated event closes its form and keeps other project draft"]
    }
    private static func mainTaskWindow() async throws -> NSWindow {
        try await waitUntil("main task WindowGroup") { NSApp.windows.contains { $0.styleMask.contains(.titled) } }
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("No main window") }
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        return window
    }
    private static func taskSheet(_ main: NSWindow) async throws -> NSWindow {
        try await waitUntil("native task sheet") { main.attachedSheet != nil }
        let sheet = main.attachedSheet!
        sheet.makeKeyAndOrderFront(nil); NSApp.activate()
        try await waitUntil("task sheet key focus") { sheet.isKeyWindow }
        try await Task.sleep(for: .milliseconds(150))
        return sheet
    }
    private static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private static func replaceField(in sheet: NSWindow, with text: String) async throws {
        guard let root = sheet.contentView, let field = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else { throw failure("Native text field missing") }
        sheet.makeFirstResponder(field)
        try await waitUntil("native field editor") { field.currentEditor() != nil }
        guard let editor = field.currentEditor() as? NSTextView else { throw failure("No field editor") }
        editor.setSelectedRange(.init(location: 0, length: (editor.string as NSString).length))
        editor.insertText(text, replacementRange: editor.selectedRange())
        sheet.makeFirstResponder(nil)
    }
    private static func replaceBody(in sheet: NSWindow, with text: String) async throws {
        guard let root = sheet.contentView, let editor = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor && $0.isEditable }) else { throw failure("Native Markdown editor missing") }
        sheet.makeFirstResponder(editor)
        editor.setSelectedRange(.init(location: 0, length: (editor.string as NSString).length))
        editor.insertText(text, replacementRange: editor.selectedRange())
        sheet.makeFirstResponder(nil)
    }
    private static func submitTaskSheet(_ sheet: NSWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                                          context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
              sheet.performKeyEquivalent(with: event) else { throw failure("Native Return action unavailable") }
    }
    static func prepareTaskEditor(_ store: BoardStore) async throws -> Bool {
        let state = argument("--qa-state") ?? ""
        guard ["editor-long", "editor-preview", "editor-unknown", "editor-stale", "priority"].contains(state),
              let project = store.projection?.projectOrder.first else { return false }
        if state == "editor-long" || state == "editor-preview" {
            try store.session.drafts?.save(.init(key: .create(project), draft: .init(title: String(repeating: "Длинный заголовок задачи · ", count: 8)), exactBody: editedTaskBody + String(repeating: "\n- [ ] Дополнительный пункт проверки и длинный текст, который должен переноситься внутри редактора.", count: 14)))
            store.beginCreation(project)
        } else {
            guard let card = store.projection?.tasks.values.first(where: { TaskActions.canEdit($0) }) else { throw failure("Editable QA task missing") }
            await store.select(card.id)
            guard let detail = store.detail else { throw failure("QA details missing") }
            if state == "priority" { store.sheet = .priority(detail.task) }
            else {
                var base = detail.task
                if state == "editor-stale" { base.title = "Прежний заголовок" }
                try store.session.drafts?.save(.init(key: .edit(card.id), draft: .init(title: "Мой сохранённый заголовок"), exactBody: taskBody, baseCard: base))
                store.sheet = .edit(detail.task, state == "editor-unknown" ? nil : detail.body)
            }
        }
        return true
    }
}
