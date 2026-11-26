// Worlds, parts 2 and 3 (migration 0028): airport closures, fare caps, airspace closures, late deliveries, and seats
// between countries.
export async function checks18(t) {
  const { q, one, ok, as, fails, w8Params } = t;
  await as(null);
  console.log('Shocks and seats between countries (0028)');
  for (const p of w8Params) await q(`update public.game_params set num = $1 where key = $2`, [p.num, p.key]);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'fuel_vol_day', 'fx_vol_day',
    'event_airport_prob_day', 'event_airspace_prob_day', 'late_delivery_prob')`);
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 18', 0.36, 18, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1800' from w returning world_id`);
  const A = await one(`select public.found_airline('test1800', 'Eighteen Air', 'ET', 'DEL')`);
  const B = await one(`select public.found_airline('test1800', 'Other Air', 'OT', 'BOM')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const day = async () => Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  if (await day() === 0) await run(7);
  const acA = await one(`select id from public.aircraft where airline_id = $1 and status = 'active' limit 1`, [A]);
  const acB = await one(`select id from public.aircraft where airline_id = $1 and status = 'active' limit 1`, [B]);
  const seatsA = Number(await one(`select seats_econ + seats_biz from public.aircraft where id = $1`, [acA]));

  // ---------- seats between countries ----------
  const lim = Number(await one(`select game.seat_limit($1, 'AE')`, [W]));
  ok('a world shares India\'s seats to the UAE, sized to its places', lim === Math.round(135000 * 0.36), `${lim} a week`);
  ok('countries with open skies have no limit', (await one(`select game.seat_limit($1, 'GB')`, [W])) === null);
  const used0 = Number(await one(`select game.seats_used($1, 'AE')`, [W]));   // the computer-run airlines' Gulf flights
  await q(`insert into public.world_params (world_id, key, num, public) values ($1, 'seat_limit_mult', $2, true)`, [W, (used0 + 1.5 * seatsA) / (135000 * 0.36)]);
  const RA = await one(`select public.open_route($1, 'DEL', 'DXB')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 1)`, [A, acA, RA]);
  await fails('more round trips than the free seats are refused', `select public.set_rotation('${A}', '${acA}', '${RA}', 2)`, /Seats between India and the UAE are full in this world: [0-9,]+ of [0-9,]+ a week/);
  const room = (await one(`select public.seat_room($1, $2)`, [W, A])).find((x) => x.country === 'AE');
  ok('the app sees the seats, those taken and its own', room && room.used === used0 + seatsA && room.mine === seatsA && Math.abs(room.limit - (used0 + 1.5 * seatsA)) <= 1, JSON.stringify(room));
  const RB = await one(`select public.open_route($1, 'BOM', 'DXB')`, [B]);
  await fails('another airline is refused once they are taken', `select public.set_rotation('${B}', '${acB}', '${RB}', 1)`, /full in this world/);
  await q(`update public.airlines set is_ai = true where id = $1`, [B]);
  await q(`select public.set_rotation($1, $2, $3, 1)`, [B, acB, RB]);
  ok('a computer-run airline is counted but not refused', Number(await one(`select game.seats_used($1, 'AE')`, [W])) > room.limit);
  await q(`update public.airlines set is_ai = false where id = $1`, [B]);
  await q(`select public.set_rotation($1, $2, $3, 0)`, [B, acB, RB]);
  await q(`update public.world_params set num = 0 where world_id = $1 and key = 'seat_limit_mult'`, [W]);
  await q(`select public.set_rotation($1, $2, $3, 3)`, [A, acA, RA]);
  ok('No limits: any number of seats', Number(await one(`select weekly_trips from public.rotations where route_id = $1`, [RA])) === 3
    && (await one(`select public.seat_room($1)`, [W])).length === 0);
  await q(`update public.world_params set num = 1 where world_id = $1 and key = 'seat_limit_mult'`, [W]);
  await q(`select public.set_rotation($1, $2, $3, 2)`, [A, acA, RA]);
  const RD = await one(`select public.open_route($1, 'DEL', 'BOM')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [A, acA, RD]);
  await run(14);   // two weeks on sale and flying

  // ---------- airport closures ----------
  const d1 = (await day()) + 1;
  const flown = async () => (await q(`select flights::float, cancelled::float, refunds_inr::float from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d1]))[0];
  await q('begin');
  await q(`insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload) values ($1, 'airport_closed', $2, $2, $2, '{"airport": "DEL"}')`, [W, d1]);
  await run(1);
  const shut = await flown();
  await q('rollback');
  await run(1);
  const open = await flown();
  ok('a closed airport cancels every flight to and from it', shut.flights === 0 && shut.cancelled === open.flights && open.flights > 0, `${open.flights} flights a day cancelled`);
  ok('... and refunds their travellers, routes with every flight cancelled included', shut.refunds_inr > 0 && open.refunds_inr === 0, `Rs ${Math.round(shut.refunds_inr)}`);

  // ---------- fare caps ----------
  if ((await day()) % 7 !== 0) await run(7 - (await day()) % 7);
  const prices = async () => Object.fromEntries((await q(`select w.route_id, max(w.price_e)::float p from public.route_weeks w where w.route_id in ($1, $2) and w.flown_e is null group by 1`, [RA, RD])).map((r) => [r.route_id, r.p]));
  const refD = Number(await one(`select m.ref_fare from public.markets m where m.a = 'BOM' and m.b = 'DEL'`));
  await q('begin');
  await q(`insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload) values ($1, 'fare_cap', $2, $2, $2 + 27, '{"airport": "DEL", "mult": 0.9}')`, [W, (await day()) + 1]);
  await q(`select game.sell_week($1, $2)`, [W, (await day()) + 1]);
  const capped = await prices();
  await q('rollback');
  await q('begin');
  await q(`select game.sell_week($1, $2)`, [W, (await day()) + 1]);
  const free = await prices();
  await q('rollback');
  ok('a fare cap holds domestic economy fares to and from the airport at the cap', capped[RD] <= 0.9 * refD && free[RD] > capped[RD],
    `Rs ${capped[RD]} against Rs ${free[RD]} uncapped, cap Rs ${Math.floor(0.9 * refD)}`);
  ok('... and leaves routes abroad alone', capped[RA] === free[RA]);

  // ---------- airspace closures ----------
  const d2 = (await day()) + 1;
  const ops = async () => (await q(`select fuel_kg::float kg, flights::float, cancelled::float from public.airline_daily where airline_id = $1 and game_day = $2`, [A, d2]))[0];
  await q('begin'); await run(1); const plain = await ops(); await q('rollback');
  await q('begin');
  await q(`insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload) values ($1, 'airspace_closed', $2, $2, $2 + 30, '{"lat_min": 23}')`, [W, d2]);
  await run(1); const round_ = await ops();
  await q('rollback');
  await q('begin');
  await q(`insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload) values ($1, 'airspace_closed', $2, $2, $2 + 30, '{"lat_min": 23}')`, [W, d2]);
  await q(`update public.airspace_detours set detour_km = 9000 where region = 'GULF'`);
  await run(1); const far = await ops();
  await q('rollback');
  ok('north India to the Gulf flies round a closed airspace: more fuel', round_.kg > plain.kg && round_.flights === plain.flights,
    `${Math.round(plain.kg)} kg a day, ${Math.round(round_.kg)} kg the long way`);
  ok('an aircraft that can no longer reach is cancelled', far.cancelled > 0 && far.flights < plain.flights);

  // ---------- late deliveries ----------
  await q(`update public.airline_finance set cash_inr = 1e11 where airline_id = $1`, [A]);
  const ord = await one(`select public.order_aircraft($1, 'A20N', 'DEL', 0, null, 30, 'cash')`, [A]);
  const ordId = typeof ord === 'object' ? (ord.aircraft_id ?? ord.id ?? ord[0]) : ord;
  const newAc = await one(`select x.id from public.aircraft x join public.aircraft_terms y on y.aircraft_id = x.id
    where x.airline_id = $1 and y.ordered_day is not null order by x.available_day limit 1`, [A]);
  const due = (await day()) + 70 - ((await day()) + 70) % 7 + 1;
  await q(`update public.aircraft set available_day = $2 where id = $1`, [newAc, due]);
  await q(`insert into public.world_params (world_id, key, num) values ($1, 'late_delivery_prob', 1), ($1, 'late_delivery_max_weeks', 1)`, [W]);
  await run(1);
  const late = (await q(`select x.available_day, y.delay_weeks from public.aircraft x join public.aircraft_terms y on y.aircraft_id = x.id where x.id = $1`, [newAc]))[0];
  ok('13 weeks before delivery the maker may put a new aircraft back, and says so', late.available_day === due + 7 && late.delay_weeks === 1
    && /now arrives in week/.test(await one(`select body from public.news where airline_id = $1 and kind = 'fleet' order by id desc limit 1`, [A])), String(ordId).slice(0, 8));
  await run(1);
  ok('... once only', Number(await one(`select available_day from public.aircraft where id = $1`, [newAc])) === due + 7);

  // ---------- the shocks come by themselves ----------
  await q('begin');
  await q(`insert into public.world_params (world_id, key, num) values ($1, 'event_airport_prob_day', 1), ($1, 'event_airspace_prob_day', 1), ($1, 'fare_cap_min_pax', 0)`, [W]);
  await run(1);
  const ev = (await q(`select kind from public.events where world_id = $1 and starts_day = (select game_day from public.worlds where id = $1)`, [W])).map((r) => r.kind).sort();
  const news = Number(await one(`select count(*) from public.news where world_id = $1 and kind = 'event' and game_day = (select game_day from public.worlds where id = $1)`, [W]));
  await q('rollback');
  ok('airport and airspace closures and fare caps start by themselves, with news', ev.join(',') === 'airport_closed,airspace_closed,fare_cap' && news === 3, ev.join(', '));

  // ---------- the founder's choices and the admin ----------
  const ADMIN = '00000000-0000-0000-0000-0000000018a1';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [ADMIN]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 18', true) on conflict (user_id) do update set is_admin = true`, [ADMIN]);
  await as(ADMIN);
  const made = await one(`select public.create_world('Shocks 18', '{"seats": "tight", "shocks": "calm", "bots": "none"}')`);
  const r = await one(`select public.admin_set_disruptions($1, '{"event_airport_prob_day": 0.01, "late_delivery_prob": 0.5, "fare_cap_on": 0}')`, [W]);
  await fails('the admin\'s limits hold for the new values', `select public.admin_set_disruptions('${W}', '{"late_delivery_prob": 2}')`, /late_delivery_prob must be a number from 0/);
  await as(null);
  const wp = Object.fromEntries((await q(`select key, num::float, public from public.world_params where world_id = $1`, [made.world_id])).map((x) => [x.key, x]));
  ok('a founder\'s choices set seats and the newer shocks', wp.seat_limit_mult?.num === 0.7 && wp.seat_limit_mult.public
    && wp.event_airspace_prob_day?.num === 0 && !wp.event_airspace_prob_day.public && wp.late_delivery_prob?.num === 0 && wp.fare_cap_on?.num === 0);
  ok('the admin sets the newer shocks per world', Number(r.event_airport_prob_day) === 0.01 && Number(r.late_delivery_prob) === 0.5 && Number(r.fare_cap_on) === 0);
  for (const id of [W, made.world_id]) await q(`delete from public.worlds where id = $1`, [id]);
}
