import AppKit

/// The suggestion capsule.
///
/// One panel spec, every host. The fill is a blurred sample of whatever is
/// behind it, so contrast comes from the background rather than from a colour
/// picked in advance — which is what every earlier version got wrong, tuning a
/// fixed colour to whichever screenshot was most recent and breaking on the
/// next background.
///
/// Anatomy (from the design spec):
///
///     height    34 · radius 999 (full capsule, matches the caret's roundness)
///     padding   7 / 7 / 7 / 13 — tighter on the key side so the badge
///               reads as inset rather than as a button floating in space
///     fill      vibrancy .16 white over blur(24) saturate(180%)
///     stroke    1px white .16, plus an inner top highlight at .14
///     shadow    0 10 30 -12 black .8 — the only thing separating it from the app
///     type      14pt system, -0.003em; key badge 10pt 600 caps
///     motion    in 180ms ease-out (fade + 4px rise); out 120ms fade only
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let material = NSVisualEffectView()
    private let content = NSView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "TAB")
    private let stroke = CAShapeLayer()
    private let topHighlight = CAShapeLayer()
    private var dots: [CALayer] = []

    private(set) var isVisible = false
    private var thinking = false

    private let height: CGFloat = 34
    private let padLeft: CGFloat = 13
    private let padRight: CGFloat = 7
    private let gap: CGFloat = 9
    private let badgeSize = CGSize(width: 34, height: 20)
    private let thinkingWidth: CGFloat = 64
    /// Rule 3: ~360pt, then truncate.
    private let maxWidth: CGFloat = 360

    init() {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true          // 0 10 30 -12 black .8, per spec
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false

        // A blurred, saturated sample of what's behind. Legibility then comes
        // from the host instead of from a colour guessed in advance.
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.masksToBounds = true
        material.translatesAutoresizingMaskIntoConstraints = false

        stroke.fillColor = nil
        stroke.lineWidth = 1
        stroke.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        topHighlight.fillColor = nil
        topHighlight.lineWidth = 1
        topHighlight.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        // Rule 3: a full sentence rendered twice is noise. Middle truncation
        // keeps both the join at the caret and the ending visible, which is
        // what tells you whether the suggestion is the one you wanted.
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        badge.isBezeled = false
        badge.isEditable = false
        badge.drawsBackground = false
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = badgeSize.height / 2
        badge.translatesAutoresizingMaskIntoConstraints = false

        content.wantsLayer = true
        content.addSubview(label)
        content.addSubview(badge)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padLeft),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: gap),
            badge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padRight),
            badge.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: badgeSize.width),
            badge.heightAnchor.constraint(equalToConstant: badgeSize.height),
        ])

        let root = NSView()
        root.wantsLayer = true
        root.addSubview(material)
        material.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            material.topAnchor.constraint(equalTo: root.topAnchor),
            material.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        for _ in 0..<3 {
            let d = CALayer()
            d.cornerRadius = 2
            d.isHidden = true
            content.layer?.addSublayer(d)
            dots.append(d)
        }
        root.layer?.addSublayer(stroke)
        root.layer?.addSublayer(topHighlight)

        p.contentView = root
        panel = p
        applyPalette()
    }

    private func applyPalette() {
        // The material supplies the surface; the type just needs to sit on it.
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        dots.forEach { $0.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor }
    }

    // MARK: states

    /// Thinking — the same capsule collapsed to three dots. Never a spinner.
    func showThinking(caret: CGRect?, field: CGRect?) {
        guard let panel else { return }
        thinking = true
        label.stringValue = ""
        badge.stringValue = ""
        place(width: thinkingWidth, caret: caret, field: field, panel: panel)
    }

    func showSuggestion(_ text: String, caret: CGRect?, field: CGRect?) {
        guard !text.isEmpty, let panel else { return }
        thinking = false
        label.stringValue = text
        badge.stringValue = "TAB"
        let width = min(padLeft + label.intrinsicContentSize.width + gap
                        + badgeSize.width + padRight, maxWidth)
        place(width: width, caret: caret, field: field, panel: panel)
    }

    /// Accepting — a 60ms press-in with the key badge inverted, so the keypress
    /// is acknowledged before the text lands.
    func flashAccept() {
        guard isVisible else { return }
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        badge.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = 1.0
        press.toValue = 0.97
        press.duration = 0.06
        press.autoreverses = true
        panel?.contentView?.layer?.add(press, forKey: "press")
    }

    // MARK: placement

    /// Places the capsule under the caret, then **proves** it isn't covering
    /// anything the user is writing.
    ///
    /// Every previous version computed a position and trusted the arithmetic.
    /// That is how the capsule ended up sitting on top of a half-typed sentence:
    /// one bad caret rect from one app, and the panel lands squarely over the
    /// text. Position is now a proposal, and the field rect is the referee — if
    /// the proposed frame intersects the field at all, it is moved below the
    /// field's bottom edge, and above its top edge if there is no room below.
    /// A suggestion that hides what you are writing is worse than no suggestion.
    private func place(width: CGFloat, caret: CGRect?, field: CGRect?, panel: NSPanel) {
        let size = CGSize(width: width, height: height)
        var frame: CGRect
        if let caret {
            frame = CGRect(origin: CGPoint(x: caret.minX, y: caret.minY - height - 6), size: size)
        } else if let field {
            frame = CGRect(origin: CGPoint(x: field.minX + 8, y: field.minY - height - 8),
                           size: size)
        } else if isVisible {
            frame = CGRect(origin: panel.frame.origin, size: size)
        } else {
            return
        }

        if let field, frame.intersects(field.insetBy(dx: -2, dy: -2)) {
            let visible = (NSScreen.screens.first { $0.frame.intersects(field) }
                           ?? NSScreen.main)?.visibleFrame
            let below = CGRect(x: frame.origin.x, y: field.minY - height - 8,
                               width: width, height: height)
            let above = CGRect(x: frame.origin.x, y: field.maxY + 8,
                               width: width, height: height)
            if let visible, below.minY < visible.minY + 8 {
                frame = above          // no room underneath; flip over the top
            } else {
                frame = below
            }
        }
        let target = clamped(frame)

        if !isVisible {
            // In: 180ms ease-out, fade plus a 4pt rise.
            panel.setFrame(target.offsetBy(dx: 0, dy: -4), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isVisible = true
            layout(size: size)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
            layout(size: size)
            panel.orderFrontRegardless()
        }
    }

    private func layout(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = size.height / 2      // radius 999: a true capsule
        material.layer?.cornerRadius = r
        material.layer?.cornerCurve = .continuous
        stroke.frame = CGRect(origin: .zero, size: size)
        stroke.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5,
                                                 width: size.width - 1,
                                                 height: size.height - 1),
                             cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil)
        // Inner top highlight: the upper arc only, so the capsule catches light
        // from above the way a physical control would.
        let hl = CGMutablePath()
        hl.addArc(center: CGPoint(x: size.width / 2, y: size.height / 2 - 1),
                  radius: size.height / 2 - 1.5,
                  startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
        topHighlight.frame = stroke.frame
        topHighlight.path = hl

        for (i, d) in dots.enumerated() {
            d.isHidden = !thinking
            d.frame = CGRect(x: size.width / 2 - 14 + CGFloat(i) * 10,
                             y: size.height / 2 - 2, width: 4, height: 4)
        }
        CATransaction.commit()
        label.isHidden = thinking
        badge.isHidden = thinking
    }

    /// Out: 120ms, fade only — no movement, so a suggestion the user has typed
    /// past disappears without pulling the eye back to it.
    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        thinking = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            panel.orderOut(nil)
            self.applyPalette()      // undo any accept-flash inversion
        })
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.minY < visible.minY + 8 { f.origin.y = visible.minY + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        return f
    }
}
