// Revenue management (migration 0018). Runs in its own world with revenue management on and the random parts off.
export async function checks8(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  console.log('Revenue management (0018)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'pilot_quit_year', 'rm_date_sd', 'rm_city_prob')`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, rm) values ('Test 8', 0.5, 25, false, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test8000' from w returning world_id`);
  const P = await one(`select public.found_airline('test8000', 'Sell Air', 'SA', 'DEL')`);
  const Q = await one(`select public.found_airline('test8000', 'Hold Air', 'HA', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const day = () => one(`select game_day from public.worlds where id = $1`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  await run(1);
  const H = 42;

  // two domestic markets from Delhi nobody flies, 500 to 1,200 km
  const mk = await q(`select case when m.a = 'DEL' then m.b else m.a end as other, m.ref_fare::int ref, m.km
      from public.markets m join public.airports x on x.iata = case when m.a = 'DEL' then m.b else m.a end
     where 'DEL' in (m.a, m.b) and not m.intl and m.km between 500 and 1200 and x.opens_day <= 2 and x.runway_class >= 2
       and not exists (select 1 from public.routes r where r.world_id = $1 and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b)
     order by m.n_biz + m.n_lei + m.n_bud desc limit 2`, [W]);
  const wetP = (await q(`select id from public.aircraft where airline_id = $1 order by reg`, [P])).map((r) => r.id);
  const wetQ = (await q(`select id from public.aircraft where airline_id = $1 order by reg`, [Q])).map((r) => r.id);
  const rP = await one(`select public.open_route($1, 'DEL', $2, $3)`, [P, mk[0].other, mk[0].ref]);
  const rm0 = (await q(`select * from public.route_rm where route_id = $1`, [rP]))[0];
  ok('a new route sells to a booking curve with six economy fare levels that close as the day nears',
    rm0.mode === 'curve' && rm0.e_mult.length === 6 && rm0.e_close.join() === '21,14,7,2,0,0' && Number(rm0.flex) === 0.15);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [P, wetP[0], rP]);
  await run(1);
  const d1 = await day();
  const deps = await q(`select dep_day, lvl_e, (select sum(v) from unnest(sold_e) v)::float sold, cap_e::float cap, curve
      from public.departures where route_id = $1 order by dep_day`, [rP]);
  ok('the route is on sale for the next six weeks', deps.length === H - 1 && deps[0].dep_day === d1 + 1 && deps.at(-1).dep_day === d1 + H - 1,
    `departures for days ${deps[0].dep_day} to ${deps.at(-1).dep_day}`);
  const flown = (await q(`select * from public.departure_log where route_id = $1 and dep_day = $2`, [rP, d1]))[0];
  ok('a route going on sale for the first time is filled as if it had been on sale: its first flight goes out with passengers',
    flown && flown.pax_e > 0.4 * flown.cap_e, flown ? `${Math.round(flown.pax_e)} of ${Math.round(flown.cap_e)} seats` : 'no flight');
  ok('flights further away have sold less', deps[0].sold > deps[20].sold && deps[20].sold > deps[40].sold,
    `${Math.round(deps[0].sold)}, ${Math.round(deps[20].sold)} and ${Math.round(deps[40].sold)} seats sold 1, 21 and 41 days ahead`);
  const fence = deps.every((d) => { const n = d.dep_day - d1; return d.lvl_e === 0 || (n >= 21 || d.lvl_e >= 2) && (n >= 7 || d.lvl_e >= 4) && (n >= 2 || d.lvl_e >= 5); });
  ok('cheap fare levels stop selling on their day: level 1 three weeks ahead, level 3 one week ahead, level 4 two days ahead', fence,
    deps.slice(0, 8).map((d) => `${d.dep_day - d1}:${d.lvl_e}`).join(' '));
  const curve = flown?.curve ?? [];
  ok('each flight keeps its bookings by days before departure', curve.length === H && curve[0] >= curve[7] && curve[7] >= curve[21] && curve[21] > 0,
    `${Math.round(curve[21])} booked 21 days before, ${Math.round(curve[7])} 7 days before, ${Math.round(curve[0])} on the day`);

  // Business travellers book late and buy Flexi; leisure travellers book early and buy Saver.
  await run(6);
  const mix = (await q(`select sum(sav[1] + flx[1])::float biz, sum(sav[1] + flx[1] + sav[2] + flx[2] + sav[3] + flx[3])::float tot,
      sum(flx[1])::float fb, sum(flx[2])::float fl, sum(sav[2] + flx[2])::float lei from public.departure_log where route_id = $1`, [rP]))[0];
  const far = (await q(`select sum(sav[1] + flx[1])::float biz, sum(sav[1] + flx[1] + sav[2] + flx[2] + sav[3] + flx[3])::float tot
      from public.departures where route_id = $1 and dep_day >= $2 + 30`, [rP, await day()]))[0];
  ok('business travellers book late: they are a bigger share of a flown flight than of bookings a month ahead',
    mix.biz / mix.tot > 1.5 * (far.biz / far.tot), `${(100 * mix.biz / mix.tot).toFixed(0)}% flown, ${(100 * far.biz / far.tot).toFixed(0)}% of bookings 30+ days ahead`);
  ok('Flexi sells to business travellers, hardly to leisure travellers', mix.fb / mix.biz > 0.6 && mix.fl / mix.lei < 0.2,
    `${(100 * mix.fb / mix.biz).toFixed(0)}% of business, ${(100 * mix.fl / mix.lei).toFixed(0)}% of leisure`);
  const dlast = await day();
  const lg = (await q(`select sum(revenue)::float rev, sum(noshow)::float ns, sum(denied)::float den from public.departure_log l
      join public.routes r on r.id = l.route_id where r.airline_id = $1 and l.dep_day = $2`, [P, dlast]))[0];
  const ad = (await q(`select rev_ticket::float rev, pax::int pax from public.airline_daily where airline_id = $1 and game_day = $2`, [P, dlast]))[0];
  ok("ticket revenue is what the day's flights sold, both ways, after refunds", Math.abs(ad.rev - 2 * lg.rev) <= 2, `Rs ${Math.round(ad.rev)}`);
  ok('some passengers do not turn up', lg.ns > 0, `${(2 * lg.ns).toFixed(0)} no-shows both ways`);

  // Booking curve mode: a high target makes it sell cheaper, a low one dearer.
  const avgLvl = () => one(`select avg(lvl_e)::float from public.departures where route_id = $1 and dep_day between $2 + 7 and $2 + 30`, [rP, d1 + 7]);
  const l0 = await avgLvl();
  await q(`select public.set_rm($1, $2, '{"target_lf": 1.1, "pace": 3}')`, [P, rP]);
  await run(3);
  const l1 = await avgLvl();
  await q(`select public.set_rm($1, $2, '{"target_lf": 0.5}')`, [P, rP]);
  await run(3);
  const l2 = await avgLvl();
  ok('booking-curve mode sells cheaper when bookings run behind a high target, dearer when ahead of a low one', l1 < l0 - 0.3 && l2 > l1 + 0.5,
    `average level ${l0.toFixed(1)}, then ${l1.toFixed(1)} aiming for 110% full, ${l2.toFixed(1)} aiming for 50%`);

  // Manual mode: seat limits cap each cheap level.
  await q(`select public.set_rm($1, $2, '{"mode": "manual", "e_limit": [0.01, 0.02, 0.03, 0.04, 0.05, 1], "overbook": 0}')`, [P, rP]);
  const dm = await day();
  await run(2);
  const man = await q(`select (select sum(v) from unnest(sold_e[1:5]) v)::float cheap, sold_e[6]::float top, cap_e::float cap
      from public.departures where route_id = $1 and opened > $2`, [rP, dm]);
  ok('manual mode: no more seats sell at the cheap levels than their limit; the rest sell at the top level',
    man.length > 0 && man.every((x) => x.cheap <= 0.05 * x.cap + 1e-6), man.map((x) => `${x.cheap.toFixed(1)}/${(0.05 * x.cap).toFixed(1)}`).join(' '));

  // The optimiser picks a level for every date on sale, never one that has stopped selling.
  await q(`select public.set_rm($1, $2, '{"mode": "optimise"}')`, [P, rP]);
  await run(1);
  const opt = await q(`select dep_day - $2 n, lvl_e from public.departures where route_id = $1 order by dep_day`, [rP, await day()]);
  ok('optimiser mode sets a level within the fences for every date', opt.every((x) => x.lvl_e >= 1 && (x.n >= 21 || x.lvl_e >= 2) && (x.n >= 2 || x.lvl_e >= 5)),
    `levels ${[...new Set(opt.map((x) => x.lvl_e))].sort().join(', ')}`);

  // A date's own floor
  const dd = await day();
  ok('a date can be closed to cheap fares by hand', (await one(`select public.set_rm_dates($1, $2, $3, $4, 6)`, [P, rP, dd + 10, dd + 12])) === 3);
  await run(1);
  ok('and only the top level sells on those dates', (await one(`select bool_and(lvl_e in (0, 6)) from public.departures where route_id = $1 and dep_day between $2 and $3`, [rP, dd + 10, dd + 12])) === true);

  // Validation
  await fails('fare levels must rise level by level', `select public.set_rm('${P}', '${rP}', '{"e_mult": [0.7, 0.8, 0.8, 1, 1.2, 1.4]}')`, /each dearer/);
  await fails('a cheap level cannot sell later than a dearer one', `select public.set_rm('${P}', '${rP}', '{"e_close": [7, 14, 7, 3, 0, 0]}')`, /no earlier than/);
  await fails('the dearest level may always sell every seat', `select public.set_rm('${P}', '${rP}', '{"e_limit": [0.2, 0.4, 0.6, 0.8, 0.9, 0.95]}')`, /every seat/);
  await fails('fare levels are set route by route', `select public.set_rm('${P}', null, '{"e_mult": [0.7, 0.8, 0.9, 1, 1.2, 1.4]}')`, /route by route/);
  await fails('overbooking is capped', `select public.set_rm('${P}', '${rP}', '{"overbook": 0.4}')`, /Overbooking/);
  ok('network-wide settings reach every route', (await one(`select public.set_rm($1, null, '{"mode": "curve", "target_lf": 0.85}')`, [P])) >= 1);

  // Overbooking with nobody missing their flight: passengers who cannot board get their fare back and compensation.
  const rQ = await one(`select public.open_route($1, 'DEL', $2, $3)`, [Q, mk[1].other, Math.round(mk[1].ref * 0.6)]);
  await q(`select public.set_rotation($1, $2, $3, 3)`, [Q, wetQ[0], rQ]);
  await q(`update public.game_params set num = 0 where key in ('rm_noshow_biz', 'rm_noshow_lei', 'rm_noshow_bud', 'rm_noshow_flex')`);
  await q(`select public.set_rm($1, $2, '{"overbook": 0.15, "mode": "manual", "e_limit": [0.2, 0.4, 0.6, 0.8, 1, 1]}')`, [Q, rQ]);
  await run(1);   // goes on sale, filled as if on sale for six weeks: with fares this low it sells out, 15% over
  const ob = (await q(`select * from public.departure_log where route_id = $1 order by dep_day desc limit 1`, [rQ]))[0];
  const rdq = (await q(`select denied::int, noshow::int from public.route_daily where route_id = $1 order by game_day desc limit 1`, [rQ]))[0];
  const avgFare = (ob.revenue + ob.denied * 0) / Math.max(1, ob.pax_e + ob.pax_b);
  ok('an overbooked flight with no no-shows leaves passengers behind', ob.denied > 0.1 * ob.cap_e && rdq.denied === Math.round(2 * ob.denied),
    `${Math.round(ob.denied)} of ${Math.round(ob.cap_e * 1.15)} booked could not board`);
  ok('each gets compensation of twice the fare, at most Rs 10,000', Math.abs(ob.compensation - ob.denied * Math.min(2 * avgFare, 10000)) < 0.02 * ob.compensation + 5,
    `Rs ${Math.round(ob.compensation)} for ${ob.denied.toFixed(1)} passengers`);
  await q(`update public.game_params set num = v from (values ('rm_noshow_biz', 0.06), ('rm_noshow_lei', 0.025), ('rm_noshow_bud', 0.025), ('rm_noshow_flex', 0.06)) x(k, v) where key = k`);

  // Taking the aircraft off: flights more than two weeks away are refunded, nearer ones fly empty and compensate everyone.
  const before = (await q(`select sum((select sum(v) from unnest(sold_e) v)) filter (where dep_day > $2 + 15)::float far,
      sum((select sum(v) from unnest(sold_e) v)) filter (where dep_day <= $2 + 14)::float near from public.departures where route_id = $1`, [rQ, await day()]))[0];
  await q(`select public.set_rotation($1, $2, $3, 0)`, [Q, wetQ[0], rQ]);
  await run(1);
  const after = (await q(`select sum((select sum(v) from unnest(sold_e) v)) filter (where dep_day > $2 + 14)::float far,
      sum((select sum(v) from unnest(sold_e) v)) filter (where dep_day <= $2 + 13)::float near from public.departures where route_id = $1`, [rQ, await day()]))[0];
  const cx = (await q(`select pax_e::float, denied::float, compensation::float from public.departure_log where route_id = $1 order by dep_day desc limit 1`, [rQ]))[0];
  ok('cutting a flight more than two weeks away refunds its passengers without compensation', before.far > 0 && after.far < 1e-6,
    `${Math.round(before.far)} seats refunded`);
  ok('a flight cut at short notice leaves its passengers behind, with compensation', after.near > 0 && cx.pax_e === 0 && cx.denied > 0 && cx.compensation > 0,
    `${Math.round(cx.denied)} passengers, Rs ${Math.round(cx.compensation)}`);

  // What travellers see, and the what-if
  const mf = await q(`select * from public.market_fares($1)`, [rP]);
  ok("anyone can see the fares on sale on a route's market by date", mf.length >= H - 2 && mf.every((x) => x.fare_e == null || x.fare_e > 0));
  const wi = await q(`select * from public.rm_whatif($1)`, [rP]);
  ok('the what-if shows fewer travellers at higher fares, and never more passengers than seats',
    wi.length === 15 && wi.every((x, i) => i === 0 || Number(x.demand) < Number(wi[i - 1].demand)) && wi.every((x) => Number(x.pax) <= Number(x.demand) + 0.1),
    wi.filter((_, i) => i % 4 === 0).map((x) => `${x.fare}: ${x.demand}`).join(', '));

  // A city's event, announced weeks ahead, brings more travellers on its days
  await q(`update public.game_params set num = 1 where key = 'rm_city_prob'`);
  await run(1);
  await q(`update public.game_params set num = 0 where key = 'rm_city_prob'`);
  const ev = (await q(`select * from public.events where world_id = $1 and kind = 'city_demand'`, [W]))[0];
  ok('cities announce events weeks ahead, with news', ev && ev.starts_day >= (await day()) + 14 && (await one(`select count(*)::int from public.news where world_id = $1 and kind = 'city_demand'`, [W])) === 1,
    ev ? `${ev.payload.name} at ${ev.payload.iata}, days ${ev.starts_day} to ${ev.ends_day}` : '');

  // Money by aircraft still adds up in a world with revenue management
  const dz = await day();
  const r = (await q(`select sum(revenue_inr)::float rev from public.route_daily where airline_id = $1 and game_day = $2`, [P, dz]))[0];
  const a = (await q(`select sum(revenue_inr)::float rev, count(*)::int n from public.aircraft_daily where airline_id = $1 and game_day = $2`, [P, dz]))[0];
  ok('aircraft revenue adds up to route revenue', Math.abs(a.rev - r.rev) <= 2 * a.n + 2, `Rs ${Math.round(a.rev)} against Rs ${Math.round(r.rev)}`);

  // A running world switched to revenue management fills six weeks of bookings on its next day
  const W2 = await one(`insert into public.worlds (name, demand_scale, max_airlines, pilots, rm) values ('Test 8b', 0.5, 25, false, false) returning id`);
  await q(`select public.admin_start_world($1)`, [W2]);
  await q(`select game.run_day($1)`, [W2]);
  await q(`update public.worlds set rm = true where id = $1`, [W2]);
  await q(`select game.run_day($1)`, [W2]);
  const sw = (await q(`select count(distinct route_id)::int routes, count(*)::int deps, avg(cardinality(curve))::float len,
      (select avg(pax_e / nullif(cap_e, 0))::float from public.departure_log where world_id = $1) lf from public.departures where world_id = $1`, [W2]))[0];
  ok('a world switched to revenue management goes on sale for six weeks, and its first flights go out full', sw.deps === sw.routes * (H - 1) && sw.lf > 0.6,
    `${sw.routes} routes, first-day load ${(100 * sw.lf).toFixed(0)}%`);
}
