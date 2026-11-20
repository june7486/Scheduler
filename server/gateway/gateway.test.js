#!/usr/bin/env node
/**
 * Regression tests for the gateway's posture: where it binds, who may call it
 * cross-origin, what `/health` is allowed to say, and what `/readyz` must never
 * claim.
 *
 * ## Why these four things
 * Each one is a defect that was *found in production intent*, not imagined:
 *
 *   1. `listen(PORT, '0.0.0.0')` was hard-coded. The docs said loopback; the
 *      code said every interface. A gateway published to the internet by
 *      default is the whole vulnerability, so it gets a test.
 *   2. `Access-Control-Allow-Origin: *` on a **header**-authenticated API. The
 *      usual "wildcards cannot use credentials" defence does not apply here,
 *      so every site on the web could call the gateway and read the answer.
 *   3. `/health` carried `storage` (internal configuration) and `time` (nothing).
 *      It is served unauthenticated and published as static JSON.
 *   4. There was no readiness signal at all, so a proxy could not tell "alive"
 *      from "unable to store anything".
 *
 * ## Why zero dependencies
 * The gateway itself has none (`http`, `https`, `crypto`, `zlib`, `fs`, `path`
 * only) and ships as a single file an operator copies to a NAS. A test that
 * needed `npm install` would be a test nobody on that box could run. Node's
 * built-in runner is enough:
 *
 *   node --test server/gateway/gateway.test.js
 *
 * ## Why a real child process and real sockets
 * The interesting failures here are all in the *binding* and the *headers*, and
 * neither can be asserted against an in-process mock: a mock listens where you
 * tell it to, which is exactly the assumption under test. So each case spawns
 * the actual `server.js` with its own environment, on its own port, against a
 * throwaway data directory, and talks to it over TCP.
 */
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SERVER = path.join(__dirname, 'server.js');

/** Ports are picked per test so two suites on one box cannot collide. */
let nextPort = 8300;
const pickPort = () => nextPort++;

/**
 * Start the gateway as a child process and resolve once it is answering.
 *
 * Waits on the *socket*, not on stdout: parsing the banner would couple every
 * test to log formatting, and a log line can be reworded without changing
 * behaviour. The 10 s ceiling is generous for a process this small; hitting it
 * means a real failure, not a slow machine.
 */
async function startGateway(env) {
  const port = Number(env.PORT);
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let log = '';
  child.stdout.on('data', (d) => (log += d.toString()));
  child.stderr.on('data', (d) => (log += d.toString()));

  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`gateway exited early (${child.exitCode}):\n${log}`);
    }
    const ok = await new Promise((resolve) => {
      const probe = http.request(
        { host: '127.0.0.1', port, path: '/health', timeout: 400 },
        (res) => {
          res.resume();
          resolve(true);
        }
      );
      probe.on('error', () => resolve(false));
      probe.on('timeout', () => {
        probe.destroy();
        resolve(false);
      });
      probe.end();
    });
    if (ok) return { child, port, log: () => log };
    await new Promise((r) => setTimeout(r, 100));
  }
  child.kill('SIGKILL');
  throw new Error(`gateway did not come up on :${port}\n${log}`);
}

/** A minimal GET that keeps the status, headers and body separately visible. */
function get(port, urlPath, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, path: urlPath, method: 'GET', headers },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (body += c));
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers, body })
        );
      }
    );
    req.on('error', reject);
    req.end();
  });
}

/** An OPTIONS preflight, which is what a browser sends before a real call. */
function preflight(port, urlPath, origin) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        path: urlPath,
        method: 'OPTIONS',
        headers: {
          Origin: origin,
          'Access-Control-Request-Method': 'GET',
          'Access-Control-Request-Headers': 'X-Sync-Key',
        },
      },
      (res) => {
        res.resume();
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers })
        );
      }
    );
    req.on('error', reject);
    req.end();
  });
}

/** A fresh, writable data directory that the test owns and removes. */
function tempDataDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'june-gw-'));
}

// ---------------------------------------------------------------------------

test('binds to loopback by default, not to every interface', async () => {
  // The defect this pins down: `listen(PORT, '0.0.0.0')` was a literal. This
  // asserts the *default*, so deleting the `HOST` constant or reverting the
  // listen call fails here rather than in a port scan.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    // No HOST, no SYNC_SECRET: the purest default state.
  });
  try {
    // The banner names the interface. Asserting on it is acceptable here
    // because this is the one place the *value* matters and there is no other
    // way to read a listen address back out of Node.
    assert.match(
      gw.log(),
      /listening on 127\.0\.0\.1:\d+/,
      `expected a loopback bind, got:\n${gw.log()}`
    );
    // And the loopback address really does answer.
    const res = await get(gw.port, '/health');
    assert.strictEqual(res.status, 200);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/health says only what an unauthenticated client needs', async () => {
  // `/health` is world-readable AND published as frozen JSON on GitHub Pages.
  // `storage` leaked the backend mode; `time` leaked nothing useful but cost a
  // byte and invited clock-skew logic. Both must stay gone, while `service` and
  // `nas` must stay — the client distinguishes "our gateway" from "DSM login
  // page answering 200" using exactly those two keys.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
  });
  try {
    const res = await get(gw.port, '/health');
    assert.strictEqual(res.status, 200);
    const body = JSON.parse(res.body);

    assert.deepStrictEqual(
      Object.keys(body).sort(),
      ['nas', 'ok', 'service'],
      `unexpected /health keys: ${Object.keys(body)}`
    );
    assert.strictEqual(body.service, 'june-nas-gateway');
    assert.strictEqual(body.ok, true);
    assert.strictEqual(body.nas, true);

    // The removed fields, named explicitly so a future edit that re-adds one
    // fails with a message that says why.
    assert.strictEqual(body.storage, undefined, 'storage must not be published');
    assert.strictEqual(body.time, undefined, 'time must not be published');

    // No-store: an intermediary cache must never replay a liveness bit.
    assert.match(String(res.headers['cache-control']), /no-store/);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/readyz answers 200 {"ready":true} when the mode\'s dependency works', async () => {
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'a'.repeat(48),
  });
  try {
    const res = await get(gw.port, '/readyz');
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(JSON.parse(res.body), { ready: true });
    // Spec: no-store, and no topology in the body.
    assert.match(String(res.headers['cache-control']), /no-store/);
    assert.ok(
      !res.body.includes(dir),
      'the data directory path must never appear in a readiness reply'
    );
    // The probe cleans up after itself — a scratch file left behind would
    // slowly accumulate in the share.
    assert.ok(
      !fs.existsSync(path.join(dir, '.readyz.tmp')),
      'writability probe left a scratch file behind'
    );
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/readyz answers 503 storage when the data dir cannot be written', async () => {
  // The case that matters operationally: the process is alive (so `/health` is
  // 200 and a naive monitor is happy) but nothing can be saved. This is exactly
  // the state `/readyz` exists to expose.
  const dir = tempDataDir();
  fs.chmodSync(dir, 0o500); // r-x: traversable, not writable

  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'a'.repeat(48),
  });
  try {
    const health = await get(gw.port, '/health');
    assert.strictEqual(health.status, 200, 'liveness is unaffected by storage');
    assert.strictEqual(JSON.parse(health.body).nas, false, 'nas:false signals it');

    const ready = await get(gw.port, '/readyz');
    assert.strictEqual(ready.status, 503);
    assert.deepStrictEqual(JSON.parse(ready.body), {
      ready: false,
      reason: 'storage',
    });
  } finally {
    gw.child.kill('SIGKILL');
    fs.chmodSync(dir, 0o700);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/readyz answers 503 auth when exposed without a shared key', async () => {
  // Beyond loopback with no secret means "anyone who can reach this port can
  // read and write every workspace". Refusing to call that ready is the point.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    HOST: '0.0.0.0',
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: '', // deliberately absent
  });
  try {
    const res = await get(gw.port, '/readyz');
    assert.strictEqual(res.status, 503);
    assert.deepStrictEqual(JSON.parse(res.body), {
      ready: false,
      reason: 'auth',
    });

    // And the operator is told out loud at startup rather than discovering it
    // from a log line they never read.
    assert.match(gw.log(), /no SYNC_SECRET and listening beyond loopback/);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/readyz answers 503 auth when the shared key is too short to matter', async () => {
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'short',
  });
  try {
    const res = await get(gw.port, '/readyz');
    assert.strictEqual(res.status, 503);
    assert.deepStrictEqual(JSON.parse(res.body), {
      ready: false,
      reason: 'auth',
    });
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('CORS echoes an allow-listed origin and nothing else', async () => {
  // The regression: `Access-Control-Allow-Origin: *` on a header-authenticated
  // API. Three assertions, because each one alone can pass for the wrong reason.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'a'.repeat(48),
    CORS_ORIGINS: 'https://www.aqdesign.co.kr,https://www.june7486.com',
  });
  try {
    const allowed = await get(gw.port, '/health', {
      Origin: 'https://www.aqdesign.co.kr',
    });
    assert.strictEqual(
      allowed.headers['access-control-allow-origin'],
      'https://www.aqdesign.co.kr'
    );
    // `Vary: Origin` is not cosmetic: without it a shared cache can hand one
    // origin's reply to another.
    assert.match(String(allowed.headers.vary || ''), /Origin/);

    const blocked = await get(gw.port, '/health', {
      Origin: 'https://evil.example.com',
    });
    assert.strictEqual(
      blocked.headers['access-control-allow-origin'],
      undefined,
      'an unlisted origin must not receive an allow-origin header'
    );

    // A wildcard anywhere is a failure, even though it would "work".
    assert.notStrictEqual(
      allowed.headers['access-control-allow-origin'],
      '*',
      'wildcard ACAO defeats the whole allow-list'
    );

    const pre = await preflight(gw.port, '/api/state', 'https://www.june7486.com');
    assert.strictEqual(pre.status, 204);
    assert.strictEqual(
      pre.headers['access-control-allow-origin'],
      'https://www.june7486.com'
    );
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('CORS sends no allow-origin at all when the list is empty', async () => {
  // The default: no cross-origin callers. Same-origin requests are unaffected
  // by CORS, so this cannot break the normal same-host deployment.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'a'.repeat(48),
    // CORS_ORIGINS deliberately unset
  });
  try {
    const res = await get(gw.port, '/health', {
      Origin: 'https://www.aqdesign.co.kr',
    });
    assert.strictEqual(res.headers['access-control-allow-origin'], undefined);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/api/* still demands the shared key', async () => {
  // Guards against the CORS rework accidentally making the API anonymous:
  // /health and /readyz are public by design, everything under /api/ is not.
  const dir = tempDataDir();
  const key = 'k'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: key,
  });
  try {
    const denied = await get(gw.port, '/api/state?ws=TESTWS0001');
    assert.strictEqual(denied.status, 401);

    const accepted = await get(gw.port, '/api/state?ws=TESTWS0001', {
      'X-Sync-Key': key,
    });
    assert.strictEqual(accepted.status, 200);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Key rotation
// ---------------------------------------------------------------------------
//
// These exist because the key cannot be changed atomically. It is compiled into
// `main.dart.js`, so at any instant the population of open tabs is split between
// two keys and there is nothing the server can do to synchronise them. The tests
// below pin the *only* ordering that does not produce an outage.

test('during rotation both the current and the retired key are accepted', async () => {
  // The step that gets skipped. If `SYNC_SECRET_PREVIOUS` is not honoured, then
  // publishing a new bundle logs out every user whose old bundle is still
  // cached — which is most of them.
  const dir = tempDataDir();
  const current = 'c'.repeat(48);
  const previous = 'p'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: current,
    SYNC_SECRET_PREVIOUS: previous,
  });
  try {
    const withCurrent = await get(gw.port, '/api/state?ws=TESTWS0001', {
      'X-Sync-Key': current,
    });
    assert.strictEqual(withCurrent.status, 200, 'current key must work');

    const withPrevious = await get(gw.port, '/api/state?ws=TESTWS0001', {
      'X-Sync-Key': previous,
    });
    assert.strictEqual(
      withPrevious.status,
      200,
      'a cached bundle still sending the old key must keep working — this is ' +
        'the entire point of the rotation window'
    );

    // A third key is still refused: the window accepts exactly two, not "any".
    const withOther = await get(gw.port, '/api/state?ws=TESTWS0001', {
      'X-Sync-Key': 'x'.repeat(48),
    });
    assert.strictEqual(withOther.status, 401, 'an unrelated key must still fail');

    // And the operator can see the rotation is in progress.
    assert.match(gw.log(), /rotation=on/);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('after the retired key is removed it stops working immediately', async () => {
  // Step 4 of the rotation, and the reason the window must eventually close:
  // the whole exercise is pointless if the leaked key keeps being honoured.
  const dir = tempDataDir();
  const current = 'c'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: current,
    // SYNC_SECRET_PREVIOUS deliberately absent — rotation finished
  });
  try {
    // ## Why the retired key is not written out here
    // The first draft of this test pasted the real leaked key as a literal, to
    // "prove" it no longer works. That is self-defeating: it re-published the
    // credential inside the very file that asserts the credential is dead, in a
    // public repository. A retired key has to be *unrecoverable* from the repo,
    // which means the test cannot quote it.
    //
    // What is actually being pinned is the behaviour — "a key that is not the
    // current one is refused" — and any wrong key proves that. `notCurrent` is
    // deliberately the right length and shape so the check cannot pass merely
    // because the input was malformed.
    const notCurrent = 'f'.repeat(64);
    const res = await get(gw.port, '/api/state?ws=TESTWS0001', {
      'X-Sync-Key': notCurrent,
    });
    assert.strictEqual(
      res.status,
      401,
      'the retired key must be dead once SYNC_SECRET_PREVIOUS is removed'
    );
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('/readyz refuses a config where either key is too short', async () => {
  // A short *retired* key is still a door. Readiness must not report "ready"
  // just because the new key is strong.
  const dir = tempDataDir();
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: 'c'.repeat(48),
    SYNC_SECRET_PREVIOUS: 'short',
  });
  try {
    const res = await get(gw.port, '/readyz');
    assert.strictEqual(res.status, 503);
    assert.deepStrictEqual(JSON.parse(res.body), { ready: false, reason: 'auth' });
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a malformed key header is refused without throwing', async () => {
  // `crypto.timingSafeEqual` throws on unequal-length buffers, and an attacker
  // controls the header length. A throw inside the request handler would be a
  // one-request denial of service; this pins that it cannot happen.
  const dir = tempDataDir();
  const key = 'k'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: key,
  });
  try {
    for (const probe of ['', 'k', 'k'.repeat(47), 'k'.repeat(49), 'k'.repeat(2000)]) {
      const res = await get(gw.port, '/api/state?ws=TESTWS0001', {
        'X-Sync-Key': probe,
      });
      assert.strictEqual(
        res.status,
        401,
        `a ${probe.length}-byte key must be refused cleanly, not crash`
      );
    }
    // The server is still alive and still honouring the real key.
    const ok = await get(gw.port, '/api/state?ws=TESTWS0001', { 'X-Sync-Key': key });
    assert.strictEqual(ok.status, 200);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Derivable workspace ids and the destructive verbs
// ---------------------------------------------------------------------------
//
// `Store.workspaceCodeFor()` maps account id → workspace id with plain SHA-256,
// and that code is in a public repo. The shared key is also public (compiled
// into main.dart.js). Individually each is defensible; together they would let a
// stranger compute a workspace id and erase it.
//
// Changing the derivation would orphan every existing document, so the fix is on
// the destructive verbs: a wipe only lands on an account-shaped workspace id.

/** POST helper — `get` above is GET-only and these routes need a body. */
function post(port, urlPath, body, headers = {}) {
  const raw = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        path: urlPath,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(raw),
          ...headers,
        },
      },
      (res) => {
        let out = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (out += c));
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers, body: out })
        );
      }
    );
    req.on('error', reject);
    req.end(raw);
  });
}

test('reset is refused for a workspace id that is not account-shaped', async () => {
  const dir = tempDataDir();
  const key = 'k'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: key,
  });
  try {
    const auth = { 'X-Sync-Key': key };

    // Account-shaped: the derivation's own output shape. Allowed, because the
    // wipe flow a real client performs has to keep working.
    const ok = await post(gw.port, '/api/reset', { ws: 'ACC57DFBBA5C9FE10468296BE0DA575' }, auth);
    assert.strictEqual(ok.status, 200);

    // Not account-shaped: nothing legitimate wipes such a workspace, and an
    // attacker cannot reach a stranger's document this way.
    const refused = await post(gw.port, '/api/reset', { ws: 'SOMETHINGELSE0001' }, auth);
    assert.strictEqual(refused.status, 403);
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a wipe shaped as a push is refused for a non-account workspace', async () => {
  // Without this, the reset guard is decorative: the client's "I am the newest
  // generation, with nothing in it" push reaches the same end state one call
  // later. The two must agree or neither means anything.
  const dir = tempDataDir();
  const key = 'k'.repeat(48);
  const gw = await startGateway({
    PORT: String(pickPort()),
    STORAGE: 'local',
    DATA_DIR: dir,
    SYNC_SECRET: key,
  });
  try {
    const auth = { 'X-Sync-Key': key };

    const wipe = await post(
      gw.port,
      '/api/push',
      { ws: 'SOMETHINGELSE0001', gen: 5, entities: {} },
      auth
    );
    assert.strictEqual(wipe.status, 403, 'gen>0 with no entities is a wipe');

    // A genuine first write must still work — that is how a new device seeds its
    // own document, and blocking it would break sign-up on a clean NAS.
    const seed = await post(
      gw.port,
      '/api/push',
      { ws: 'SOMETHINGELSE0001', gen: 0, entities: { a1: { v: 1, updatedAt: 1 } } },
      auth
    );
    assert.strictEqual(seed.status, 200, 'an ordinary first write must not be blocked');
  } finally {
    gw.child.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
