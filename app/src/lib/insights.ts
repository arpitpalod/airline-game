// Insights (step 3 of spec section 19): sector kinds, the verdict on each flown week, and the practice flight, a small
// simulation of one flight week selling under each strategy (no database writes; a simplified copy of game.sell_week).
import type { Market, RouteWeek, Strategy, StrategyKey } from './types';

export type Band = 'short' | 'medium' | 'long' | 'intl';
export type Shape = 'alone' | 'two' | 'few' | 'many';
export const BAND_LABEL: Record<Band, string> = { short: 'Short (under 800 km)', medium: 'Medium (800 to 1,800 km)', long: 'Long domestic', intl: 'International' };
export const SHAPE_LABEL: Record<Shape, string> = { alone: 'Alone', two: 'Two airlines', few: 'Three or four', many: 'Five or more' };
export const STRAT_SHORT: Record<StrategyKey, string> = { fill: 'Fill', balanced: 'Balanced', top: 'Top', follow: 'Follow' };
export const bandOf = (m: Pick<Market, 'km' | 'intl'>): Band => (m.intl ? 'intl' : m.km < 800 ? 'short' : m.km < 1800 ? 'medium' : 'long');
export const shapeOf = (airlines: number): Shape => (airlines <= 1 ? 'alone' : airlines === 2 ? 'two' : airlines <= 4 ? 'few' : 'many');

export interface SectorInsight {
  world_id: string; week: number; band: Band; shape: Shape; strategy: StrategyKey; routes: number; weeks: number;
  load: number; fare_index: number | null; rev_index: number;
}

/** A flown week in plain words: too full (travellers turned away), too empty (seats flew empty), or about right. */
export function verdict(w: RouteWeek) {
  const seats = w.seats_e + w.seats_b;
  const flown = (w.flown_e ?? 0) + (w.flown_b ?? 0);
  const empty = Math.max(0, seats - flown);
  const turned = w.spill;
  const kind: 'full' | 'empty' | 'right' = seats > 0 && turned >= 0.05 * seats ? 'full' : seats > 0 && empty >= 0.2 * seats ? 'empty' : 'right';
  return { seats, flown, empty, turned, kind };
}

/** The route's own last flown weeks, as revenue per seat over the reference fare (as in sector_insights). */
export function routeIndex(weeks: RouteWeek[], ref: number) {
  const f = weeks.filter((w) => w.flown_e != null && w.seats_e + w.seats_b > 0);
  const seats = f.reduce((s, w) => s + w.seats_e + w.seats_b, 0);
  const flown = f.reduce((s, w) => s + (w.flown_e ?? 0) + (w.flown_b ?? 0), 0);
  const rev = f.reduce((s, w) => s + (w.rev_flown_e ?? 0) + (w.rev_flown_b ?? 0), 0);
  return seats ? { load: flown / seats, rev_index: rev / (seats * ref), weeks: f.length } : null;
}

// ---------- Practice flight ----------
export interface PracticeInput {
  m: Market; seats: number; tripsDay: number; rivalSeats: number; rivalTripsDay: number; rivalFare: number | null;
  season: number; demandScale: number; p: Record<string, number>;
}
export interface PracticeWeek { n: number; fare: number; booked: number; target: number }
export interface PracticeResult { key: StrategyKey; revenue: number; sold: number; load: number; fare: number; turned: number; empty: number; weeks: PracticeWeek[] }

/** The practice run's set-up for one of the player's routes: its own seats (or one A320neo twice a day if it has no
 *  aircraft yet), the rivals' seats, flights and average fare, and this week's demand (scale and growth, G). */
export function practiceInput(m: Market, all: { route: { airline_id: string; fare_econ: number }; weekly: number; seatsWeek: number }[],
                              airlineId: string, demandScale: number, day: number, p: Record<string, number>, season = 1): PracticeInput {
  const mine = all.find((x) => x.route.airline_id === airlineId);
  const theirs = all.filter((x) => x.route.airline_id !== airlineId && x.weekly > 0);
  const seats = mine && mine.seatsWeek > 0 ? mine.seatsWeek / 2 : 14 * 180;
  const trips = mine && mine.weekly > 0 ? mine.weekly / 7 : 2;
  const rSeats = theirs.reduce((s, x) => s + x.seatsWeek / 2, 0);
  const rTrips = theirs.reduce((s, x) => s + x.weekly / 7, 0);
  const rFare = theirs.length ? theirs.reduce((s, x) => s + x.route.fare_econ * x.seatsWeek, 0) / Math.max(1, theirs.reduce((s, x) => s + x.seatsWeek, 0)) : null;
  const g = m.intl ? (p.growth_year_intl ?? p.growth_year ?? 0) : (p.growth_year ?? 0);
  return { m, seats, tripsDay: trips, rivalSeats: rSeats, rivalTripsDay: rTrips, rivalFare: rFare, season,
           demandScale: demandScale * Math.pow(1 + g, (Math.max(day, 1) - 1) / 364), p };
}

/** One flight week on sale for 26 weeks, selling against rivals who hold their fare. Economy only, no no-shows. */
export function practice(s: Strategy, x: PracticeInput): PracticeResult {
  const h = x.p.sale_weeks ?? 26;
  const curve = (shape: number, scale: number) => {
    const raw = Array.from({ length: h }, (_, n) => Math.pow(n + 0.5, shape) * Math.exp(-(n + 0.5) / scale));
    const tot = raw.reduce((a, b) => a + b, 0);
    return raw.map((v) => v / tot);
  };
  const arr = { b: curve(x.p.book_shape_biz ?? 0, x.p.book_scale_biz ?? 1.5), l: curve(x.p.book_shape_lei ?? 2, x.p.book_scale_lei ?? 2.5), u: curve(x.p.book_shape_bud ?? 2, x.p.book_scale_bud ?? 3.5) };
  const pre = (a: number[], n: number) => a.slice(n + 1).reduce((s0, v) => s0 + v, 0);
  const lam = x.p.nest_lambda ?? 0.6;
  const ref = x.m.ref_fare;
  const segs = [
    { k: 'b' as const, n: x.m.n_biz, a: x.p.seg_biz_a, pr: x.p.seg_biz_price, fq: x.p.seg_biz_freq },
    { k: 'l' as const, n: x.m.n_lei, a: x.p.seg_lei_a, pr: x.p.seg_lei_price, fq: x.p.seg_lei_freq },
    { k: 'u' as const, n: x.m.n_bud, a: x.p.seg_bud_a, pr: x.p.seg_bud_price, fq: x.p.seg_bud_freq },
  ];
  const wsum = x.m.n_biz + x.m.n_lei + x.m.n_bud || 1;
  const ramp = (n: number) => Math.pow((h - 1 - n) / (h - 1), x.p.fare_ramp_power ?? 3);
  let adj = 1, sold = 0, rev = 0, turned = 0;
  const weeks: PracticeWeek[] = [];
  for (let n = h - 1; n >= 0; n--) {
    const base = s.early_mult + (s.late_mult - s.early_mult) * ramp(n);
    const tgt = s.target_lf * x.seats * (x.m.n_biz * pre(arr.b, n) + x.m.n_lei * pre(arr.l, n) + x.m.n_bud * pre(arr.u, n)) / wsum;
    if (tgt >= 0.02 * x.seats && Math.abs(sold / tgt - 1) > s.band)
      adj *= 1 + s.step * Math.max(-3, Math.min(3, (sold / tgt - 1) / Math.max(s.band, 0.01)));
    adj = Math.min(s.max_mult / base, Math.max(s.min_mult / base, adj));
    let fare = Math.round((ref * base * adj) / 10) * 10;
    if (s.key === 'follow' && x.rivalFare) fare = Math.round(Math.min(s.max_mult * ref, Math.max(s.min_mult * ref, x.rivalFare * (1 + s.follow_gap))) / 10) * 10;
    const room = Math.max(0, x.seats - sold);
    let want = 0;
    for (const g of segs) {
      const A = 7 * g.n * x.demandScale * x.season * arr[g.k][n];
      const xm = room > 0.5 ? Math.exp((g.a - g.pr * (fare / ref) + g.fq * Math.log(1 + x.tripsDay)) / lam) : 0;
      const xr = x.rivalSeats > 0 ? Math.exp((g.a - g.pr * ((x.rivalFare ?? ref) / ref) + g.fq * Math.log(1 + x.rivalTripsDay)) / lam) : 0;
      const S = xm + xr;
      const k = S > 0 ? Math.pow(S, lam - 1) / (1 + Math.pow(S, lam)) : 0;
      want += A * xm * k;
    }
    const got = Math.min(want, room);
    sold += got; rev += got * fare; turned += want - got;
    weeks.push({ n, fare, booked: got, target: tgt });
  }
  return { key: s.key, revenue: rev, sold, load: x.seats ? sold / x.seats : 0, fare: sold ? rev / sold : 0, turned, empty: Math.max(0, x.seats - sold), weeks };
}
