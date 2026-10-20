import Foundation

/// Finds one-time codes in incoming message text. Texty ships per-language keyword and
/// prefix/suffix regex tables (en, fr, es, de, ja, ru, zh-Hans, pt-BR, ko, it); this is a
/// compact equivalent: a message must contain an OTP keyword, and the code nearest that
/// keyword wins.
enum OTPExtractor {
    private static let keywords: [String] = [
        // English
        "code", "otp", "passcode", "password", "pin", "verification", "verify", "one-time",
        "one time", "security code", "login", "log in", "sign in", "authentication", "2fa", "token",
        // French / Spanish / Portuguese / Italian / German
        "code de", "mot de passe", "código", "codigo", "contraseña", "senha", "codice",
        "verifica", "bestätigung", "passwort", "anmeldung", "verifizierung", "einmal",
        // Russian / Japanese / Chinese / Korean
        "код", "пароль", "認証", "確認コード", "コード", "验证码", "驗證碼", "校验码", "动态码", "인증", "인증번호",
    ]

    private static let codeRegex = try! NSRegularExpression(
        pattern: #"(?<![\w-])((?:[A-Z]{1,3}-)?\d{4,8}|\d{3}[ -]\d{3})(?![\w-])"#,
        options: [])

    static func extract(from text: String) -> String? {
        let lower = text.lowercased()
        let keywordRanges: [Range<String.Index>] = keywords.compactMap { lower.range(of: $0) }
        guard !keywordRanges.isEmpty else { return nil }

        let ns = text as NSString
        let matches = codeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let candidates: [(code: String, location: Int)] = matches.compactMap { m in
            var code = ns.substring(with: m.range(at: 1))
            if code.contains("-"), let dash = code.lastIndex(of: "-"),
               code[code.startIndex..<dash].allSatisfy({ $0.isLetter }) {
                code = String(code[code.index(after: dash)...]) // "G-123456" -> "123456"
            }
            code = code.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            guard code.count >= 4, code.count <= 8 else { return nil }
            // Skip things that look like years in a date context.
            if code.count == 4, let y = Int(code), (1900...2100).contains(y),
               lower.contains("\(y)-") || lower.contains("/\(y)") { return nil }
            return (code, m.range.location)
        }
        guard !candidates.isEmpty else { return nil }

        let keywordOffsets = keywordRanges.map { lower.distance(from: lower.startIndex, to: $0.lowerBound) }
        return candidates.min { a, b in
            distance(a.location, keywordOffsets) < distance(b.location, keywordOffsets)
        }?.code
    }

    private static func distance(_ loc: Int, _ offsets: [Int]) -> Int {
        offsets.map { abs($0 - loc) }.min() ?? Int.max
    }
}
