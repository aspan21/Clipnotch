import AppKit
import Combine
import SwiftUI

/// Observable façade over `MediaRemoteBridge` for the SwiftUI layer.
@MainActor
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    @Published private(set) var snapshot = NowPlayingSnapshot()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkAccent: Color = .white
    @Published private(set) var isUnavailable = false
    @Published private(set) var unavailableReason = ""
    /// Ticks while playing so the progress bar animates without a stream update.
    @Published private(set) var position: Double = 0
    /// Worth showing in the closed notch: playing, or paused for less than
    /// `pauseLinger`. A pause that sticks folds the notch back to plain black.
    @Published private(set) var isLive = false

    private static let pauseLinger = Duration.seconds(3)
    private var lingerTask: Task<Void, Never>?

    private var bridge: MediaRemoteBridge?
    private var ticker: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Set while the user drags the scrubber so incoming updates don't fight them.
    private var scrubbing = false

    private init() {}

    func start() {
        guard let bridge = MediaRemoteBridge() else {
            isUnavailable = true
            unavailableReason = String(localized: "Adapter resources are missing from the app bundle.")
            return
        }
        self.bridge = bridge

        bridge.onUpdate = { [weak self] snapshot, artwork, artworkChanged in
            MainActor.assumeIsolated { self?.apply(snapshot, artwork: artwork, artworkChanged: artworkChanged) }
        }
        bridge.onAvailabilityChange = { [weak self] availability in
            MainActor.assumeIsolated {
                switch availability {
                case .available, .unknown:
                    self?.isUnavailable = false
                    self?.unavailableReason = ""
                case .unavailable(let reason):
                    self?.isUnavailable = true
                    self?.unavailableReason = reason
                }
            }
        }
        bridge.start()

        // The position is extrapolated from the snapshot, so a paused ticker
        // loses nothing: it picks up the right value when it resumes.
        ScreenActivity.shared.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { active ? self?.startTicker() : self?.stopTicker() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        lingerTask?.cancel()
        cancellables.removeAll()
        stopTicker()
        bridge?.stop()
        bridge = nil
    }

    func refresh() { bridge?.refresh() }

    private func startTicker() {
        guard ticker == nil else { return }
        if !scrubbing { position = snapshot.position() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = self.snapshot.position()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    var sourceAppName: String? {
        guard let id = snapshot.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var sourceAppIcon: NSImage? {
        guard let id = snapshot.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Controls

    func togglePlayPause() { bridge?.send(.togglePlayPause) }
    func next() { bridge?.send(.nextTrack) }
    func previous() { bridge?.send(.previousTrack) }

    func beginScrub() { scrubbing = true }

    func scrub(to value: Double) {
        position = value
    }

    func endScrub(at value: Double) {
        scrubbing = false
        position = value
        bridge?.seek(toSeconds: value)
    }

    // MARK: - Internals

    private func apply(_ new: NowPlayingSnapshot, artwork newArtwork: NSImage?, artworkChanged: Bool) {
        let trackChanged = new.title != snapshot.title || new.artist != snapshot.artist
        snapshot = new
        if !scrubbing { position = new.position() }
        updateLiveness()

        if artworkChanged {
            artwork = newArtwork
            artworkAccent = newArtwork.flatMap { Self.accent(from: $0) } ?? .white
        } else if trackChanged && newArtwork == nil && !new.hasTrack {
            artwork = nil
            artworkAccent = .white
        }
    }

    private func updateLiveness() {
        if snapshot.hasTrack, snapshot.isPlaying {
            lingerTask?.cancel()
            lingerTask = nil
            if !isLive { isLive = true }
        } else if !snapshot.hasTrack {
            // The player went away; nothing to linger over.
            lingerTask?.cancel()
            lingerTask = nil
            if isLive { isLive = false }
        } else if isLive, lingerTask == nil {
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: Self.pauseLinger)
                guard !Task.isCancelled else { return }
                self?.isLive = false
                self?.lingerTask = nil
            }
        }
    }

    /// Average colour of the artwork, saturation-boosted, used to tint the progress bar.
    private static func accent(from image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage
        else { return nil }

        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2])
        }
        let count = Double(width * height) * 255
        let base = NSColor(red: r / count, green: g / count, blue: b / count, alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return Color(base) }
        return Color(NSColor(
            hue: hsb.hueComponent,
            saturation: min(1, hsb.saturationComponent * 1.8),
            brightness: max(0.65, hsb.brightnessComponent),
            alpha: 1
        ))
    }
}
