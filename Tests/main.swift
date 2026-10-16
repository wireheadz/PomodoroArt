import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "StorageTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let vault = folder.appendingPathComponent("vault")
let capture = folder.appendingPathComponent("capture.json")
let store = AppStorage(directory: folder, captureFile: capture, vault: vault)
do {
    let defaults = try store.handle("settings") as! [String: Any]
    try require(defaults["focusMinutes"] as? Int == 25, "Default focus duration changed")
    let short: [String: Any] = ["focusMinutes": 1.0 / 6, "breakMinutes": 1.0 / 6]
    _ = try store.handle("settings", method: "PUT", body: short)
    let reloaded = try AppStorage(directory: folder, captureFile: capture, vault: vault).handle("settings") as! [String: Any]
    try require(abs((reloaded["focusMinutes"] as! Double) * 60 - 10) < 0.00001, "Ten-second settings did not survive restart")
    for invalid in [5.0 / 60, 11.0 / 60, 61.0] {
        var rejected = false
        do { _ = try store.handle("settings", method: "PUT", body: ["focusMinutes": invalid, "breakMinutes": 5]) }
        catch { rejected = true }
        try require(rejected, "Invalid focus duration accepted")
    }
    _ = try store.handle("capture-control", method: "PUT", body: ["paused": true])
    let control = try store.handle("capture-control") as! [String: Any]
    try require(control["paused"] as? Bool == true && control["source"] as? String == "pomodoro-art", "Capture pause command changed")
    let statusFile = vault.appendingPathComponent("90 System/Agent Docs/Current Status.md")
    try FileManager.default.createDirectory(at: statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = "---\nother_field: preserve me\npomodoro_status: Pausing\npomodoro_status_updated_at: old\n---\n\n# Status\n\nKeep this paragraph.\n\n## Agent use\n\nKeep instructions.\n"
    try original.write(to: statusFile, atomically: true, encoding: .utf8)
    _ = try store.handle("status", method: "PUT", body: ["state": "Working"])
    let note = try String(contentsOf: statusFile, encoding: .utf8)
    try require(note.contains("pomodoro_status: Working") && note.contains("other_field: preserve me") && note.contains("Keep instructions."), "Status integration damaged existing content")
    _ = try store.handle("completions", method: "POST", body: short)
    let today = try store.handle("completions/today") as! [String: Any]
    try require(today["count"] as? Int == 1, "Completion was not recorded")
    try require(abs((today["focusMinutes"] as! Double) * 60 - 10) < 0.00001, "Short completion was rounded")
    let date = today["date"] as! String
    let activityFile = vault.appendingPathComponent("20 Areas/Journal/Activity Log/\(date).md")
    var activity = try String(contentsOf: activityFile, encoding: .utf8)
    activity += "\n## Other activity\n\nPreserve this.\n"
    try activity.write(to: activityFile, atomically: true, encoding: .utf8)
    _ = try store.handle("completions", method: "POST", body: short)
    let updated = try String(contentsOf: activityFile, encoding: .utf8)
    try require(updated.components(separatedBy: "<!-- pomodoro-art:begin -->").count == 2 && updated.contains("Preserve this."), "Activity update duplicated its section or damaged content")
    try require(updated.contains("2 completed cycles"), "Activity total was not updated")
    print("PASS: native settings, 10-second durations, validation, persistence, capture control, completion history, and Obsidian updates")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
