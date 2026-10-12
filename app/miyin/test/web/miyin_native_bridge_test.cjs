const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const bridgePath = path.resolve(__dirname, '../../assets/miyin_v5/miyin-native-bridge.js');

function createBridge() {
  const posted = [];
  const window = { MiyinApp: { postMessage: (message) => posted.push(message) } };
  window.setTimeout = setTimeout;
  window.clearTimeout = clearTimeout;
  const context = vm.createContext({ window, Map, Promise, Date, setTimeout, clearTimeout });
  vm.runInContext(fs.readFileSync(bridgePath, 'utf8'), context, { filename: bridgePath });
  return { bridge: window.MiyinNativeBridge, posted };
}

test('posts versioned requests and resolves the matching request ID', async () => {
  const { bridge, posted } = createBridge();
  const response = bridge.request('history.list', { limit: 12 });
  const request = JSON.parse(posted[0]);

  assert.equal(request.version, 1);
  assert.equal(request.method, 'history.list');
  assert.equal(request.params.limit, 12);
  bridge.receive({ version: 1, id: request.id, ok: true, result: ['saved'] });
  assert.deepEqual(await response, ['saved']);
});

test('rejects a correlated native error with its stable code', async () => {
  const { bridge, posted } = createBridge();
  const response = bridge.request('translation.translate', {});
  const request = JSON.parse(posted[0]);
  bridge.receive({
    version: 1,
    id: request.id,
    ok: false,
    error: { code: 'model_missing', message: 'Download the model.' },
  });

  await assert.rejects(response, (error) => error.code === 'model_missing');
});
