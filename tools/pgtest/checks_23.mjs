// Refusals that read like the app (migration 0034): money in the app's format, grouped seat counts.
export async function checks23(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Clear refusals (0034)');
  const fmt = await q(`select game.inr_text(v) s from unnest(array[2389300000, 238930000, 23893000, 4530000, 12345.6, -25000000, 0]::numeric[]) v`);
  const want = ['₹239 cr', '₹23.9 cr', '₹2.39 cr', '₹45.3 lakh', '₹12,346', '−₹2.5 cr', '₹0'];
  ok('money in refusals reads as in the app', fmt.map((r) => r.s).join('|') === want.join('|'), fmt.map((r) => r.s).join('|'));
  const al = await one(`select a.id from public.airlines a join public.airline_finance f on f.airline_id = a.id where not a.is_ai order by f.cash_inr desc limit 1`);
  await q('begin');
  await q(`update public.airline_finance set cash_inr = 50000000 where airline_id = $1`, [al]);
  await q('savepoint s');
  await fails('a payment larger than the cash says what it needs and what there is',
    `select game.book('${al}', 1, -238930000, 'deposit', 'x')`, /Not enough cash: this needs ₹23\.9 cr and you have ₹5 cr in hand/);
  await q('rollback to savepoint s');
  await q('rollback');
}
