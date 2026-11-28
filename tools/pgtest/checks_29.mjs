// Gems (migration 0041, spec 14.33): hidden demand at random places and dates per world, its shapes, selling, clues,
// studies, the consultant's rumours and computer-run airlines.
export async function checks29(t) {
  const { q, one, ok, as } = t;
  await as(null);
  console.log('Gems (0041)');
  await q(`update public.game_params set num = 1 where key = 'gems_on'`);
  await q(`update public.game_params set num = 0 where key in ('demand_noise_sd', 'event_airport_prob_day', 'event_airspace_prob_day')`);
  ok('ten kinds of gem, public', Number(await one(`select count(*) from public.gem_kinds`)) === 10);

  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 29', 0.5, 25, false, 13, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2900' from w returning world_id`);
  const A = await one(`select public.found_airline('test2900', 'Gem Air', 'GM', 'DEL')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const drawn = await q(`select kind, count(*)::int n from game.world_gems where world_id = $1 group by kind`, [W]);
  const n = Object.fromEntries(drawn.map((r) => [r.kind, r.n]));
  ok('a world draws its lasting gems and yearly seasons at its first week of selling',
    n.diaspora_pair === 5 && n.medical === 2 && n.pilgrim_season === 3 && n.student_season === 2 && n.wedding_season === 2, JSON.stringify(n));
  ok('the app cannot read them', Number(await one(`select count(*) from information_schema.table_privileges
    where table_schema = 'game' and table_name = 'world_gems' and grantee in ('anon', 'authenticated')`)) === 0);

  // shapes: a flat gathering, a season rising and falling, a boom city that stays, a season back a year later
  const gem = async (kind, a, start, weeks, mult, extra = {}) => one(`insert into game.world_gems (world_id, kind, a, b, country, start_week, weeks, mult, drift, clue_week)
    values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning id`, [W, kind, a, extra.b ?? null, extra.country ?? null, start, weeks, mult, extra.drift ?? 0, extra.clue ?? null]);
  const rows = async (id, w0, w1) => (await q(`select week, round(m::numeric, 3)::float m from game.gem_rows($1, $2, $3) where id = $4 order by week`, [W, w0, w1, id]));
  const pg = await gem('pilgrim_season', 'IXZ', 300, 5, 2, { drift: -2 });
  const r1 = await rows(pg, 290, 360);
  ok('a pilgrim season rises to its peak and falls, and comes back two weeks earlier the next year',
    r1.length === 10 && r1[2].m === 2 && r1[0].m < 1.4 && r1[4].m < 1.4 && r1[5].week === 350, JSON.stringify(r1.slice(0, 6)));
  const bc = await gem('boom_city', 'IXZ', 300, 10, 1.5);
  const r2 = await rows(bc, 300, 320);
  ok('a boom city builds up over its years and stays', r2.length === 21 && r2[0].m === 1.05 && r2[9].m === 1.5 && r2[20].m === 1.5);
  await q(`delete from game.world_gems where id in ($1, $2)`, [pg, bc]);

  // selling: a gathering at Goa in flight week 20 multiplies the week's leisure and budget travellers there
  const ac = await one(`select id from public.aircraft where airline_id = $1 order by reg limit 1`, [A]);
  const rt = await one(`select public.open_route($1, 'DEL', 'GOI')`, [A]);
  await q(`select public.set_rotation($1, $2, $3, 7)`, [A, ac, rt]);
  await q(`delete from game.world_gems where world_id = $1 and (a in ('GOI', 'DEL') or b in ('GOI', 'DEL') or country is not null)`, [W]);
  await q(`select game.run_day($1)`, [W]);
  for (let i = 0; i < 6; i++) await q(`select game.run_day($1)`, [W]);
  const trial = async (withGem) => {
    await q('begin');
    if (withGem) await gem('mega_event', 'GOI', 20, 1, 4);
    const b = Number(await one(`select bk_l + bk_u from public.route_weeks where route_id = $1 and week = 20`, [rt]));
    for (let i = 0; i < 7; i++) await q(`select game.run_day($1)`, [W]);
    const got = Number(await one(`select bk_l + bk_u from public.route_weeks where route_id = $1 and week = 20`, [rt])) - b;
    await q('rollback');
    return got;
  };
  const withG = await trial(true), without = await trial(false);
  ok('a gathering four times normal at Goa sells about four times the leisure and budget seats that week', withG > 3 * without && withG < 4.5 * without,
    `${withG.toFixed(1)} against ${without.toFixed(1)}`);

  // a clue reaches the news, vaguely
  const wk = Number(await one(`select game.week_of(game_day + 1) from public.worlds where id = $1`, [W]));
  const cl = await gem('mega_event', 'IXZ', wk + 6, 2, 5, { clue: wk });
  await q(`select game.gems_week($1, $2)`, [W, wk]);
  const news = await one(`select body from public.news where world_id = $1 and kind = 'gem' and body like '%gathering%' order by id desc limit 1`, [W]);
  ok('its clue reaches the news, naming only part of the country', /huge gathering is expected in the (south|east|north|west|centre) of India/.test(news ?? ''), news);
  ok('and everyone knows of it', (await one(`select clued from game.world_gems where id = $1`, [cl])) === true);

  // studies: a quick one notices, a full one sizes it, and the airline knows of it
  const g2 = await gem('mega_event', 'GOI', wk + 10, 2, 3);
  const quick = await one(`select public.route_study($1, 'DEL', 'GOI', 'quick')`, [A]);
  const full = await one(`select public.route_study($1, 'DEL', 'GOI', 'full')`, [A]);
  ok('a quick study notices something unusual; a full one says about how much and when',
    /Something unusual/.test(quick.gem_note ?? '') && new RegExp(`about \\+\\d+% at its peak, between weeks ${wk + 10} and ${wk + 11}`).test(full.gem_note ?? ''), full.gem_note);
  ok('the airline now knows of it', (await one(`select $1 = any (known_by) from game.world_gems where id = $2`, [A, g2])) === true);
  const hub = await one(`select public.hub_study($1, 'DEL')`, [A]);
  ok('a hub study lists the gems on its routes', hub.gems.some((x) => x.at === 'GOI' && x.from_week === wk + 10), JSON.stringify(hub.gems));

  // the consultant hears rumours (here all of them)
  await q(`update public.game_params set num = 1 where key = 'gem_hint_share'`);
  await q(`insert into public.consultant_reports (id, airline_id, world_id, game_day, fee_inr) values ('00000000-0000-0000-0000-0000000029c1', $1, $2, 1, 0)`, [A, W]);
  const ov = await one(`select public.consultant_data('00000000-0000-0000-0000-0000000029c1', 'overview')`);
  ok('the consultant\'s overview carries rumours of what is coming', ov.market_hints.some((h) => h.kind === 'A mega gathering'), JSON.stringify(ov.market_hints).slice(0, 200));
  ok('and its playbook says they are possibilities, not facts', /market_hints/.test(await one(`select body from public.consultant_playbook where active order by version desc limit 1`)));
  await q(`update public.game_params set num = 0.5 where key = 'gem_hint_share'`);

  // computer-run airlines sell Top fares into a gem they know of, and go back afterwards
  for (let i = 0; i < 91; i++) await q(`select game.run_day($1)`, [W]);
  const br = (await q(`select r.id, r.dest, pl.strategy from public.routes r join public.airlines al on al.id = r.airline_id
    join public.route_plans pl on pl.route_id = r.id where r.world_id = $1 and al.is_ai and r.status = 'open' and pl.strategy <> 'top'
    order by r.id limit 1`, [W]))[0];
  const w2 = Number(await one(`select game.week_of(game_day + 1) from public.worlds where id = $1`, [W]));
  const g3 = await gem('mega_event', br.dest, w2 + 1, 2, 3);
  await q(`update game.world_gems set clued = true where id = $1`, [g3]);
  await q(`select game.bot_network($1, $2)`, [W, w2]);
  const on = (await q(`select strategy, gem_prev, gem_until from public.route_plans where route_id = $1`, [br.id]))[0];
  await q(`select game.bot_network($1, $2)`, [W, w2 + 5]);
  const off = await one(`select strategy from public.route_plans where route_id = $1`, [br.id]);
  ok('a computer-run airline sells Top fares into a gem it knows of, then goes back to its own way',
    on.strategy === 'top' && on.gem_prev === br.strategy && on.gem_until === w2 + 2 && off === br.strategy, `${JSON.stringify(on)} then ${off}`);
}
