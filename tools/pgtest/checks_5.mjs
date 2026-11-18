// Pilots (migration 0013). Runs in its own world with pilots on and the computer-run airlines at full scale.
export async function checks5(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'pilot_quit_year')`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots) values ('Test 5', 0.5, 25, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test5000' from w returning world_id`);
  const found = (name, code) => one(`select public.found_airline('test5000', $1, $2, 'DEL')`, [name, code]);
  const P = await found('Pilot Air', 'PL'), Q = await found('Thin Crew', 'TC');
  await q(`select public.admin_start_world($1)`, [W]);
  const day = () => one(`select game_day from public.worlds where id = $1`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const crew = (a, f = 'A320') => q(`select captains, fos, expats, need from public.airline_pilots where airline_id = $1 and family = $2`, [a, f]).then((r) => r[0] ?? { captains: 0, fos: 0, expats: 0, need: 0 });
  const market = () => q(`select captains::float c, fos::float f, pay_index::float idx from public.pilot_market where world_id = $1 and family = 'A320'`, [W]).then((r) => r[0]);

  console.log('Pilots (0013)');
  await run(1);
  const m0 = await market();
  ok('the world market opens with 2.5 times its target of pilots per place', Math.abs(m0.c - 20 * 25 * 2.5) < 5 && Math.abs(m0.f - 30 * 25 * 2.5) < 8,
    `${Math.round(m0.c)} A320 captains, ${Math.round(m0.f)} first officers for 25 places`);
  const bots = await q(`select sum(ap.captains)::int c, sum(ap.need)::int n, sum(d.cancelled)::float x, sum(d.flights)::float fl
    from public.airlines al join public.airline_pilots ap on ap.airline_id = al.id
    join public.airline_daily d on d.airline_id = al.id and d.game_day = 1 where al.world_id = $1 and al.is_ai`, [W]);
  ok('computer-run airlines start with crews for their fleets and cancel nothing', bots[0].c >= bots[0].n && bots[0].n > 0 && bots[0].x === 0,
    `${bots[0].c} captains for a need of ${bots[0].n}`);
  const wet = await crew(P);
  ok('a new airline flying only its wet-leased aircraft needs no pilots', wet.need === 0 && wet.captains === 0);

  // P leases two A320neos; crews are hired from the market ahead of their arrival
  const pool = (await q(`select id from public.aircraft where world_id = $1 and status = 'pool' and type_id = 'A20N' order by built_day desc limit 4`, [W])).map((r) => r.id);
  for (const id of pool.slice(0, 2)) await q(`select public.lease_aircraft($1, $2, 'DEL')`, [P, id]);
  const arrive = await one(`select max(available_day) from public.aircraft where airline_id = $1 and status = 'delivering'`, [P]);
  await run(1);
  const c1 = await crew(P);
  const hires = await q(`select rank, sum(n)::int n, min(due_day) due from public.pilot_moves where airline_id = $1 and kind = 'hire' group by rank order by rank`, [P]);
  ok('leasing aircraft makes the airline hire crews from the market, to join in 28 days',
    c1.need === Math.ceil(2 * 17 * 0.7 / 2.4 * 1.15) && hires.length === 2 && hires[0].n === Math.ceil(c1.need * 1.1) && hires[0].due === (await day()) + 28,
    `need ${c1.need} of each rank for 2 aircraft planned at 70% of their flying day; ${hires[0].n} captains join on day ${hires[0].due}, aircraft on day ${arrive}`);
  const m1 = await market();
  ok('and the market has that many fewer pilots', m1.c < m0.c - hires[0].n + 5);

  // P flies them: no cancellations, and salaries replace the old flat cost per aircraft
  await run(arrive - (await day()));
  const ac = (await q(`select id from public.aircraft where airline_id = $1 and type_id = 'A20N' and status = 'active' order by reg`, [P])).map((r) => r.id);
  const rP = await one(`select public.open_route($1, 'DEL', 'BOM', 6000)`, [P]);
  for (const id of ac) await q(`select public.set_rotation($1, $2, $3, 21)`, [P, id, rP]);
  await run(1);
  const dP = (await q(`select flights::float, cancelled::float, c_crew::float from public.airline_daily where airline_id = $1 and game_day = $2`, [P, await day()]))[0];
  const c2 = await crew(P);
  ok('a fully crewed airline flies every flight', dP.cancelled === 0 && dP.flights > 0, `${c2.captains} captains, ${c2.fos} first officers, need ${c2.need}`);
  const pay = await q(`select pay_index::float idx from public.pilot_market where world_id = $1 and family = 'A320'`, [W]);
  const sal = pay[0].idx * (c2.captains * 17800 + c2.fos * 8100);
  const flying = await one(`select sum(2 * ro.weekly_trips / 7.0 * (m.km::numeric / t.cruise_kmh + t.block_offset_h) * (t.pilot_inr_bh + 4 * 600))::float
     from public.rotations ro join public.aircraft x on x.id = ro.aircraft_id join public.aircraft_types t on t.id = x.type_id
     join public.aircraft_terms tm on tm.aircraft_id = x.id and tm.holding <> 'wet'
     join public.routes r on r.id = ro.route_id join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest) where x.airline_id = $1`, [P]);
  ok('pilot salaries replace the flat pilot cost per aircraft', Math.abs(dP.c_crew - (sal + flying + 2 * 4 * 10000)) < 0.02 * dP.c_crew,
    `crew cost ${Math.round(dP.c_crew)}, of which salaries ${Math.round(sal)} (flat cost was ${2 * 190000})`);

  ok('every airline takes foreign captains as the last resort unless the engine is told otherwise',
    (await one(`select bool_and(pilot_expats) from public.airline_finance where airline_id in ($1, $2)`, [P, Q])) === true);
  // Q leases two as well but the market has no captains left (and, for this test, no foreign captains): it hires
  // first officers, promotes a few, and is short
  await q(`select public.set_pilot_policy($1, 1, 0.1, 0, false)`, [Q]);
  await q(`update public.game_params set num = 0 where key = 'pilot_pool_in_qtr'`);
  await q(`update public.pilot_market set captains = 0 where world_id = $1 and family = 'A320'`, [W]);
  for (const id of pool.slice(2, 4)) await q(`select public.lease_aircraft($1, $2, 'DEL')`, [Q, id]);
  const arriveQ = await one(`select max(available_day) from public.aircraft where airline_id = $1 and status = 'delivering'`, [Q]);
  await q(`update public.pilot_market set captains = 0 where world_id = $1 and family = 'A320'`, [W]);
  await run(arriveQ - (await day()));
  await q(`update public.pilot_market set captains = 0 where world_id = $1 and family = 'A320'`, [W]);
  const acQ = (await q(`select id from public.aircraft where airline_id = $1 and type_id = 'A20N' and status = 'active' order by reg`, [Q])).map((r) => r.id);
  const rQ = await one(`select public.open_route($1, 'DEL', 'BLR', 7000)`, [Q]);
  for (const id of acQ) await q(`select public.set_rotation($1, $2, $3, 14)`, [Q, id, rQ]);
  await q(`update public.pilot_market set captains = 0 where world_id = $1 and family = 'A320'`, [W]);
  await run(1);
  const cQ = await crew(Q);
  const dQ = (await q(`select flights::float, cancelled::float from public.airline_daily where airline_id = $1 and game_day = $2`, [Q, await day()]))[0];
  const upg = await one(`select coalesce(sum(n), 0)::int from public.pilot_moves where airline_id = $1 and kind = 'upgrade'`, [Q]);
  ok('with no captains in the market an airline cannot crew its aircraft and cancels flights', cQ.captains < cQ.need && dQ.cancelled > 0,
    `${cQ.captains} captains for a need of ${cQ.need}: ${dQ.cancelled} of ${dQ.flights + dQ.cancelled} flights cancelled`);
  ok('it puts first officers into command training, a few a quarter', upg > 0 && upg <= Math.floor(cQ.fos * 0.1) + 1, `${upg} in training`);
  await fails('pay outside 0.8 to 1.5 times the market is refused', `select public.set_pilot_policy('${Q}', 2, 0.1, 0, true)`, /between 0.8 and 1.5/);
  await q(`select public.set_pilot_policy($1, 1, 0.1, 0, true)`, [Q]);
  await run(1);
  const ex = await q(`select sum(n)::int n, min(due_day) due from public.pilot_moves where airline_id = $1 and kind = 'expat'`, [Q]);
  ok('allowing foreign captains fills the gap in 56 days', ex[0].n > 0 && ex[0].due === (await day()) + 56, `${ex[0].n} foreign captains join on day ${ex[0].due}`);
  await q(`update public.pilot_market set captains = 0 where world_id = $1 and family = 'A320'`, [W]);
  await run(56);
  await q(`update public.game_params set num = 0.25 where key = 'pilot_pool_in_qtr'`);
  const cQ2 = await crew(Q);
  const dQ2 = (await q(`select cancelled::float from public.airline_daily where airline_id = $1 and game_day = $2`, [Q, await day()]))[0];
  ok('once they join the airline flies everything again, paying them 1.8 times the market', cQ2.expats > 0 && dQ2.cancelled === 0, `${cQ2.expats} foreign captains`);

  // resignations: P pays 0.8 of the market while Q pays 1.2
  await q(`select public.set_pilot_policy($1, 0.8, 0.1, 0, false)`, [P]);
  await q(`select public.set_pilot_policy($1, 1.2, 0.1, 0, true)`, [Q]);
  await q(`update public.game_params set num = 8 where key = 'pilot_quit_year'`);
  await run(3);
  await q(`update public.game_params set num = 0 where key = 'pilot_quit_year'`);
  const lv = async (a) => q(`select rank, sum(n)::int n, min(due_day - start_day) notice from public.pilot_moves where airline_id = $1 and kind = 'leave' group by rank order by rank`, [a]);
  const lP = await lv(P), lQ = await lv(Q);
  const nP = lP.reduce((s, r) => s + r.n, 0), nQ = lQ.reduce((s, r) => s + r.n, 0);
  ok('pilots paid below a rival resign far more often', nP > 3 * Math.max(1, nQ), `${nP} resignations at 0.8x pay against ${nQ} at 1.2x`);
  ok('captains serve 364 days of notice, first officers 182', lP.every((r) => r.notice === (r.rank === 'c' ? 364 : 182)));
  ok('and the airline hears about it', (await one(`select count(*)::int from public.news where airline_id = $1 and kind = 'pilots'`, [P])) > 0);

  // cadets, surplus, duty-time rules
  await q(`select public.set_pilot_policy($1, 1, 0.1, 30, false)`, [P]);
  const cash0 = Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [P]));
  await run(10);
  const cad = await q(`select sum(n)::int n, min(due_day - start_day) days from public.pilot_moves where airline_id = $1 and kind = 'cadet'`, [P]);
  ok('cadets start through the quarter and become first officers after 364 days', cad[0].n >= 2 && cad[0].n <= 4 && cad[0].days === 364, `${cad[0].n} cadets in 10 days at 30 a quarter`);
  ok('each costs Rs 30 lakh of training', (await one(`select -sum(amount_inr)::float from public.transactions where airline_id = $1 and kind = 'training' and note like 'Training for%'`, [P])) === cad[0].n * 3000000);
  await q(`update public.airline_pilots set captains = captains + 40 where airline_id = $1 and family = 'A320'`, [P]);
  const mk1 = await market();
  await run(1);
  const sev = await one(`select -sum(amount_inr)::float from public.transactions where airline_id = $1 and kind = 'severance'`, [P]);
  const cP3 = await crew(P);
  ok('pilots far above need are let go with 91 days of pay and go back to the market',
    sev > 0 && cP3.captains - (await one(`select coalesce(sum(n), 0)::int from public.pilot_moves where airline_id = $1 and kind = 'leave' and rank = 'c' and not done`, [P]))
      <= Math.ceil(cP3.need * 1.1 * 1.25) && (await market()).c > mk1.c + 20, `severance Rs ${(sev / 1e5).toFixed(1)} lakh`);
  await q(`update public.game_params set num = 1 where key = 'event_duty_prob_day'`);
  await run(1);
  await q(`update public.game_params set num = 0 where key = 'event_duty_prob_day'`);
  const ev = (await q(`select announced_day, starts_day from public.events where world_id = $1 and kind = 'duty_rules'`, [W]))[0];
  ok('the regulator announces stricter duty-time rules 91 days ahead', ev && ev.starts_day === ev.announced_day + 91);
  ok('from then each pilot flies 10% fewer hours', Number(await one(`select game.pilot_bh($1, $2)`, [W, ev.starts_day])) === 2.16
    && Number(await one(`select game.pilot_bh($1, $2)`, [W, ev.starts_day - 1])) === 2.4);
  ok('and only once a season', (await run(1), await one(`select count(*)::int from public.events where world_id = $1 and kind = 'duty_rules'`, [W])) === 1);

  // places: demand, pools and pilots grow together
  const mk2 = await market();
  await q(`select public.admin_set_places($1, 30)`, [W]);
  const w2 = (await q(`select max_airlines, demand_scale::float from public.worlds where id = $1`, [W]))[0];
  ok('more places raise demand and add pilots to the market at once', w2.max_airlines === 30 && w2.demand_scale === 0.6 && Math.abs((await market()).c - mk2.c - 100) < 1);
  await fails('once running, places only go up', `select public.admin_set_places('${W}', 20)`, /only go up/);
}
