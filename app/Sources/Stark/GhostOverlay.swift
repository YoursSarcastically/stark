import AppKit

/// The suggestion, drawn on top of whatever app the user is typing in.
///
/// Two presentations, chosen by how much the focused app is willing to tell us:
///
///  - **inline** — dimmed ghost text sitting exactly at the caret, in the
///    field's own font. Requires precise caret bounds from AX.
///  - **pill** — a small floating chip near the bottom of the focused window,
///    used when the app won't report caret geometry (Electron without AX,
///    Catalyst, custom editors). Less magical, but honest and still usable.
///
/// The panel is borderless, non-activating, and ignores mouse events, so it
/// never steals focus or interrupts typing.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let backdrop = NSView()

    private(set) var isVisible = false

    init() {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false

        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(backdrop)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        p.contentView = container
        panel = p
    }

    /// Ghost text at the caret, matching the field's font.
    func showInline(_ text: String, at caret: CGRect, font: NSFont?) {
        guard !text.isEmpty, let panel else { return }
        let f = font ?? NSFont.systemFont(ofSize: max(11, min(caret.height * 0.72, 24)))
        label.font = f
        label.stringValue = text
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.75)
        backdrop.layer?.backgroundColor = NSColor.clear.cgColor

        let width = min(label.intrinsicContentSize.width + 8, 520)
        let height = max(caret.height, f.pointSize + 4)
        // Sit on the caret's baseline, immediately to its right.
        let frame = CGRect(x: caret.maxX + 1, y: caret.minY, width: width, height: height)
        panel.setFrame(clamped(frame), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Fallback chip, anchored to the focused window, when the caret is unknown.
    func showPill(_ text: String, near window: CGRect) {
        guard !text.isEmpty, let panel else { return }
        let f = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.font = f
        label.stringValue = "⇥ " + text
        label.textColor = .labelColor
        backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.96).cgColor
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.separatorColor.cgColor

        let width = min(label.intrinsicContentSize.width + 20, 460)
        let frame = CGRect(x: window.midX - width / 2,
                           y: window.minY + 18,
                           width: width, height: 24)
        panel.setFrame(clamped(frame), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Keep the overlay fully on whichever screen it mostly occupies.
    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }
}
