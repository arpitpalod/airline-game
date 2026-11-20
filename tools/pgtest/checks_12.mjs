// Fixes from the first playtest (migration 0022): international demand grows faster, festivals and events change demand,
// routes can be planned while a world is in setup, and starting a world plays its first week at once.
export async function checks12(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Playtest fixes (0022)');
  // the values of 0022 (run.mjs set the older checks' values)
  await q(`update public.game_params set num = case key when 'growth_year_intl' then 0.12 else 1 end where key in ('growth_year_intl', 'start_first_week')`);
  await t.db.exec(`delete from public.demand_events; insert into public.demand_events select * from public.demand_events_0022;`);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'bot_explore_prob')`);
  ok('festivals and events are in a game-value table', Number(await one(`select count(*) from public.demand_events`)) === 11);

  // ---------- planning in setup ----------
  const lead = Number(await one(`select num from public.game_params where key = 'route_lead_days'`));
  await q(`update public.game_params set num = 0 where key = 'route_lead_days'`);   // so week 1 is on sale (the Goa check)
  const B = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling, bot_scale)
    values ('Test 12b', 0.02, 25, false, 0, true, 0) returning id)   -- small demand: no flight sells out, so bookings scale with demand
    insert into public.world_secrets (world_id, invite_code) select id, 'test1201' from w returning world_id`);
  const P = await one(`select public.found_airline('test1201', 'Plan Air', 'PL', 'DEL')`);
  const ac = await one(`select id from public.aircraft where airline_id = $1`, [P]);
  const bom = await one(`select public.open_route($1, 'DEL', 'BOM')`, [P]);
  const dxb = await one(`select public.open_route($1, 'DEL', 'DXB')`, [P]);
  const goi = await one(`select public.open_route($1, 'DEL', 'GOI')`, [P]);
  for (const r of [bom, dxb, goi]) await q(`select public.set_rotation($1, $2, $3, 5)`, [P, ac, r]);
  const extra = await one(`select public.open_route($1, 'DEL', 'JAI')`, [P]);
  await q(`select public.close_route($1, $2)`, [P, extra]);
  ok('in a world still in setup, routes open and close and aircraft go on them',
    Number(await one(`select count(*) from public.rotations where aircraft_id = $1`, [ac])) === 3
      && (await one(`select status from public.routes where id = $1`, [extra])) === 'closed');
  await fails('leasing still waits for the start', `select public.wet_lease('${P}', 'A20N', 'DEL')`, /not running/);
  await q(`select game.start_world($1)`, [B]);
  await q(`update public.game_params set num = $1 where key = 'route_lead_days'`, [lead]);

  // ---------- festivals and events ----------
  // one week of selling inside a transaction that is rolled back, to compare the same week with other game values
  const sell = async (before, after) => {
    await q('begin');
    try {
      if (before) await t.db.exec(before);
      await q(`select game.sell_week($1, 1)`, [B]);
      return await after();
    } finally { await q('rollback'); }
  };
  const ev = await sell(null, () => q(`select a || '-' || b k, week, fb, fl, fu from pg_temp._ev`));
  const at = (k, w) => ev.find((x) => x.k === k && x.week === w);
  const near = (x, y) => x != null && Math.abs(x - y) < 1e-6;
  ok('Holi: three of week 11\'s days raise domestic leisure demand by 3/7 of 30% and lower business demand',
    near(at('BOM-DEL', 11)?.fl, 1 + (3 * 0.3) / 7) && near(at('BOM-DEL', 11)?.fb, 1 - (3 * 0.1) / 7), JSON.stringify(at('BOM-DEL', 11)));
  ok('Eid fills the whole of week 20 on Gulf routes only', near(at('DEL-DXB', 20)?.fl, 1.5) && near(at('DEL-DXB', 20)?.fb, 1)
    && !at('BOM-DEL', 20) && !at('DEL-DXB', 11));
  ok('Christmas and New Year runs across the year end: Goa in week 1', near(at('DEL-GOI', 1)?.fl, 1 + (3 * 0.6) / 7), JSON.stringify(at('DEL-GOI', 1)));
  const bk = (route, w) => async () => (await q(`select bk_l::float l, bk_be::float b from public.route_weeks where route_id = $1 and week = $2`, [route, w]))[0];
  const withEid = await sell(null, bk(dxb, 20));
  const noEid = await sell(`delete from public.demand_events`, bk(dxb, 20));
  ok('and the extra travellers book: 50% more leisure bookings in Eid week, the same business bookings',
    noEid.l > 0 && near(withEid.l / noEid.l, 1.5) && near(withEid.b / noEid.b, 1), `${withEid.l.toFixed(2)} vs ${noEid.l.toFixed(2)}`);

  // ---------- international growth ----------
  const both = async () => ({ i: (await bk(dxb, 26)()).l, d: (await bk(bom, 26)()).l });
  const one7 = await sell(`delete from public.demand_events; update public.game_params set num = 0.07 where key = 'growth_year_intl'`, both);
  const two = await sell(`delete from public.demand_events`, both);
  const want = Math.pow(1.12 / 1.07, (25 * 7 + 3) / 364);
  ok('international demand grows 12% a game year, domestic 7%', near(two.i / one7.i, want) && near(two.d / one7.d, 1),
    `week 26: x${(two.i / one7.i).toFixed(4)} international, x${(two.d / one7.d).toFixed(4)} domestic`);
  await q(`delete from public.worlds where id = $1`, [B]);

  // ---------- the first week at the start ----------
  const A = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, prelaunch_minutes, selling)
    values ('Test 12a', 0.5, 25, false, 13, 60, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1202' from w returning world_id`);
  await one(`select public.found_airline('test1202', 'Start Air', 'SA', 'BOM')`);
  // started by a signed-in admin from the app: the week is still played as the server (the rivals act in it)
  const U = '00000000-0000-0000-0000-0000000000a1';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [U]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin', true) on conflict (user_id) do update set is_admin = true`, [U]);
  await as(U);
  await q(`select public.admin_start_world($1)`, [A]);
  await as(null);
  const s = (await q(`select w.game_day, game.due_day(w.id) due, extract(epoch from now() - w.started_at)::float secs,
      (select count(*)::int from public.airlines a where a.world_id = w.id and a.is_ai) bots,
      (select count(*)::int from public.route_weeks x where x.world_id = w.id) on_sale
    from public.worlds w where w.id = $1`, [A]))[0];
  ok('starting a world plays its first week at once: rivals and seats on sale straight away',
    s.game_day === 7 && s.bots === 6 && s.on_sale > 0, JSON.stringify(s));
  ok('and the clock stands at the end of week 1 (4.6 minutes into a one-hour pre-launch), so the scheduler waits for week 2',
    s.due === 7 && s.secs > (7 * 3600) / 91 - 2 && s.secs < (7 * 3600) / 91 + 120, `${s.secs.toFixed(0)} s`);
  await q(`delete from public.worlds where id = $1`, [A]);

  // players can read the festivals and events
  await q(`set role authenticated`);
  const seen = Number(await one(`select count(*) from public.demand_events`));
  await q(`reset role`);
  ok('players can read the festivals and events', seen === 11);
}
