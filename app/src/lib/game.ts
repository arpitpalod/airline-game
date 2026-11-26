// Display helpers that mirror server rules (spec sections 5 and 7). The server re-checks everything;
// these only let screens show what a choice means before it is sent.
import type { Aircraft, AircraftType, Market, World } from './types';

export const pairKey = (a: string, b: string) => (a < b ? `${a}-${b}` : `${b}-${a}`);

/** Seat geometry of a layout: rows for the seat map. Mirrors public.layout_calc. */
export function layoutRows(t: AircraftType, bizRows: number, bizPitch: number | null, econPitch: number) {
  const bp = bizRows > 0 ? (t.biz_kind === 'lieflat' ? 44 : bizPitch ?? 38) : 0;
  const seatsBiz = bizRows * t.biz_abreast;
  const econRows = Math.floor((t.cabin_len_in - bizRows * bp) / econPitch);
  const seatsEcon = Math.max(0, Math.min(econRows * t.econ_abreast, t.max_seats - seatsBiz));
  return { econRows: Math.ceil(seatsEcon / t.econ_abreast), seatsEcon, seatsBiz, seats: seatsEcon + seatsBiz };
}

/** Minimum turnaround in minutes; delta is the airline's operating style (0023), never below 15 minutes. */
export function minTurn(t: AircraftType, seats: number, delta = 0) {
  return Math.max(15, Math.max(t.base_turn_min - 5, t.base_turn_min + 0.1 * (seats - t.ref_seats)) + delta);
}

export function cabinRange(t: AircraftType, seats: number) {
  return Math.round(t.range_km * Math.min(1.1, 1 - (0.4 * (seats - t.ref_seats)) / t.ref_seats));
}

/** Why an aircraft cannot fly a route, checked as set_rotation checks it, or null: a runway too short at either end,
 *  then the route beyond its range with this cabin. */
export function cannotFly(t: AircraftType, seats: number, ends: ({ city: string; runway_class: number } | undefined)[], km: number) {
  const short = ends.find((ap) => ap && ap.runway_class < t.runway_class);
  if (short) return { badge: 'Runway', why: short.runway_class === 1 ? `${short.city} takes turboprops only` : `${short.city}'s runway is too short for it` };
  const reach = cabinRange(t, seats);
  if (km > reach) return { badge: 'Too far', why: `Beyond its range: ${reach.toLocaleString('en-IN')} km with this cabin` };
  return null;
}

export function crewFor(seats: number) {
  return Math.ceil(seats / 50);
}

/** Hours one round trip takes, turnarounds included. */
export function tripHours(t: AircraftType, km: number, turnMin: number) {
  return 2 * (km / t.cruise_kmh + t.block_offset_h + turnMin / 60);
}

export function weekHours(t: AircraftType) {
  return 7 * t.day_window_h;
}

/** Round trips a week this aircraft could add on a route, given hours already planned elsewhere. */
export function maxWeekly(t: AircraftType, ac: Aircraft, km: number, usedHours: number, turnDelta = 0) {
  const trip = tripHours(t, km, minTurn(t, ac.seats_econ + ac.seats_biz, turnDelta));
  return Math.max(0, Math.min(84, Math.floor((weekHours(t) - usedHours + 1e-9) / trip)));
}

export function marketTotal(m: Market) {
  return m.n_biz + m.n_lei + m.n_bud;
}

/** Age in years at a game day; aircraft built before the world have negative build days. */
export function ageYears(ac: Aircraft, day: number) {
  return Math.max(0, (day - ac.built_day) / 364);
}

/** Pool rent estimate: base rent x shortage x age discount (3% a year, floor 50%). */
export function poolRentUsd(t: AircraftType, rentMult: number, age: number) {
  return t.lease_usd_month * rentMult * Math.max(0.5, 1 - 0.03 * Math.floor(age));
}

/** The world clock, as in game.clock_day (migration 0018): the pre-launch's weeks pass in prelaunch_minutes, then
 *  speed game days per real day. Only whole weeks fall due; results appear when the scheduler next runs (every 5 minutes). */
export function clockDay(w: World, sec: number) {
  const pre = w.prelaunch_weeks > 0 ? w.prelaunch_minutes * 60 : 0;
  if (w.prelaunch_weeks > 0 && sec < pre) return (sec * w.prelaunch_weeks * 7) / pre;
  return w.prelaunch_weeks * 7 + ((sec - pre) * w.speed) / 86400;
}
export function clockSeconds(w: World, day: number) {
  const pre = w.prelaunch_weeks > 0 ? w.prelaunch_minutes * 60 : 0;
  if (w.prelaunch_weeks > 0 && day < w.prelaunch_weeks * 7) return (day * pre) / (w.prelaunch_weeks * 7);
  return pre + ((day - w.prelaunch_weeks * 7) * 86400) / w.speed;
}
export function clock(w: World, now = Date.now()) {
  if (w.status !== 'running' || !w.started_at) return { dueDay: w.game_day, nextInSec: null as number | null };
  const elapsed = (now - Date.parse(w.started_at)) / 1000 - w.paused_seconds;
  const dueDay = 7 * Math.floor(clockDay(w, elapsed) / 7);
  const nextWeekEnd = 7 * (Math.floor(w.game_day / 7) + 1);              // results for the week being played
  const nextInSec = Math.max(0, clockSeconds(w, nextWeekEnd) - elapsed) + 150;   // plus half a scheduler interval on average
  return { dueDay, nextInSec };
}
/** The first game day a world's airlines fly, and whether the world is still in its pre-launch. */
export const worldFirstFlight = (w: World) => w.prelaunch_weeks * 7 + 1;
export const inPrelaunch = (w: World) => w.game_day + 1 < worldFirstFlight(w);

export const LIVERY_COLORS = ['#0E7C70', '#1E5AA8', '#7A3FD1', '#B4530F', '#C2185B', '#2E7D32', '#37474F', '#D4A017'];

export const STATUS_LABEL: Record<string, string> = {
  pool: 'With the lessor', delivering: 'On its way', active: 'In service', grounded: 'Grounded', refit: 'In refit', returned: 'Returned',
};

export const HOLDING_LABEL: Record<string, string> = { lease: 'Leased', owned: 'Owned', wet: 'Wet lease' };
export const holdingLabel = (a: { status: string; terms: { holding: string; ordered_day: number | null } | null }) =>
  a.status === 'delivering' && a.terms?.ordered_day != null ? 'On order' : HOLDING_LABEL[a.terms?.holding ?? 'lease'];
