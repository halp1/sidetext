import Foundation

/// A message delivered by the page's Notification shim.
///
/// Texty's parser (decompiled from FUN_100007e04 / FUN_100008790 in 1.3.13) accepts two
/// shapes of the `options` object Google Messages passes to `new Notification(title, options)`:
///   1. `options.data` is a dictionary with a `participants` array; the last participant has
///      `displayName`/`fullName`/`name`, `options.tag` is `"cid:<conversationId>"`, and
///      `options.body` is the text.
///   2. `options.data` is a base64 protobuf string (Texty's `texty.NotificationData`).
/// Both are handled here, with the notification title as the fallback sender name.
struct IncomingMessage: Codable, Equatable {
    var title: String
    var body: String
    var senderName: String?
    var senderPhone: String?
    var conversationID: String?
    // Only explicit IDs are safe for automatic mutations. Protobuf IDs are heuristic.
    var trustedConversationID: String?

    var displayName: String { senderName?.nilIfEmpty ?? title.nilIfEmpty ?? "Unknown" }

    /// A successfully auto-copied code needs no normal notification or attention alert.
    func handleAutomaticOTP(enabled: Bool, copy: (String) -> Bool) -> Bool {
        guard enabled, let code = OTPExtractor.extract(from: body) else { return false }
        return copy(code)
    }

    static func parse(_ raw: Any) -> IncomingMessage? {
        var title = ""
        var options: [String: Any] = [:]

        if let dict = raw as? [String: Any] {
            title = dict["title"] as? String ?? ""
            options = dict["options"] as? [String: Any] ?? [:]
        } else if let arr = raw as? [Any] {
            // Texty's own script posts [title, options].
            title = arr.first as? String ?? ""
            if arr.count > 1 { options = arr[1] as? [String: Any] ?? [:] }
        } else {
            return nil
        }

        let body = (options["body"] as? String) ?? ""
        var msg = IncomingMessage(title: title, body: body)

        if let tag = options["tag"] as? String, tag.hasPrefix("cid:") {
            msg.conversationID = String(tag.dropFirst(4))
            msg.trustedConversationID = msg.conversationID?.nilIfEmpty
        }

        if let data = options["data"] as? [String: Any] {
            if let participants = data["participants"] as? [[String: Any]], let last = participants.last {
                if let display = last["displayName"] as? String {
                    // Display names look like "Name • +1 555…" in group/unknown-contact cases.
                    let parts = display.components(separatedBy: "•")
                    if parts.count > 1 {
                        msg.senderPhone = parts.last?.trimmingCharacters(in: .whitespaces)
                    }
                }
                msg.senderName = (last["name"] as? String) ?? (last["fullName"] as? String)
                    ?? (last["displayName"] as? String)
            }
            if msg.conversationID == nil {
                msg.conversationID = (data["conversationId"] as? String) ?? (data["cid"] as? String)
                msg.trustedConversationID = msg.conversationID?.nilIfEmpty
            }
        } else if let b64 = options["data"] as? String, let bytes = Data(base64Encoded: b64) {
            let strings = Protobuf.strings(in: bytes)
            // Field layout is not published; use the decoded strings as hints only.
            if msg.conversationID == nil,
               let cid = strings.first(where: { $0.count >= 6 && $0.count <= 40 && $0.allSatisfy { $0.isNumber } }) {
                msg.conversationID = cid
            }
            if msg.senderPhone == nil {
                msg.senderPhone = strings.first(where: { $0.hasPrefix("+") && $0.dropFirst().allSatisfy { $0.isNumber || $0 == " " } })
            }
        }

        if msg.senderName == nil, !title.isEmpty { msg.senderName = title }
        if msg.body.isEmpty && msg.title.isEmpty { return nil }
        return msg
    }
}

/// Minimal protobuf wire-format walker that collects UTF-8 strings from length-delimited fields.
enum Protobuf {
    static func strings(in data: Data, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        let b = [UInt8](data)
        var i = 0
        var out: [String] = []
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            switch key & 7 {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), i + Int(len) <= b.count else { return out }
                let chunk = Data(b[i..<(i + Int(len))])
                i += Int(len)
                let nested = strings(in: chunk, depth: depth + 1)
                if !nested.isEmpty {
                    out.append(contentsOf: nested)
                } else if let s = String(data: chunk, encoding: .utf8), !s.isEmpty,
                          s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) {
                    out.append(s)
                }
            default: return out
            }
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
