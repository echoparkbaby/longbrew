import AppKit

@MainActor
final class DiagnosticsWindowController {
    private var window: NSWindow?
    private var textView: NSTextView?

    func show() {
        if window == nil { build() }
        textView?.string = Diagnostics.report()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window?.isVisible == true || textView?.string.isEmpty == true else { return }
        textView?.string = Diagnostics.report()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
    }

    private func build() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.setAccessibilityLabel("Longbrew diagnostics")
        scroll.documentView = text
        textView = text
        let copy = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiagnostics))
        let note = NSTextField(wrappingLabelWithString: "Includes app and helper status and recent errors from this session. Nothing is sent automatically.")
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [scroll, note, copy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 540),
            scroll.heightAnchor.constraint(equalToConstant: 320),
            note.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 572, height: 425),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Longbrew Diagnostics"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.center()
        window = win
    }
}
