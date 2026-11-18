// Bulk orders and leases, and extras (migration 0011). Runs in its own quiet world.
export async function checks3(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale) values ('Test 3', 0.5) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test3000' from w returning world_id`);
  const found = (name, code) => one(`select public.found_airline('test3000', $1, $2, 'DEL')`, [name, code]);
  const X = await found('Extras Free', 'XF'), Y = await found('Extras Paid', 'XP');
  await q(`select public.admin_start_world($1)`, [W]);
  const near = (a, b) => Math.abs(a - b) < 1e-6;

  console.log('Bulk orders and leases (0011)');
  const pool = (await q(`select id from public.aircraft where world_id = $1 and status = 'pool' and type_id = 'A20N' order by built_day desc limit 7`, [W])).map((r) => r.id);
  const lz = await one(`select public.lease_aircraft_bulk($1, $2::uuid[], 'DEL')`, [X, `{${pool.slice(0, 3).join(',')}}`]);
  ok('three aircraft leased from the pool in one go', lz.length === 3
    && (await one(`select count(*)::int from public.aircraft where airline_id = $1 and status = 'delivering'`, [X])) === 3);
  await fails('more than the pool limit allows is refused, saying how many are left',
    `select public.lease_aircraft_bulk('${X}', '{${pool.slice(3, 7).join(',')}}'::uuid[], 'DEL')`, /you can lease 3 more now/);
  ok('and none of them is leased', (await one(`select count(*)::int from public.aircraft where id = any($1::uuid[]) and status = 'pool'`, [`{${pool.slice(3, 7).join(',')}}`])) === 4);
  await q(`select public.borrow($1, 2000000000)`, [Y]);
  const od = await one(`select public.order_aircraft_bulk($1, 'A20N', 'DEL', 3, 0, null, 29, 'loan')`, [Y]);
  const days = od.map((o) => o.arrives_day);
  ok('three new aircraft ordered in one go', od.length === 3 && days.every((d, i) => i === 0 || d >= days[i - 1]), `arrive on days ${days.join(', ')}`);
  ok('each with its own deposit', (await one(`select count(*)::int from public.transactions where airline_id = $1 and kind = 'deposit'`, [Y])) === 3);
  await fails('more than ten in one order is refused', `select public.order_aircraft_bulk('${Y}', 'A20N', 'DEL', 11, 0, null, 29, 'cash')`, /between 1 and 10/);

  console.log('Extras (0011)');
  const terms = (a) => q(`select d_biz::float, d_lei::float, d_bud::float, yield::float, cost::float from game.anc_terms($1)`, [a]).then((r) => r[0]);
  const t0 = await terms(Y);
  ok('by default every extra is sold at its reference price: no change to the fare travellers see',
    t0.d_biz === 0 && t0.d_lei === 0 && t0.d_bud === 0 && t0.cost === 0 && near(t0.yield, 0.0956), `extras ${(t0.yield * 100).toFixed(2)}% of the reference fare a passenger`);
  await q(`select public.set_extras($1, '{"meal": {"included": true}, "bag": {"mult": 1.5}}')`, [Y]);
  const t1 = await terms(Y);
  ok('a dearer bag and a free meal change perceived fares, revenue and cost as set out',
    near(t1.d_lei, 0.5 * 0.17 * 0.5 - 0.3 * 0.06) && near(t1.cost, 0.04 * 0.85)
    && near(t1.yield, 0.17 * 1.5 * 0.35 * Math.exp(-0.6 * 0.5) + 0.06 * 0.30 + 0.07 * 0.07), `yield ${(t1.yield * 100).toFixed(2)}%`);
  await fails('prices outside 0.25 to 3 times the reference are refused', `select public.set_extras('${Y}', '{"seat": {"mult": 5}}')`, /between 0.25 and 3/);
  await fails('unknown extras are refused', `select public.set_extras('${Y}', '{"lounge": {"included": true}}')`, /Unknown extra/);
  await q(`select public.set_extras($1, '{"meal": {"included": false, "mult": 1}, "bag": {"mult": 1}}')`, [Y]);
  await q(`select public.set_extras($1, '{"bag": {"included": true}, "seat": {"included": true}, "meal": {"included": true}, "priority": {"included": true}}')`, [X]);

  // the same aircraft, fare and schedule on a thin route: everything included draws more travellers, earns no extras and costs more
  const mk = await q(`select a, b, ref_fare::float ref from public.markets m join public.airports ap on ap.iata = case when m.a = 'DEL' then m.b else m.a end
    where 'DEL' in (m.a, m.b) and not m.intl and ap.runway_class >= 2 and (m.n_biz + m.n_lei + m.n_bud) * 0.5 between 120 and 220
    and not exists (select 1 from public.bot_network n where least(n.origin, n.dest) = m.a and greatest(n.origin, n.dest) = m.b)
    order by (m.n_biz + m.n_lei + m.n_bud) desc limit 1`);
  const dest = mk[0].a === 'DEL' ? mk[0].b : mk[0].a;
  const rt = {};
  for (const al of [X, Y]) {
    rt[al] = await one(`select public.open_route($1, 'DEL', $2, $3)`, [al, dest, mk[0].ref]);
    await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1 and status = 'active' order by reg limit 1), $2, 7)`, [al, rt[al]]);
  }
  await q(`select game.run_day($1)`, [W]);
  const d = await one(`select game_day from public.worlds where id = $1`, [W]);
  const rd = async (al) => (await q(`select pax_econ, revenue_inr::float rev, var_cost_inr::float var from public.route_daily where route_id = $1 and game_day = $2`, [rt[al], d]))[0];
  const rx = await rd(X), ry = await rd(Y);
  ok('with every extra included an airline carries more travellers at the same fare', rx.pax_econ > ry.pax_econ, `DEL-${dest}: ${rx.pax_econ} against ${ry.pax_econ}`);
  ok('earns no extras revenue on them', rx.rev === rx.pax_econ * mk[0].ref);
  ok('while the one selling extras earns them on top of the fare', ry.rev === Math.round(ry.pax_econ * mk[0].ref * (1 + t0.yield)));
}
