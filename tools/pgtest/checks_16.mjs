// Currency, the basics (migration 0026): dollar costs and the currency effect, dollar hedging, where you sell on
// international routes, rupee loans for ordered aircraft.
export async function checks16(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Currency (0026)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day')`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 16', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1600' from w returning world_id`);
  const A = await one(`select public.found_airline('test1600', 'Sixteen Air', 'SX', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const day = async () => Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  if (await day() === 0) await run(7);

  // ---------- routes: one domestic, one international ----------
  const ac = (await q(`select a.id, a.type_id from public.aircraft a join public.aircraft_terms tm on tm.aircraft_id = a.id
    where a.airline_id = $1 and a.status = 'active' order by a.reg`, [A]));
  const im = (await q(`select case when m.a = 'DEL' then m.b else m.a end far from public.markets m
    join public.aircraft_types t on t.id = $1
    where m.intl and 'DEL' in (m.a, m.b) and m.km < t.range_km * 0.8 order by m.n_biz + m.n_lei + m.n_bud desc limit 1`, [ac[0].type_id]))[0];
  const RI = await one(`select public.open_route($1, 'DEL', $2)`, [A, im.far]);
  const RD = await one(`select public.open_route($1, 'DEL', 'AMD')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [A, ac[0].id, RI]);

  // ---------- 1. dollar hedging, like fuel hedging ----------
  await fails('dollar hedging only in steps of 25%, up to 75%', `select public.set_usd_hedge('${A}', 0.3)`, /steps of/);
  await fails('no more than 75% of a week\'s dollar costs', `select public.set_usd_hedge('${A}', 1)`, /up to/);
  const hs = await one(`select public.set_usd_hedge($1, 0.5)`, [A]);
  await run(7 + ((7 - (await day()) % 7) % 7));
  const wk = Number(await one(`select game.week_of(game_day) from public.worlds where id = $1`, [W]));
  const bought = (await q(`select week, share::float, rate_inr_usd::float rate from public.usd_hedges where airline_id = $1 order by week desc limit 1`, [A]))[0];
  const fxNow = Number(await one(`select fx_inr_usd from public.worlds where id = $1`, [W]));
  ok('each week start buys that share of the dollars 13 weeks ahead, at the week\'s rate plus 1%',
    bought && bought.week === wk + 13 && bought.share === 0.5 && Math.abs(bought.rate - Math.round(fxNow * 1.01 * 1000) / 1000) < 0.002
    && hs.from_week <= wk + 13, bought && `week ${bought.week}, Rs ${bought.rate}`);

  // the same day with the rupee at 100: no hedge, and half the week's dollars bought at 90
  const usdDay = async (share) => {
    await q('begin');
    await q(`update public.worlds set fx_walk = 100, fx_inr_usd = 100 where id = $1`, [W]);
    const d = (await day()) + 1, w = Number(await one(`select game.week_of($1)`, [d]));
    await q(`delete from public.usd_hedges where airline_id = $1 and week = $2`, [A, w]);
    if (share > 0) await q(`insert into public.usd_hedges (airline_id, week, share, rate_inr_usd) values ($1, $2, $3, 90)`, [A, w, share]);
    await q(`select game.run_day($1)`, [W]);
    const r = (await q(`select d.usd_cost_usd::float usd, d.usd_cost_inr::float inr, d.usd_hedge_inr::float hedge, d.fx_effect_inr::float fx,
        d.c_rent::float rent, wd.fx_inr_usd::float spot
      from public.airline_daily d join public.world_daily wd on wd.world_id = $2 and wd.game_day = d.game_day
      where d.airline_id = $1 and d.game_day = $3`, [A, W, d]))[0];
    await q('rollback');
    return r;
  };
  const u0 = await usdDay(0), u5 = await usdDay(0.5);
  ok('dollar costs are shown against Rs 90: what the weaker rupee added',
    u0.usd > 0 && Math.abs(u0.inr - u0.usd * u0.spot) < 3 && Math.abs(u0.fx - (u0.inr - u0.usd * 90)) < 3 && u0.hedge === 0,
    `$${Math.round(u0.usd)} a day, Rs ${Math.round(u0.fx)} more than at Rs 90`);
  const rate5 = 0.5 * 90 + 0.5 * u5.spot;
  ok('hedged: half the dollars cost the locked rate; the rent is paid at the blend',
    Math.abs(u5.rent / u0.rent - rate5 / u0.spot) < 1e-5 && u5.hedge > 0 && Math.abs(u5.hedge - (u5.usd * u5.spot - u5.inr)) < 3
    && u5.fx < u0.fx, `rent Rs ${Math.round(u5.rent)} at Rs ${rate5.toFixed(2)}; hedge saved Rs ${Math.round(u5.hedge)} a day`);

  // ---------- 2. where you sell, on international routes ----------
  await fails('only international routes sell abroad', `select public.set_sell_where('${A}', '${RD}', 'abroad')`, /Only international/);
  await fails('three choices', `select public.set_sell_where('${A}', '${RI}', 'everywhere')`, /Choose india/);
  ok('a route sells mostly in India until changed', (await one(`select sell_where from public.route_plans where route_id = $1`, [RI])) === 'india');
  if ((await day()) % 7 !== 0) await run(7 - (await day()) % 7);
  const sellWeek = async (where) => {
    await q('begin');
    await q(`select public.set_sell_where($1, $2, $3)`, [A, RI, where]);
    await q(`update public.worlds set fx_walk = 100, fx_inr_usd = 100 where id = $1`, [W]);
    const before = await q(`select week, bk_be + bk_l + bk_u e, bk_b b, rev_e + rev_b rev from public.route_weeks where route_id = $1`, [RI]);
    await q(`select game.sell_week($1, $2)`, [W, (await day()) + 1]);
    const after = await q(`select week, bk_be + bk_l + bk_u e, bk_b b, rev_e + rev_b rev, price_e, price_b from public.route_weeks where route_id = $1`, [RI]);
    await q('rollback');
    let pax = 0, rev = 0, val = 0;
    for (const a of after) {
      const b = before.find((x) => x.week === a.week) || { e: 0, b: 0, rev: 0 };
      const de = Number(a.e) - Number(b.e), db = Number(a.b) - Number(b.b);
      pax += de + db; rev += Number(a.rev) - Number(b.rev); val += de * Number(a.price_e || 0) + db * Number(a.price_b || 0);
    }
    return { pax, rev, mult: rev / val };
  };
  const sIn = await sellWeek('india'), sBo = await sellWeek('both'), sAb = await sellWeek('abroad');
  const fxm = (s) => 1 + s * (100 / 90 - 1);
  ok('selling abroad reaches more travellers', sAb.pax > sBo.pax && sBo.pax > sIn.pax,
    `a week's sales: ${sIn.pax.toFixed(0)} / ${sBo.pax.toFixed(0)} / ${sAb.pax.toFixed(0)} travellers (+${((sAb.pax / sIn.pax - 1) * 100).toFixed(1)}% abroad)`);
  ok('with the rupee at 100, tickets priced in dollars bring more rupees: 20%, 45% or 70% of them',
    Math.abs(sIn.mult - fxm(0.2)) < 0.001 && Math.abs(sBo.mult - fxm(0.45)) < 0.001 && Math.abs(sAb.mult - fxm(0.7)) < 0.001,
    `x ${sIn.mult.toFixed(4)} / ${sBo.mult.toFixed(4)} / ${sAb.mult.toFixed(4)}`);

  // the sales team abroad: a share of the route's revenue, in its costs (not on a domestic route)
  const firstWeek = Number(await one(`select min(week) from public.route_weeks where route_id = $1`, [RI]));
  while ((await day()) + 1 < (firstWeek - 1) * 7 + 2) await run(1);   // the second day of its first flight week
  const flyDay = async (where) => {
    await q('begin');
    await q(`update public.route_plans set sell_where = $2 where route_id = $1`, [RI, where]);
    const d = (await day()) + 1;
    await q(`select game.run_day($1)`, [W]);
    const r = (await q(`select revenue_inr::float rev, var_cost_inr::float vc from public.route_daily where route_id = $1 and game_day = $2`, [RI, d]))[0];
    const c = (await q(`select c_dist::float dist, rev_ticket::float tix from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d]))[0];
    await q('rollback');
    return { ...r, ...c };
  };
  const fIn = await flyDay('india'), fAb = await flyDay('abroad');
  ok('a sales team abroad costs 5.5% of the route\'s ticket revenue, in the route\'s costs and sales',
    fIn.tix > 0 && fAb.tix === fIn.tix && Math.abs(fAb.vc - fIn.vc - 0.055 * fAb.tix) < 3 && Math.abs(fAb.dist - fIn.dist - 0.055 * fAb.tix) < 3,
    `Rs ${Math.round(fAb.vc - fIn.vc)} on Rs ${Math.round(fAb.tix)} of tickets`);

  // ---------- 3. a rupee loan when ordering ----------
  await q(`update public.airline_finance set cash_inr = 5e10, debt_inr = 0 where airline_id = $1`, [A]);
  const ord = await one(`select public.order_aircraft($1, 'A20N', 'DEL', 0, null, 29, 'loan_inr')`, [A]);
  const lt0 = (await q(`select loan_ccy, finance_loan from public.aircraft_terms where aircraft_id = $1`, [ord.aircraft_id]))[0];
  ok('an order can be paid with a rupee loan', lt0.loan_ccy === 'inr' && lt0.finance_loan === true);
  await q(`update public.aircraft set available_day = $2 where id = $1`, [ord.aircraft_id, (await day()) + 1]);
  const fx1 = Number(await one(`select fx_inr_usd from public.worlds where id = $1`, [W]));
  for (let i = 0; i < 8 && (await one(`select status from public.aircraft where id = $1`, [ord.aircraft_id])) === 'delivering'; i++) await run(1);
  const lt = (await q(`select holding, coalesce(loan_usd, 0)::float usd, loan_inr::float inr, loan_pay_inr_day::float pay, deposit_inr::float dep
    from public.aircraft_terms where aircraft_id = $1`, [ord.aircraft_id]))[0];
  const fxd = Number(await one(`select fx_inr_usd from public.world_daily where world_id = $1 and game_day = $2`, [W, await day()]));
  const bal = Math.round(ord.price_usd * fxd) - ord.deposit_inr;
  ok('on delivery the balance is borrowed in rupees over 12 years, nothing in dollars',
    lt.holding === 'owned' && lt.usd === 0 && lt.dep === 0 && Math.abs(lt.inr + lt.pay - bal) < 1 && Math.abs(lt.pay - bal / (12 * 364)) < 0.01,
    `Rs ${(lt.inr / 1e7).toFixed(1)} cr outstanding (fx ${fx1} on order, ${fxd} on delivery)`);
  await run(1);
  const ld = (await q(`select loan_repaid::float rep, c_interest::float intr from public.airline_daily where airline_id = $1 and game_day = $2`, [A, await day()]))[0];
  const lt2 = Number(await one(`select loan_inr from public.aircraft_terms where aircraft_id = $1`, [ord.aircraft_id]));
  ok('each day pays principal and 10.5% interest in rupees', Math.abs(ld.rep - Math.round(lt.pay)) <= 1
    && Math.abs(ld.intr - Math.round(lt.inr * 0.105 / 364)) <= 1 && Math.abs(lt2 - (lt.inr - lt.pay)) < 0.01,
    `Rs ${Math.round(ld.intr)} interest a day`);
  const sale = await one(`select public.return_aircraft($1, $2)`, [A, ord.aircraft_id]);
  const book = ord.price_usd * fxd * (1 - 2 * 0.036 / 364);
  ok('selling repays the rupee loan from the proceeds', Math.abs(sale.cash_inr - (0.85 * book - lt2)) < 2e5,
    `Rs ${(sale.cash_inr / 1e7).toFixed(1)} cr to the airline`);

  await q(`delete from public.worlds where id = $1`, [W]);
}
