"""Reference implementation of the market model, used to check the SQL version.

Usage: python3 -I tools/calibrate.py <ourairports airports.csv>

Domestic: doubly constrained gravity model. Every airport's pair totals add up to its
real domestic passenger count; pairs are weighted by the share of travellers who fly
rather than go by road or rail. International: each Indian airport's international
passengers are split over foreign airports by mass x affinity.
"""
import csv, math, os, sys

here = os.path.dirname(os.path.abspath(__file__))
seed = os.path.join(here, '..', 'supabase', 'seed')
ind = {r['iata']: r for r in csv.DictReader(open(os.path.join(seed, 'airports_india.csv')))}
frn = {r['iata']: r for r in csv.DictReader(open(os.path.join(seed, 'airports_foreign.csv')))}
aff = {(r['india_region'], r['foreign_region']): float(r['mult'])
       for r in csv.DictReader(open(os.path.join(seed, 'intl_affinity.csv')))}

D0, POW, CAPTURE = 300.0, 3.0, 0.65


def load_positions(src):
    rank = {'large_airport': 0, 'medium_airport': 1, 'small_airport': 2}
    pos = {}
    for r in csv.DictReader(open(src, encoding='utf-8')):
        c = r['iata_code']
        if (c in ind or c in frn) and r['type'] in rank:
            k = (rank[r['type']], 0 if r['scheduled_service'] == 'yes' else 1)
            if c not in pos or k < pos[c][0]:
                pos[c] = (k, round(float(r['latitude_deg']), 4), round(float(r['longitude_deg']), 4))
    return pos


def km(pos, a, b):
    (_, la1, lo1), (_, la2, lo2) = pos[a], pos[b]
    p1, p2 = math.radians(la1), math.radians(la2)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lo2 - lo1) / 2) ** 2
    return 2 * 6371 * math.asin(math.sqrt(h))


def air_share(d):
    return 1 - 1 / (1 + (d / D0) ** POW)


def domestic(pos):
    """Annual passengers (millions, both directions) per pair of Indian airports."""
    dom = {c: float(r['pax_m']) * (1 - float(r['intl_share'])) for c, r in ind.items()}
    now = [c for c, r in ind.items() if r['opens_day'] == '0']
    later = [c for c in ind if c not in now]
    w = {(a, b): air_share(km(pos, a, b)) for a in ind for b in ind if a != b}
    f = {c: 1.0 for c in now}
    for _ in range(200):
        for a in now:
            tot = sum(f[a] * f[b] * dom[a] * dom[b] * w[(a, b)] for b in now if b != a)
            f[a] *= math.sqrt(dom[a] / tot)
    for c in later:
        f[c] = f[ind[c]['sibling']]
    out = {}
    codes = sorted(ind)
    for i, a in enumerate(codes):
        for b in codes[i + 1:]:
            out[(a, b)] = f[a] * f[b] * dom[a] * dom[b] * w[(a, b)]
    return out, dom, now


def international(pos):
    out = {}
    for a, r in ind.items():
        intl = float(r['pax_m']) * float(r['intl_share'])
        if intl <= 0:
            continue
        wts = {b: float(fr['mass']) * aff.get((r['region'], fr['region']), 1.0) for b, fr in frn.items()}
        tot = sum(wts.values())
        for b, wt in wts.items():
            out[(a, b)] = intl * wt / tot
    return out


def per_day_each_way(annual_m):
    return annual_m * 1e6 / 2 / 365


if __name__ == '__main__':
    pos = load_positions(sys.argv[1])
    dm, dom, now = domestic(pos)
    live = {p: v for p, v in dm.items() if p[0] in now and p[1] in now}
    tot = sum(live.values())
    print(f"domestic: {len(live)} pairs, {tot:.1f}M passengers a year, {per_day_each_way(tot)*2:,.0f} a day")
    worst = max(abs(sum(v for p, v in live.items() if c in p) - dom[c]) / dom[c] for c in now)
    print(f"largest airport-total error after balancing: {worst:.2%}")
    top = sorted(live.items(), key=lambda x: -x[1])[:12]
    print('top pairs (M a year):', ', '.join(f"{a}-{b} {v:.2f}" for (a, b), v in top))
    print(f"top 10 share of domestic: {sum(v for _, v in top[:10])/tot:.0%}")
    for p in [('BOM', 'DEL'), ('BLR', 'DEL'), ('BLR', 'BOM'), ('DEL', 'PAT'), ('BLR', 'MAA'), ('BOM', 'PNQ'), ('IDR', 'LKO')]:
        print(f"  {p[0]}-{p[1]}: {dm[p]:.2f}M a year, {per_day_each_way(dm[p]):,.0f} each way a day, {round(km(pos, *p))} km")
    it = international(pos)
    print(f"international: {sum(it.values()):.1f}M a year")
    by_f = {}
    for (a, b), v in it.items():
        by_f[b] = by_f.get(b, 0) + v
    print('top foreign (M a year):', ', '.join(f"{b} {v:.1f}" for b, v in sorted(by_f.items(), key=lambda x: -x[1])[:8]))
    for p in [('BOM', 'DXB'), ('DEL', 'LHR'), ('COK', 'DXB'), ('ATQ', 'LHR'), ('MAA', 'SIN'), ('DEL', 'JFK')]:
        print(f"  {p[0]}-{p[1]}: {per_day_each_way(it[p]):,.0f} each way a day, {round(km(pos, *p))} km")
    served = sum(1 for v in it.values() if per_day_each_way(v) / CAPTURE >= 1)
    print(f"international pairs with at least 1 potential passenger a day: {served}")
