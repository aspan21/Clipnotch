import Foundation

/// Adds and removes the radar's hooks in `~/.claude/settings.json`.
///
/// Changes are planned first and shown as a diff; nothing is written until the
/// user confirms. Writing keeps a timestamped backup, touches only the hook
/// groups that run `clipnotch-hook`, and refuses a file whose shape it does
/// not understand rather than replacing it.
enum ClaudeHooks {
    /// The events the radar reads. None of its hooks can block or decide.
    static let events = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    /// Generous for a helper that takes milliseconds, tight enough that a
    /// wedged one never stalls a session for long.
    private static let timeout = 5

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
            // Dotfile setups often symlink it; write through to the real file.
            .resolvingSymlinksInPath()
    }

    /// A stable copy outside the app bundle, so moving or rebuilding the app
    /// never leaves Claude Code calling a path that is gone.
    static var helperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clipnotch/bin/clipnotch-hook")
    }

    private static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clipnotch-hook")
    }

    private static var command: String { "\"\(helperURL.path)\"" }

    enum Failure: LocalizedError {
        case unreadable(String)
        case unexpectedShape(String)
        case changedOnDisk
        case helperMissing

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return String(localized: "Couldn’t read settings.json: \(reason)")
            case .unexpectedShape(let key):
                return String(localized: "settings.json has “\(key)” in a shape Clipnotch doesn’t recognise, so it was left alone.")
            case .changedOnDisk:
                return String(localized: "settings.json changed while you were reviewing it. Review the changes again.")
            case .helperMissing:
                return String(localized: "The hook helper is missing from the app bundle. Run Clipnotch from Clipnotch.app.")
            }
        }
    }

    struct Plan {
        let install: Bool
        let before: String
        let after: String
        let output: Data
        let lines: [DiffLine]
    }

    enum DiffLine: Hashable {
        case same(String)
        case added(String)
        case removed(String)
        /// Unchanged lines folded away.
        case gap
    }

    // MARK: - Status

    static func isInstalled() -> Bool {
        guard let settings = try? read(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: isOurs) ?? false
        }
    }

    /// Keeps the stable helper copy current, so an app update reaches it.
    static func refreshHelperIfInstalled() {
        guard isInstalled() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundledHelperURL.path),
              !fileManager.contentsEqual(atPath: bundledHelperURL.path, andPath: helperURL.path)
        else { return }
        try? copyHelper()
    }

    // MARK: - Plan and apply

    static func plan(install: Bool) throws -> Plan {
        var settings = try read()
        let before = try render(settings)

        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: throw Failure.unexpectedShape("hooks")
        }

        for event in events {
            var groups: [[String: Any]]
            switch hooks[event] {
            case nil: groups = []
            case let existing as [[String: Any]]: groups = existing
            default: throw Failure.unexpectedShape("hooks.\(event)")
            }
            groups.removeAll(where: isOurs)
            if install {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks

        let output = try serialize(settings)
        let after = String(decoding: output, as: UTF8.self)
        return Plan(install: install, before: before, after: after, output: output,
                    lines: diff(before: before, after: after))
    }

    static func apply(_ plan: Plan) throws {
        // Claude Code writes this file too; never overwrite what was not shown.
        guard try render(read()) == plan.before else { throw Failure.changedOnDisk }

        if plan.install { try copyHelper() }

        let url = settingsURL
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.clipnotch-backup-\(formatter.string(from: Date()))")
            try fileManager.copyItem(at: url, to: backup)
        }
        try plan.output.write(to: url, options: .atomic)

        if !plan.install { try? fileManager.removeItem(at: helperURL) }
    }

    // MARK: - Internals

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("clipnotch-hook") == true
        } ?? false
    }

    private static func read() throws -> [String: Any] {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unexpectedShape("settings.json")
            }
            return object
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    private static func serialize(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(contentsOf: Array("\n".utf8))
        return data
    }

    /// The file as it would look written back unchanged, so the diff shows
    /// only what the hooks change, not key order or indentation.
    private static func render(_ settings: [String: Any]) throws -> String {
        String(decoding: try serialize(settings), as: UTF8.self)
    }

    private static func copyHelper() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundledHelperURL.path) else { throw Failure.helperMissing }
        try fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: helperURL)
        try fileManager.copyItem(at: bundledHelperURL, to: helperURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    /// Line diff with three lines of context around each change.
    private static func diff(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                rows.append(.removed(old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                rows.append(.added(new[j]))
                j += 1
            } else if j < new.count {
                rows.append(.same(new[j]))
                i += 1
                j += 1
            } else {
                i += 1
            }
        }

        let context = 3
        let changed = rows.indices.filter {
            if case .same = rows[$0] { return false }
            return true
        }
        var kept: [DiffLine] = []
        var lastKept = -1
        for index in rows.indices {
            let near = changed.contains { abs($0 - index) <= context }
            if near {
                if index - lastKept > 1 { kept.append(.gap) }
                kept.append(rows[index])
                lastKept = index
            }
        }
        if lastKept < rows.count - 1 { kept.append(.gap) }
        return kept
    }
}
