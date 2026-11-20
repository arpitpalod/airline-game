// Selling 26 weeks ahead (migration 0019): strategies, bookings and cash before flights, revenue when flown, no-shows,
// passengers who cannot board, refunds, a new route's lead time, what rivals see, and the admin's strategy settings.
export async function checks9(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  console.log('Selling ahead (0019)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day')`);
  await t.db.exec(`alter table public.airlines enable trigger airlines_first_flight; alter table public.aircraft enable trigger aircraft_week_start`);

  ok('four ways to sell, tuned by the admin', (await one(`select string_agg(key, ',' order by sort) from public.rm_strategies`)) === 'fill,balanced,top,follow');

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 9', 0.5, 25, false, 13, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test9000' from w returning world_id`);
  const P = await one(`select public.found_airline('test9000', 'Sell Air', 'SA', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const ref = Number(await one(`select ref_fare from public.markets where a = 'BOM' and b = 'DEL'`));
  const rt = await one(`select public.open_route($1, 'DEL', 'BOM', ${Math.round(ref)})`, [P]);
  const ac = await one(`select id from public.aircraft where airline_id = $1 order by reg limit 1`, [P]);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [P, ac, rt]);
  ok('a route opened in the pre-launch flies from the first flights, and sells Balanced', (await one(`select first_flight_day from public.routes where id = $1`, [rt])) === 92
    && (await one(`select strategy from public.route_plans where route_id = $1`, [rt])) === 'balanced');
  await fails('fares are no longer set by hand', `select public.set_fares('${P}', '${rt}', 5000)`, /choose a strategy/);
  await fails('only the four strategies', `select public.set_strategy('${P}', '${rt}', 'cheap')`, /Choose Fill every seat/);

  const day = () => one(`select game_day from public.worlds where id = $1`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  const cash = async () => Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [P]));
  const c0 = await cash();
  await run(7);
  const wk = await q(`select week, price_e, (bk_be + bk_l + bk_u + bk_b)::float sold, rev_e::float + rev_b::float rev from public.route_weeks where route_id = $1 order by week`, [rt]);
  ok('in week 1 the flights of weeks 14 to 26 go on sale, and sell', wk.length === 13 && wk[0].week === 14 && wk[12].week === 26 && wk.every((x) => x.sold > 0 && x.price_e > 0),
    `${wk.length} weeks, ${Math.round(wk.reduce((s, x) => s + x.sold, 0))} seats each way`);
  const aw = (await q(`select sales_inr::float s, refunds_inr::float r, advance_inr::float a from public.airline_weeks where airline_id = $1 and week = 1`, [P]))[0];
  const rev2 = 2 * wk.reduce((s, x) => s + x.rev, 0);
  ok('the money comes in when tickets sell: cash up by the week\'s sales, all of it advance sales', Math.abs((await cash()) - c0 - aw.s) <= 1
    && Math.abs(aw.s - rev2) <= 2 && Math.abs(aw.a - rev2) <= 2, `Rs ${(aw.s / 1e7).toFixed(2)} crore`);
  ok('nothing flies in the pre-launch', (await one(`select count(*)::int from public.route_daily where route_id = $1`, [rt])) === 0);

  // strategies change the fares of the flight week that goes on sale (adj starts at 1, 26 weeks out)
  await q(`select public.set_strategy($1, $2, 'top')`, [P, rt]);
  await run(7);
  const top = Number(await one(`select price_e from public.route_weeks where route_id = $1 and week = 27`, [rt]));
  ok('a flight week goes on sale at 0.85 of the reference fare with Balanced, 1.00 with Top fares',
    Math.abs(wk[12].price_e / ref - 0.85) < 0.01 && Math.abs(top / ref - 1) < 0.01, `${wk[12].price_e} and ${top} against ${ref}`);
  await q(`select public.set_strategy($1, $2, 'balanced')`, [P, rt]);

  // a flight week overbooked beyond its seats: those who turn up beyond the seats cannot board
  await q(`update public.route_weeks set bk_l = seats_e * 1.3, rev_e = seats_e * 1.3 * 6000 where route_id = $1 and week = 15`, [rt]);
  // and a flight week whose schedule is cut after selling: a refund only
  await run(91 - 14);   // to day 91
  const cA = await cash();
  await run(1);         // day 92: selling for week 14, then the first flights
  const w14 = (await q(`select (bk_be + bk_l + bk_u + bk_b)::float sold, noshow::float ns, denied::float den, flown_e::float fe, rev_flown_e::float + rev_flown_b::float rf
    from public.route_weeks where route_id = $1 and week = 14`, [rt]))[0];
  ok('week 14 closes: about 1 in 20 do not turn up; the rest fit', w14.ns / w14.sold > 0.01 && w14.ns / w14.sold < 0.15 && w14.den === 0,
    `${(100 * w14.ns / w14.sold).toFixed(1)}% no-shows of ${Math.round(w14.sold)}`);
  const rd = (await q(`select pax_econ, revenue_inr::float rev from public.route_daily where route_id = $1 and game_day = 92`, [rt]))[0];
  ok('each day of the week flies a seventh of those who turned up', rd && Math.abs(rd.pax_econ - 2 * w14.fe / 7) <= 1, `${rd?.pax_econ} passengers`);
  await run(4);   // day 96
  const c96 = await cash();
  await run(1);   // day 97, a plain flying day
  const d97 = (await q(`select rev_anc::float anc, (c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead
    + c_interest + loan_repaid)::float cost, refunds_inr::float rf, rev_ticket::float tk from public.airline_daily where airline_id = $1 and game_day = 97`, [P]))[0];
  ok('on a flying day cash moves by extras less costs: the tickets were paid for when sold', d97.tk > 0
    && Math.abs((await cash()) - c96 - (d97.anc - d97.cost - d97.rf)) <= 1, `ticket revenue Rs ${(d97.tk / 1e5).toFixed(1)} lakh, not in cash`);
  await run(1);   // day 98
  const flown = Number(await one(`select sum(rev_ticket)::float from public.airline_daily where airline_id = $1 and game_day between 92 and 98`, [P]));
  ok('revenue counts when the flights fly: the week\'s fares, no-shows\' included', Math.abs(flown - 2 * w14.rf) / flown < 0.01,
    `Rs ${(flown / 1e7).toFixed(2)} crore`);
  await run(1);   // day 99: week 15 closes
  const w15 = (await q(`select (bk_be + bk_l + bk_u + bk_b)::float sold, seats_e::float se, noshow::float ns, denied::float den, comp::float comp
    from public.route_weeks where route_id = $1 and week = 15`, [rt]))[0];
  const aw15 = (await q(`select refunds_inr::float r, comp_inr::float c from public.airline_weeks where airline_id = $1 and week = 15`, [P]))[0];
  ok('an overbooked week: those beyond the seats cannot board, get their fare back and Rs 10,000 each',
    w15.den > 0 && Math.abs(w15.den - (w15.sold - w15.ns - w15.se)) < 0.01 && Math.abs(w15.comp - w15.den) < 0.01
      && Math.abs(aw15.c - 2 * w15.den * 10000) <= 1 && aw15.r > 0, `${Math.round(2 * w15.den)} passengers`);
  ok('and the compensation is a cost', Number(await one(`select -sum(pnl_inr)::float from public.transactions where airline_id = $1 and kind = 'denied_boarding'`, [P])) === Math.round(aw15.c));

  // a schedule cut after selling: passengers who cannot fly get a refund only
  await run(6);   // day 105, the end of week 15
  await q(`select public.set_rotation($1, $2, $3, 2)`, [P, ac, rt]);
  await run(1);   // day 106: week 16 closes with fewer seats
  const w16 = (await q(`select denied::float den, comp::float comp from public.route_weeks where route_id = $1 and week = 16`, [rt]))[0];
  ok('a schedule cut after selling: those without a seat get a refund, no compensation', w16.den > 0 && w16.comp === 0, `${Math.round(2 * w16.den)} passengers`);
  await q(`select public.set_rotation($1, $2, $3, 14)`, [P, ac, rt]);
  await run(6);   // day 112

  // a new route goes on sale at once and flies two weeks later
  const d0 = await day();
  const r2 = await one(`select public.open_route($1, 'DEL', 'BLR', 6000)`, [P]);
  ok('a route opened during flying goes on sale now and flies two weeks later', (await one(`select first_flight_day from public.routes where id = $1`, [r2])) === d0 + 1 + 14);

  // what rivals see
  ok('rivals see each airline\'s fares and flights on a market, and what changed',
    (await one(`select count(*)::int from public.market_watch where world_id = $1 and a = 'BOM' and b = 'DEL'`, [W])) >= 2
      && (await one(`select count(*)::int from public.market_moves where world_id = $1 and kind = 'enter'`, [W])) > 0);

  // closing a route refunds its tickets for later weeks
  const adv = Number(await one(`select 2 * sum(rev_e + rev_b)::float from public.route_weeks where route_id = $1 and flown_e is null`, [rt]));
  await q(`select public.close_route($1, $2)`, [P, rt]);
  await run(7);
  const wk2 = Number(await one(`select max(week) from public.airline_weeks where airline_id = $1`, [P]));
  ok('closing a route refunds every ticket sold for its later weeks', (await one(`select count(*)::int from public.route_weeks where route_id = $1 and flown_e is null`, [rt])) === 0
    && Math.abs(Number(await one(`select refunds_inr from public.airline_weeks where airline_id = $1 and week = $2`, [P, wk2])) - adv) <= 2, `Rs ${(adv / 1e7).toFixed(2)} crore`);

  // administration takes the tickets sold with it (the restart capital does not refund them)
  await q(`select public.set_rotation($1, $2, $3, 14)`, [P, ac, r2]);
  await run(7);
  await q(`update public.airlines set administrations = administrations + 1 where id = $1`, [P]);
  ok('an airline in administration loses its tickets sold', (await one(`select count(*)::int from public.route_weeks where airline_id = $1 and flown_e is null`, [P])) === 0);

  // the admin tunes the strategies
  await q(`select public.admin_set_strategy('fill', '{"step": 0.05, "target_lf": 0.9}'::jsonb)`);
  ok('the admin can retune a strategy', Number(await one(`select step from public.rm_strategies where key = 'fill'`)) === 0.05);
  await fails('only known settings', `select public.admin_set_strategy('fill', '{"speed": 1}'::jsonb)`, /Unknown setting/);
  await q(`select public.admin_set_strategy('fill', '{"step": 0.04, "target_lf": 0.92}'::jsonb)`);

  // a player can set only their own routes
  const U2 = '00000000-0000-0000-0000-0000000000b9';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [U2]);
  await as(U2);
  await fails('a player cannot change another airline\'s strategy', `select public.set_strategy('${P}', '${r2}', 'top')`, /not your airline/);
  await as(null);
  await q(`delete from public.worlds where id = $1`, [W]);
}
