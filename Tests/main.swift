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
    print("PASS: settings, exact durations, history preservation, local timezone, and app-only storage")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
