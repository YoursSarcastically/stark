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
    private let keycap = NSTextField(labelWithString: "tab")
    /// Shown in the keycap's place until the model has finished, so the card
    /// reads as "working" rather than as a finished suggestion that happens to
    /// be short.
    private let spinner = NSProgressIndicator()
    /// A small gradient lozenge at the leading edge. Carries the colour so the
    /// text doesn't have to — gradient-filled text is illegible at 13pt, and a
    /// gradient across the whole surface fights the glass behind it.
    private let accent = NSView()
    private let accentFill = CAGradientLayer()
    /// The border highlight. `rimHost` is fixed and carries the rounded-rect
    /// stroke as its mask; `rim` is a square conic gradient spinning inside it.
    /// The mask has to live on a separate, stationary layer — put it on the
    /// gradient itself and it rotates too, and nothing appears to move.
    private let rimHost = CALayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    private(set) var isVisible = false
    private var cardMode = false
    private var anchor: CGPoint = .zero
    private var anchorCentreX: CGFloat = 0
    private var centred = false

    private let height: CGFloat = 40
    private let hInset: CGFloat = 15

    init() {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 13
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
            v.layer?.cornerRadius = 13
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
        // Slightly translucent overall so the card reads as glass rather than a
        // solid chip. Kept above 0.9 — below that the label starts to lose
        // contrast against busy backgrounds.
        p.alphaValue = 0.93
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
        keycap.font = Self.rounded(10, weight: .semibold)
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

        // A single bright arc travelling around the border, over a dim base, so
        // the card reads as lit rather than outlined. Kept close to white with a
        // faint cool cast — a saturated rainbow here looks like a gaming laptop.
        rim.type = .conic
        rim.colors = [
            NSColor.white.withAlphaComponent(0.05).cgColor,
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor(calibratedRed: 0.45, green: 0.56, blue: 1.00, alpha: 0.60).cgColor,
            NSColor(calibratedRed: 0.66, green: 0.45, blue: 0.98, alpha: 0.60).cgColor,
            NSColor(calibratedRed: 0.95, green: 0.50, blue: 0.74, alpha: 0.35).cgColor,
            NSColor.white.withAlphaComponent(0.05).cgColor,
        ]
        rim.locations = [0, 0.30, 0.44, 0.52, 0.66, 1]
        rim.startPoint = CGPoint(x: 0.5, y: 0.5)
        rim.endPoint = CGPoint(x: 1, y: 0.5)

        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.4
        rimHost.mask = rimMask
        rimHost.addSublayer(rim)

        accentFill.colors = [
            NSColor(calibratedRed: 0.40, green: 0.52, blue: 1.00, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.98, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.72, alpha: 1).cgColor,
        ]
        accentFill.startPoint = CGPoint(x: 0.5, y: 1)
        accentFill.endPoint = CGPoint(x: 0.5, y: 0)
        accentFill.cornerRadius = 1.75
        accent.wantsLayer = true
        accent.layer?.addSublayer(accentFill)
        accent.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(accent)
        content.addSubview(label)
        content.addSubview(keycap)
        content.addSubview(spinner)
        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hInset),
            accent.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3.5),
            accent.heightAnchor.constraint(equalToConstant: 17),

            label.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 11),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keycap.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            keycap.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hInset),
            keycap.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 26),
            keycap.heightAnchor.constraint(equalToConstant: 16),

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
        root.layer?.addSublayer(rimHost)
        p.contentView = root
        panel = p
    }

    /// SF Rounded at a given size, falling back to the default face if the
    /// rounded design is unavailable.
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
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
        // SF Rounded: softer terminals than the default face, which is what
        // reads as "modern" here without resorting to a third-party font.
        // Medium weight because the card is read at a glance, out of the corner
        // of the eye, over arbitrary content showing through glass.
        label.font = Self.rounded(NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.stringValue = text.isEmpty ? "…" : text

        let width = min(max(hInset + 3.5 + 11 + label.intrinsicContentSize.width + 14 + 26 + hInset, 130), 500)
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
                panel.animator().alphaValue = 0.93
            }
        } else {
            // Resize without animation: the frame changes on every streamed
            // token, and animating that would make the card wobble.
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        }
        accentFill.frame = accent.bounds
        layoutRim(size: target.size)
        isVisible = true
    }

    private func layoutRim(size: CGSize) {
        guard cardMode else { rimHost.isHidden = true; return }
        rimHost.isHidden = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation on resize
        rimHost.frame = CGRect(origin: .zero, size: size)
        rimMask.frame = rimHost.bounds
        rimMask.path = CGPath(roundedRect: CGRect(x: 0.6, y: 0.6,
                                                  width: size.width - 1.2,
                                                  height: size.height - 1.2),
                              cornerWidth: 12.4, cornerHeight: 12.4, transform: nil)
        // Square and large enough that the spinning gradient still covers the
        // corners; a conic gradient in a wide rect would sweep past the ends.
        let side = (size.width * size.width + size.height * size.height).squareRoot()
        rim.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rim.position = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()

        guard rim.animation(forKey: "circle") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 4.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        rim.add(spin, forKey: "circle")
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
