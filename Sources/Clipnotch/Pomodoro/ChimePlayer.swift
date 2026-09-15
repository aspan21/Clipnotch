import AppKit
import Combine

/// The end-of-phase sound: a soft five-second chime, synthesised once at
/// first use instead of shipped as a file.
///
/// Two gentle arpeggios over a slow bell decay, quiet by design. System alert
/// sounds are short and sharp — right for an error, wrong for "your break is
/// over" landing in the middle of focused work.
@MainActor
final class ChimePlayer: NSObject, ObservableObject, NSSoundDelegate {
    static let shared = ChimePlayer()

    @Published private(set) var isPlaying = false

    private var sound: NSSound?

    private override init() {}

    func play() {
        stop()
        guard let sound = NSSound(data: Self.wav) else { return }
        sound.delegate = self
        self.sound = sound
        isPlaying = sound.play()
    }

    func stop() {
        sound?.stop()
        sound = nil
        isPlaying = false
    }

    func toggle() {
        isPlaying ? stop() : play()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        MainActor.assumeIsolated {
            guard sound === self.sound else { return }
            self.sound = nil
            isPlaying = false
        }
    }

    // MARK: - Synthesis

    private static let sampleRate = 44_100
    private static let length: Double = 5
    /// Peak level. Deliberately low: it should be noticed, not startle.
    private static let peak: Double = 0.28

    private struct Note {
        let start: Double
        let frequency: Double
        let level: Double
    }

    /// G major, rising, then an answering phrase that settles back home.
    private static let notes: [Note] = [
        Note(start: 0.00, frequency: 783.99, level: 1.0),   // G5
        Note(start: 0.32, frequency: 987.77, level: 0.85),  // B5
        Note(start: 0.64, frequency: 1174.66, level: 0.75), // D6
        Note(start: 1.90, frequency: 987.77, level: 0.55),  // B5
        Note(start: 2.22, frequency: 880.00, level: 0.5),   // A5
        Note(start: 2.54, frequency: 783.99, level: 0.6),   // G5
    ]

    private static let wav: Data = {
        let count = Int(length * Double(sampleRate))
        var mix = [Double](repeating: 0, count: count)

        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            for index in first..<count {
                let t = Double(index - first) / Double(sampleRate)
                let attack = min(1, t / 0.008)
                let omega = 2 * Double.pi * note.frequency * t
                // A sine body with short-lived upper partials: the slightly
                // inharmonic third is what makes it read as a bell, not a beep.
                let tone = sin(omega) * exp(-t / 1.2)
                    + 0.3 * sin(2 * omega) * exp(-t / 0.4)
                    + 0.1 * sin(3.01 * omega) * exp(-t / 0.18)
                mix[index] += note.level * attack * tone
            }
        }

        let loudest = mix.map(abs).max() ?? 1
        let gain = loudest > 0 ? peak / loudest : 0
        let fadeStart = length - 0.9

        var pcm = Data(capacity: count * 2)
        for (index, value) in mix.enumerated() {
            let t = Double(index) / Double(sampleRate)
            let fade = t > fadeStart ? max(0, (length - t) / (length - fadeStart)) : 1
            let sample = Int16(max(-1, min(1, value * gain * fade)) * Double(Int16.max))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }

        return waveHeader(dataSize: pcm.count) + pcm
    }()

    private static func waveHeader(dataSize: Int) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8

        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels)
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(blockAlign))
        append(blockAlign)
        append(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        return header
    }
}
