// The consultant as a world rule (migration 0032): Off, Free, Standard or Premium, chosen when a world is founded.
export async function checks21(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('The consultant as a world rule (0032)');
  const ADMIN = '00000000-0000-0000-0000-0000000021a1';
  await q(`insert into auth.users (id) values ($1) on conflict do nothing`, [ADMIN]);
  await q(`insert into public.profiles (user_id, display_name, is_admin) values ($1, 'Admin 21', true) on conflict (user_id) do update set is_admin = true`, [ADMIN]);
  const made = [];
  async function world(name, code, rules) {
    await as(ADMIN);
    const w = await one(`select public.create_world($1, $2)`, [name, JSON.stringify({ bots: 'none', min_players: 1, ...rules })]);
    const a = await one(`select public.found_airline($1, $2, $3, 'DEL')`, [w.invite, `${name} Air`, code]);
    await as(null);
    await q(`select public.admin_start_world($1)`, [w.world_id]);
    made.push(w.world_id);
    return { W: w.world_id, A: a };
  }
  const cash = async (a) => Number(await one(`select cash_inr from public.airline_finance where airline_id = $1`, [a]));
  const status = async (a) => { await as(ADMIN); const s = await one(`select public.consultant_status($1)`, [a]); await as(null); return s; };

  const opts = await q(`select option from public.world_options where setting = 'consultant' order by sort`);
  ok('four choices: Off, Free, Standard (the default) and Premium',
    opts.map((r) => r.option).join(',') === 'off,free,standard,premium'
    && (await one(`select option from public.world_options where setting = 'consultant' and is_default`)) === 'standard');
  const w1 = (await q(`select rules->>'consultant' c, game.wparam(id, 'consultant_fee_share') s from public.worlds where name = 'World 1'`))[0];
  ok('a world made before 0032 is Standard, in its own values', !w1 || (w1.c === 'standard' && Number(w1.s) === 0.01), JSON.stringify(w1));

  const off = await world('Off 21', 'O1', { consultant: 'off' });
  const so = await status(off.A);
  ok('Off: nobody can ask, with a plain reason', so.can_ask === false && /founded without the consultant/.test(so.reason) && so.on === false, so.reason);
  await as(ADMIN);
  await fails('Off: starting a report is refused', `select public.consultant_start('${off.A}')`, /founded without the consultant/);
  await as(null);

  const free = await world('Free 21', 'F1', { consultant: 'free' });
  await q(`insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax) values ($1, 1, 6e9, 1e8, 5e7, 100000)`, [free.A]);
  const sf = await status(free.A);
  const c0 = await cash(free.A);
  await as(ADMIN);
  const r1 = await one(`select public.consultant_start($1)`, [free.A]);
  await as(null);
  ok('Free: no fee, even after a quarter of revenue, and nothing is booked', Number(sf.fee_inr) === 0 && sf.can_ask && Number(r1.fee_inr) === 0
    && await cash(free.A) === c0 && Number(await one(`select count(*) from public.transactions where airline_id = $1 and kind = 'consultant'`, [free.A])) === 0);
  await q(`select public.consultant_finish($1, false, null, 0, 0, 0, 0, 'test')`, [r1.report_id]);
  ok('Free: a failed report refunds nothing', await cash(free.A) === c0
    && Number(await one(`select count(*) from public.transactions where airline_id = $1 and kind = 'consultant'`, [free.A])) === 0);

  const prem = await world('Premium 21', 'P1', { consultant: 'premium' });
  const sp0 = await status(prem.A);
  await q(`insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax) values ($1, 1, 6e9, 1e8, 5e7, 100000)`, [prem.A]);
  const sp1 = await status(prem.A);
  ok('Premium: at least Rs 1 crore, then 3% of last quarter\'s revenue', Number(sp0.fee_inr) === 1e7 && Number(sp1.fee_inr) === 1.8e8
    && Number(sp1.fee_share) === 0.03, `${sp0.fee_inr} ${sp1.fee_inr}`);

  const std = await world('Standard 21', 'S1', {});
  const ss = await status(std.A);
  ok('a world founded without choosing gets Standard', (await one(`select rules->>'consultant' from public.worlds where id = $1`, [std.W])) === 'standard'
    && Number(ss.fee_inr) === 2.5e6 && Number(ss.fee_share) === 0.01, JSON.stringify(ss));
  await fails('the rule is fixed once founded: the disruption values cannot change it',
    `select public.admin_set_disruptions('${prem.W}', '{"consultant_fee_share": 0}')`, /Not a disruption value/);
  await as(ADMIN);
  await fails('and an unknown choice is refused', `select public.create_world('Bad 21', '{"consultant": "gold"}')`, /consultant options/);
  await as(null);

  for (const w of made) await q(`delete from public.worlds where id = $1`, [w]);
}
