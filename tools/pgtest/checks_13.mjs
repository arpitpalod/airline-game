// Ops (migration 0023): fuel hedging, maintenance strategies, operating styles, cost benchmarks, automatic pilot settings.
export async function checks13(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Ops (0023)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day')`);
  ok('four maintenance strategies and four operating styles, as game values',
    Number(await one(`select count(*) from public.maint_plans`)) === 4 && Number(await one(`select count(*) from public.op_styles`)) === 4);
  ok('fuel shocks are now 25 to 45%', Number(await one(`select num from public.game_params where key = 'event_fuel_mult_min'`)) === 1.25);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling, bot_scale)
    values ('Test 13', 0.5, 25, false, 0, false, 0) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1300' from w returning world_id`);
  const A = await one(`select public.found_airline('test1300', 'Ops Air', 'OA', 'DEL')`);
  const B = await one(`select public.found_airline('test1300', 'Two Ops', 'TO', 'BOM')`);
  const C = await one(`select public.found_airline('test1300', 'Three Ops', 'TH', 'BLR')`);
  ok('every airline gets its Ops settings: pay as you go, standard, no hedge',
    (await one(`select string_agg(maint_plan || '/' || op_style || '/' || hedge_share, ',') from public.airline_ops where airline_id in ($1, $2, $3)`, [A, B, C]))
      === 'payg/standard/0,payg/standard/0,payg/standard/0');
  // each airline's founding aircraft becomes an operating lease (wet leases carry no maintenance) and flies one route
  await q(`update public.aircraft_terms set holding = 'lease', lease_usd_month = 380000, wet_usd_bh = null
    where aircraft_id in (select id from public.aircraft where airline_id in ($1, $2, $3))`, [A, B, C]);
  const ac = await one(`select id from public.aircraft where airline_id = $1`, [A]);
  const rt = await one(`select public.open_route($1, 'DEL', 'BOM')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [A, ac, rt]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1), public.open_route($1, 'BOM', 'DEL'), 14)`, [B]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1), public.open_route($1, 'BLR', 'DEL'), 14)`, [C]);
  await q(`select public.admin_start_world($1)`, [W]);   // plays week 1 (start_first_week)
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const day = async () => Number(await one(`select game_day from public.worlds where id = $1`, [W]));

  // pilots: no longer a player setting
  const U = '00000000-0000-0000-0000-0000000000b1';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [U]);
  await q(`update public.airlines set user_id = $1 where id = $2`, [U, A]);
  await as(U);
  await fails('a player cannot set pilot pay or spares any more', `select public.set_pilot_policy('${A}', 0.9, 0.05, 0, true)`, /set automatically/);
  // ---------- hedging ----------
  await fails('a hedge goes in steps of 25%, up to 75%', `select public.set_hedge('${A}', 0.3)`, /steps of/);
  await fails('and never above 75%', `select public.set_hedge('${A}', 1)`, /up to/);
  const h = await one(`select public.set_hedge($1, 0.5)`, [A]);
  await as(null);
  const w0 = Math.floor((await day()) / 7) + 1;
  await run(1);   // the next week starts: half of week w0 + 13's fuel is bought at that day's price + 2%
  const bought = (await q(`select h.week, h.share::float, h.price_inr_kg::float p, w.fuel_inr_kg::float f
    from public.fuel_hedges h, public.worlds w where w.id = $2 and h.airline_id = $1`, [A, W]))[0];
  ok('each week a hedging airline buys its share of the fuel 13 weeks ahead, at that week\'s price + 2%',
    bought && bought.week === w0 + 13 && bought.share === 0.5 && Math.abs(bought.p - Math.round(bought.f * 1.02 * 100) / 100) < 0.011
      && h.from_week === w0 + 13, JSON.stringify({ bought, h }));
  await run(6);
  // a hedge for this week (as if bought 13 weeks ago, at Rs 80 a kg): half the fuel at 80, half at today's price
  const wk = Math.floor((await day()) / 7) + 1;
  await q(`insert into public.fuel_hedges values ($1, $2, 0.5, 80)`, [A, wk]);
  await run(1);
  const f = (await q(`select d.c_fuel::float c, d.fuel_kg::float kg, d.hedge_inr::float h, w.fuel_inr_kg::float p
    from public.airline_daily d, public.worlds w where w.id = $2 and d.airline_id = $1 and d.game_day = w.game_day`, [A, W]))[0];
  ok('fuel in a hedged week: the hedged half at the locked price, the rest at today\'s',
    f.kg > 0 && Math.abs(f.c / (f.kg * (0.5 * 80 + 0.5 * f.p)) - 1) < 1e-4 && Math.abs(f.h / (f.kg * f.p - f.c) - 1) < 1e-3,
    `Rs ${Math.round(f.h)} saved against today's Rs ${f.p} a kg`);

  // ---------- maintenance ----------
  const costsAt = async (setup) => {   // one day under a strategy, rolled back, to compare like with like
    await q('begin');
    try {
      await q(`select setseed(0.25)`);   // the same fuel and currency moves in each comparison
      await t.db.exec(setup);
      await run(1);
      return (await q(`select d.c_maint::float m, d.c_fuel::float f, d.fuel_kg::float kg, d.c_crew::float c, a.otp::float otp
        from public.airline_daily d join public.airlines a on a.id = d.airline_id join public.worlds w on w.id = a.world_id
        where d.airline_id = '${A}' and d.game_day = w.game_day`))[0];
    } finally { await q('rollback'); }
  };
  const age = Number(await one(`select greatest(0, w.game_day + 1 - a.built_day) / 364.0 from public.aircraft a, public.worlds w where a.id = $1 and w.id = $2`, [ac, W]));
  const payg = await costsAt(`select 1`);
  const contract = await costsAt(`update public.airline_ops set maint_plan = 'contract' where airline_id = '${A}'`);
  const hangar = await costsAt(`update public.airline_ops set maint_plan = 'hangar' where airline_id = '${A}'`);
  const lean = await costsAt(`update public.airline_ops set maint_plan = 'lean' where airline_id = '${A}'`);
  ok('maintenance: a flight-hour contract costs 1.12x with no ageing; lean 0.85x with faster ageing',
    Math.abs(contract.m / payg.m - 1.12 / (1 + 0.03 * age)) < 0.002 && Math.abs(lean.m / payg.m - 0.85 * (1 + 0.04 * age) / (1 + 0.03 * age)) < 0.002,
    `age ${age.toFixed(1)} years: contract x${(contract.m / payg.m).toFixed(3)}, lean x${(lean.m / payg.m).toFixed(3)}`);
  ok('an own hangar: 0.75x the work plus its fixed cost a week', Math.abs(hangar.m - (0.75 * payg.m + 60000000 / 7)) <= 1.5, `${hangar.m} against ${payg.m}`);

  await as(U);
  const ch = await one(`select public.set_maint_plan($1, 'contract')`, [A]);
  await as(null);
  ok('a new strategy waits for the start of the next week', ch.from_day === Math.ceil((await day()) / 7) * 7 + 1
    && (await one(`select maint_plan from public.airline_ops where airline_id = $1`, [A])) === 'payg', JSON.stringify(ch));
  await run(ch.from_day - (await day()));
  const ops = (await q(`select maint_plan, maint_locked_until from public.airline_ops where airline_id = $1`, [A]))[0];
  ok('then takes effect, and a contract runs 52 weeks', ops.maint_plan === 'contract' && ops.maint_locked_until === ch.from_day + 364);
  await as(U);
  await fails('leaving the contract early is refused', `select public.set_maint_plan('${A}', 'lean')`, /runs until week/);
  await as(null);
  // an own hangar: its setup is paid at once and it opens 13 weeks later (airline B)
  const U2 = '00000000-0000-0000-0000-0000000000b2';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [U2]);
  await q(`update public.airlines set user_id = $1 where id = $2`, [U2, B]);
  const cash0 = Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [B]));
  await as(U2);
  const hg = await one(`select public.set_maint_plan($1, 'hangar')`, [B]);
  await as(null);
  const cash1 = Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [B]));
  ok('an own hangar costs Rs 100 crore to set up, paid now, and opens 13 weeks later',
    cash0 - cash1 === 1000000000 && hg.from_day === Math.ceil(((await day()) + 1 + 91 - 1) / 7) * 7 + 1, JSON.stringify(hg));

  // groundings follow the strategy and are counted; a lean airline grounds more
  await q(`update public.game_params set num = 0.03 where key = 'ground_prob_day'`);
  await q(`update public.airline_ops set maint_plan = 'lean' where airline_id = $1`, [C]);
  await q(`insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata, econ_pitch, seats_econ, seats_biz)
    select $1, 'A20N', a.id, 'VT-T' || lpad((row_number() over ())::text, 3, '0') || substr(a.code, 1, 1), 1, 'active', 1, b.iata, 29, 180, 0
      from public.airlines a join public.bases b on b.airline_id = a.id cross join generate_series(1, 100)
     where a.id in ($2, $3)`, [W, A, C]);
  await q(`insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month)
    select id, airline_id, 'lease', 380000 from public.aircraft where reg like 'VT-T%' on conflict do nothing`);
  await q(`select setseed(0.5)`);   // the same random draws every run
  await run(7);
  const g = await q(`select airline_id, sum(groundings)::int n from public.airline_daily where airline_id in ($1, $2) and game_day > $3 - 7 group by airline_id`, [A, C, await day()]);
  const gA = g.find((x) => x.airline_id === A)?.n ?? 0, gC = g.find((x) => x.airline_id === C)?.n ?? 0;
  ok('groundings are counted, and the lean airline grounds more than the one on a contract (0.7x against 1.8x)', gC > 1.5 * gA && gA > 0, `contract ${gA}, lean ${gC}`);
  await q(`update public.game_params set num = 0 where key = 'ground_prob_day'`);
  await q(`update public.aircraft set status = 'active', available_day = 1 where world_id = $1 and status = 'grounded'`, [W]);

  // ---------- operating style ----------
  const saver = await costsAt(`update public.airline_ops set op_style = 'saver' where airline_id = '${A}'`);
  const std = await costsAt(`select 1`);
  ok('fuel saver: 4% less fuel, crew hours and maintenance 5% dearer', Math.abs(saver.kg / std.kg - 0.96) < 0.001 && Math.abs(saver.m / std.m - 1.05) < 0.001);
  const quick = await costsAt(`update public.airline_ops set op_style = 'quick' where airline_id = '${A}'`);
  const flights = Number(await one(`select flights from public.airline_daily where airline_id = $1 order by game_day desc limit 1`, [A]));
  ok('high utilisation: a crew allowance of Rs 2,500 for each quick turn', Math.abs(quick.c - std.c - 2500 * flights) <= 2, `${flights} flights a day`);
  // turns: how many round trips fit (an A320neo, Delhi-Mumbai)
  const fit = async () => {
    const r = (await q(`select m.km / 830.0 + 0.7 as block, l.min_turn_min as turn from public.aircraft a, public.worlds w, public.markets m,
      lateral public.layout_calc(a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch, w.crew_rule) l
      where a.id = $1 and w.id = $2 and m.a = 'BOM' and m.b = 'DEL'`, [ac, W]))[0];
    return (d) => Math.floor((7 * 17) / (2 * (Number(r.block) + (Number(r.turn) + d) / 60)));
  };
  const n = await fit();
  await as(U);
  await fails('at standard turns, one round trip too many does not fit', `select public.set_rotation('${A}', '${ac}', '${rt}', ${n(0) + 1})`, /hours a week/);
  await q(`select public.set_op_style($1, 'quick')`, [A]);
  const more = await one(`select public.set_rotation($1, $2, $3, $4)`, [A, ac, rt, n(-10)]);
  const back = await one(`select public.set_op_style($1, 'punctual')`, [A]);
  await as(null);
  ok('with quick turns (10 minutes shorter) more round trips fit; going back to longer turns reports the aircraft that no longer fit',
    n(-10) > n(0) && more.weekly_trips === n(-10) && back.over === 1, `${n(0)} -> ${n(-10)} round trips a week`);
  await q(`select public.set_op_style($1, 'standard')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [A, ac, rt]);
  const pun = await costsAt(`update public.airline_ops set op_style = 'punctual' where airline_id = '${A}'`);
  ok('punctual: 4% more fuel and better punctuality', Math.abs(pun.kg / std.kg - 1.04) < 0.001 && pun.otp > std.otp);

  // ---------- previews and benchmarks ----------
  await q(`update public.game_params set num = 0.004 where key = 'ground_prob_day'`);
  await as(U);
  const pv = await one(`select public.ops_preview($1)`, [A]);
  await fails('a player cannot preview another airline', `select public.ops_preview('${(await one(`select id from public.airlines where world_id = '${W}' and id not in ('${A}', '${B}')`))}')`, /not your airline/);
  await as(null);
  await q(`update public.game_params set num = 0 where key = 'ground_prob_day'`);
  const P = Object.fromEntries(pv.plans.map((x) => [x.key, x])), S = Object.fromEntries(pv.styles.map((x) => [x.key, x]));
  ok('the Ops preview: each strategy\'s cost a week, groundings and round trips that fit, for this airline',
    pv.plans.length === 4 && pv.styles.length === 4 && P.hangar.fixed_week === 60000000 && P.lean.groundings_qtr > P.payg.groundings_qtr
      && S.quick.trips_fit > S.standard.trips_fit && S.punctual.trips_fit < S.standard.trips_fit && S.saver.fuel_week < S.standard.fuel_week,
    `${pv.aircraft} aircraft; payg Rs ${Math.round(P.payg.cost_week / 1e5)} lakh a week, hangar Rs ${Math.round(P.hangar.cost_week / 1e5)} lakh`);
  const bm = await q(`select line, airlines, median_inr_ask::float m from public.cost_benchmarks where world_id = $1 order by line`, [W]);
  ok('cost benchmarks: the median cost per seat-km of each line, over the airlines flying', bm.length === 7 && bm.every((x) => x.airlines === 3 && x.m >= 0),
    bm.map((x) => `${x.line} ${x.m.toFixed(2)}`).join(', '));
  await q(`delete from public.worlds where id = $1`, [W]);
}
