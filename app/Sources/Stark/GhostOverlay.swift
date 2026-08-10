import AppKit

/// Inline ghost text: the suggestion drawn at the caret, in the field's own
/// font, dimmed. Nothing else.
///
/// Every container this went through — capsule, card, glass, pill, rail — put a
/// shape on screen that competed with the sentence it was continuing, and each
/// one had to be positioned, which meant it could land on top of the user's
/// text. Text has no such problem: it sits where the next word would go, in the
/// same face and size, one step dimmer. If the model is right you barely notice
/// it appeared; if it is wrong you keep typing straight through it.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

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

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        p.contentView = root
        panel = p
    }

    /// `font` is the field's own face where the app reports it, so the ghost
    /// text lines up with what has already been typed instead of looking pasted
    /// on. `caret` is the cursor rect; `field` is used only to keep the text
    /// from spilling out of the input it belongs to.
    func show(_ text: String, caret: CGRect?, field: CGRect?, font: NSFont?) {
        guard !text.isEmpty, let panel, let caret else { hide(); return }

        let f = font ?? .systemFont(ofSize: 14)
        label.font = f
        label.stringValue = text
        // Dimmed rather than coloured: this is the same sentence, just not
        // committed yet. A tint would make it look like a different kind of
        // content.
        label.textColor = NSColor.textColor.withAlphaComponent(0.42)

        var width = label.intrinsicContentSize.width + 2
        // Never run past the right edge of the field it belongs to.
        if let field { width = min(width, max(field.maxX - caret.maxX - 4, 40)) }
        let height = max(caret.height, f.pointSize + 4)
        let frame = CGRect(x: caret.maxX + 1,
                           y: caret.midY - height / 2,
                           width: width, height: height)

        panel.setFrame(clamped(frame), display: true)
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isVisible = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.size.width = max(visible.maxX - f.minX - 4, 40) }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }
}
