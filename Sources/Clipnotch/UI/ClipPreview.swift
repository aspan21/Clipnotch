import SwiftUI

/// One image clip at size. The panel grows to `NotchGeometry.previewSize` for
/// this, so the picture gets the room and the chrome stays out of its way.
struct ClipPreview: View {
    let item: ClipItem
    let onDismiss: () -> Void

    @EnvironmentObject var controller: NotchController

    var body: some View {
        VStack(spacing: 10) {
            header

            image
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            caption
        }
        .padding(.horizontal, NotchGeometry.contentInset(forTopRadius: NotchGeometry.cornerRadii.open.top))
        .padding(.top, 6)
        .padding(.bottom, Theme.contentGutter)
        .frame(width: controller.currentSize.width,
               height: controller.currentSize.height)
    }

    /// Same shape as the panel's own header, cutout reserve included: the
    /// camera housing covers that band, so nothing may be laid out in it.
    private var header: some View {
        HStack(spacing: 0) {
            BackButton(action: onDismiss)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: controller.closedSize.width)

            Color.clear
                .frame(maxWidth: .infinity)
        }
        .frame(height: controller.headerHeight)
    }

    private var image: some View {
        ZStack {
            if let image = ClipStore.shared.fullImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .light))
                    Text("This clip’s image is no longer on disk.")
                        .font(.system(size: 11))
                        .tracking(Theme.tracking(forSize: 11))
                }
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        // Clicking the picture goes back too, but that is a shortcut on top of
        // the button, never instead of it.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            Text(item.subtitle)
            if let name = item.sourceAppName {
                Text("·")
                Text(name)
            }
            Text("·")
            Text(ClipCard.relative(item.createdAt))
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .tracking(Theme.tracking(forSize: 11))
        .foregroundStyle(Theme.secondaryText)
        .frame(height: 16)
    }
}

private struct BackButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                Text("Back")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(Theme.tracking(forSize: 12))
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.24 : 0.14))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovering ? 0.4 : 0.26))
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
        .help("Back to Clips")
    }
}
