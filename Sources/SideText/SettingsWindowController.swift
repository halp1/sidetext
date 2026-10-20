import AppKit
import ServiceManagement

/// Security-scoped bookmark for the custom download folder (the app is sandboxed).
enum BookmarkStore {
    private static var accessedURL: URL?

    static func save(folder: URL) {
        let data = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: Prefs.Key.customDownloadBookmark)
        UserDefaults.standard.set(folder.path, forKey: Prefs.Key.customDownloadFolderPath)
        UserDefaults.standard.set(true, forKey: Prefs.Key.useCustomDownloadFolder)
    }

    static func startAccessingDownloadFolder() -> Bool {
        guard UserDefaults.standard.bool(forKey: Prefs.Key.useCustomDownloadFolder),
              let data = UserDefaults.standard.data(forKey: Prefs.Key.customDownloadBookmark) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return false }
        if stale { save(folder: url) }
        accessedURL = url
        return url.startAccessingSecurityScopedResource()
    }

    static func stopAccessingDownloadFolder() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(enabled, forKey: Prefs.Key.launchOnLogin)
        } catch {
            Log.error("Login item update failed: \(error)", category: "App")
            let alert = NSAlert()
            alert.messageText = "Launch on Login"
            alert.informativeText = "SideText couldn't update the login items list:\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}

/// Settings window. Same options as Texty's Preferences pane, all unlocked.
final class SettingsWindowController: NSWindowController {
    private let soundPopup = NSPopUpButton()
    private let downloadPopup = NSPopUpButton()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let zoomSlider = NSSlider(value: 1, minValue: 0.5, maxValue: 2.0, target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open SideText at login", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        build()
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
    }

    private func check(_ title: String, key: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(key)", options: nil)
        return b
    }

    private func popup(_ items: [String], key: String) -> NSPopUpButton {
        let p = NSPopUpButton()
        for (i, title) in items.enumerated() {
            p.addItem(withTitle: title)
            p.lastItem?.tag = i
        }
        p.bind(.selectedTag, to: NSUserDefaultsController.shared, withKeyPath: "values.\(key)", options: nil)
        return p
    }

    private func label(_ s: String, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        l.alignment = .right
        return l
    }

    private func build() {
        // Sounds
        soundPopup.target = self
        soundPopup.action = #selector(soundChosen(_:))

        // Downloads
        downloadPopup.target = self
        downloadPopup.action = #selector(downloadChosen(_:))

        // Zoom
        zoomSlider.numberOfTickMarks = 7
        zoomSlider.allowsTickMarkValuesOnly = false
        zoomSlider.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(Prefs.Key.zoomFactor)", options: nil)
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)

        let notifSettings = NSButton(title: "Notification Settings…", target: self, action: #selector(openNotificationSettings))

        let bounce = popup(["Once", "Until SideText is opened"], key: Prefs.Key.bounceType)
        let space = popup(["Follow Active Space", "Retain Original Space"], key: Prefs.Key.windowSpaceBehaviour)
        let scroll = popup(["System", "Google Messages"], key: Prefs.Key.scrollBarStyle)

        let zoomRow = NSStackView(views: [zoomSlider, zoomLabel])
        zoomSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let soundRow = NSStackView(views: [check("Play sound", key: Prefs.Key.playSound), soundPopup])
        let bounceRow = NSStackView(views: [check("Bounce Dock icon", key: Prefs.Key.enableBounce), bounce])

        let rows: [[NSView]] = [
            [label("General", bold: true), loginCheckbox],
            [label("Zoom Level"), zoomRow],
            [label("Downloads"), downloadPopup],
            [label("Window Spaces"), space],
            [label("Scroll Bars"), scroll],
            [NSView(), NSView()],
            [label("Notifications", bold: true), check("Show notifications for new messages", key: Prefs.Key.showNotifications)],
            [NSView(), soundRow],
            [NSView(), notifSettings],
            [NSView(), NSView()],
            [label("Replies", bold: true), check("Reply from notifications", key: Prefs.Key.enableInlineReplies)],
            [NSView(), check("Show conversation after sending a reply", key: Prefs.Key.showWindowAfterReply)],
            [NSView(), NSView()],
            [label("Dock", bold: true), check("Show unread count badge", key: Prefs.Key.showUnreadBadge)],
            [NSView(), bounceRow],
            [NSView(), NSView()],
            [label("One-Time Codes", bold: true), check("Automatically copy codes to the clipboard", key: Prefs.Key.autoCopyOTP)],
            [NSView(), hint("\u{201C}Copy Code\u{201D} is always available on notifications that contain a code.")],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 130
        for i in 0..<grid.numberOfRows where type(of: rows[i][0]) == NSView.self && type(of: rows[i][1]) == NSView.self {
            grid.row(at: i).height = 6
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
    }

    private func hint(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func refresh() {
        soundPopup.removeAllItems()
        let names = SoundCatalog.names()
        soundPopup.addItems(withTitles: names)
        if !names.contains(Prefs.soundName) { soundPopup.addItem(withTitle: Prefs.soundName) }
        soundPopup.selectItem(withTitle: Prefs.soundName)

        downloadPopup.removeAllItems()
        let folder = Prefs.downloadFolder
        downloadPopup.addItem(withTitle: folder.lastPathComponent)
        downloadPopup.lastItem?.image = NSWorkspace.shared.icon(forFile: folder.path).resized(16)
        downloadPopup.menu?.addItem(.separator())
        downloadPopup.addItem(withTitle: "Downloads")
        downloadPopup.lastItem?.tag = 1
        downloadPopup.addItem(withTitle: "Other…")
        downloadPopup.lastItem?.tag = 2
        downloadPopup.selectItem(at: 0)

        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        zoomChanged()
    }

    @objc private func soundChosen(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        UserDefaults.standard.set(name, forKey: Prefs.Key.soundName)
        SoundCatalog.play(name)
    }

    @objc private func downloadChosen(_ sender: NSPopUpButton) {
        switch sender.selectedItem?.tag {
        case 1:
            UserDefaults.standard.set(false, forKey: Prefs.Key.useCustomDownloadFolder)
            refresh()
        case 2:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose Folder"
            panel.beginSheetModal(for: window!) { [weak self] response in
                if response == .OK, let url = panel.url { BookmarkStore.save(folder: url) }
                self?.refresh()
            }
        default:
            break
        }
    }

    @objc private func zoomChanged() {
        zoomLabel.stringValue = "\(Int((Prefs.zoomFactor * 100).rounded()))%"
    }

    @objc private func loginToggled() {
        LoginItem.set(loginCheckbox.state == .on)
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func openNotificationSettings() { NotificationManager.openNotificationSettings() }
}

extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let img = copy() as! NSImage
        img.size = NSSize(width: side, height: side)
        return img
    }
}
