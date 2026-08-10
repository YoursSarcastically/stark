import SwiftUI
import AppKit

/// Animated demonstrations for onboarding.
///
/// Each demo plays a real recording when one is bundled at
/// `Resources/demos/<name>.gif`, and otherwise falls back to an animated
/// reconstruction built from the same views the product uses. The fallback is
/// deliberately a *reconstruction* and not a mock screenshot of somebody else's
/// app: it shows Stark's own behaviour, so nothing here can claim something the
/// product doesn't do.
///
/// To swap in real captures, record them and drop them in `app/Demos/`:
///
///     rewrite.gif   · select messy text, press ⌘D, watch it replace in place
///     predict.gif   · type a half sentence, ghost text appears, Tab accepts
///     aura.gif      · the menu bar showing accepted rewrites accumulating
struct DemoView: View {
    /// Matches the canvas in tools/make_demos.py (520x150 at 1x).
    static let w: CGFloat = 392
    static let h: CGFloat = 113

    let name: String
    let fallback: AnyView

    init<F: View>(_ name: String, @ViewBuilder fallback: () -> F) {
        self.name = name
        self.fallback = AnyView(fallback())
    }

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "gif",
                                         subdirectory: "demos"),
               let image = NSImage(contentsOf: url) {
                AnimatedGIF(image: image, target: NSSize(width: Self.w, height: Self.h))
            } else {
                fallback
            }
        }
        // An explicit size, not aspectRatio + maxWidth. NSViewRepresentable has
        // no intrinsic size, so aspectRatio has nothing to reason about and
        // SwiftUI hands the view every available point — the artwork then
        // scaled up until the type was enormous and clipped. 392x113 is the
        // canvas ratio exactly (520:150), so nothing is cropped.
        .frame(width: Self.w, height: Self.h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Plays a GIF by stepping its frames on a timer.
///
/// `NSImageView.animates` is the obvious approach and does not work reliably
/// inside an `NSViewRepresentable`: the view often renders frame one and stops,
/// which showed up here as an empty box, because frame one of every demo is an
/// empty text field. Driving the frames explicitly always works, and gives us
/// the per-frame delays the GIF actually specifies rather than a fixed rate.
private struct AnimatedGIF: NSViewRepresentable {
    let image: NSImage

    final class Player {
        var frames: [NSImage] = []
        var delays: [TimeInterval] = []
        var timer: Timer?
        var index = 0

        /// Frames are built at the exact point size the view will display, so
        /// nothing depends on NSImageView's scaling behaviour. Relying on
        /// `.scaleProportionallyDown` did not work: NSImage reports the GIF's
        /// pixel dimensions as its point size, so each frame drew at 1:1 inside
        /// a 392x113 view and was cropped to the top-left corner.
        init(_ image: NSImage, target: NSSize) {
            guard let data = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: data),
                  let count = rep.value(forProperty: .frameCount) as? Int, count > 1
            else { image.size = target; frames = [image]; delays = [1]; return }
            for i in 0..<count {
                rep.setProperty(.currentFrame, withValue: i)
                guard let cg = rep.cgImage else { continue }
                frames.append(NSImage(cgImage: cg, size: target))
                let d = rep.value(forProperty: .currentFrameDuration) as? TimeInterval
                delays.append(max(d ?? 0.05, 0.02))
            }
            if frames.isEmpty { image.size = target; frames = [image]; delays = [1] }
        }

        func start(_ view: NSImageView) {
            timer?.invalidate()
            guard frames.count > 1 else { view.image = frames.first; return }
            index = 0
            view.image = frames[0]
            schedule(view)
        }

        private func schedule(_ view: NSImageView) {
            timer = Timer.scheduledTimer(withTimeInterval: delays[index],
                                         repeats: false) { [weak view] _ in
                guard let view else { return }
                self.index = (self.index + 1) % self.frames.count
                view.image = self.frames[self.index]
                self.schedule(view)
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }

        func stop() { timer?.invalidate(); timer = nil }
    }

    let target: NSSize

    func makeCoordinator() -> Player { Player(image, target: target) }

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        context.coordinator.start(v)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {}

    static func dismantleNSView(_ v: NSImageView, coordinator: Player) {
        coordinator.stop()
    }
}

// MARK: - Reconstructions

/// A miniature text field that types itself, then gets rewritten in place —
/// the one-keystroke loop, at a glance.
struct RewriteDemo: View {
    final class Beat: ObservableObject {
        @Published var typed = ""
        @Published var polished = false
        @Published var pressed = false
    }
    @StateObject private var beat = Beat()

    private let messy = "hey i cant beleive how fast this runs"
    private let clean = "Hey, I can't believe how fast this runs."

    var body: some View {
        DemoFrame {
            VStack(alignment: .leading, spacing: 12) {
                Text(beat.polished ? clean : beat.typed)
                    .font(.system(size: 13))
                    .foregroundStyle(beat.polished ? .primary : .secondary)
                    .animation(.easeInOut(duration: 0.25), value: beat.polished)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    KeyCap("⌘", pressed: beat.pressed)
                    KeyCap("D", pressed: beat.pressed)
                    Text(beat.polished ? "rewritten in place" : "press to rewrite")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { run() }
    }

    private func run() {
        beat.typed = ""; beat.polished = false; beat.pressed = false
        for (i, ch) in messy.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(i)) {
                beat.typed.append(ch)
            }
        }
        let typingDone = 0.045 * Double(messy.count) + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDone) { beat.pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDone + 0.25) {
            beat.pressed = false
            beat.polished = true
        }
        // Loop, so the panel is never showing a finished still frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDone + 2.6) { run() }
    }
}

/// Typing that stops mid-sentence, a dimmed continuation appearing after it,
/// and Tab folding it into the line.
struct PredictDemo: View {
    final class Beat: ObservableObject {
        @Published var typed = ""
        @Published var ghost = ""
        @Published var accepted = false
        @Published var pressed = false
    }
    @StateObject private var beat = Beat()

    private let start = "hey, are you free to"
    private let suggestion = " hop on a quick call later today?"

    var body: some View {
        DemoFrame {
            VStack(alignment: .leading, spacing: 12) {
                (Text(beat.typed).foregroundStyle(.primary)
                 + Text(beat.accepted ? "" : beat.ghost).foregroundStyle(.secondary.opacity(0.55)))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    KeyCap("tab", pressed: beat.pressed, wide: true)
                    Text(beat.accepted ? "accepted"
                         : (beat.ghost.isEmpty ? "keep typing…" : "press to accept"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { run() }
    }

    private func run() {
        beat.typed = ""; beat.ghost = ""; beat.accepted = false; beat.pressed = false
        for (i, ch) in start.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                beat.typed.append(ch)
            }
        }
        let typed = 0.05 * Double(start.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 0.45) {
            beat.ghost = suggestion
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 1.6) { beat.pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 1.8) {
            beat.pressed = false
            beat.accepted = true
            beat.typed += suggestion
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + typed + 4.2) { run() }
    }
}

/// Accepted rewrites accumulating into training examples — the point being
/// that the counter goes up and nothing leaves the machine.
struct AuraDemo: View {
    final class Beat: ObservableObject {
        @Published var count = 0
        @Published var flash = false
    }
    @StateObject private var beat = Beat()

    var body: some View {
        DemoFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.brand)
                    Text("Aura, learning your voice")
                        .font(.system(size: 12, weight: .medium))
                }
                HStack(spacing: 6) {
                    Text("\(beat.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: beat.count)
                    Text("rewrites you kept")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("stored on this Mac · never uploaded")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { run() }
    }

    private func run() {
        beat.count = 0
        for i in 1...7 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42 * Double(i)) {
                beat.count = i
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { run() }
    }
}

// MARK: - Shared chrome

/// The window the reconstructions play inside — enough of a frame to read as
/// "a text field somewhere", without imitating any particular app.
private struct DemoFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(height: 104, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1))
    }
}

private struct KeyCap: View {
    let label: String
    let pressed: Bool
    var wide = false

    init(_ label: String, pressed: Bool, wide: Bool = false) {
        self.label = label
        self.pressed = pressed
        self.wide = wide
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .frame(width: wide ? 30 : 20, height: 18)
            .background(pressed ? Color.brand : Color.secondary.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(pressed ? .white : .secondary)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
