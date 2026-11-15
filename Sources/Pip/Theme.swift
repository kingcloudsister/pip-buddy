import SwiftUI

/// Which screen edge the strip hugs. Along the top it lies flat and cards drop down from it.
enum PipEdge: String, CaseIterable {
    case left, right, top
    var horizontal: Bool { self == .top }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Pip's one look, taken from the Buddy Monitor mockup: warm sand and tan, white cards with warm hairlines,
/// near-black ink, tracked uppercase labels, and a square face drawn in ink.
enum Theme {
    // Surfaces
    static let sand = Color(red: 0.957, green: 0.949, blue: 0.933)       // panel
    static let tan = Color(red: 0.902, green: 0.827, blue: 0.690)        // the strip (the mockup's side column)
    static let tanEdge = Color(red: 0.80, green: 0.71, blue: 0.56)       // hairline around the strip
    static let tile = Color(red: 0.969, green: 0.949, blue: 0.914)       // buttons on the strip
    static let hairline = Color(red: 0.86, green: 0.83, blue: 0.79)
    static let toast = Color(white: 0.13)

    // Text
    static let ink = Color(white: 0.11)
    static let muted = Color(red: 0.55, green: 0.51, blue: 0.47)
    static let caption = Color(red: 0.60, green: 0.53, blue: 0.45)

    // Status
    static let workingBg = Color(red: 0.933, green: 0.898, blue: 0.831)
    static let workingFg = Color(red: 0.52, green: 0.45, blue: 0.37)
    static let readyBg = Color(red: 0.976, green: 0.839, blue: 0.847)
    static let readyFg = Color(red: 0.23, green: 0.15, blue: 0.15)
    static let quietBg = Color(white: 0.93)
    static let quietFg = Color(white: 0.55)
    static let rose = Color(red: 0.91, green: 0.42, blue: 0.51)          // "finished, not seen yet" dot
    static let tapBack = Color(red: 0.96, green: 0.64, blue: 0.69)       // on the dark notice
    static let tapBackInk = Color(red: 0.84, green: 0.33, blue: 0.43)    // on white cards

    // Panel
    static let monitorWidth: CGFloat = 290
    static let monitorHeader: CGFloat = 58
    static let monitorMargin: CGFloat = 28   // transparent room around the panel for its shadow

    // Strip geometry. Cards line up with the row they talk about.
    static let margin: CGFloat = 12     // transparent room around the strip for its shadow
    static let pillWidth: CGFloat = 52
    static let pad: CGFloat = 8
    static let mascot: CGFloat = 36
    static let gap: CGFloat = 12        // between the face and the first app, holds a short divider
    static let row: CGFloat = 40
    static let rowGap: CGFloat = 0
    static let tuck: CGFloat = pillWidth / 2   // how far cards and the panel reach under the strip

    static let handle: CGFloat = 20     // the minimize chevron at the end of the strip

    /// Center of row `i` along the strip, measured from its top (or its left edge when it lies along the top).
    static func rowCenter(_ i: Int) -> CGFloat {
        margin + pad + mascot + gap + CGFloat(i) * (row + rowGap) + row / 2
    }

    static let mascotCenter = margin + pad + mascot / 2
}
