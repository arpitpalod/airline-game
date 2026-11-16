import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
const dir = process.argv[2];
const db = new PGlite();
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
`);
for (const f of ['0001_schema.sql', '0002_rule_functions.sql', '0003_seed_reference.sql']) {
  const t0 = Date.now();
  try { await db.exec(fs.readFileSync(`${dir}/${f}`, 'utf8')); console.log('ok', f, Date.now() - t0, 'ms'); }
  catch (e) { console.log('FAIL', f, e.message); process.exit(1); }
}
const q = async (s) => (await db.query(s)).rows;
console.log(await q(`select count(*) n, count(*) filter (where intl) intl, round(sum(n_biz+n_lei+n_bud) filter (where not intl)) dom_potential from public.markets`));
console.log(await q(`select a, b, km, round(n_biz+n_lei+n_bud) n, round((n_biz+n_lei+n_bud)*0.65) realized, ref_fare from public.markets where (a,b) in (('BOM','DEL'),('BLR','DEL'),('BLR','BOM'),('DEL','PAT'),('BLR','MAA'),('BOM','DXB'),('DEL','LHR'),('COK','DXB'),('DEL','JFK'),('BOM','NMI'),('DEL','NMI')) order by n desc`));
console.log(await q(`select t.id, l.* from public.aircraft_types t, lateral public.layout_calc(t.id, 0, null, 29) l order by t.sort`));
console.log(await q(`select * from public.layout_calc('A20N', 3, 38, 30)`));
console.log(await q(`select * from public.layout_calc('A359', 9, null, 31)`));
console.log(await q(`select seats, cabin_crew from public.layout_calc('A20N', 0, null, 28, 'india')`));
console.log(await q(`select valid, reason from public.layout_calc('AT76', 2, 38, 29)`));
console.log(await q(`select round(game.block_hours('A20N', 1150), 2) blk, round(game.sector_fuel_kg('A20N', 1150, 180)) fuel, round(game.sector_fuel_kg('AT76', 370, 72)) atr_fuel`));
console.log(await q(`select name, status, speed, season_days, (select length(invite_code) from public.world_secrets s where s.world_id = w.id) code_len from public.worlds w`));
