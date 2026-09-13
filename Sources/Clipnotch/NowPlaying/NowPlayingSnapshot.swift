import AppKit
import Foundation

struct NowPlayingSnapshot: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var bundleIdentifier: String?
    var isPlaying: Bool = false
    var duration: Double = 0
    /// Elapsed time as reported at `timestamp`.
    var elapsedTime: Double = 0
    var timestamp: Date = .distantPast
    var playbackRate: Double = 0

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }

    /// Elapsed time extrapolated to `date` so the progress bar moves between updates.
    func position(at date: Date = Date()) -> Double {
        guard isPlaying, playbackRate != 0, timestamp != .distantPast else { return elapsedTime }
        let projected = elapsedTime + date.timeIntervalSince(timestamp) * playbackRate
        guard duration > 0 else { return max(0, projected) }
        return min(max(0, projected), duration)
    }
}

/// MRCommand identifiers accepted by the adapter's `send` function.
enum MediaCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}
