const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function timer(nativeApp = true) {
  let now = 1_000_000;
  const messages = [];
  const requests = [];
  const elements = new Map();
  const element = () => ({
    style: { setProperty() {} }, classList: { add() {}, remove() {}, toggle() {} },
    setAttribute() {}, addEventListener() {}, replaceChildren() {}, appendChild() {},
    pause() { this.paused = true; }, play() { this.playCount += 1; this.paused = false; return Promise.resolve(); }, playCount: 0, paused: true, volume: 0,
  });
  const document = {
    getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); },
    createDocumentFragment: element, createElement: element,
    documentElement: element(), addEventListener() {},
  };
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({
    document, Date: Clock, navigator: {}, performance: { now: () => now },
    localStorage: { getItem: () => 'false', setItem() {} },
    window: { addEventListener() {}, ...(nativeApp ? { webkit: { messageHandlers: { pomodoro: { postMessage(message) { messages.push(message); } } } } } : {}) },
    fetch: (url, options) => { requests.push({ url, options }); return Promise.reject(new Error('offline')); },
    setInterval: () => 1, clearInterval() {}, cancelAnimationFrame() {}, requestAnimationFrame: () => 1,
  });
  const html = fs.readFileSync(require.resolve('../index.html'), 'utf8');
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  return { context, messages, requests, advance(seconds) { now += seconds * 1000; }, run(code) { return vm.runInContext(code, context); } };
}

test('ten-second focus and break durations display, persist, and complete accurately', () => {
  const app = timer();
  app.run('applyDurationSettings({ focusMinutes: 1 / 6, breakMinutes: 1 / 6 }); persistDurationSettings()');
  assert.equal(app.run('previews[0].textContent'), '00:10');
  assert.equal(app.run('previews[1].textContent'), '00:10');
  const settings = JSON.parse(app.requests.find(request => request.options?.method === 'PUT' && request.url === '/api/settings').options.body);
  assert.equal(settings.focusMinutes * 60, 10);
  assert.equal(settings.breakMinutes * 60, 10);
  app.run('start()');
  app.advance(9);
  app.run('tick()');
  assert.equal(app.run('remaining'), 1);
  assert.equal(app.run('awaitingConfirmation'), false);
  app.advance(1);
  app.run('tick(); confirmStage()');
  assert.equal(app.run('remaining'), 10);
  app.advance(10);
  app.run('tick()');
  assert.equal(app.run('completedCycles'), 1);
  const completion = JSON.parse(app.requests.find(request => request.url === '/api/completions' && request.options?.method === 'POST').options.body);
  assert.equal(completion.focusMinutes * 60, 10);
  assert.equal(completion.breakMinutes * 60, 10);
});

test('deadline catches up after background delay and completion happens once', () => {
  const app = timer();
  app.run('start()');
  assert.equal(app.messages.at(-1).state, 'Working');
  app.advance(1501);
  app.run('tick()');
  assert.equal(app.run('remaining'), 0);
  assert.equal(app.messages.at(-1).awaitingConfirmation, true);
  assert.equal(app.messages.at(-1).state, 'Pausing');
  const count = app.messages.length;
  app.run('tick()');
  assert.equal(app.messages.length, count);
  app.run('confirmStage()');
  assert.equal(app.messages.at(-1).state, 'Resting');
  app.advance(301);
  app.run('tick()');
  assert.equal(app.run('completedCycles'), 1);
  app.run('tick()');
  assert.equal(app.run('completedCycles'), 1);
});

test('pause accounts for elapsed time and resume creates a fresh deadline', () => {
  const app = timer();
  app.run('start()');
  app.advance(42);
  app.run('stop()');
  assert.equal(app.run('remaining'), 1458);
  assert.equal(app.messages.at(-1).deadline, null);
  app.advance(100);
  app.run('start()');
  app.advance(8);
  app.run('tick()');
  assert.equal(app.run('remaining'), 1450);
  app.run('reset()');
  assert.equal(app.run('remaining'), 1500);
  assert.equal(app.messages.at(-1).state, 'Pausing');
});

test('external capture pause preserves remaining time without completing a cycle', () => {
  const app = timer();
  app.run('start()');
  app.advance(65);
  app.run('pauseForCaptureControl()');
  assert.equal(app.run('remaining'), 1435);
  assert.equal(app.run('running'), false);
  assert.equal(app.run('completedCycles'), 0);
});


test('macOS countdown completion leaves sound to the system notification', () => {
  const app = timer();
  app.run('start()');
  app.advance(1501);
  app.run('tick()');
  assert.equal(app.run('awaitingConfirmation'), true);
  assert.equal(app.run('alarmAudio.playCount'), 0);
  app.run('confirmStage()');
  assert.equal(app.run('alarmAudio.playCount'), 0);
});

test('browser completion still plays its alarm and reset stops it', () => {
  const app = timer(false);
  app.run('start()');
  app.advance(1501);
  app.run('tick()');
  assert.equal(app.run('alarmAudio.playCount'), 1);
  assert.equal(app.run('alarmAudio.paused'), false);
  app.run('reset()');
  assert.equal(app.run('alarmAudio.paused'), true);
});
