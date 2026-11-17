// Stage 2a: reference data and rule functions match docs/SPEC.md.
export async function checks2a(t) {
  console.log('Stage 2a: reference data');
  const m = (await t.q(`select count(*)::int n, round(sum(n_biz+n_lei+n_bud) filter (where not intl))::int dom from public.markets`))[0];
  t.ok('markets built', m.n > 6000, `${m.n} markets`);
  const dm = (await t.q(`select km, round((n_biz+n_lei+n_bud)*0.65)::int flown, ref_fare from public.markets where a='BOM' and b='DEL'`))[0];
  t.ok('Delhi-Mumbai about 12,600 each way a day', Math.abs(dm.flown - 12600) < 300, `${dm.flown} at ${dm.km} km, ref fare ${dm.ref_fare}`);
  const seats = await t.q(`select t.id, l.seats from public.aircraft_types t, lateral public.layout_calc(t.id, 0, null, 29) l order by t.sort`);
  t.ok('all-economy seats at 29 in', seats.map((r) => r.seats).join() === '72,180,228,228,432', seats.map((r) => `${r.id} ${r.seats}`).join(' '));
  t.ok('A320neo two-class 162', await t.one(`select seats from public.layout_calc('A20N', 3, 38, 30)`) === 162);
  t.ok('A350 36 lie-flat 324', await t.one(`select seats from public.layout_calc('A359', 9, null, 31)`) === 324);
  t.ok('ATR takes no business cabin', await t.one(`select valid from public.layout_calc('AT76', 2, 38, 29)`) === false);
  const b = (await t.q(`select round(game.block_hours('A20N', 1150), 2)::float blk, round(game.sector_fuel_kg('A20N', 1150, 180))::int fuel`))[0];
  t.ok('Delhi-Mumbai block 2.09 h', b.blk === 2.09, `fuel ${b.fuel} kg`);
  t.ok('first world waiting, invite code set',
    await t.one(`select status = 'setup' and (select length(invite_code) from public.world_secrets s where s.world_id = w.id) = 8 from public.worlds w`));
}
