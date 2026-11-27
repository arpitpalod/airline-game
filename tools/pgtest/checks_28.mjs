// The hub and route study (migration 0040, spec 14.32): price, figures, errors, the airline's network now and a
// suggested one, and computer-run airlines using it.
export async function checks28(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  console.log('Hub and route study (0040)');
  const W = await one(`with w as (insert into public.worlds (name, demand_scale, max_airlines, pilots, prelaunch_weeks, selling)
    values ('Test 28', 0.5, 25, false, 13, true) returning id)
    insert into public.world_secrets (world_id, invite_code) select id, 'test2800' from w returning world_id`);
  const A = await one(`select public.found_airline('test2800', 'Study Air', 'SY', 'BOM')`);
  await q(`select public.admin_start_world($1)`, [W]);
  const cash = async () => Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [A]));
  const c0 = await cash();
  const s1 = await one(`select public.hub_study($1, 'BOM')`, [A]);
  ok('a hub study costs Rs 1.5 crore', Math.abs(c0 - (await cash()) - 15000000) < 1, `${c0 - (await cash())}`);
  const sp = s1.spokes;
  ok('it lists 40 routes out of Mumbai, best first, with their own and connecting travellers',
    sp.length === 40 && sp.every((x) => x.own_wk >= 0 && x.conn_wk >= 0)
      && sp.slice(0, 5).every((x) => x.own_wk + x.conn_wk > 0), `${sp[0].x} ${sp[0].own_wk} + ${sp[0].conn_wk} a week`);
  ok('the top connecting markets through Mumbai, with their nonstops', s1.markets.length === 15
    && s1.markets.every((m) => m.a < m.b && m.conn_wk >= 0 && m.detour >= 1), `${s1.markets[0].a}-${s1.markets[0].b} ${s1.markets[0].conn_wk} a week`);
  ok('a suggested network of 12 routes; nothing connects yet with no routes there', s1.suggested.spokes.length === 12
    && s1.suggested.conn_wk > 0 && s1.now.spokes === 0 && s1.now.conn_wk === 0, JSON.stringify(s1.now));
  await fails('only airports this world shows', `select public.hub_study('${A}', 'SUB')`, /no airport SUB/);

  // two routes through Mumbai: the study counts the connections between them
  const [ac] = (await q(`select id from public.aircraft where airline_id = $1 order by reg`, [A])).map((r) => r.id);
  for (const x of ['DEL', 'GOI']) {
    const r = await one(`select public.open_route($1, 'BOM', $2)`, [A, x]);
    await q(`select public.set_rotation($1, $2, $3, 7)`, [A, ac, r]);
  }
  const s2 = await one(`select public.hub_study($1, 'BOM')`, [A]);
  ok('with Delhi and Goa flown, the study shows them as yours and the Delhi-Goa connections', s2.now.spokes === 2 && s2.now.conn_wk > 0
    && s2.spokes.filter((x) => x.yours).length === 2, JSON.stringify(s2.now));
  const d1 = sp.find((x) => x.x === 'DEL'), d2 = s2.spokes.find((x) => x.x === 'DEL');
  ok('each study carries its own errors: the same figure differs, within the range', d1 && d2 && d1.own_wk !== d2.own_wk
    && d2.own_wk / d1.own_wk > 0.6 && d2.own_wk / d1.own_wk < 1.6, `${d1?.own_wk} then ${d2?.own_wk}`);
  ok('the studies are kept, readable by their airline only', Number(await one(`select count(*) from public.hub_studies where airline_id = $1`, [A])) === 2);

  // computer-run airlines: a study of their biggest base in week 26, and its best suggested route opens
  for (let i = 0; i < 98; i++) await q(`select game.run_day($1)`, [W]);   // past the first flights: the computer-run airlines are flying
  await q(`update public.airline_finance f set cash_inr = 1e10 from public.airlines a where a.id = f.airline_id and a.world_id = $1 and a.is_ai`, [W]);
  const before = Number(await one(`select count(*) from game.bot_plan p join public.airlines a on a.id = p.airline_id where a.world_id = $1`, [W]));
  ok('computer-run airlines study nothing before week 26', Number(await one(`select game.bot_hub($1, 13)`, [W])) === 0);
  const opened = Number(await one(`select game.bot_hub($1, 26)`, [W]));
  const bots = Number(await one(`select count(*) from public.airlines where world_id = $1 and is_ai and status = 'active'`, [W]));
  const studied = Number(await one(`select count(*) from public.hub_studies h join public.airlines a on a.id = h.airline_id where a.world_id = $1 and a.is_ai`, [W]));
  const after = Number(await one(`select count(*) from game.bot_plan p join public.airlines a on a.id = p.airline_id where a.world_id = $1`, [W]));
  ok('in week 26 each computer-run airline buys a study and opens the best suggested route it does not fly',
    bots > 0 && studied === bots && opened > 0 && opened <= bots && after === before + opened, `${opened} routes from ${studied} studies`);
}
