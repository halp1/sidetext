import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NotificationManagerDelegate {
    static weak var shared: AppDelegate?

    private var window: NSWindow!
    private var messagesVC: MessagesViewController!
    private var settings: SettingsWindowController?
    private var console: ConsoleWindowController?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // When started as a login item, stay in the background (no window) until opened.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        NotificationManager.shared.delegate = self
        NotificationManager.shared.configure()
        buildMainMenu()

        messagesVC = MessagesViewController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Messages"
        window.contentViewController = messagesVC
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SideTextMainWindow")
        if !window.setFrameUsingName("SideTextMainWindow") { window.center() }
        window.tabbingMode = .disallowed
        applySpaceBehaviour()

        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)

        if !launchedAtLogin { showMainWindow() }

        if Prefs.isFirstLaunch {
            Prefs.isFirstLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.showWelcome() }
        } else {
            NotificationManager.shared.checkAuthorization(prompt: true)
        }
    }

    // Keep running in the background when the window closes, so notifications keep arriving.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DockManager.shared.appBecameActive()
        NotificationManager.shared.removeAllDelivered()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Message", action: #selector(newMessage), keyEquivalent: "")
        menu.addItem(withTitle: "Show Messages", action: #selector(showMainWindowAction), keyEquivalent: "")
        return menu
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            window.orderOut(nil)
            return false
        }
        return true
    }

    // MARK: Window

    func showMainWindow() {
        applySpaceBehaviour()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPreferences() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applySpaceBehaviour() {
        var behavior = window.collectionBehavior
        behavior.remove([.moveToActiveSpace, .managed])
        if Prefs.spaceBehaviour == .followActive {
            behavior.insert(.moveToActiveSpace)
        } else {
            behavior.insert(.managed)
        }
        window.collectionBehavior = behavior
    }

    @objc private func prefsChanged() {
        DispatchQueue.main.async { self.applySpaceBehaviour() }
    }

    private func showWelcome() {
        showMainWindow()
        let alert = NSAlert()
        alert.messageText = "Welcome to SideText"
        alert.informativeText = """
        SideText brings Google Messages to your Mac so you can text from your Android phone. \
        It supports RCS, full-size photos and videos, and reactions.

        Pair your phone by scanning the QR code with Google Messages (Device pairing). \
        SideText keeps running in the background and notifies you when new messages arrive.
        """
        alert.addButton(withTitle: "Continue")
        let checkbox = NSButton(checkboxWithTitle: "Open SideText at login", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox
        if alert.runModal() == .alertFirstButtonReturn, checkbox.state == .on { LoginItem.set(true) }
        NotificationManager.shared.checkAuthorization(prompt: true)
    }

    // MARK: NotificationManagerDelegate

    func notificationManager(_ m: NotificationManager, didRequestReply text: String, to message: IncomingMessage) {
        messagesVC.queueReply(text, to: message)
    }

    func notificationManager(_ m: NotificationManager, didOpen message: IncomingMessage) {
        showMainWindow()
        messagesVC.open(message: message)
    }

    // MARK: Actions

    @objc func newMessage() { showMainWindow(); messagesVC.startNewMessage() }
    @objc func showMainWindowAction() { showMainWindow() }
    @objc func showPreferencesAction() { showPreferences() }
    @objc func reloadMessages() { messagesVC.reload(clearCache: false) }
    @objc func reloadMessagesClearingCache() { messagesVC.reload(clearCache: true) }
    @objc func zoomIn() { messagesVC.zoom(by: 0.1) }
    @objc func zoomOut() { messagesVC.zoom(by: -0.1) }
    @objc func zoomActual() { messagesVC.zoom(by: nil) }
    @objc func showConsole() {
        if console == nil { console = ConsoleWindowController() }
        console?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showHelp() { NSWorkspace.shared.open(URL(string: "https://support.google.com/messages/answer/7611075")!) }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()
        let name = "SideText"

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferencesAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: name)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Message", action: #selector(newMessage), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        edit.addItem(submenu: spelling, title: "Spelling and Grammar")
        let subs = NSMenu(title: "Substitutions")
        subs.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        subs.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        subs.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        edit.addItem(submenu: subs, title: "Substitutions")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Actual Size", action: #selector(zoomActual), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        let zi2 = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zi2.isAlternate = true
        zi2.keyEquivalentModifierMask = [.command]
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Reload Messages", action: #selector(reloadMessages), keyEquivalent: "r")
        let hard = view.addItem(withTitle: "Reload and Clear Cache", action: #selector(reloadMessagesClearingCache), keyEquivalent: "r")
        hard.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Show Console Output", action: #selector(showConsole), keyEquivalent: "")
        main.addItem(submenu: view, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Messages", action: #selector(showMainWindowAction), keyEquivalent: "1")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Google Messages Help", action: #selector(showHelp), keyEquivalent: "?")
        main.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}
