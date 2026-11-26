// Stage 2c: computer-run airlines and tuning (open items 7 to 13). Runs in a second, quiet world.
export async function checks2c(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'fuel_vol_day', 'fx_vol_day', 'fx_drift_year', 'event_fuel_prob_day',
    'event_fx_prob_day', 'event_engine_prob_day', 'ground_prob_day')`);
  await q(`update public.game_params set num = 1 where key = 'starter_aircraft'`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale) values ('Test 2c', 0.5) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2c00' from w returning world_id`);
  const found = (name, code, base) => one(`select public.found_airline('test2c00', $1, $2, $3)`, [name, code, base]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const day = () => one(`select game_day from public.worlds where id = $1`, [W]);
  const ref = (a, b) => one(`select ref_fare from public.markets where a = least($1, $2) and b = greatest($1, $2)`, [a, b]);
  const acOf = (al) => one(`select id from public.aircraft where airline_id = $1 order by reg limit 1`, [al]);
  const rd = (route, d) => q(`select flights::float, seats_econ, seats_biz, pax_econ, pax_biz, spill from public.route_daily where route_id = $1 and game_day = $2`, [route, d]).then((r) => r[0]);

  console.log('Stage 2c: founding, reference fares, overheads (items 8, 13)');
  ok('reference fare is Rs 2,100 + 3.3 a km: Delhi-Mumbai Rs 5,850', (await ref('DEL', 'BOM')) === 5850);
  const P = await found('Starter Air', 'STA', 'DEL');
  const st = (await q(`select a.type_id, a.status, a.available_day, a.seats_econ, t.holding, t.deposit_inr::float dep, t.wet_usd_bh::float rate
    from public.aircraft a join public.aircraft_terms t on t.aircraft_id = a.id where a.airline_id = $1`, [P]));
  ok('a new airline gets one wet-leased A320neo, flying on its first day, with no deposit', st.length === 1 && st[0].type_id === 'A20N'
    && st[0].status === 'active' && st[0].available_day === 1 && st[0].seats_econ === 180 && st[0].holding === 'wet' && st[0].dep === 0,
    `$${st[0]?.rate} a block hour`);
  ok('at the normal wet-lease rate', st[0].rate === Number(await one(`select game.wet_rate_usd($1, 'A20N')`, [W])));
  const PT = await found('Turbo Air', 'TRB', 'KUU');
  ok('a base with a turboprop runway gets an ATR instead', (await one(`select type_id from public.aircraft where airline_id = $1`, [PT])) === 'AT76');
  ok('and the airline is told in a private notice', (await one(`select count(*)::int from public.news where airline_id = $1 and private and kind = 'fleet'`, [P])) === 1);
  await fails('computer-run airline names are reserved', `select public.found_airline('test2c00', 'Koel Air', 'KQ', 'DEL')`, /already taken/);
  await fails('and their codes', `select public.found_airline('test2c00', 'Some Air', 'SRW', 'DEL')`, /already taken/);

  // airlines for the later checks, all founded before the start
  const [N1, N2, N3, S1, S2, D1, C1, L1, Q1] = [];
  const ids = {};
  for (const [k, c, b] of [['N1', 'NA', 'DEL'], ['N2', 'NB', 'DEL'], ['N3', 'NC', 'DEL'], ['S1', 'SA', 'DEL'], ['S2', 'SB', 'DEL'],
    ['D1', 'DA', 'DEL'], ['C1', 'CA', 'DEL'], ['L1', 'LA', 'DEL'], ['Q1', 'QA', 'DEL']]) ids[k] = await found(`Test ${k}`, c, b);

  await q(`select public.admin_start_world($1)`, [W]);
  const RP = await one(`select public.open_route($1, 'DEL', 'BOM', $2)`, [P, 2 * (await ref('DEL', 'BOM'))]);
  await q(`select public.set_rotation($1, $2, $3, 21)`, [P, await acOf(P), RP]);

  // item 10: three airlines with four flights a day each, then one airline with all twelve
  const fl = {};
  for (const k of ['N1', 'N2', 'N3']) {
    fl[k] = await one(`select public.open_route($1, 'DEL', 'LKO')`, [ids[k]]);
    await q(`select public.set_rotation($1, $2, $3, 28)`, [ids[k], await acOf(ids[k]), fl[k]]);
  }
  const extra = [await one(`select public.wet_lease($1, 'A20N', 'DEL')`, [ids.N1]), await one(`select public.wet_lease($1, 'A20N', 'DEL')`, [ids.N1])];
  // item 9: lessors place at most six aircraft a quarter with one airline
  const pool = await q(`select id from public.aircraft where world_id = $1 and status = 'pool' and type_id = 'A20N' order by built_day desc limit 7`, [W]);
  for (const a of pool.slice(0, 6)) await q(`select public.lease_aircraft($1, $2, 'DEL')`, [ids.Q1, a.id]);
  await fails('a seventh aircraft from the pool in one quarter is refused', `select public.lease_aircraft('${ids.Q1}', '${pool[6].id}', 'DEL')`, /at most 6 aircraft/);
  await q(`update public.transactions set game_day = game_day - 91 where airline_id = $1 and kind = 'lease'`, [ids.Q1]);
  ok('and allowed again a quarter later', !!(await one(`select public.lease_aircraft($1, $2, 'DEL')`, [ids.Q1, pool[6].id])));

  console.log('Stage 2c: computer-run airlines (item 7)');
  await run(1);
  const bots = await q(`select al.code, al.is_ai, (select count(*)::int from public.aircraft x where x.airline_id = al.id) fleet
    from public.airlines al where al.world_id = $1 and al.is_ai order by al.code`, [W]);
  const want = await one(`select sum(ceil(game.bot_trips(aircraft, weekly_trips, 0.5)::numeric / weekly_trips))::int from public.bot_network`);
  ok('six computer-run airlines start on day 1, fleets scaled to the world', bots.length === 6 && bots.reduce((s, b) => s + b.fleet, 0) === want,
    bots.map((b) => `${b.code} ${b.fleet}`).join(', '));
  const trunks = await q(`select m.a || '-' || m.b mkt, (select count(*)::int from public.routes r join public.airlines al on al.id = r.airline_id
      where al.is_ai and al.world_id = $1 and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b
        and exists (select 1 from public.rotations ro where ro.route_id = r.id)) n
    from public.markets m join public.airports pa on pa.iata = m.a join public.airports pb on pb.iata = m.b
    where m.zone = 'india' and pa.opens_day = 0 and pb.opens_day = 0 order by m.n_biz + m.n_lei + m.n_bud desc limit 8`, [W]);
  ok('they fly every one of the eight busiest domestic routes from day 1', trunks.every((r) => r.n >= 1), trunks.map((r) => `${r.mkt} ${r.n}`).join(', '));
  const lone = await rd(RP, 1);
  ok('a player pricing Delhi-Mumbai at twice the reference fare no longer fills up', lone.flights === 6 && lone.pax_econ < 0.1 * lone.seats_econ,
    `${lone.pax_econ} of ${lone.seats_econ} seats`);
  const s1 = await rd(fl.N1, 1);
  ok('the starter aircraft flies on day 1', s1.flights === 8, `${s1.pax_econ} passengers on Delhi-Lucknow`);

  console.log('Stage 2c: demand (items 10, 12)');
  await run(12);
  const potLko = await one(`select (n_biz + n_lei + n_bud)::float * 0.5 from public.markets where a = 'DEL' and b = 'LKO'`);
  const paxOn = async (d) => one(`select sum(pax_econ + pax_biz)::float from public.route_daily where route_id = any($1) and game_day = $2`, [Object.values(fl), d]);
  const three = await paxOn(13);
  ok('three airlines with four flights a day each carry about 65% of potential', Math.abs(three / (2 * potLko) - 0.65) < 0.04,
    `${(100 * three / (2 * potLko)).toFixed(1)}%`);
  for (const k of ['N2', 'N3']) await q(`select public.set_rotation($1, $2, $3, 0)`, [ids[k], await acOf(ids[k]), fl[k]]);
  await run(1);
  for (const e of extra) await q(`select public.set_rotation($1, $2, $3, 28)`, [ids.N1, e.aircraft_id, fl.N1]);
  await run(1);
  const one12 = await paxOn(15);
  ok('one airline with all twelve flights carries nearly as many: the number of airlines no longer drives total travel',
    one12 / three > 0.93 && one12 / three < 1.03, `${(100 * one12 / (2 * potLko)).toFixed(1)}% (old model: 50% against 65%)`);

  // spill weighs fares: a cheap, small airline overflows; a rival at twice the reference fare picks up few of its travellers
  const rs = await ref('DEL', 'SXR');
  const RS1 = await one(`select public.open_route($1, 'DEL', 'SXR', $2)`, [ids.S1, Math.round(0.6 * rs)]);
  const RS2 = await one(`select public.open_route($1, 'DEL', 'SXR', $2)`, [ids.S2, 2 * rs]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [ids.S1, await acOf(ids.S1), RS1]);
  await q(`select public.set_rotation($1, $2, $3, 28)`, [ids.S2, await acOf(ids.S2), RS2]);
  await run(1);
  const sp1 = await rd(RS1, 16), sp2 = await rd(RS2, 16);
  ok('travellers spilled by a full airline mostly do not pay twice the fare elsewhere', sp1.spill > 100 && sp2.pax_econ < 0.25 * sp1.spill,
    `${sp1.spill} spilled, rival at 2x carried ${sp2.pax_econ} (old rule: up to 60% of them)`);

  // business travellers who find business full take economy on the same airline
  const two = await one(`with a as (insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, base_iata,
      biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ) values ($1, 'A20N', $2, 'VT-TWO', 0, 'active', 'DEL', 3, 38, 30, 12, 150) returning id)
    insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, start_day)
    select id, $2, 'lease', 380000, 2000, 1 from a returning aircraft_id`, [W, ids.D1]);
  const rb = await ref('DEL', 'GOI');   // economy priced high so it has seats left; business at the lowest fare so it overflows
  const RD = await one(`select public.open_route($1, 'DEL', 'GOI', $2, $3)`, [ids.D1, Math.round(2.5 * rb), Math.ceil(0.25 * rb * 3.5)]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [ids.D1, two, RD]);
  await q(`update public.game_params set num = 0 where key = 'biz_downgrade_share'`);
  await run(1);
  await q(`update public.game_params set num = 0.5 where key = 'biz_downgrade_share'`);
  await run(1);
  const dg0 = await rd(RD, 17), dg5 = await rd(RD, 18);
  ok('business travellers who find the business cabin full move down to economy', dg0.pax_biz === dg0.seats_biz && dg5.pax_econ > dg0.pax_econ + 20,
    `economy ${dg0.pax_econ} without, ${dg5.pax_econ} with`);

  // an idle aircraft of the same type at the same base covers a grounded one
  const own = [];
  for (const r of ['VT-CV1', 'VT-CV2']) own.push(await one(`with a as (insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, base_iata,
      econ_pitch, seats_econ) values ($1, 'A20N', $2, $3, 0, 'active', 'DEL', 29, 180) returning id)
    insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, start_day)
    select id, $2, 'lease', 380000, 2000, 1 from a returning aircraft_id`, [W, ids.C1, r]));
  await q(`select public.return_aircraft($1, $2)`, [ids.C1, await one(`select id from public.aircraft a where airline_id = $1 and exists
    (select 1 from public.aircraft_terms t where t.aircraft_id = a.id and t.holding = 'wet')`, [ids.C1])]);
  const RC = await one(`select public.open_route($1, 'DEL', 'AMD')`, [ids.C1]);
  await q(`select public.set_rotation($1, $2, $3, 21)`, [ids.C1, own[0], RC]);
  await q(`update public.aircraft set status = 'grounded', available_day = 30 where id = $1`, [own[0]]);
  await run(1);
  const cv = (await q(`select flights::float, cancelled::float from public.airline_daily where airline_id = $1 and game_day = 19`, [ids.C1]))[0];
  ok('an idle aircraft at the same base covers a grounded one: no cancellations', cv.flights === 6 && cv.cancelled === 0);
  await q(`update public.aircraft set status = 'grounded', available_day = 30 where id = $1`, [own[1]]);
  await run(1);
  const cv2 = (await q(`select flights::float, cancelled::float from public.airline_daily where airline_id = $1 and game_day = 20`, [ids.C1]))[0];
  ok('without a spare the flights are cancelled', cv2.flights === 0 && cv2.cancelled === 6);

  console.log('Stage 2c: aircraft loans (item 13), overheads, slots (item 11)');
  const c0 = await one(`select cash_inr::float from public.airline_finance where airline_id = $1`, [ids.L1]);
  const ord = await one(`select public.order_aircraft($1, 'A20N', 'DEL', 0, null, 29, 'loan')`, [ids.L1]);
  await fails('payment plans are cash, loan or slb', `select public.order_aircraft('${ids.L1}', 'A20N', 'DEL', 0, null, 29, 'bank')`, /cash, loan or slb/);
  await q(`update public.aircraft set available_day = $2 where id = $1`, [ord.aircraft_id, (await day()) + 1]);
  await run(1);
  const lt = (await q(`select holding, loan_usd::float loan, loan_pay_usd_day::float pay, deposit_inr::float dep from public.aircraft_terms where aircraft_id = $1`, [ord.aircraft_id]))[0];
  const bal = (ord.price_usd * 90 - ord.deposit_inr) / 90;
  ok('a loan order is delivered owned, with the balance borrowed in dollars over 12 years', lt.holding === 'owned' && lt.dep === 0
    && Math.abs(lt.loan + lt.pay - bal) < 1 && Math.abs(lt.pay - bal / (12 * 364)) < 0.01, `$${(lt.loan / 1e6).toFixed(2)}M outstanding`);
  const ld = (await q(`select loan_repaid::float rep, c_interest::float intr, rev_ticket + rev_anc - (c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots
    + c_dist + c_marketing + c_overhead + c_interest + loan_repaid) net, cash_end::float cash from public.airline_daily where airline_id = $1 and game_day = 21`, [ids.L1]))[0];
  const tx = await one(`select coalesce(sum(amount_inr), 0)::float from public.transactions where airline_id = $1 and game_day = 21`, [ids.L1]);
  ok('each day pays principal and 8% interest, and cash reconciles', Math.abs(ld.rep - Math.round(lt.pay * 90)) <= 1
    && Math.abs(ld.intr - Math.round(bal * 0.08 / 364 * 90)) <= 1 && Math.abs(ld.cash - (c0 + Number(ld.net) + tx)) < 1);
  const sale = await one(`select public.return_aircraft($1, $2)`, [ids.L1, ord.aircraft_id]);
  const book = ord.price_usd * 90 * (1 - 0.036 / 364);
  ok('selling repays the loan from the proceeds', Math.abs(sale.cash_inr - (0.85 * book - lt.loan * 90)) < 1e5);

  const ov = (await q(`select c_overhead::float ovh from public.airline_daily where airline_id = $1 and game_day = 21`, [ids.C1]))[0];
  ok('head-office overhead: Rs 6 lakh a day, Rs 1,000 a seat and Rs 1.5 lakh a base', ov.ovh === 600000 + 1000 * 360 + 150000);
  ok('slot price at a full airport is 100 times the base (was 400)', await one(`select game.param('slot_base_inr') / power(1 - game.param('slot_util_cap'), 2)
    / game.param('slot_base_inr') = 100`));

  console.log('Stage 2c: computer-run airlines over time');
  await run(91 - (await day()));
  const band = await q(`select al.code, r.fare_econ::float / m.ref_fare mult, ba.defend_lo::float lo, ba.fare_hi::float hi from public.routes r
    join public.airlines al on al.id = r.airline_id join public.bot_airlines ba on ba.code = al.code
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest) where al.world_id = $1 and r.status = 'open'`, [W]);
  ok('their fares move, and stay within their bands', band.some((b) => Math.abs(b.mult - 1) > 0.02) && band.every((b) => b.mult >= b.lo - 0.01 && b.mult <= b.hi + 0.01),
    `${band.filter((b) => Math.abs(b.mult - 1) > 0.02).length} of ${band.length} routes repriced`);
  const qr = await q(`select al.is_ai, q.rank from public.quarterly_reports q join public.airlines al on al.id = q.airline_id where al.world_id = $1 and q.quarter = 1`, [W]);
  ok('quarterly results include them, but only players are ranked', qr.filter((r) => r.is_ai).length === 6 && qr.every((r) => (r.rank === null) === r.is_ai));
  ok('a quarter\'s capacity moves run without errors', (await one(`select count(*)::int from game.engine_log where world_id = $1`, [W])) === 0);
  const K = await one(`select id from public.airlines where world_id = $1 and code = 'KOL'`, [W]);
  await q(`update public.airline_finance set cash_inr = -1e11, debt_inr = credit_limit_inr where airline_id = $1`, [K]);
  await run(15);
  ok('they never go into administration', await one(`select administrations = 0 and status = 'active' from public.airlines where id = $1`, [K]));
  await q(`update public.game_params set num = v.n from (values ('demand_noise_sd', 0.10), ('fuel_vol_day', 0.012), ('fx_vol_day', 0.002),
    ('event_fuel_prob_day', 0.004), ('event_fx_prob_day', 0.003), ('event_engine_prob_day', 0.002), ('ground_prob_day', 0.004)) v(k, n) where key = v.k`);
}
