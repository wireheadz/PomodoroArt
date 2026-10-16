const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

test('desktop server uses isolated storage and accepts its ephemeral-port origin', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'pomodoro-desktop-'));
  process.env.POMODORO_DATA_DIRECTORY = directory;
  process.env.POMODORO_PORT = '0';
  const { server } = require('../server');
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    const settings = { focusMinutes: 40, breakMinutes: 8 };
    const response = await fetch(`${origin}/api/settings`, {
      method: 'PUT', headers: { Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify(settings),
    });
    assert.equal(response.status, 200);
    const saved = await response.json();
    assert.equal(saved.focusMinutes, 40);
    assert.equal(saved.breakMinutes, 8);
    assert.deepEqual(JSON.parse(await fs.readFile(path.join(directory, 'settings.json'), 'utf8')), saved);
    assert.deepEqual(await (await fetch(`${origin}/api/settings`)).json(), saved);
    const forbidden = await fetch(`${origin}/api/settings`, {
      method: 'PUT', headers: { Origin: 'https://example.com', 'Content-Type': 'application/json' },
      body: JSON.stringify(settings),
    });
    assert.equal(forbidden.status, 403);
    const shortSettings = { focusMinutes: 1 / 6, breakMinutes: 1 / 6 };
    const shortResponse = await fetch(`${origin}/api/settings`, {
      method: 'PUT', headers: { Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify(shortSettings),
    });
    assert.equal(shortResponse.status, 200);
    const reloaded = await (await fetch(`${origin}/api/settings`)).json();
    assert.equal(reloaded.focusMinutes * 60, 10);
    assert.equal(reloaded.breakMinutes * 60, 10);
    for (const seconds of [5, 11]) {
      const invalid = await fetch(`${origin}/api/settings`, {
        method: 'PUT', headers: { Origin: origin, 'Content-Type': 'application/json' },
        body: JSON.stringify({ focusMinutes: seconds / 60, breakMinutes: 1 / 6 }),
      });
      assert.equal(invalid.status, 400);
    }
  } finally {
    await new Promise(resolve => server.close(resolve));
    await fs.rm(directory, { recursive: true, force: true });
  }
});
