import SwiftUI
import AppKit

extension Color {
    /// The accent: indigo.
    ///
    /// Deliberately not `Color.accentColor`. With no asset catalog in the
    /// bundle that resolves to whatever the user has picked in System Settings,
    /// which is how the setup window came out orange on one Mac and would come
    /// out pink or green on the next. A product's palette should not be a
    /// system preference.
    ///
    /// The first attempt made everything graphite to match the mark, and it was
    /// lifeless — a screen with no colour in it at all reads as unfinished
    /// rather than restrained. The structure stays graphite (see `ink`); this
    /// is reserved for the things you can act on: the button, the step you are
    /// on, the focus ring, the caret.
    static let brand = Color(nsColor: NSColor(name: "StarkBrand") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.51, green: 0.50, blue: 0.94, alpha: 1)
            : NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
    })

    /// Graphite, the value the mark is drawn in. Structure and marks, never
    /// something you click.
    static let ink = Color(nsColor: NSColor(name: "StarkInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.93, alpha: 1)
            : NSColor(calibratedRed: 0.27, green: 0.27, blue: 0.29, alpha: 1)
    })

    /// The one place a hue survives: state that means "something is wrong".
    /// Everything else is graphite, so a colour anywhere reads as a signal.
    static let brandWarning = Color(nsColor: .systemOrange)
}
