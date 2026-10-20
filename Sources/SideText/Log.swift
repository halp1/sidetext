import AppKit
import os

/// App log, mirrored to os_log and the in-app Console Output window.
final class Log {
    static let shared = Log()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SideText", category: "app")
    private(set) var lines: [String] = []
    private let maxLines = 5000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static let didAppend = Notification.Name("SideTextLogDidAppend")

    static func info(_ message: String, category: String = "App") { shared.append(message, category: category, level: .info) }
    static func error(_ message: String, category: String = "App") { shared.append(message, category: category, level: .error) }

    private func append(_ message: String, category: String, level: OSLogType) {
        logger.log(level: level, "[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
            NotificationCenter.default.post(name: Log.didAppend, object: line)
        }
    }
}

final class ConsoleWindowController: NSWindowController {
    private let textView = NSTextView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Console Output"
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let copy = NSButton(title: "Copy to Clipboard", target: self, action: #selector(copyAll))
        copy.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            copy.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()

        textView.string = Log.shared.lines.joined(separator: "\n")
        NotificationCenter.default.addObserver(self, selector: #selector(appended(_:)), name: Log.didAppend, object: nil)
    }

    @objc private func appended(_ note: Notification) {
        guard let line = note.object as? String else { return }
        textView.textStorage?.append(NSAttributedString(string: "\n" + line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
}

/// Small non-activating toast shown near the top-right of the screen (used for
/// "Code copied" confirmations), like Texty's CustomToast.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ title: String, subtitle: String? = nil, duration: TimeInterval = 2.5) {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            p.ignoresMouseEvents = true

            let effect = NSVisualEffectView(frame: p.contentView!.bounds)
            effect.material = .hudWindow
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.autoresizingMask = [.width, .height]

            let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemGreen
            icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            t.lineBreakMode = .byTruncatingTail
            let s = NSTextField(labelWithString: subtitle ?? "")
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            s.isHidden = subtitle == nil
            let text = NSStackView(views: [t, s])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let row = NSStackView(views: [icon, text])
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            row.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor),
                row.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            ])
            p.contentView = effect

            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: screen.maxX - 320, y: screen.maxY - 84))
            }
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
            panel = p
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard panel === p else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                    p.orderOut(nil)
                    if panel === p { panel = nil }
                }
            }
        }
    }
}
