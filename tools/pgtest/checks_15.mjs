// Disruptions per world and random but profitable fights (migration 0025).
export async function checks15(t) {
  const { q, one, ok, as, z5Params } = t;
  await as(null);
  console.log('Disruptions per world, fights (0025)');
  for (const p of z5Params) await q(`update public.game_params set num = $1 where key = $2`, [p.num, p.key]);
  ok('currency swings by default about once in three years', Number(await one(`select num from public.game_params where key = 'event_fx_prob_day'`)) === 0.001);
  // random parts off for the game as a whole: only a world's own values switch them on
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day')`);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 15', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1500' from w returning world_id`);
  const W2 = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 15b', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1501' from w returning world_id`);

  // ---------- 1. the admin sets a world's disruptions ----------
  const ADM = '00000000-0000-0000-0000-0000000015a1', PL = '00000000-0000-0000-0000-0000000015b1';
  await q(`insert into auth.users (id) values ($1), ($2) on conflict do nothing`, [ADM, PL]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 15', true), ($2, 'Player 15', false)
    on conflict (user_id) do update set is_admin = excluded.is_admin`, [ADM, PL]);
  await as(PL);
  let refused = '';
  try { await q(`select public.admin_set_disruptions($1, '{"event_fx_prob_day": 0.01}')`, [W]); } catch (e) { refused = e.message; }
  await as(ADM);
  const set = await one(`select public.admin_set_disruptions($1, $2)`, [W, JSON.stringify({ event_fx_prob_day: 12 / 364, ground_prob_day: 0.01, event_fuel_mult_max: 1.8 })]);
  const own = Number(await one(`select game.wparam($1, 'event_fx_prob_day')`, [W]));
  const other = Number(await one(`select game.wparam($1, 'event_fx_prob_day')`, [W2]));
  ok('only an admin sets disruptions, and only for that world', refused !== '' && Math.abs(own - 12 / 364) < 1e-9 && other === 0
    && Number(set.event_fuel_mult_max) === 1.8);
  const bad = async (v) => { try { await q(`select public.admin_set_disruptions($1, $2)`, [W, JSON.stringify(v)]); return ''; } catch (e) { return e.message; } };
  const tooOften = await bad({ event_fuel_prob_day: 0.05 }), upside = await bad({ event_fx_mult_min: 1.3, event_fx_mult_max: 1.1 });
  ok('more than once a month, or a lowest above its highest, is refused', /from/.test(tooOften) && /lowest/.test(upside), tooOften);
  await q(`select public.admin_set_disruptions($1, '{"ground_prob_day": null}')`, [W]);
  ok('a value set to null goes back to the game default', Number(await one(`select game.wparam($1, 'ground_prob_day')`, [W])) === 0);
  await as(null);
  let seen = null;
  try {
    await q('begin');
    await q(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: PL, role: 'authenticated' })]);
    await q('set local role authenticated');
    seen = Number(await one(`select count(*) from public.world_params`));
  } catch (e) { seen = e.message; }
  await q('rollback');
  await as(null);
  ok('players cannot see a world\'s disruption values', seen === 0, String(seen));

  // ---------- the engine follows each world's values ----------
  await q('begin');
  await q(`select setseed(0.3)`);
  for (let d = 1; d <= 364; d++) await q(`select game.day_world($1, $2)`, [W, d]);
  await q(`update public.world_params set num = $2 where world_id = $1 and key = 'event_fx_prob_day'`, [W, 0]);
  const fx = await q(`select starts_day, ends_day from public.events where world_id = $1 and kind = 'fx_swing' order by starts_day`, [W]);
  const fx2 = Number(await one(`select count(*) from public.events where world_id = $1 and kind = 'fx_swing'`, [W2]));
  await q('rollback');
  const noOverlap = fx.every((e, i) => i === 0 || e.starts_day > fx[i - 1].ends_day);
  ok('currency swings at most once a month in that world, one at a time; none in the other', fx.length >= 2 && noOverlap && fx2 === 0,
    `${fx.length} swings in a year`);

  // ---------- 2. fights: random, never below cost plus 5% ----------
  const A = await one(`select public.found_airline('test1500', 'Fifteen Air', 'FT', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  if (Number(await one(`select game_day from public.worlds where id = $1`, [W])) === 0) await run(7);
  const kr = (await q(`select r.id, r.origin, r.dest, least(r.origin, r.dest) a, greatest(r.origin, r.dest) b, m.ref_fare::float ref
    from public.routes r join public.airlines al on al.id = r.airline_id and al.is_ai
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    where r.world_id = $1 and r.status = 'open' and 'DEL' in (r.origin, r.dest) and not m.intl order by m.km limit 1`, [W]))[0];
  const far2 = kr.origin === 'DEL' ? kr.dest : kr.origin;
  const pr = await one(`select public.open_route($1, 'DEL', $2)`, [A, far2]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1 limit 1), $2, 7)`, [A, pr]);
  await q(`select public.set_strategy($1, $2, 'top')`, [A, pr]);
  await run(7);
  await q('begin');
  await q(`select setseed(0.4)`);
  await q(`insert into public.world_params (world_id, key, num) values ($1, 'event_engine_prob_day', 0.03)`, [W]);
  for (let d = 20; d <= 383; d++) await q(`select game.day_world($1, $2)`, [W, d]);
  const en = await q(`select starts_day, ends_day from public.events where world_id = $1 and kind = 'engine_grounding' order by starts_day`, [W]);
  await q('rollback');
  ok('engine events no longer pile up: one at a time', en.length >= 2 && en.every((e, i) => i === 0 || e.starts_day > en[i - 1].ends_day), `${en.length} in a year`);

  const fight = async (pos, floorMult) => {
    await q('begin');
    const d0 = Number(await one(`select game_day from public.worlds where id = $1`, [W]));
    const w = Number(await one(`select game.week_of($1)`, [d0 + 1]));
    await q(`update public.route_plans set strategy = 'follow', fight_until = $2, fight_pos = $3 where route_id = $1`, [kr.id, w + 8, pos]);
    // the bot route's costs: floorMult times the reference fare at 80% full, extras at 8%
    await q(`insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz, revenue_inr, var_cost_inr, aircraft_cost_inr)
      select $1, d, (select airline_id from public.routes where id = $1), 10, 1000, 0, 700, 0, 1, $2::float * $3::float * 0.8 * 1.08 * 1000, 0
        from generate_series($4::int - 27, $4::int) d
      on conflict (route_id, game_day) do update set seats_econ = 1000, seats_biz = 0, var_cost_inr = excluded.var_cost_inr, aircraft_cost_inr = 0`,
      [kr.id, kr.ref, floorMult, d0]);
    await q(`select game.sell_week($1, $2)`, [W, d0 + 1]);
    const rows = await q(`select b.week, b.price_e::float bot, p.price_e::float pl from public.route_weeks b
      join public.route_weeks p on p.route_id = $2 and p.week = b.week
      where b.route_id = $1 and b.flown_e is null and b.price_e is not null and p.price_e is not null order by b.week`, [kr.id, pr]);
    await q('rollback');
    return rows;
  };
  const fp = (m) => m * kr.ref * 1.05;
  const near = await fight(0, 0.9), mid = await fight(0.5, 0.9), far = await fight(1, 0.9), held = await fight(0.5, 1.6);
  const within = (r, pos, m) => r.length > 5 && r.every((x) => {
    const lo = fp(m), want = x.pl >= lo ? lo + pos * (x.pl - lo) : lo;
    return Math.abs(x.bot - Math.min(want, 1.9 * kr.ref)) <= 10;
  });
  ok('a fight prices at its drawn point between cost plus 5% and the player\'s fare',
    within(near, 0, 0.9) && within(mid, 0.5, 0.9) && within(far, 1, 0.9),
    `week ${mid[0]?.week}: player ${mid[0]?.pl}, bot ${near[0]?.bot} / ${mid[0]?.bot} / ${far[0]?.bot}`);
  ok('below its profitable lowest fare it holds there and lets the player lose alone',
    held.length > 5 && held.every((x) => x.bot >= Math.min(fp(1.6), 1.9 * kr.ref) - 10), `bot ${held[0]?.bot}, player ${held[0]?.pl}`);

  // a fight draws its point when it starts, and clears it when it ends
  await q('begin');
  const w = Number(await one(`select game.week_of(game_day + 1) from public.worlds where id = $1`, [W]));
  await q(`update public.bot_airlines set aggression = 1 where code = (select code from public.airlines a join public.routes r on r.airline_id = a.id where r.id = $1)`, [kr.id]);
  await q(`update public.route_plans set strategy = 'balanced', fight_until = null, fight_pos = null where route_id = $1`, [kr.id]);
  await q(`insert into public.market_moves (world_id, a, b, week, airline_id, kind) values ($1, $2, $3, $4, $5, 'enter')`, [W, kr.a, kr.b, w - 1, A]);
  await q(`select game.bot_selling($1, (select game_day + 1 from public.worlds where id = $1))`, [W]);
  const drawn = await q(`select strategy, fight_pos::float from public.route_plans where route_id = $1`, [kr.id]);
  await q(`update public.route_plans set fight_until = $2 where route_id = $1`, [kr.id, w]);
  await q(`select game.bot_selling($1, (select game_day + 1 from public.worlds where id = $1))`, [W]);
  const after = await q(`select fight_until, fight_pos from public.route_plans where route_id = $1`, [kr.id]);
  await q('rollback');
  ok('a fight draws its point when it starts and clears it when it ends',
    drawn[0].strategy === 'follow' && drawn[0].fight_pos >= 0 && drawn[0].fight_pos <= 1 && after[0].fight_until === null && after[0].fight_pos === null,
    `drawn ${drawn[0].fight_pos?.toFixed(2)}`);

  await q(`delete from public.worlds where id in ($1, $2)`, [W, W2]);
}
