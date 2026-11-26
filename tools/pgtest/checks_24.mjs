// Airports and traffic for every home region (migration 0035, spec 14.28). India's markets and airports must not change.
export async function checks24(t) {
  const { q, one, ok, as, fails } = t;
  await as(null);
  console.log('Airports and traffic for every home region (0035)');

  // the same fingerprints as before 0035 (taken from a database with 0001-0034)
  const indiaMarkets = `select count(*)::int n, md5(string_agg(concat_ws(',', a, b, km, intl, n_biz, n_lei, n_bud, ref_fare), ';' order by a, b)) h
    from public.markets m where exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.is_india)`;
  const im = (await q(indiaMarkets))[0];
  ok("India's 6,584 markets are exactly as before", im.n === 6584 && im.h === '0f879dfc9888cb7510190f328b2e6ac4', JSON.stringify(im));
  const ia = (await q(`select count(*)::int n, md5(string_agg(concat_ws(',', iata, city, country, region, lat, lon, pax_m, intl_share, mass,
      biz_idx, tour_idx, slot_cap, runway_class, opens_day), ';' order by iata)) h from public.airports where is_india`))[0];
  ok("India's 93 airports are exactly as before", ia.n === 93 && ia.h === 'b9719ea10087af8afcaebc5a651924df', JSON.stringify(ia));

  const src = (await q(`select count(*) filter (where pax_src = 'V')::int v, count(*) filter (where pax_src = 'G')::int g
      from public.airports where not is_india`))[0];
  ok('245 airports outside India carry published figures (0036), 95 stay estimates', src.v === 245 && src.g === 95, JSON.stringify(src));
  const atl = await one(`select pax_m from public.airports where iata = 'ATL'`);
  ok('Atlanta has its published figure (FAA 2025 boardings x 2)', Number(atl) === 102.9, atl);
  const fa = (await q(`select count(*)::int n, count(*) filter (where mass is null)::int new,
      count(*) filter (where pax_m is null or intl_share is null or od_share is null)::int gaps from public.airports where not is_india`))[0];
  ok('340 airports outside India, 271 of them new, every one with passengers and shares', fa.n === 340 && fa.new === 271 && fa.gaps === 0, JSON.stringify(fa));
  const homes = await q(`select home, count(*)::int n from public.airports where home is not null group by home order by home`);
  const want = { africa: 36, canada: 15, china: 46, europe: 75, india: 93, middle_east: 24, south_america: 39, usa: 53 };
  ok('home airports per region', homes.every((r) => want[r.home] === r.n) && homes.length === 8, homes.map((r) => `${r.home} ${r.n}`).join(', '));

  const seen = (await q(`select count(*) filter (where home is not null and not home = any(seen_in))::int missing,
      count(*) filter (where 'india' = any(seen_in))::int india from public.airports`))[0];
  ok('every airport is seen in its own region, and an India world shows the same 162 airports as before', seen.missing === 0 && seen.india === 162, JSON.stringify(seen));

  const mk = (await q(`select count(*) filter (where not exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.is_india))::int other,
      count(*) filter (where zone = 'india')::int india_dom,
      count(*) filter (where zone is distinct from (select case when x.home = y.home then x.home end from public.airports x, public.airports y
                                                    where x.iata = m.a and y.iata = m.b))::int wrong_zone
      from public.markets m`))[0];
  ok('25,683 markets outside India (0036); zones set (India domestic 4,278)', mk.other === 25683 && mk.india_dom === 4278 && mk.wrong_zone === 0, JSON.stringify(mk));
  const pairs = await q(`select a || '-' || b p, round(n_biz + n_lei + n_bud) n from public.markets
     where (a, b) in (('JFK','LHR'), ('BCN','MAD'), ('JED','RUH'), ('PEK','SHA'), ('CPT','JNB'), ('BOG','MDE'), ('YUL','YYZ'), ('IST','SAW'))
     order by 1`);
  ok('known markets exist and the two Istanbul airports have none between them',
    pairs.length === 7 && !pairs.some((r) => r.p === 'IST-SAW') && pairs.every((r) => Number(r.n) > 1000), pairs.map((r) => `${r.p} ${r.n}`).join(', '));
  const thin = await one(`select count(*)::int from public.markets m where zone is null and intl and n_biz + n_lei + n_bud < 1.9
     and not exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.is_india)`);
  ok('no new market between countries under 2 potential travellers a day each way', thin === 0, thin);
  const rw = await q(`select iata, runway_class from public.airports where iata in ('YTZ', 'LGA', 'ATL', 'SDU', 'EDI') order by iata`);
  ok('runway classes: Toronto Island turboprops, LaGuardia and Santos Dumont narrowbodies, Atlanta and Edinburgh widebodies',
    rw.map((r) => `${r.iata}${r.runway_class}`).join(' ') === 'ATL3 EDI3 LGA2 SDU2 YTZ1', rw.map((r) => `${r.iata}${r.runway_class}`).join(' '));

  const w1 = await one(`select id from public.worlds where name = 'World 1'`);
  ok("a world without a region is India's", (await one(`select game.world_region('${w1}')`)) === 'india');
  const top = await q(`select string_agg(a || b, ',' order by n desc) s from (select a, b, n_biz + n_lei + n_bud n from public.markets m
     where m.zone = game.world_region('${w1}') order by n desc limit 8) x
     union all select string_agg(a || b, ',' order by n desc) from (select a, b, n_biz + n_lei + n_bud n from public.markets m
     where not m.intl and exists (select 1 from public.airports x where x.iata = m.a and x.is_india) order by n desc limit 8) y`);
  ok("an India world's eight busiest home markets are the eight it had", top[0].s === top[1].s, top[0].s);

  const al = await one(`select a.id from public.airlines a join public.worlds w on w.id = a.world_id
     where w.status = 'running' and not a.is_ai and game.world_region(w.id) = 'india' order by a.id limit 1`);
  await q('begin');
  await q(`update public.airline_finance set cash_inr = 1e10 where airline_id = $1`, [al]);
  await q('savepoint s');
  await fails('an India world cannot study a pair outside India', `select public.route_study('${al}', 'ATL', 'DEN', 'quick')`, /There is no market between ATL and DEN/);
  await q('rollback to savepoint s');
  const st = await one(`select public.route_study('${al}', 'DEL', 'DXB', 'quick') is not null`);
  ok('an India world still studies Delhi-Dubai', st === true);
  await q('rollback');

  await q('begin');
  await q(`select game.rebuild_markets()`);
  const after = (await q(indiaMarkets))[0];
  const other = await one(`select count(*)::int from public.markets m where not exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.is_india)
     and n_biz + n_lei + n_bud > 0`);
  ok("rebuilding India's markets gives the same markets and keeps the other regions'", after.h === im.h && other === 25683, `${after.h} ${other}`);
  await q('rollback');
}
