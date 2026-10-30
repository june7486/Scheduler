#!/usr/bin/env node
/**
 * June's Scheduler — NAS sync server.
 *
 * A complete, dependency-free sync API that runs on your own NAS (Synology,
 * QNAP, TrueNAS, a Raspberry Pi — anything that runs Node 18+ or Docker).
 *
 *   GET  /health                       liveness probe
 *   GET  /api/state?ws=<id>&rev=<n>    full document, or {unchanged:true}
 *   POST /api/push                     merge entities (last-writer-wins)
 *   OPTIONS *                          CORS preflight
 *
 * Design notes
 * ------------
 * * Storage is one JSON file per workspace, written atomically (tmp + rename).
 *   A personal scheduler is tiny; SQLite would add a dependency for no gain.
 * * Merge is last-writer-wins on `updatedAt`. Deletions arrive as tombstones
 *   (`deletedAt`), so they win by being newer — never by disappearing.
 * * No polling limits: this is your hardware, so the client may ask as often
 *   as it likes. That is the whole reason this beats a hosted pub/sub service.
 */
'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');

const PORT = Number(process.env.PORT || 8099);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const API_KEY = (process.env.SYNC_SECRET || '').trim();

// Workspace ids are derived (hashed) in the app; keep the path safe anyway.
const WS_RE = /^[A-Za-z0-9_-]{6,64}$/;

fs.mkdirSync(DATA_DIR, { recursive: true });

const MAX_BODY = 8 * 1024 * 1024; // 8 MB: a decade of tasks is far below this

function wsFile(ws) {
  return path.join(DATA_DIR, `${ws}.json`);
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Sync-Key',
    'Access-Control-Max-Age': '86400',
    'Cache-Control': 'no-store',
  };
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    ...corsHeaders(),
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

async function readDoc(ws) {
  try {
    const raw = await fsp.readFile(wsFile(ws), 'utf8');
    const data = JSON.parse(raw);
    return {
      rev: Number(data.rev) || 0,
      entities: data.entities && typeof data.entities === 'object' ? data.entities : {},
    };
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
}

async function writeDoc(ws, doc) {
  const file = wsFile(ws);
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  const payload = JSON.stringify({
    rev: doc.rev,
    entities: doc.entities,
    updatedAt: new Date().toISOString(),
  });
  // Atomic replace: a crash mid-write must never leave a truncated document.
  await fsp.writeFile(tmp, payload, 'utf8');
  await fsp.rename(tmp, file);
}

/** Last-writer-wins per record, keyed by updatedAt. */
function mergeEntities(base, incoming) {
  const merged = { ...base };
  for (const [key, rec] of Object.entries(incoming || {})) {
    if (!rec || typeof rec !== 'object') continue;
    const mine = Number(rec.updatedAt) || 0;
    const theirs = merged[key] && typeof merged[key] === 'object'
      ? Number(merged[key].updatedAt) || 0
      : -1;
    if (mine >= theirs) merged[key] = rec;
  }
  return merged;
}

function authorized(req) {
  if (!API_KEY) return true; // open LAN mode
  const got = req.headers['x-sync-key'];
  if (typeof got !== 'string' || got.length !== API_KEY.length) return false;
  return crypto.timingSafeEqual(Buffer.from(got), Buffer.from(API_KEY));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// Cheap per-IP guard so a buggy client cannot hammer the disk.
const hits = new Map();
function allowed(ip) {
  const now = Date.now();
  const rec = hits.get(ip) || { count: 0, reset: now + 1000 };
  if (now > rec.reset) {
    rec.count = 0;
    rec.reset = now + 1000;
  }
  rec.count += 1;
  hits.set(ip, rec);
  return rec.count <= 200; // 200 req/s per IP is generous for a scheduler
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const ip = req.socket.remoteAddress || 'unknown';

  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders());
    res.end();
    return;
  }

  try {
    if (!allowed(ip)) return send(res, 429, { error: 'slow down' });

    if (url.pathname === '/health') {
      return send(res, 200, { ok: true, service: 'june-sync', time: Date.now() });
    }

    if (!authorized(req)) return send(res, 401, { error: 'bad key' });

    if (url.pathname === '/api/state' && req.method === 'GET') {
      const ws = url.searchParams.get('ws') || '';
      if (!WS_RE.test(ws)) return send(res, 400, { error: 'bad workspace' });
      const since = Number(url.searchParams.get('rev') || 0);
      const doc = await readDoc(ws);
      if (!doc) return send(res, 200, { exists: false, rev: 0, entities: {} });
      if (since && since === doc.rev) {
        return send(res, 200, { exists: true, unchanged: true, rev: doc.rev });
      }
      return send(res, 200, { exists: true, rev: doc.rev, entities: doc.entities });
    }

    if (url.pathname === '/api/push' && req.method === 'POST') {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        return send(res, 400, { error: 'bad json' });
      }
      const ws = String(body.ws || '');
      if (!WS_RE.test(ws)) return send(res, 400, { error: 'bad workspace' });
      const current = (await readDoc(ws)) || { rev: 0, entities: {} };
      const merged = mergeEntities(current.entities, body.entities);
      const next = { rev: current.rev + 1, entities: merged };
      await writeDoc(ws, next);
      return send(res, 200, { ok: true, rev: next.rev, count: Object.keys(merged).length });
    }

    return send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error('[june-sync]', e);
    return send(res, 500, { error: String(e && e.message ? e.message : e) });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[june-sync] listening on :${PORT}`);
  console.log(`[june-sync] data dir: ${DATA_DIR}`);
  console.log(`[june-sync] auth: ${API_KEY ? 'shared key required' : 'OPEN (LAN only!)'}`);
});
