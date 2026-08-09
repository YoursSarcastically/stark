import AppKit

/// The suggestion, drawn as text on a rail rather than as a container.
///
/// There is no panel here — no fill, no border, no capsule. The suggestion is
/// set in the host's own body size, one step dimmer than the text the user
/// typed, with a thin rule running underneath it that starts at the caret in
/// the accent colour and fades out toward the tail. The rail is the only
/// chrome, and it is 1.5pt tall.
///
/// This is the honest end state of everything that came before it. Each earlier
/// version added something to make the suggestion feel like an object — a fill,
/// a border, a glow, glass — and every one of those made it compete with the
/// sentence it was supposed to be continuing. Removing the container removes
/// the competition: the eye reads one line of text, and the rail says which
/// part of it hasn't been committed yet.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let host = NSView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "TAB")
    private let rail = CAGradientLayer()
    private var dots: [CALayer] = []

    private(set) var isVisible = false
    private var anchor: CGPoint = .zero
    private var thinking = false

    private let height: CGFloat = 24
    private let bodySize: CGFloat = 15
    /// Distance from the top of the frame to the text baseline area; the rail
    /// hangs just under it.
    private let railInset: CGFloat = 4
    private let railHeight: CGFloat = 1.5
    private let leadIn: CGFloat = 3
    private let thinkingWidth: CGFloat = 40

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

        host.wantsLayer = true
        host.layer?.masksToBounds = false

        // Full strength where the suggestion begins, gone by the end — the rail
        // points back at the caret it grew out of.
        rail.startPoint = CGPoint(x: 0, y: 0.5)
        rail.endPoint = CGPoint(x: 1, y: 0.5)
        rail.locations = [0, 0.55, 1]

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        hint.isBezeled = false
        hint.isEditable = false
        hint.drawsBackground = false
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 9, weight: .semibold)
        hint.translatesAutoresizingMaskIntoConstraints = false

        host.layer?.addSublayer(rail)
        for _ in 0..<3 {
            let d = CALayer()
            d.cornerRadius = 1.5
            d.isHidden = true
            host.layer?.addSublayer(d)
            dots.append(d)
        }
        host.addSubview(label)
        host.addSubview(hint)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: leadIn),
            label.topAnchor.constraint(equalTo: host.topAnchor),
            hint.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 9),
            hint.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])

        p.contentView = host
        panel = p
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func applyPalette() {
        let dark = isDark
        // One step down from committed text: clearly a suggestion, still
        // comfortably readable.
        label.textColor = dark ? NSColor(calibratedWhite: 1, alpha: 0.72)
                               : NSColor(calibratedWhite: 0, alpha: 0.62)
        hint.textColor = dark ? NSColor(calibratedWhite: 1, alpha: 0.28)
                              : NSColor(calibratedWhite: 0, alpha: 0.32)
        let accent = NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.28, alpha: 1)
        rail.colors = [accent.withAlphaComponent(dark ? 0.95 : 0.85).cgColor,
                       accent.withAlphaComponent(dark ? 0.45 : 0.40).cgColor,
                       accent.withAlphaComponent(0).cgColor]
        let dotColor = (dark ? NSColor(calibratedWhite: 1, alpha: 0.45)
                             : NSColor(calibratedWhite: 0, alpha: 0.40)).cgColor
        dots.forEach { $0.backgroundColor = dotColor }
    }

    // MARK: presentation

    func showThinking(caret: CGRect?, window: CGRect?) {
        guard let panel else { return }
        thinking = true
        label.stringValue = ""
        hint.stringValue = ""
        applyPalette()
        place(width: thinkingWidth, caret: caret, window: window, panel: panel)
    }

    func showSuggestion(_ text: String, caret: CGRect?, window: CGRect?) {
        guard !text.isEmpty, let panel else { return }
        thinking = false
        label.font = .systemFont(ofSize: bodySize)
        label.stringValue = text
        hint.stringValue = "TAB"
        applyPalette()
        let width = min(leadIn + label.intrinsicContentSize.width + 9
                        + hint.intrinsicContentSize.width + 6, 560)
        place(width: width, caret: caret, window: window, panel: panel)
    }

    private func place(width: CGFloat, caret: CGRect?, window: CGRect?, panel: NSPanel) {
        // Sits on the caret's own line, starting where the text stopped.
        if let caret {
            anchor = CGPoint(x: caret.maxX, y: caret.midY - height / 2)
        } else if let window {
            anchor = CGPoint(x: window.midX - width / 2,
                             y: window.minY + max(72, window.height * 0.13))
        } else if !isVisible {
            return
        }
        let target = clamped(CGRect(origin: anchor,
                                    size: CGSize(width: width, height: height)))
        let first = !isVisible
        if first {
            var start = target
            start.size.width = leadIn
            panel.setFrame(start, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            isVisible = true
        }
        // Width animates, opacity doesn't: the rail extends out of the caret
        // rather than fading into place.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = first ? 0.18 : 0.09
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.isVisible else { return }
            self.layout(size: target.size)
        })
        layout(size: target.size)
    }

    private func layout(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The rail spans the suggestion text only — not the TAB hint, which is
        // annotation rather than content.
        let railWidth = thinking ? thinkingWidth
                                 : min(leadIn + label.intrinsicContentSize.width, size.width)
        rail.frame = CGRect(x: 0, y: railInset, width: railWidth, height: railHeight)
        rail.isHidden = thinking
        for (i, d) in dots.enumerated() {
            d.isHidden = !thinking
            d.frame = CGRect(x: leadIn + 2 + CGFloat(i) * 8, y: size.height / 2 - 1.5,
                             width: 3, height: 3)
        }
        CATransaction.commit()
        label.isHidden = thinking
        hint.isHidden = thinking
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        thinking = false
        var end = panel.frame
        end.size.width = leadIn
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            panel.orderOut(nil)
        })
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 4 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 4 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 4 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 4 }
        return f
    }
}
