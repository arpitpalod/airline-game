// Money by aircraft and by route (migration 0017), in the pilots world of checks_5.
export async function checks7(t) {
  const { q, one, ok, as } = t;
  await as(null);
  console.log('Money by aircraft and by route (0017)');
  const W = await one(`select id from public.worlds where name = 'Test 5'`);
  const P = await one(`select id from public.airlines where world_id = $1 and code = 'PL'`, [W]);
  await q(`select game.run_day($1)`, [W]);
  const d = await one(`select game_day from public.worlds where id = $1`, [W]);
  const r = (await q(`select sum(revenue_inr)::float rev, sum(var_cost_inr)::float var, sum(aircraft_cost_inr)::float acx
                        from public.route_daily where airline_id = $1 and game_day = $2`, [P, d]))[0];
  const a = (await q(`select sum(revenue_inr)::float rev, sum(flying_cost_inr)::float fly, sum(aircraft_cost_inr) filter (where flights > 0)::float acx,
                             count(*)::int n from public.aircraft_daily where airline_id = $1 and game_day = $2`, [P, d]))[0];
  const fleet = await one(`select count(*)::int from public.aircraft where airline_id = $1 and status in ('active', 'grounded', 'refit')`, [P]);
  ok('every aircraft in service gets a row each day', a.n === fleet, `${a.n} aircraft`);
  ok('aircraft revenue adds up to route revenue', Math.abs(a.rev - r.rev) <= a.n, `Rs ${Math.round(a.rev)} against Rs ${Math.round(r.rev)}`);
  ok('aircraft flying costs add up to route flying costs', Math.abs(a.fly - r.var) <= a.n);
  ok('the aircraft cost routes carry adds up to the holding cost of the aircraft that flew', Math.abs(a.acx - r.acx) <= a.n);
  const lease = (await q(`select ad.aircraft_cost_inr::float c, tm.lease_usd_month::float m, w.fx_inr_usd::float fx, ac.seats_econ + ac.seats_biz seats
       from public.aircraft_daily ad join public.aircraft_terms tm on tm.aircraft_id = ad.aircraft_id join public.aircraft ac on ac.id = ad.aircraft_id
       join public.worlds w on w.id = $3 where ad.airline_id = $1 and ad.game_day = $2 and tm.holding = 'lease' limit 1`, [P, d, W]))[0];
  ok("a leased aircraft's holding cost is its rent and its cabin crew's base pay",
    Math.abs(lease.c - (lease.m * lease.fx / 30.33 + Math.ceil(lease.seats / 50) * 10000)) <= 1, `Rs ${Math.round(lease.c)} a day`);
}
