const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const fsSync = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const temporaryDirectory = fsSync.mkdtempSync(path.join(os.tmpdir(), "pomodoro-capture-control-"));
process.env.POMODORO_CAPTURE_CONTROL_FILE = path.join(temporaryDirectory, "pomodoro-capture-control.json");
const { readCaptureControl, recordCaptureControl } = require("../server");

test.after(async () => {
  await fs.rm(temporaryDirectory, { recursive: true, force: true });
});

test("writes the pause command Mac Live Context consumes", async () => {
  const control = await recordCaptureControl(true);

  assert.deepEqual(await readCaptureControl(), control);
  assert.equal(control.version, 1);
  assert.equal(control.paused, true);
  assert.equal(control.source, "pomodoro-art");
  assert.ok(Number.isFinite(Date.parse(control.updatedAt)));
});

test("does not treat an invalid shared command as a valid pause state", async () => {
  await fs.writeFile(process.env.POMODORO_CAPTURE_CONTROL_FILE, "{}\n", "utf8");

  await assert.rejects(readCaptureControl(), /invalid structure/);
});
