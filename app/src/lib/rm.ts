// Revenue management helpers: the same booking curves, calendar and fare levels as the engine (migration 0018).
import type { Departure, DepartureLog, Market, RmMode, RouteRm } from './types';
import type { Ref, RmCalendar } from './data';

export const MODE_LABEL: Record<RmMode, string> = { curve: 'Booking curve', optimise: 'Optimiser', manual: 'Manual' };
export const MODE_HELP: Record<RmMode, string> = {
  curve: 'You set the load to aim for. Each day the game opens a cheaper fare level when a flight sells slower than the target curve, and a dearer one when it sells faster.',
  optimise: 'Each day the game picks the fare level that should earn the most from the seats left, from who is still to book and what rivals charge. You set how hopeful its forecast is.',
  manual: 'You decide how many seats each cheap level may sell. When a level\'s seats are gone, the next dearer level opens.',
};
export const TYPES = ['Business', 'Leisure', 'Family and budget'] as const;
export const DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export const levelFare = (base: number, mult: number) => Math.round((base * mult) / 10) * 10;
export const sum = (a: (number | null)[]) => a.reduce<number>((s, v) => s + (v ?? 0), 0);
export const booked = (d: Departure | DepartureLog) => sum(d.sold_e) + sum(d.sold_b);

// Calendar of a game day: day 1 is a Monday; the year starts in the world's season_start_month.
export const dow = (day: number) => (day - 1) % 7;
export function doy(day: number, startMonth: number) { return (Math.floor(((startMonth - 1) * 91) / 3) + (day - 1)) % 364; }
export function monthOf(day: number, startMonth: number) { return ((startMonth - 1 + Math.floor((((day - 1) % 364) * 12) / 364)) % 12) + 1; }
export function dateLabel(day: number, startMonth: number, withDow = true) {
  const d = doy(day, startMonth), m = Math.floor((d * 12) / 364), dom = Math.floor(d - (m * 364) / 12) + 1;
  return `${withDow ? DOW[dow(day)] + ' ' : ''}${dom} ${MONTHS[m]}`;
}
export function festivalsOn(day: number, startMonth: number, intl: boolean, cal: RmCalendar | undefined) {
  if (!cal) return [];
  const d = doy(day, startMonth);
  return cal.festivals.filter((f) => (f.scope === 'all' || (f.scope === 'international') === intl)
    && (f.from_doy <= f.to_doy ? d >= f.from_doy && d <= f.to_doy : d >= f.from_doy || d <= f.to_doy));
}

// Share of a traveller type that books n or fewer days before the flight (n = -1: none)
export function left(n: number, tau: number, h: number) { return n < 0 ? 0 : (1 - Math.exp(-(n + 1) / tau)) / (1 - Math.exp(-h / tau)); }

// The target curve: seats a departure should have sold by the end of n days before it, aiming for the target load.
// Each type's booking curve is weighted by its share of the market that day (seasons and weekday), as in the engine.
export function targetAt(n: number, day: number, d: { cap_e: number; cap_b: number }, rm: RouteRm, m: Market, ref: Ref, cal: RmCalendar | undefined) {
  const p = ref.param, h = p.rm_horizon ?? 42, sm = p.season_start_month ?? 4;
  const s = cal?.season[monthOf(day, sm)] ?? { biz: 1, lei: 1, bud: 1 }, w = cal?.weekday[dow(day)] ?? { biz: 1, lei: 1, bud: 1 };
  const wb = m.n_biz * s.biz * w.biz, wl = m.n_lei * s.lei * w.lei, wu = m.n_bud * s.bud * w.bud;
  const tb = p.rm_tau_biz ?? 6, tl = p.rm_tau_lei ?? 16, tu = p.rm_tau_bud ?? 24;
  const ce = 1 - (wb * left(n - 1, tb, h) + wl * left(n - 1, tl, h) + wu * left(n - 1, tu, h)) / Math.max(1e-9, wb + wl + wu);
  const cb = 1 - left(n - 1, tb, h);
  return rm.target_lf * (d.cap_e * ce + d.cap_b * cb);
}

export type Pace = 'ahead' | 'on' | 'behind' | 'full' | 'none';
export function paceOf(d: Departure, today: number, rm: RouteRm, m: Market, ref: Ref, cal: RmCalendar | undefined): { pace: Pace; ratio: number | null } {
  const cap = d.cap_e + d.cap_b;
  if (cap <= 0) return { pace: 'none', ratio: null };
  const b = booked(d);
  if (b >= cap * (1 + rm.overbook) - 0.5) return { pace: 'full', ratio: null };
  const tgt = targetAt(d.dep_day - today, d.dep_day, d, rm, m, ref, cal);
  // the engine's dead band: the band around the curve, and at least a share of the seats
  const band = Math.max((ref.param.rm_curve_band ?? 0.08) * tgt, (ref.param.rm_curve_seats ?? 0.03) * cap);
  return { pace: b > tgt + band ? 'ahead' : b < tgt - band ? 'behind' : 'on', ratio: tgt > 0 ? b / tgt : null };
}
export const PACE_LABEL: Record<Pace, string> = { ahead: 'Selling fast', on: 'On target', behind: 'Selling slowly', full: 'Sold out', none: 'No seats' };
export const PACE_TONE: Record<Pace, 'good' | 'warn' | 'info' | 'accent' | 'neutral'> = { ahead: 'info', on: 'good', behind: 'warn', full: 'accent', none: 'neutral' };

// Results of flown departures (each way), and plain-language advice drawn from them
export interface RmStats {
  n: number; cap: number; pax: number; revenue: number; turned: number; noshow: number; denied: number; cancelled: number; comp: number;
  byLevel: number[]; sav: number[]; flx: number[]; bkb: number; lf: number | null; fare: number | null;
  early: number;    // share of economy seats sold at the two cheapest levels
}
export function rmStats(log: DepartureLog[]): RmStats {
  const z = (k: number) => Array.from({ length: k }, () => 0);
  const st: RmStats = { n: log.length, cap: 0, pax: 0, revenue: 0, turned: 0, noshow: 0, denied: 0, cancelled: 0, comp: 0, byLevel: z(6), sav: z(3), flx: z(3), bkb: 0, lf: null, fare: null, early: 0 };
  for (const l of log) {
    st.cap += l.cap_e + l.cap_b; st.pax += l.pax_e + l.pax_b; st.revenue += l.revenue; st.turned += l.turned;
    st.noshow += l.noshow; st.denied += l.denied; st.cancelled += l.cancelled ?? 0; st.comp += l.compensation; st.bkb += l.bkb;
    l.sold_e.forEach((v, i) => (st.byLevel[i] += v)); l.sav.forEach((v, i) => (st.sav[i] += v)); l.flx.forEach((v, i) => (st.flx[i] += v));
  }
  st.lf = st.cap ? st.pax / st.cap : null;
  st.fare = st.pax ? st.revenue / st.pax : null;
  const se = sum(st.byLevel);
  st.early = se ? (st.byLevel[0] + st.byLevel[1]) / se : 0;
  return st;
}

export function advice(st: RmStats, rm: RouteRm): string[] {
  const out: string[] = [];
  if (st.n < 3 || st.pax <= 0) return out;
  const turned = st.turned / st.pax, empty = st.lf != null ? 1 - st.lf : 0, biz = st.sav[0] + st.flx[0];
  if (turned > 0.03 && st.early > 0.25)
    out.push(`You turned away ${pct0(turned)} as many travellers as you carried, yet sold ${pct0(st.early)} of economy at the two cheapest levels. Cheap seats went early to people who would have paid more: close levels 1 and 2 earlier, sell fewer of them, or aim for a higher load.`);
  else if (turned > 0.03)
    out.push(`Flights sell out and you turn travellers away (${pct0(turned)} of what you carry). Your fares can go up, or the route can take more seats.`);
  if (empty > 0.25 && turned < 0.01)
    out.push(`Flights leave ${pct0(empty)} empty. Keep the cheaper levels on sale longer, lower the base fare, or put fewer seats on the route.`);
  if (biz > 0 && rm.flex != null && st.flx[0] / biz < 0.4)
    out.push('Fewer than 4 in 10 business travellers buy Flexi: its price is above what they think flexibility is worth.');
  if (biz > 0 && rm.flex != null && st.flx[0] / biz > 0.9)
    out.push('Almost every business traveller buys Flexi: it could cost more.');
  if (st.denied > 0.005 * st.pax)
    out.push(`${pct0(st.denied / st.pax)} of passengers could not board, at ${inr0(st.comp / Math.max(1, st.denied))} each in compensation. Overbook less.`);
  else if (rm.overbook < st.noshow / st.pax - 0.005 && empty < 0.1)
    out.push(`About ${pct0(st.noshow / st.pax)} of passengers do not turn up and your flights are nearly full: overbooking by about that much would fill their seats.`);
  return out;
}
const pct0 = (x: number) => `${Math.round(x * 100)}%`;
const inr0 = (x: number) => `₹${Math.round(x).toLocaleString('en-IN')}`;
export const kRs = (x: number | null | undefined) => (x == null ? '–' : x >= 1e5 ? `${(x / 1e5).toFixed(1)}L` : x >= 1e3 ? `${(x / 1e3).toFixed(1)}k` : `${Math.round(x)}`);
