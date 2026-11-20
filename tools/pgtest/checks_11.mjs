// Computer-run airlines that sell like rivals (migration 0021): strategies drawn from each airline's mix, fights when a
// player enters their market, reviews that follow What works where or try another way at random.
export async function checks11(t) {
  const { q, one, ok, as } = t;
  await as(null);
  console.log('Computer-run airlines sell like rivals (0021)');
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_fuel_prob_day', 'event_fx_prob_day',
    'event_engine_prob_day', 'ground_prob_day', 'event_duty_prob_day', 'bot_explore_prob')`);
  await q(`update public.bot_airlines set aggression = 1`);
  // the mixes of 0021 (run.mjs gives the older checks one way each)
  await t.db.exec(`do $$ begin if to_regclass('public.bot_strategy_mix_0021') is not null then
    delete from public.bot_strategy_mix; insert into public.bot_strategy_mix select * from public.bot_strategy_mix_0021; end if; end $$;`);
  await t.db.exec(`alter table public.airlines enable trigger airlines_first_flight; alter table public.aircraft enable trigger aircraft_week_start`);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 11', 0.5, 25, false, 0, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test1100' from w returning world_id`);
  const P = await one(`select public.found_airline('test1100', 'Fight Air', 'FA', 'DEL')`);
  await q(`select setseed(0.5)`);   // the draws below are random: a fixed seed keeps the check from failing by chance
  await q(`select public.admin_start_world($1)`, [W]);
  const run = async (n) => { for (let i = 0; i < n; i++) await q(`select game.run_day($1)`, [W]); };
  await run(7);
  const mix = await q(`select a.code, count(*)::int n, count(distinct p.strategy)::int k,
      bool_and(exists (select 1 from public.bot_strategy_mix x where x.code = a.code and x.strategy = p.strategy)) inmix
    from public.route_plans p join public.airlines a on a.id = p.airline_id where a.world_id = $1 and a.is_ai group by a.code`, [W]);
  ok('each computer-run airline\'s routes start from its own mix of strategies, drawn at random',
    mix.length === 6 && mix.every((x) => x.inmix) && mix.filter((x) => x.n >= 5).every((x) => x.k >= 2), mix.map((x) => `${x.code} ${x.k}/${x.n}`).join(', '));

  // a player enters Delhi-Mumbai: every computer-run airline there fights with low fares for 8 weeks, then goes back
  const before = await q(`select p.route_id, p.strategy from public.route_plans p join public.routes r on r.id = p.route_id
    join public.airlines a on a.id = r.airline_id where r.world_id = $1 and a.is_ai and least(r.origin, r.dest) = 'BOM' and greatest(r.origin, r.dest) = 'DEL'`, [W]);
  const rt = await one(`select public.open_route($1, 'DEL', 'BOM', 5000)`, [P]);
  await q(`select public.set_rotation($1, (select id from public.aircraft where airline_id = $1 order by reg limit 1), $2, 14)`, [P, rt]);
  await run(21);   // week 4: on sale; week 5's selling sees the entry of week 4
  const fight = await q(`select p.route_id, p.strategy, p.prev_strategy, p.fight_until from public.route_plans p where p.route_id = any($1)`, [before.map((x) => x.route_id)]);
  ok('a player starts flying their market: the computer-run airlines there fight with Fill every seat',
    before.length >= 2 && fight.every((x) => x.strategy === 'fill' && x.fight_until > 0 && x.prev_strategy === before.find((b) => b.route_id === x.route_id).strategy),
    `${fight.length} routes`);
  const until = fight[0].fight_until;
  await run(7 * (until - 4));
  const after = await q(`select route_id, strategy, fight_until from public.route_plans where route_id = any($1)`, [before.map((x) => x.route_id)]);
  ok('after eight weeks each goes back to how it sold before', after.every((x) => x.fight_until == null && x.strategy === before.find((b) => b.route_id === x.route_id).strategy));

  // reviews: where What works where shows a clearly better way, a route under review moves to it
  await q(`update public.bot_airlines set aggression = 0`);
  await q(`delete from public.sector_insights where world_id = $1`, [W]);
  await q(`insert into public.sector_insights (world_id, week, band, shape, strategy, routes, weeks, load, fare_index, rev_index)
    select $1, 0, b, s, 'top', 9, 90, 0.8, 1.5, 10 from unnest(array['short','medium','long','intl']) b, unnest(array['alone','two','few','many']) s`, [W]);
  const wk = Math.floor((await one(`select game_day from public.worlds where id = $1`, [W])) / 7) + 1;
  const due = await q(`select p.route_id from public.route_plans p join public.routes r on r.id = p.route_id join public.airlines a on a.id = r.airline_id
    where r.world_id = $1 and a.is_ai and r.status = 'open' and p.fight_until is null and ($2 + abs(hashtext(p.route_id::text))) % 4 = 0
      and exists (select 1 from public.route_weeks x where x.route_id = p.route_id and x.flown_e is not null)`, [W, wk]);
  await run(7);
  const moved = await one(`select count(*)::int from public.route_plans where route_id = any($1) and strategy = 'top'`, [due.map((x) => x.route_id)]);
  ok('every few weeks a route reviews: it moves to the way that earned clearly more on routes like it', due.length > 3 && moved === due.length, `${moved} of ${due.length} routes reviewed this week`);

  // and now and then it tries another way at random
  await q(`update public.game_params set num = 1 where key = 'bot_explore_prob'`);
  await q(`update public.game_params set num = 100 where key = 'bot_switch_gain'`);
  const snap = await q(`select p.route_id, p.strategy from public.route_plans p join public.routes r on r.id = p.route_id join public.airlines a on a.id = r.airline_id
    where r.world_id = $1 and a.is_ai and r.status = 'open'`, [W]);
  await run(28);
  const changed = await one(`select count(*)::int from public.route_plans p join unnest($1::uuid[], $2::text[]) s(id, st) on s.id = p.route_id where p.strategy <> s.st`,
    [snap.map((x) => x.route_id), snap.map((x) => x.strategy)]);
  ok('exploring, every route tries another way within a review cycle', changed >= snap.length * 0.9, `${changed} of ${snap.length}`);
  // the admin tunes them
  await q(`select public.admin_set_bot('KOL', 0.95, '{"fill": 0.7, "follow": 0.3}'::jsonb)`);
  ok('the admin can set an airline\'s aggression and mix', Number(await one(`select aggression from public.bot_airlines where code = 'KOL'`)) === 0.95
    && (await one(`select string_agg(strategy || ':' || weight, ',' order by strategy) from public.bot_strategy_mix where code = 'KOL'`)) === 'fill:0.7,follow:0.3');
  await t.fails('an unknown strategy is refused', `select public.admin_set_bot('KOL', null, '{"cheap": 1}'::jsonb)`, /Unknown strategy/);
  await q(`select public.admin_set_bot('KOL', 0.9, '{"fill": 0.6, "follow": 0.2, "balanced": 0.2}'::jsonb)`);
  await q(`select public.admin_set_param('bot_fight_weeks', 6)`);
  ok('and any game value by name', Number(await one(`select num from public.game_params where key = 'bot_fight_weeks'`)) === 6);
  await t.fails('an unknown game value is refused', `select public.admin_set_param('no_such_value', 1)`, /No such game value/);
  await q(`select public.admin_set_param('bot_fight_weeks', 8)`);
  await q(`update public.game_params set num = case key when 'bot_explore_prob' then 0.15 else 0.08 end where key in ('bot_explore_prob', 'bot_switch_gain')`);
  await q(`update public.bot_airlines set aggression = case code when 'KOL' then 0.9 when 'BLB' then 0.7 when 'SRW' then 0.4 when 'MYN' then 0.3 else 0.5 end`);
  await q(`delete from public.worlds where id = $1`, [W]);
}
