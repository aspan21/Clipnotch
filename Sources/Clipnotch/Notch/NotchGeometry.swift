import AppKit

enum NotchGeometry {
    /// Size of the expanded panel, excluding the shadow gutter. The height is
    /// the tallest pane's natural height — any more and the panel reads as a
    /// box with a hole in it.
    static let openSize = CGSize(width: 660, height: 214)
    /// Ceiling on the preview panel, so a tall screenshot cannot run down the
    /// whole display.
    static let previewMaxHeight: CGFloat = 460
    /// Floor on the picture itself, so a very wide strip still reads as one.
    static let previewMinImageHeight: CGFloat = 150

    /// Extra room below the content so the drop shadow is not clipped.
    static let shadowPadding: CGFloat = 26

    /// Sized for the largest state the panel can reach; the rest of the window
    /// is transparent and click-through.
    static var windowSize: CGSize {
        CGSize(
            width: openSize.width,
            height: max(openSize.height, previewMaxHeight) + shadowPadding
        )
    }

    static let cornerRadii = (
        open: (top: CGFloat(20), bottom: CGFloat(26)),
        closed: (top: CGFloat(6), bottom: CGFloat(13))
    )

    /// Horizontal inset that keeps content clear of the shape's top flare. The
    /// flare eats `topRadius` on each side, so the inset has to be derived from
    /// the radius being drawn — a fixed padding is wrong at one radius or the
    /// other, and the difference shows up as clipped content.
    static func contentInset(forTopRadius radius: CGFloat) -> CGFloat {
        radius + Theme.contentGutter
    }

    /// Width left for the open panel's content once both flare insets are taken.
    static var openContentWidth: CGFloat {
        openSize.width - 2 * contentInset(forTopRadius: cornerRadii.open.top)
    }

    /// Panel size for previewing an image, sized to the picture. A fixed panel
    /// height leaves a wide screenshot floating between black bands.
    static func previewSize(imageAspect: CGFloat, headerHeight: CGFloat) -> CGSize {
        // Header, top padding, the two 10pt gaps, the caption, bottom gutter.
        let chrome = headerHeight + 6 + 10 + 10 + 16 + Theme.contentGutter
        let ideal = imageAspect > 0 ? openContentWidth / imageAspect : openContentWidth
        let picture = min(max(ideal, previewMinImageHeight), previewMaxHeight - chrome)
        return CGSize(width: openSize.width, height: picture + chrome)
    }

    /// Physical notch cutout of `screen`, or a synthetic strip on notch-less displays.
    static func closedSize(for screen: NSScreen?) -> CGSize {
        var width: CGFloat = 190
        var height: CGFloat = 32

        guard let screen else { return CGSize(width: width, height: height) }

        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            // +4 hides the seam between the real cutout and our drawn shape.
            width = screen.frame.width - left - right + 4
        }

        let override = Settings.shared.notchHeightOverride
        if override > 0 {
            height = override
        } else if screen.safeAreaInsets.top > 0 {
            height = screen.safeAreaInsets.top
        } else {
            // No cutout: match the menu bar so the panel reads as part of it.
            height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        }

        return CGSize(width: width, height: height)
    }

    /// True only for displays whose hardware actually eats the strip we draw
    /// over. Everywhere else that strip covers usable pixels, so the closed
    /// panel has to stay out of the way until the pointer asks for it.
    static func hasPhysicalNotch(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    /// Top-centre band that reveals the concealed strip on a notch-less display.
    /// Wider than the strip itself so the pointer does not have to be aimed.
    static func peekZone(on screen: NSScreen, closedSize: CGSize) -> NSRect {
        let width = closedSize.width + 2 * peekZoneSlack
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - max(closedSize.height, 4),
            width: width,
            height: max(closedSize.height, 4)
        )
    }

    /// Whether `point` rests against the very top edge of `screen`, over the
    /// strip. Inclusive of `maxY`: the pointer pinned to the edge reports
    /// exactly that, which a half-open `NSRect.contains` would reject.
    static func isAtTopEdge(_ point: NSPoint, of screen: NSScreen, closedSize: CGSize) -> Bool {
        let zone = peekZone(on: screen, closedSize: closedSize)
        return point.x >= zone.minX && point.x <= zone.maxX
            && point.y >= screen.frame.maxY - topEdgeDepth && point.y <= screen.frame.maxY
    }

    /// How far below the top edge the pointer may sit and still count as
    /// pressed against it.
    static let topEdgeDepth: CGFloat = 3

    /// Extra width on each side of the strip that still counts as "at the notch".
    static let peekZoneSlack: CGFloat = 40

    /// Band that opens the shelf when a file drag reaches it. More forgiving
    /// than the peek zone: the pointer is carrying something and aiming is harder.
    static func dragZone(on screen: NSScreen, closedSize: CGSize) -> NSRect {
        let width = closedSize.width + 2 * 70
        let height = max(closedSize.height, 24) + 12
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    /// Screen rect of a panel of `size` hanging from the top centre of `screen`.
    static func panelFrame(on screen: NSScreen, size: CGSize) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
               width: size.width, height: size.height)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(for: $0) == displayID }
    }

    /// Display the keyboard shortcut and the menu bar item act on: the one under
    /// the pointer, falling back to the built-in cutout and then the main display.
    static var focusedScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
    }

    /// Top-centre frame on `screen` for a window of `windowSize`.
    static func windowFrame(on screen: NSScreen) -> NSRect {
        let size = windowSize
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
