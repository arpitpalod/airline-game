// Computer-run airlines that hold their ground (migration 0029): head office that grows with the fleet, closing losing
// routes instead of thinning them, and fighting only on markets they hold.
export async function checks19(t) {
  const { q, one, ok, as, w9Params } = t;
  await as(null);
  console.log('Computer-run airlines hold their ground (0029)');
  for (const p of w9Params) await q(`update public.game_params set num = $1 where key = $2`, [p.num, p.key]);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day',
    'event_airport_prob_day', 'event_airspace_prob_day', 'late_delivery_prob', 'bot_explore_prob')`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 19', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1900' from w returning world_id`);
  const A = await one(`select public.found_airline('test1900', 'Nineteen Air', 'NT', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const day = async () => Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  if (await day() === 0) await run(7);
  await run(28);

  // ---------- head office grows with the fleet ----------
  const d = await day();
  const oh = (await q(`select c_overhead::float from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d]))[0].c_overhead;
  const p = Object.fromEntries((await q(`select key, num::float from public.game_params where key like 'overhead%' or key = 'base_fixed_inr_day'`)).map((r) => [r.key, r.num]));
  const seats = Number(await one(`select sum(seats_econ + seats_biz) from public.aircraft where airline_id = $1 and status = 'active'`, [A]));
  const want = p.overhead_fixed_inr_day * Math.max(p.overhead_min_share, 1 / p.overhead_full_fleet) + p.overhead_aircraft_inr_day + p.overhead_seat_inr_day * seats + p.base_fixed_inr_day;
  ok('a one-aircraft airline pays a quarter of the head office', Math.abs(oh - Math.round(want)) <= 1, `Rs ${oh} a day against Rs ${Math.round(want + p.overhead_fixed_inr_day * 0.75)} before`);
  const big = (await q(`select al.name, d.c_overhead::float oh, (select count(*) from public.aircraft x where x.airline_id = al.id and x.status in ('active', 'grounded', 'refit')) n
    from public.airline_daily d join public.airlines al on al.id = d.airline_id where al.world_id = $1 and al.is_ai and d.game_day = $2 order by 3 desc limit 1`, [W, d]))[0];
  ok('a big airline pays it in full', big.n >= p.overhead_full_fleet ? big.oh >= p.overhead_fixed_inr_day : big.oh > p.overhead_fixed_inr_day * p.overhead_min_share, `${big.name}, ${big.n} aircraft`);

  // ---------- concentrate instead of thinning ----------
  const top8 = (await q(`select a, b from public.markets where zone = 'india' order by n_biz + n_lei + n_bud desc limit 8`)).map((r) => `${r.a}-${r.b}`);
  const plan = await q(`select p.route_id, p.airline_id, p.trips, least(r.origin, r.dest) || '-' || greatest(r.origin, r.dest) mk
    from game.bot_plan p join public.routes r on r.id = p.route_id join public.airlines al on al.id = p.airline_id
    where al.world_id = $1 and r.status = 'open' order by al.code, p.trips desc`, [W]);
  const busy = plan.find((x) => top8.includes(x.mk) && x.trips >= 10);
  const thin = plan.find((x) => !top8.includes(x.mk) && x.airline_id === busy?.airline_id && x.route_id !== busy?.route_id);
  await q('begin');
  await q(`update game.bot_plan set since_day = -1000 where airline_id = $1`, [busy.airline_id]);   // old enough to be reviewed
  await q(`update public.route_daily set var_cost_inr = revenue_inr * 2 where route_id in ($1, $2) and game_day > $3 - 28`, [busy.route_id, thin.route_id, d]);
  await q(`select game.bot_quarter($1, $2)`, [W, d]);
  const after = Object.fromEntries((await q(`select r.id, r.status, coalesce(p.trips, 0) trips from public.routes r left join game.bot_plan p on p.route_id = r.id where r.id in ($1, $2)`, [busy.route_id, thin.route_id])).map((r) => [r.id, r]));
  await q('rollback');
  ok('a route losing heavily closes outright', after[thin.route_id].status === 'closed', `${thin.mk}, ${thin.trips} round trips a week`);
  ok('one of the eight busiest markets is only cut, to no fewer than a daily service', after[busy.route_id].status === 'open'
    && after[busy.route_id].trips === Math.max(Math.min(busy.trips, 7), Math.round(busy.trips * 0.75)), `${busy.mk}: ${busy.trips} to ${after[busy.route_id].trips}`);

  // ---------- fight only where they hold the market ----------
  const R = await one(`select public.open_route($1, 'DEL', 'BOM')`, [A]);
  const ac = await one(`select id from public.aircraft where airline_id = $1 and status = 'active' limit 1`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [A, ac, R]);
  await run(7 - (await day()) % 7);
  const w = Number(await one(`select game.week_of(game_day + 1) from public.worlds where id = $1`, [W]));
  const fights = async (share) => {
    await q('begin');
    await q(`update public.game_params set num = $1 where key = 'bot_defend_share'`, [share]);
    await q(`update public.bot_airlines set aggression = 1`);
    await q(`insert into public.market_moves (world_id, a, b, week, airline_id, kind) values ($1, 'BOM', 'DEL', $2, $3, 'enter')`, [W, w - 1, A]);
    await q(`select game.bot_selling($1, $2)`, [W, (await day()) + 1]);
    const n = Number(await one(`select count(*) from public.route_plans pl join public.routes r on r.id = pl.route_id
      where r.world_id = $1 and least(r.origin, r.dest) = 'BOM' and greatest(r.origin, r.dest) = 'DEL' and pl.fight_until is not null and r.airline_id <> $2`, [W, A]));
    await q('rollback');
    return n;
  };
  const holders = Number(await one(`select count(*) from (select r.airline_id, sum(w.seats_e + w.seats_b) s from public.route_weeks w join public.routes r on r.id = w.route_id
    where r.world_id = $1 and w.week = $2 and least(r.origin, r.dest) = 'BOM' and greatest(r.origin, r.dest) = 'DEL' group by 1) x
    where x.s >= 0.4 * (select sum(w2.seats_e + w2.seats_b) from public.route_weeks w2 join public.routes r2 on r2.id = w2.route_id
      where r2.world_id = $1 and w2.week = $2 and least(r2.origin, r2.dest) = 'BOM' and greatest(r2.origin, r2.dest) = 'DEL')`, [W, w]));
  const all = await fights(0), held = await fights(0.4), none = await fights(1.01);
  ok('a computer-run airline fights a newcomer only on a market it holds', all > 0 && held === holders && none === 0, `${all} would fight anywhere, ${held} hold 40% or more`);

  await q(`delete from public.worlds where id = $1`, [W]);
}
