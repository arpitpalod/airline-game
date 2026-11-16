"""Builds the airport insert statements. Usage: python3 -I tools/build_airports_sql.py <ourairports airports.csv>"""
import csv, os, sys
here = os.path.dirname(os.path.abspath(__file__))
seed = os.path.join(here, '..', 'supabase', 'seed')
ind = list(csv.DictReader(open(os.path.join(seed, 'airports_india.csv'))))
frn = list(csv.DictReader(open(os.path.join(seed, 'airports_foreign.csv'))))
want = {r['iata'] for r in ind} | {r['iata'] for r in frn}
rank = {'large_airport': 0, 'medium_airport': 1, 'small_airport': 2}
pos = {}
for r in csv.DictReader(open(sys.argv[1], encoding='utf-8')):
    c = r['iata_code']
    if c in want and r['type'] in rank:
        k = (rank[r['type']], 0 if r['scheduled_service'] == 'yes' else 1)
        if c not in pos or k < pos[c][0]:
            pos[c] = (k, r['iso_country'], f"{float(r['latitude_deg']):.4f}", f"{float(r['longitude_deg']):.4f}")
q = lambda s: "'" + s.replace("'", "''") + "'"
n = lambda s: s if s else 'null'
print("insert into public.airports (iata,city,country,region,is_india,lat,lon,pax_m,pax_src,intl_share,biz_idx,tour_idx,slot_cap,runway_class,opens_day,sibling) values")
print(",\n".join(
    f"({q(r['iata'])},{q(r['city'])},'IN',{q(r['region'])},true,{pos[r['iata']][2]},{pos[r['iata']][3]},{r['pax_m']},{q(r['pax_src'])},{r['intl_share']},{r['biz']},{r['tour']},{n(r['slot_cap'])},{r['rwy']},{r['opens_day']},{q(r['sibling']) if r['sibling'] else 'null'})"
    for r in ind) + ";")
print("insert into public.airports (iata,city,country,region,is_india,lat,lon,mass,biz_idx,tour_idx,slot_cap,runway_class) values")
print(",\n".join(
    f"({q(r['iata'])},{q(r['city'])},{q(pos[r['iata']][1])},{q(r['region'])},false,{pos[r['iata']][2]},{pos[r['iata']][3]},{r['mass']},{r['biz']},{r['tour']},{n(r['slot_cap'])},{r['rwy']})"
    for r in frn) + ";")
