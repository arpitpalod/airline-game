// Computer-run airlines contest player routes (migration 0009). Runs in its own quiet world.
export async function checks2d(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale) values ('Test 2d', 0.5) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2d00' from w returning world_id`);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const pairRoutes = () => q(`select r.id, r.airline_id, a.is_ai, a.name, r.fare_econ::int fare, r.status, r.opened_day,
      (select count(*)::int from public.rotations ro where ro.route_id = r.id) n
    from public.routes r join public.airlines a on a.id = r.airline_id
    where r.world_id = $1 and least(r.origin, r.dest) = 'DEL' and greatest(r.origin, r.dest) = 'PAT' order by a.is_ai, a.name`, [W]);

  console.log('Computer-run airlines contest player routes (0009)');
  const P = await one(`select public.found_airline('test2d00', 'Patna Express', 'PX', 'DEL')`);
  const L = await one(`select public.found_airline('test2d00', 'Late Air', 'LT', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const ref = Number(await one(`select ref_fare from public.markets where a = 'DEL' and b = 'PAT'`));
  const R = await one(`select public.open_route($1, 'DEL', 'PAT', $2)`, [P, ref]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1), $2, 7)`, [P, R]);
  ok('no computer-run airline flies Delhi-Patna at the start', (await pairRoutes()).filter((r) => r.is_ai).length === 0);
  await run(70);
  // a second player's route opened within 28 days of the quarter end is not contested yet
  const R2 = await one(`select public.open_route($1, 'DEL', 'VNS', $2)`, [L, await one(`select ref_fare from public.markets where a = 'DEL' and b = 'VNS'`)]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1), $2, 7)`, [L, R2]);
  await run(20);
  const lf = Number(await one(`select sum(pax_econ + pax_biz)::numeric / sum(seats_econ + seats_biz) from public.route_daily where route_id = $1 and game_day > 62`, [R]));
  ok('the player fills Delhi-Patna at the reference fare', lf >= 0.85, `load ${(lf * 100).toFixed(0)}% over 28 days`);
  await run(1);   // day 91: the quarter
  const bots = (await pairRoutes()).filter((r) => r.is_ai && r.status === 'open');
  const band = bots.length ? await q(`select fare_lo::float lo, fare_hi::float hi from public.bot_airlines ba join public.airlines a on a.code = ba.code where a.id = $1`, [bots[0].airline_id]) : [];
  const want = band.length ? Math.round(Math.max(band[0].lo * ref, Math.min(band[0].hi * ref, ref * 0.95))) : -1;
  ok('at the quarter one computer-run airline starts flying it', bots.length === 1 && bots[0].n === 1, bots.map((b) => b.name).join(', '));
  ok('priced at 95% of the player fare, inside its band', bots[0]?.fare === want, `Rs ${bots[0]?.fare} against Rs ${ref}`);
  ok('and the world is told', (await one(`select count(*)::int from public.news where world_id = $1 and kind = 'route' and not private and body like '%starts flying Delhi to Patna%'`, [W])) === 1);
  ok('a route open for under 28 days is left alone',
    (await one(`select count(*)::int from public.routes r join public.airlines a on a.id = r.airline_id where r.world_id = $1 and a.is_ai and least(r.origin, r.dest) = 'DEL' and greatest(r.origin, r.dest) = 'VNS'`, [W])) === 0);
  const before = await one(`select count(*)::int from public.aircraft where world_id = $1 and status = 'pool'`, [W]);
  await run(90);
  // force the contested route to look empty, then the next quarter gives it up
  await q(`update public.route_daily set pax_econ = 0, pax_biz = 0 where route_id = $1`, [bots[0].id]);
  await run(1);   // day 182
  const after = (await pairRoutes()).find((r) => r.id === bots[0].id);
  ok('a contested route that stays empty is given up at the next quarter', after.status === 'closed' && after.n === 0);
  ok('and its aircraft goes back to the lessor pool', (await one(`select count(*)::int from public.aircraft where world_id = $1 and status = 'pool'`, [W])) > before);
  ok('with a news item', (await one(`select count(*)::int from public.news where world_id = $1 and body like '%stops flying Delhi to Patna%'`, [W])) === 1);
  ok('and no computer-run airline goes straight back in', (await pairRoutes()).filter((r) => r.is_ai && r.status === 'open').length === 0);
  ok('starting-network routes are never given up this way',
    (await one(`select count(*)::int from public.routes r join public.airlines a on a.id = r.airline_id where r.world_id = $1 and a.is_ai and r.status = 'closed' and not game.bot_entered(a.id, r.origin, r.dest)`, [W])) === 0);

  console.log('Admins set the clock (0010)');
  const d0 = Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  ok('a game day can be set to 15 minutes of real time', Number(await one(`select public.admin_set_speed($1, 15)`, [W])) === 96);
  ok('the processed day stays and nothing more falls due', Number(await one(`select game.due_day($1)`, [W])) === 7 * Math.floor(d0 / 7));
  await fails('a game week under 15 minutes is refused', `select public.admin_set_week_hours('${W}', 0.2)`, /between 15 minutes and 7 days/);
  await q(`select public.admin_pause_world($1)`, [W]);
  await q(`select public.admin_set_speed($1, 20)`, [W]);
  await q(`select public.admin_resume_world($1)`, [W]);
  ok('changing it while paused also keeps the day', Number(await one(`select game.due_day($1)`, [W])) === 7 * Math.floor(d0 / 7));
}
