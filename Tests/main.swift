import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "StorageTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let zone = TimeZone(identifier: "Pacific/Honolulu")!
let store = AppStorage(directory: folder, timeZone: zone)
do {
    let defaults = try store.handle("settings") as! [String: Any]
    try require(defaults["focusMinutes"] as? Int == 25, "Default focus duration changed")
    let short: [String: Any] = ["focusMinutes": 1.0 / 6, "breakMinutes": 1.0 / 6]
    _ = try store.handle("settings", method: "PUT", body: short)
    let reloaded = try AppStorage(directory: folder).handle("settings") as! [String: Any]
    try require(abs((reloaded["focusMinutes"] as! Double) * 60 - 10) < 0.00001, "Ten-second settings did not survive restart")
    for invalid in [5.0 / 60, 11.0 / 60, 180.0 + 10.0 / 60] {
        var rejected = false
        do { _ = try store.handle("settings", method: "PUT", body: ["focusMinutes": invalid, "breakMinutes": 5]) }
        catch { rejected = true }
        try require(rejected, "Invalid duration accepted")
    }
    _ = try store.handle("settings", method: "PUT", body: ["focusMinutes": 180, "breakMinutes": 30])
    let maximum = try AppStorage(directory: folder).handle("settings") as! [String: Any]
    try require(maximum["focusMinutes"] as? Int == 180, "Three-hour setting did not survive restart")
    _ = try store.handle("settings", method: "PUT", body: ["focusMinutes": 30, "breakMinutes": 10])
    let exact = try store.handle("settings") as! [String: Any]
    try require(exact["focusMinutes"] as? Int == 30, "Exact 30-minute setting was lost")
    let oldLog: [String: Any] = ["version": 2, "timezone": "Legacy/Zone", "days": ["2000-01-01": ["count": 2, "focusMinutes": 50, "breakMinutes": 10]]]
    try JSONSerialization.data(withJSONObject: oldLog).write(to: folder.appendingPathComponent("completions.json"))
    _ = try store.handle("completions", method: "POST", body: short)
    let today = try store.handle("completions/today") as! [String: Any]
    try require(today["count"] as? Int == 1, "Completion was not recorded")
    try require(abs((today["focusMinutes"] as! Double) * 60 - 10) < 0.00001, "Short completion was rounded")
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = zone
    dateFormatter.dateFormat = "yyyy-MM-dd"
    try require(today["date"] as? String == dateFormatter.string(from: Date()), "Completion day ignored local timezone")
    let log = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("completions.json"))) as! [String: Any]
    try require(log["timezone"] as? String == "Pacific/Honolulu", "History timezone ignored system timezone")
    let days = log["days"] as! [String: [String: Any]]
    try require(days["2000-01-01"]?["count"] as? Int == 2, "Existing history was changed")
    let sessions = today["sessions"] as! [[String: Any]]
    try require((sessions[0]["completedAt"] as! String).hasSuffix("-10:00"), "Timestamp offset is incorrect")
    for removed in ["status", "capture-control"] {
        var rejected = false
        do { _ = try store.handle(removed, method: "PUT", body: ["paused": true]) }
        catch { rejected = true }
        try require(rejected, "Personal integration is still exposed")
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    try require(files == ["completions.json", "settings.json"], "Unexpected files written")
    let midnightFolder = folder.appendingPathComponent("midnight-tests")
    let iso = ISO8601DateFormatter()
    var clock = iso.date(from: "2030-01-02T07:59:59Z")! // 23:59:59 in Los Angeles.
    let localZone = TimeZone(identifier: "America/Los_Angeles")!
    let midnightStore = AppStorage(directory: midnightFolder, timeZone: localZone, now: { clock })
    _ = try midnightStore.handle("completions", method: "POST", body: short)
    let beforeMidnight = try midnightStore.handle("completions/today") as! [String: Any]
    try require(beforeMidnight["date"] as? String == "2030-01-01", "Used UTC instead of local day")
    try require(beforeMidnight["count"] as? Int == 1, "Round before midnight missing")
    try require(midnightStore.nextDayStart == iso.date(from: "2030-01-02T08:00:00Z")!, "Next refresh is not local midnight")
    clock = clock.addingTimeInterval(1)
    let afterMidnight = try midnightStore.handle("completions/today") as! [String: Any]
    try require(afterMidnight["date"] as? String == "2030-01-02" && afterMidnight["count"] as? Int == 0, "Midnight did not reset today's count")
    _ = try midnightStore.handle("completions", method: "POST", body: short)
    let restarted = AppStorage(directory: midnightFolder, timeZone: localZone, now: { clock })
    let newDay = try restarted.handle("completions/today") as! [String: Any]
    try require(newDay["count"] as? Int == 1, "New-day count did not survive restart")
    let midnightLog = try JSONSerialization.jsonObject(with: Data(contentsOf: midnightFolder.appendingPathComponent("completions.json"))) as! [String: Any]
    let midnightDays = midnightLog["days"] as! [String: [String: Any]]
    try require(midnightDays["2030-01-01"]?["count"] as? Int == 1, "Midnight erased historical rounds")
    let changedZone = AppStorage(directory: midnightFolder, timeZone: zone, now: { clock })
    let traveled = try changedZone.handle("completions/today") as! [String: Any]
    try require(traveled["date"] as? String == "2030-01-01", "Timezone change did not use the current local date")
    for (start, end, hours) in [("2030-03-10T08:00:00Z", "2030-03-11T07:00:00Z", 23.0), ("2030-11-03T07:00:00Z", "2030-11-04T08:00:00Z", 25.0)] {
        clock = iso.date(from: start)!
        try require(midnightStore.nextDayStart == iso.date(from: end)!, "DST scheduled the wrong local midnight")
        try require(midnightStore.nextDayStart.timeIntervalSince(clock) == hours * 3600, "Assumed a fixed 24-hour day")
    }
    clock = iso.date(from: "2030-01-05T20:00:00Z")!
    let afterSleep = try midnightStore.handle("completions/today") as! [String: Any]
    try require(afterSleep["count"] as? Int == 0, "Several days asleep leaked an old count")
    print("PASS: settings, exact durations, history preservation, local midnight, DST, timezone changes, history, and app-only storage")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
