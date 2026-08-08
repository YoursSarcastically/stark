import AppKit
import QuartzCore

/// The suggestion, drawn on top of whatever app the user is typing in.
///
/// Two presentations, chosen by how much the focused app is willing to tell us:
///
///  - **inline** — dimmed ghost text sitting at the caret in the field's own
///    font, so it reads as part of the sentence being written.
///  - **chip** — a floating capsule anchored under the caret, or to the window
///    when even that is unknown. Used for apps that won't report caret
///    geometry (Google Docs, many Electron surfaces).
///
/// The chip is deliberately not a grey system tooltip: it carries a soft
/// animated aurora border so it reads as a live model producing something,
/// which is the whole feeling the feature is selling. It never takes focus and
/// ignores mouse events.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "tab")
    private let backdrop = NSVisualEffectView()
    private let glow = CAGradientLayer()
    private let border = CAShapeLayer()
    private var chipMode = false

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

        let container = NSView()
        container.wantsLayer = true

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 11
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        // The aurora: a wide multi-stop gradient that sweeps horizontally,
        // masked to the rounded rect's stroke so only the border lights up.
        glow.colors = Self.auroraColors
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.locations = [0, 0.25, 0.5, 0.75, 1]
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.6
        glow.mask = border

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        key.isBezeled = false
        key.isEditable = false
        key.drawsBackground = false
        key.font = .systemFont(ofSize: 9, weight: .semibold)
        key.textColor = .tertiaryLabelColor
        key.translatesAutoresizingMaskIntoConstraints = false
        key.wantsLayer = true
        key.layer?.cornerRadius = 3

        container.addSubview(backdrop)
        container.addSubview(label)
        container.addSubview(key)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            key.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            key.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layer?.addSublayer(glow)
        p.contentView = container
        panel = p
    }

    /// Warm gold through violet to cyan and back — wide enough that the sweep
    /// always has several hues on screen, and looped so there is no visible seam.
    private static var auroraColors: [CGColor] {
        [NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.25, alpha: 1),
         NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.55, alpha: 1),
         NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.98, alpha: 1),
         NSColor(calibratedRed: 0.25, green: 0.80, blue: 0.95, alpha: 1),
         NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.25, alpha: 1)].map(\.cgColor)
    }

    // MARK: presentation

    func showInline(_ text: String, at caret: CGRect, font: NSFont?) {
        guard !text.isEmpty, let panel else { return }
        chipMode = false
        let f = font ?? NSFont.systemFont(ofSize: max(11, min(caret.height * 0.72, 24)))
        label.font = f
        label.stringValue = text
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        key.isHidden = true
        backdrop.isHidden = true
        glow.isHidden = true

        let width = min(label.intrinsicContentSize.width + 24, 560)
        let height = max(caret.height, f.pointSize + 6)
        present(frame: CGRect(x: caret.maxX + 1, y: caret.minY, width: width, height: height),
                panel: panel)
    }

    /// Anchored just under the caret when we know it, otherwise near the top of
    /// the focused window — never pinned to the bottom of the screen, which is
    /// where a suggestion is least likely to be looked at.
    func showChip(_ text: String, caret: CGRect?, window: CGRect?) {
        guard !text.isEmpty, let panel else { return }
        chipMode = true
        label.font = .systemFont(ofSize: 12.5, weight: .regular)
        label.stringValue = text
        label.textColor = .labelColor
        key.isHidden = false
        backdrop.isHidden = false
        glow.isHidden = false

        let width = min(label.intrinsicContentSize.width + 12 + 8 + key.intrinsicContentSize.width + 12, 520)
        let height: CGFloat = 30
        let origin: CGPoint
        if let caret {
            origin = CGPoint(x: caret.minX, y: caret.minY - height - 6)
        } else if let window {
            origin = CGPoint(x: window.midX - width / 2, y: window.maxY - height - 56)
        } else {
            return
        }
        present(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
                panel: panel)
    }

    private func present(frame: CGRect, panel: NSPanel) {
        panel.setFrame(clamped(frame), display: true)
        if chipMode { layoutGlow(size: panel.frame.size) }
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
        isVisible = true
    }

    private func layoutGlow(size: CGSize) {
        // The gradient is three times the chip's width so the sweep always has
        // colour to bring in from off-screen.
        glow.frame = CGRect(x: -size.width, y: 0, width: size.width * 3, height: size.height)
        let path = CGPath(roundedRect: CGRect(x: size.width + 0.8, y: 0.8,
                                              width: size.width - 1.6, height: size.height - 1.6),
                          cornerWidth: 10.2, cornerHeight: 10.2, transform: nil)
        border.path = path
        border.frame = glow.bounds

        guard glow.animation(forKey: "aurora") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.byValue = size.width
        sweep.duration = 2.6
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        glow.add(sweep, forKey: "aurora")
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
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
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }
}
