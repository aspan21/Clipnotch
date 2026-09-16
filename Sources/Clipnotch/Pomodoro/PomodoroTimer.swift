import AppKit
import SwiftUI

/// Focus/break cycle: four focus rounds, a short break after each, a long one
/// after the fourth.
///
/// Every phase keeps its own remaining time, but only one of them ever ticks:
/// `runningPhase`. Picking a phase in the pane only changes what is shown —
/// pressing play is what moves the clock, and starting one phase parks
/// whichever other one was running until someone comes back to it.
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

    /// The phase the pane is showing. Not necessarily the one that is running.
    @Published private(set) var phase: Phase = .focus
    /// The one phase counting down, if any.
    @Published private(set) var runningPhase: Phase?
    /// Focus rounds finished in the current cycle, 0...roundsPerCycle.
    @Published private(set) var completedRounds = 0
    /// Briefly true after a phase runs out, so the closed notch can say so.
    @Published private(set) var justFinished = false
    /// Bumped on every finished phase; drives the completion pulse.
    @Published private(set) var finishCount = 0
    /// Bumped on every discrete jump (reset, skip, length change, phase
    /// change), so the dial springs to its new value instead of snapping.
    @Published private(set) var revision = 0

    private var endDate: Date?
    /// Where each phase stands while it is not the one running, so switching
    /// away and back picks up from there instead of starting over.
    private var remainders: [Phase: TimeInterval] = [:]
    private var completionTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?

    private init() {}

    /// Anything worth showing in the closed notch.
    var isLive: Bool { runningPhase != nil || justFinished }

    /// Whichever phase the closed notch should report on: the running one, or
    /// the shown one when nothing runs.
    var livePhase: Phase { runningPhase ?? phase }

    /// True while any phase counts down. For "is the shown one running", ask
    /// `isRunning(_:)`.
    var isRunning: Bool { runningPhase != nil }

    func isRunning(_ phase: Phase) -> Bool { runningPhase == phase }

    /// True once the shown phase has been started and not reset.
    var hasProgress: Bool {
        isRunning(phase) || (remainders[phase] ?? duration(of: phase)) < duration(of: phase)
    }

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

    func remaining(of phase: Phase, at date: Date) -> TimeInterval {
        if runningPhase == phase, let endDate {
            return max(0, endDate.timeIntervalSince(date))
        }
        return remainders[phase] ?? duration(of: phase)
    }

    /// 0 at the start of the phase, 1 when it runs out.
    func progress(of phase: Phase, at date: Date) -> Double {
        let total = duration(of: phase)
        guard total > 0 else { return 0 }
        return 1 - remaining(of: phase, at: date) / total
    }

    // MARK: - Controls

    func toggle() {
        isRunning(phase) ? pause() : start()
    }

    /// Starts the shown phase. Whatever else was running stops where it is:
    /// one clock at a time.
    func start() {
        guard runningPhase != phase else { return }
        park()
        clearFinished()
        ChimePlayer.shared.stop()

        let left = remainders[phase] ?? duration(of: phase)
        let end = Date().addingTimeInterval(left)
        endDate = end
        runningPhase = phase
        scheduleCompletion(at: end)
    }

    func pause() {
        park()
    }

    /// Back to the top of the shown phase. If that is the phase running, it
    /// keeps running, from the top.
    func reset() {
        restarting { remainders[phase] = duration(of: phase) }
    }

    /// Straight to the next phase, without counting this one as done. A clock
    /// that was running follows along.
    func skip() {
        restarting {
            remainders[phase] = duration(of: phase)
            let upcoming = next(after: phase, countingRound: false)
            phase = upcoming
            remainders[upcoming] = duration(of: upcoming)
        }
    }

    /// Shows `phase`. Nothing starts and nothing stops: a phase already
    /// counting down keeps counting down behind the pane, and its tab keeps
    /// the running dot.
    func select(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        revision += 1
    }

    /// Sets the shown phase's length, and starts it over at that length —
    /// running or not, since the length is set from buttons rather than by
    /// dragging the dial.
    func setMinutes(_ minutes: Int) {
        let value = min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        guard value != self.minutes(of: phase) else { return }
        restarting {
            let settings = Settings.shared
            switch phase {
            case .focus: settings.focusMinutes = value
            case .shortBreak: settings.shortBreakMinutes = value
            case .longBreak: settings.longBreakMinutes = value
            }
            remainders[phase] = TimeInterval(value * 60)
        }
    }

    /// Nudges the shown phase's length, for the minus/plus stepper.
    func adjustMinutes(by delta: Int) {
        setMinutes(minutes(of: phase) + delta)
    }

    // MARK: - Internals

    /// Applies a change to the shown phase and puts its clock back the way it
    /// was found, so nothing but the pause button, another phase starting, or
    /// the time running out leaves a running phase paused.
    private func restarting(_ change: () -> Void) {
        let wasRunning = isRunning(phase)
        if wasRunning { park() }
        clearFinished()
        change()
        revision += 1
        if wasRunning { start() }
    }

    /// Banks the running phase's remaining time and stops the clock.
    private func park() {
        guard let running = runningPhase else { return }
        remainders[running] = remaining(of: running, at: Date())
        endDate = nil
        runningPhase = nil
        completionTask?.cancel()
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
        guard let done = runningPhase else { return }
        endDate = nil
        runningPhase = nil
        // Both the phase that ran out and the one after it are left full, ready
        // to be started again.
        remainders[done] = duration(of: done)
        let upcoming = next(after: done, countingRound: true)
        remainders[upcoming] = duration(of: upcoming)
        phase = upcoming
        revision += 1
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
