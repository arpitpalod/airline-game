// Route studies (migration 0012). Uses the quiet world of checks_3.
export async function checks4(t) {
  const { q, one, ok, fails, as } = t;
  await as(null);
  const W = await one(`select id from public.worlds where name = 'Test 3'`);
  const [X, Y] = (await q(`select id from public.airlines where world_id = $1 and not is_ai order by name`, [W])).map((r) => r.id);
  console.log('Route studies (0012)');
  const r = await q(`select r.origin, r.dest, r.id from public.routes r where r.airline_id = $1 and r.status = 'open'`, [X]);
  const truth = (await q(`select sum(pax_econ + pax_biz)::float / count(distinct game_day) / 2 fly, sum(spill)::float / count(distinct game_day) / 2 turned
      from public.route_daily d join public.routes rt on rt.id = d.route_id
     where rt.world_id = $1 and least(rt.origin, rt.dest) = least($2, $3) and greatest(rt.origin, rt.dest) = greatest($2, $3)`, [W, r[0].origin, r[0].dest]))[0];
  const cash0 = Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [Y]));
  const sq = await one(`select public.route_study($1, $2, $3, 'full')`, [Y, r[0].origin, r[0].dest]);
  ok('a full study costs Rs 40 lakh', cash0 - Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [Y])) === 4000000);
  ok('and reports a range for travellers flying the route with all airlines', sq.flying_lo <= sq.flying_hi && sq.carriers === 2
    && sq.flying_hi / sq.flying_lo < 1.3, `${sq.flying_lo}-${sq.flying_hi} a day each way (actual ${Math.round(truth.fly)})`);
  ok('turned-away travellers and seats filled', sq.turned_lo != null && sq.lf_lo > 0 && sq.lf_hi <= 1, `${sq.turned_lo}-${sq.turned_hi} turned away, ${sq.lf_lo}-${sq.lf_hi} full`);
  ok('the traveller mix and next quarter\'s outlook', Math.abs(sq.biz_share + sq.lei_share + sq.bud_share - 1) < 0.011 && sq.next_qtr > 0.5 && sq.next_qtr < 1.6,
    `mix ${sq.biz_share}/${sq.lei_share}/${sq.bud_share}, next quarter x${sq.next_qtr}`);
  const qk = await one(`select public.route_study($1, 'DEL', 'IXC', 'quick')`, [Y]);
  ok('a quick study of a route nobody flies estimates who would fly with one airline', qk.carriers === 0 && qk.flying_lo == null && qk.untapped_lo > 0
    && qk.untapped_hi / qk.untapped_lo > 1.9 && qk.biz_share == null, `${qk.untapped_lo}-${qk.untapped_hi} a day each way`);
  ok('studies are private to the airline', (await one(`select count(*)::int from public.route_studies where airline_id = $1`, [Y])) === 2);
  await fails('a study needs a market', `select public.route_study('${Y}', 'DEL', 'DEL', 'quick')`, /no market/);
  await fails('and a known depth', `select public.route_study('${Y}', 'DEL', 'BOM', 'deep')`, /quick or full/);
}
