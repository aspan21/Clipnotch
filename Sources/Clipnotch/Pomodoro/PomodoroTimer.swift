import AppKit
import SwiftUI

/// Focus/break cycle: four focus rounds, a short break after each, a long one
/// after the fourth.
///
/// Time is stored as an end date rather than a ticking counter, so nothing
/// publishes every second: views that show the clock read it off a
/// `TimelineView`, and the only published changes are the discrete ones.
@MainActor
final class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()

    enum Phase: String, CaseIterable, Identifiable {
        case focus
        case shortBreak
        case longBreak

        var id: String { rawValue }

        var title: String {
            switch self {
            case .focus: return String(localized: "Focus")
            case .shortBreak: return String(localized: "Short Break")
            case .longBreak: return String(localized: "Long Break")
            }
        }

        var tint: Color {
            switch self {
            case .focus: return Color(red: 1.0, green: 0.45, blue: 0.34)
            case .shortBreak: return Color(red: 0.33, green: 0.86, blue: 0.62)
            case .longBreak: return Color(red: 0.48, green: 0.62, blue: 1.0)
            }
        }
    }

    static let roundsPerCycle = 4
    static let minuteRange = 1...120
    /// How long the closed notch keeps showing a finished phase.
    private static let finishLinger = Duration.seconds(4)

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    /// Focus rounds finished in the current cycle, 0...roundsPerCycle.
    @Published private(set) var completedRounds = 0
    /// Briefly true after a phase runs out, so the closed notch can say so.
    @Published private(set) var justFinished = false
    /// Bumped on every finished phase; drives the completion pulse.
    @Published private(set) var finishCount = 0
    /// Bumped on every discrete jump (reset, skip, phase change), so the dial
    /// springs to its new value instead of snapping.
    @Published private(set) var revision = 0
    /// Remaining time of the current phase while it is not running. Published
    /// so dragging the dial redraws it.
    @Published private(set) var pausedRemaining: TimeInterval = 25 * 60

    private var endDate: Date?
    /// Where each phase was left off, so switching away and back resumes it
    /// instead of starting over.
    private var parked: [Phase: TimeInterval] = [:]
    private var completionTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?

    private init() {
        pausedRemaining = duration(of: .focus)
    }

    /// Anything worth showing in the closed notch.
    var isLive: Bool { isRunning || justFinished }

    /// True once the current phase has been started and not reset.
    var hasProgress: Bool { isRunning || pausedRemaining < duration(of: phase) }

    func duration(of phase: Phase) -> TimeInterval {
        TimeInterval(minutes(of: phase) * 60)
    }

    func minutes(of phase: Phase) -> Int {
        let settings = Settings.shared
        let value: Int
        switch phase {
        case .focus: value = settings.focusMinutes
        case .shortBreak: value = settings.shortBreakMinutes
        case .longBreak: value = settings.longBreakMinutes
        }
        return min(max(value, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    func remaining(at date: Date) -> TimeInterval {
        guard isRunning, let endDate else { return pausedRemaining }
        return max(0, endDate.timeIntervalSince(date))
    }

    /// 0 at the start of the phase, 1 when it runs out.
    func progress(at date: Date) -> Double {
        1 - remaining(at: date) / duration(of: phase)
    }

    // MARK: - Controls

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        clearFinished()
        ChimePlayer.shared.stop()
        let end = Date().addingTimeInterval(pausedRemaining)
        endDate = end
        isRunning = true
        scheduleCompletion(at: end)
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining(at: Date())
        endDate = nil
        isRunning = false
        completionTask?.cancel()
    }

    /// Back to the top of the current phase.
    func reset() {
        stop()
        pausedRemaining = duration(of: phase)
        revision += 1
    }

    /// Straight to the next phase, without counting this one as done.
    func skip() {
        stop()
        parked[phase] = nil
        enter(next(after: phase, countingRound: false), fresh: true)
    }

    /// Switches to `phase`, pausing the current one where it is. Coming back
    /// later picks up from there.
    func select(_ phase: Phase) {
        guard phase != self.phase else { return }
        pause()
        clearFinished()
        parked[self.phase] = pausedRemaining
        enter(phase, fresh: false)
    }

    /// Sets the current phase's length, and starts it over at that length.
    /// Only while the clock is stopped: the dial is not draggable while it runs.
    func setMinutes(_ minutes: Int) {
        guard !isRunning else { return }
        let value = min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        let settings = Settings.shared
        switch phase {
        case .focus: settings.focusMinutes = value
        case .shortBreak: settings.shortBreakMinutes = value
        case .longBreak: settings.longBreakMinutes = value
        }
        clearFinished()
        parked[phase] = nil
        pausedRemaining = TimeInterval(value * 60)
    }

    // MARK: - Internals

    private func stop() {
        completionTask?.cancel()
        clearFinished()
        endDate = nil
        isRunning = false
    }

    private func enter(_ phase: Phase, fresh: Bool) {
        self.phase = phase
        if fresh { parked[phase] = nil }
        pausedRemaining = parked.removeValue(forKey: phase) ?? duration(of: phase)
        revision += 1
    }

    private func next(after phase: Phase, countingRound: Bool) -> Phase {
        guard phase == .focus else {
            if phase == .longBreak { completedRounds = 0 }
            return .focus
        }
        let rounds = completedRounds + (countingRound ? 1 : 0)
        if rounds >= Self.roundsPerCycle {
            completedRounds = Self.roundsPerCycle
            return .longBreak
        }
        completedRounds = rounds
        return .shortBreak
    }

    private func scheduleCompletion(at end: Date) {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            // ContinuousClock under the hood, so a sleeping Mac still counts down.
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        endDate = nil
        isRunning = false
        parked[phase] = nil
        enter(next(after: phase, countingRound: true), fresh: true)
        ChimePlayer.shared.play()

        finishCount += 1
        justFinished = true
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finishLinger)
            guard !Task.isCancelled else { return }
            self?.justFinished = false
        }
    }

    private func clearFinished() {
        lingerTask?.cancel()
        if justFinished { justFinished = false }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
