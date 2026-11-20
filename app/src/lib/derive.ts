// Numbers derived from the raw tables, shared by several screens.
import type { FleetItem, Ref } from './data';
import { minTurn, pairKey, tripHours, weekHours } from './game';
import type { AircraftDaily, AirlineDaily, Market, Rotation, Route, RouteDaily } from './types';

export function dailyRevenue(d: AirlineDaily) { return d.rev_ticket + d.rev_anc; }
export function dailyOpCost(d: AirlineDaily) {
  return d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_other + d.c_depr;
}
export function dailyOpProfit(d: AirlineDaily) { return dailyRevenue(d) - dailyOpCost(d); }
export function dailyNetProfit(d: AirlineDaily) { return dailyOpProfit(d) - d.c_interest; }

export interface Sum { pax: number; ask: number; rpk: number; revenue: number; opCost: number; opProfit: number; netProfit: number; days: number; flights: number; cancelled: number }
export function sumDaily(ds: AirlineDaily[]): Sum {
  const s: Sum = { pax: 0, ask: 0, rpk: 0, revenue: 0, opCost: 0, opProfit: 0, netProfit: 0, days: ds.length, flights: 0, cancelled: 0 };
  for (const d of ds) {
    s.pax += d.pax; s.ask += d.ask; s.rpk += d.rpk; s.revenue += dailyRevenue(d); s.opCost += dailyOpCost(d);
    s.opProfit += dailyOpProfit(d); s.netProfit += dailyNetProfit(d); s.flights += d.flights; s.cancelled += d.cancelled;
  }
  return s;
}

/** Results week by week (week 1 is days 1 to 7), oldest first. */
export function byWeek(ds: AirlineDaily[]): (Sum & { week: number })[] {
  const m = new Map<number, AirlineDaily[]>();
  for (const d of ds) { const w = Math.floor((d.game_day - 1) / 7) + 1; m.set(w, [...(m.get(w) ?? []), d]); }
  return [...m.entries()].sort((a, b) => a[0] - b[0]).map(([week, rows]) => ({ week, ...sumDaily(rows) }));
}

export interface RouteStat { lf: number | null; pax: number; seats: number; revenue: number; varCost: number; aircraftCost: number; spill: number; days: number; flights: number }
export function routeStat(rd: RouteDaily[], routeId: string, fromDay: number): RouteStat {
  const s: RouteStat = { lf: null, pax: 0, seats: 0, revenue: 0, varCost: 0, aircraftCost: 0, spill: 0, days: 0, flights: 0 };
  for (const d of rd) {
    if (d.route_id !== routeId || d.game_day < fromDay) continue;
    s.pax += d.pax_econ + d.pax_biz; s.seats += d.seats_econ + d.seats_biz; s.revenue += d.revenue_inr;
    s.varCost += d.var_cost_inr; s.aircraftCost += d.aircraft_cost_inr ?? 0; s.spill += d.spill; s.days++; s.flights += d.flights;
  }
  s.lf = s.seats > 0 ? s.pax / s.seats : null;
  return s;
}

export function lfTone(lf: number | null): 'good' | 'warn' | 'low' | 'none' {
  if (lf == null) return 'none';
  return lf >= 0.7 ? 'good' : lf >= 0.5 ? 'warn' : 'low';
}

/** Weekly hours each aircraft is planned to fly, from its rotations. */
export function hoursByAircraft(fleet: FleetItem[], routes: Route[], rotations: Rotation[], markets: Record<string, Market> | undefined, ref: Ref) {
  const rById = Object.fromEntries(routes.map((r) => [r.id, r]));
  const out: Record<string, number> = {};
  for (const ac of fleet) {
    const t = ref.type[ac.type_id];
    let h = 0;
    for (const ro of rotations) {
      if (ro.aircraft_id !== ac.id) continue;
      const r = rById[ro.route_id]; const m = r && markets?.[pairKey(r.origin, r.dest)];
      if (m) h += ro.weekly_trips * tripHours(t, m.km, minTurn(t, ac.seats_econ + ac.seats_biz));
    }
    out[ac.id] = h;
  }
  return out;
}

export function windowShare(ac: FleetItem, hours: number, ref: Ref) {
  return hours / weekHours(ref.type[ac.type_id]);
}

export const COST_LINES: { key: keyof AirlineDaily; label: string }[] = [
  { key: 'c_fuel', label: 'Fuel' }, { key: 'c_rent', label: 'Aircraft rent' }, { key: 'c_crew', label: 'Crew' },
  { key: 'c_maint', label: 'Maintenance' }, { key: 'c_airport', label: 'Airport and navigation' }, { key: 'c_slots', label: 'Slots' },
  { key: 'c_dist', label: 'Sales, service and free extras' }, { key: 'c_marketing', label: 'Marketing' }, { key: 'c_overhead', label: 'Head office and bases' },
  { key: 'c_depr', label: 'Depreciation' }, { key: 'c_other', label: 'Other' },
];

// Unit economics of a route over a period: revenue and cost (flying costs plus the aircraft cost it carries) per seat-km,
// and the load factor at which revenue would just cover that cost at today's fares. Pilot salaries, head office and
// marketing are not included.
export function unitEcon(s: RouteStat, km: number) {
  const ask = s.seats * km;
  if (ask <= 0 || s.revenue <= 0) return null;
  const cost = s.varCost + s.aircraftCost;
  return { rask: s.revenue / ask, cask: cost / ask, beLf: s.lf != null ? s.lf * cost / s.revenue : null };
}

// An aircraft's days: revenue, flying costs and what holding it costs, summed.
export interface AircraftStat { days: number; revenue: number; flying: number; holding: number; result: number; pax: number; flights: number }
export function aircraftStats(ad: AircraftDaily[], fromDay: number) {
  const out: Record<string, AircraftStat> = {};
  for (const d of ad) {
    if (d.game_day < fromDay) continue;
    const s = (out[d.aircraft_id] ??= { days: 0, revenue: 0, flying: 0, holding: 0, result: 0, pax: 0, flights: 0 });
    s.days++; s.revenue += d.revenue_inr; s.flying += d.flying_cost_inr; s.holding += d.aircraft_cost_inr; s.pax += d.pax; s.flights += d.flights;
    s.result += d.revenue_inr - d.flying_cost_inr - d.aircraft_cost_inr;
  }
  return out;
}
