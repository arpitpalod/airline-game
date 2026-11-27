// Southeast Asia, the ninth home region (migration 0038, spec 14.30). India worlds must not change.
export async function checks26(t) {
  const { q, one, ok, as, fails } = t;
  console.log('Southeast Asia, the ninth home region (0038)');
  const ADMIN = '00000000-0000-0000-0000-0000000026a1', U = '00000000-0000-0000-0000-0000000026b1';
  await as(null);
  for (const id of [ADMIN, U]) await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [id]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 26', true) on conflict (user_id) do update set is_admin = true`, [ADMIN]);
  await q(`insert into public.profiles (user_id, display_name) values ($1, 'Player 26') on conflict do nothing`, [U]);

  const ap = (await q(`select count(*)::int n, count(*) filter (where pax_src = 'V')::int v, count(distinct country)::int c
    from public.airports where home = 'southeast_asia'`))[0];
  ok('70 home airports in ten countries, 45 with published figures', ap.n === 70 && ap.v === 45 && ap.c === 10, JSON.stringify(ap));
  const top = await q(`select a, b, m.intl from public.markets m where zone = 'southeast_asia' order by n_biz + n_lei + n_bud desc limit 1`);
  ok("Hanoi-Ho Chi Minh City is the region's busiest market", top[0].a === 'HAN' && top[0].b === 'SGN' && !top[0].intl, JSON.stringify(top[0]));
  const intl = await q(`select a, b from public.markets m where zone = 'southeast_asia' and intl order by n_biz + n_lei + n_bud desc limit 1`);
  ok('Kuala Lumpur-Singapore is its busiest between countries', intl[0].a === 'KUL' && intl[0].b === 'SIN', JSON.stringify(intl[0]));
  ok('Singapore has no domestic market, and Batam-Singapore (25 km of sea, ferries) none at all',
    Number(await one(`select count(*) from public.markets m join public.airports x on x.iata = m.a join public.airports y on y.iata = m.b
      where x.country = 'SG' and y.country = 'SG'`)) === 0
      && Number(await one(`select count(*) from public.markets where a = 'BTH' and b = 'SIN'`)) === 0);
  const seen = (c) => one(`select seen_in from public.airports where iata = '${c}'`);
  ok('Singapore and Bangkok are seen in India worlds and their own; Surabaya not in India worlds',
    (await seen('SIN')).includes('india') && (await seen('SIN')).includes('southeast_asia')
      && (await seen('BKK')).includes('india') && !(await seen('SUB')).includes('india') && (await seen('SUB')).includes('southeast_asia'));
  await fails('a home must be a region', `update public.airports set home = 'atlantis' where iata = 'SUB'`, /foreign key/);

  const R = (await q(`select * from public.regions where key = 'southeast_asia'`))[0];
  const lvl = (0.436 + 0.35 * 0.8 + 0.105 * 1.2 + 0.058 * 1.0 + 0.051) * Number(R.fare_premium);
  ok('the Singapore dollar at Rs 70, its price level from its costs', R.currency === 'SGD' && Number(R.unit_inr) === 70
    && Math.abs(Number(R.price_level) - lvl) < 0.0001 && Number(R.demand_mult) > 0, `${R.price_level} ${R.demand_mult}`);
  ok('the region waits for step 3 in Found a world',
    (await q(`select available from public.world_options where setting = 'region' and option = 'southeast_asia'`))[0].available === false);

  // a Southeast Asia world, founded by an admin (the region is opened here only for the check)
  await q(`update public.world_options set available = true where setting = 'region' and option = 'southeast_asia'`);
  await as(ADMIN);
  const made = await one(`select public.create_world('Straits 26', $1)`, [JSON.stringify({ region: 'southeast_asia', pace: '1h', turn: 'clock',
    places: '12', money: '500', banks: 'normal', growth: 'normal', seats: 'real', shocks: 'real', bots: 'normal', consultant: 'standard' })]);
  await as(null);
  await q(`update public.world_options set available = false where setting = 'region' and option = 'southeast_asia'`);
  const W = made.world_id;
  const v = Object.fromEntries((await q(`select key, num from public.world_params where world_id = $1`, [W])).map((r) => [r.key, Number(r.num)]));
  const r4 = (x, d) => Math.round(x * 10 ** d) / 10 ** d, P = Number(R.price_level);
  ok('the world takes the region values: growth x0.85, swings x0.7 with fewer shocks, a currency that rises, its rights and tax',
    v.pay_mult === r4(1.2 / P, 4) && v.fx_drift_year === -0.01 && v.cancel_notice_days === 3 && v.tax_rate === 0.21
      && Math.abs(v.fx_vol_day - 0.7 * Number(await one(`select game.param('fx_vol_day')`))) < 1e-9 && v.start_cash_inr === 5000000000, JSON.stringify({ pay: v.pay_mult, drift: v.fx_drift_year, vol: v.fx_vol_day }));
  const k = Math.round(1000 * 70 / P);
  ok('a Southeast Asia world shows Singapore dollars', (await one(`select game.money_text($1, $2)`, [W, k])) === 'S$1,000',
    await one(`select game.money_text($1, $2)`, [W, k]));
  ok('its aircraft are registered 9V-…', /^9V-[A-Z]{3,}$/.test(await one(`select game.next_reg($1)`, [W])), await one(`select game.next_reg($1)`, [W]));

  const code = await one(`select invite_code from public.world_secrets where world_id = $1`, [W]);
  await as(U);
  await fails('it refuses a base in India', `select public.found_airline('${code}', 'Lion Cub', 'LC', 'BOM')`, /airports in Southeast Asia/);
  const A = await one(`select public.found_airline('${code}', 'Lion Cub', 'LC', 'CGK')`);
  ok('it founds an airline at Jakarta', !!A);
  await as(null);
  const ind = Number(await one(`select count(*) from public.airports where is_india and 'southeast_asia' = any(seen_in)`));
  ok('the world shows only the Indian airports with markets to the region', ind > 0 && ind < 93, ind);
}
