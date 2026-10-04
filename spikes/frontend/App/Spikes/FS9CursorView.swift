import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class FS9Model {
    var path = ""
    var lines: [String] = []

    func record(_ line: String) {
        SpikeFileLog.append("fs9", line)
        lines.append(line)
    }
}

struct FS9CursorView: View {
    @State private var model = FS9Model()

    var body: some View {
        SpikeScreen(
            code: "FS-9",
            title: "Открыть в Cursor",
            instruments: "Смотрите, какое приложение вышло на передний план и открылась ли папка. Bundle id кандидата не проверялся на этой машине."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Путь к клону", text: Bindable(model).path)
                    Button("Временная папка") { makeTemp() }
                    Button("Открыть") { openInCursor() }
                        .disabled(model.path.isEmpty)
                }
                Text("Сначала `cursor <путь>`, затем NSWorkspace по bundle id \(SpikeIdentity.cursorBundleIDCandidate) и по /Applications/Cursor.app. НЕ ПРОВЕРЕНО: верный ли это bundle id — команда в README.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LogList(lines: model.lines)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func makeTemp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaban-spike-clone-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "клон спайка FS-9\n".write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            model.path = dir.path
            model.record("создана папка \(dir.path)")
        } catch {
            model.record("не создалась папка: \(error.localizedDescription)")
        }
    }

    private func openInCursor() {
        let folder = URL(fileURLWithPath: model.path)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            model.record("нет такой папки")
            return
        }
        if let cli = locateCursorCLI() {
            model.record("CLI \(cli.path)")
            runCLI(cli, folder: folder)
        } else {
            model.record("CLI cursor не найден")
        }
        openByBundle(folder)
    }

    private func locateCursorCLI() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/cursor",
            "/usr/local/bin/cursor",
            NSString(string: "~/.local/bin/cursor").expandingTildeInPath,
        ]
        if let which = whichCursor() {
            candidates.insert(which, at: 0)
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func whichCursor() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["cursor"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private func runCLI(_ executable: URL, folder: URL) {
        let process = Process()
        process.executableURL = executable
        process.arguments = [folder.path]
        do {
            try process.run()
            model.record("CLI запущен pid=\(process.processIdentifier). Смотрите, открылся ли Cursor: ждать завершения процесса нельзя, CLI часто остаётся живым.")
        } catch {
            model.record("CLI не запустился: \(error.localizedDescription)")
        }
    }

    private func openByBundle(_ folder: URL) {
        let bundleID = SpikeIdentity.cursorBundleIDCandidate
        let configured = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let applications = URL(fileURLWithPath: "/Applications/Cursor.app")
        let appURL = configured ?? (FileManager.default.fileExists(atPath: applications.path) ? applications : nil)
        guard let appURL else {
            model.record("приложение Cursor не найдено ни по \(bundleID), ни в /Applications/Cursor.app")
            return
        }
        model.record("NSWorkspace \(appURL.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sink = model
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration) { _, error in
            let message = error.map { "NSWorkspace ошибка: \($0.localizedDescription)" } ?? "NSWorkspace принял запрос"
            Task { @MainActor in
                sink.record(message)
            }
        }
    }
}
