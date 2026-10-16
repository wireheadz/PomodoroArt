const http = require("node:http");
const { createReadStream } = require("node:fs");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");

const host = "127.0.0.1";
const port = Number(process.env.POMODORO_PORT || 4173);
const rootDirectory = __dirname;
const dataDirectory = process.env.POMODORO_DATA_DIRECTORY || path.join(rootDirectory, "data");
const dataFile = path.join(dataDirectory, "completions.json");
const settingsFile = path.join(dataDirectory, "settings.json");
const obsidianVaultDirectory = process.env.POMODORO_OBSIDIAN_VAULT || path.join(
  os.homedir(), "Library", "Mobile Documents", "iCloud~md~obsidian", "Documents", "Personal knowledge library",
);
const activityLogDirectory = path.join(obsidianVaultDirectory, "20 Areas", "Journal", "Activity Log");
const currentStatusFile = path.join(obsidianVaultDirectory, "90 System", "Agent Docs", "Current Status.md");
const captureControlFile = process.env.POMODORO_CAPTURE_CONTROL_FILE || path.join(
  os.homedir(), "Library", "Application Support", "MacLiveContext", "pomodoro-capture-control.json",
);
const timezone = "Asia/Shanghai";

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".mp3": "audio/mpeg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
};

let completionQueue = Promise.resolve();
let settingsQueue = Promise.resolve();
let statusQueue = Promise.resolve();
let captureControlQueue = Promise.resolve();

function localTimestamp(date = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(date).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]),
  );

  const day = `${parts.year}-${parts.month}-${parts.day}`;
  return {
    day,
    completedAt: `${day}T${parts.hour}:${parts.minute}:${parts.second}+08:00`,
  };
}

function emptyLog() {
  return {
    version: 2,
    timezone,
    totals: { cycles: 0, focusMinutes: 0, breakMinutes: 0 },
    days: {},
  };
}

async function readLog() {
  try {
    const parsed = JSON.parse(await fs.readFile(dataFile, "utf8"));
    if (!parsed || typeof parsed !== "object" || !parsed.days || typeof parsed.days !== "object") {
      throw new Error("Completion log has an invalid structure");
    }
    return parsed;
  } catch (error) {
    if (error.code === "ENOENT") return emptyLog();
    throw error;
  }
}

async function writeLog(log) {
  await fs.mkdir(dataDirectory, { recursive: true });
  const temporaryFile = `${dataFile}.${process.pid}.tmp`;
  await fs.writeFile(temporaryFile, `${JSON.stringify(log, null, 2)}\n`, "utf8");
  await fs.rename(temporaryFile, dataFile);
}

async function readStatus() {
  try {
    const note = await fs.readFile(currentStatusFile, "utf8");
    const state = note.match(/^pomodoro_status:\s*(Working|Resting|Pausing)\s*$/m)?.[1];
    const updatedAt = note.match(/^pomodoro_status_updated_at:\s*(.+)\s*$/m)?.[1];
    if (!state || !updatedAt) {
      throw new Error("Pomodoro status has an invalid structure");
    }
    return { state, updatedAt };
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function currentStatusContentWithPomodoroState(note, state, updatedAt) {
  const normalizedNote = note.replace(
    /^(pomodoro_status_updated_at:\s*.+?)---$/m,
    "$1\n---",
  );
  const frontmatter = normalizedNote.match(/^---\n([\s\S]*?)\n---/);
  if (!frontmatter) throw new Error("Current Status is missing YAML frontmatter");

  const upsertField = (fields, key, value) => {
    const pattern = new RegExp(`^${key}:.*$`, "m");
    return pattern.test(fields) ? fields.replace(pattern, `${key}: ${value}`) : `${fields}\n${key}: ${value}`;
  };
  let fields = frontmatter[1];
  fields = upsertField(fields, "pomodoro_status", state);
  fields = upsertField(fields, "pomodoro_status_updated_at", updatedAt);
  let updated = normalizedNote.replace(frontmatter[0], `---\n${fields}\n---`);
  const section = `## Pomodoro Alarm\n\nLatest reported alarm state: ${state}.\n`;
  const sectionPattern = /## Pomodoro Alarm\n[\s\S]*?(?=\n## |\s*$)/;
  if (sectionPattern.test(updated)) return updated.replace(sectionPattern, section.trimEnd());
  const agentUse = "## Agent use";
  return updated.includes(agentUse)
    ? updated.replace(agentUse, `${section}\n${agentUse}`)
    : `${updated.trimEnd()}\n\n${section}`;
}

function pomodoroActivitySection(day, current) {
  const sessions = Array.isArray(current.sessions) ? current.sessions : [];
  const entries = sessions
    .map((session) => {
      const time = typeof session.completedAt === "string" ? session.completedAt.slice(11, 19) : "Unknown time";
      return `- ${time} · Focus ${session.focusMinutes}m; Break ${session.breakMinutes}m completed`;
    })
    .join("\n");
  const count = Number(current.count) || 0;
  const focusMinutes = Number(current.focusMinutes) || 0;
  const breakMinutes = Number(current.breakMinutes) || 0;
  return [
    "<!-- pomodoro-art:begin -->",
    "## Pomodoro",
    "",
    `- Total: ${count} completed ${count === 1 ? "cycle" : "cycles"}; ${focusMinutes}m focus; ${breakMinutes}m break.`,
    entries,
    "<!-- pomodoro-art:end -->",
  ].filter(Boolean).join("\n");
}

function newActivityLog(day) {
  return [
    "---",
    "type: activity-log",
    `date: ${day}`,
    "tags:",
    "  - activity-log",
    "---",
    "",
    `# Activity Log — ${day}`,
    "",
  ].join("\n");
}

async function upsertPomodoroActivity(day, current) {
  await fs.mkdir(activityLogDirectory, { recursive: true });
  const activityLogFile = path.join(activityLogDirectory, `${day}.md`);
  let note;
  try {
    note = await fs.readFile(activityLogFile, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    note = newActivityLog(day);
  }

  const section = pomodoroActivitySection(day, current);
  const pattern = /<!-- pomodoro-art:begin -->[\s\S]*?<!-- pomodoro-art:end -->/;
  const updated = pattern.test(note)
    ? note.replace(pattern, section)
    : `${note.trimEnd()}\n\n${section}\n`;
  if (updated !== note) await fs.writeFile(activityLogFile, updated, "utf8");
}

async function syncPomodoroActivities(log) {
  for (const [day, current] of Object.entries(log.days).sort(([left], [right]) => left.localeCompare(right))) {
    await upsertPomodoroActivity(day, current);
  }
}

function recordStatus(state) {
  const operation = statusQueue.then(async () => {
    const { completedAt } = localTimestamp();
    const status = { state, updatedAt: completedAt };
    const note = await fs.readFile(currentStatusFile, "utf8");
    const updated = currentStatusContentWithPomodoroState(note, state, completedAt);
    const temporaryFile = `${currentStatusFile}.${process.pid}.tmp`;
    await fs.writeFile(temporaryFile, updated, "utf8");
    await fs.rename(temporaryFile, currentStatusFile);
    return status;
  });

  statusQueue = operation.catch(() => {});
  return operation;
}

async function readCaptureControl() {
  try {
    const control = JSON.parse(await fs.readFile(captureControlFile, "utf8"));
    if (
      !control || control.version !== 1 || typeof control.paused !== "boolean" ||
      typeof control.updatedAt !== "string" || typeof control.source !== "string"
    ) {
      throw new Error("Pomodoro capture control has an invalid structure");
    }
    return control;
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function recordCaptureControl(paused) {
  const operation = captureControlQueue.then(async () => {
    const control = {
      version: 1,
      paused,
      updatedAt: new Date().toISOString(),
      source: "pomodoro-art",
    };
    await fs.mkdir(path.dirname(captureControlFile), { recursive: true });
    const temporaryFile = `${captureControlFile}.${process.pid}.tmp`;
    await fs.writeFile(temporaryFile, `${JSON.stringify(control, null, 2)}\n`, "utf8");
    await fs.rename(temporaryFile, captureControlFile);
    return control;
  });

  captureControlQueue = operation.catch(() => {});
  return operation;
}

function defaultSettings() {
  return { version: 1, focusMinutes: 25, breakMinutes: 5 };
}

async function readSettings() {
  try {
    const settings = JSON.parse(await fs.readFile(settingsFile, "utf8"));
    validMinutes(settings.focusMinutes, 1 / 6, 60, "focusMinutes");
    validMinutes(settings.breakMinutes, 1 / 6, 30, "breakMinutes");
    return settings;
  } catch (error) {
    if (error.code === "ENOENT") return defaultSettings();
    throw error;
  }
}

function saveSettings({ focusMinutes, breakMinutes }) {
  const operation = settingsQueue.then(async () => {
    const settings = {
      version: 1,
      focusMinutes,
      breakMinutes,
      updatedAt: localTimestamp().completedAt,
    };
    await fs.mkdir(dataDirectory, { recursive: true });
    const temporaryFile = `${settingsFile}.${process.pid}.tmp`;
    await fs.writeFile(temporaryFile, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
    await fs.rename(temporaryFile, settingsFile);
    return settings;
  });

  settingsQueue = operation.catch(() => {});
  return operation;
}

function totalsFromDays(days) {
  return Object.values(days).reduce((totals, day) => {
    totals.cycles += Number(day.count) || 0;
    totals.focusMinutes += Number(day.focusMinutes) || 0;
    totals.breakMinutes += Number(day.breakMinutes) || 0;
    return totals;
  }, { cycles: 0, focusMinutes: 0, breakMinutes: 0 });
}

function validMinutes(value, minimum, maximum, label) {
  const minutes = Number(value);
  const seconds = minutes * 60;
  if (!Number.isFinite(seconds) || seconds < minimum * 60 || seconds > maximum * 60 ||
      Math.abs(seconds - Math.round(seconds)) > 1e-6 || Math.round(seconds) % 10 !== 0) {
    const error = new Error(`${label} must represent 10 seconds to ${maximum} minutes in 10-second steps`);
    error.statusCode = 400;
    throw error;
  }
  return Math.round(seconds) / 60;
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 4096) {
      const error = new Error("Request body is too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    const error = new Error("Request body must be valid JSON");
    error.statusCode = 400;
    throw error;
  }
}

function recordCompletion({ focusMinutes, breakMinutes }) {
  const operation = completionQueue.then(async () => {
    const { day, completedAt } = localTimestamp();
    const log = await readLog();
    const current = log.days[day] || {
      count: 0,
      focusMinutes: 0,
      breakMinutes: 0,
      completedAt: [],
      sessions: [],
    };
    current.completedAt = Array.isArray(current.completedAt) ? current.completedAt : [];
    current.sessions = Array.isArray(current.sessions) ? current.sessions : [];
    const previousCount = Math.max(Number(current.count) || 0, current.completedAt.length);
    current.completedAt.push(completedAt);
    current.sessions.push({ completedAt, focusMinutes, breakMinutes });
    current.count = previousCount + 1;
    current.focusMinutes = (Number(current.focusMinutes) || 0) + focusMinutes;
    current.breakMinutes = (Number(current.breakMinutes) || 0) + breakMinutes;
    log.version = 2;
    log.timezone = timezone;
    log.days[day] = current;
    log.totals = totalsFromDays(log.days);
    await writeLog(log);
    await upsertPomodoroActivity(day, current);
    return {
      date: day,
      count: current.count,
      completedAt,
      focusMinutes: current.focusMinutes,
      breakMinutes: current.breakMinutes,
      totals: log.totals,
    };
  });

  completionQueue = operation.catch(() => {});
  return operation;
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
  });
  response.end(`${JSON.stringify(payload)}\n`);
}

function hasTrustedOrigin(request) {
  const origin = request.headers.origin;
  if (!origin) return true;
  const listeningPort = server.address()?.port || port;
  return origin === `http://${host}:${listeningPort}` || origin === `http://localhost:${listeningPort}`;
}

async function serveStatic(request, response, pathname) {
  const relativePath = pathname === "/" ? "index.html" : decodeURIComponent(pathname).replace(/^\/+/, "");
  const filePath = path.resolve(rootDirectory, relativePath);
  if (filePath !== rootDirectory && !filePath.startsWith(`${rootDirectory}${path.sep}`)) {
    sendJson(response, 403, { error: "Forbidden" });
    return;
  }

  try {
    const stats = await fs.stat(filePath);
    if (!stats.isFile()) throw Object.assign(new Error("Not found"), { code: "ENOENT" });
    const contentType = contentTypes[path.extname(filePath).toLowerCase()] || "application/octet-stream";
    const range = request.headers.range?.match(/^bytes=(\d*)-(\d*)$/);
    let start = 0;
    let end = stats.size - 1;
    let statusCode = 200;

    if (range) {
      if (!range[1] && range[2]) {
        const suffixLength = Number(range[2]);
        start = Math.max(0, stats.size - suffixLength);
      } else {
        start = range[1] ? Number(range[1]) : 0;
        end = range[2] ? Number(range[2]) : end;
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || start >= stats.size) {
        response.writeHead(416, { "Content-Range": `bytes */${stats.size}` });
        response.end();
        return;
      }
      end = Math.min(end, stats.size - 1);
      statusCode = 206;
    }

    const headers = {
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-cache",
      "Content-Length": end - start + 1,
      "Content-Type": contentType,
    };
    if (statusCode === 206) headers["Content-Range"] = `bytes ${start}-${end}/${stats.size}`;
    response.writeHead(statusCode, headers);
    if (request.method === "HEAD") {
      response.end();
      return;
    }
    createReadStream(filePath, { start, end }).pipe(response);
  } catch (error) {
    if (error.code === "ENOENT") {
      sendJson(response, 404, { error: "Not found" });
      return;
    }
    throw error;
  }
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host || `${host}:${port}`}`);

    if (request.method === "GET" && url.pathname === "/api/health") {
      sendJson(response, 200, { ok: true, timezone });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/completions/today") {
      const { day } = localTimestamp();
      const log = await readLog();
      const current = log.days[day] || {
        count: 0,
        focusMinutes: 0,
        breakMinutes: 0,
        completedAt: [],
      };
      sendJson(response, 200, {
        date: day,
        count: current.count,
        focusMinutes: current.focusMinutes || 0,
        breakMinutes: current.breakMinutes || 0,
        completedAt: current.completedAt,
        totals: log.totals || totalsFromDays(log.days),
      });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/settings") {
      sendJson(response, 200, await readSettings());
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/status") {
      sendJson(response, 200, await readStatus());
      return;
    }

    if (request.method === "PUT" && url.pathname === "/api/status") {
      if (!hasTrustedOrigin(request)) {
        sendJson(response, 403, { error: "Forbidden origin" });
        return;
      }
      const body = await readJsonBody(request);
      if (!["Working", "Resting", "Pausing"].includes(body.state)) {
        const error = new Error("state must be Working, Resting, or Pausing");
        error.statusCode = 400;
        throw error;
      }
      sendJson(response, 200, await recordStatus(body.state));
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/capture-control") {
      sendJson(response, 200, await readCaptureControl());
      return;
    }

    if (request.method === "PUT" && url.pathname === "/api/capture-control") {
      if (!hasTrustedOrigin(request)) {
        sendJson(response, 403, { error: "Forbidden origin" });
        return;
      }
      const body = await readJsonBody(request);
      if (typeof body.paused !== "boolean") {
        const error = new Error("paused must be a boolean");
        error.statusCode = 400;
        throw error;
      }
      sendJson(response, 200, await recordCaptureControl(body.paused));
      return;
    }

    if (request.method === "PUT" && url.pathname === "/api/settings") {
      if (!hasTrustedOrigin(request)) {
        sendJson(response, 403, { error: "Forbidden origin" });
        return;
      }
      const body = await readJsonBody(request);
      const focusMinutes = validMinutes(body.focusMinutes, 1 / 6, 60, "focusMinutes");
      const breakMinutes = validMinutes(body.breakMinutes, 1 / 6, 30, "breakMinutes");
      sendJson(response, 200, await saveSettings({ focusMinutes, breakMinutes }));
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/completions") {
      if (!hasTrustedOrigin(request)) {
        sendJson(response, 403, { error: "Forbidden origin" });
        return;
      }
      const body = await readJsonBody(request);
      const focusMinutes = validMinutes(body.focusMinutes, 1 / 6, 60, "focusMinutes");
      const breakMinutes = validMinutes(body.breakMinutes, 1 / 6, 30, "breakMinutes");
      sendJson(response, 201, await recordCompletion({ focusMinutes, breakMinutes }));
      return;
    }

    if (request.method === "GET" || request.method === "HEAD") {
      await serveStatic(request, response, url.pathname);
      return;
    }

    sendJson(response, 405, { error: "Method not allowed" });
  } catch (error) {
    const statusCode = error.statusCode || 500;
    if (statusCode >= 500) console.error(error);
    sendJson(response, statusCode, {
      error: statusCode >= 500 ? "Internal server error" : error.message,
    });
  }
});

if (require.main === module) {
  server.listen(port, host, async () => {
    console.log(`Pomodoro running at http://${host}:${server.address().port}`);
    console.log(`Completion log: ${dataFile}`);
    try {
      await syncPomodoroActivities(await readLog());
      console.log(`Activity log: ${activityLogDirectory}`);
    } catch (error) {
      console.error("Unable to sync Pomodoro activity logs", error);
    }
  });
}

module.exports = { server, readCaptureControl, recordCaptureControl };
