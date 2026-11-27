"""Airports and traffic for the home regions outside India (spec 14.28).

Usage: python3 -I tools/build_regions.py <ourairports airports.csv> <ourairports runways.csv> [out.sql [refresh]]

Without out.sql it prints the calibration report only. With 'refresh' it writes a whole data migration that updates
every airport outside India (adding airports new since, and their homes) and rebuilds every market outside India
(refused if a route flies one); without it, the
airport part of 0035 (the first build).

Inputs (supabase/seed): airports_world.csv (new airports, and figures for the foreign airports already in the
game), regions_model.csv (road/rail cut-off, distance decay and coverage per home region; the 'intl' row is for
flights between countries), zone_affinity.csv and country_affinity.csv (ties between zones and countries;
'RU,*EUR,0' means Russia with every country in zone EUR unless a country pair says otherwise).

Model, the same shape as tools/calibrate.py:
  Domestic, per country with two or more home airports: doubly constrained gravity. Each airport's pair totals add
  up to its domestic travellers who start or end there (passengers x (1 - international share) x share that are
  not changing planes x coverage); pairs weigh air_share(km, d0) x (km / 1000) ^ -beta.
  International, between airports in different countries: doubly constrained gravity over every airport outside
  India, with the travellers India's markets already carry (tools/calibrate.py) taken off first. Pairs weigh
  air_share(km, 300) x (km / 1000) ^ -0.9 x zone tie x country tie. Pairs between two destination-only airports
  are dropped (no world is based at either end).
India's markets are not touched.
"""
import csv, math, os, sys

here = os.path.dirname(os.path.abspath(__file__))
seed = os.path.join(here, '..', 'supabase', 'seed')
sys.path.insert(0, here)
sys.dont_write_bytecode = True
import calibrate  # noqa: E402  (India's reference model: its international flows are taken off first)

CAPTURE = calibrate.CAPTURE
MIN_N = 1.0        # potential travellers a day each way, at demand scale 1, for a domestic pair to become a market
MIN_N_INTL = 2.0   # and for a pair between countries (thinner ones could never fill a flight)

world = list(csv.DictReader(open(os.path.join(seed, 'airports_world.csv'))))
frn = {r['iata']: r for r in csv.DictReader(open(os.path.join(seed, 'airports_foreign.csv')))}
model = {r['home']: r for r in csv.DictReader(open(os.path.join(seed, 'regions_model.csv')))}
zaff = {}
for r in csv.DictReader(open(os.path.join(seed, 'zone_affinity.csv'))):
    zaff[(r['zone_a'], r['zone_b'])] = zaff[(r['zone_b'], r['zone_a'])] = float(r['mult'])
ccover = {r['country']: float(r['cover_dom']) for r in csv.DictReader(open(os.path.join(seed, 'country_cover.csv')))}
SAME_CITY_KM = 100   # pairs closer than this are one city's airports: no traffic between them
caff = {}
for r in csv.DictReader(open(os.path.join(seed, 'country_affinity.csv'))):
    caff[(r['country_a'], r['country_b'])] = caff[(r['country_b'], r['country_a'])] = float(r['mult'])

codes = {r['iata'] for r in world}
assert len(codes) == len(world), 'duplicate rows in airports_world.csv'
assert set(frn) <= codes, f'foreign airports without figures: {sorted(set(frn) - codes)}'
assert not codes & set(calibrate.ind), 'an Indian airport in airports_world.csv'

# OurAirports: position, country and longest open runway
rank = {'large_airport': 0, 'medium_airport': 1, 'small_airport': 2}
pos, ident = {}, {}
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    c = r['iata_code']
    if c in codes and r['type'] in rank:
        k = (rank[r['type']], 0 if r['scheduled_service'] == 'yes' else 1)
        if c not in pos or k < pos[c][0]:
            pos[c] = (k, round(float(r['latitude_deg']), 4), round(float(r['longitude_deg']), 4), r['iso_country'])
            ident[c] = r['ident']
missing = sorted(codes - set(pos))
assert not missing, f'not in OurAirports: {missing}'
rwy_ft = {}
for r in csv.DictReader(open(sys.argv[2], encoding='utf-8')):
    if r['closed'] != '1' and r['length_ft']:
        rwy_ft[r['airport_ident']] = max(rwy_ft.get(r['airport_ident'], 0), int(r['length_ft']))


def runway_class(c):
    ft = rwy_ft.get(ident[c], 0)
    return 3 if ft >= 8900 else 2 if ft >= 5900 else 1


A = {}
for r in world:
    c = r['iata']
    old = frn.get(c)
    A[c] = dict(
        iata=c, new=old is None, zone=r['zone'], home=r['home'] or None,
        country=r['country'] or pos[c][3], lat=pos[c][1], lon=pos[c][2],
        pax=float(r['pax_m']), src=r['pax_src'], intl=float(r['intl_share']), od=float(r['od_share']),
        city=r['city'] or (old and old['city']), biz=r['biz'] or old['biz'], tour=r['tour'] or old['tour'],
        slot=r['slot_cap'] or None, rwy=int(r['rwy']) if r['rwy'] else (runway_class(c) if old is None else int(old['rwy'])))
    assert 0 <= A[c]['intl'] <= 1 and 0 < A[c]['od'] <= 1, c
    assert A[c]['home'] is None or A[c]['home'] in model, c


def km(a, b):
    p, q = A[a], A[b]
    return 2 * 6371 * math.asin(math.sqrt(
        math.sin(math.radians(q['lat'] - p['lat']) / 2) ** 2
        + math.cos(math.radians(p['lat'])) * math.cos(math.radians(q['lat'])) * math.sin(math.radians(q['lon'] - p['lon']) / 2) ** 2))


def air_share(d, d0, power=3.0):
    return 1 - 1 / (1 + (d / d0) ** power)


def balance(nodes, target, weight, rounds=300):
    """Doubly constrained, symmetric: T[a,b] = f[a] f[b] t[a] t[b] w[a,b], with every airport's sum = its target."""
    f = {c: 1.0 for c in nodes}
    live = [c for c in nodes if target[c] > 0]
    for _ in range(rounds):
        for a in live:
            tot = sum(f[b] * target[b] * w for b, w in weight[a].items())
            if tot > 0:
                f[a] *= math.sqrt(target[a] / (f[a] * target[a] * tot))
    return {(a, b): f[a] * f[b] * target[a] * target[b] * w
            for a in nodes for b, w in weight[a].items() if a < b}


# India's international flows, a year (millions), by foreign airport: these markets exist and stay as they are
ipos = calibrate.load_positions(sys.argv[1])
india = {}
for (a, b), v in calibrate.international(ipos).items():
    if calibrate.per_day_each_way(v) / CAPTURE >= 1:   # only the pairs that became markets
        india[b] = india.get(b, 0) + v

# Domestic, country by country. Business travellers mind distance less: a pair's decay is beta x (1 - biz_a x biz_b),
# so New York-Los Angeles is a big market and Las Vegas-Orlando is not.
dom_out = {}
by_country = {}
for c, x in A.items():
    if x['home']:
        by_country.setdefault(x['country'], []).append(c)
for ctry, nodes in by_country.items():
    if len(nodes) < 2:
        continue
    m = model[A[nodes[0]]['home']]
    d0, beta, cover = float(m['d0_km']), float(m['beta']), ccover.get(ctry, float(m['cover_dom']))
    t = {c: A[c]['pax'] * (1 - A[c]['intl']) * A[c]['od'] * cover for c in nodes}
    w = {a: {b: air_share(km(a, b), d0) * (km(a, b) / 1000) ** (-beta * (1 - float(A[a]['biz']) * float(A[b]['biz'])))
             for b in nodes if b != a and km(a, b) >= SAME_CITY_KM} for a in nodes}
    dom_out.update(balance(nodes, t, w))


def country_tie(p, q):
    for k in ((p['country'], q['country']),):
        if k in caff:
            return caff[k]
    if (p['country'], '*' + q['zone']) in caff:
        return caff[(p['country'], '*' + q['zone'])]
    if (q['country'], '*' + p['zone']) in caff:
        return caff[(q['country'], '*' + p['zone'])]
    return 1.0


# International, every airport outside India
im = model['intl']
D0I, BETAI = float(im['d0_km']), float(im['beta'])
TUNE = __import__('json').loads(os.environ.get('TUNE', '{}'))   # for calibration runs only
BETAI = TUNE.get('beta', BETAI)
for k, v in TUNE.get('zaff', {}).items():
    za, zb = k.split('-'); zaff[(za, zb)] = zaff[(zb, za)] = v
nodes = sorted(A)
t = {}
for c in nodes:
    x = A[c]
    cover = float(model[x['home']]['cover_intl']) if x['home'] else float(model['dest:' + x['zone']]['cover_intl'])
    t[c] = max(0.0, x['pax'] * x['intl'] * x['od'] * cover - india.get(c, 0))
# Long-haul (LH_KM and over) and short-haul are balanced apart: each airport's share of long-haul travel is its zone's,
# scaled by its business index / its zone's average, so hubs send more travellers far than leisure airports.
zlong = {r['zone']: float(r['long_share']) for r in csv.DictReader(open(os.path.join(seed, 'zone_longhaul.csv')))}
LH_KM = TUNE.get('lh_km', float(model['long']['d0_km']))        # the 'long' row: where long-haul starts, and its decay
BETA_LONG = TUNE.get('beta_long', float(model['long']['beta']))
zbiz = {}
for x in A.values():
    zbiz.setdefault(x['zone'], []).append(float(x['biz']))
LH_POW = TUNE.get('lh_pow', 1)
lshare = {c: min(0.75, max(0.02, zlong[x['zone']] * (float(x['biz']) / (sum(zbiz[x['zone']]) / len(zbiz[x['zone']]))) ** LH_POW))
          for c, x in A.items()}
ws = {a: {} for a in nodes}
wl = {a: {} for a in nodes}
for i, a in enumerate(nodes):
    for b in nodes[i + 1:]:
        p, q = A[a], A[b]
        d = km(a, b)
        if p['country'] == q['country'] or d < SAME_CITY_KM:
            continue
        tie = zaff.get((p['zone'], q['zone']), 1.0) * country_tie(p, q)
        if tie <= 0:
            continue
        if d < LH_KM:
            ws[a][b] = ws[b][a] = air_share(d, D0I) * (d / 1000) ** -BETAI * tie
        else:
            wl[a][b] = wl[b][a] = (d / 1000) ** -BETA_LONG * tie
for r in csv.DictReader(open(os.path.join(seed, 'longhaul_hubs.csv'))):   # the big hubs' own long-haul shares
    lshare[r['iata']] = float(r['long_share'])
for c in nodes:   # an airport with no foreign airport in one of the two bands sends all its travellers to the other
    if not ws[c]:
        lshare[c] = 1.0
    elif not wl[c]:
        lshare[c] = 0.0
ts = {c: t[c] * (1 - lshare[c]) for c in nodes}
tl = {c: t[c] * lshare[c] for c in nodes}
both = balance(nodes, ts, ws)
for p, v in balance(nodes, tl, wl).items():
    both[p] = both.get(p, 0) + v
intl_out = {p: v for p, v in both.items() if A[p[0]]['home'] or A[p[1]]['home']}


def n_day(annual_m):
    return annual_m * 1e6 / 2 / 365 / CAPTURE


markets = {p: n_day(v) for p, v in dom_out.items() if n_day(v) >= MIN_N}
markets.update({p: n_day(v) for p, v in intl_out.items() if n_day(v) >= MIN_N_INTL})


def report():
    print(f"airports: {len(A)} outside India ({sum(x['new'] for x in A.values())} new), "
          f"home: " + ', '.join(f"{h} {sum(1 for x in A.values() if x['home'] == h)}" for h in model if ':' not in h and h not in ('intl', 'long')))
    print(f"markets: {len(markets)} ({sum(1 for p in markets if p in dom_out)} domestic, {sum(1 for p in markets if p in intl_out)} between countries)")
    print(f"India's flows taken off first (M a year): " + ', '.join(f"{c} {v:.1f}" for c, v in sorted(india.items(), key=lambda x: -x[1])[:8]))
    # every airport's total against its target, domestic and international
    worst = []
    for c, x in A.items():
        d = sum(v for p, v in dom_out.items() if c in p)
        i = sum(v for p, v in balance_all.items() if c in p)
        worst.append((abs(i - t[c]) / t[c] if t[c] > 1 else 0, c))
    print('largest international balancing error: {:.2%} ({})'.format(*max(worst)))
    for h in [k for k in model if ':' not in k and k not in ('intl', 'long')]:
        top = sorted(((p, n) for p, n in markets.items() if A[p[0]]['home'] == h or A[p[1]]['home'] == h), key=lambda x: -x[1])
        dom = sorted(((p, n) for p, n in markets.items() if p in dom_out and A[p[0]]['home'] == h), key=lambda x: -x[1])
        print(f"\n{h}: {len(top)} markets; busiest domestic: " + ', '.join(f"{a}-{b} {n:,.0f}" for (a, b), n in dom[:6]))
        print('   busiest abroad: ' + ', '.join(f"{a}-{b} {n:,.0f}" for (a, b), n in [x for x in top if x[0] in intl_out][:8]))
    eur = [c for c, x in A.items() if x['home'] == 'europe']
    tot = sum(v for p, v in intl_out.items() if A[p[0]]['home'] == 'europe' or A[p[1]]['home'] == 'europe')
    intra = sum(v for p, v in intl_out.items() if A[p[0]]['zone'] == 'EUR' and A[p[1]]['zone'] == 'EUR')
    lhr = sum(v for p, v in intl_out.items() if 'LHR' in p)
    lhr_n = sum(v for p, v in intl_out.items() if 'LHR' in p and 'NAM' in (A[p[0]]['zone'], A[p[1]]['zone']))
    print('long-haul shares: ' + ', '.join(f"{c} {lshare[c]:.2f}" for c in ['LHR', 'STN', 'CDG', 'FRA', 'JFK', 'MCO', 'DXB', 'DOH', 'PVG', 'GRU', 'JNB', 'MEX']))
    print(f"\nEurope: {intra / tot:.0%} of travel between countries stays in Europe; LHR to North America {lhr_n / lhr:.0%} of LHR's")
    print('\nchecks (potential a day each way; real flown both ways a year in brackets):')
    for a, b in [('JFK', 'LHR'), ('DXB', 'LHR'), ('LAX', 'SFO'), ('ATL', 'MCO'), ('JFK', 'LAX'), ('BCN', 'MAD'), ('PEK', 'SHA'),
                 ('CAN', 'PEK'), ('HKG', 'TPE'), ('CAI', 'JED'), ('JNB', 'CPT'), ('CGH', 'SDU'), ('BOG', 'MDE'), ('YUL', 'YYZ'),
                 ('JFK', 'YYZ'), ('DUB', 'LHR'), ('AYT', 'DUS'), ('DXB', 'KHI'), ('IST', 'SAW'), ('RUH', 'JED'), ('MEX', 'LAX'), ('CUN', 'JFK')]:
        p = (min(a, b), max(a, b))
        v = dom_out.get(p, intl_out.get(p))
        print(f"  {p[0]}-{p[1]}: {n_day(v):,.0f} ({v:.2f}M), {km(*p):,.0f} km" if v else f"  {p[0]}-{p[1]}: none")


balance_all = both
if len(sys.argv) <= 3:
    report()
    sys.exit(0)

MARKETS_SQL = """
insert into public.markets (a, b, km, intl, n_biz, n_lei, n_bud, ref_fare)
select f.a, f.b, round(x.km)::int, p.country <> q.country,
       round((f.n * x.sb)::numeric, 1), round((f.n * (1 - x.sb) * x.sl)::numeric, 1),
       round((f.n * (1 - x.sb) * (1 - x.sl))::numeric, 1),
       (round((game.param('ref_fare_fixed') + game.param('ref_fare_per_km') * x.km) / 10) * 10)::int
  from region_flows f
  join public.airports p on p.iata = f.a
  join public.airports q on q.iata = f.b
  cross join lateral (select game.haversine_km(p.lat::float8, p.lon::float8, q.lat::float8, q.lon::float8) as km,
                             0.08 + 0.27 * (p.biz_idx + q.biz_idx)::float8 / 2 as sb,
                             0.30 + 0.45 * greatest(p.tour_idx, q.tour_idx)::float8 as sl) x;
drop table region_flows;

update public.airports ap set seen_in = coalesce(s.regions, '{}')
  from public.airports a0
  left join (select x, array_agg(distinct r order by r) as regions
               from (select iata as x, home as r from public.airports where home is not null
                     union
                     select e.x, o.home from (select a as x, b as y from public.markets union all select b, a from public.markets) e
                       join public.airports o on o.iata = e.y where o.home is not null) z
              group by x) s on s.x = a0.iata
 where ap.iata = a0.iata;
"""
q = lambda s: "'" + str(s).replace("'", "''") + "'"
nl = lambda s: q(s) if s not in (None, '') else 'null'
out = open(sys.argv[3], 'w')
w_ = out.write
new = [x for x in A.values() if x['new']]
old = [x for x in A.values() if not x['new']]
REFRESH = len(sys.argv) > 4 and sys.argv[4] == 'refresh'
if not REFRESH:   # the first build (0035): new airports, and figures for the older foreign ones
    w_("insert into public.airports (iata,city,country,region,is_india,lat,lon,pax_m,pax_src,intl_share,od_share,home,biz_idx,tour_idx,slot_cap,runway_class) values\n")
    w_(",\n".join(f"({q(x['iata'])},{q(x['city'])},{q(x['country'])},{q(x['zone'])},false,{x['lat']:.4f},{x['lon']:.4f},{x['pax']},{q(x['src'])},"
                  f"{x['intl']},{x['od']},{nl(x['home'])},{x['biz']},{x['tour']},{x['slot'] or 'null'},{x['rwy']})" for x in new) + ";\n\n")
    w_("update public.airports a set pax_m = v.pax_m, pax_src = v.pax_src, intl_share = v.intl_share, od_share = v.od_share, home = v.home,\n"
       "  region = v.region\nfrom (values\n")
    w_(",\n".join(f"({q(x['iata'])},{x['pax']}::numeric,{q(x['src'])},{x['intl']}::numeric,{x['od']}::numeric,{nl(x['home'])},{q(x['zone'])})" for x in old))
    w_(") v (iata, pax_m, pax_src, intl_share, od_share, home, region)\nwhere a.iata = v.iata and not a.is_india;\n\n")
    w_("create temp table region_flows (a text, b text, n float8);\ninsert into region_flows (a, b, n) values\n")
    w_(",\n".join(f"({q(a)},{q(b)},{n:.2f})" for (a, b), n in sorted(markets.items())) + ";\n")
else:             # a refresh: airports added since (on conflict nothing), new figures and homes for every airport outside
                  # India, and every market outside India rebuilt
    w_("insert into public.airports (iata,city,country,region,is_india,lat,lon,pax_m,pax_src,intl_share,od_share,home,biz_idx,tour_idx,slot_cap,runway_class) values\n")
    w_(",\n".join(f"({q(x['iata'])},{q(x['city'])},{q(x['country'])},{q(x['zone'])},false,{x['lat']:.4f},{x['lon']:.4f},{x['pax']},{q(x['src'])},"
                  f"{x['intl']},{x['od']},{nl(x['home'])},{x['biz']},{x['tour']},{x['slot'] or 'null'},{x['rwy']})" for x in new))
    w_("\non conflict (iata) do nothing;\n\n")
    w_("update public.airports a set pax_m = v.pax_m, pax_src = v.pax_src, intl_share = v.intl_share, od_share = v.od_share, home = v.home,\n"
       "  region = v.region\nfrom (values\n")
    w_(",\n".join(f"({q(x['iata'])},{x['pax']}::numeric,{q(x['src'])},{x['intl']}::numeric,{x['od']}::numeric,{nl(x['home'])},{q(x['zone'])})"
                  for x in A.values()))
    w_(") v (iata, pax_m, pax_src, intl_share, od_share, home, region)\nwhere a.iata = v.iata and not a.is_india;\n\n")
    w_("do $$ begin\n  if exists (select 1 from public.routes r join public.airports o on o.iata = r.origin join public.airports d on d.iata = r.dest\n"
       "             where not o.is_india and not d.is_india) then\n    raise exception 'A route flies a market outside India: rebuild it by hand';\n  end if;\nend $$;\n")
    w_("delete from public.markets m where not exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.is_india);\n\n")
    w_("create temp table region_flows (a text, b text, n float8);\ninsert into region_flows (a, b, n) values\n")
    w_(",\n".join(f"({q(a)},{q(b)},{n:.2f})" for (a, b), n in sorted(markets.items())) + ";\n")
    w_(MARKETS_SQL)
out.close()
print(f"wrote {'a refresh of ' + str(len(A)) + ' airports' if REFRESH else str(len(new)) + ' new airports, ' + str(len(old)) + ' updated'}, {len(markets)} markets to {sys.argv[3]}")
