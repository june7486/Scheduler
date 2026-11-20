#!/usr/bin/env node
/**
 * June Scheduler — NAS gateway.
 *
 * ## Why this exists
 * The app is a *web* page. Synology's FileStation API does not send
 * `Access-Control-Allow-Origin`, so a browser is not allowed to read its
 * replies — the request leaves, the answer is sealed. No amount of retrying
 * fixes that; only a server on our own origin can.
 *
 * So this one file does three things:
 *   1. Holds the DSM session (a browser must never see the NAS password).
 *   2. Talks FileStation: read / write one small JSON file per workspace.
 *   3. Answers the browser with proper CORS from our own origin.
 *
 * `/health` exposes a read-only, credential-free up/down bit that is safe to
 * commit as static JSON on GitHub Pages — that is how the web app knows whether
 * to use the NAS or fall back to local storage immediately.
 *
 * ## Latency design (the whole point)
 * * One file per workspace, so a read is a single download — no index scan.
 * * In-memory cache with a short TTL: repeat opens cost 0 network calls.
 * * `rev` short-circuit: the client sends the rev it already has, and an
 *   unchanged workspace returns ~40 bytes instead of the full document.
 * * **Long poll** (`wait=25`): the request parks here and answers the instant a
 *   write lands, so a change on one device appears on another within one round
 *   trip while an idle session costs ~2 requests/minute instead of 30.
 * * **Write echo**: the push answer carries `key → updatedAt` for every record
 *   the merge accepted, so the client confirms its outbox from the reply and
 *   never needs the "write then immediately re-read" double round trip.
 * * **gzip** on document bodies: a year of tasks compresses ~8×.
 * * Single in-flight download per workspace (coalesced), so ten widgets asking
 *   at once still cause one request.
 * * Keep-alive HTTP agent to the NAS, so no TLS handshake per call.
 *
 * Zero dependencies — Node 18+ only, same as the direct server.
 */
'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

// ---------------- Config ----------------

const PORT = Number(process.env.PORT || 8097);

/**
 * The interface the gateway binds to.
 *
 * ## Why this is not `0.0.0.0` any more
 * It used to be hard-coded to `0.0.0.0` — every interface — on the theory that
 * a firewall would keep the outside out. That is a single layer of defence, and
 * it is the wrong one to rely on: an operator who starts the process on a
 * machine without a firewall, or behind a NAT that forwards the port, publishes
 * the gateway to the internet without ever seeing a warning. The gateway is
 * designed to sit *behind* a reverse proxy, so the only interface it has any
 * business listening on is the loopback one.
 *
 * `HOST` exists for the one legitimate exception: running the gateway where a
 * proxy lives in a different network namespace (a container sidecar, a
 * separate machine on a private network). Anyone who sets it is making an
 * explicit, visible decision instead of getting one by default.
 *
 *   HOST=127.0.0.1   default — only this machine can reach it
 *   HOST=::1         IPv6 loopback
 *   HOST=0.0.0.0     every interface — only behind a firewall you control
 */
const HOST = (process.env.HOST || '127.0.0.1').trim();

/**
 * Exact origins allowed to call the gateway cross-origin, comma separated.
 *
 * ## Why `Access-Control-Allow-Origin: *` had to go
 * `*` is usually defended with "a browser will not send cookies to a wildcard
 * origin, so nobody can act as the user". That reasoning does not apply here:
 * this gateway authenticates with a **header** (`X-Sync-Key`), not a cookie. A
 * wildcard therefore meant every site on the internet could call it and read
 * the reply.
 *
 * An empty list means "no cross-origin callers" — which is the correct default
 * once the app is served from the same origin as the gateway (Nginx proxies
 * `/api/` on the site's own host). Same-origin requests are unaffected by CORS
 * regardless of this setting, so an empty list cannot break the normal
 * deployment.
 *
 *   CORS_ORIGINS=https://www.aqdesign.co.kr,https://www.june7486.com
 */
const CORS_ORIGINS = (process.env.CORS_ORIGINS || '')
  .split(',')
  .map((s) => s.trim().replace(/\/+$/, ''))
  .filter(Boolean);

/**
 * Where the workspace JSON files actually live.
 *
 *   local — a plain directory on the machine running the gateway (fastest).
 *   dsm   — uploaded to the NAS through DSM's FileStation API.
 *
 * Both exist on purpose. `local` is the right choice when the gateway itself
 * runs *on* the NAS (a packaged Node process): it removes an entire HTTPS round
 * trip per read and per write, and the share is already the durable copy.
 * `dsm` is for running the gateway anywhere else while still keeping the data
 * on the NAS.
 */
const STORAGE = (process.env.STORAGE || (process.env.NAS_HOST ? 'dsm' : 'local'))
  .trim()
  .toLowerCase();

/** Data directory for `STORAGE=local`.
 *
 * Deliberately the same folder DSM mode writes to: switching drivers then
 * finds the existing documents instead of an empty directory. */
const DATA_DIR = (process.env.DATA_DIR || path.join(__dirname, 'data')).trim();

const NAS_HOST = (process.env.NAS_HOST || '').trim();
const NAS_PORT = Number(process.env.NAS_PORT || 5001);
const NAS_USER = (process.env.NAS_USER || '').trim();
const NAS_PASS = process.env.NAS_PASS || '';
const NAS_SESSION = (process.env.NAS_SESSION || 'FileStation').trim();
const NAS_FOLDER = (process.env.NAS_FOLDER || '').trim(); // e.g. /92_Scheduler/sync
const NAS_INSECURE = process.env.NAS_INSECURE !== '0'; // file:// + self-signed

/** Shared secret the app sends as `X-Sync-Key`. Empty ⇒ open (LAN only). */
const SYNC_SECRET = (process.env.SYNC_SECRET || '').trim();

/**
 * Keys the gateway also accepts while a rotation is in flight.
 *
 * ## Why a single key cannot be rotated safely
 * The key is not stored anywhere the server can change it: `deploy_pages.sh`
 * passes it through `--dart-define`, which splices it into `main.dart.js` *as a
 * string literal*. So the moment a new key is published, every browser that
 * loads the new bundle sends the new key — and every browser that still has the
 * old `main.dart.js` cached (which is most of them, for as long as GitHub Pages
 * and the browser cache say so) sends the old one.
 *
 * With one accepted key that window is a hard outage: whichever side you change
 * second, half the clients get 401 until the cache drains. Users do not report
 * "I am in the rotation window"; they report "동기화가 안 됩니다", and there is no
 * way to tell the two apart from the outside.
 *
 * ## What this does instead
 * Both keys are accepted for as long as `SYNC_SECRET_PREVIOUS` is set — long
 * enough for every cached bundle to expire — and then it is removed. The order
 * is what makes it safe, and it is the reverse of what feels natural:
 *
 *   1. Set `SYNC_SECRET_PREVIOUS=<old>` and `SYNC_SECRET=<new>` on the gateway.
 *      Both work now. Nothing breaks. (This is the step people skip.)
 *   2. Publish a bundle built with the new key. Old tabs keep working.
 *   3. Wait out the cache. Watch the gateway log for the old-key counter to sit
 *      at zero.
 *   4. Remove `SYNC_SECRET_PREVIOUS`. Now the old key is dead.
 *
 * ## Why not just accept every key
 * Because then the key would not be a filter at all — and the point of the key
 * is not secrecy (it is in the bundle; it never was secret) but to stop a
 * mistyped or stale client from writing to a workspace it does not own. Two
 * keys bound that risk; an unbounded list would not.
 */
const SYNC_SECRET_PREVIOUS = (process.env.SYNC_SECRET_PREVIOUS || '').trim();

/** Every key the gateway currently honours, current first.
 *
 * Empty ⇒ no auth (loopback-only default; `/readyz` refuses this beyond
 * loopback). `SYNC_SECRET` alone ⇒ the normal single-key deployment. */
const ACCEPTED_KEYS = [SYNC_SECRET, SYNC_SECRET_PREVIOUS].filter(Boolean);

/** How long a document may be served from RAM before re-checking the NAS. */
const CACHE_MS = Number(process.env.CACHE_MS || 8000);

/** Longest a `/api/state` request may be parked waiting for a change.
 *
 * 20 s, not 60: DSM's own reverse proxy has shorter idle timeouts and buffers
 * aggressively. Staying well inside them means the connection is never cut
 * mid-wait, which is what would otherwise look like "sync randomly stops". */
const MAX_WAIT_MS = 20000;

/** Optional URL prefix when mounted under a sub-path (e.g. `/scheduler-sync`).
 *
 * DSM's reverse proxy usually maps a whole subdomain, but a path prefix is also
 * common. Normalising here means the route checks work either way instead of a
 * silent 404 that looks like a broken deployment. */
const BASE_PATH = (() => {
  const raw = (process.env.BASE_PATH || '').trim();
  if (!raw || raw === '/') return '';
  const withSlash = raw.startsWith('/') ? raw : `/${raw}`;
  return withSlash.replace(/\/+$/, '');
})();

/** Hard cap on a workspace body. A decade of tasks is far below this. */
const MAX_BODY = 8 * 1024 * 1024;

const WS_RE = /^[A-Za-z0-9_-]{6,64}$/;
const FILE_RE = /^[A-Za-z0-9_-]{6,64}\.json$/;

if (STORAGE !== 'local' && STORAGE !== 'dsm') {
  console.error(`[gateway] FATAL: STORAGE must be "local" or "dsm" (got "${STORAGE}")`);
  process.exit(1);
}

if (STORAGE === 'dsm') {
  if (!NAS_HOST || !NAS_USER || !NAS_PASS) {
    console.error('[gateway] FATAL: STORAGE=dsm needs NAS_HOST / NAS_USER / NAS_PASS');
    process.exit(1);
  }
  if (!NAS_FOLDER.startsWith('/')) {
    console.error('[gateway] FATAL: NAS_FOLDER must be an absolute share path');
    process.exit(1);
  }
}

const API = NAS_HOST ? `https://${NAS_HOST}:${NAS_PORT}/webapi/entry.cgi` : '';

// ---------------- DSM client ----------------

/** Keep-alive agent: the NAS is called constantly, so reuse the socket. */
const agent = new https.Agent({
  keepAlive: true,
  maxSockets: 8,
  rejectUnauthorized: !NAS_INSECURE,
});

const session = { sid: null, at: 0, inflight: null };
const SESSION_MS = 20 * 60 * 1000; // DSM drops idle sessions; refresh early

function httpsJson(url, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      {
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        method,
        headers,
        agent,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const raw = Buffer.concat(chunks);
          resolve({ status: res.statusCode, raw });
        });
      }
    );
    req.setTimeout(20000, () => req.destroy(new Error('nas timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function formBody(fields) {
  const boundary = '----june' + crypto.randomBytes(8).toString('hex');
  const parts = [];
  for (const [k, v] of Object.entries(fields)) {
    parts.push(
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`
      )
    );
  }
  parts.push(Buffer.from(`--${boundary}--\r\n`));
  return {
    boundary,
    body: Buffer.concat(parts),
  };
}

async function dsmLogin() {
  // GET with query parameters, deliberately NOT multipart.
  // DSM rejects a multipart POST to SYNO.API.Auth with error 115 (no permission)
  // even though the same credentials succeed over a GET query string — verified
  // against DSM 7 on this NAS. Login is rare (once per session), so the tiny
  // credential-in-query exposure is acceptable and stays inside the TLS tunnel.
  const q = new URLSearchParams({
    api: 'SYNO.API.Auth',
    version: '6',
    method: 'login',
    account: NAS_USER,
    passwd: NAS_PASS,
    session: NAS_SESSION,
    format: 'sid',
  });
  const res = await httpsJson(`${API}?${q.toString()}`);
  let json;
  try {
    json = JSON.parse(res.raw.toString('utf8'));
  } catch {
    throw new Error('nas login: bad response');
  }
  if (!json.success) {
    throw new Error(`nas login failed: ${JSON.stringify(json.error || json)}`);
  }
  session.sid = json.data.sid;
  session.at = Date.now();
  return session.sid;
}

/** Returns a live SID, logging in at most once for concurrent callers. */
async function sid() {
  if (session.sid && Date.now() - session.at < SESSION_MS) return session.sid;
  if (!session.inflight) {
    session.inflight = dsmLogin().finally(() => {
      session.inflight = null;
    });
  }
  return session.inflight;
}

/** Runs a DSM call, re-logging in once if the session expired (error 119). */
async function dsm(api, params, { retry = true } = {}) {
  const s = await sid();
  const q = new URLSearchParams({ api, _sid: s, ...params });
  const res = await httpsJson(`${API}?${q.toString()}`);
  const text = res.raw.toString('utf8');
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    return { ok: false, status: res.status, text };
  }
  if (json.success) return { ok: true, data: json.data };

  const code = json.error && json.error.code;
  if (code === 119 && retry) {
    session.sid = null;
    await sid();
    return dsm(api, params, { retry: false });
  }
  return { ok: false, code, error: json.error };
}

async function dsmDownload(name) {
  const path = `${NAS_FOLDER}/${name}`;
  const s = await sid();
  const q = new URLSearchParams({
    api: 'SYNO.FileStation.Download',
    version: '2',
    method: 'download',
    mode: 'download',
    path,
    _sid: s,
  });
  const res = await httpsJson(`${API}?${q.toString()}`);

  const text = res.raw.toString('utf8');

  // DSM answers 502 with an HTML error page when the file *or the containing
  // folder* does not exist yet. That is the normal first-run condition, not a
  // failure: the first push creates the folder (create_parents=true). Treating
  // it as "missing" is what makes a brand-new account work on the first try.
  const looksHtml = /^\s*<(!doctype|html)/i.test(text);
  if (res.status !== 200 || looksHtml) {
    return { ok: true, missing: true };
  }

  const trimmed = text.trim();

  // A JSON error blob instead of file content means "cannot serve this".
  if (trimmed.startsWith('{') && trimmed.includes('"success":false')) {
    try {
      const j = JSON.parse(trimmed);
      const code = j.error && j.error.code;
      if (code === 119) {
        session.sid = null;
        return dsmDownload(name);
      }
      if (code === 408 || code === 900) return { ok: true, missing: true };
      return { ok: false, code };
    } catch {
      /* not JSON after all: fall through and treat as content */
    }
  }
  return { ok: true, text: trimmed };
}

async function dsmUpload(name, text) {
  const s = await sid();
  const boundary = '----june' + crypto.randomBytes(8).toString('hex');
  const head = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="path"\r\n\r\n${NAS_FOLDER}\r\n` +
      `--${boundary}\r\nContent-Disposition: form-data; name="create_parents"\r\n\r\ntrue\r\n` +
      `--${boundary}\r\nContent-Disposition: form-data; name="overwrite"\r\n\r\ntrue\r\n` +
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${name}"\r\n` +
      `Content-Type: application/json\r\n\r\n`
  );
  const body = Buffer.concat([
    head,
    Buffer.from(text, 'utf8'),
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const q = new URLSearchParams({
    api: 'SYNO.FileStation.Upload',
    version: '2',
    method: 'upload',
    _sid: s,
  });
  const res = await httpsJson(`${API}?${q.toString()}`, {
    method: 'POST',
    headers: {
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
      'Content-Length': body.length,
    },
    body,
  });
  let json;
  try {
    json = JSON.parse(res.raw.toString('utf8'));
  } catch {
    return { ok: false, status: res.status };
  }
  if (json.success) return { ok: true };
  if (json.error && json.error.code === 119) {
    session.sid = null;
    return dsmUpload(name, text);
  }
  return { ok: false, code: json.error && json.error.code };
}

// ---------------- local storage driver -----------------

/** Writes are small and rare; a millisecond is not worth an fsync per write. */
function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, file); // rename is atomic on the same filesystem
}

async function localDownload(name) {
  const file = path.join(DATA_DIR, name);
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return { ok: true, missing: true };
    return { ok: false, code: e.code };
  }
  return { ok: true, text: text.trim() };
}

async function localUpload(name, text) {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    writeAtomic(path.join(DATA_DIR, name), text);
    return { ok: true };
  } catch (e) {
    return { ok: false, code: e.code };
  }
}

// ---------------- storage façade -----------------

/**
 * The only two calls the rest of the server makes. Picking the driver once at
 * startup keeps every request path free of `if (storage === …)` branches — the
 * merge, cache, and long-poll code is identical whichever disk is behind it.
 */
const download = STORAGE === 'local' ? localDownload : dsmDownload;
const upload = STORAGE === 'local' ? localUpload : dsmUpload;

/** Human-readable storage description for /health, the banner, and selftest. */
const STORAGE_LABEL =
  STORAGE === 'local' ? `local(${DATA_DIR})` : `dsm(${NAS_HOST}:${NAS_PORT}${NAS_FOLDER})`;

// ---------------- Cache & coalescing ----------------

/**
 * workspace id → { rev, entities, at }
 *
 * Read-through with a short TTL. The point is not durability (the NAS is the
 * durable copy) but that opening the app twice, or five widgets asking at once,
 * does not become five downloads.
 */
const cache = new Map();
/** workspace id → Promise, so concurrent reads share one download. */
const inflight = new Map();

function cacheGet(ws) {
  const hit = cache.get(ws);
  if (!hit) return null;
  if (Date.now() - hit.at > CACHE_MS) return null;
  return hit;
}

function cachePut(ws, doc) {
  cache.set(ws, { ...doc, at: Date.now() });
  // A tiny LRU guard: this is a personal scheduler, not a data warehouse.
  if (cache.size > 200) cache.delete(cache.keys().next().value);
}

function cacheDrop(ws) {
  cache.delete(ws);
}

async function loadDoc(ws) {
  const cached = cacheGet(ws);
  if (cached) return cached;

  if (inflight.has(ws)) return inflight.get(ws);

  const p = (async () => {
    const res = await download(`${ws}.json`);
    if (!res.ok) throw new Error(`nas read failed (${res.code || res.status})`);
    if (res.missing) {
      const empty = { rev: 0, gen: 0, entities: {} };
      cachePut(ws, empty);
      return empty;
    }
    let doc;
    try {
      doc = JSON.parse(res.text);
    } catch {
      throw new Error('nas read: invalid json');
    }
    const out = {
      rev: Number(doc.rev) || 0,
      // `gen` is absent in documents written by older builds; 0 is the right
      // default because it never triggers a false "the server was reset".
      gen: Number(doc.gen) || 0,
      entities: doc.entities && typeof doc.entities === 'object' ? doc.entities : {},
    };
    cachePut(ws, out);
    return out;
  })().finally(() => inflight.delete(ws));

  inflight.set(ws, p);
  return p;
}

/** last-writer-wins on `updatedAt`, exactly like the direct server. */
function mergeEntities(base, incoming) {
  const out = { ...base };
  for (const [k, rec] of Object.entries(incoming || {})) {
    if (!rec || typeof rec !== 'object') continue;
    const mine = Number(rec.updatedAt) || 0;
    const theirs = Number((out[k] || {}).updatedAt) || 0;
    if (!out[k] || mine >= theirs) out[k] = rec;
  }
  return out;
}

// ---------------- Long-poll waiters ----------------
//
// One entry per parked `/api/state?wait=…` request. Every write and reset for
// that workspace flushes them immediately, which is what turns "poll every 2
// seconds" into "answer the moment it changes".

/** workspace id → Set<() => void> */
const waiters = new Map();

function parkWaiter(ws, finish) {
  let set = waiters.get(ws);
  if (!set) {
    set = new Set();
    waiters.set(ws, set);
  }
  set.add(finish);
  return () => {
    set.delete(finish);
    if (set.size === 0) waiters.delete(ws);
  };
}

function wakeWaiters(ws) {
  const set = waiters.get(ws);
  if (!set) return;
  waiters.delete(ws);
  for (const fn of set) {
    try {
      fn();
    } catch {
      /* a dead socket must not stop the others */
    }
  }
}

// ---------------- HTTP surface ----------------

function cors(req, res) {
  // Echo the caller's origin back only when it is on the allow-list.
  //
  // ## Why not `*`
  // This gateway authenticates with the `X-Sync-Key` header rather than a
  // cookie, so the usual "a wildcard cannot use credentials" argument does not
  // protect it: any page could call the gateway and read the answer. Echoing a
  // specific allowed origin gives the same "callable from our own site" result
  // without handing that ability to every site in the world.
  //
  // `Vary: Origin` matters because the response now depends on the Origin
  // header; without it a shared cache can serve one origin's answer to another.
  const origin = req && req.headers ? req.headers.origin : '';
  if (origin && CORS_ORIGINS.includes(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Credentials', 'false');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Sync-Key');
  res.setHeader('Access-Control-Max-Age', '86400');
  res.setHeader('Cache-Control', 'no-store');
}

/**
 * Sends a JSON answer, gzipping anything big enough to be worth it.
 *
 * A workspace document with a year of tasks is tens of kilobytes of very
 * repetitive JSON; gzip takes it to a fraction of that. Below ~1 KB the header
 * overhead is not worth it, hence the threshold.
 */
function send(res, status, obj, req) {
  const raw = Buffer.from(JSON.stringify(obj), 'utf8');
  const acceptsGzip =
    req && /\bgzip\b/.test(String(req.headers['accept-encoding'] || ''));

  if (acceptsGzip && raw.length > 1024) {
    const gz = zlib.gzipSync(raw, { level: 6 });
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Encoding': 'gzip',
      Vary: 'Accept-Encoding',
      'Content-Length': gz.length,
    });
    res.end(gz);
    return;
  }

  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': raw.length,
  });
  res.end(raw);
}

/**
 * How many requests arrived with the *retired* key during a rotation.
 *
 * The only reliable way to know the cache has drained. `SYNC_SECRET_PREVIOUS`
 * is supposed to be removed when this stops moving — without it there is no
 * signal, and "wait a few days" is a guess.
 */
let previousKeyHits = 0;

/**
 * Constant-time comparison of two strings of possibly different length.
 *
 * ## Why this is not just `===`
 * A byte-by-byte compare that returns on the first mismatch leaks, through its
 * running time, how much of the guess was right. The key is 64 hex characters,
 * so an attacker who can time the endpoint can recover it one nibble at a time.
 * `crypto.timingSafeEqual` cannot be given unequal-length buffers (it throws),
 * so equalising the length first is not a nicety — it is what makes the call
 * legal. Comparing the SHA-256 of each side keeps the work independent of where
 * the inputs differ.
 */
function keyEquals(got, want) {
  if (typeof got !== 'string' || typeof want !== 'string' || !want) return false;
  const a = crypto.createHash('sha256').update(got, 'utf8').digest();
  const b = crypto.createHash('sha256').update(want, 'utf8').digest();
  return crypto.timingSafeEqual(a, b);
}

function authorized(req) {
  // No configured key ⇒ open. Only ever appropriate on loopback, and `/readyz`
  // says so out loud (`reason: "auth"`) if someone exposes it anyway.
  if (ACCEPTED_KEYS.length === 0) return true;

  const got = req.headers['x-sync-key'];
  const supplied = typeof got === 'string' ? got : '';

  // Check *all* keys rather than stopping at the first match: returning early
  // would make the current and previous keys take measurably different time.
  let ok = false;
  for (const key of ACCEPTED_KEYS) {
    if (keyEquals(supplied, key)) ok = true;
  }
  if (!ok) return false;

  // Count use of the retired key so the operator knows when to drop it.
  if (SYNC_SECRET_PREVIOUS && keyEquals(supplied, SYNC_SECRET_PREVIOUS)) {
    previousKeyHits += 1;
  }
  return true;
}

const hits = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const slot = hits.get(ip) || { n: 0, t: now };
  if (now - slot.t > 1000) {
    slot.n = 0;
    slot.t = now;
  }
  slot.n += 1;
  hits.set(ip, slot);
  return slot.n > 200;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Reachability vs. readiness
// ---------------------------------------------------------------------------

/**
 * Cheap "is the backend there?" probe — what `/health` answers.
 *
 * ## Why this is not the readiness check
 * `/health` is polled often and is published as frozen JSON on GitHub Pages, so
 * it has to stay a single fast question. Under `local` we therefore only look at
 * the data directory; under `dsm` we reuse the cached session. Neither branch
 * writes anything.
 *
 * Every branch is **mode-specific by construction**: under `local` we never call
 * the DSM API, under `dsm` we never touch the local disk. `STORAGE=local` must
 * not report itself down because a NAS somewhere else is unreachable.
 */
async function reachable() {
  if (STORAGE === 'local') {
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      fs.accessSync(DATA_DIR, fs.constants.W_OK);
      return true;
    } catch {
      return false;
    }
  }
  try {
    return (await sid()) != null;
  } catch {
    return false;
  }
}

/** How long a readiness verdict may be reused.
 *
 * A probe running every second must not cost a NAS login or a disk write every
 * second, so the verdict is memoised for a few seconds. Kept short (5 s) on
 * purpose: a stale "ready" is exactly the state that keeps a broken node in a
 * load balancer's rotation. */
const READY_CACHE_MS = Number(process.env.READY_CACHE_MS || 5000);

let readyCache = null;
let readyAt = 0;

/**
 * Can the filesystem behind `STORAGE=local` actually accept a write?
 *
 * A directory that merely *looks* writable is not the same as a writable
 * filesystem: `W_OK` can succeed on a read-only remount, a full volume, or a
 * quota-exhausted share, and the failure then lands on the user's next save
 * instead of on the probe. So we write one scratch file, read it back, and
 * delete it.
 *
 * The leading dot keeps it out of the workspace filename grammar (`FILE_RE`
 * requires the name to start with `[A-Za-z0-9_-]`), so the probe file can never
 * be mistaken for — or enumerated as — somebody's data.
 */
function writableProbe() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    const probe = path.join(DATA_DIR, '.readyz.tmp');
    const token = `${process.pid}-${Date.now()}`;
    fs.writeFileSync(probe, token, { mode: 0o600 });
    const back = fs.readFileSync(probe, 'utf8');
    fs.unlinkSync(probe);
    return back === token;
  } catch {
    return false;
  }
}

/**
 * The `/readyz` verdict: `{ready}` or `{ready:false, reason}`.
 *
 * Reason is one of three coarse tokens — `config`, `auth`, `storage` — never a
 * path, host or credential. A probe log stays useful without turning into a map
 * of the machine.
 */
async function readiness() {
  const now = Date.now();
  if (readyCache && now - readyAt < READY_CACHE_MS) return readyCache;

  let verdict;
  // 1. settings this process cannot run without
  if (STORAGE !== 'local' && STORAGE !== 'dsm') {
    verdict = { ready: false, reason: 'config' };
  } else if (!Number.isFinite(PORT) || PORT <= 0) {
    verdict = { ready: false, reason: 'config' };
  } else if (STORAGE === 'dsm' && (!NAS_HOST || !NAS_USER || !NAS_PASS)) {
    verdict = { ready: false, reason: 'config' };
  } else if (STORAGE === 'dsm' && !NAS_FOLDER.startsWith('/')) {
    verdict = { ready: false, reason: 'config' };
  } else if (STORAGE === 'dsm' && !(Number.isFinite(NAS_PORT) && NAS_PORT > 0)) {
    verdict = { ready: false, reason: 'config' };
    // 2. authentication shape — a key is mandatory the moment we leave loopback
  } else {
    const onLoopback = HOST === '127.0.0.1' || HOST === '::1' || HOST === 'localhost';
    if (!onLoopback && ACCEPTED_KEYS.length === 0) {
      verdict = { ready: false, reason: 'auth' };
    } else if (ACCEPTED_KEYS.some((k) => k.length < 16)) {
      // A short key in *either* slot is a misconfiguration, not a grace period:
      // the retired key is still a door while it is accepted.
      verdict = { ready: false, reason: 'auth' };
      // 3. the dependency the *current* storage mode needs — and only it
    } else {
      const ok = STORAGE === 'local' ? writableProbe() : (await reachable());
      verdict = ok ? { ready: true } : { ready: false, reason: 'storage' };
    }
  }

  readyCache = verdict;
  readyAt = now;
  return verdict;
}

const server = http.createServer(async (req, res) => {
  cors(req, res);

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const ip = req.socket.remoteAddress || '?';
  if (rateLimited(ip)) return send(res, 429, { error: 'rate limited' }, req);

  const url = new URL(req.url, 'http://localhost');
  let path = url.pathname;
  if (BASE_PATH && path.startsWith(BASE_PATH)) {
    path = path.slice(BASE_PATH.length) || '/';
  }

  // --- liveness. Deliberately says nothing sensitive: it is published as
  // static JSON so the web app can decide "NAS or local" before first paint.
  if (path === '/health') {
    // `reachable()` picks the probe that matches the storage mode, so a local
    // deployment never asks the NAS and vice versa.
    const up = await reachable();
    // ## What may appear in this answer
    // `/health` is unauthenticated by design — it is the credential-free
    // up/down bit the web app reads before first paint. That means everything
    // here is world-readable, so it carries only what the *client* needs:
    //
    //   service — the client uses this to tell "our gateway" from DSM's own
    //             login page answering 200 on the same host. Removing it would
    //             break that check.
    //   nas     — the client maps `nas:false` to "storage down". The name is a
    //             historical artefact; under STORAGE=local it means "the data
    //             directory is writable", which is what a push needs anyway.
    //
    // `storage` and `time` were removed: `storage` described internal
    // configuration (useful to someone probing, not to a client that never
    // reads it — verified: no client code touches `body['storage']`), and
    // `time` served nothing. Availability belongs on `/readyz`, which is allowed
    // to say 503; this endpoint stays a single cheap "is it there" bit.
    return send(
      res,
      200,
      {
        ok: true,
        service: 'june-nas-gateway',
        nas: up,
      },
      req
    );
  }

  // -------------------------------------------------------------------------
  // `/readyz` — "may I take traffic right now?"  //
  // Deliberately NOT folded into `/health`. `/health` answers "is the process
  // alive" and is *published as static JSON* for first-paint decisions; a
  // storage probe inside it would make that frozen copy lie in one direction or
  // the other. `/readyz` answers the question a reverse proxy asks before it
  // forwards a user here, so it is allowed to say 503.
  //
  // Unauthenticated on purpose: the thing asking is Nginx or a container probe,
  // and it has no `X-Sync-Key`. That is safe because the answer carries no data
  // and no topology — see `readiness()` for why the reason is a 3-word enum.
  //
  // What it never does, per the coordination spec:
  //   * no workspace enumeration — that is an O(n) NAS round trip, and this is
  //     probed every few seconds
  //   * no mutation of user data — the writability check is one dot-prefixed
  //     scratch file the workspace grammar cannot match
  //   * no detailed paths, hosts, or credentials in the reply
  //
  //   ready    → 200 {"ready":true}
  //   not yet  → 503 {"ready":false,"reason":"config|auth|storage"}
  //
  // `Cache-Control: no-store` is already applied to every reply by `cors()`.
  if (path === '/readyz') {
    const verdict = await readiness();
    return send(res, verdict.ready ? 200 : 503, verdict, req);
  }

  if (!authorized(req)) return send(res, 401, { error: 'bad key' }, req);

  try {
    // --- read: one small file, optionally parked until something changes
    if (path === '/api/state' && req.method === 'GET') {
      const ws = url.searchParams.get('ws') || '';
      const wantRev = Number(url.searchParams.get('rev') || 0);
      const wantGen = Number(url.searchParams.get('gen') || 0);
      const waitMs = Math.min(
        Math.max(Number(url.searchParams.get('wait') || 0) || 0, 0) * 1000,
        MAX_WAIT_MS
      );
      if (!WS_RE.test(ws)) return send(res, 400, { error: 'bad ws' }, req);

      const doc = await loadDoc(ws);

      // Generation mismatch means the user wiped the workspace from another
      // device. Answer immediately with the empty document — never park, or the
      // client would sit on stale data for a whole wait cycle.
      const genStale = wantGen > 0 && doc.gen !== wantGen;

      // Already current: either answer now, or park until a write wakes us.
      if (!genStale && wantRev > 0 && doc.rev === wantRev) {
        if (waitMs <= 0) {
          return send(
            res,
            200,
            { exists: true, unchanged: true, rev: doc.rev, gen: doc.gen },
            req
          );
        }

        let done = false;
        const finish = () => {
          if (done) return;
          done = true;
          unpark();
          clearTimeout(timer);
          if (res.writableEnded) return;
          // Re-read: the change that woke us is what the client wants.
          loadDoc(ws)
            .then((fresh) => {
              const count = Object.keys(fresh.entities).length;
              send(
                res,
                200,
                {
                  exists: count > 0,
                  rev: fresh.rev,
                  gen: fresh.gen,
                  entities: fresh.entities,
                },
                req
              );
            })
            .catch(() => send(res, 502, { error: 'nas read failed' }, req));
        };

        const timer = setTimeout(finish, waitMs);
        const unpark = parkWaiter(ws, finish);
        // A client that hangs up must not leave a waiter behind.
        req.on('close', () => {
          done = true;
          unpark();
          clearTimeout(timer);
        });
        return;
      }

      const count = Object.keys(doc.entities).length;
      return send(
        res,
        200,
        {
          exists: count > 0,
          rev: doc.rev,
          gen: doc.gen,
          entities: doc.entities,
        },
        req
      );
    }

    // --- write: merge, bump rev, persist, return the echo
    if (path === '/api/push' && req.method === 'POST') {
      const raw = await readBody(req);
      let payload;
      try {
        payload = JSON.parse(raw);
      } catch {
        return send(res, 400, { error: 'bad json' }, req);
      }
      const ws = String(payload.ws || '');
      if (!WS_RE.test(ws)) return send(res, 400, { error: 'bad ws' }, req);
      if (!FILE_RE.test(`${ws}.json`)) return send(res, 400, { error: 'bad ws' }, req);

      const before = await loadDoc(ws);
      const incoming = payload.entities;
      const merged = mergeEntities(before.entities, incoming);

      // Echo only what the merge actually accepted at (or above) the version we
      // were sent. A record that lost the merge is absent, so the client keeps
      // it queued instead of pretending the save worked.
      //
      // For the losers we ship the winning record itself. Conflicts are rare
      // (the same record edited on two devices at once), and healing them inside
      // this same answer is what keeps the common case at ONE round trip while
      // still resolving the rare case without a follow-up read.
      const echo = {};
      const lost = {};
      for (const [k, rec] of Object.entries(incoming || {})) {
        if (!rec || typeof rec !== 'object') continue;
        const held = merged[k];
        if (!held) continue;
        if (held === rec) {
          echo[k] = Number(rec.updatedAt) || 0;
        } else {
          lost[k] = held;
        }
      }

      const next = { rev: before.rev + 1, gen: before.gen, entities: merged };

      const put = await upload(`${ws}.json`, JSON.stringify(next));
      if (!put.ok) {
        cacheDrop(ws);
        return send(res, 502, { error: 'nas write failed', code: put.code }, req);
      }
      cachePut(ws, next);
      // Wake every other device parked on this workspace.
      wakeWaiters(ws);
      return send(
        res,
        200,
        {
          ok: true,
          rev: next.rev,
          gen: next.gen,
          count: Object.keys(merged).length,
          echo,
          lost,
        },
        req
      );
    }

    // --- wipe: empty the workspace and bump its generation
    if (path === '/api/reset' && req.method === 'POST') {
      const raw = await readBody(req);
      let payload = {};
      try {
        payload = JSON.parse(raw);
      } catch {
        /* ignore */
      }
      const ws = String(payload.ws || '');
      if (!WS_RE.test(ws)) return send(res, 400, { error: 'bad ws' }, req);

      const before = await loadDoc(ws);
      const next = { rev: before.rev + 1, gen: before.gen + 1, entities: {} };
      const put = await upload(`${ws}.json`, JSON.stringify(next));
      if (!put.ok) {
        cacheDrop(ws);
        return send(res, 502, { error: 'nas write failed', code: put.code }, req);
      }
      cachePut(ws, next);
      wakeWaiters(ws);
      return send(res, 200, { ok: true, rev: next.rev, gen: next.gen, count: 0 }, req);
    }

    // --- explicit revalidate (used after another device says it wrote)
    if (path === '/api/drop' && req.method === 'POST') {
      const raw = await readBody(req);
      let payload = {};
      try {
        payload = JSON.parse(raw);
      } catch {
        /* ignore */
      }
      if (payload.ws && WS_RE.test(payload.ws)) {
        cacheDrop(payload.ws);
        wakeWaiters(payload.ws);
      } else {
        cache.clear();
      }
      return send(res, 200, { ok: true }, req);
    }

    send(res, 404, { error: 'not found' }, req);
  } catch (e) {
    console.error('[gateway]', e.message);
    send(res, 500, { error: String(e.message || e) }, req);
  }
});

// ---------------- Startup self-check ----------------

/**
 * `node server.js --selftest` talks to the NAS once and prints what it found.
 *
 * Meant to be run over SSH right after installing, before touching the app: it
 * separates "the NAS credentials are wrong" from "the reverse proxy is wrong"
 * from "the app is wrong", which are otherwise indistinguishable from a browser.
 */
async function selftest() {
  const line = (ok, label, extra = '') =>
    console.log(`${ok ? '  OK  ' : ' FAIL '} ${label}${extra ? ` — ${extra}` : ''}`);

  console.log('\n[june-gateway] self-test\n');
  line(true, 'storage', STORAGE_LABEL);
  line(
    ACCEPTED_KEYS.length > 0,
    'auth',
    ACCEPTED_KEYS.length === 0
      ? 'OPEN (LAN only!)'
      : SYNC_SECRET_PREVIOUS
        ? 'current + previous key accepted (rotation in progress)'
        : 'shared key required'
  );

  if (STORAGE === 'dsm') {
    try {
      const s = await sid();
      line(!!s, 'DSM login', 'session established');
    } catch (e) {
      line(false, 'DSM login', e.message);
      console.log('\n  → NAS_USER / NAS_PASS 확인, NAS_PORT=5001 인지 확인\n');
      process.exit(1);
    }
  }

  const probe = 'ACCSELFTEST000000000000000';

  try {
    const down = await download(`${probe}.json`);
    line(
      down.ok,
      'download',
      down.missing ? 'nothing stored yet (normal)' : 'readable'
    );
  } catch (e) {
    line(false, 'download', e.message);
  }

  try {
    const up = await upload(
      `${probe}.json`,
      JSON.stringify({ rev: 0, gen: 0, entities: {} })
    );
    line(up.ok, 'upload', up.ok ? 'write + folder creation works' : `code ${up.code}`);
    if (up.ok) {
      if (STORAGE === 'local') {
        fs.unlinkSync(path.join(DATA_DIR, `${probe}.json`));
      } else {
        await dsm('SYNO.FileStation.Delete', {
          version: '2',
          method: 'delete',
          path: `${NAS_FOLDER}/${probe}.json`,
        });
      }
    }
  } catch (e) {
    line(false, 'upload', e.message);
  }

  console.log(`\n  저장 위치: ${STORAGE_LABEL}`);
  console.log('  결과가 모두 OK 면 게이트웨이는 저장소와 정상 통신합니다.');
  console.log('  이제 브라우저에서 /health 를 열어 프록시까지 확인하세요.\n');
  process.exit(0);
}

if (process.argv.includes('--selftest')) {
  selftest();
} else {
  server.listen(PORT, HOST, () => {
    // Say the interface out loud. "listening on :8097" hid the fact that it
    // was 0.0.0.0, and that is precisely how a gateway ends up published.
    console.log(`[june-gateway] listening on ${HOST}:${PORT}`);
    console.log(`[june-gateway] storage=${STORAGE_LABEL}`);
    console.log(
      `[june-gateway] auth=${
        ACCEPTED_KEYS.length === 0 ? 'OPEN (loopback only!)' : 'key required'
      }`
    );
    if (SYNC_SECRET_PREVIOUS) {
      // Rotation in progress. Say so, and say the *order*, because the easy
      // mistake is to publish the new bundle first and drop the old key last
      // (which is right) — or the reverse (which is an outage).
      console.log(
        '[june-gateway] rotation=on — the previous key is still accepted. ' +
          'Publish a bundle built with the new key, let the cache drain, then ' +
          'remove SYNC_SECRET_PREVIOUS. The log reports retired-key hits every ' +
          '60 s; when that sits at 0, the cache has drained.'
      );

      // The only reliable "is it safe to drop the old key yet?" signal. It goes
      // to the log rather than `/readyz` on purpose: `/readyz` is public and its
      // reply is a contract ({"ready":true}); a request counter is neither.
      let lastReported = -1;
      setInterval(() => {
        if (previousKeyHits !== lastReported) {
          lastReported = previousKeyHits;
          console.log(
            `[june-gateway] retiredKeyHits=${previousKeyHits} — ` +
              (previousKeyHits === 0
                ? 'no client is using the old key; safe to remove SYNC_SECRET_PREVIOUS'
                : 'clients still on a cached bundle; do NOT remove the old key yet')
          );
        }
      }, 60000).unref();
    }
    console.log(
      `[june-gateway] cors=${CORS_ORIGINS.length ? CORS_ORIGINS.join(' , ') : 'same-origin only'}`
    );
    if (HOST === '0.0.0.0' || HOST === '::') {
      console.warn(
        '[june-gateway] WARNING: bound to every interface. Only do this behind a ' +
          'firewall or a reverse proxy that you control.'
      );
    }
    if (ACCEPTED_KEYS.length === 0 && HOST !== '127.0.0.1' && HOST !== '::1' && HOST !== 'localhost') {
      console.warn(
        '[june-gateway] WARNING: no SYNC_SECRET and listening beyond loopback — ' +
          'anyone who can reach this port can read and write every workspace.'
      );
    }
  });

  process.on('SIGTERM', () => {
    server.close(() => process.exit(0));
  });
}
