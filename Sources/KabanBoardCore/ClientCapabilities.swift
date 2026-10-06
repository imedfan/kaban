import KabanProtocol

extension DaemonCapabilities {
    public func supports(_ command: CommandName) -> Bool {
        commands.first { $0.name == command.rawValue }?.support == .supported
    }
    public func supportsOperation(_ name: String) -> Bool {
        operations.first { $0.name == name }?.supported == true
    }
    public func requireSession() throws {
        for name in ["snapshot", "command", "synchronize", "subscribe", "ephemeral"] where !supportsOperation(name) {
            throw CommandError(code: CommandError.unsupportedOperationCode, message: "Служба Kaban не поддерживает подключение приложения (\(name)). Обновите службу.")
        }
    }
}
