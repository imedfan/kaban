import Foundation

/// Durations in `pipeline.yaml`: `30s`, `2m`, `1h`, `1h30m`, or a bare integer (seconds).
public enum DurationParser {
    public static func seconds(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if let n = Int(s) { return n >= 0 ? n : nil }
        var total = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isASCII && ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            switch ch {
            case "s": total += n
            case "m": total += n * 60
            case "h": total += n * 3600
            case "d": total += n * 86400
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        return number.isEmpty && sawUnit ? total : nil
    }

    public static func format(_ seconds: Int) -> String {
        if seconds % 3600 == 0 && seconds > 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 && seconds > 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
