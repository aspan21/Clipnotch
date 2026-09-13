import AppKit
import Foundation

/// Streams system-wide Now Playing state by running `mediaremote-adapter.pl`
/// under `/usr/bin/perl`, which is the only process Apple still lets load
/// MediaRemote on macOS 15.4+. Works for any player that publishes to the
/// system now-playing session — Spotify, Apple Music, YouTube in a browser,
/// Yandex Music, VLC, anything.
///
/// Adapter by Jonas van den Berg (BSD-3-Clause):
/// https://github.com/ungive/mediaremote-adapter
final class MediaRemoteBridge {
    enum Availability {
        case unknown
        case available
        case unavailable(String)
    }

    private(set) var availability: Availability = .unknown

    /// Called on the main queue. `artwork` is non-nil only when it changed.
    var onUpdate: ((NowPlayingSnapshot, NSImage?, Bool) -> Void)?
    var onAvailabilityChange: ((Availability) -> Void)?

    private let scriptURL: URL
    private let frameworkURL: URL

    private var process: Process?
    private var buffer = Data()
    /// Merged view of every payload seen so far, since the stream sends diffs.
    private var merged: [String: Any] = [:]
    private var restartAttempts = 0
    private var isStopping = false
    /// Set once the stream has produced a payload. The stream itself is the
    /// only availability test we can trust: the adapter's own `test` function
    /// needs a `MediaRemoteAdapterTestClient` binary that upstream does not
    /// ship with the framework, so calling it just reports
    /// "Test client path is missing" on a working system.
    private var hasStreamed = false
    private var lastStreamError = ""

    init?() {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "framework")
        else {
            Log.media.error("mediaremote-adapter resources missing from bundle")
            return nil
        }
        scriptURL = script
        frameworkURL = framework
    }

    // MARK: - Lifecycle

    func start() {
        isStopping = false
        hasStreamed = false
        restartAttempts = 0
        lastStreamError = ""
        // Optimistic: a working adapter answers within a second, and a broken
        // one is caught by the stream failing to produce anything.
        setAvailability(.available)
        spawnStream()
    }

    func stop() {
        isStopping = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Commands

    func send(_ command: MediaCommand) {
        runOneShot(["send", String(command.rawValue)])
    }

    func seek(toSeconds seconds: Double) {
        let micros = Int((seconds * 1_000_000).rounded())
        runOneShot(["seek", String(max(0, micros))])
    }

    /// Pulls a full snapshot immediately; used when the panel opens.
    func refresh() {
        runOneShot(["get", "--micros"]) { [weak self] data in
            guard let self,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                self.merge(payload: object, isDiff: false)
            }
        }
    }

    // MARK: - Process plumbing

    private func arguments(_ tail: [String]) -> [String] {
        [scriptURL.path, frameworkURL.path] + tail
    }

    private func spawnStream() {
        guard !isStopping else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // --micros gives an epoch timestamp in microseconds, so progress can be
        // extrapolated without parsing ISO-8601 and without sub-second drift.
        process.arguments = arguments(["stream", "--micros", "--debounce=150"])

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }

        process.terminationHandler = { [weak self] _ in
            guard let self, !self.isStopping else { return }
            outPipe.fileHandleForReading.readabilityHandler = nil

            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty { self.lastStreamError = message }

            // Exponential-ish backoff so a broken adapter cannot spin the CPU.
            self.restartAttempts += 1
            let attempts = self.restartAttempts

            // Two failed starts with nothing on the wire means the adapter is
            // genuinely not working; report why.
            if !self.hasStreamed, attempts >= 2 {
                let reason = self.lastStreamError.isEmpty
                    ? "MediaRemote is not available on this system"
                    : self.lastStreamError
                self.setAvailability(.unavailable(reason))
            }

            let delay = min(30.0, pow(2.0, Double(min(attempts, 5))))
            Log.media.warning("adapter stream exited, restarting in \(delay, privacy: .public)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.spawnStream() }
        }

        do {
            try process.run()
            self.process = process
            Log.media.info("adapter stream started")
        } catch {
            Log.media.error("failed to launch adapter: \(error.localizedDescription, privacy: .public)")
            setAvailability(.unavailable(error.localizedDescription))
        }
    }

    private func runOneShot(_ tail: [String], capture: ((Data) -> Void)? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments(tail)
        process.standardError = FileHandle.nullDevice

        if let capture {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { _ in
                capture(pipe.fileHandleForReading.readDataToEndOfFile())
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            Log.media.error("one-shot \(tail.first ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parsing

    /// Splits the NDJSON stream on newlines. Artwork payloads run to hundreds of
    /// kilobytes, so a line can span many reads.
    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
        // Guard against a runaway line with no newline in sight.
        if buffer.count > 64 * 1024 * 1024 { buffer.removeAll() }
    }

    private func handle(line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard (root["type"] as? String) == "data" else { return }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let isDiff = (root["diff"] as? Bool) ?? true
        DispatchQueue.main.async { self.merge(payload: payload, isDiff: isDiff) }
    }

    private func merge(payload: [String: Any], isDiff: Bool) {
        // First payload is the proof that the adapter works.
        if !hasStreamed {
            hasStreamed = true
            restartAttempts = 0
            setAvailability(.available)
        }

        if isDiff {
            for (key, value) in payload {
                // An explicit null clears the field; an absent key leaves it alone.
                if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
            }
        } else {
            merged = payload.filter { !($0.value is NSNull) }
        }

        let artworkChanged = payload.keys.contains("artworkData")
        var artwork: NSImage?
        if artworkChanged, let base64 = merged["artworkData"] as? String,
           let data = Data(base64Encoded: base64) {
            artwork = NSImage(data: data)
        }

        onUpdate?(snapshot(from: merged), artwork, artworkChanged)
    }

    private func snapshot(from raw: [String: Any]) -> NowPlayingSnapshot {
        var s = NowPlayingSnapshot()
        s.title = raw["title"] as? String ?? ""
        s.artist = raw["artist"] as? String ?? ""
        s.album = raw["album"] as? String ?? ""
        s.bundleIdentifier = raw["bundleIdentifier"] as? String
        s.isPlaying = raw["playing"] as? Bool ?? false
        s.playbackRate = number(raw["playbackRate"]) ?? 0

        // --micros renames the time keys; accept both spellings so a plain
        // `get` without the flag still decodes.
        if let micros = number(raw["durationMicros"]) {
            s.duration = micros / 1_000_000
        } else {
            s.duration = number(raw["duration"]) ?? 0
        }
        if let micros = number(raw["elapsedTimeMicros"]) {
            s.elapsedTime = micros / 1_000_000
        } else {
            s.elapsedTime = number(raw["elapsedTime"]) ?? 0
        }
        if let micros = number(raw["timestampEpochMicros"]) {
            s.timestamp = Date(timeIntervalSince1970: micros / 1_000_000)
        } else if let iso = raw["timestamp"] as? String,
                  let date = ISO8601DateFormatter().date(from: iso) {
            s.timestamp = date
        }
        return s
    }

    private func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func setAvailability(_ value: Availability) {
        availability = value
        DispatchQueue.main.async { self.onAvailabilityChange?(value) }
    }
}
