@MainActor enum AppArguments {
    static func value(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func qaValue(_ name: String) -> String? {
        #if KABAN_QA
        value(name)
        #else
        nil
        #endif
    }
    static var isQA: Bool {
        #if KABAN_QA
        BoardQA.isActive
        #else
        false
        #endif
    }
}
