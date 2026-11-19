// Prints md5(prosrc) of every function in game and public after all migrations, to compare with the list the database
// workflow prints. Usage: node md5.mjs ../../supabase/migrations
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
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
const r = await db.query(`select n.nspname || '.' || p.proname || ' ' || md5(p.prosrc) as l from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('game', 'public') and p.prokind = 'f' order by 1`);
for (const x of r.rows) console.log(x.l);
process.exit(0);
