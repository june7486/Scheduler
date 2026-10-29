/**
 * June Scheduler sync relay — Cloudflare Worker (single file, KV-backed).
 *
 * Deploy:
 *   wrangler kv namespace create JUNE_SYNC
 *   wrangler deploy sync-worker.js --name june-sync
 *   # then set SYNC_URL (see lib/services/sync_service.dart) to the worker URL
 *
 * API
 *   GET  /state?code=CODE&owner=UID  -> {rev, entities:{key:record}, t}
 *   POST /push  {code, owner, baseRev, entities, stamps} -> {rev, entities}
 *
 * Merge rule: last-writer-wins on each record's `updatedAt` (epoch ms).
 * Deletions arrive as records with a non-null `deletedAt` (tombstones).
 */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
  });

export default {
  async fetch(req, env) {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    const url = new URL(req.url);

    try {
      if (req.method === 'GET' && url.pathname === '/state') {
        const code = (url.searchParams.get('code') || '').toUpperCase();
        if (!code) return json({ error: 'code required' }, 400);
        const doc = (await env.JUNE_SYNC.get(`w:${code}`, 'json')) || { rev: 0, entities: {}, t: 0 };
        return json(doc);
      }

      if (req.method === 'POST' && url.pathname === '/push') {
        const body = await req.json();
        const code = (body.code || '').toUpperCase();
        if (!code) return json({ error: 'code required' }, 400);

        const key = `w:${code}`;
        const cur = (await env.JUNE_SYNC.get(key, 'json')) || { rev: 0, entities: {}, t: 0 };
        const incoming = body.entities || {};
        let changed = false;

        for (const [k, rec] of Object.entries(incoming)) {
          if (!rec || typeof rec !== 'object') continue;
          const remoteStamp = Number(rec.updatedAt) || 0;
          const local = cur.entities[k];
          const localStamp = local ? Number(local.updatedAt) || 0 : -1;
          if (remoteStamp >= localStamp) {
            cur.entities[k] = rec;
            changed = true;
          }
        }

        if (changed) {
          cur.rev = (cur.rev || 0) + 1;
          cur.t = Date.now();
          await env.JUNE_SYNC.put(key, JSON.stringify(cur));
        }
        return json(cur);
      }

      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },
};
