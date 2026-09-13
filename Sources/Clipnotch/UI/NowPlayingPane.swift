import SwiftUI

struct NowPlayingPane: View {
    let artworkNamespace: Namespace.ID

    @ObservedObject var media = NowPlayingModel.shared

    private static let artworkSide: CGFloat = 100

    var body: some View {
        Group {
            if media.isUnavailable {
                unavailable
            } else if media.snapshot.hasTrack {
                player
            } else {
                EmptyStateView(
                    symbol: "music.note",
                    title: "Nothing playing",
                    detail: "Start audio in any app and it shows up here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var player: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                artwork

                VStack(alignment: .leading, spacing: 6) {
                    MarqueeText(text: media.snapshot.title.isEmpty ? "Unknown title" : media.snapshot.title,
                                font: .system(size: 16, weight: .semibold),
                                tracking: Theme.tracking(forSize: 16))
                        .frame(height: 22)

                    // Only when there is one. An empty row here reads as a gap.
                    if !subtitleLine.isEmpty {
                        MarqueeText(text: subtitleLine,
                                    font: .system(size: 12.5, weight: .regular),
                                    color: Theme.secondaryText,
                                    tracking: Theme.tracking(forSize: 12.5))
                            .frame(height: 17)
                    }

                    Scrubber(
                        value: media.position,
                        total: media.snapshot.duration,
                        tint: media.artworkAccent,
                        onScrubBegan: media.beginScrub,
                        onScrubChanged: media.scrub(to:),
                        onScrubEnded: media.endScrub(at:)
                    )
                    .frame(height: 28)
                }
            }
            .frame(height: Self.artworkSide)

            // Its own row, so it is centred on the panel's axis. Centred inside
            // the text column it only ever lined up with the middle of that
            // column, which sits well right of the middle of the panel.
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitleLine: String {
        [media.snapshot.artist, media.snapshot.album]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.cardFill
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Same id as the closed strip's art: the artwork flies out of the
        // cutout instead of one copy fading out while another fades in.
        .matchedGeometryEffect(id: Theme.artworkGeometryID, in: artworkNamespace)
        .overlay(alignment: .bottomTrailing) {
            if let icon = media.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .padding(5)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// Centred under the scrubber it belongs to.
    private var controls: some View {
        HStack(spacing: 12) {
            TransportButton(symbol: "backward.fill", glyph: 13, side: 34, action: media.previous)
            TransportButton(
                symbol: media.snapshot.isPlaying ? "pause.fill" : "play.fill",
                glyph: 16,
                side: 42,
                prominent: true,
                action: media.togglePlayPause
            )
            TransportButton(symbol: "forward.fill", glyph: 13, side: 34, action: media.next)
        }
        .frame(height: 42)
        .frame(maxWidth: .infinity)
    }

    private var unavailable: some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: "Now Playing unavailable",
            detail: media.unavailableReason.isEmpty
                ? "The MediaRemote adapter could not start."
                : media.unavailableReason
        )
    }
}

private struct TransportButton: View {
    let symbol: String
    let glyph: CGFloat
    let side: CGFloat
    var prominent: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(prominent ? Color.black : Theme.primaryText)
                .frame(width: side, height: side)
                .background(
                    Circle().fill(
                        prominent
                            ? Theme.primaryText.opacity(isHovering ? 1 : 0.92)
                            : (isHovering ? Theme.cardFillHover : Theme.cardFill)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Feedback on press, and never a transform that moves the target the
        // pointer is already aiming at.
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(Theme.tracking(forSize: 13))
                .foregroundStyle(Theme.secondaryText)
            Text(detail)
                .font(.system(size: 11))
                .tracking(Theme.tracking(forSize: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
