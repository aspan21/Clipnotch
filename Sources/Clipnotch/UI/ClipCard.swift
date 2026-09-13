import SwiftUI

struct ClipCard: View {
    let item: ClipItem
    let queuePosition: Int?
    let onTap: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var isQueued: Bool { queuePosition != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The card face is its own tap target. The action buttons sit on
            // top of it rather than inside a Button's label, so their clicks
            // reach them instead of being swallowed by the card.
            content
                .frame(width: Theme.cardSize.width, height: Theme.cardSize.height)
                .clipShape(shape)
                .contentShape(shape)
                .onTapGesture(perform: onTap)

            if let position = queuePosition {
                Text("\(position)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accent))
                    .padding(6)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { actions }
        .overlay {
            shape.strokeBorder(
                isQueued ? Theme.accent : (isHovering ? Theme.primaryText.opacity(0.25) : Theme.cardStroke),
                lineWidth: isQueued ? 1.6 : 1
            )
        }
        // Hover raises the card instead of scaling it: a target that grows
        // under the pointer is a target you have to chase.
        .shadow(color: .black.opacity(isHovering ? 0.5 : 0), radius: 9, y: 4)
        .animation(Theme.quick, value: isHovering)
        .animation(Theme.snap, value: queuePosition)
        .onHover { isHovering = $0 }
        .help(helpText)
        .contextMenu {
            if item.kind == .image {
                Button("Preview", action: onPreview)
            }
            Button(isQueued ? "Remove from queue" : "Add to queue", action: onTap)
            Divider()
            Button("Delete", action: onDelete)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
    }

    private var content: some View {
        ZStack {
            Theme.cardFill

            switch item.kind {
            case .image:
                if let thumb = ClipStore.shared.thumbnail(for: item) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder(symbol: "photo")
                }

            case .files:
                VStack(spacing: 6) {
                    if let thumb = ClipStore.shared.thumbnail(for: item) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(firstFileName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }

            case .text, .richText:
                Text(item.textPreview ?? "")
                    .font(.system(size: 10.5, design: item.kind == .richText ? .default : .monospaced))
                    .foregroundStyle(Theme.primaryText.opacity(0.82))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) { footer }
    }

    private func placeholder(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Theme.tertiaryText)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon).resizable().frame(width: 11, height: 11)
            }
            Text(item.subtitle)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(Self.relative(item.createdAt))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(.black.opacity(0.62))
    }

    /// Revealed on hover in the card's own top-right corner, where the pointer
    /// can reach them without leaving the card and losing the hover.
    private var actions: some View {
        Group {
            if isHovering {
                HStack(spacing: 6) {
                    if item.kind == .image {
                        CardAction(symbol: "eye", help: "Preview", action: onPreview)
                    }
                    CardAction(symbol: "trash", help: "Delete", action: onDelete)
                }
                .padding(6)
                .transition(.opacity)
            }
        }
    }

    private var firstFileName: String {
        (item.textPreview ?? "").split(separator: "\n").first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "File"
    }

    private var helpText: String {
        if isQueued { return "Queued — click to remove" }
        return "Click to add to the paste queue"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CardAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                // 28pt: a target you hit without aiming.
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.black.opacity(isHovering ? 0.92 : 0.7))
                        .overlay(Circle().strokeBorder(.white.opacity(isHovering ? 0.35 : 0.14)))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
