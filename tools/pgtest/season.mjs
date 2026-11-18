// Full-season simulation: the computer-run airlines plus simulated players with different strategies.
// Used to tune Stage 2c. Usage: node season.mjs ../../supabase/migrations [--days 2366] [--scale auto] [--seed snapshot.tgz]
// Players act once a game week through the public action functions, like a person checking the app.
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';

const dir = process.argv[2];
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const DAYS = +arg('--days', 2366);
const SNAP = arg('--seed', null);   // optional snapshot of migrations 0001-0006, to skip the 25 s market build

// strategy: aircraft type and cabin, how aircraft are acquired, fare band, which routes
const STRATS = {
  lcc_trunk:  { type: 'A20N', lay: [0, null, 28], src: 'pool', lo: 0.90, hi: 1.20, start: 0.95, pick: 'trunk', bases: ['DEL', 'BLR'] },
  niche:      { type: 'A20N', lay: [0, null, 29], src: 'pool', lo: 0.95, hi: 1.80, start: 1.10, pick: 'niche', bases: ['PNQ', 'JAI'] },
  full_svc:   { type: 'A20N', lay: [3, 38, 30],   src: 'pool', lo: 1.00, hi: 1.50, start: 1.10, pick: 'trunk', bases: ['BOM', 'HYD'], mkt: 40 },
  regional:   { type: 'AT76', lay: [0, null, 28], src: 'pool', lo: 0.95, hi: 1.80, start: 1.10, pick: 'niche', maxkm: 700, bases: ['HYD', 'CCU'] },
  gulf:       { type: 'A21N', lay: [0, null, 28], src: 'pool', lo: 0.95, hi: 1.50, start: 1.00, pick: 'intl', maxkm: 3500, bases: ['COK', 'HYD'] },
  long_haul:  { type: 'A359', lay: [9, null, 31], src: 'pool', lo: 1.00, hi: 1.60, start: 1.10, pick: 'intl', minkm: 3500, bases: ['DEL', 'BOM'] },
  order_loan: { type: 'A20N', lay: [0, null, 29], src: 'loan', lo: 0.95, hi: 1.80, start: 1.10, pick: 'niche', bases: ['AMD', 'CCU'] },
  order_cash: { type: 'A20N', lay: [0, null, 29], src: 'cash', lo: 0.95, hi: 1.80, start: 1.10, pick: 'niche', bases: ['MAA', 'GOI'] },
  wet_only:   { type: 'A20N', lay: [0, null, 29], src: 'wet',  lo: 0.95, hi: 1.80, start: 1.10, pick: 'niche', bases: ['IDR', 'NAG'] },
};
const players = Object.entries(STRATS).flatMap(([k, s]) => s.bases.map((b, i) => ({ strat: k, s, base: b, name: `${k} ${i + 1}` })));
const SCALE = arg('--scale', 'auto') === 'auto' ? players.length / 50 : +arg('--scale');

let db;
if (SNAP) db = new PGlite({ loadDataDir: new Blob([fs.readFileSync(SNAP)]) });
else {
  db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role; create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;`);
}
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.sql')).sort()) {
  if (SNAP && f < '0007') continue;
  await db.exec(fs.readFileSync(`${dir}/${f}`, 'utf8'));
}
const q = async (s, p) => (await db.query(s, p)).rows;
const one = async (s, p) => Object.values((await db.query(s, p)).rows[0] ?? {})[0];
const tryq = async (s) => { try { return await q(s); } catch (e) { return null; } };

for (const [k, v] of Object.entries(JSON.parse(arg('--params', '{}')))) await q(`update public.game_params set num = $1 where key = $2`, [v, k]);
const W = await one(`select id from public.worlds limit 1`);
const code = await one(`select invite_code from public.world_secrets where world_id = $1`, [W]);
await q(`update public.worlds set demand_scale = $1 where id = $2`, [SCALE, W]);
for (const p of players) p.id = await one(`select public.found_airline($1, $2, $3, $4)`, [code, p.name, 'P' + players.indexOf(p), p.base]);
await q(`select public.admin_start_world($1)`, [W]);
console.log(`${players.length} players, demand_scale ${SCALE.toFixed(2)}, ${DAYS} days`);

// round trips a week that fit 88% of the flying window
async function tripsFor(ac, km) {
  const r = (await q(`select t.cruise_kmh, t.block_offset_h, t.day_window_h, l.min_turn_min, l.range_km from public.aircraft a
    join public.aircraft_types t on t.id = a.type_id, lateral public.layout_calc(a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch) l where a.id = $1`, [ac]))[0];
  if (km > r.range_km) return 0;
  const rot = 2 * (km / r.cruise_kmh + +r.block_offset_h + r.min_turn_min / 60);
  return Math.min(84, Math.floor((0.88 * 7 * r.day_window_h) / rot));
}

// Give an aircraft's free flying hours to the routes with the most unserved demand from the base,
// each sized to that demand (trunk strategies aim for about 15% of the market instead).
async function fill(p, ac, day) {
  const s = p.s;
  const a = (await q(`select a.seats_econ + a.seats_biz seats, t.cruise_kmh::float cr, t.block_offset_h::float off, t.day_window_h::float win,
      l.min_turn_min::float turn, l.range_km,
      coalesce((select sum(ro.weekly_trips * 2 * (m.km::float / t.cruise_kmh + t.block_offset_h + l.min_turn_min / 60.0))
                  from public.rotations ro join public.routes r on r.id = ro.route_id
                  join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
                 where ro.aircraft_id = a.id), 0)::float used
      from public.aircraft a join public.aircraft_types t on t.id = a.type_id,
      lateral public.layout_calc(a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch) l where a.id = $1`, [ac]))[0];
  let free = 0.88 * 7 * a.win - a.used;
  const rows = await q(`
    with sup as (select least(r.origin, r.dest) a, greatest(r.origin, r.dest) b, sum(ro.weekly_trips / 7.0 * (x.seats_econ + x.seats_biz)) seats,
                        sum(ro.weekly_trips / 7.0 * (x.seats_econ + x.seats_biz)) filter (where r.airline_id = $1) mine
              from public.routes r join public.rotations ro on ro.route_id = r.id join public.aircraft x on x.id = ro.aircraft_id
             where r.world_id = $2 and r.status = 'open' group by 1, 2)
    select case when m.a = $3 then m.b else m.a end other, m.km, (m.n_biz + m.n_lei + m.n_bud)::float * $4 pot, coalesce(sup.seats, 0)::float seats,
           coalesce(sup.mine, 0)::float mine, m.ref_fare
      from public.markets m
      join public.airports pa on pa.iata = m.a join public.airports pb on pb.iata = m.b
      left join sup on sup.a = m.a and sup.b = m.b
     where (m.a = $3 or m.b = $3) and m.intl = $5 and m.km between $6 and $7
       and least(pa.runway_class, pb.runway_class) >= (select runway_class from public.aircraft_types where id = $8)
       and pa.opens_day <= $9 and pb.opens_day <= $9
     order by case when $10 = 'trunk' then (m.n_biz + m.n_lei + m.n_bud) * $4 * 0.15 - coalesce(sup.mine, 0) * 0.85
                   else (m.n_biz + m.n_lei + m.n_bud) * $4 * 0.55 - coalesce(sup.seats, 0) * 0.85 end desc
     limit 15`, [p.id, W, p.base, SCALE, s.pick === 'intl', s.minkm ?? 150, Math.min(s.maxkm ?? 20000, a.range_km), s.type, day, s.pick]);
  for (const r of rows) {
    const rot = 2 * (r.km / a.cr + a.off + a.turn / 60);
    const max = Math.min(84, Math.floor(free / rot));
    if (max < 3) continue;
    const resid = s.pick === 'trunk' ? r.pot * 0.15 - r.mine * 0.85 : r.pot * 0.55 - r.seats * 0.85;
    const want = Math.ceil(resid * 7 / (a.seats * 0.85));
    if (want < 3) continue;
    const trips = Math.min(max, want);
    let route = await one(`select id from public.routes where airline_id = $1 and least(origin, dest) = least($2, $3) and greatest(origin, dest) = greatest($2, $3)`, [p.id, p.base, r.other]);
    if (!route) route = await one(`select public.open_route($1, $2, $3, $4)`, [p.id, p.base, r.other, Math.round(r.ref_fare * s.start)]);
    else await tryq(`select public.open_route('${p.id}', '${p.base}', '${r.other}', ${Math.round(r.ref_fare * s.start)})`);
    if (await tryq(`select public.set_rotation('${p.id}', '${ac}', '${route}', ${trips})`)) { free -= trips * rot; r.mine += trips / 7 * a.seats; }
    if (free < 6) break;
  }
}

async function acquire(p, day) {
  const s = p.s, [br, bp, ep] = s.lay;
  const leased = await one(`select count(*)::int from public.transactions where airline_id = $1 and kind = 'lease'`, [p.id]);
  let src = s.src;
  if ((src === 'loan' || src === 'cash') && leased < 2) src = 'pool';   // two pool aircraft to bridge the order wait
  if (src === 'pool') {
    const ac = await one(`select id from public.aircraft where world_id = $1 and status = 'pool' and type_id = $2
      order by (biz_rows = $3 and econ_pitch = $4) desc, built_day desc limit 1`, [W, s.type, br, ep]);
    if (ac && await tryq(`select public.lease_aircraft('${p.id}', '${ac}', '${p.base}')`)) return 'lease';
    return null;
  }
  if (src === 'wet') return (await tryq(`select public.wet_lease('${p.id}', '${s.type}', '${p.base}')`)) ? 'wet' : null;
  return (await tryq(`select public.order_aircraft('${p.id}', '${s.type}', '${p.base}', ${br}, ${bp ?? 'null'}, ${ep}, '${src}')`)) ? 'order' : null;
}

async function act(p, day) {
  const s = p.s;
  // 1. fares from the last 7 days' load factor, within the strategy's band
  for (const r of await q(`select r.id, r.fare_econ, r.fare_biz, m.ref_fare, sum(d.pax_econ)::float / nullif(sum(d.seats_econ), 0) lf,
      sum(d.pax_biz)::float / nullif(sum(d.seats_biz), 0) lfb
      from public.routes r join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
      join public.route_daily d on d.route_id = r.id and d.game_day > $2 - 7
      where r.airline_id = $1 and r.status = 'open' group by r.id, m.ref_fare`, [p.id, day])) {
    const adj = (f, lf) => lf == null ? f : lf > 0.92 ? f * 1.05 : lf < 0.75 ? f * 0.95 : f;
    const e = Math.round(Math.min(s.hi, Math.max(s.lo, adj(r.fare_econ, r.lf) / r.ref_fare)) * r.ref_fare);
    const b = Math.round(Math.min(s.hi * 3.5, Math.max(s.lo * 3.5, adj(r.fare_biz, r.lfb) / r.ref_fare)) * r.ref_fare);
    if (e !== r.fare_econ || b !== r.fare_biz) await tryq(`select public.set_fares('${p.id}', '${r.id}', ${e}, ${b})`);
  }
  // 2. once an own aircraft is flying, the wet-leased ones go back; their routes are filled again in step 3
  if (s.src !== 'wet' && await one(`select count(*)::int from public.aircraft a join public.aircraft_terms t on t.aircraft_id = a.id
      where a.airline_id = $1 and a.status = 'active' and t.holding <> 'wet'`, [p.id]) > 0)
    for (const w of await q(`select a.id from public.aircraft a join public.aircraft_terms t on t.aircraft_id = a.id
        where a.airline_id = $1 and t.holding = 'wet'`, [p.id])) await tryq(`select public.return_aircraft('${p.id}', '${w.id}')`);
  // 3. idle aircraft get a route
  for (const a of await q(`select a.id from public.aircraft a where a.airline_id = $1 and a.status in ('active', 'delivering')
      and a.available_day <= $2 + 14 and not exists (select 1 from public.rotations r where r.aircraft_id = a.id)`, [p.id, day])) await fill(p, a.id, day);
  // 4. prune: every quarter, close routes that stay empty at the bottom of the band
  if (day % 91 === 0) for (const r of await q(`select r.id from public.routes r join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
      join public.route_daily d on d.route_id = r.id where r.airline_id = $1 and r.status = 'open' and r.fare_econ <= m.ref_fare * $2 * 1.02
      group by r.id having sum(d.pax_econ)::float / nullif(sum(d.seats_econ), 0) < 0.6`, [p.id, s.lo])) await tryq(`select public.close_route('${p.id}', '${r.id}')`);
  // 5. grow while cash allows and the airline is making money
  const f = (await q(`select cash_inr::float cash, (select count(*)::int from public.aircraft where airline_id = $1) fleet,
      (select sum(rev_ticket + rev_anc - (c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead))::float
         from public.airline_daily where airline_id = $1 and game_day > $2 - 28) op28 from public.airline_finance where airline_id = $1`, [p.id, day]))[0];
  if (s.mkt) await tryq(`select public.set_marketing('${p.id}', ${Math.round(s.mkt * 1000 * Math.max(1, f.fleet))})`);
  const idle = await one(`select count(*)::int from public.aircraft a where a.airline_id = $1 and a.status = 'active'
      and not exists (select 1 from public.rotations r where r.aircraft_id = a.id)`, [p.id]);
  if (f.cash > 6e8 && f.fleet < 60 && idle === 0 && (f.fleet <= 2 || f.op28 > 0)) p.got = (p.got ?? 0) + ((await acquire(p, day)) ? 1 : 0);
}

const t0 = Date.now();
for (let d = 1; d <= DAYS; d++) {
  await q(`select game.run_day($1)`, [W]);
  if (d % 7 === 1) for (const p of players) await act(p, d);
  if (d % 364 === 0 || d === DAYS) {
    console.log(`\n== day ${d} (${((Date.now() - t0) / 1000).toFixed(0)} s)`);
    console.table(await q(`
      select al.name, (select count(*)::int from public.aircraft x where x.airline_id = al.id) fleet, round(f.cash_inr / 1e7) cash_cr,
             round(sum(d.rev_ticket + d.rev_anc) / 1e7) rev_cr,
             round(1 - sum(d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_other + d.c_depr)
                       / nullif(sum(d.rev_ticket + d.rev_anc), 0), 3) op_margin,
             round(sum(d.rpk) / nullif(sum(d.ask), 0), 3) lf,
             round(sum(d.rev_ticket + d.rev_anc) / nullif(sum(d.ask), 0), 2) rask,
             round(sum(d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_other + d.c_depr) / nullif(sum(d.ask), 0), 2) cask,
             round(al.brand) brand, (select round(score / 1e7) from public.quarterly_reports r where r.airline_id = al.id order by quarter desc limit 1) score_cr,
             (select rank from public.quarterly_reports r where r.airline_id = al.id order by quarter desc limit 1) rk, al.administrations adm
        from public.airlines al join public.airline_finance f on f.airline_id = al.id
        left join public.airline_daily d on d.airline_id = al.id and d.game_day > $2 - 364
       where al.world_id = $1 group by al.id, f.cash_inr order by al.is_ai, rk nulls last`, [W, d]));
  }
}
console.log('cost per seat-km by component, last 364 days');
console.table(await q(`select al.name, round(sum(d.ask) / nullif(sum(d.flights), 0) / nullif((select avg(x.seats_econ + x.seats_biz) from public.aircraft x where x.airline_id = al.id), 0)) stage_km,
  ${['c_fuel', 'c_rent', 'c_crew', 'c_maint', 'c_airport', 'c_slots', 'c_dist', 'c_overhead', 'c_marketing', 'c_other', 'c_depr'].map((c) => `round(sum(d.${c}) / nullif(sum(d.ask), 0), 2) ${c.slice(2)}`).join(', ')},
  round(sum(d.cancelled) / nullif(sum(d.flights + d.cancelled), 0), 3) cxl
  from public.airlines al join public.airline_daily d on d.airline_id = al.id and d.game_day > ${DAYS} - 364 group by al.id order by al.is_ai, al.name`));
const slots = await q(`with mv as (select z.iata, sum(z.m) moves from (select r.origin iata, ro.weekly_trips * 2 / 7.0 m from public.routes r join public.rotations ro on ro.route_id = r.id where r.status = 'open'
  union all select r.dest, ro.weekly_trips * 2 / 7.0 from public.routes r join public.rotations ro on ro.route_id = r.id where r.status = 'open') z group by 1)
  select ap.iata, round(mv.moves) moves, ap.slot_cap, round(mv.moves / (ap.slot_cap * ${SCALE}), 2) util from mv join public.airports ap on ap.iata = mv.iata where ap.slot_cap is not null order by util desc limit 6`);
console.table(slots);
const fares = await q(`select m.a || '-' || m.b mkt, round(avg(r.fare_econ::numeric / m.ref_fare) filter (where al.is_ai), 2) bots, round(avg(r.fare_econ::numeric / m.ref_fare) filter (where not al.is_ai), 2) players,
  count(*) filter (where not al.is_ai) n_players from public.routes r join public.airlines al on al.id = r.airline_id join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
  where r.status = 'open' and exists (select 1 from public.rotations ro where ro.route_id = r.id) group by 1 order by sum(m.n_biz + m.n_lei + m.n_bud) desc limit 8`);
console.table(fares);
console.log('routes computer-run airlines started and gave up to contest players');
console.table(await q(`select a.name, count(*) filter (where n.body like '%starts flying%')::int started, count(*) filter (where n.body like '%stops flying%')::int gave_up,
  (select count(*)::int from public.routes r where r.airline_id = a.id and r.status = 'open' and game.bot_entered(a.id, r.origin, r.dest)) open_now
  from public.airlines a left join public.news n on n.airline_id = a.id and n.kind = 'route' and not n.private
  where a.is_ai group by a.id, a.name order by a.name`));
console.log('engine log:', await q(`select game_day, message from game.engine_log limit 5`));
if (arg('--save', null)) { const b = await db.dumpDataDir('gzip'); fs.writeFileSync(arg('--save'), Buffer.from(await b.arrayBuffer())); }
process.exit(0);
