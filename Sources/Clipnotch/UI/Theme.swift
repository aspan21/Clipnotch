import SwiftUI

enum Theme {
    static let panel = Color.black
    static let stroke = Color.white.opacity(0.09)
    static let cardFill = Color.white.opacity(0.06)
    static let cardFillHover = Color.white.opacity(0.11)
    static let cardStroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
    static let accent = Color(red: 0.42, green: 0.62, blue: 1.0)

    /// Gap between the notch shape's straight inner edge and the content. The
    /// outer inset is the corner radius itself, so content never lands under
    /// the flare; see `NotchGeometry.contentInset(forTopRadius:)`.
    static let contentGutter: CGFloat = 12
    /// Roughly 16:9 — clips are mostly screenshots, and a squarer card
    /// crops their sides away and leaves the thumbnail unreadable.
    static let cardSize = CGSize(width: 176, height: 102)
    static let cardRadius: CGFloat = 10

    /// `matchedGeometryEffect` id shared by the closed strip's album art and the
    /// open panel's, so the artwork flies between them.
    static let artworkGeometryID = "notchArtwork"

    // MARK: - Motion

    /// One spring per direction, picked by the state being animated *towards*.
    /// Opening follows a pull, so a little overshoot reads as momentum; closing
    /// is critically damped so the panel never bounces back at the user.
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    static let notchClose = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    /// Follows the pointer during a pan, so it has to be interruptible.
    static let gesture = Animation.interactiveSpring(response: 0.28, dampingFraction: 1.0, blendDuration: 0)

    /// Non-gesture state changes (tab switch, card insert) carry no momentum, so
    /// they settle without overshoot.
    static let snap = Animation.spring(response: 0.3, dampingFraction: 1.0)
    static let quick = Animation.easeOut(duration: 0.16)

    // MARK: - Typography

    /// Tracking is size-specific: display text reads too loose as it grows,
    /// small text too tight. One fixed value would be wrong at one end.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        switch size {
        case ..<11.5: return 0.2
        case ..<14: return 0
        case ..<20: return -0.2
        default: return -0.4
        }
    }
}

extension View {
    /// Hit-testing and hover only inside the drawn shape, so the rest of the
    /// oversized window stays click-through.
    func notchClipped(top: CGFloat, bottom: CGFloat) -> some View {
        let shape = NotchShape(topRadius: top, bottomRadius: bottom)
        return clipShape(shape).contentShape(shape)
    }
}
