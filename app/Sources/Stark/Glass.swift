import SwiftUI
import AppKit

/// A real `NSVisualEffectView` behind SwiftUI content.
///
/// SwiftUI's `.regularMaterial` blurs what is *inside* the window. For a window
/// that should feel like frosted glass sitting on the desktop, the blur has to
/// sample what is *behind* it, which only AppKit's visual effect view does. The
/// onboarding window used flat white and a lot of orange, which read as a web
/// page in a window frame rather than a Mac app.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        // `.active` rather than `.followsWindowActiveState`: the setup window
        // loses key focus the moment the user goes to System Settings to grant
        // permission, and a pane that turns flat grey while they are away looks
        // like it has crashed.
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// The card treatment used throughout onboarding: translucent fill, a hairline
/// edge that catches light at the top, and a shadow soft enough to read as
/// depth rather than a drop shadow.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

extension View {
    func glassCard(radius: CGFloat = 12) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

/// The one prominent button per screen.
///
/// `.borderedProminent` in the app's amber gave every screen a large flat
/// orange slab, which is what made the whole thing look like a landing page.
/// This keeps the accent but treats it as a lit surface: a soft vertical
/// gradient, a bright top edge, and a coloured shadow instead of a hard fill.
struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                LinearGradient(colors: [Color.brand.opacity(0.98),
                                        Color.brand.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                    .blendMode(.plusLighter))
            .shadow(color: Color.brand.opacity(0.32), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
