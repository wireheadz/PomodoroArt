import Foundation
import CoreFoundation

/// Local settings/history and the existing optional file integrations.
final class AppStorage {
    let directory: URL
    let captureFile: URL
    let vault: URL
    private var status: [String: Any] = [:]
    private let manager = FileManager.default
    private let encoder = JSONSerialization.WritingOptions([.prettyPrinted, .sortedKeys])

    init(directory: URL? = nil, captureFile: URL? = nil, vault: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        self.directory = directory ?? home.appendingPathComponent("Library/Application Support/Pomodoro Art")
        self.captureFile = captureFile ?? URL(fileURLWithPath: environment["POMODORO_CAPTURE_CONTROL_FILE"] ?? home.appendingPathComponent("Library/Application Support/MacLiveContext/pomodoro-capture-control.json").path)
        self.vault = vault ?? URL(fileURLWithPath: environment["POMODORO_OBSIDIAN_VAULT"] ?? home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal knowledge library").path)
    }

    private func read(_ url: URL) throws -> [String: Any]? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw failure("Invalid JSON data") }
        return value
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: encoder).write(to: url, options: .atomic)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PomodoroArt", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func duration(_ body: [String: Any], _ key: String, maximum: Double) throws -> Double {
        guard let number = body[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw failure("Invalid duration") }
        let seconds = number.doubleValue * 60
        guard seconds.isFinite, seconds >= 10, seconds <= maximum * 60,
              abs(seconds - seconds.rounded()) < 0.000001, Int(seconds.rounded()) % 10 == 0 else {
            throw failure("Durations must use 10-second steps")
        }
        return seconds.rounded() / 60
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: Date())
    }

    private func emptyLog() -> [String: Any] {
        ["version": 2, "timezone": "Asia/Shanghai", "totals": ["cycles": 0, "focusMinutes": 0, "breakMinutes": 0], "days": [String: Any]()]
    }

    private func totals(_ days: [String: [String: Any]]) -> [String: Any] {
        var cycles = 0
        var focus = 0.0
        var rest = 0.0
        for day in days.values {
            cycles += (day["count"] as? NSNumber)?.intValue ?? 0
            focus += (day["focusMinutes"] as? NSNumber)?.doubleValue ?? 0
            rest += (day["breakMinutes"] as? NSNumber)?.doubleValue ?? 0
        }
        return ["cycles": cycles, "focusMinutes": focus, "breakMinutes": rest]
    }

    func handle(_ operation: String, method: String = "GET", body: [String: Any] = [:]) throws -> Any {
        let settingsFile = directory.appendingPathComponent("settings.json")
        let logFile = directory.appendingPathComponent("completions.json")
        switch (method, operation) {
        case ("GET", "settings"):
            let settings = try read(settingsFile) ?? ["version": 1, "focusMinutes": 25, "breakMinutes": 5]
            _ = try duration(settings, "focusMinutes", maximum: 180)
            _ = try duration(settings, "breakMinutes", maximum: 30)
            return settings
        case ("PUT", "settings"):
            let settings: [String: Any] = ["version": 1, "focusMinutes": try duration(body, "focusMinutes", maximum: 180), "breakMinutes": try duration(body, "breakMinutes", maximum: 30), "updatedAt": timestamp()]
            try write(settings, to: settingsFile)
            return settings
        case ("GET", "capture-control"):
            guard let control = try read(captureFile) else { return NSNull() }
            guard control["version"] as? Int == 1, let paused = control["paused"] as? NSNumber,
                  CFGetTypeID(paused) == CFBooleanGetTypeID(), control["updatedAt"] is String, control["source"] is String else { throw failure("Invalid capture control") }
            return control
        case ("PUT", "capture-control"):
            guard let paused = body["paused"] as? NSNumber, CFGetTypeID(paused) == CFBooleanGetTypeID() else { throw failure("Invalid pause command") }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let control: [String: Any] = ["version": 1, "paused": paused.boolValue, "updatedAt": formatter.string(from: Date()), "source": "pomodoro-art"]
            try write(control, to: captureFile)
            return control
        case ("GET", "status"):
            return status
        case ("PUT", "status"):
            guard let state = body["state"] as? String, ["Working", "Resting", "Pausing"].contains(state) else { throw failure("Invalid status") }
            status = ["state": state, "updatedAt": timestamp()]
            do { try updateStatusNote(state, at: status["updatedAt"] as! String) }
            catch { NSLog("Unable to update Obsidian status: %@", error.localizedDescription) }
            return status
        case ("GET", "completions/today"):
            let log = try read(logFile) ?? emptyLog()
            let days = log["days"] as? [String: [String: Any]] ?? [:]
            let today = String(timestamp().prefix(10))
            var day = days[today] ?? ["count": 0, "focusMinutes": 0, "breakMinutes": 0, "completedAt": [String]()]
            day["date"] = today
            day["totals"] = totals(days)
            return day
        case ("POST", "completions"):
            let focus = try duration(body, "focusMinutes", maximum: 180)
            let rest = try duration(body, "breakMinutes", maximum: 30)
            var log = try read(logFile) ?? emptyLog()
            var days = log["days"] as? [String: [String: Any]] ?? [:]
            let time = timestamp()
            let today = String(time.prefix(10))
            var day = days[today] ?? [:]
            var dates = day["completedAt"] as? [String] ?? []
            let count = max((day["count"] as? NSNumber)?.intValue ?? 0, dates.count) + 1
            dates.append(time)
            var sessions = day["sessions"] as? [[String: Any]] ?? []
            sessions.append(["completedAt": time, "focusMinutes": focus, "breakMinutes": rest])
            day["count"] = count
            day["completedAt"] = dates
            day["sessions"] = sessions
            day["focusMinutes"] = ((day["focusMinutes"] as? NSNumber)?.doubleValue ?? 0) + focus
            day["breakMinutes"] = ((day["breakMinutes"] as? NSNumber)?.doubleValue ?? 0) + rest
            days[today] = day
            log["version"] = 2
            log["timezone"] = "Asia/Shanghai"
            log["days"] = days
            log["totals"] = totals(days)
            try write(log, to: logFile)
            do { try updateActivity(today, day: day) }
            catch { NSLog("Unable to update Obsidian activity: %@", error.localizedDescription) }
            var result = day
            result["date"] = today
            result["totals"] = log["totals"]
            return result
        default: throw failure("Unknown local storage operation")
        }
    }

    private func updateStatusNote(_ state: String, at time: String) throws {
        let file = vault.appendingPathComponent("90 System/Agent Docs/Current Status.md")
        guard manager.fileExists(atPath: file.path) else { return }
        var note = try String(contentsOf: file, encoding: .utf8)
        note = note.replacingOccurrences(of: #"(?m)^(pomodoro_status_updated_at:\s*.+?)---$"#, with: "$1\n---", options: .regularExpression)
        guard note.hasPrefix("---\n"), let end = note.range(of: "\n---", range: note.index(note.startIndex, offsetBy: 4)..<note.endIndex) else { throw failure("Missing status frontmatter") }
        var fields = String(note[note.index(note.startIndex, offsetBy: 4)..<end.lowerBound])
        for (key, value) in [("pomodoro_status", state), ("pomodoro_status_updated_at", time)] {
            let expression = try NSRegularExpression(pattern: "^" + key + ":.*$", options: .anchorsMatchLines)
            let range = NSRange(fields.startIndex..., in: fields)
            fields = expression.firstMatch(in: fields, range: range) != nil
                ? expression.stringByReplacingMatches(in: fields, range: range, withTemplate: key + ": " + value)
                : fields + "\n" + key + ": " + value
        }
        note.replaceSubrange(note.startIndex..<end.lowerBound, with: "---\n" + fields)
        let section = "## Pomodoro Alarm\n\nLatest reported alarm state: \(state).\n"
        let expression = try NSRegularExpression(pattern: #"## Pomodoro Alarm\n[\s\S]*?(?=\n## |\s*$)"#)
        let range = NSRange(note.startIndex..., in: note)
        if expression.firstMatch(in: note, range: range) != nil {
            note = expression.stringByReplacingMatches(in: note, range: range, withTemplate: section)
        } else if let position = note.range(of: "## Agent use") {
            note.insert(contentsOf: section + "\n", at: position.lowerBound)
        } else { note += "\n\n" + section }
        try note.write(to: file, atomically: true, encoding: .utf8)
    }

    private func updateActivity(_ date: String, day: [String: Any]) throws {
        guard manager.fileExists(atPath: vault.path) else { return }
        let file = vault.appendingPathComponent("20 Areas/Journal/Activity Log/\(date).md")
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sessions = day["sessions"] as? [[String: Any]] ?? []
        let entries = sessions.map { session -> String in
            let time = String((session["completedAt"] as? String ?? "").dropFirst(11).prefix(8))
            return "- \(time) · Focus \(session["focusMinutes"] ?? 0)m; Break \(session["breakMinutes"] ?? 0)m completed"
        }.joined(separator: "\n")
        let count = (day["count"] as? NSNumber)?.intValue ?? 0
        let section = "<!-- pomodoro-art:begin -->\n## Pomodoro\n\n- Total: \(count) completed \(count == 1 ? "cycle" : "cycles"); \(day["focusMinutes"] ?? 0)m focus; \(day["breakMinutes"] ?? 0)m break.\n\(entries)\n<!-- pomodoro-art:end -->"
        var note = manager.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : "---\ntype: activity-log\ndate: \(date)\ntags:\n  - activity-log\n---\n\n# Activity Log — \(date)\n"
        let expression = try NSRegularExpression(pattern: #"<!-- pomodoro-art:begin -->[\s\S]*?<!-- pomodoro-art:end -->"#)
        let range = NSRange(note.startIndex..., in: note)
        note = expression.firstMatch(in: note, range: range) != nil
            ? expression.stringByReplacingMatches(in: note, range: range, withTemplate: section)
            : note + "\n\n" + section + "\n"
        try note.write(to: file, atomically: true, encoding: .utf8)
    }
}
