// Weeks (migration 0018): the clock in whole weeks, the pre-launch, first flight days, and the fresh Test World.
export async function checks8(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  console.log('Weeks and the pre-launch (0018)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day')`);

  for (const p of t.weekParams ?? []) await q(`update public.game_params set num = $2 where key = $1`, [p.key, p.num]);
  await t.db.exec(`alter table public.airlines enable trigger airlines_first_flight; alter table public.aircraft enable trigger aircraft_week_start`);
  ok('0018 sets the game values for weeks: wet leases in 28 days, the year from January, scheduler runs of 4 weeks',
    JSON.stringify(Object.fromEntries((await q(`select key, num::float from public.game_params where key in ('wet_lead_days', 'season_start_month', 'tick_max_days', 'late_join_days') order by key`)).map((r) => [r.key, r.num])))
      === JSON.stringify({ late_join_days: 28, season_start_month: 1, tick_max_days: 28, wet_lead_days: 28 }));
  const tw = t.freshTestWorld;   // as migration 0018 made it (run.mjs notes it, then removes it for the older checks)
  ok('a fresh Test World waits in setup: a game week in 1 hour, a 13-week pre-launch, 25 places, pilots, its own invite code',
    tw && tw.status === 'setup' && tw.speed === 168 && tw.prelaunch_weeks === 13 && tw.max_airlines === 25 && tw.pilots && /^[0-9a-f]{8}$/.test(tw.invite_code));

  // A world with the pre-launch, at the standard pace (made here: run.mjs sets older checks' worlds to no pre-launch)
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks) values ('Test 8', 0.5, 25, false, 13) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test8000' from w returning world_id`);
  ok('a new world runs a game week in 4 hours', Number(await one(`select speed from public.worlds where id = $1`, [W])) === 42);
  const P = await one(`select public.found_airline('test8000', 'Early Air', 'EA', 'DEL')`);
  ok('an airline founded before the start flies from the first flight day, day 92', (await one(`select first_flight_day from public.airlines where id = $1`, [P])) === 92);
  await q(`select public.admin_start_world($1)`, [W]);

  // The clock: the pre-launch's 91 days pass in 60 minutes, then 7 days every 4 hours; only whole weeks are due
  const due = async (secs) => {
    await q(`update public.worlds set started_at = now() - make_interval(secs => $2), paused_seconds = 0 where id = $1`, [W, secs]);
    return one(`select game.due_day($1)`, [W]);
  };
  const d30 = await due(30 * 60), d60 = await due(60 * 60), d4h = await due(60 * 60 + 4 * 3600), d5h = await due(60 * 60 + 5 * 3600);
  ok('the pre-launch passes 13 weeks in an hour, in whole weeks', d30 === 42 && d60 === 91, `${d30} after 30 minutes, ${d60} after an hour`);
  ok('then a week every 4 hours, never part of one', d4h === 98 && d5h === 98, `${d4h} after 5 hours, ${d5h} after 6`);

  // Pre-launch: nothing flies and nothing is charged; first flights on day 92
  const rt = await one(`select public.open_route($1, 'DEL', 'BOM', (select round(ref_fare)::int from public.markets where a = 'BOM' and b = 'DEL'))`, [P]);
  const wet = await one(`select id from public.aircraft where airline_id = $1 order by reg limit 1`, [P]);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [P, wet, rt]);
  await due(10 * 60);   // 15 days due: two whole weeks
  const ran = await one(`select game.tick()`);
  ok('a scheduler run processes whole weeks only', ran === 14 && (await one(`select game_day from public.worlds where id = $1`, [W])) === 14, `${ran} days`);
  const cash0 = Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [P]));
  for (let i = 0; i < 77; i++) await q(`select game.run_day($1)`, [W]);
  const pre = (await q(`select (select count(*)::int from public.route_daily rd join public.routes r on r.id = rd.route_id where r.world_id = $1) flights,
      (select count(*)::int from public.airline_daily d join public.airlines a on a.id = d.airline_id where a.world_id = $1) days,
      (select count(*)::int from public.routes where world_id = $1 and status = 'open') routes,
      (select count(*)::int from public.news where world_id = $1 and kind = 'quarter') quarters`, [W]))[0];
  ok('in the pre-launch nothing flies, nothing is charged and no quarter is reported, though every airline has its routes',
    pre.flights === 0 && pre.days === 0 && pre.routes > 10 && pre.quarters === 0, `${pre.routes} routes ready`);
  ok("the founder's cash is untouched by the pre-launch", Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [P])) === cash0);
  await q(`select game.run_day($1)`, [W]);
  const d92 = (await q(`select (select count(*)::int from public.route_daily where route_id = $2 and game_day = 92) mine,
      (select count(*)::int from public.route_daily rd join public.routes r on r.id = rd.route_id where r.world_id = $1 and rd.game_day = 92) all_,
      (select count(*)::int from public.airline_daily d join public.airlines a on a.id = d.airline_id where a.world_id = $1 and d.game_day = 92) days`, [W, rt]))[0];
  ok('on day 92 every airline flies and pays its costs', d92.mine === 1 && d92.all_ > 10 && d92.days > 6, `${d92.all_} routes flown`);

  // A late joiner flies from the start of the week four weeks on
  for (let i = 0; i < 8; i++) await q(`select game.run_day($1)`, [W]);   // day 100
  const L = await one(`select public.found_airline('test8000', 'Late Air', 'LA', 'BOM')`);
  ok('an airline founded on day 100 flies from day 134, the start of week 20', (await one(`select first_flight_day from public.airlines where id = $1`, [L])) === 134);
  const lr = await one(`select public.open_route($1, 'BOM', 'DEL', (select round(ref_fare)::int from public.markets where a = 'BOM' and b = 'DEL'))`, [L]);
  const lw = await one(`select id from public.aircraft where airline_id = $1 order by reg limit 1`, [L]);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [L, lw, lr]);
  for (let i = 0; i < 34; i++) await q(`select game.run_day($1)`, [W]);   // to day 134
  const late = (await q(`select min(game_day)::int first, count(*)::int n from public.route_daily where route_id = $1`, [lr]))[0];
  ok('and not a day before', late.first === 134 && late.n === 1, `first flown day ${late.first}`);

  // Wet leases take four weeks
  const day = await one(`select game_day from public.worlds where id = $1`, [W]);
  const wl = await one(`select public.wet_lease($1, (select type_id from public.aircraft where id = $2), 'BOM')`, [L, lw]);
  ok('a wet-leased aircraft arrives four weeks after it is ordered', wl.arrives_day === day + 1 + 28, `ordered day ${day + 1}, arrives day ${wl.arrives_day}`);
  const pool = await one(`select id from public.aircraft where world_id = $1 and status = 'pool' and type_id = 'A20N' order by available_day, reg limit 1`, [W]);
  const lz = await one(`select public.lease_aircraft($1, $2, 'BOM')`, [L, pool]);
  const arr = await one(`select available_day from public.aircraft where id = $1`, [pool]);
  ok('an aircraft from the pool arrives at the start of a week, never mid-week', arr % 7 === 1 && arr >= lz.arrives_day && arr - lz.arrives_day < 7,
    `lead time ends day ${lz.arrives_day}, arrives day ${arr}`);

  // Hours per game week, from the Admin screen (admin only; the service role counts as admin here)
  await q(`select public.admin_set_week_hours($1, 2)`, [W]);
  const w2 = (await q(`select speed::float, game.due_day(id) due, game_day from public.worlds where id = $1`, [W]))[0];
  ok('the game week can be set in hours; the clock carries on from the day reached', w2.speed === 84 && w2.due === 7 * Math.floor(w2.game_day / 7), `due ${w2.due} at day ${w2.game_day}`);
  await fails('a game week of more than 7 days is refused', `select public.admin_set_week_hours('${W}', 200)`, /between 15 minutes and 7 days/);

  // A world with its airlines, fleets and history can be deleted (the old Test World was)
  await q(`delete from public.worlds where id = $1`, [W]);
  ok('a world is deleted with everything in it', (await one(`select count(*)::int from public.airlines where world_id = $1`, [W])) === 0);
}
