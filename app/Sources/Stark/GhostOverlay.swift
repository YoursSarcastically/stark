import AppKit

/// The suggestion, drawn over whatever app the user is typing in.
///
/// Built on `NSGlassEffectView` — the system's own Liquid Glass — rather than a
/// hand-made imitation. Earlier attempts stacked a blurred gradient behind a
/// solid card to fake depth; that always reads as decoration sitting *on top of*
/// the screen. Real glass refracts what is behind it, so the suggestion looks
/// like part of the window it is floating over, at any size, on any background,
/// in either appearance. There is no gradient, no glow, and no idle animation:
/// the only thing that moves is the text arriving as the model produces it.
///
/// Two presentations:
///
/// One presentation: a glass card anchored below the text. Inline ghost text at
/// the caret was tried and removed — it covers the sentence being written and
/// jumps on every keystroke, and the apps that most need suggestions (Docs,
/// Electron) are exactly the ones that won't report caret geometry anyway.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    /// Real Liquid Glass on macOS 26+, vibrancy everywhere else. Held as a bare
    /// NSView so the deployment target stays at macOS 14 — Stark still runs on
    /// Macs that never got Liquid Glass, they just get the older material.
    private let backdrop: NSView
    private let content = NSView()
    private let label = NSTextField(labelWithString: "")
    /// The glyph, not the word: system UI names this key ⇥.
    private let keycap = NSTextField(labelWithString: "⇥")
    /// Shown in the keycap's place until the model has finished, so the card
    /// reads as "working" rather than as a finished suggestion that happens to
    /// be short.
    private let spinner = NSProgressIndicator()
    /// A single static hairline. Nothing on this card animates except the
    /// text arriving — a rotating highlight is a gaming-peripheral idiom,
    /// not something the system does anywhere.
    private let hairline = CAShapeLayer()

    private(set) var isVisible = false
    private var cardMode = false
    private var anchor: CGPoint = .zero
    private var anchorCentreX: CGFloat = 0
    private var centred = false

    private let height: CGFloat = 38
    private let hInset: CGFloat = 14

    init() {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 12
            // `.clear` is the genuinely transparent glass; `.regular` frosts
            // heavily and, over a white page, resolves to the flat grey slab
            // this component kept looking like.
            g.style = .clear
            g.tintColor = nil
            backdrop = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 12
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            backdrop = v
        }

        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false          // the glass carries its own shading
        // Left fully opaque: `.clear` glass already lets the background through,
        // and lowering the panel's alpha on top of it only washes out the label.
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        keycap.isBezeled = false
        keycap.isEditable = false
        keycap.drawsBackground = false
        keycap.alignment = .center
        keycap.font = .systemFont(ofSize: 11, weight: .regular)
        keycap.textColor = .secondaryLabelColor
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 5
        keycap.layer?.cornerCurve = .continuous
        keycap.layer?.borderWidth = 1
        keycap.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        keycap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        keycap.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        hairline.fillColor = nil
        hairline.lineWidth = 1
        hairline.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor

        content.addSubview(label)
        content.addSubview(keycap)
        content.addSubview(spinner)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hInset),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keycap.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            keycap.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hInset),
            keycap.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 22),
            keycap.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: keycap.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: keycap.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])

        if #available(macOS 26.0, *), let g = backdrop as? NSGlassEffectView {
            g.contentView = content
        } else {
            content.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                content.topAnchor.constraint(equalTo: backdrop.topAnchor),
                content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            ])
        }
        // The rim must live ABOVE the glass, in a plain container. The header
        // for NSGlassEffectView is explicit that arbitrary subviews/sublayers
        // get no z-order guarantee relative to the glass, so a rim added to the
        // glass view itself may simply never be drawn.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.masksToBounds = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layer?.addSublayer(hairline)
        p.contentView = root
        panel = p
    }

    // MARK: presentation

    func showCard(_ text: String, caret: CGRect?, window: CGRect?, streaming: Bool = false) {
        guard let panel else { return }
        let isNew = !cardMode || !isVisible
        cardMode = true
        keycap.isHidden = streaming
        if streaming { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // NSFont.systemFont at the standard small-control size: the same face
        // and metrics AppKit uses for menus and HUDs, rather than a bespoke
        // point size that reads as a web component.
        // SF Pro at the system size, regular weight. Rounded reads as playful
        // rather than premium here, and bumping the weight to fight the glass
        // just makes it look heavy — the material should be adjusted instead.
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.stringValue = text.isEmpty ? "…" : text

        let width = min(max(hInset + label.intrinsicContentSize.width + 12 + 22 + hInset, 120), 500)
        if isNew {
            // Deliberately ignores the caret. Anchoring beside it puts the card
            // on top of the sentence being written and makes it jump with every
            // keystroke; a fixed position below the text is calmer to read and
            // never occludes what you just typed.
            if let window {
                anchorCentreX = window.midX
                anchor = CGPoint(x: window.midX - width / 2,
                                 y: window.minY + max(72, window.height * 0.13))
                centred = true
            } else {
                return
            }
        } else if centred {
            // Keep it centred as it grows during streaming, rather than letting
            // it creep rightwards off its anchor.
            anchor.x = anchorCentreX - width / 2
        }
        place(CGRect(origin: anchor, size: CGSize(width: width, height: height)), panel: panel)
    }

    private func place(_ frame: CGRect, panel: NSPanel) {
        let target = clamped(frame)
        if !isVisible {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
            }
        } else {
            // Resize without animation: the frame changes on every streamed
            // token, and animating that would make the card wobble.
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        }
        layoutHairline(size: target.size)
        isVisible = true
    }

    private func layoutHairline(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = CGRect(origin: .zero, size: size)
        hairline.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5,
                                                   width: size.width - 1,
                                                   height: size.height - 1),
                               cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
        CATransaction.commit()
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            panel.orderOut(nil)
        })
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        return f
    }
}
