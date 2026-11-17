// Local migration test: runs every migration in an in-memory Postgres, then the checks.
// Usage: node run.mjs ../../supabase/migrations [--perf]
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { checks2a } from './checks_2a.mjs';
import { checks2b } from './checks_2b.mjs';

const dir = process.argv[2];
const db = new PGlite();
// Stand-ins for Supabase's roles and auth schema. auth.uid() reads the request claims, as Supabase's does.
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;
  grant usage on schema auth to authenticated, anon;
`);
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.sql')).sort()) {
  const t0 = Date.now();
  try { await db.exec(fs.readFileSync(`${dir}/${f}`, 'utf8')); console.log('ok', f, Date.now() - t0, 'ms'); }
  catch (e) { console.log('FAIL', f, e.message); process.exit(1); }
}

let failed = 0;
const t = {
  db,
  q: async (s, p) => (await db.query(s, p)).rows,
  one: async (s, p) => Object.values((await db.query(s, p)).rows[0])[0],
  ok(name, cond, detail = '') { if (!cond) failed++; console.log(cond ? '  pass' : '  FAIL', name, detail); },
  async fails(name, sql, re) {
    try { await db.query(sql); failed++; console.log('  FAIL', name, '(no error)'); }
    catch (e) { const hit = re.test(e.message); if (!hit) failed++; console.log(hit ? '  pass' : '  FAIL', name, hit ? '' : e.message); }
  },
  as: (uid) => db.query(`select set_config('request.jwt.claims', $1, false)`,
    [uid ? JSON.stringify({ sub: uid, role: 'authenticated' }) : '']),
};

await checks2a(t);
await checks2b(t, process.argv.includes('--perf'));
console.log(failed ? `\n${failed} CHECK(S) FAILED` : '\nall checks passed');
process.exit(failed ? 1 : 0);
