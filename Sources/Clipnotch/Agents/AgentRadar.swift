import AppKit
import Combine

/// Watches Claude Code sessions through their hook events and says when one is
/// waiting on you: a permission prompt, a question, or a finished turn.
///
/// Events arrive from `clipnotch-hook` over a Unix socket, one JSON object per
/// connection. The radar never answers a hook: it only listens, so nothing it
/// does can hold up or change what Claude does.
@MainActor
final class AgentRadar: ObservableObject {
    static let shared = AgentRadar()

    /// Must match `socketPath` in the hook helper.
    nonisolated static let socketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clipnotch/radar.sock")

    /// Most urgent first, then the longest-waiting.
    @Published private(set) var sessions: [AgentSession] = []
    /// A session silent this long is assumed gone: closed terminal, crash, a
    /// missed SessionEnd.
    private static let staleAfter: TimeInterval = 12 * 3600

    private let queue = DispatchQueue(label: "clipnotch.radar", qos: .utility)
    private var acceptSource: DispatchSourceRead?

    private init() {}

    var attentionCount: Int { sessions.filter(\.needsAttention).count }

    /// The session the closed strip speaks for.
    var mostUrgent: AgentSession? { sessions.first(where: \.needsAttention) }

    // MARK: - Lifecycle

    func start() {
        guard acceptSource == nil else { return }
        let url = Self.socketURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let fd = Self.listen(at: url.path) else {
            Log.agents.error("radar: could not listen on \(url.path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            Self.acceptPending(on: fd) { data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(data) }
                }
            }
        }
        source.setCancelHandler {
            close(fd)
            unlink(url.path)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    // MARK: - Actions

    /// Brings the session's terminal forward and stops counting it.
    func open(_ session: AgentSession) {
        acknowledge(session.id)
        TerminalActivator.activate(bundleID: session.bundleID, termProgram: session.termProgram)
    }

    func acknowledge(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].acknowledged = true
    }

    // MARK: - Events

    private func receive(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = event["hook_event_name"] as? String,
              let id = event["session_id"] as? String
        else { return }

        // `claude -p` and SDK runs: scripts, not conversations — nobody is
        // going to come back and type the next prompt.
        if let entrypoint = event["entrypoint"] as? String, entrypoint.hasPrefix("sdk") { return }

        prune()

        if name == "SessionEnd" {
            sessions.removeAll { $0.id == id }
            return
        }

        var session = sessions.first { $0.id == id } ?? AgentSession(id: id, cwd: "")
        if let cwd = event["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        if let bundleID = event["bundle_id"] as? String, !bundleID.isEmpty { session.bundleID = bundleID }
        if let program = event["term_program"] as? String, !program.isEmpty { session.termProgram = program }
        session.lastEvent = Date()

        // A subagent's tool calls mean the session is busy; its own stop or
        // question is not the session waiting on you.
        let fromSubagent = event["agent_id"] != nil

        switch name {
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure":
            transition(&session, to: .working)
        case "PreToolUse":
            if event["tool_name"] as? String == "AskUserQuestion", !fromSubagent {
                transition(&session, to: .question)
            } else {
                transition(&session, to: .working)
            }
        case "Notification":
            let message = event["message"] as? String
            switch event["notification_type"] as? String {
            case "permission_prompt":
                transition(&session, to: .needsPermission, detail: message)
            case "elicitation_dialog", "agent_needs_input":
                transition(&session, to: .question, detail: message)
            case "idle_prompt":
                // A minute after the turn ended. Already reported by Stop;
                // only matters if Stop never arrived.
                if session.state == .working { transition(&session, to: .finished) }
            default:
                break
            }
        case "Stop":
            guard !fromSubagent else { break }
            // Background work still running will wake Claude up on its own.
            let background = event["background_tasks"] as? Int ?? 0
            transition(&session, to: background > 0 ? .working : .finished)
        case "StopFailure":
            guard !fromSubagent else { break }
            transition(&session, to: .failed, detail: event["message"] as? String)
        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortSessions()
    }

    private func transition(_ session: inout AgentSession, to state: AgentState, detail: String? = nil) {
        if state == session.state {
            if let detail { session.detail = detail }
            return
        }
        session.state = state
        session.detail = detail
        session.since = Date()
        session.acknowledged = false

        guard state.needsYou else { return }

        // Counted until you open it, even if its app is in front: an editor
        // like VS Code is in front all day, whichever window you look at.
        announce(session)
    }

    private func announce(_ session: AgentSession) {
        // Its app in front: you may well be watching it stop. Mark it, but
        // quietly.
        let inFront = session.bundleID != nil
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == session.bundleID
        if Settings.shared.agentSound, !inFront {
            // A finished turn is good news; a blocked one is a nudge.
            NSSound(named: session.state == .finished ? "Glass" : "Ping")?.play()
        }
        Log.agents.info("\(session.project, privacy: .public): \(String(describing: session.state), privacy: .public)")
    }

    private func sortSessions() {
        sessions.sort { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.state.urgency != b.state.urgency { return a.state.urgency < b.state.urgency }
            return a.since < b.since
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        sessions.removeAll { $0.lastEvent < cutoff }
    }

    // MARK: - Socket

    private nonisolated static func listen(at path: String) -> Int32? {
        // A socket file left behind by a crash would make bind fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Only this user may talk to it.
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Accepts every waiting connection and reads each to EOF. The helper
    /// writes one small object and closes, so this never waits long; the
    /// receive timeout covers a client that stalls.
    private nonisolated static func acceptPending(on fd: Int32, deliver: (Data) -> Void) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 64 * 1024 {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            if !data.isEmpty { deliver(data) }
        }
    }
}

/// Brings a session's terminal to the front.
enum TerminalActivator {
    /// `TERM_PROGRAM` values for when the hook saw no bundle identifier.
    private static let bundleIDs: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "vscode": "com.microsoft.VSCode",
        "kitty": "net.kovidgoyal.kitty",
    ]

    @MainActor
    static func activate(bundleID: String?, termProgram: String?) {
        let candidates = [bundleID, termProgram.flatMap { bundleIDs[$0] }].compactMap { $0 }
        for candidate in candidates {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: candidate).isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate)
            else { continue }
            // Through LaunchServices rather than NSRunningApplication.activate:
            // an accessory app asking another app to come forward is otherwise
            // refused since macOS 14.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
    }
}
