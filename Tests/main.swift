import Foundation

// Compiled together with OTPExtractor.swift and IncomingMessage.swift by scripts/test.sh.
var failures = 0
func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("ok   \(label)")
    } else {
        print("FAIL \(label): got \(actual), expected \(expected)")
        failures += 1
    }
}

// OTP extraction
expect(OTPExtractor.extract(from: "Your verification code is 482913. Don't share it."), "482913", "en verification code")
expect(OTPExtractor.extract(from: "G-748211 is your Google verification code."), "748211", "google G- prefix")
expect(OTPExtractor.extract(from: "Use 3391 to log in to Acme"), "3391", "4 digit login")
expect(OTPExtractor.extract(from: "Votre code de vérification est 120934"), "120934", "fr code")
expect(OTPExtractor.extract(from: "Ваш код: 5521"), "5521", "ru code")
expect(OTPExtractor.extract(from: "验证码 884213，5分钟内有效"), "884213", "zh code")
expect(OTPExtractor.extract(from: "Running 10 min late, see you at 1830"), nil, "no keyword")
expect(OTPExtractor.extract(from: "Call me at 555 1234 tonight"), nil, "phone number, no keyword")

// Notification payload: Google Messages dictionary form (as decompiled from Texty).
let dictPayload: [String: Any] = [
    "title": "Alex",
    "options": [
        "body": "Hey, are we still on for tonight?",
        "tag": "cid:12345",
        "data": ["participants": [["displayName": "Me"], ["displayName": "Alex • +1 555-0100", "name": "Alex"]]],
    ],
]
let m1 = IncomingMessage.parse(dictPayload)
expect(m1?.conversationID, "12345", "dict cid from tag")
expect(m1?.senderName, "Alex", "dict sender name")
expect(m1?.senderPhone, "+1 555-0100", "dict phone from display name")
expect(m1?.body, "Hey, are we still on for tonight?", "dict body")

// Texty's own array form: [title, options]
let m2 = IncomingMessage.parse(["Sam", ["body": "ok"]] as [Any])
expect(m2?.displayName, "Sam", "array form title fallback")

// Base64 protobuf form: field 1 = "98765432" (cid), field 2 = "+15550100" (phone).
var proto = Data([0x0a, 8]) + Data("98765432".utf8) + Data([0x12, 9]) + Data("+15550100".utf8)
let m3 = IncomingMessage.parse(["title": "Taylor", "options": ["body": "hi", "data": proto.base64EncodedString()]])
expect(m3?.conversationID, "98765432", "protobuf cid")
expect(m3?.senderPhone, "+15550100", "protobuf phone")
_ = proto.count

expect(IncomingMessage.parse(["title": "", "options": [:]]) == nil, true, "empty payload rejected")

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
