import Foundation

/// matches a prompt on the cursor's line (`Password:`, `[sudo] password for me:`,
/// `Mot de passe :`, ...). new/repeat password and passphrase prompts don't count:
/// the saved password isn't the answer there.
public enum PasswordPrompt {
    public static func matches(_ textBeforeCursor: String) -> Bool {
        let line = textBeforeCursor.trimmingCharacters(in: .whitespaces)
        guard line.count <= 160, line.hasSuffix(":") || line.hasSuffix("：") else { return false }
        // only the end of the line matters: a shell prompt or log line can mention
        // a password earlier on.
        let tail = line.lowercased().suffix(60)
        guard words.contains(where: { tail.contains($0) }) else { return false }
        return !excluded.contains { tail.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    private static let words = [
        "password", "passwort", "mot de passe", "contraseña", "senha", "wachtwoord", "パスワード", "密码", "密碼",
        "пароль", "passcode",
    ]

    private static let excluded = [
        "new", "retype", "re-enter", "reenter", "again", "confirm", "verify", "repeat", "nouveau", "nouvel",
        "neues", "passphrase",
    ]
}
