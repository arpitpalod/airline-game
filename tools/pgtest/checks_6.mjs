// Computer-run airlines drop starting routes that do not pay their way; Flamingo Air's re-sized network (migration 0016).
export async function checks6(t) {
  const { q, one, ok, as } = t;
  await as(null);
  console.log('Computer-run airlines: re-sized networks and dropping routes that do not pay (0016)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'pilot_quit_year')`);
  const W = await one(`insert into public.worlds (name, demand_scale, max_airlines, pilots) values ('Test 6', 0.5, 25, false) returning id`);
  await q(`select public.admin_start_world($1)`, [W]);
  await q(`select game.run_day($1)`, [W]);
  const flm = await q(`select r.origin || '-' || r.dest as route from public.routes r join public.airlines al on al.id = r.airline_id
     where al.world_id = $1 and al.code = 'FLM' and r.status = 'open' order by 1`, [W]);
  const fleet = await one(`select count(*)::int from public.aircraft ac join public.airlines al on al.id = ac.airline_id where al.world_id = $1 and al.code = 'FLM'`, [W]);
  ok("Flamingo Air no longer starts on Kochi to Abu Dhabi or Kochi to Doha",
    !flm.some((r) => ['COK-AUH', 'COK-DOH'].includes(r.route)) && flm.length === 7, `${flm.length} routes, ${fleet} aircraft at 25 places`);

  // slot prices scale with aircraft size: Myna flies only ATRs (72 reference seats), so pricing slots as if 72 seats were the
  // reference makes its slot bill exactly 180 / 72 = 2.5 times larger on an otherwise identical day
  const s1 = Number(await one(`select c_slots from public.airline_daily d join public.airlines al on al.id = d.airline_id where al.world_id = $1 and al.code = 'MYN' and d.game_day = 1`, [W]));
  await q(`update public.game_params set num = 72 where key = 'slot_ref_seats'`);
  await q(`select game.run_day($1)`, [W]);
  await q(`update public.game_params set num = 180 where key = 'slot_ref_seats'`);
  const s2 = Number(await one(`select c_slots from public.airline_daily d join public.airlines al on al.id = d.airline_id where al.world_id = $1 and al.code = 'MYN' and d.game_day = 2`, [W]));
  ok('a turboprop pays slot prices in proportion to its size (0.4 of an A320neo)', s1 > 0 && Math.abs(s2 / s1 - 2.5) < 0.01,
    `Myna's slots Rs ${Math.round(s1)} a day; Rs ${Math.round(s2)} if an ATR paid like an A320neo`);

  // Make Hornbill's routes look old and thin: 28 days at 40% full with fares below flying costs, except the busiest one.
  const day = 400;
  await q(`update public.worlds set game_day = $2 where id = $1`, [W, day]);
  const hrn = await q(`select r.id, r.origin, r.dest, (least(r.origin, r.dest), greatest(r.origin, r.dest)) in
      (select m.a, m.b from public.markets m where not m.intl order by m.n_biz + m.n_lei + m.n_bud desc limit 8) as top8
      from public.routes r join public.airlines al on al.id = r.airline_id where al.world_id = $1 and al.code = 'HRN' and r.status = 'open'`, [W]);
  await q(`update public.routes r set opened_day = 1 from public.airlines al where al.id = r.airline_id and al.world_id = $1 and al.code in ('HRN', 'KOL')`, [W]);
  await q(`insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz, spill, revenue_inr, var_cost_inr)
           select r.id, d, r.airline_id, 4, 1000, 0, 400, 0, 0, 1000000, 2000000
             from public.routes r join public.airlines al on al.id = r.airline_id, generate_series($2 - 27, $2) d
            where al.world_id = $1 and al.code = 'HRN'
           on conflict do nothing`, [W, day]);
  const ac = await q(`select ro.aircraft_id from public.rotations ro join public.routes r on r.id = ro.route_id
                       join public.airlines al on al.id = r.airline_id where al.world_id = $1 and al.code = 'HRN'`, [W]);
  const poolBefore = await one(`select count(*)::int from public.aircraft where world_id = $1 and status = 'pool'`, [W]);
  const n = await one(`select game.bot_exit($1, $2)`, [W, day]);
  const left = await q(`select r.origin || '-' || r.dest as route from public.routes r join public.airlines al on al.id = r.airline_id
     where al.world_id = $1 and al.code = 'HRN' and r.status = 'open'`, [W]);
  ok('a computer-run airline drops thin starting routes that lose money, down to two routes (and nothing without 21 days of results)', hrn.length > 2 && n === hrn.length - 2 && left.length === 2,
    `Hornbill ${hrn.length} routes, ${n} dropped, kept ${left.map((r) => r.route).join(', ')}`);
  ok('their aircraft leave the world instead of joining the lessor pool',
    (await one(`select count(*)::int from public.aircraft where world_id = $1 and status = 'pool'`, [W])) === poolBefore
    && (await one(`select count(*)::int from public.aircraft where id = any($1::uuid[]) and status = 'returned'`, [ac.map((r) => r.aircraft_id)])) > 0);
  ok('and the news says so', (await one(`select count(*)::int from public.news where world_id = $1 and body like 'Hornbill Airways stops flying%'`, [W])) === n);

  // a full route that loses money is kept: fares, not flights, need fixing
  const koel = await q(`select r.id from public.routes r join public.airlines al on al.id = r.airline_id
     where al.world_id = $1 and al.code = 'KOL' and r.status = 'open'
       and (least(r.origin, r.dest), greatest(r.origin, r.dest)) not in
           (select m.a, m.b from public.markets m where not m.intl order by m.n_biz + m.n_lei + m.n_bud desc limit 8) limit 1`, [W]);
  await q(`insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz, spill, revenue_inr, var_cost_inr)
           select r.id, d, r.airline_id, 4, 1000, 0, 900, 0, 0, 1000000, 2000000 from public.routes r, generate_series($2 - 27, $2) d
            where r.id = $1 on conflict do nothing`, [koel[0].id, day]);
  await q(`select game.bot_exit($1, $2)`, [W, day]);
  ok('a computer-run airline keeps a losing route that is 90% full', (await one(`select status from public.routes where id = $1`, [koel[0].id])) === 'open');
  ok('and never drops one of the eight busiest domestic routes, however thin it looks',
    (await one(`select count(*)::int from public.routes r join public.airlines al on al.id = r.airline_id
        where al.world_id = $1 and r.status = 'closed' and (least(r.origin, r.dest), greatest(r.origin, r.dest)) in
        (select m.a, m.b from public.markets m where not m.intl order by m.n_biz + m.n_lei + m.n_bud desc limit 8)`, [W])) === 0);
}
