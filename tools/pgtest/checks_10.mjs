// Insights (migration 0020): each flight week records its strategy; What works where by kind of sector, market shape and
// strategy; rivals' bigger moves as private news.
export async function checks10(t) {
  const { q, one, ok, as } = t;
  await as(null);
  console.log('Insights (0020)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day')`);
  await t.db.exec(`alter table public.airlines enable trigger airlines_first_flight; alter table public.aircraft enable trigger aircraft_week_start`);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 10', 0.5, 25, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1000' from w returning world_id`);
  const P1 = await one(`select public.found_airline('test1000', 'One Air', 'OA', 'DEL')`);
  const P2 = await one(`select public.found_airline('test1000', 'Two Air', 'TA', 'BOM')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const assign = async (P, a, b) => {
    const r = await one(`select public.open_route($1, $2, $3, 5000)`, [P, a, b]);
    await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1 order by reg limit 1), $2, 14)`, [P, r]);
    return r;
  };
  const r1 = await assign(P1, 'DEL', 'BOM');
  await run(35);                     // to the end of week 5
  const r2 = await assign(P2, 'BOM', 'DEL');
  await run(14);                     // week 7's selling sees Two Air's first flights next week
  const news = await q(`select airline_id, body from public.news where world_id = $1 and kind = 'rival'`, [W]);
  ok('a player hears when a rival starts flying their market', news.some((n) => n.airline_id === P1 && /Two Air starts flying (Delhi|Mumbai)/.test(n.body)),
    news.filter((n) => n.airline_id === P1).map((n) => n.body).join(' | ').slice(0, 160));
  ok('the mover and the computer-run airlines get no such news', !news.some((n) => n.airline_id === P2 && /Two Air/.test(n.body))
    && (await one(`select count(*)::int from public.news n join public.airlines a on a.id = n.airline_id where n.world_id = $1 and n.kind = 'rival' and a.is_ai`, [W])) === 0);

  await q(`select public.set_strategy($1, $2, 'top')`, [P2, r2]);
  await run(7);
  ok('a big fare change by a rival makes news too', (await one(`select count(*)::int from public.news where world_id = $1 and airline_id = $2 and kind = 'rival' and body like 'Two Air raises fares on %'`, [W, P1])) === 1);

  await run(91);
  ok('each flight week records the strategy it sold with', (await one(`select count(*)::int from public.route_weeks where route_id = $1 and flown_e is not null and strategy is null`, [r1])) === 0
    && (await one(`select strategy from public.route_weeks where route_id = $1 and flown_e is not null order by week desc limit 1`, [r2])) === 'top');
  const ins = await q(`select band, shape, strategy, routes, weeks, load::float, rev_index::float, fare_index::float from public.sector_insights where world_id = $1`, [W]);
  ok('What works where: the last 13 weeks by kind of sector, market shape and strategy', ins.length >= 4
    && ins.every((x) => x.routes >= 3 && x.load > 0 && x.load < 1.2 && x.rev_index > 0 && x.weeks <= 13 * x.routes),
    `${ins.length} cells, e.g. ${ins.slice(0, 2).map((x) => `${x.band}/${x.shape}/${x.strategy} ${x.routes} routes, load ${x.load.toFixed(2)}`).join('; ')}`);
  ok('the computer-run airlines sell in several ways, so What works where has more than one to compare',
    (await one(`select count(distinct p.strategy)::int from public.route_plans p join public.airlines a on a.id = p.airline_id where a.world_id = $1 and a.is_ai`, [W])) >= 3);
  await q(`delete from public.worlds where id = $1`, [W]);
}
