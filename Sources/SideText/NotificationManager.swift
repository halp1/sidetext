import AppKit
import UserNotifications

protocol NotificationManagerDelegate: AnyObject {
    func notificationManager(_ m: NotificationManager, didRequestReply text: String, to message: IncomingMessage)
    func notificationManager(_ m: NotificationManager, didOpen message: IncomingMessage)
}

/// Native notifications for incoming messages, with inline reply and one-click code copy.
/// Category/action layout follows Texty's UserNotificationManager (NEW_MESSAGE_WITH_REPLY,
/// COPY_OTP, phone offline/online); the Pro-gated variants are not needed here.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    weak var delegate: NotificationManagerDelegate?

    private let center = UNUserNotificationCenter.current()
    private let messageKey = "message"
    private let otpKey = "otp"

    enum Category {
        static let message = "NEW_MESSAGE"
        static let messageWithReply = "NEW_MESSAGE_WITH_REPLY"
        static let messageWithOTP = "NEW_MESSAGE_WITH_OTP"
        static let messageWithReplyAndOTP = "NEW_MESSAGE_WITH_REPLY_AND_OTP"
        static let phoneStatus = "PHONE_STATUS"
    }
    enum Action {
        static let reply = "REPLY_ACTION"
        static let copyCode = "COPY_OTP_ACTION"
    }

    func configure() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply",
                                                  options: [], textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Message")
        let copy = UNNotificationAction(identifier: Action.copyCode, title: "Copy Code", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.message, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.messageWithReply, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.messageWithOTP, actions: [copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.messageWithReplyAndOTP, actions: [copy, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.phoneStatus, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Log.info("Notification authorization granted=\(granted) \(error.map { "error=\($0)" } ?? "")", category: "Notifications")
        }
    }

    func checkAuthorization(prompt: Bool) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .denied, prompt else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Notifications Disabled"
                alert.informativeText = "SideText needs notification access to alert you about new messages. Enable notifications in System Settings."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { Self.openNotificationSettings() }
            }
        }
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Posting

    func post(message: IncomingMessage) {
        let otp = OTPExtractor.extract(from: message.body)
        if let otp, Prefs.autoCopyOTP {
            copyToClipboard(otp, auto: true)
        }
        guard Prefs.showNotifications else {
            if Prefs.playSound { SoundCatalog.play(Prefs.soundName) }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = message.displayName
        if let phone = message.senderPhone, phone != message.displayName { content.subtitle = phone }
        content.body = message.body
        content.threadIdentifier = "conversation.\(message.conversationID ?? message.displayName)"
        var info: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(message) { info[messageKey] = data }
        if let otp { info[otpKey] = otp }
        content.userInfo = info

        let canReply = Prefs.enableInlineReplies
        switch (canReply, otp != nil) {
        case (true, true): content.categoryIdentifier = Category.messageWithReplyAndOTP
        case (true, false): content.categoryIdentifier = Category.messageWithReply
        case (false, true): content.categoryIdentifier = Category.messageWithOTP
        default: content.categoryIdentifier = Category.message
        }

        // Custom sounds are played with NSSound so any system or ~/Library/Sounds sound works,
        // not only those inside the app bundle.
        if Prefs.playSound { SoundCatalog.play(Prefs.soundName) }

        let request = UNNotificationRequest(identifier: "message.\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.error("Could not add notification: \(error)", category: "Notifications") }
        }
    }

    func postPhoneStatus(online: Bool) {
        guard Prefs.showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = online ? "Phone back online" : "Phone offline"
        content.body = online ? "Messages can be sent and received again."
            : "Messages can't be delivered until the phone is back online."
        content.categoryIdentifier = Category.phoneStatus
        let request = UNNotificationRequest(identifier: online ? "phone.online" : "phone.offline", content: content, trigger: nil)
        center.removeDeliveredNotifications(withIdentifiers: ["phone.online", "phone.offline"])
        center.add(request)
    }

    func removeAllDelivered() { center.removeAllDeliveredNotifications() }

    private func copyToClipboard(_ code: String, auto: Bool) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            Toast.show("\u{201C}\(code)\u{201D} copied to clipboard",
                       subtitle: auto ? "Copied from a new message" : "Copied to clipboard")
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banners even when the app is frontmost (sound is played separately).
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let message = (info[messageKey] as? Data).flatMap { try? JSONDecoder().decode(IncomingMessage.self, from: $0) }

        switch response.actionIdentifier {
        case Action.reply:
            if let text = (response as? UNTextInputNotificationResponse)?.userText
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let message {
                Log.info("Notification reply requested", category: "Notifications")
                DispatchQueue.main.async { self.delegate?.notificationManager(self, didRequestReply: text, to: message) }
            }
        case Action.copyCode:
            if let code = info[otpKey] as? String { copyToClipboard(code, auto: false) }
        case UNNotificationDefaultActionIdentifier:
            if let message {
                DispatchQueue.main.async { self.delegate?.notificationManager(self, didOpen: message) }
            } else {
                DispatchQueue.main.async { AppDelegate.shared?.showMainWindow() }
            }
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        DispatchQueue.main.async { AppDelegate.shared?.showPreferences() }
    }
}

/// Dock badge and attention bouncing.
final class DockManager {
    static let shared = DockManager()
    private var newSinceActive = 0
    private var pageUnread: Int?
    private var attentionRequest: Int?

    /// Called for every incoming message.
    func messageArrived() {
        if !NSApp.isActive {
            newSinceActive += 1
            if Prefs.enableBounce {
                if let r = attentionRequest { NSApp.cancelUserAttentionRequest(r) }
                attentionRequest = NSApp.requestUserAttention(Prefs.bounceType == .untilActive ? .criticalRequest : .informationalRequest)
            }
        }
        refresh()
    }

    /// Unread conversation count scraped from the page (nil if unknown).
    func setPageUnread(_ n: Int?) {
        pageUnread = n
        refresh()
    }

    func appBecameActive() {
        newSinceActive = 0
        if let r = attentionRequest { NSApp.cancelUserAttentionRequest(r); attentionRequest = nil }
        refresh()
    }

    func refresh() {
        guard Prefs.showUnreadBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        // Prefer the page's unread count; fall back to messages received while in the background.
        let count = max(pageUnread ?? 0, NSApp.isActive ? 0 : newSinceActive)
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}
