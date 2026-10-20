import AppKit

/// UserDefaults-backed settings. Keys and defaults mirror the ones Texty ships in
/// Defaults.plist, so behavior lines up with the original app. Every "Pro" option is
/// available here without a subscription.
enum Prefs {
    enum Key {
        static let launchOnLogin = "launchOnLogin"
        static let showNotifications = "willShowNotificationForNewMessage"
        static let playSound = "willPlaySoundForNewMessage"
        static let soundName = "soundNameForNewMessage"
        static let showWindowAfterReply = "showWindowAfterNotificationReply"
        static let enableInlineReplies = "enableInlineReplies"
        static let showUnreadBadge = "showUnreadCountBadge"
        static let enableBounce = "enableBounceDockIcon"
        static let bounceType = "bounceDockIconType"
        static let windowSpaceBehaviour = "windowSpaceBehaviour"
        static let scrollBarStyle = "scrollBarStyle"
        static let zoomFactor = "zoomFactor"
        static let useCustomDownloadFolder = "useCustomDownloadFolder"
        static let customDownloadFolderPath = "customDownloadFolderPath"
        static let customDownloadBookmark = "customDownloadBookmark"
        static let autoCopyOTP = "automaticallyCopyOTPCodes"
        static let isFirstLaunch = "isFirstLaunch"
    }

    /// 0 = bounce once (informational), 1 = bounce until the app is activated (critical).
    enum BounceType: Int { case once = 0, untilActive = 1 }
    /// 0 = follow the active space, 1 = keep the window in its original space.
    enum SpaceBehaviour: Int { case followActive = 0, retainOriginal = 1 }
    /// 0 = native macOS scroll bars, 1 = Google Messages styling (the default).
    enum ScrollBarStyle: Int { case system = 0, google = 1 }

    static let defaultSound = "Glass"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.launchOnLogin: false,
            Key.showNotifications: true,
            Key.playSound: true,
            Key.soundName: defaultSound,
            Key.showWindowAfterReply: false,
            Key.enableInlineReplies: true,
            Key.showUnreadBadge: true,
            Key.enableBounce: true,
            Key.bounceType: BounceType.once.rawValue,
            Key.windowSpaceBehaviour: SpaceBehaviour.followActive.rawValue,
            Key.scrollBarStyle: ScrollBarStyle.google.rawValue,
            Key.zoomFactor: 1.0,
            Key.useCustomDownloadFolder: false,
            Key.autoCopyOTP: false,
            Key.isFirstLaunch: true,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var showNotifications: Bool { d.bool(forKey: Key.showNotifications) }
    static var playSound: Bool { d.bool(forKey: Key.playSound) }
    static var soundName: String { d.string(forKey: Key.soundName) ?? defaultSound }
    static var showWindowAfterReply: Bool { d.bool(forKey: Key.showWindowAfterReply) }
    static var enableInlineReplies: Bool { d.bool(forKey: Key.enableInlineReplies) }
    static var showUnreadBadge: Bool { d.bool(forKey: Key.showUnreadBadge) }
    static var enableBounce: Bool { d.bool(forKey: Key.enableBounce) }
    static var bounceType: BounceType { BounceType(rawValue: d.integer(forKey: Key.bounceType)) ?? .once }
    static var spaceBehaviour: SpaceBehaviour {
        SpaceBehaviour(rawValue: d.integer(forKey: Key.windowSpaceBehaviour)) ?? .followActive
    }
    static var scrollBarStyle: ScrollBarStyle {
        ScrollBarStyle(rawValue: d.integer(forKey: Key.scrollBarStyle)) ?? .google
    }
    static var autoCopyOTP: Bool { d.bool(forKey: Key.autoCopyOTP) }

    static var zoomFactor: Double {
        get {
            let v = d.double(forKey: Key.zoomFactor)
            return v == 0 ? 1.0 : min(max(v, 0.5), 2.0)
        }
        set { d.set(min(max(newValue, 0.5), 2.0), forKey: Key.zoomFactor) }
    }

    static var isFirstLaunch: Bool {
        get { d.bool(forKey: Key.isFirstLaunch) }
        set { d.set(newValue, forKey: Key.isFirstLaunch) }
    }

    /// Folder for downloads: the chosen custom folder when enabled, otherwise ~/Downloads.
    static var downloadFolder: URL {
        if d.bool(forKey: Key.useCustomDownloadFolder),
           let path = d.string(forKey: Key.customDownloadFolderPath), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }
}

/// Notification sounds: macOS system sounds plus anything in ~/Library/Sounds.
enum SoundCatalog {
    static func names() -> [String] {
        var result: [String] = []
        let dirs = [
            "/System/Library/Sounds",
            "/Library/Sounds",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds"),
        ]
        let exts: Set<String> = ["aiff", "aif", "caf", "wav", "mp3", "m4a"]
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for f in files.sorted() where exts.contains((f as NSString).pathExtension.lowercased()) {
                let name = (f as NSString).deletingPathExtension
                if !result.contains(name) { result.append(name) }
            }
        }
        return result
    }

    static func play(_ name: String) {
        if let s = NSSound(named: NSSound.Name(name)) {
            s.stop()
            s.play()
        } else {
            NSSound.beep()
        }
    }
}
