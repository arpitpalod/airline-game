// Stage 2b: player actions and the daily engine.
export async function checks2b(t, perf) {
  const { q, one, ok, fails, as } = t;
  const U1 = '00000000-0000-0000-0000-000000000001', U2 = '00000000-0000-0000-0000-000000000002';
  await q(`insert into auth.users values ('${U1}'), ('${U2}')`);
  const W = await one(`select id from public.worlds`);
  const code = await one(`select invite_code from public.world_secrets`);
  const cash = (a) => one(`select cash_inr::float from public.airline_finance where airline_id = '${a}'`);

  // Stage 2b rules on their own: no starter aircraft and no computer-run airlines (Stage 2c, checks_2c.mjs)
  await q(`update public.game_params set num = 0 where key = 'starter_aircraft'`);
  await q(`update public.worlds set bot_scale = 0`);

  console.log('Stage 2b: player actions');
  await as(U1);
  await fails('wrong invite code refused', `select public.found_airline('nope', 'Test Air', 'TA', 'DEL')`, /invite code/);
  await fails('foreign base refused', `select public.found_airline('${code}', 'Test Air', 'TA', 'DXB')`, /Indian airports/);
  const A = await one(`select public.found_airline('${code}', 'Test Air', 'ta', 'del')`);
  ok('airline founded with Rs 500 crore and a free base', (await cash(A)) === 5e9
    && (await one(`select count(*)::int from public.bases where airline_id = '${A}'`)) === 1);
  await fails('one airline per player per world', `select public.found_airline('${code}', 'Second Air', 'SA', 'BOM')`, /already have an airline/);
  await fails('no actions before the world starts', `select public.wet_lease('${A}', 'A20N', 'DEL')`, /not running/);
  await fails('players cannot start a world', `select public.admin_start_world('${W}')`, /Admins only/);
  await as(null);
  await q(`select public.admin_start_world('${W}')`);
  const mkt = await q(`select type_id, pool_available a, pool_target g, rent_mult::float m, lease_lead_days d,
    order_delivery_day od, order_price_usd::float op, wet_usd_bh::float wr from public.aircraft_market('${W}')`);
  ok('pool filled to target at base rent, 39 days to arrive', mkt.every((r) => r.a === r.g && r.m === 1 && r.d === 39),
    mkt.map((r) => `${r.type_id} ${r.a}`).join(' '));
  const a20 = mkt.find((r) => r.type_id === 'A20N');
  ok('order quote: first slot is day 547 at list price', a20.od === 547 && a20.op === 55e6);
  ok('A320neo wet rate about $5,500 a block hour', Math.abs(a20.wr - 5500) < 300, `$${a20.wr}`);

  await as(U2);
  const B = await one(`select public.found_airline('${code}', 'Rival Air', 'RV', 'BOM')`);
  await fails('cannot act for another airline', `select public.wet_lease('${A}', 'A20N', 'DEL')`, /not your airline/);
  await as(U1);

  const pick = await one(`select id from public.aircraft where status = 'pool' and type_id = 'A20N' and seats_biz = 0 and econ_pitch = 29 order by built_day desc limit 1`);
  const before = await cash(A);
  const lease = await one(`select public.lease_aircraft('${A}', '${pick}', 'DEL')`);
  ok('lease: arrives day 40, deposit is 3 months of rent', lease.arrives_day === 40
    && lease.deposit_inr === Math.round(lease.rent_usd_month * 3 * 90) && before - (await cash(A)) === lease.deposit_inr,
    `$${lease.rent_usd_month} a month`);
  await fails('a leased aircraft is gone from the pool', `select public.lease_aircraft('${A}', '${pick}', 'DEL')`, /no longer available/);
  await fails('lease needs one of your bases', `select public.lease_aircraft('${A}', (select id from public.aircraft where status = 'pool' limit 1), 'BLR')`, /no base/);
  ok('shortage premium starts once the pool is drawn on', (await one(`select rent_mult::float from public.aircraft_market('${W}') where type_id = 'A20N'`)) > 1);

  const ord = await one(`select public.order_aircraft('${A}', 'A21N', 'DEL', 3, 38, 30, 'slb')`);
  ok('order: day 547, 15% deposit', ord.arrives_day === 547 && ord.deposit_inr === Math.round(65e6 * 0.15 * 90));
  await fails('impossible cabin refused', `select public.order_aircraft('${A}', 'AT76', 'DEL', 2, 38, 29)`, /business cabin/);
  const ord2 = await one(`select public.order_aircraft('${A}', 'A21N', 'DEL', 0, null, 29)`);
  const cancel = await one(`select public.return_aircraft('${A}', '${ord2.aircraft_id}')`);
  ok('cancelling an order forfeits the deposit', cancel.cash_inr === 0 && cancel.pnl_inr === -ord2.deposit_inr);

  const wet = await one(`select public.wet_lease('${A}', 'A20N', 'DEL')`);
  ok('wet lease arrives day 14 with 180 seats', wet.arrives_day === 14
    && (await one(`select seats_econ from public.aircraft where id = '${wet.aircraft_id}'`)) === 180);
  const wide = await one(`select public.wet_lease('${A}', 'A359', 'DEL')`);

  const c0 = await cash(A);
  await q(`select public.open_base('${A}', 'BOM')`);
  ok('second base costs Rs 5 crore', c0 - (await cash(A)) === 5e7);

  const R = await one(`select public.open_route('${A}', 'DEL', 'BOM')`);
  const ref = await one(`select ref_fare from public.markets where a = 'BOM' and b = 'DEL'`);
  ok('route opens at reference fares', await one(`select fare_econ = ${ref} and fare_biz = round(${ref} * 3.5) from public.routes where id = '${R}'`));
  await fails('one route per city pair', `select public.open_route('${A}', 'BOM', 'DEL')`, /already fly/);
  await fails('routes start at a base', `select public.open_route('${A}', 'BLR', 'MAA')`, /your bases/);
  await fails('fare limits', `select public.set_fares('${A}', '${R}', 100)`, /Economy fare/);
  await q(`select public.set_rotation('${A}', '${wet.aircraft_id}', '${R}', 21)`);
  await fails('flying window enforced (4 a day does not fit)', `select public.set_rotation('${A}', '${wet.aircraft_id}', '${R}', 28)`, /hours a week/);
  const RL = await one(`select public.open_route('${A}', 'DEL', 'LHR')`);
  await fails('range enforced', `select public.set_rotation('${A}', '${wet.aircraft_id}', '${RL}', 3)`, /range/);
  const RP = await one(`select public.open_route('${A}', 'DEL', 'PAT')`);
  await fails('runway enforced', `select public.set_rotation('${A}', '${wide.aircraft_id}', '${RP}', 7)`, /runway/);
  await fails('aircraft must be based on the route', `select public.set_rotation('${A}', '${wet.aircraft_id}', (select public.open_route('${A}', 'BOM', 'GOI')), 7)`, /based at/);
  await q(`select public.close_route('${A}', '${RL}')`);
  await q(`select public.return_aircraft('${A}', '${wide.aircraft_id}')`);
  await fails('refit needs an aircraft in service', `select public.refit_aircraft('${A}', '${pick}', 0, null, 30)`, /in service/);
  await q(`select public.set_rotation('${A}', '${pick}', '${R}', 21)`);

  await q(`select public.borrow('${A}', 1e9)`);
  await fails('credit line is a hard limit', `select public.borrow('${A}', 1.5e9)`, /credit line/);
  await q(`select public.repay('${A}', 1e9)`);
  ok('borrow and repay net to zero', await one(`select debt_inr = 0 from public.airline_finance where airline_id = '${A}'`));
  await fails('marketing limit', `select public.set_marketing('${A}', 1e9)`, /Marketing/);

  await q(`set role authenticated`);
  await fails('players cannot write tables', `update public.airline_finance set cash_inr = 1e12`, /permission denied/);
  await fails('players cannot call engine internals', `select game.start_world('${W}')`, /permission denied/);
  ok('players read only their own books', (await one(`select count(*)::int from public.airline_finance`)) === 1);
  await q(`reset role`);
  await as(null);

  console.log('Stage 2b: daily engine');
  // a quiet world, so results can be checked exactly
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'fuel_vol_day', 'fx_vol_day',
    'fx_drift_year', 'event_fuel_prob_day', 'event_fx_prob_day', 'event_engine_prob_day', 'ground_prob_day')`);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day('${W}')`); };
  const day = () => one(`select game_day from public.worlds where id = '${W}'`);
  const daily = async (a, d) => (await q(`select pax, ask::float, rpk::float, rev_ticket::float rev, rev_anc::float anc,
    c_fuel::float fuel, c_crew::float crew, c_maint::float maint, c_airport::float airport, c_rent::float rent,
    c_slots::float slots, c_dist::float dist, c_marketing::float mkt, c_overhead::float ovh, c_interest::float intr,
    c_other::float other, c_depr::float depr, flights::float, cancelled::float, cash_end::float cash, brand::float, otp::float
    from public.airline_daily where airline_id = '${a}' and game_day = ${d}`))[0];
  const cashCosts = (d) => d.fuel + d.crew + d.maint + d.airport + d.rent + d.slots + d.dist + d.mkt + d.ovh + d.intr;

  await run(13);
  const d13 = await daily(A, 13);
  ok('day 13: nothing flies yet, overheads still run', d13.flights === 0 && d13.rev === 0 && d13.ovh === 600000 + 2 * 150000);
  await run(1);
  const d14 = await daily(A, 14);
  const r14 = (await q(`select flights::float, seats_econ, pax_econ, spill, revenue_inr::float rev, var_cost_inr::float var
    from public.route_daily where route_id = '${R}' and game_day = 14`))[0];
  ok('day 14: the wet-leased A320 arrives and flies 6 sectors, 1,080 seats', r14.flights === 6 && r14.seats_econ === 1080);
  ok('an empty trunk route fills the aircraft and spills the rest', r14.pax_econ === 1080 && r14.spill > 1000, `spill ${r14.spill}`);
  const anY = Number(await one(`select yield from game.anc_terms('${A}')`));
  ok('revenue = passengers x fare, plus extras sold at their reference prices', r14.rev === Math.round(1080 * ref * (1 + anY)) && d14.rev === 1080 * ref,
    `extras ${(anY * 100).toFixed(1)}% of the reference fare a passenger`);
  ok('wet lease: hourly rent, no crew or maintenance bill', d14.crew === 0 && d14.maint === 0
    && Math.abs(d14.rent - wet.wet_usd_bh * 90 * 6 * (1137 / 830 + 0.7)) < 2, `rent Rs ${(d14.rent / 1e5).toFixed(1)} lakh a day`);
  const tx14 = await one(`select coalesce(sum(amount_inr), 0)::float from public.transactions where airline_id = '${A}' and game_day = 14`);
  ok('cash reconciles: yesterday + revenue - cash costs + one-off movements',
    Math.abs(d14.cash - (d13.cash + d14.rev + d14.anc - cashCosts(d14) + tx14)) < 1);
  ok('ASK and RPK', d14.ask === 1080 * 1137 && d14.rpk === 1080 * 1137);

  // unit costs of an ordinary leased A320neo on Delhi-Mumbai, flying alone
  await run(25);
  await q(`select public.return_aircraft('${A}', '${wet.aircraft_id}')`);
  await run(1);
  const d40 = await daily(A, 40);
  ok('day 40: the leased A320 arrives and takes over the route', d40.flights === 6 && d40.crew > 0 && d40.maint > 0);
  // the same aircraft at an 85% load: shrink the market for one day
  const s40 = await one(`select spill from public.route_daily where route_id = '${R}' and game_day = 40`);
  await q(`update public.worlds set demand_scale = ${(0.85 * 1080 / (1080 + s40)).toFixed(5)} where id = '${W}'`);
  await run(1);
  await q(`update public.worlds set demand_scale = 1 where id = '${W}'`);
  const d41 = await daily(A, 41);
  const hq = 600000 + 2 * 150000;   // head office and bases: spread thin on a one-aircraft airline, so left out here
  const cask = (cashCosts(d41) - d41.intr - hq) / d41.ask, rask = (d41.rev + d41.anc) / d41.ask, lf = d41.rpk / d41.ask;
  const per = (x) => (x / d41.ask).toFixed(2);
  ok('aircraft-level cost per seat-km in the Rs 4.1 to 4.8 band', cask > 4.1 && cask < 4.8,
    `CASK ${cask.toFixed(2)} = fuel ${per(d41.fuel)} + rent ${per(d41.rent)} + maintenance ${per(d41.maint)} + crew ${per(d41.crew)} + airport ${per(d41.airport + d41.slots)} + distribution ${per(d41.dist)} + overhead ${per(d41.ovh - hq)}`);
  ok('revenue per seat-km at the reference fare in the Rs 4.4 to 5.2 band', rask > 4.4 && rask < 5.2, `RASK ${rask.toFixed(2)} at ${(lf * 100).toFixed(0)}% load`);
  ok('operating margin at that load is 3 to 10%', 1 - cask / rask > 0.03 && 1 - cask / rask < 0.10, `${((1 - cask / rask) * 100).toFixed(1)}%`);
  ok('three round trips a day use 91% of the flying window: on-time performance about 84%', d41.otp > 0.83 && d41.otp < 0.86, `${d41.otp}`);

  // fares move demand: pricing far above the market empties the aircraft
  await q(`select public.set_fares('${A}', '${R}', ${ref * 3})`);
  await run(1);
  const hi = await one(`select pax_econ from public.route_daily where route_id = '${R}' and game_day = 42`);
  ok('tripling the fare loses most passengers', hi < 600, `${hi} of 1080`);
  await q(`select public.set_fares('${A}', '${R}', ${ref})`);

  // a rival on the same route shares the market
  await as(t.U2 = U2);
  const RB = await one(`select public.open_route('${B}', 'BOM', 'DEL', ${Math.round(ref * 0.9)})`);
  const wb = await one(`select public.wet_lease('${B}', 'A20N', 'BOM')`);
  await q(`select public.set_rotation('${B}', '${wb.aircraft_id}', '${RB}', 21)`);
  ok('private notices stay private', (await (async () => { await q(`set role authenticated`);
    const n = await one(`select count(*)::int from public.news where private`); await q(`reset role`); return n; })()) === 0);
  await as(null);

  // grounding cancels flights and hurts the brand
  await q(`update public.aircraft set status = 'grounded', available_day = 45 where id = '${pick}'`);
  const b0 = await one(`select brand::float from public.airlines where id = '${A}'`);
  await run(2);
  const d44 = await daily(A, 44);
  ok('a grounded aircraft cancels its flights and dents the brand', d44.flights === 0 && d44.cancelled === 6 && d44.brand < b0);
  await run(1);
  ok('it returns to service on its available day', (await daily(A, 45)).flights === 6);

  // refit
  const rf = await one(`select public.refit_aircraft('${A}', '${pick}', 0, null, 30)`);
  ok('refit: Rs 1 crore + Rs 50,000 a seat, 7 days on the ground', rf.cost_inr === 1e7 + 6 * 50000 && rf.back_day === 53 && rf.seats === 174);
  await run(8);
  ok('refit cost is booked as an expense; aircraft is back with 174 seats',
    (await daily(A, 46)).other === rf.cost_inr && (await one(`select seats_econ from public.route_daily where route_id = '${R}' and game_day = 53`)) === 6 * 174);

  // quarter end
  await run(91 - (await day()));
  const qr = await q(`select al.name, q.rank, q.revenue::float rev, q.op_profit::float op, q.net_profit::float net, q.net_worth::float nw, q.score::float score,
    q.load_factor::float lf, q.cask::float cask from public.quarterly_reports q join public.airlines al on al.id = q.airline_id where q.quarter = 1 order by q.rank`);
  ok('quarter 1 reports and ranks every airline', qr.length === 2 && qr[0].rank === 1 && qr[1].rank === 2,
    qr.map((r) => `${r.rank}. ${r.name} op profit Rs ${(r.op / 1e7).toFixed(1)} cr`).join('; '));
  const sumOp = await one(`select sum(rev_ticket + rev_anc - (c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead + c_other + c_depr))::float from public.airline_daily where airline_id = '${A}'`);
  const qa = qr.find((r) => r.name === 'Test Air');
  ok('quarterly profit equals the sum of the days; score = net worth + 5 x profit after interest (Stage 2c)', Math.abs(qa.op - sumOp) < 1 && Math.abs(qa.score - (qa.nw + 5 * qa.net)) < 2);
  const depo = await one(`select sum(deposit_inr)::float from public.aircraft_terms where airline_id = '${A}'`);
  ok('net worth = cash - debt + deposits held', Math.abs(qa.nw - ((await cash(A)) + depo)) < 2);
  ok('results headline published; pool topped up', (await one(`select count(*)::int from public.news where kind = 'results'`)) === 1
    && (await one(`select pool_available = pool_target from public.aircraft_market('${W}') where type_id = 'A20N'`)));
  ok('route results kept for 28 days only', (await one(`select min(game_day) from public.route_daily`)) === 64);

  // deliveries from the manufacturer (pulled forward for the test)
  const cashOrd = await one(`select public.order_aircraft('${A}', 'A20N', 'DEL', 0, null, 28, 'cash')`);
  const poorOrd = await one(`select public.order_aircraft('${B}', 'A20N', 'BOM', 0, null, 28, 'cash')`);
  await q(`update public.aircraft set available_day = 92 where id in ('${ord.aircraft_id}', '${cashOrd.aircraft_id}', '${poorOrd.aircraft_id}')`);
  await q(`update public.airline_finance set cash_inr = cash_inr + 5e9 where airline_id = '${A}'`);
  const c1 = await cash(A);
  await run(1);
  const d92 = await daily(A, 92);
  const terms = async (id) => (await q(`select holding, lease_usd_month::float rent, deposit_inr::float dep from public.aircraft_terms where aircraft_id = '${id}'`))[0];
  const tS = await terms(ord.aircraft_id), tC = await terms(cashOrd.aircraft_id), tP = await terms(poorOrd.aircraft_id);
  ok('sale and leaseback: rent at 85% of the base rate, order deposit swapped for a lease deposit',
    tS.holding === 'lease' && tS.rent === 408000 && tS.dep === 408000 * 3 * 90);
  ok('cash purchase: balance paid, aircraft owned, depreciation starts', tC.holding === 'owned' && tC.dep === 0
    && Math.abs(d92.depr - 55e6 * 90 * 0.036 / 364) < 1);
  ok('a buyer short of cash on delivery gets a sale and leaseback instead of losing the aircraft', tP.holding === 'lease' && tP.rent === 323000);
  const tx92 = await one(`select sum(amount_inr)::float from public.transactions where airline_id = '${A}' and game_day = 92`);
  ok('delivery payments reconcile', Math.abs(d92.cash - (c1 - (55e6 * 90 - cashOrd.deposit_inr) + (ord.deposit_inr - tS.dep) + d92.rev + d92.anc - cashCosts(d92))) < 1, `${tx92}`);
  const sale = await one(`select public.return_aircraft('${A}', '${cashOrd.aircraft_id}')`);
  ok('an owned aircraft sells at 85% of book value', Math.abs(sale.cash_inr - 0.85 * 55e6 * 90 * (1 - 0.036 / 364)) < 5e4);

  // lease renewal at the end of the term
  await q(`update public.aircraft_terms set lease_end_day = 92 where aircraft_id = '${pick}'`);
  await run(1);
  ok('a lease renews at the market rent when its term ends',
    (await one(`select lease_end_day from public.aircraft_terms where aircraft_id = '${pick}'`)) === 92 + 728
    && (await one(`select count(*)::int from public.news where private and body like 'The lease on%'`)) === 1);

  // the clock
  const setDue = (n) => q(`update public.worlds set started_at = now() - make_interval(secs => (game_day + ${n} + 0.5) * 86400 / speed) where id = '${W}'`);
  await setDue(3);
  ok('the scheduler catches up exactly the days that are due', (await one(`select game.tick()`)) === 3 && (await one(`select game.tick()`)) === 0);
  await setDue(100);
  ok('at most 30 days per run', (await one(`select game.tick()`)) === 30);
  await q(`update public.season_factors set month = 13 - month where false`);
  await setDue(0);
  const g0 = await day();
  await q(`alter table public.season_factors rename to season_factors_x`);
  await setDue(2);
  ok('a failing day is rolled back and logged, not half-applied', (await one(`select game.tick()`)) === 0 && (await day()) === g0
    && (await one(`select count(*)::int from game.engine_log`)) === 1 && (await one(`select count(*)::int from public.airline_daily where game_day > ${g0}`)) === 0);
  await q(`alter table public.season_factors_x rename to season_factors`);
  ok('and is retried on the next run', (await one(`select game.tick()`)) === 2);

  // insolvency
  await q(`update public.airline_finance set cash_inr = -5e9, debt_inr = credit_limit_inr where airline_id = '${B}'`);
  await run(13);
  ok('13 days under water: still trading', (await one(`select administrations from public.airlines where id = '${B}'`)) === 0);
  await run(1);
  const adm = (await q(`select al.administrations n, f.cash_inr::float cash, f.debt_inr::float debt, f.credit_limit_inr::float lim,
    (select count(*)::int from public.aircraft where airline_id = al.id) fleet, (select count(*)::int from public.routes where airline_id = al.id and status = 'open') routes
    from public.airlines al join public.airline_finance f on f.airline_id = al.id where al.id = '${B}'`))[0];
  ok('day 14: administration. Fleet gone, routes closed, restart with Rs 250 crore and a public mark',
    adm.n === 1 && adm.cash === 2.5e9 && adm.debt === 0 && adm.lim === 1e9 && adm.fleet === 0 && adm.routes === 0);

  // shortfalls draw on the credit line first
  await q(`update public.airline_finance set cash_inr = -1e8 where airline_id = '${A}'`);
  await run(1);
  ok('a cash shortfall is covered from the credit line', await one(`select cash_inr >= 0 and debt_inr > 1e8 and insolvent_days = 0 from public.airline_finance where airline_id = '${A}'`));

  // events, noise and random groundings (switched back on)
  ok('new airports are announced as events at world start', (await one(`select count(*)::int from public.events where kind = 'airport_opening'`)) === 2);
  await q(`update public.game_params set num = 1 where key in ('event_fuel_prob_day', 'event_fx_prob_day', 'event_engine_prob_day', 'ground_prob_day')`);
  await q(`update public.game_params set num = v.n from (values ('demand_noise_sd', 0.10), ('fuel_vol_day', 0.012), ('fx_vol_day', 0.002)) v(k, n) where key = v.k`);
  await run(1);
  const ev = (await q(`select w.fuel_inr_kg::float fuel, w.fuel_walk::float walk, w.fx_inr_usd::float fx, w.fx_walk::float fxw,
    (select (payload ->> 'mult')::float from public.events where kind = 'fuel_shock') mf, (select (payload ->> 'mult')::float from public.events where kind = 'fx_swing') mx,
    (select count(*)::int from public.events where kind = 'engine_grounding') eng,
    (select count(*)::int from public.aircraft x join public.aircraft_terms y on y.aircraft_id = x.id where x.status = 'active' and y.holding <> 'wet') flying,
    (select count(*)::int from public.aircraft where status = 'grounded' and available_day between w.game_day + 2 and w.game_day + 60) grounded from public.worlds w`))[0];
  ok('fuel shock and currency swing lift today\'s prices above the underlying walk', ev.mf >= 1.15 && Math.abs(ev.fuel - ev.walk * ev.mf) < 0.01
    && ev.mx >= 1.04 && Math.abs(ev.fx - ev.fxw * ev.mx) < 0.001, `fuel Rs ${ev.fuel}/kg, Rs ${ev.fx} per dollar`);
  ok('engine event raised; technical groundings take aircraft out of service', ev.eng === 1 && ev.flying === 0 && ev.grounded >= 1);
  await q(`update public.game_params set num = 0 where key in ('event_fuel_prob_day', 'event_fx_prob_day', 'event_engine_prob_day', 'ground_prob_day')`);
  await run(3);

  // pause and resume
  await q(`select public.admin_pause_world('${W}')`);
  ok('a paused world processes nothing', (await one(`select game.run_day('${W}')`)) === null && (await one(`select game.tick()`)) === 0);
  await q(`select public.admin_resume_world('${W}')`);
  ok('and resumes', (await one(`select status from public.worlds`)) === 'running');

  if (perf) {
    // 50 airlines x 20 aircraft x 3 routes each, built straight into the tables
    await q(`insert into public.airlines (world_id, name, code, is_ai) select '${W}', 'Load ' || i, 'L' || lpad(i::text, 2, '0'), true from generate_series(1, 48) i`);
    await q(`insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr) select id, 5e9, 2e9 from public.airlines where is_ai`);
    await q(`insert into public.bases (airline_id, iata, opened_day) select id, 'DEL', 1 from public.airlines where is_ai`);
    await q(`insert into public.routes (world_id, airline_id, origin, dest, fare_econ, fare_biz, opened_day)
      select '${W}', al.id, 'DEL', m.b, m.ref_fare, m.ref_fare * 3, 1 from public.airlines al
      cross join lateral (select b, ref_fare from public.markets where a = 'DEL' and not intl and km between 500 and 1500 order by n_bud desc limit 30) m where al.is_ai`);
    await q(`insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, base_iata, econ_pitch, seats_econ)
      select '${W}', 'A20N', al.id, 'P' || al.code || i, 0, 'active', 'DEL', 29, 180 from public.airlines al, generate_series(1, 20) i where al.is_ai`);
    await q(`insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, start_day)
      select id, airline_id, 'lease', 380000, 2000, 1 from public.aircraft where reg like 'PL%'`);
    await q(`insert into public.rotations (aircraft_id, route_id, weekly_trips)
      select ac.id, r.id, 7 from (select id, airline_id, row_number() over (partition by airline_id order by reg) n from public.aircraft where reg like 'PL%') ac
      join (select id, airline_id, row_number() over (partition by airline_id order by dest) n from public.routes) r
        on r.airline_id = ac.airline_id and (r.n - 1) % 20 = (ac.n - 1) % 20 or (r.airline_id = ac.airline_id and (r.n + 6) % 20 = (ac.n - 1) % 20)`);
    const n = await q(`select (select count(*)::int from public.rotations) rot, (select count(*)::int from public.routes where status = 'open') routes, (select count(*)::int from public.aircraft where airline_id is not null) fleet`);
    const t0 = Date.now(); await run(5);
    const ms = (Date.now() - t0) / 5;
    ok('a game day with 50 airlines runs in under 2 seconds (in-memory test database)', ms < 2000, `${ms.toFixed(0)} ms a day with ${n[0].fleet} aircraft, ${n[0].routes} routes, ${n[0].rot} rotations`);
  }

  // season end
  await q(`update public.worlds set season_days = game_day + 1 where id = '${W}'`);
  await run(2);
  ok('the season ends on its last day and the world stops', (await one(`select status from public.worlds`)) === 'ended');
  await as(U1);
  await fails('no actions after the season ends', `select public.set_marketing('${A}', 0)`, /not running/);
  await as(null);
}
