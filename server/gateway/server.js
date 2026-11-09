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

/** Data directory for `STORAGE=local`. */
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

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
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

function authorized(req) {
  if (!SYNC_SECRET) return true;
  const got = req.headers['x-sync-key'] || '';
  const a = Buffer.from(got);
  const b = Buffer.from(SYNC_SECRET);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
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

const server = http.createServer(async (req, res) => {
  cors(res);

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
    // With local storage there is no session to check, so "reachable" is simply
    // "the data directory is writable" — the same thing the next push needs.
    let up;
    if (STORAGE === 'local') {
      try {
        fs.mkdirSync(DATA_DIR, { recursive: true });
        fs.accessSync(DATA_DIR, fs.constants.W_OK);
        up = true;
      } catch {
        up = false;
      }
    } else {
      try {
        up = (await sid()) != null;
      } catch {
        up = false;
      }
    }
    return send(
      res,
      200,
      {
        ok: true,
        service: 'june-nas-gateway',
        storage: STORAGE,
        nas: up,
        time: Date.now(),
      },
      req
    );
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
  line(true, 'auth', SYNC_SECRET ? 'shared key required' : 'OPEN (LAN only!)');

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
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`[june-gateway] listening on :${PORT}`);
    console.log(`[june-gateway] storage=${STORAGE_LABEL}`);
    console.log(`[june-gateway] auth=${SYNC_SECRET ? 'key required' : 'OPEN'}`);
  });

  process.on('SIGTERM', () => {
    server.close(() => process.exit(0));
  });
}
