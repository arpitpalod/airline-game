// Every action priced, rules by region (migration 0033): compensation for an airline's own cancellations, denied boarding
// by region, hedges at the expected price, administration, interest on cash, insurance, tax, lease breaks, wet leases,
// launch fees, ferry flights, closing bases, computer-run airlines under the same rules, and the region values of a world.
export async function checks22(t) {
  const { q, one, ok, as, fails, w10Params } = t;
  await as(null);
  console.log('Every action priced, rules by region (0033)');
  for (const p of w10Params) await q(`update public.game_params set num = $1 where key = $2`, [p.num, p.key]);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day',
    'event_airport_prob_day', 'event_airspace_prob_day', 'late_delivery_prob', 'bot_explore_prob')`);
  const P = Object.fromEntries((await q(`select key, num::float from public.game_params`)).map((r) => [r.key, r.num]));
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 22', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2200' from w returning world_id`);
  const A = await one(`select public.found_airline('test2200', 'Priced Air', 'PR', 'DEL')`);
  const B = await one(`select public.found_airline('test2200', 'Second Air', 'SE', 'BOM')`);
  const day = async () => Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const runTo = async (f) => { while (!f(await day())) await run(1); return day(); };
  const cash = async (a) => Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [a]));
  const region = (opt) => q(`insert into public.world_params (world_id, key, num, public)
    select $1, e.key, e.value::numeric, true from public.world_options o, jsonb_each_text(o.vals) e
     where o.setting = 'region' and o.option = $2
    on conflict (world_id, key) do update set num = excluded.num`, [W, opt]);
  // a refusal inside an open transaction, without ending it
  const failsIn = async (name, sql, re) => { await q('savepoint f'); await fails(name, sql, re); await q('rollback to savepoint f'); };
  const txn = async (a, kind, d) => (await q(`select coalesce(sum(amount_inr), 0)::float amt, count(*)::int n from public.transactions
    where airline_id = $1 and kind = $2 and game_day = $3`, [a, kind, d]))[0];

  // ---------- 8. the starter wet lease ----------
  const st = await q(`select tm.wet_usd_bh::float r, tm.starter, tm.wet_min_until,
      round(game.wet_rate_usd($2, ac.type_id) * $3 / $4)::float want
    from public.aircraft ac join public.aircraft_terms tm on tm.aircraft_id = ac.id where ac.airline_id = $1`, [A, W, P.wet_starter_mult, P.wet_lease_mult]);
  ok('the starter aircraft is wet leased at the starter rate, with no minimum term',
    st.length === P.starter_aircraft && st.every((x) => x.starter && x.wet_min_until === null && x.r === x.want), JSON.stringify(st));

  // ---------- 6. a route costs its launch ----------
  const c0 = await cash(A);
  const R = await one(`select public.open_route($1, 'DEL', 'BOM')`, [A]);
  const ln = await txn(A, 'launch', 1);
  ok('launching a route costs Rs 25 lakh, in the results', c0 - await cash(A) === P.route_launch_inr && ln.amt === -P.route_launch_inr
    && Number(await one(`select pnl_inr from public.transactions where airline_id = $1 and kind = 'launch'`, [A])) === -P.route_launch_inr);
  const AC = await one(`select id from public.aircraft where airline_id = $1`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 10)`, [A, AC, R]);
  await q(`select public.admin_start_world($1)`, [W]);
  if (await day() === 0) await run(7);
  const botLaunch = Number(await one(`select count(*) from public.transactions t join public.airlines al on al.id = t.airline_id
    where al.world_id = $1 and al.is_ai and t.kind = 'launch' and t.game_day = 1`, [W]));
  const botRoutes = Number(await one(`select count(*) from public.routes r join public.airlines al on al.id = r.airline_id
    where al.world_id = $1 and al.is_ai`, [W]));
  ok('a computer-run airline\'s starting network pays no launches', botRoutes > 0 && botLaunch === 0, `${botRoutes} routes`);

  // ---------- 6, 7. ferry flights and closing bases ----------
  const BC = await one(`select id from public.aircraft where airline_id = $1`, [B]);
  await q(`select public.open_base($1, 'DEL')`, [B]);
  const fc = Number(await one(`select game.ferry_cost($1, 'BOM', 'DEL')`, [BC]));
  const c1 = await cash(B);
  const fq = await one(`select public.price_quote($1, 'ferry', $2, 'DEL')`, [B, BC]);
  await q(`select public.rebase_aircraft($1, $2, 'DEL')`, [B, BC]);
  const fd = await day();
  ok('moving an aircraft to another base costs one empty flight, quoted before', fc > 2e5 && fc < 5e6 && c1 - await cash(B) === fc && Number(fq.cost_inr) === fc
    && (await txn(B, 'ferry', fd + 1)).amt === -fc, `Rs ${fc}`);
  await fails('a base with aircraft cannot close', `select public.close_base('${B}', 'DEL')`, /Move or return the aircraft based at DEL first/);
  await q(`select public.rebase_aircraft($1, $2, 'BOM')`, [B, BC]);
  await q(`select public.close_base($1, 'DEL')`, [B]);
  ok('an empty base closes', Number(await one(`select count(*) from public.bases where airline_id = $1 and iata = 'DEL'`, [B])) === 0);
  await fails('the last base cannot close', `select public.close_base('${B}', 'BOM')`, /at least one base/);
  await q('begin');
  await q(`select public.open_base($1, 'GOI')`, [B]);
  await q(`select public.open_route($1, 'GOI', 'BOM')`, [B]);
  await failsIn('a base where routes start cannot close', `select public.close_base('${B}', 'GOI')`, /Close the routes that start at GOI first/);
  await q('rollback');

  // ---------- 5. breaking a lease ----------
  await q('begin');
  const pool = await one(`select id from public.aircraft where world_id = $1 and status = 'pool' order by built_day desc limit 1`, [W]);
  await q(`select public.lease_aircraft($1, $2, 'DEL')`, [A, pool]);
  await q(`update public.aircraft set status = 'active' where id = $1`, [pool]);
  const lt = (await q(`select tm.deposit_inr::float dep, least(round(tm.lease_usd_month * w.fx_inr_usd * $2),
      round(tm.lease_usd_month * w.fx_inr_usd / 30.33 * greatest(0, tm.lease_end_day - (w.game_day + 1))))::float fee,
      round(tm.lease_usd_month * w.fx_inr_usd * 3)::float three
    from public.aircraft_terms tm join public.worlds w on w.id = $3 where tm.aircraft_id = $1`, [pool, P.lease_break_months, W]))[0];
  await q('savepoint ro'); await q('set transaction read only');
  const lq = await one(`select public.price_quote($1, 'return', $2)`, [A, pool]);
  await q('rollback to savepoint ro');
  const lr = await one(`select public.return_aircraft($1, $2)`, [A, pool]);
  await q('rollback');
  ok('giving a leased aircraft back early costs six months of rent, out of the deposit, quoted before', Number(lr.pnl_inr) === -lt.fee && lt.fee > lt.three
    && Number(lq.fee_inr) === lt.fee && Number(lq.cash_inr) === Number(lr.cash_inr)
    && Number(lr.cash_inr) === lt.dep - lt.fee, `Rs ${lt.fee} against a deposit of Rs ${lt.dep}`);

  // ---------- 8. wet leases: a limited supply, a minimum term ----------
  await q('begin');
  const typ = await one(`select type_id from public.aircraft where id = $1`, [AC]);
  const room = (await q(`select * from game.wet_room($1, $2)`, [W, typ]))[0];
  const wl = [];
  for (let i = room.n_out; i < room.n_max; i++) wl.push(await one(`select public.wet_lease($1, $2, 'DEL')`, [A, typ]));
  ok('wet lessors have a fifth of an aircraft of each type per place, the starter aircraft aside',
    room.n_max === Math.ceil(P.wet_per_place * 18) && room.n_out === 0 && wl.length === room.n_max, `${room.n_max}`);
  await failsIn('beyond them, a wet lease is refused', `select public.wet_lease('${A}', '${typ}', 'DEL')`, /Wet lessors have no .* free in this world/);
  const w0 = wl[0];
  const wq = await one(`select public.price_quote($1, 'wet', null, $2)`, [A, typ]);
  const wrq = await one(`select public.price_quote($1, 'return', $2)`, [A, w0.aircraft_id]);
  const wr = await one(`select public.return_aircraft($1, $2)`, [A, w0.aircraft_id]);
  ok('the quotes show no wet lessor free, and the minimum term owed', wq.free === 0 && wq.max === room.n_max && Number(wrq.fee_inr) === -Number(wr.pnl_inr));
  const fx = Number(await one(`select fx_inr_usd from public.worlds where id = $1`, [W]));
  const want = Math.round(Number(w0.wet_usd_bh) * P.wet_min_hours_day * fx * (w0.min_until_day - Math.max(await day() + 1, w0.arrives_day)));
  ok('ending a wet lease inside its 13 weeks pays the minimum hours left (not the wait before it comes)', w0.min_until_day === w0.arrives_day + 7 * P.wet_min_weeks
    && Math.abs(Number(wr.pnl_inr) + want) <= 1 && want > 0, `Rs ${want}`);
  const starterBack = await one(`select public.return_aircraft($1, $2)`, [A, AC]);
  ok('the starter aircraft goes back at no cost, and frees no wet lessor', Number(starterBack.pnl_inr) === 0
    && (await q(`select * from game.wet_room($1, $2)`, [W, typ]))[0].n_out === room.n_max - 1);
  await q('rollback');

  // ---------- 1. cancelling flights already sold ----------
  // same week, India: the rest of the week's travellers are refunded and paid compensation
  let d = await runTo((x) => x >= 17 && x % 7 === 3);
  const inWeek = `select round(2 * (coalesce(x.flown_e, 0) / 7 * game.cancel_comp(x.world_id, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
      + coalesce(x.flown_b, 0) / 7 * game.cancel_comp(x.world_id, m.km, x.rev_b / nullif(x.bk_b, 0))))::float
    from public.route_weeks x join public.routes r on r.id = x.route_id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where x.route_id = $1 and x.week = game.week_of($2)`;
  await q('begin');
  const e1 = Number(await one(inWeek, [R, d + 1]));
  const q1 = await one(`select public.price_quote($1, 'close_route', $2)`, [A, R]);
  await q(`delete from public.rotations where route_id = $1`, [R]);
  await run(1);
  const t1 = await txn(A, 'cancellation', d + 1);
  const ad1 = (await q(`select c_comp::float cc, cancelled::float n, refunds_inr::float rf, c_other::float oth from public.airline_daily
    where airline_id = $1 and game_day = $2`, [A, d + 1]))[0];
  await q('rollback');
  ok('flights taken off in the week they fly: refunds, and India\'s compensation (capped at the fare)', e1 > 0 && t1.n === 1
    && Math.abs(t1.amt + e1) <= 1 && ad1.cc === -t1.amt && ad1.oth >= ad1.cc && ad1.rf > 0, `Rs ${e1}`);
  ok('and they count as cancelled flights for brand', ad1.n >= 2 * 10 / 7 - 0.01, `${ad1.n}`);
  ok('closing mid-week is quoted with the rest of the week\'s compensation', Number(q1.comp_inr) >= e1 * (7 * Math.ceil((d + 1) / 7) - d) - 1,
    `Rs ${q1.comp_inr}`);
  await as('00000000-0000-0000-0000-0000000022a1');
  await fails('a quote is only for the airline\'s own player', `select public.price_quote('${A}', 'close_route', '${R}')`, /not your airline/);
  await as(null);
  // the same flights stopped by an airport closure: refunds only
  await q('begin');
  await q(`insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values ($1, 'airport_closed', $2, $2, $2, '{"airport": "DEL"}')`, [W, d + 1]);
  await run(1);
  const t2 = await txn(A, 'cancellation', d + 1);
  const rf2 = Number(await one(`select refunds_inr from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d + 1]));
  await q('rollback');
  ok('flights stopped by an airport closure pay refunds but no compensation', t2.n === 0 && rf2 > 0);

  // interest on cash, an ordinary day
  await run(2);
  d = await day();
  const ic = (await q(`select d.i_cash::float i, p.cash_end::float c from public.airline_daily d
    join public.airline_daily p on p.airline_id = d.airline_id and p.game_day = d.game_day - 1 where d.airline_id = $1 and d.game_day = $2`, [A, d]))[0];
  const iw = Math.max(0, ic.c) * P.cash_interest_year / 364;
  ok('cash earns the region\'s interest every day', ic.i > 0 && Math.abs(ic.i - iw) <= iw * 0.02 + 1, `Rs ${ic.i} on Rs ${Math.round(ic.c / 1e7)} cr`);
  // insurance: none on wet leases, on the value of every other aircraft
  const ins = (await q(`select al.id, d.c_insurance::float got,
      round(sum(t.price_usd_m * 1e6 * w.fx_inr_usd * greatest(0.4, 1 - game.param('depreciation_year') * greatest(0, d.game_day - ac.built_day) / 364.0)
                * game.param('insurance_year') / 364))::float want
    from public.airlines al join public.airline_daily d on d.airline_id = al.id and d.game_day = $2
    join public.worlds w on w.id = al.world_id
    join public.aircraft ac on ac.airline_id = al.id and ac.status in ('active', 'grounded', 'refit')
    join public.aircraft_terms tm on tm.aircraft_id = ac.id and tm.holding <> 'wet'
    join public.aircraft_types t on t.id = ac.type_id
   where al.world_id = $1 and al.is_ai group by al.id, d.c_insurance order by count(*) desc limit 1`, [W, d]))[0];
  const insA = Number(await one(`select c_insurance from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d]));
  ok('hull insurance on the value of aircraft owned or leased, none on wet leases', ins.want > 0 && Math.abs(ins.got - ins.want) <= 1 && insA === 0,
    `Rs ${ins.got} a day`);

  // ---------- at a week start: closures and cuts within the notice, denied boarding, hedges ----------
  d = await runTo((x) => x % 7 === 0);
  const ws = d + 1, vw = Math.floor((ws - 1) / 7) + 1;
  const closing = `select round(sum(least(7, greatest(0, $3::float8 - ((x.week - 1) * 7 + 1 - $2))) / 7.0 * 2
      * ((x.bk_be + x.bk_l + x.bk_u) * game.cancel_comp(x.world_id, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
        + x.bk_b * game.cancel_comp(x.world_id, m.km, x.rev_b / nullif(x.bk_b, 0)))))::float
    from public.route_weeks x join public.routes r on r.id = x.route_id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where x.route_id = $1 and x.flown_e is null`;
  const closeAt = async (reg) => {
    await q('begin');
    if (reg) await region(reg);
    const notice = Number(await one(`select game.wparam($1, 'cancel_notice_days')`, [W]));
    const e = Number(await one(closing, [R, ws, notice]));
    const quote = await one(`select public.price_quote($1, 'close_route', $2)`, [A, R]);
    await q(`select public.close_route($1, $2)`, [A, R]);
    await run(1);
    const tx = await txn(A, 'cancellation', ws);
    const aw = (await q(`select cancel_comp_inr::float c, cut_flights::float n from public.airline_weeks where airline_id = $1 and week = $2`, [A, vw]))[0];
    await q('rollback');
    return { notice, e, tx, aw, quote };
  };
  const ci = await closeAt(null);
  ok('India: closing a route pays compensation for the flights within a day of the close, as quoted', ci.notice === 1 && ci.e > 0
    && Math.abs(Number(ci.quote.comp_inr) - ci.e) <= 1 && Number(ci.quote.refund_inr) > 0
    && Math.abs(ci.tx.amt + ci.e) <= 1 && Math.abs(ci.aw.c - ci.e) <= 1 && ci.aw.n > 0, `Rs ${ci.e}, ${ci.aw.n} flights`);
  const ce = await closeAt('europe');
  ok('Europe: for every flight within 14 days, at its distance band', ce.notice === 14 && ce.e > ci.e * 5 && Math.abs(Number(ce.quote.comp_inr) - ce.e) <= 1
    && Math.abs(ce.tx.amt + ce.e) <= 1 && ce.aw.n > ci.aw.n * 6, `Rs ${ce.e}, ${ce.aw.n} flights`);
  const cu = await closeAt('usa');
  ok('USA: refunds only', cu.e === 0 && cu.tx.n === 0);

  // a cut in round trips, counted at the week start against the region's notice
  const cutAt = async (reg) => {
    await q('begin');
    if (reg) await region(reg);
    const before = Object.fromEntries((await q(`select week, seats_e::float s from public.route_weeks where route_id = $1 and week between $2 and $2 + 2`, [R, vw]))
      .map((r) => [r.week, r.s]));
    await q(`update public.rotations set weekly_trips = 2 where route_id = $1`, [R]);
    const seats = Number(await one(`select 2 * seats_econ from public.aircraft where id = $1`, [AC]));
    await run(1);
    const after = Object.fromEntries((await q(`select week, cut_in_e::float c from public.route_weeks where route_id = $1 and week between $2 and $2 + 2`, [R, vw]))
      .map((r) => [r.week, r.c]));
    const tx = await txn(A, 'cancellation', ws);
    await q('rollback');
    return [0, 1, 2].map((k) => ({ want: (before[vw + k] - seats), got: after[vw + k] })).concat([{ tx }]);
  };
  const ki = await cutAt(null);
  ok('India: a cut counts only for the flights within a day', ki[0].want > 0 && Math.abs(ki[0].got - ki[0].want / 7) < 0.01
    && ki[1].got === 0 && ki[2].got === 0, JSON.stringify(ki.slice(0, 3)));
  const ke = await cutAt('europe');
  ok('Europe: for this week and next; travellers who lose their seat are paid', Math.abs(ke[0].got - ke[0].want) < 0.01
    && Math.abs(ke[1].got - ke[1].want) < 0.01 && ke[2].got === 0 && ke[3].tx.amt < 0, JSON.stringify(ke));

  // denied boarding: the region's amount plus a multiple of the fare
  const deniedAt = async (reg) => {
    await q('begin');
    if (reg) await region(reg);
    // 400 more travellers than seats, all overbooked (the most seats ever on sale are the seats now)
    await q(`update public.route_weeks x set bk_b = 0, rev_b = 0, seats_max_e = x.seats_e, bk_u = x.bk_u + y.add, rev_e = x.rev_e + y.add * y.f
      from (select route_id, week, greatest(0, seats_e - (bk_be + bk_l + bk_u)) + 400 as add, rev_e / nullif(bk_be + bk_l + bk_u, 0) as f
              from public.route_weeks where route_id = $1 and week = $2) y
     where x.route_id = y.route_id and x.week = y.week`, [R, vw]);
    await run(1);
    const x = (await q(`select comp::float n, (rev_e / nullif(bk_be + bk_l + bk_u, 0))::float fe from public.route_weeks where route_id = $1 and week = $2`, [R, vw]))[0];
    const v = (await q(`select game.wparam($1, 'denied_comp_inr')::float c, game.wparam($1, 'denied_fare_mult')::float m`, [W]))[0];
    const tx = await txn(A, 'denied_boarding', ws);
    await q('rollback');
    return { n: x.n, want: Math.round(2 * x.n * (v.c + v.m * x.fe)), tx };
  };
  const di = await deniedAt(null);
  const du = await deniedAt('usa');
  ok('denied boarding: India Rs 10,000 a traveller', di.n > 0 && Math.abs(di.tx.amt + di.want) <= 1 && di.want === Math.round(2 * di.n * 10000), `${di.n} travellers`);
  ok('USA: twice the fare', du.n > 0 && Math.abs(du.tx.amt + du.want) <= 1 && du.want !== di.want, `Rs ${du.want}`);

  // hedges lock the expected price 13 weeks ahead, not today's
  await q('begin');
  await q(`select public.set_hedge($1, $2)`, [A, P.hedge_step]);
  await q(`select public.set_usd_hedge($1, $2)`, [A, P.usd_hedge_step]);
  await q(`update public.worlds set fuel_walk = fuel_walk * 1.4, fuel_inr_kg = fuel_inr_kg * 1.4 where id = $1`, [W]);
  await run(1);
  const hg = (await q(`select h.price_inr_kg::float p, round(game.fuel_expect($1, $3::int * 7) * (1 + $4::numeric), 2)::float want,
      round(w.fuel_inr_kg * (1 + $4::numeric), 2)::float today, w.fuel_walk::float walk
    from public.fuel_hedges h join public.worlds w on w.id = $1 where h.airline_id = $2 and h.week = $5::int + $3::int`,
  [W, A, P.hedge_lead_weeks, P.hedge_premium, vw]))[0];
  const uh = (await q(`select h.rate_inr_usd::float r, round(game.fx_expect($1, $3::int * 7) * (1 + $4::numeric), 3)::float want
    from public.usd_hedges h where h.airline_id = $2 and h.week = $5::int + $3::int`, [W, A, P.hedge_lead_weeks, P.usd_hedge_premium, vw]))[0];
  const pv = await one(`select public.ops_preview($1)`, [A]);
  await q('rollback');
  ok('a fuel hedge locks the price expected in 13 weeks, with fuel 40% above normal: below today\'s', hg && hg.p === hg.want
    && hg.p < hg.today && hg.p > P.fuel_ref_inr_kg && Number(pv.fuel_lock) === hg.p, JSON.stringify(hg));
  ok('so does a dollar hedge, and Ops shows the price it locks', uh && uh.r === uh.want && Number(pv.usd.lock) === uh.r, JSON.stringify(uh));

  // ---------- 9. computer-run airlines under the same rules ----------
  d = await day();
  const bot = (await q(`select al.id, al.brand::float brand, al.administrations n, fin.credit_limit_inr::float lim,
      (select count(*)::int from public.routes r where r.airline_id = al.id and r.status = 'open') routes
    from public.airlines al join public.airline_finance fin on fin.airline_id = al.id
   where al.world_id = $1 and al.is_ai order by 5 desc limit 1`, [W]))[0];
  await q('begin');
  for (let k = 101; k <= 104; k++) {
    await q(`insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax) values ($1, $2, 1e9, -1e8, -2e8, 1000)`, [bot.id, k]);
  }
  await q(`insert into public.world_params (world_id, key, num, public) values ($1, 'credit_debt_limit', 6, true)
    on conflict (world_id, key) do update set num = excluded.num`, [W]);   // a world whose banks watch debt
  await q(`update public.airline_finance set debt_inr = 1e9 where airline_id = $1`, [bot.id]);
  await q(`select game.bank_week($1, $2)`, [W, d]);
  const bk = (await q(`select credit_limit_inr::float lim, credit_cut_from::float was from public.airline_finance where airline_id = $1`, [bot.id]))[0];
  await q('rollback');
  ok('banks cut a losing computer-run airline\'s credit line too', bk.was === bot.lim && bk.lim === Math.round(bot.lim * P.credit_cut_share));

  await q('begin');
  await q(`update public.airline_finance set cash_inr = -1e13, debt_inr = credit_limit_inr, insolvent_days = $2 - 1 where airline_id = $1`, [bot.id, P.insolvency_days]);
  await q(`select game.day_solvency($1, $2)`, [W, d]);
  const rs = (await q(`select fin.cash_inr::float cash, al.brand::float brand, al.administrations n, al.status,
      (select count(*)::int from public.routes r where r.airline_id = al.id and r.status = 'open') routes,
      (select count(*)::int from public.news n where n.airline_id = al.id and n.body like '%run out of money%') news
    from public.airlines al join public.airline_finance fin on fin.airline_id = al.id where al.id = $1`, [bot.id]))[0];
  await q('rollback');
  const shut = Math.max(0, Math.min(Math.ceil(bot.routes * 0.25), bot.routes - P.bot_keep_routes));
  ok('a computer-run airline out of money is restructured: the hole filled, a quarter of its routes closed, brand down',
    rs.cash === 0 && rs.routes === bot.routes - shut && shut > 0 && rs.brand === Math.max(0, bot.brand - P.restart_brand_hit)
    && rs.n === bot.n && rs.status === 'active' && rs.news === 1, `${bot.routes} routes to ${rs.routes}`);

  const intl = (await q(`select ro.aircraft_id, ro.route_id, ro.weekly_trips, r.airline_id from public.rotations ro
      join public.routes r on r.id = ro.route_id join public.airlines al on al.id = r.airline_id
      join public.airports a on a.iata = r.origin join public.airports b on b.iata = r.dest
      join public.seat_limits sl on sl.country = case when a.is_india then b.country else a.country end
     where al.world_id = $1 and al.is_ai and (not a.is_india or not b.is_india) order by ro.weekly_trips desc limit 1`, [W]))[0];
  if (intl) {
    await q('begin');
    await q(`insert into public.world_params (world_id, key, num, public) values ($1, 'seat_limit_mult', 0.001, true)
      on conflict (world_id, key) do update set num = excluded.num`, [W]);
    const sr = await one(`select public.set_rotation($1, $2, $3, $4)`, [intl.airline_id, intl.aircraft_id, intl.route_id, intl.weekly_trips]);
    await q('rollback');
    ok('a computer-run airline trims its flights to the free seats between countries', Number(sr.weekly_trips) < intl.weekly_trips,
      `${intl.weekly_trips} to ${sr.weekly_trips}`);
  } else ok('a computer-run airline flies abroad, to test the seat limits', false);

  // ---------- 3. administration ----------
  await q(`update public.airline_finance set cash_inr = -1e12, debt_inr = credit_limit_inr, insolvent_days = $2 - 1 where airline_id = $1`, [B, P.insolvency_days]);
  await run(1);
  const ab = (await q(`select fin.cash_inr::float cash, al.administrations n from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id where al.id = $1`, [B]))[0];
  ok('administration restarts with half the world\'s starting money', ab.n === 1 && ab.cash === Math.round(P.restart_cash_share * P.start_cash_inr),
    `Rs ${ab.cash / 1e7} cr`);

  // ---------- 10. tax, after losses carried forward; the season score ----------
  await runTo((x) => x === 90);
  const all = (await q(`select al.id, al.is_ai from public.airlines al where al.world_id = $1 and al.status = 'active' order by al.code`, [W]));
  const cf0 = {};
  all.forEach((a, i) => { cf0[a.id] = i % 2 ? 3e8 : 0; });
  for (const [id, v] of Object.entries(cf0)) await q(`update public.airline_finance set tax_loss_inr = $2 where airline_id = $1`, [id, v]);
  const botsBefore = new Set((await q(`select ac.id from public.aircraft ac join public.airlines al on al.id = ac.airline_id
    where al.world_id = $1 and al.is_ai`, [W])).map((r) => r.id));
  await run(1);
  const qr = await q(`select q.airline_id id, q.net_profit::float np, q.tax_inr::float tax, q.net_worth::float nw, q.score::float score,
      fin.tax_loss_inr::float cf, coalesce(d.c_tax, 0)::float ct,
      (select coalesce(-sum(amount_inr), 0) from public.transactions t where t.airline_id = q.airline_id and t.kind = 'tax' and t.game_day = 91)::float tt
    from public.quarterly_reports q join public.airline_finance fin on fin.airline_id = q.airline_id
    left join public.airline_daily d on d.airline_id = q.airline_id and d.game_day = 91
   where q.quarter = 1 and q.airline_id = any($1)`, [all.map((a) => a.id)]);
  let taxBad = [], paid = 0, shielded = 0;
  for (const r of qr) {
    const pre = r.np + r.tax, cf = cf0[r.id];
    const tax = Math.round(P.tax_rate * Math.max(0, pre - cf));
    const cfNew = pre < 0 ? cf - pre : Math.max(0, cf - pre);
    if (Math.abs(r.tax - tax) > 1 || Math.abs(r.cf - cfNew) > 1 || r.ct !== r.tax || r.tt !== r.tax) taxBad.push(r.id);
    if (r.tax > 0) paid++;
    if (cf > 0 && pre > 0) shielded++;
  }
  ok('a quarter\'s profit pays the region\'s tax, after losses carried forward; losses carry forward', qr.length === all.length && !taxBad.length
    && paid > 0 && shielded > 0, `${paid} paid, ${shielded} shielded by losses`);
  const sc = Object.fromEntries(qr.map((r) => [r.id, Math.round(r.nw + P.score_profit_mult * r.np) - r.score]));
  ok('each administration costs the season score one starting stake', sc[B] === P.start_cash_inr && sc[A] === 0, `${sc[B]}`);
  const fresh = await q(`select ac.id, tm.holding, tm.deposit_inr::float dep from public.aircraft ac join public.airlines al on al.id = ac.airline_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id where al.world_id = $1 and al.is_ai and not (ac.id = any($2))`, [W, [...botsBefore]]);
  const leased = Number(await one(`select count(*) from public.transactions t join public.airlines al on al.id = t.airline_id
    where al.world_id = $1 and al.is_ai and t.kind = 'lease' and t.game_day = 91`, [W]));
  ok('computer-run airlines grow from the lessor pool, with a deposit, like players', fresh.every((x) => x.holding === 'lease' && x.dep > 0)
    && leased === fresh.length, `${fresh.length} aircraft`);

  // ---------- the region values of a world ----------
  const keys = await q(`select option, string_agg(k, ',' order by k) ks from public.world_options o, jsonb_object_keys(o.vals) k
    where setting = 'region' group by option`);
  ok('every region sets the same rules', keys.length === 9 && new Set(keys.map((r) => r.ks)).size === 1 && !keys[0].ks.split(',').includes('interest_year'),
    keys[0]?.ks);
  const nw = await one(`select public.create_world('Regions 22', '{"bots": "none", "min_players": 1}')`);
  const wp = Object.fromEntries((await q(`select key, num::float from public.world_params where world_id = $1`, [nw.world_id])).map((r) => [r.key, r.num]));
  ok('a new India world gets India\'s passenger rights, tax and interest on cash, and its banks\' credit rate',
    wp.cancel_notice_days === 1 && wp.cancel_comp_3_inr === 10000 && wp.tax_rate === 0.25 && wp.cash_interest_year === 0.06
    && wp.interest_year > 0, JSON.stringify({ n: wp.cancel_notice_days, tax: wp.tax_rate, i: wp.interest_year }));
  await fails('regions without airports cannot be chosen yet', `select public.create_world('Europe 22', '{"region": "europe"}')`, /Choose one of the region options/);
}
