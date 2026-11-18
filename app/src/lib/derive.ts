// Numbers derived from the raw tables, shared by several screens.
import type { FleetItem, Ref } from './data';
import { minTurn, pairKey, tripHours, weekHours } from './game';
import type { AirlineDaily, Market, Rotation, Route, RouteDaily } from './types';

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

export interface RouteStat { lf: number | null; pax: number; seats: number; revenue: number; varCost: number; spill: number; days: number; flights: number }
export function routeStat(rd: RouteDaily[], routeId: string, fromDay: number): RouteStat {
  const s: RouteStat = { lf: null, pax: 0, seats: 0, revenue: 0, varCost: 0, spill: 0, days: 0, flights: 0 };
  for (const d of rd) {
    if (d.route_id !== routeId || d.game_day < fromDay) continue;
    s.pax += d.pax_econ + d.pax_biz; s.seats += d.seats_econ + d.seats_biz; s.revenue += d.revenue_inr;
    s.varCost += d.var_cost_inr; s.spill += d.spill; s.days++; s.flights += d.flights;
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
