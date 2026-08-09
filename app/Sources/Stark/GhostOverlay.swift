import AppKit

/// The suggestion, drawn as a pill whose left cap **is** the caret.
///
/// The silhouette is asymmetric on purpose: square on the left, capped on the
/// right. That shape says "this continues from here" — the panel reads as the
/// text cursor extended rightward rather than as a separate object arriving
/// from elsewhere, so there is no distance for the eye to close.
///
/// Four rules, each fixing something an earlier version got wrong:
///
///  1. **The hint is the quietest thing in the object.** A bone-white "TAB" on
///     near-black is the highest-contrast element on screen, which sends the eye
///     to the shortcut before the suggestion. It sits at 9pt in the fill's own
///     mid-tone instead.
///  2. **The text is one flat colour.** Fading it toward the tail to express
///     model confidence just reads as a rendering bug.
///  3. **The caret rule is 2pt and inset**, not a 4pt stripe down the edge — a
///     saturated bar on the left is the universal pattern for a validation error.
///  4. **It is barely taller than a line.** Something that appears every few
///     seconds must be smaller than the thing it describes.
@MainActor
final class GhostOverlay {

    private var panel: NSPanel?
    private let host = NSView()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let border = CAShapeLayer()
    private let caretRule = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "TAB")
    private var dots: [CALayer] = []

    private(set) var isVisible = false
    private var anchor: CGPoint = .zero
    private var thinking = false

    // 26pt against a 15pt body is roughly 1.7x the line — enough to be an
    // object, small enough to stay subordinate to the sentence.
    private let height: CGFloat = 26
    private let bodySize: CGFloat = 15
    private let capRadius: CGFloat = 13
    private let caretWidth: CGFloat = 2
    private let leftPad: CGFloat = 10
    private let rightPad: CGFloat = 9
    private let thinkingWidth: CGFloat = 44

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

        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.mask = fillMask
        border.fillColor = nil
        border.lineWidth = 1

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
        hint.translatesAutoresizingMaskIntoConstraints = false

        host.layer?.addSublayer(fill)
        host.layer?.addSublayer(border)
        host.layer?.addSublayer(caretRule)
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
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: leftPad),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            hint.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        p.contentView = host
        panel = p
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The container tints with its host — dark ink on dark, warm paper on
    /// light — while the geometry never changes.
    private func applyPalette() {
        let dark = isDark
        let ink: NSColor = dark ? .white
            : NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.08, alpha: 1)
        fill.colors = [ink.withAlphaComponent(dark ? 0.15 : 0.085).cgColor,
                       ink.withAlphaComponent(dark ? 0.09 : 0.055).cgColor]
        border.strokeColor = ink.withAlphaComponent(dark ? 0.20 : 0.11).cgColor
        caretRule.backgroundColor = NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.28,
                                            alpha: dark ? 0.85 : 0.75).cgColor
        label.textColor = dark ? NSColor(calibratedWhite: 1, alpha: 0.92)
                               : NSColor(calibratedWhite: 0.10, alpha: 1)
        hint.textColor = ink.withAlphaComponent(dark ? 0.34 : 0.40)
        let dotColor = ink.withAlphaComponent(dark ? 0.45 : 0.40).cgColor
        dots.forEach { $0.backgroundColor = dotColor }
    }

    // MARK: presentation

    /// Three dots while the model works. Never a spinner: a spinner implies an
    /// indeterminate wait, and this resolves in well under a second.
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
        let wasThinking = thinking
        thinking = false
        label.font = .systemFont(ofSize: bodySize)
        label.stringValue = text
        hint.font = .systemFont(ofSize: 9, weight: .semibold)
        hint.stringValue = "TAB"
        applyPalette()

        let width = min(leftPad + label.intrinsicContentSize.width + 8
                        + hint.intrinsicContentSize.width + rightPad, 520)
        place(width: width, caret: caret, window: window, panel: panel,
              unroll: wasThinking || !isVisible)
    }

    private func place(width: CGFloat, caret: CGRect?, window: CGRect?,
                       panel: NSPanel, unroll: Bool = true) {
        // Butted against the text with no gap — the pill IS the caret, and any
        // gap breaks that reading.
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

        if !isVisible {
            // Unrolls left to right: width animates, opacity does not. Fading in
            // makes it drift into place; growing out of the caret makes it look
            // like it was always there.
            var start = target
            start.size.width = unroll ? caretWidth : target.width
            panel.setFrame(start, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            isVisible = true
            layout(size: start.size)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                guard let self, self.isVisible else { return }
                self.layout(size: target.size)
            })
        } else {
            panel.setFrame(target, display: true)
            layout(size: target.size)
            panel.orderFrontRegardless()
        }
    }

    /// Square on the left, capped on the right: radius 0 / 13 / 13 / 0.
    private func pillPath(_ size: CGSize, inset: CGFloat = 0) -> CGPath {
        let r = max(min(capRadius, size.height / 2) - inset, 0)
        let rect = CGRect(x: inset, y: inset,
                          width: max(size.width - inset * 2, r * 2),
                          height: max(size.height - inset * 2, 0))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.midY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func layout(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        fill.frame = bounds
        fillMask.frame = bounds
        fillMask.path = pillPath(size)
        border.frame = bounds
        border.path = pillPath(size, inset: 0.5)
        // Inset vertically so it reads as a cursor inside the field rather than
        // a coloured edge on the container.
        caretRule.frame = CGRect(x: 0, y: 3, width: caretWidth, height: max(size.height - 6, 0))

        for (i, d) in dots.enumerated() {
            d.isHidden = !thinking
            d.frame = CGRect(x: leftPad + CGFloat(i) * 8, y: size.height / 2 - 1.5,
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
        // Depletes rather than fades: the pill gives ground back to the text.
        var end = panel.frame
        end.size.width = caretWidth
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
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
