import SwiftUI

struct FS8YamlView: View {
    @State private var original = ""
    @State private var surgical = ""
    @State private var naive = ""
    @State private var failures: [String] = []
    @State private var runs = "13"
    @State private var model = "opus-4.5"
    @State private var loadError = ""

    var body: some View {
        SpikeScreen(
            code: "FS-8",
            title: "pipeline.yaml, комментарии и порядок",
            instruments: "Отдельный шаблон не нужен. Кнопка «Эталон» гоняет те же инварианты, что и yaml self-check в run.sh."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !loadError.isEmpty {
                    Text(loadError).foregroundStyle(.red)
                }
                HStack {
                    TextField("max_runs_per_task", text: $runs)
                        .frame(width: 160)
                    TextField("model стадии dev", text: $model)
                        .frame(width: 220)
                    Button("Эталон 13 / opus-4.5") { applyCanonical() }
                    Button("Применить поля") { applyCustom() }
                }
                if failures.isEmpty {
                    Text(surgical.isEmpty ? "Правка ещё не запускалась." : "Инварианты эталона выполнены.")
                        .foregroundStyle(surgical.isEmpty ? Color.secondary : Color.green)
                } else {
                    ForEach(failures, id: \.self) { failure in
                        Text(failure).foregroundStyle(.red)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    yamlPane("Исходник", original)
                    yamlPane("Точечная правка", surgical)
                    yamlPane("Наивная перезапись", naive)
                }
                Text("Наивная перезапись — стенд вместо Yams: комментарии снимаются, ключи сортируются. Yams в спайк не подключался. Подмножество парсера описано в PipelineYamlEditor.swift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .onAppear(perform: load)
        }
    }

    private func yamlPane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            TextEditor(text: .constant(text))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        guard original.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "pipeline", withExtension: "yaml") else {
            loadError = "В бандле нет pipeline.yaml"
            return
        }
        do {
            original = try String(contentsOf: url, encoding: .utf8)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func applyCanonical() {
        runs = "13"
        model = "opus-4.5"
        guard !original.isEmpty else { return }
        do {
            let report = try PipelineYamlEditor.applyFixtureEdits(to: original)
            surgical = report.surgical
            naive = report.naive
            failures = report.failures
            SpikeFileLog.append("fs8", failures.isEmpty ? "canonical ok" : failures.joined(separator: " | "))
        } catch {
            failures = [String(describing: error)]
            SpikeFileLog.append("fs8", "canonical error \(error)")
        }
    }

    private func applyCustom() {
        guard !original.isEmpty else { return }
        do {
            let runsPath: [PipelineYamlEditor.Component] = [.key("board"), .key("max_runs_per_task")]
            let modelPath: [PipelineYamlEditor.Component] = [.key("stages"), .index(1), .key("model")]
            var edited = try PipelineYamlEditor.surgicalReplace(in: original, path: runsPath, newValue: runs)
            edited = try PipelineYamlEditor.surgicalReplace(in: edited, path: modelPath, newValue: model)
            surgical = edited
            naive = PipelineYamlEditor.naiveRewrite(
                in: original,
                replacements: [(runsPath, runs), (modelPath, model)]
            )
            failures = commentFailures(original: original, surgical: edited)
            SpikeFileLog.append("fs8", "custom runs=\(runs) model=\(model) failures=\(failures.count)")
        } catch {
            failures = [String(describing: error)]
        }
    }

    private func commentFailures(original: String, surgical: String) -> [String] {
        let left = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let right = surgical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        if left.count != right.count {
            found.append("число строк изменилось")
        }
        for index in 0..<min(left.count, right.count) where left[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") && left[index] != right[index] {
            found.append("комментарий изменился: \(left[index])")
        }
        return found
    }
}
