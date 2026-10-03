import Foundation
import Security

/// Team ID текущего процесса. Пусто у ad-hoc подписи.
enum SigningProbe {
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let info,
              let dict = info as? [String: Any]
        else {
            return nil
        }
        guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return nil
        }
        return team
    }
}
