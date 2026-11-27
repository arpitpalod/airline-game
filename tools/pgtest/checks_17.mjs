// Worlds with their own rules, founded by players (migration 0027, part 1): founding, the rules' game values, the
// founder as the world's admin, starting once full or closing, When all are ready, and banks that cut credit lines.
export async function checks17(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Worlds founded by players (0027)');
  await q(`update public.game_params set num = 1 where key = 'start_first_week'`);
  const ADMIN = '00000000-0000-0000-0000-0000000017a1', U = '00000000-0000-0000-0000-0000000017b1', U2 = '00000000-0000-0000-0000-0000000017b2';
  for (const id of [ADMIN, U, U2]) await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [id]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 17', true) on conflict (user_id) do update set is_admin = true`, [ADMIN]);

  // ---------- the rules ----------
  ok('the choices a founder makes are game data', Number(await one(`select count(*) from public.world_options where available`)) >= 25
    && Number(await one(`select count(*) from public.world_options where setting = 'region' and not available`)) === 8);   // Southeast Asia waits too (0038)
  await as(ADMIN);
  const made = await one(`select public.create_world('Rules 17', $1)`, [JSON.stringify({ pace: '1h', turn: 'ready', places: '12', money: '250', banks: 'tight',
    growth: 'boom', shocks: 'rough', bots: 'none', min_players: 2 })]);
  await as(null);
  const W = made.world_id;
  const w = (await q(`select speed::float, max_airlines, demand_scale::float, turn_mode, min_players, bot_scale::float, rules,
      extract(epoch from join_deadline - now())::float / 86400 days from public.worlds where id = $1`, [W]))[0];
  const wp = Object.fromEntries((await q(`select key, num::float, public from public.world_params where world_id = $1`, [W])).map((r) => [r.key, r]));
  ok('a new world takes its pace, places, turns and rules', w.speed === 168 && w.max_airlines === 12 && w.demand_scale === 0.24 && w.turn_mode === 'ready'
    && w.min_players === 2 && w.bot_scale === 0 && Math.abs(w.days - 7) < 0.01 && w.rules.banks === 'tight' && made.invite.length === 8,
    `${w.speed} days a day, ${w.max_airlines} places, closes in ${w.days.toFixed(2)} days`);
  ok('each choice writes its game values for the world', wp.start_cash_inr.num === 2.5e9 && wp.credit_limit_inr.num === 1e9 && wp.interest_year.num === 0.15
    && wp.loan_rate_inr_year.num === 0.13 && wp.order_deposit_share.num === 0.25 && wp.credit_debt_limit.num === 4 && wp.growth_year.num === 0.12
    && wp.growth_year_intl.num === 0.18 && wp.start_cash_inr.public && !wp.ground_prob_day.public
    && Math.abs(wp.ground_prob_day.num - 2 * Number(await one(`select num from public.game_params where key = 'ground_prob_day'`))) < 1e-9);
  ok('the engine reads them per world', Number(await one(`select (game.params_for($1)->>'growth_year')::numeric`, [W])) === 0.12
    && Number(await one(`select (game.params_for(null)->>'growth_year')::numeric`)) !== 0.12);
  await fails('regions still to come cannot be chosen', `select public.create_world('Gulf 17', '{"region": "middle_east"}')`, /region options/);

  // a founded airline gets the world's money and credit line
  const A1 = await one(`select public.found_airline($1, 'Lean Air', 'LN', 'DEL')`, [made.invite]);
  const f1 = (await q(`select cash_inr::float, credit_limit_inr::float from public.airline_finance where airline_id = $1`, [A1]))[0];
  ok('starting money and credit line come from the world', f1.cash_inr === 2.5e9 && f1.credit_limit_inr === 1e9);

  // a world founded by a player is open while it waits; admin-made worlds need the invite
  await as(ADMIN);
  const open = await one(`select public.create_world('Open 17', '{"bots": "none"}')`);
  await as(U);
  ok('a founded world waiting for players shows its code to anyone signed in', (await one(`select public.world_join_code($1)`, [open.world_id])) === open.invite);
  await as(null);
  await q(`update public.worlds set founder_id = null where id = $1`, [open.world_id]);
  await as(U);
  await fails('a world without a founder (Test World, World 1) does not', `select public.world_join_code('${open.world_id}')`, /invite only/);
  await as(null);
  await q(`delete from public.worlds where id = $1`, [open.world_id]);

  // ---------- starting once full ----------
  await q(`select game.tick()`);
  ok('a founded world waits for its players', (await one(`select status from public.worlds where id = $1`, [W])) === 'setup');
  const A2 = await one(`select public.found_airline($1, 'Second Lean', 'SL', 'BOM')`, [made.invite]);
  await q(`update public.worlds set prelaunch_weeks = 0 where id = $1`, [W]);
  await q(`select game.tick()`);
  const st = (await q(`select status, game_day from public.worlds where id = $1`, [W]))[0];
  ok('it starts by itself once its minimum has joined, with the first week played', st.status === 'running' && st.game_day === 7, `${st.status} at day ${st.game_day}`);

  // ---------- When all are ready ----------
  await q(`select game.tick()`);
  ok('nobody ready: the week waits for the clock', Number(await one(`select game_day from public.worlds where id = $1`, [W])) === 7);
  const r1 = await one(`select public.set_ready($1)`, [A1]);
  await q(`select game.tick()`);
  ok('one of two ready: still waiting', r1.waiting_for === 1 && Number(await one(`select game_day from public.worlds where id = $1`, [W])) === 7);
  await q(`select public.set_ready($1)`, [A2]);
  await q(`select game.tick()`);
  const rd = (await q(`select game_day, game.due_day(id) due from public.worlds where id = $1`, [W]))[0];
  ok('all ready: the next week is played at once, and the clock counts on from now', rd.game_day === 14 && rd.due === 14, `day ${rd.game_day}, due ${rd.due}`);

  // ---------- closing ----------
  await as(ADMIN);
  const late = await one(`select public.create_world('Late 17', '{"bots": "none", "min_players": 3}')`);
  await as(null);
  await q(`update public.worlds set join_deadline = now() - interval '1 minute' where id = $1`, [late.world_id]);
  await q(`select game.tick()`);
  ok('a world that does not fill in time closes', (await one(`select status from public.worlds where id = $1`, [late.world_id])) === 'ended');

  // ---------- founding as a player ----------
  await as(U);
  await fails('founding needs a record', `select public.create_world('Mine 17', '{}')`, /game quarters/);
  const AU = await one(`select public.found_airline($1, 'Proven Air', 'PV', 'BLR')`, [made.invite]);
  await as(null);
  for (const [qn, op] of [[1, -5e7], [2, -1e7], [3, 2e7], [4, -3e7]]) {
    await q(`insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax) values ($1, $2, 1e9, $3, $3, 1000)`, [AU, qn, op]);
  }
  await as(U);
  const fs1 = await one(`select public.founder_status()`);
  ok('4 quarters, but the latest lost money: not yet', fs1.quarters === 4 && fs1.ok === false && fs1.last.length === 2);
  await as(null);
  await q(`update public.quarterly_reports set op_profit = 4e7 where airline_id = $1 and quarter = 4`, [AU]);
  await as(U);
  ok('4 quarters, the last 2 in profit: may found', (await one(`select public.founder_status()`)).ok === true);
  const mine = await one(`select public.create_world('Mine 17', '{"pace": "4h", "bots": "calm"}')`);
  await fails('one live world per founder', `select public.create_world('Mine Too 17', '{}')`, /one at a time/);
  ok('the founder may change pace and turns', Number(await one(`select public.admin_set_week_hours($1, 1)`, [mine.world_id])) === 168
    && (await one(`select public.set_turn_mode($1, 'ready')`, [mine.world_id])) === 'ready'
    && (await one(`select public.admin_world_invite($1)`, [mine.world_id])) === mine.invite);
  await fails('but not another world', `select public.admin_set_week_hours('${W}', 4)`, /founder or an admin/);
  await fails('nor start a world early', `select public.admin_start_world('${mine.world_id}')`, /Admins only/);
  await as(null);
  ok('calm rivals fight half as often', Number(await one(`select game.wparam($1, 'bot_aggression_mult')`, [mine.world_id])) === 0.5);
  await fails('once started, places only go up', `select public.admin_set_places('${W}', 10)`, /only go up/);

  // ---------- banks ----------
  for (const [qn, op] of [[1, 2e7], [2, 2e7], [3, 2e7], [4, 2e7]]) {
    await q(`insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax) values ($1, $2, 1e9, $3, $3, 1000)`, [A1, qn, op]);
  }
  await q(`update public.airline_finance set debt_inr = 5e8 where airline_id = $1`, [A1]);
  const day = Number(await one(`select game_day from public.worlds where id = $1`, [W]));
  await q(`select game.bank_week($1, $2)`, [W, day]);
  const b1 = (await q(`select credit_limit_inr::float, credit_cut_from::float from public.airline_finance where airline_id = $1`, [A1]))[0];
  ok('debt over 4 times a year\'s operating profit: the bank halves the credit line', b1.credit_limit_inr === 5e8 && b1.credit_cut_from === 1e9
    && /cut your credit line to Rs 50 cr/.test(await one(`select body from public.news where airline_id = $1 and kind = 'bank' order by id desc limit 1`, [A1])));
  await q(`select game.bank_week($1, $2)`, [W, day]);
  ok('it is cut once, not again each week', Number(await one(`select credit_limit_inr from public.airline_finance where airline_id = $1`, [A1])) === 5e8);
  await q(`update public.airline_finance set debt_inr = 2e8 where airline_id = $1`, [A1]);
  await q(`select game.bank_week($1, $2)`, [W, day]);
  ok('back within the limit: the full line returns', Number(await one(`select credit_limit_inr from public.airline_finance where airline_id = $1`, [A1])) === 1e9);
  await q(`update public.airline_finance set debt_inr = 5e8 where airline_id = $1`, [A2]);
  await q(`select game.bank_week($1, $2)`, [W, day]);
  ok('an airline without 4 quarters of results is not checked', Number(await one(`select credit_limit_inr from public.airline_finance where airline_id = $1`, [A2])) === 1e9);

  for (const id of [W, late.world_id, mine.world_id]) await q(`delete from public.worlds where id = $1`, [id]);
}
