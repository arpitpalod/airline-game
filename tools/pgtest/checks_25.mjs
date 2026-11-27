// Each region's own money and economy (migration 0037, spec 14.29). India worlds must not change.
export async function checks25(t) {
  const { q, one, ok, as, fails } = t;
  console.log("Each region's own money and economy (0037)");
  const ADMIN = '00000000-0000-0000-0000-0000000025a1', U = '00000000-0000-0000-0000-0000000025b1';
  await as(null);
  for (const id of [ADMIN, U]) await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [id]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 25', true) on conflict (user_id) do update set is_admin = true`, [ADMIN]);
  await q(`insert into public.profiles (user_id, display_name) values ($1, 'Player 25') on conflict do nothing`, [U]);

  const rg = await q(`select key, currency, price_level from public.regions order by key`);
  const pl = Object.fromEntries(rg.map((r) => [r.key, Number(r.price_level)]));
  const mix = (r) => 0.436 + 0.35 * r.fuel_level + 0.105 * r.pay_level + 0.058 * r.charge_level + 0.051;
  const full = Object.fromEntries((await q(`select * from public.regions`)).map((r) => [r.key, Object.fromEntries(Object.entries(r).map(([k, v]) => [k, isNaN(v) ? v : Number(v)]))]));
  ok("nine regions (Southeast Asia from 0038), each with its currency; fares follow costs by India's measured mix, times Africa's, South America's and Europe's premium",
    rg.length === 9 && pl.india === 1 && Object.values(full).every((r) => Math.abs(r.price_level - mix(r) * r.fare_premium) < 0.0001),
    rg.map((r) => `${r.key} ${r.currency} ${r.price_level}`).join(', '));
  const dm = Object.fromEntries((await q(`select key, demand_mult from public.regions`)).map((r) => [r.key, Number(r.demand_mult)]));
  ok("demand factors match each region's 150 busiest markets to India's (India 1, Europe 1.03, Canada 2.73 after 0038)",
    dm.india === 1 && Math.abs(dm.europe - 1.03) < 0.01 && Math.abs(dm.canada - 2.73) < 0.01, JSON.stringify(dm));
  ok("Heathrow, JFK, Amsterdam, Hong Kong, Singapore and Dubai have full slot caps beside India's share",
    Number(await one(`select count(*) from public.airports where slot_cap_full is not null and slot_cap_full > slot_cap`)) === 6);
  const w1 = await one(`select id from public.worlds where name = 'World 1'`);
  ok('an India world shows rupees as before', (await one(`select game.money_text('${w1}', 239000000)`)) === '₹23.9 cr');
  ok('an India world has no region values of its own',
    Number(await one(`select count(*) from public.world_params where world_id = '${w1}' and key in ('pay_mult', 'charge_mult', 'fuel_ref_inr_kg')`)) === 0);

  // a US world, founded by an admin (the region is opened here only for the check)
  await q(`update public.world_options set available = true where setting = 'region' and option = 'usa'`);
  await as(ADMIN);
  const made = await one(`select public.create_world('States 25', $1)`, [JSON.stringify({ region: 'usa', pace: '1h', turn: 'clock', places: '12',
    money: '500', banks: 'normal', growth: 'normal', seats: 'real', shocks: 'real', bots: 'normal', consultant: 'standard' })]);
  await as(null);
  await q(`update public.world_options set available = false where setting = 'region' and option = 'usa'`);
  const W = made.world_id;
  const v = Object.fromEntries((await q(`select key, num from public.world_params where world_id = $1`, [W])).map((r) => [r.key, Number(r.num)]));
  const US = full.usa, r4 = (x, d) => Math.round(x * 10 ** d) / 10 ** d;
  ok('the US world takes its region values: pay and charges over its price level, fuel and the dollar at its prices',
    v.pay_mult === r4(4 / US.price_level, 4) && v.charge_mult === r4(1.2 / US.price_level, 4)
      && v.fuel_ref_inr_kg === r4(100 * 0.75 / US.price_level, 2) && v.fx_ref_inr_usd === r4(90 / US.price_level, 3),
    JSON.stringify({ pay: v.pay_mult, charge: v.charge_mult, fuel: v.fuel_ref_inr_kg, fx: v.fx_ref_inr_usd }));
  ok("the founder's choices in the region's terms: growth 7% x 0.4, loans 10.5% - 5 points, no currency swings",
    v.growth_year === 0.028 && v.loan_rate_inr_year === 0.055 && v.fx_vol_day === 0 && v.event_fx_prob_day === 0,
    JSON.stringify({ g: v.growth_year, loan: v.loan_rate_inr_year, vol: v.fx_vol_day, ev: v.event_fx_prob_day }));
  ok('starting money buys the same size of airline (the same internal amount)', v.start_cash_inr === 5000000000, v.start_cash_inr);
  const wr = (await q(`select fuel_inr_kg, fx_inr_usd, fx_walk from public.worlds where id = $1`, [W]))[0];
  ok("the world's fuel and dollar start at the region's prices", Number(wr.fuel_inr_kg) === v.fuel_ref_inr_kg && Number(wr.fx_inr_usd) === v.fx_ref_inr_usd, JSON.stringify(wr));
  const k = Math.round(1000 * 90 / US.price_level);
  ok('a US world shows dollars', (await one(`select game.money_text($1, $2)`, [W, k])) === '$1,000'
    && (await one(`select game.money_text($1, $2)`, [W, -k * 1000])) === '−$1M', await one(`select game.money_text($1, $2)`, [W, -k * 1000]));
  ok('new aircraft in the US world are registered N…', /^N[A-Z]{3,}$/.test(await one(`select game.next_reg($1)`, [W])) && /^VT-/.test(await one(`select game.next_reg()`)));
  ok("India's festivals move demand only in India worlds", Number(await one(`select count(*) from public.demand_events where region <> 'india'`)) === 0);
  await one(`select game.apply_region($1)`, [W]);
  ok('the region values are applied once only', Number(await one(`select num from public.world_params where world_id = $1 and key = 'growth_year'`, [W])) === 0.028);

  // founding in the US world: US airports only
  const code = await one(`select invite_code from public.world_secrets where world_id = $1`, [W]);
  await as(U);
  await fails('a US world refuses a base in India', `select public.found_airline('${code}', 'Peach Air', 'PA', 'DEL')`, /airports in USA/);
  const A = await one(`select public.found_airline('${code}', 'Peach Air', 'PA', 'ATL')`);
  ok('a US world founds an airline at Atlanta', !!A);
  await as(null);
  await one(`select public.admin_start_world($1)`, [W]);
  await as(U);
  await fails('and refuses a second base abroad', `select public.open_base('${A}', 'YYZ')`, /airports in USA/);
  await as(null);
  ok('no computer-run airlines from India in a US world', Number(await one(`select count(*) from public.airlines where world_id = $1 and is_ai`, [W])) === 0);
  const wet = Number(await one(`select game.wet_rate_usd($1, 'A20N')`, [W])), wetIn = Number(await one(`select game.wet_rate_usd($1, 'A20N')`, [w1]));
  ok('a wet lease costs more in dollars in the US (its crew are paid US rates)', wet > wetIn * 1.2, `${wet} vs ${wetIn}`);
}
