// Connections (migration 0039, spec 14.31): routes sold network-based, the travellers' choice, seats, displacement,
// travellers turned away by a full nonstop, airlines outside the world, and computer-run airlines connecting.
export async function checks27(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  console.log('Connections (0039)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'event_airport_prob_day', 'event_airspace_prob_day',
    'late_delivery_prob', 'seat_limit_mult')`);
  const P = async (k) => Number(await one(`select num from public.game_params where key = $1`, [k]));
  const lam = await P('nest_lambda');
  const share = async (seg, stop) => { const x = Math.exp(-(await P(`seg_${seg}_price`)) * (await P(stop)) / lam); return 1 / (1 + x); };
  const sb = await share('biz', 'conn_stop_biz'), sl = await share('lei', 'conn_stop_lei'), su = await share('bud', 'conn_stop_bud');
  ok('at equal fares and flights the nonstop takes 19 in 20 business, 4 in 5 leisure and 7 in 10 budget travellers',
    Math.abs(sb - 0.95) < 0.01 && Math.abs(sl - 0.8) < 0.01 && Math.abs(su - 0.7) < 0.01, `${sb.toFixed(3)} ${sl.toFixed(3)} ${su.toFixed(3)}`);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 27', 0.5, 25, false, 13, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2700' from w returning world_id`);
  const A = await one(`select public.found_airline('test2700', 'Hub Air', 'HU', 'BOM')`);
  const B = await one(`select public.found_airline('test2700', 'Direct Air', 'DI', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const ac = async (al) => (await q(`select id from public.aircraft where airline_id = $1 order by reg`, [al])).map((r) => r.id);
  const open = async (al, x, y, trips, plane) => {
    const fare = Math.round(Number(await one(`select ref_fare from public.markets where a = least($1, $2) and b = greatest($1, $2)`, [x, y])));
    const r = await one(`select public.open_route($1, $2, $3, ${fare})`, [al, x, y]);
    await q(`select public.set_rotation($1, $2, $3, $4)`, [al, plane, r, trips]);
    return r;
  };
  const [a1] = await ac(A);   // each airline starts with one aircraft: it flies both routes
  const r1 = await open(A, 'BOM', 'DEL', 7, a1), r2 = await open(A, 'BOM', 'GOI', 7, a1);
  ok('Delhi-Goa exists as a market of its own, and nobody flies it', Number(await one(`select count(*) from public.markets where a = 'DEL' and b = 'GOI'`)) === 1);
  const cx = async (r) => (await q(`select coalesce(sum(bk_cx), 0)::float c, coalesce(sum(rev_cx), 0)::float v, coalesce(sum(bk_cxb), 0)::float b,
    coalesce(sum(disp), 0)::float d from public.route_weeks where route_id = $1`, [r]))[0];
  await run(7);
  ok('routes not sold network-based sell no connections', (await cx(r1)).c === 0 && (await cx(r2)).c === 0);

  await fails('a connection pays a route 50% to 100% of its fare', `select public.set_network('${A}', '${r1}', true, 0.2)`, /pays the route 50% to 100%/);
  await fails('only on your own routes', `select public.set_network('${B}', '${r1}', true)`, /not yours/);
  await as(null);
  const st = await one(`select public.set_network($1, $2, true)`, [A, r1]);
  ok('the settings: on, 80% of the fare and 30% of the seats unless changed',
    st.route_id === r1 && st.network === true && Number(st.conn_pct) === 0.8 && Number(st.conn_share) === 0.3, JSON.stringify(st));
  ok('one route alone sells no connection: both need to be network-based', await (async () => { await run(7); return (await cx(r1)).c === 0; })());
  await q(`select public.set_network($1, $2, true, 0.7, 0.4)`, [A, r2]);
  const wk = async (r, w) => (await q(`select bk_cx::float c, bk_cxb::float cb, rev_cx::float v, price_e::float pe, coalesce(price_b, 0)::float pb
    from public.route_weeks where route_id = $1 and week = $2`, [r, w]))[0];
  const b1 = await wk(r1, 20), b2 = await wk(r2, 20);
  await run(7);
  const c1 = await cx(r1), c2 = await cx(r2), e1 = await wk(r1, 20), e2 = await wk(r2, 20);
  ok('both network-based: Delhi-Goa travellers connect in Mumbai, on both routes', c1.c > 1 && Math.abs(c1.c - c2.c) < 1e-6 * c1.c,
    `${c1.c.toFixed(1)} connecting each way`);
  const part = (b, e, pct) => Math.abs((e.v - b.v) - pct * ((e.c - b.c) * e.pe + (e.cb - b.cb) * e.pb));
  ok('each route keeps its share of its own fare: 80% on Delhi, 70% on Goa', e1.c > b1.c && part(b1, e1, 0.8) < 1 && part(b2, e2, 0.7) < 1,
    `${((e1.v - b1.v) / (e1.c - b1.c)).toFixed(0)} a passenger on Delhi, fare ${e1.pe}`);

  await q(`select public.set_network($1, $2, true, null, 0)`, [A, r1]);
  await run(7);
  ok('no seats open to connections: no more connections', (await cx(r1)).c === c1.c && (await cx(r2)).c === c2.c);

  // a nonstop on the same market at the reference fare: fewer travellers connect
  await q(`select public.set_network($1, $2, true, null, 0.4)`, [A, r1]);
  const t0 = (await cx(r1)).c;
  await run(7);
  const alone = (await cx(r1)).c - t0;
  const [b1p] = await ac(B);
  await open(B, 'DEL', 'GOI', 7, b1p);
  const t1 = (await cx(r1)).c;
  await run(7);
  const vsNonstop = (await cx(r1)).c - t1;
  ok('with a nonstop on Delhi-Goa, far fewer travellers connect', alone > 0 && vsNonstop < 0.6 * alone,
    `${alone.toFixed(1)} a week alone, ${vsNonstop.toFixed(1)} against the nonstop`);

  const nearlyFull = (route, a, b, week, left) => q(`update public.route_weeks x set bk_l = x.seats_e * (1 + s.overbook * ns.v) - ${left} - x.bk_be - x.bk_u
    from public.route_plans p join public.rm_strategies s on s.key = p.strategy,
    lateral (select (m.n_biz * game.param('noshow_biz') + m.n_lei * game.param('noshow_lei') + m.n_bud * game.param('noshow_bud'))
                    / (m.n_biz + m.n_lei + m.n_bud) * exp(game.param('noshow_market_sd') * game.hash_normal('ns:' || m.a || m.b) - game.param('noshow_market_sd') ^ 2 / 2) as v
               from public.markets m where m.a = '${a}' and m.b = '${b}') ns
    where x.route_id = $1 and x.week = ${week} and p.route_id = x.route_id`, [route]);
  // travellers turned away by a full nonstop choose the connection: the nonstop's flight week 25 nearly sold out, the
  // same week of selling with and without choosing again
  const bt = await one(`select id from public.routes where airline_id = $1`, [B]);
  // the nonstop keeps a seat and a half on sale (its overbooking counted); the connection's seats are all open
  await nearlyFull(bt, 'DEL', 'GOI', 25, 1.5);
  for (const r of [r1, r2]) await q(`select public.set_network($1, $2, true, null, 1)`, [A, r]);
  const trial = async (on) => {
    await q('begin');
    await q(`update public.game_params set num = $1 where key = 'conn_recapture'`, [on]);
    const before = (await wk(r1, 25)).c;
    await run(7);
    const got = (await wk(r1, 25)).c - before;
    await q('rollback');
    return got;
  };
  const again = await trial(1), once = await trial(0);
  ok('travellers turned away by a full nonstop take the connection', again > once, `${again.toFixed(2)} against ${once.toFixed(2)}`);

  // displacement: a Delhi flight week with five seats left (its overbooking counted) and more travellers than that
  await nearlyFull(r1, 'BOM', 'DEL', 30, 5);
  await run(7);
  const d30 = Number(await one(`select disp from public.route_weeks where route_id = $1 and week = 30`, [r1]));
  ok('when a route fills, the travellers its connections displaced are counted', d30 > 0 && d30 <= 5.01, `${d30.toFixed(2)} displaced`);

  // airlines outside the world on a market with neither end in India: Kathmandu-Dubai through Delhi
  const C = await one(`select public.found_airline('test2700', 'Sixth Air', 'SX', 'DEL')`);
  ok('Dubai-Kathmandu is a market, and neither end is Indian', Number(await one(`select count(*) from public.markets where a = 'DXB' and b = 'KTM'`)) === 1);
  const [c1p] = await ac(C);
  const rx = await open(C, 'DEL', 'DXB', 7, c1p), ry = await open(C, 'DEL', 'KTM', 7, c1p);
  await q(`select public.set_network($1, $2, true, 0.8, 0.5)`, [C, rx]);
  await q(`select public.set_network($1, $2, true, 0.8, 0.5)`, [C, ry]);
  await run(7 * 11);   // to the first flights, so the new routes' weeks are on sale
  const sixth = async (on) => {
    await q('begin');
    await q(`update public.game_params set num = $1 where key = 'outside_on'`, [on]);
    const before = (await cx(rx)).c;
    await run(7);
    const got = (await cx(rx)).c - before;
    await q('rollback');
    return got;
  };
  const withOut = await sixth(1), without = await sixth(0);
  ok('the real airlines on Dubai-Kathmandu take most of its travellers', without > 0 && withOut < 0.7 * without,
    `${withOut.toFixed(1)} with them, ${without.toFixed(1)} without`);

  // computer-run airlines sell network-based from the start, and review their settings every 13 weeks
  const bots = (await q(`select count(*)::int n, count(*) filter (where p.network and p.conn_pct = 0.8 and p.conn_share = 0.3)::int net
    from public.route_plans p join public.routes r on r.id = p.route_id join public.airlines al on al.id = r.airline_id
    where r.world_id = $1 and al.is_ai and r.status = 'open'`, [W]))[0];
  ok('computer-run airlines sell every route network-based, at 80% and 30%', bots.n > 0 && bots.net === bots.n, JSON.stringify(bots));
  const br = (await q(`select r.id, r.airline_id from public.routes r join public.airlines al on al.id = r.airline_id
    where r.world_id = $1 and al.is_ai and r.status = 'open' order by r.id limit 1`, [W]))[0];
  const fake = async (from, disp, lf) => {
    await q(`insert into public.route_weeks (route_id, week, world_id, airline_id, seats_e, bk_l, rev_e, rev_cx, disp, flown_e)
      select $1, w, $2, $3, 100, 100, 500000, 1000, $4, $5 from generate_series($6::int, $6::int + 12) w`, [br.id, W, br.airline_id, disp, 100 * lf, from]);
  };
  const plan = async () => (await q(`select conn_pct::float p, conn_share::float s from public.route_plans where route_id = $1`, [br.id]))[0];
  await fake(897, 20, 1);
  await q(`select game.bot_network($1, 910)`, [W]);
  const p1 = await plan();
  await fake(988, 0, 0.5);
  await q(`select game.bot_network($1, 1001)`, [W]);
  const p2 = await plan();
  ok('a computer-run airline closes seats to connections that displace better fares, and opens more on an empty route',
    p1.s === 0.2 && p1.p === 0.85 && p2.s === 0.3 && p2.p === 0.8, `${JSON.stringify(p1)} then ${JSON.stringify(p2)}`);
  await q(`delete from public.route_weeks where route_id = $1 and week >= 897`, [br.id]);
}
