import Foundation
import CoreFoundation

/// Settings and history stored only inside the app’s Application Support folder.
final class AppStorage {
    let directory: URL
    private let timeZone: TimeZone
    private let manager = FileManager.default
    private let encoder = JSONSerialization.WritingOptions([.prettyPrinted, .sortedKeys])

    init(directory: URL? = nil, timeZone: TimeZone = .autoupdatingCurrent) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pomodoro Art")
        self.timeZone = timeZone
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
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: Date())
    }

    private func emptyLog() -> [String: Any] {
        ["version": 2, "timezone": timeZone.identifier, "totals": ["cycles": 0, "focusMinutes": 0, "breakMinutes": 0], "days": [String: Any]()]
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
            log["timezone"] = timeZone.identifier
            log["days"] = days
            log["totals"] = totals(days)
            try write(log, to: logFile)
            var result = day
            result["date"] = today
            result["totals"] = log["totals"]
            return result
        default: throw failure("Unknown local storage operation")
        }
    }

}
