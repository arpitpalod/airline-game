// Local stand-in for the parts of Supabase the app uses, so the app can be tested end to end in a session:
//   /auth/v1/token, /auth/v1/user, /auth/v1/logout   password sign-in with locally signed tokens
//   /auth/v1/signup, /resend, /recover, /verify      sign-up and password reset with 6-digit codes (spec 14.21);
//                                                    no email: GET /__test/code?email=... returns the last code
//   /functions/v1/join                               same checks as supabase/functions/join (the invite code)
//   /functions/v1/consultant                         passed to the real edge function, run under Deno on CONSULTANT_PORT
//                                                    (run_e2e.sh starts it, with claude_stub.mjs in place of Claude)
//   /rest/v1/<table>                                 PostgREST-style reads: select, eq/neq/gt/gte/lt/lte/in/is, order, limit
//   /rest/v1/rpc/<function>                          function calls with named arguments
// Every request runs as the caller's role with request.jwt.claims set, so row-level security applies as in Supabase.
// Usage: node shim.mjs   (after sh start.sh). Prints the anon key the app needs.
import http from 'http';
import crypto from 'crypto';
import pg from 'pg';

pg.types.setTypeParser(1700, Number);   // numeric: PostgREST sends JSON numbers
pg.types.setTypeParser(20, Number);     // bigint
pg.types.setTypeParser(1082, (v) => v); // date: PostgREST sends '3000-01-01'
const pool = new pg.Pool({ host: '/tmp', port: Number(process.env.PGPORT || 54322), user: 'postgres', database: 'postgres', max: 8 });
const SECRET = 'local-test-secret-not-used-anywhere-else';
const PORT = Number(process.env.PORT || 54321);

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function sign(claims) {
  const h = b64({ alg: 'HS256', typ: 'JWT' }), p = b64(claims);
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`;
}
function verify(token) {
  const [h, p, s] = (token || '').split('.');
  if (!s || crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url') !== s) return null;
  const c = JSON.parse(Buffer.from(p, 'base64url').toString());
  return c.exp && c.exp < Date.now() / 1000 ? null : c;
}
const ANON = sign({ role: 'anon', iss: 'local' });
const SERVICE = sign({ role: 'service_role', iss: 'local' });

function session(user) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const u = { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, app_metadata: {}, user_metadata: {},
              created_at: new Date().toISOString() };
  return { access_token: sign({ sub: user.id, role: 'authenticated', email: user.email, exp, aud: 'authenticated' }),
           token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: `rt.${user.id}`, user: u };
}

const codes = new Map();   // email -> { code, type }: what Supabase would email
const newCode = (email, type) => { const code = String(crypto.randomInt(0, 1e6)).padStart(6, '0'); codes.set(email, { code, type }); return code; };
const userJson = (u, identities = true) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email,
  identities: identities ? [{ id: u.id, provider: 'email' }] : [], app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() });

const IDENT = /^[a-z_][a-z0-9_]*$/;
function claimsOf(req) {
  const c = verify((req.headers.authorization || '').replace(/^Bearer /i, '')) || verify(req.headers.apikey);
  return c || { role: 'anon' };
}
async function asCaller(claims, sql, params, readOnly = false) {
  const cl = await pool.connect();
  try {
    await cl.query(readOnly ? 'begin read only' : 'begin');   // PostgREST calls STABLE and IMMUTABLE functions read-only
    if (claims.role !== 'service_role' || claims.sub) await cl.query(`set local role ${claims.role === 'authenticated' ? 'authenticated' : 'anon'}`);
    else await cl.query('set local role service_role');
    await cl.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    const r = await cl.query(sql, params);
    await cl.query('commit');
    return r;
  } catch (e) { await cl.query('rollback').catch(() => {}); throw e; } finally { cl.release(); }
}

function parseList(v) {   // in.(a,"b c",d)
  const inner = v.replace(/^\(/, '').replace(/\)$/, '');
  const out = []; let cur = '', q = false;
  for (const ch of inner) {
    if (ch === '"') q = !q; else if (ch === ',' && !q) { out.push(cur); cur = ''; } else cur += ch;
  }
  if (inner.length) out.push(cur);
  return out;
}

async function restGet(table, url, claims) {
  if (!IDENT.test(table)) throw Object.assign(new Error('bad table'), { status: 400 });
  const sel = url.searchParams.get('select') || '*';
  const cols = sel === '*' ? '*' : sel.split(',').map((c) => {
    if (!IDENT.test(c.trim())) throw Object.assign(new Error(`select not supported by the shim: ${c}`), { status: 400 });
    return `"${c.trim()}"`;
  }).join(', ');
  const where = [], params = [];
  let order = '', limit = '', offset = '';
  for (const [k, v] of url.searchParams) {
    if (k === 'select') continue;
    if (k === 'order') {
      order = ' order by ' + v.split(',').map((o) => {
        const [c, dir, nulls] = o.split('.');
        if (!IDENT.test(c)) throw new Error('bad order');
        return `"${c}" ${dir === 'desc' ? 'desc' : 'asc'}${nulls === 'nullsfirst' ? ' nulls first' : nulls === 'nullslast' ? ' nulls last' : ''}`;
      }).join(', ');
      continue;
    }
    if (k === 'limit') { limit = ` limit ${parseInt(v, 10)}`; continue; }
    if (k === 'offset') { offset = ` offset ${parseInt(v, 10)}`; continue; }
    if (!IDENT.test(k)) throw Object.assign(new Error(`filter not supported by the shim: ${k}`), { status: 400 });
    const dot = v.indexOf('.'); const op = v.slice(0, dot); const val = v.slice(dot + 1);
    const ops = { eq: '=', neq: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=' };
    if (ops[op]) { params.push(val); where.push(`"${k}"::text ${ops[op]} $${params.length}::text`); }
    else if (op === 'in') { params.push(parseList(val)); where.push(`"${k}"::text = any($${params.length}::text[])`); }
    else if (op === 'is') where.push(`"${k}" is ${val === 'null' ? 'null' : val === 'true' ? 'true' : 'false'}`);
    else throw Object.assign(new Error(`operator not supported by the shim: ${op}`), { status: 400 });
  }
  // numeric comparisons as text would be wrong; the app only uses gte/lte on integer day columns, so cast those back
  const sql = `select ${cols} from public."${table}"${where.length ? ' where ' + where.join(' and ') : ''}${order}${limit}${offset}`
    .replace(/"(\w+)"::text (>=|<=|>|<) \$(\d+)::text/g, '"$1" $2 $$$3::numeric');
  return (await asCaller(claims, sql, params)).rows;
}

async function rpc(fn, args, claims) {
  if (!IDENT.test(fn)) throw Object.assign(new Error('bad function'), { status: 400 });
  const meta = (await pool.query(
    `select p.proretset, p.prorettype::regtype::text as rt, p.proargnames, p.proargmodes, p.provolatile,
            coalesce(p.proallargtypes, p.proargtypes::oid[])::regtype[]::text[] as types
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1`, [fn])).rows[0];
  if (!meta) throw Object.assign(new Error(`Could not find the function public.${fn}`), { status: 404, code: 'PGRST202' });
  const params = [], named = [];
  for (const [k, v] of Object.entries(args || {})) {
    if (!IDENT.test(k)) throw new Error('bad argument');
    const i = (meta.proargnames || []).indexOf(k);
    if (i < 0) throw Object.assign(new Error(`Could not find the function public.${fn}(${k})`), { status: 404, code: 'PGRST202' });
    params.push(v !== null && typeof v === 'object' && (!Array.isArray(v) || /json/.test(meta.types[i])) ? JSON.stringify(v) : v);
    named.push(`${k} => $${params.length}::${meta.types[i]}`);
  }
  const call = `public."${fn}"(${named.join(', ')})`;
  const tableLike = meta.proretset || meta.rt === 'record';
  const r = await asCaller(claims, tableLike ? `select * from ${call}` : `select ${call} as r`, params, meta.provolatile !== 'v');
  return tableLike ? r.rows : meta.rt === 'void' ? null : r.rows[0].r;
}

async function body(req) {
  let s = ''; for await (const c of req) s += c; return s ? JSON.parse(s) : {};
}

const server = http.createServer(async (req, res) => {
  const send = (status, obj) => {
    res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
    res.end(obj === undefined ? '' : JSON.stringify(obj));
  };
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', '*');
  res.setHeader('access-control-allow-methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    if (p === '/auth/v1/token') {
      const b = await body(req);
      const g = url.searchParams.get('grant_type');
      const u = g === 'refresh_token'
        ? (await pool.query('select id, email from auth.users where id::text = $1', [String(b.refresh_token || '').slice(3)])).rows[0]
        : (await pool.query('select id, email, confirmed from auth.users where lower(email) = lower($1) and password = $2', [b.email, b.password])).rows[0];
      if (!u) return send(400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
      if (u.confirmed === false) return send(400, { error: 'email_not_confirmed', error_code: 'email_not_confirmed', msg: 'Email not confirmed' });
      return send(200, session(u));
    }
    if (p === '/auth/v1/signup') {
      const b = await body(req);
      const email = String(b.email || '').trim().toLowerCase();
      if (String(b.password || '').length < 8) return send(422, { code: 422, error_code: 'weak_password', msg: 'Password should be at least 8 characters.' });
      const old = (await pool.query('select id, email, confirmed from auth.users where lower(email) = $1', [email])).rows[0];
      if (old && old.confirmed) return send(200, userJson(old, false));   // as Supabase: no email, no identities
      const u = old || (await pool.query('insert into auth.users (email, password, confirmed) values ($1, $2, false) returning id, email', [email, b.password])).rows[0];
      newCode(email, 'signup');
      return send(200, userJson(u));
    }
    if (p === '/auth/v1/resend' || p === '/auth/v1/recover') {
      const b = await body(req);
      const email = String(b.email || '').trim().toLowerCase();
      const u = (await pool.query('select confirmed from auth.users where lower(email) = $1', [email])).rows[0];
      if (u && p === '/auth/v1/resend' && !u.confirmed) newCode(email, 'signup');
      if (u && p === '/auth/v1/recover' && u.confirmed) newCode(email, 'recovery');
      return send(200, {});
    }
    if (p === '/auth/v1/verify') {
      const b = await body(req);
      const email = String(b.email || '').trim().toLowerCase();
      const want = b.type === 'recovery' ? 'recovery' : 'signup';
      const c = codes.get(email);
      if (!c || c.type !== want || c.code !== String(b.token)) return send(403, { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' });
      codes.delete(email);
      const u = (await pool.query('update auth.users set confirmed = true where lower(email) = $1 returning id, email', [email])).rows[0];
      return send(200, session(u));
    }
    if (p === '/__test/code') return send(200, codes.get(String(url.searchParams.get('email') || '').toLowerCase()) || {});
    if (p === '/auth/v1/user') {
      const c = claimsOf(req);
      if (!c.sub) return send(401, { msg: 'not signed in' });
      if (req.method === 'PUT') {
        const b = await body(req);
        if (b.password !== undefined) {
          if (String(b.password).length < 8) return send(422, { code: 422, error_code: 'weak_password', msg: 'Password should be at least 8 characters.' });
          await pool.query('update auth.users set password = $2 where id = $1', [c.sub, b.password]);
        }
      }
      return send(200, session({ id: c.sub, email: c.email }).user);
    }
    if (p === '/auth/v1/logout') { res.writeHead(204); return res.end(); }
    if (p === '/functions/v1/join') {
      const b = await body(req);
      const ok = (await pool.query('select 1 from public.world_secrets s join public.worlds w on w.id = s.world_id where s.invite_code = lower(trim($1)) and w.status <> $2',
                                   [String(b.invite || ''), 'ended'])).rowCount;
      if (!ok) return send(400, { error: 'That invite code is not valid' });
      return send(200, { ok: true });
    }
    if (p === '/functions/v1/consultant') {
      const r = await fetch(`http://127.0.0.1:${process.env.CONSULTANT_PORT || 54330}/`, {
        method: 'POST', body: JSON.stringify(await body(req)),
        headers: { 'content-type': 'application/json', authorization: req.headers.authorization || '' },
      }).catch(() => null);
      if (!r) return send(503, { error: 'The consultant function is not running' });
      return send(r.status, await r.json());
    }
    if (p.startsWith('/rest/v1/rpc/') && req.method === 'POST') {
      return send(200, await rpc(p.slice('/rest/v1/rpc/'.length), await body(req), claimsOf(req)));
    }
    if (p.startsWith('/rest/v1/') && req.method === 'GET') {
      return send(200, await restGet(p.slice('/rest/v1/'.length), url, claimsOf(req)));
    }
    return send(404, { message: `not in the shim: ${req.method} ${p}` });
  } catch (e) {
    console.error('shim error', req.method, req.url, e.message);
    return send(e.status || 400, { message: e.message, code: e.code || 'P0001', details: e.detail || null, hint: e.hint || null });
  }
});
server.listen(PORT, () => {
  console.log(`shim on http://localhost:${PORT}`);
  console.log(`anon key: ${ANON}`);
  console.log(`service key: ${SERVICE}`);
});
