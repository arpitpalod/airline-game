// Year-one fixes (migration 0024): disruption rates, computer-run airlines that plan routes and share aircraft, review routes
// on profit, keep a spare and hand the rest back, fights that match the market, a cost floor, fares that follow fuel.
export async function checks14(t) {
  const { q, one, ok, as, y1Params } = t;
  await as(null);
  console.log('Year-one fixes (0024)');
  // the 0024 values (run.mjs set the old ones for the older checks)
  for (const p of y1Params) await q(`update public.game_params set num = $1 where key = $2`, [p.num, p.key]);
  const P = Object.fromEntries((await q(`select key, num::float from public.game_params`)).map((x) => [x.key, x.num]));
  ok('disruptions at real rates: groundings 0.15% a day, fuel shocks and engine events about once in three years',
    P.ground_prob_day === 0.0015 && P.event_fuel_prob_day === 0.001 && P.event_engine_prob_day === 0.001 && P.bot_drop_min_days === 91);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day')`);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 14', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1400' from w returning world_id`);
  const A = await one(`select public.found_airline('test1400', 'Year One Air', 'YO', 'DEL')`);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1), public.open_route($1, 'DEL', 'BOM'), 14)`, [A]);
  await q(`select public.admin_start_world($1)`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  if (Number(await one(`select game_day from public.worlds where id = $1`, [W])) === 0) await run(7);

  // ---------- D: networks sized to the world, aircraft shared ----------
  const plans = await q(`select p.route_id, p.trips, coalesce((select sum(ro.weekly_trips) from public.rotations ro where ro.route_id = p.route_id), 0)::int as flown
    from game.bot_plan p join public.airlines al on al.id = p.airline_id where al.world_id = $1`, [W]);
  ok('every computer-run route flies at least 3 round trips a week, as planned', plans.length > 20 && plans.every((x) => x.trips >= 3 && x.flown === x.trips),
    `${plans.length} routes`);
  const use = await q(`select ro.aircraft_id, count(*)::int as n, sum(ro.weekly_trips::float / game.fit_trips(ro.aircraft_id, m.km)) as u
    from public.rotations ro join public.routes r on r.id = ro.route_id join public.airlines al on al.id = r.airline_id and al.is_ai
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    where r.world_id = $1 group by ro.aircraft_id`, [W]);
  ok('aircraft are shared between routes, and none is scheduled beyond its flying window',
    use.some((x) => x.n >= 2) && use.every((x) => x.u <= 1.0001), `${use.filter((x) => x.n >= 2).length} aircraft fly two routes or more`);
  const fleet = Number(await one(`select count(*) from public.aircraft x join public.airlines al on al.id = x.airline_id and al.is_ai where al.world_id = $1`, [W]));
  const old = Number(await one(`select sum(game.bot_start_fleet($1, al.code)) from public.airlines al where al.world_id = $1 and al.is_ai`, [W]));
  const idle = Number(await one(`select count(*) from public.aircraft x join public.airlines al on al.id = x.airline_id and al.is_ai
    where al.world_id = $1 and not exists (select 1 from public.rotations ro where ro.aircraft_id = x.id)`, [W]));
  ok('whole aircraft per base: a smaller fleet for the same flights, with few idle', fleet < old && idle <= 6, `${fleet} aircraft (one route each: ${old}), ${idle} idle`);

  // ---------- E: the quarterly review, on profit ----------
  const day = 200;
  const K = await one(`select al.id from public.airlines al where al.world_id = $1 and al.code = 'KOL'`, [W]);
  const kr = await q(`select p.route_id, p.trips, p.base, p.type_id from game.bot_plan p where p.airline_id = $1 order by p.trips desc`, [K]);
  const L = kr[1], G = kr[0];
  // 28 days of results: one route losing 20%, one earning 20% at 90% full, the rest breaking even at 75%
  const fake = async (route, margin, lf) => q(`insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
      revenue_inr, var_cost_inr, aircraft_cost_inr)
    select $1, d, $2, 10, 1000, 0, round(1000 * $4::float), 0, 1000000, 1000000 * (1 - $3::float) * 0.7, 1000000 * (1 - $3::float) * 0.3
      from generate_series(${day - 27}, ${day}) d on conflict (route_id, game_day) do update
      set revenue_inr = excluded.revenue_inr, var_cost_inr = excluded.var_cost_inr, aircraft_cost_inr = excluded.aircraft_cost_inr,
          pax_econ = excluded.pax_econ, seats_econ = excluded.seats_econ`, [route, K, margin, lf]);
  await q('begin');
  for (const r of kr) await fake(r.route_id, r === L ? -0.2 : r === G ? 0.2 : 0, r === G ? 0.9 : 0.75);
  await q(`update game.bot_plan set since_day = 1 where airline_id = $1`, [K]);
  await one(`select game.bot_quarter($1, ${day})`, [W]);
  const after = Object.fromEntries((await q(`select route_id, trips from game.bot_plan where airline_id = $1`, [K])).map((x) => [x.route_id, x.trips]));
  const flownK = await q(`select p.route_id, p.trips, coalesce((select sum(ro.weekly_trips) from public.rotations ro where ro.route_id = p.route_id), 0)::int as flown
    from game.bot_plan p where p.airline_id = $1`, [K]);
  const overK = Number(await one(`select count(*) from (select ro.aircraft_id, sum(ro.weekly_trips::float / game.fit_trips(ro.aircraft_id, m.km)) u
    from public.rotations ro join public.routes r on r.id = ro.route_id join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    where r.airline_id = $1 group by 1) z where u > 1.0001`, [K]));
  await q('rollback');
  ok('a losing route loses a quarter of its flights; a full, earning one gains a quarter',
    after[L.route_id] <= Math.max(3, Math.round(L.trips * 0.75)) && after[G.route_id] === Math.ceil(G.trips * 1.25),
    `${L.trips} -> ${after[L.route_id]}, ${G.trips} -> ${after[G.route_id]}`);
  ok('after the review every route flies its plan and no aircraft is over its window',
    flownK.every((x) => x.flown === x.trips) && overK === 0);

  // spares and hand-backs: an idle aircraft the airline cannot use goes back and leaves the world; a big base keeps one spare
  await q('begin');
  const big = (await q(`select x.base_iata, x.type_id, x.biz_rows, x.biz_pitch, x.econ_pitch, x.seats_biz, x.seats_econ, count(*)::int n
    from public.aircraft x where x.airline_id = $1 group by 1, 2, 3, 4, 5, 6, 7 order by n desc limit 1`, [K]))[0];
  const add = async (type, br, bp, ep, sb, se, base, end) => one(`with a as (insert into public.aircraft (world_id, type_id, airline_id, reg, built_day,
      status, available_day, base_iata, biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
    values ($1, $2, $3, game.next_reg(), 1, 'active', 1, $4, $5, $6, $7, $8, $9) returning id)
    insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
    select id, $3, 'lease', 170000, $10, 0, 1 from a returning aircraft_id`, [W, type, K, base, br, bp, ep, sb, se, end]);
  const atr = await add('AT76', 0, null, 29, 0, 72, big.base_iata, 300);
  const spare = await add(big.type_id, big.biz_rows, big.biz_pitch, big.econ_pitch, big.seats_biz, big.seats_econ, big.base_iata, 5000);
  await one(`select game.bot_quarter($1, ${day})`, [W]);
  const st = await one(`select status from public.aircraft where id = $1`, [atr]);
  const idleBig = Number(await one(`select count(*) from public.aircraft x where x.airline_id = $1 and x.base_iata = $2 and x.type_id = $3
    and x.status = 'active' and not exists (select 1 from public.rotations ro where ro.aircraft_id = x.id)`, [K, big.base_iata, big.type_id]));
  const spareSt = await one(`select status from public.aircraft where id = $1`, [spare]);
  await q('rollback');
  ok('an aircraft the airline has no use for goes back and leaves the world; a big base keeps one spare',
    st === 'returned' && (big.n + 1 < P.bot_spare_min || (idleBig === 1 && spareSt === 'active')), `${big.n + 1} at ${big.base_iata}, ${idleBig} idle`);

  // ---------- F: fights match the market, and never below cost ----------
  await run(7);
  const w = Number(await one(`select game.week_of(game_day + 1) from public.worlds where id = $1`, [W]));
  const kroute = await q(`select r.id, least(r.origin, r.dest) a, greatest(r.origin, r.dest) b from public.routes r join game.bot_plan p on p.route_id = r.id
    where r.airline_id = $1 order by p.trips desc limit 1`, [K]);
  await q('begin');
  await q(`update public.bot_airlines set aggression = 1 where code = 'KOL'`);
  await q(`update public.route_plans set strategy = 'balanced', fight_until = null where route_id = $1`, [kroute[0].id]);
  await q(`insert into public.market_moves (world_id, a, b, week, airline_id, kind) values ($1, $2, $3, $4, $5, 'enter')`, [W, kroute[0].a, kroute[0].b, w - 1, A]);
  await q(`select game.bot_selling($1, (select game_day + 1 from public.worlds where id = $1))`, [W]);
  const answer = await one(`select strategy from public.route_plans where route_id = $1`, [kroute[0].id]);
  await q('rollback');
  ok('when a player enters, a fighting computer-run airline matches the market', answer === 'follow', answer);

  const floorCase = async (on) => {
    await q('begin');
    await q(`update public.game_params set num = $1 where key = 'bot_sell_floor_lf'`, [on ? 0.8 : 0]);
    const ref = Number(await one(`select m.ref_fare from public.routes r join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest) where r.id = $1`, [kroute[0].id]));
    const d0 = Number(await one(`select game_day from public.worlds where id = $1`, [W]));
    await q(`update public.route_plans set strategy = 'fill' where route_id = $1`, [kroute[0].id]);
    // costs that need 1.2 times the reference fare at 80% full (extras at 8%)
    await q(`insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz, revenue_inr, var_cost_inr, aircraft_cost_inr)
      select $1, d, $2, 10, 1000, 0, 700, 0, 1, $3::float * 1.2 * 0.8 * 1.08 * 1000, 0 from generate_series(${'$4'}::int - 27, $4::int) d
      on conflict (route_id, game_day) do update set seats_econ = 1000, seats_biz = 0, var_cost_inr = excluded.var_cost_inr, aircraft_cost_inr = 0`,
      [kroute[0].id, K, ref, d0]);
    await q(`select game.sell_week($1, $2)`, [W, d0 + 1]);
    const lo = Number(await one(`select min(price_e) from public.route_weeks where route_id = $1 and flown_e is null and price_e is not null`, [kroute[0].id]));
    await q('rollback');
    return lo / ref;
  };
  const [withFloor, without] = [await floorCase(true), await floorCase(false)];
  ok('computer-run airlines never sell economy below the fare that covers their costs at 80% full',
    withFloor >= 1.19 && without < 1.0, `lowest fare on sale ${without.toFixed(2)} x reference without the floor, ${withFloor.toFixed(2)} with it`);

  // ---------- G: fares follow a third of a change in fuel cost ----------
  const pr = await one(`select r.id from public.routes r where r.airline_id = $1`, [A]);
  const priced = async (fuel) => {
    await q('begin');
    await q(`update public.worlds set fuel_inr_kg = $2, fuel_avg = 100, fare_index = 1 where id = $1`, [W, fuel]);
    const d0 = Number(await one(`select game_day + 1 from public.worlds where id = $1`, [W]));
    for (let i = 0; i < 30; i++) await q(`select game.ops_week($1, $2)`, [W, d0]);
    const fi = Number(await one(`select fare_index from public.worlds where id = $1`, [W]));
    await q(`select game.sell_week($1, $2)`, [W, d0]);
    const pe = await q(`select week, price_e from public.route_weeks where route_id = $1 and flown_e is null and price_e is not null order by week`, [pr]);
    await q('rollback');
    return { fi, pe };
  };
  const hi = await priced(130), base = await priced(100);
  const expect = 1 + P.fuel_pass * P.fuel_fare_share * 0.3;
  const ratio = hi.pe.reduce((s, x, i) => s + x.price_e / base.pe[i].price_e, 0) / hi.pe.length;
  ok('fuel 30% dearer for weeks: fares about 3.8% higher (a third of the extra fuel cost a passenger)',
    Math.abs(hi.fi - expect) < 0.001 && base.fi === 1 && Math.abs(ratio - expect) < 0.01, `index ${hi.fi}, fares x ${ratio.toFixed(3)}`);

  await q(`delete from public.worlds where id = $1`, [W]);
}
