import Foundation

// Claude Code runs this for every hook event Clipnotch registers. It forwards a
// trimmed copy of the event to the app's socket and exits 0 without printing:
// a hook's stdout can end up in Claude's context, and a non-zero exit shows up
// as an error in the session. If the app is not running, the event is dropped.

/// Must match `AgentRadar.socketURL` in the app.
let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Clipnotch/radar.sock").path

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

// Only what the radar reads. PostToolUse carries the tool's whole output,
// which can run to megabytes; none of it needs to cross the socket.
var forwarded: [String: Any] = [:]
for key in ["hook_event_name", "session_id", "cwd", "tool_name", "notification_type", "message", "agent_id"] {
    if let value = event[key] as? String { forwarded[key] = value }
}
switch event["background_tasks"] {
case let tasks as [Any]: forwarded["background_tasks"] = tasks.count
case let tasks as [String: Any]: forwarded["background_tasks"] = tasks.count
default: break
}

// Which app the session runs in, so the radar can bring it forward.
let environment = ProcessInfo.processInfo.environment
forwarded["bundle_id"] = environment["__CFBundleIdentifier"]
forwarded["term_program"] = environment["TERM_PROGRAM"]
forwarded["entrypoint"] = environment["CLAUDE_CODE_ENTRYPOINT"]

guard let payload = try? JSONSerialization.data(withJSONObject: forwarded) else { exit(0) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

// Never hold up a tool call over a wedged app.
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: pathBytes)
}

let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }

payload.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
        let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if written <= 0 { break }
        offset += written
    }
}
exit(0)
